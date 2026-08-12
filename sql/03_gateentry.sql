-- ============================================================
-- Gate Entry module — table + stored procedures
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/gateentry (port 8084, mounted at /api/gate_entry)
--
-- NOT YET RUN on the live DB — review the JOINs against po_request_info /
-- kyc_basic_info / company_master etc. (column names taken from
-- schema_mysql.sql) before executing on 10.0.21.8, then run this whole file.
--
-- All procedures follow this codebase's convention: a single optional
-- @jsonInput NVARCHAR(MAX) parameter, fields read via JSON_VALUE. This
-- matches grn-service/src/gateentry/gateentry.repository.js, which always
-- calls procedures with one JSON-serialised parameters object (or none).
-- ============================================================

-- ── Table ─────────────────────────────────────────────────────────────────

IF OBJECT_ID('dbo.nt_gate_entry', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_gate_entry (
        gate_entry_sno   INT IDENTITY(1,1) PRIMARY KEY,
        gate_entry_no    VARCHAR(30)   NOT NULL UNIQUE,
        po_basic_sno     INT           NOT NULL,
        invoice_no       VARCHAR(100)  NOT NULL,
        invoice_date     DATE          NOT NULL,
        received_qty     DECIMAL(18,2) NOT NULL,
        received_date    DATE          NOT NULL,
        bundles          INT           NULL,
        transport_name   VARCHAR(255)  NULL,
        lr_no            VARCHAR(100)  NULL,
        receiver_ecno    VARCHAR(50)   NULL,
        photo_url        VARCHAR(500)  NULL,
        status           VARCHAR(20)   NOT NULL DEFAULT 'In',   -- In | Verified | GRN Done | Out
        created_by       VARCHAR(50)   NULL,
        created_at       DATETIME      NOT NULL DEFAULT GETDATE(),
        updated_by       VARCHAR(50)   NULL,
        updated_at       DATETIME      NULL
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_gate_entry_po_basic_sno' AND object_id = OBJECT_ID('dbo.nt_gate_entry'))
    CREATE INDEX IX_nt_gate_entry_po_basic_sno ON dbo.nt_gate_entry (po_basic_sno);
GO

-- ============================================================
-- sp_nt_GetPendingPOsForGRN
-- Approved POs pending receipt (qty-based: any item not yet fully GRN'd),
-- used by the GRN module's own PO browsing. Gate Entry's PO search uses
-- sp_nt_GetPOsPendingGateEntry instead (below) — a PO only ever gets one
-- gate entry, so that one is gated on gate-entry existence, not GRN qty.
-- One row per PO, with an `items` column holding a JSON array (frontend
-- parses it if it's a string).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPendingPOsForGRN', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPendingPOsForGRN;
GO

CREATE PROCEDURE dbo.sp_nt_GetPendingPOsForGRN
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_no NVARCHAR(50) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @po_no = JSON_VALUE(@jsonInput, '$.po_no');

    SELECT
        p.po_basic_sno,
        p.po_df_no                              AS po_no,
        p.pr_basic_sno,
        pr.pr_no                                AS pr_no,
        p.vendor_sno,
        k.company_name                          AS vendor_name,
        c.com_name                              AS com_name,
        CONVERT(VARCHAR(10), p.po_date, 120)     AS po_date,
        CONVERT(VARCHAR(10), p.required_date,120) AS required_date,
        p.delivery_address,
        p.terms_conditions,
        p.purpose,
        p.com_sno,
        p.div_sno,
        dv.div_name,
        p.brn_sno,
        br.brn_name,
        p.dept_sno,
        dp.dept_name,
        p.status,
        (
            SELECT
                i.po_item_sno,
                i.prod_sno,
                ISNULL(i.prod_name, pm.prod_name) AS prod_name,
                i.specification,
                i.qty            AS ordered_qty,
                ISNULL(i.unit_name, um.uom_name) AS unit_name,
                i.agreed_unit_price AS unit_price,
                i.net_cost       AS total_amount
            FROM dbo.po_item_details i
            LEFT JOIN dbo.product_master pm ON pm.prod_sno = i.prod_sno
            LEFT JOIN dbo.uom_master um     ON um.uom_sno  = i.unit
            WHERE i.po_basic_sno = p.po_basic_sno
              -- po_item_details.is_active has been observed as '1' rather than 'Y' in production
              AND i.is_active IN ('1', 'Y')
            FOR JSON PATH
        )                                        AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = p.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = p.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = p.dept_sno
    LEFT JOIN dbo.pr_basic_info pr   ON pr.pr_basic_sno = p.pr_basic_sno
    WHERE p.is_active = 'Y' AND p.status = 'A'
      AND (@po_no IS NULL OR p.po_df_no = @po_no)
      -- Drop POs whose items are all fully received (no pending qty left) —
      -- a fully received PO has nothing left to log at the gate.
      AND EXISTS (
          SELECT 1
          FROM dbo.po_item_details i
          LEFT JOIN (
              SELECT po_item_sno, SUM(received_qty) AS received_so_far
              FROM dbo.grn_item_details
              WHERE is_active = 'Y'
              GROUP BY po_item_sno
          ) rq ON rq.po_item_sno = i.po_item_sno
          WHERE i.po_basic_sno = p.po_basic_sno
            AND i.is_active IN ('1', 'Y')
            AND ISNULL(rq.received_so_far, 0) < i.qty
      )
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetPOsPendingGateEntry
-- Approved POs that don't have a gate entry yet — a PO only ever gets one
-- gate entry (no re-registering it once it's been logged at the gate, even
-- if that entry is still awaiting GRN/verification), so this excludes any
-- PO with an existing dbo.nt_gate_entry row regardless of that row's status.
-- Same shape as sp_nt_GetPendingPOsForGRN so the frontend can parse either.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPOsPendingGateEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPOsPendingGateEntry;
GO

CREATE PROCEDURE dbo.sp_nt_GetPOsPendingGateEntry
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_no NVARCHAR(50) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @po_no = JSON_VALUE(@jsonInput, '$.po_no');

    SELECT
        p.po_basic_sno,
        p.po_df_no                              AS po_no,
        p.pr_basic_sno,
        pr.pr_no                                AS pr_no,
        p.vendor_sno,
        k.company_name                          AS vendor_name,
        c.com_name                              AS com_name,
        CONVERT(VARCHAR(10), p.po_date, 120)     AS po_date,
        CONVERT(VARCHAR(10), p.required_date,120) AS required_date,
        p.delivery_address,
        p.terms_conditions,
        p.purpose,
        p.com_sno,
        p.div_sno,
        dv.div_name,
        p.brn_sno,
        br.brn_name,
        p.dept_sno,
        dp.dept_name,
        p.status,
        (
            SELECT
                i.po_item_sno,
                i.prod_sno,
                ISNULL(i.prod_name, pm.prod_name) AS prod_name,
                i.specification,
                i.qty            AS ordered_qty,
                ISNULL(i.unit_name, um.uom_name) AS unit_name,
                i.agreed_unit_price AS unit_price,
                i.net_cost       AS total_amount
            FROM dbo.po_item_details i
            LEFT JOIN dbo.product_master pm ON pm.prod_sno = i.prod_sno
            LEFT JOIN dbo.uom_master um     ON um.uom_sno  = i.unit
            WHERE i.po_basic_sno = p.po_basic_sno
              AND i.is_active IN ('1', 'Y')
            FOR JSON PATH
        )                                        AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.company_master c  ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = p.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = p.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = p.dept_sno
    LEFT JOIN dbo.pr_basic_info pr   ON pr.pr_basic_sno = p.pr_basic_sno
    WHERE p.is_active = 'Y' AND p.status = 'A'
      AND (@po_no IS NULL OR p.po_df_no = @po_no)
      AND NOT EXISTS (
          SELECT 1 FROM dbo.nt_gate_entry g WHERE g.po_basic_sno = p.po_basic_sno
      )
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetAllGateEntries
-- @jsonInput optional: { status, pending_only }
-- pending_only=1 excludes entries already at 'GRN Done' — used by the Gate
-- Entry sidebar, which has nothing left to verify/edit on those.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetAllGateEntries', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAllGateEntries;
GO

CREATE PROCEDURE dbo.sp_nt_GetAllGateEntries
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    DECLARE @pending_only BIT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @status = JSON_VALUE(@jsonInput, '$.status');
        SET @pending_only = TRY_CAST(JSON_VALUE(@jsonInput, '$.pending_only') AS BIT);
    END

    SELECT
        g.gate_entry_sno,
        g.gate_entry_no,
        g.po_basic_sno,
        p.po_df_no                             AS po_no,
        k.company_name                         AS vendor_name,
        g.invoice_no,
        CONVERT(VARCHAR(10), g.invoice_date, 120)  AS invoice_date,
        g.received_qty,
        CONVERT(VARCHAR(10), g.received_date, 120) AS received_date,
        g.bundles,
        g.transport_name,
        g.lr_no,
        g.receiver_ecno,
        g.photo_url,
        g.status,
        g.created_by                           AS created_by_name,
        CONVERT(VARCHAR(30), g.created_at, 120) AS created_at
    FROM dbo.nt_gate_entry g
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = g.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE (@status IS NULL OR g.status = @status)
      AND (ISNULL(@pending_only, 0) = 0 OR g.status <> 'GRN Done')
    ORDER BY g.gate_entry_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetGateEntriesByPO
-- @jsonInput: { po_basic_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetGateEntriesByPO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetGateEntriesByPO;
GO

CREATE PROCEDURE dbo.sp_nt_GetGateEntriesByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    SELECT
        g.gate_entry_sno,
        g.gate_entry_no,
        g.po_basic_sno,
        p.po_df_no                             AS po_no,
        k.company_name                         AS vendor_name,
        g.invoice_no,
        CONVERT(VARCHAR(10), g.invoice_date, 120)  AS invoice_date,
        g.received_qty,
        CONVERT(VARCHAR(10), g.received_date, 120) AS received_date,
        g.bundles,
        g.transport_name,
        g.lr_no,
        g.receiver_ecno,
        g.photo_url,
        g.status,
        g.created_by                           AS created_by_name,
        CONVERT(VARCHAR(30), g.created_at, 120) AS created_at
    FROM dbo.nt_gate_entry g
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = g.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE g.po_basic_sno = @po_basic_sno
    ORDER BY g.gate_entry_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_CreateGateEntry
-- @jsonInput: { po_basic_sno, invoice_no, invoice_date, received_qty,
--               received_date, bundles, transport_name, lr_no,
--               receiver_ecno, photo_url, created_by }
-- Returns the created row: gate_entry_sno, gate_entry_no, status
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateGateEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateGateEntry;
GO

CREATE PROCEDURE dbo.sp_nt_CreateGateEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno   INT           = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @invoice_no     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.invoice_no');
    DECLARE @invoice_date   DATE          = JSON_VALUE(@jsonInput, '$.invoice_date');
    DECLARE @received_qty   DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.received_qty');
    DECLARE @received_date  DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @bundles        INT           = JSON_VALUE(@jsonInput, '$.bundles');
    DECLARE @transport_name VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.transport_name');
    DECLARE @lr_no          VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.lr_no');
    DECLARE @receiver_ecno  VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.receiver_ecno');
    DECLARE @photo_url      VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.photo_url');
    DECLARE @created_by     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @po_basic_sno IS NULL OR @invoice_no IS NULL OR @received_qty IS NULL OR @received_date IS NULL
    BEGIN
        RAISERROR('po_basic_sno, invoice_no, received_qty and received_date are required.', 16, 1);
        RETURN;
    END

    -- Sequential per-year gate no: GE-YYYY-NNNNNN
    DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
    DECLARE @seq  INT;

    SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(gate_entry_no, 6) AS INT)), 0) + 1
    FROM dbo.nt_gate_entry
    WHERE gate_entry_no LIKE 'GE-' + @year + '-%';

    DECLARE @gate_entry_no VARCHAR(30) = 'GE-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

    INSERT INTO dbo.nt_gate_entry (
        gate_entry_no, po_basic_sno, invoice_no, invoice_date,
        received_qty, received_date, bundles, transport_name,
        lr_no, receiver_ecno, photo_url, status, created_by, created_at
    )
    VALUES (
        @gate_entry_no, @po_basic_sno, @invoice_no, @invoice_date,
        @received_qty, @received_date, @bundles, @transport_name,
        @lr_no, @receiver_ecno, @photo_url, 'In', @created_by, GETDATE()
    );

    SELECT
        gate_entry_sno,
        gate_entry_no,
        status
    FROM dbo.nt_gate_entry
    WHERE gate_entry_sno = SCOPE_IDENTITY();
END;
GO

-- ============================================================
-- sp_nt_UpdateGateEntryStatus
-- @jsonInput: { gate_entry_sno, status, updated_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_UpdateGateEntryStatus', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateGateEntryStatus;
GO

CREATE PROCEDURE dbo.sp_nt_UpdateGateEntryStatus
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gate_entry_sno INT         = JSON_VALUE(@jsonInput, '$.gate_entry_sno');
    DECLARE @status         VARCHAR(20) = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @updated_by     VARCHAR(50) = JSON_VALUE(@jsonInput, '$.updated_by');

    UPDATE dbo.nt_gate_entry
    SET status = @status,
        updated_by = @updated_by,
        updated_at = GETDATE()
    WHERE gate_entry_sno = @gate_entry_sno;

    SELECT gate_entry_sno, gate_entry_no, status
    FROM dbo.nt_gate_entry
    WHERE gate_entry_sno = @gate_entry_sno;
END;
GO

-- ============================================================
-- sp_nt_UpdateGateEntry
-- Full-record edit (invoice/qty/dates/transport/etc.) for a gate entry
-- that hasn't been consumed by a GRN yet. Once status = 'GRN Done' the
-- entry is locked — editing it after the fact would desync the GRN
-- that was created from its received_qty/invoice details.
-- @jsonInput: { gate_entry_sno, invoice_no, invoice_date, received_qty,
--               received_date, bundles, transport_name, lr_no,
--               receiver_ecno, photo_url, updated_by }
-- photo_url is optional — pass NULL/omit to keep the existing photo.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_UpdateGateEntry', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateGateEntry;
GO

CREATE PROCEDURE dbo.sp_nt_UpdateGateEntry
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gate_entry_sno INT           = JSON_VALUE(@jsonInput, '$.gate_entry_sno');
    DECLARE @invoice_no     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.invoice_no');
    DECLARE @invoice_date   DATE          = JSON_VALUE(@jsonInput, '$.invoice_date');
    DECLARE @received_qty   DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.received_qty');
    DECLARE @received_date  DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @bundles        INT           = JSON_VALUE(@jsonInput, '$.bundles');
    DECLARE @transport_name VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.transport_name');
    DECLARE @lr_no          VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.lr_no');
    DECLARE @receiver_ecno  VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.receiver_ecno');
    DECLARE @photo_url      VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.photo_url');
    DECLARE @updated_by     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.updated_by');

    IF @gate_entry_sno IS NULL OR @invoice_no IS NULL OR @received_qty IS NULL OR @received_date IS NULL
    BEGIN
        RAISERROR('gate_entry_sno, invoice_no, received_qty and received_date are required.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.nt_gate_entry WHERE gate_entry_sno = @gate_entry_sno)
    BEGIN
        RAISERROR('Gate entry not found.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.nt_gate_entry WHERE gate_entry_sno = @gate_entry_sno AND status = 'GRN Done')
    BEGIN
        RAISERROR('This gate entry has already been used for a GRN and can no longer be edited.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_gate_entry
    SET invoice_no     = @invoice_no,
        invoice_date   = @invoice_date,
        received_qty   = @received_qty,
        received_date  = @received_date,
        bundles        = @bundles,
        transport_name = @transport_name,
        lr_no          = @lr_no,
        receiver_ecno  = @receiver_ecno,
        photo_url      = ISNULL(@photo_url, photo_url),
        updated_by     = @updated_by,
        updated_at     = GETDATE()
    WHERE gate_entry_sno = @gate_entry_sno;

    SELECT
        g.gate_entry_sno,
        g.gate_entry_no,
        g.po_basic_sno,
        p.po_df_no                             AS po_no,
        k.company_name                         AS vendor_name,
        g.invoice_no,
        CONVERT(VARCHAR(10), g.invoice_date, 120)  AS invoice_date,
        g.received_qty,
        CONVERT(VARCHAR(10), g.received_date, 120) AS received_date,
        g.bundles,
        g.transport_name,
        g.lr_no,
        g.receiver_ecno,
        g.photo_url,
        g.status,
        g.created_by                           AS created_by_name,
        CONVERT(VARCHAR(30), g.created_at, 120) AS created_at
    FROM dbo.nt_gate_entry g
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = g.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE g.gate_entry_sno = @gate_entry_sno;
END;
GO
