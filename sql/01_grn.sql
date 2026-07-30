-- ============================================================
-- GRN (Goods Receipt Note) module — tables + stored procedures
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/grn (port 8084, mounted at /api/grn)
--
-- NOT YET RUN on the live DB — review the JOINs against po_request_info /
-- kyc_basic_info / company_master etc. (column names taken from
-- schema_mysql.sql) before executing on 10.0.21.8, then run this whole file.
-- Depends on grn-service/sql/03_gateentry.sql having been run first
-- (nt_gate_entry table + sp_nt_UpdateGateEntryStatus).
--
-- GRN is gated on Gate Entry: a GRN can only be raised against a gate entry
-- whose status is not yet 'GRN Done' (sp_nt_GetPendingGateEntriesForGRN).
-- After sp_nt_CreateGRN inserts successfully, grn-service's application
-- layer (not this SP) calls sp_nt_UpdateGateEntryStatus to flip the gate
-- entry to 'GRN Done' — keeping DB objects single-purpose.
--
-- All procedures follow this codebase's convention: a single optional
-- @jsonInput NVARCHAR(MAX) parameter, fields read via JSON_VALUE/JSON_QUERY.
-- This matches grn-service/src/grn/grn.repository.js.
-- ============================================================

-- ── Tables ────────────────────────────────────────────────────────────────

IF OBJECT_ID('dbo.nt_grn_basic_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_grn_basic_info (
        grn_basic_sno    INT IDENTITY(1,1) PRIMARY KEY,
        grn_no           VARCHAR(30)   NOT NULL UNIQUE,
        gate_entry_sno   INT           NOT NULL,
        po_basic_sno     INT           NOT NULL,
        vendor_sno       INT           NULL,
        received_date    DATE          NOT NULL,
        doc_ref_no       VARCHAR(100)  NULL,
        vehicle_no       VARCHAR(50)   NULL,
        challan_no       VARCHAR(100)  NULL,
        remarks          VARCHAR(500)  NULL,
        status           VARCHAR(20)   NOT NULL DEFAULT 'Received',
        created_by       VARCHAR(50)   NULL,
        created_at       DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_nt_grn_basic_info_gate_entry
            FOREIGN KEY (gate_entry_sno) REFERENCES dbo.nt_gate_entry (gate_entry_sno)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_grn_basic_info_po_basic_sno' AND object_id = OBJECT_ID('dbo.nt_grn_basic_info'))
    CREATE INDEX IX_nt_grn_basic_info_po_basic_sno ON dbo.nt_grn_basic_info (po_basic_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_grn_basic_info_gate_entry_sno' AND object_id = OBJECT_ID('dbo.nt_grn_basic_info'))
    CREATE INDEX IX_nt_grn_basic_info_gate_entry_sno ON dbo.nt_grn_basic_info (gate_entry_sno);
GO

IF OBJECT_ID('dbo.nt_grn_item_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_grn_item_details (
        grn_item_sno     INT IDENTITY(1,1) PRIMARY KEY,
        grn_basic_sno    INT           NOT NULL,
        po_item_sno      INT           NULL,
        prod_sno         INT           NULL,
        prod_name        VARCHAR(255)  NULL,
        specification    VARCHAR(500)  NULL,
        ordered_qty      DECIMAL(18,2) NULL,
        received_qty     DECIMAL(18,2) NOT NULL,
        rejected_qty     DECIMAL(18,2) NOT NULL DEFAULT 0,
        unit_name        VARCHAR(50)   NULL,
        condition        VARCHAR(20)   NOT NULL DEFAULT 'Good',  -- Good | Damaged | Partial
        remarks          VARCHAR(500)  NULL,
        CONSTRAINT FK_nt_grn_item_details_grn
            FOREIGN KEY (grn_basic_sno) REFERENCES dbo.nt_grn_basic_info (grn_basic_sno)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_grn_item_details_grn_basic_sno' AND object_id = OBJECT_ID('dbo.nt_grn_item_details'))
    CREATE INDEX IX_nt_grn_item_details_grn_basic_sno ON dbo.nt_grn_item_details (grn_basic_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_grn_item_details_po_item_sno' AND object_id = OBJECT_ID('dbo.nt_grn_item_details'))
    CREATE INDEX IX_nt_grn_item_details_po_item_sno ON dbo.nt_grn_item_details (po_item_sno);
GO

-- ============================================================
-- sp_nt_GetPendingGateEntriesForGRN
-- Gate entries not yet turned into a GRN (status <> 'GRN Done'), joined to
-- the same PO/vendor/org info as sp_nt_GetPendingPOsForGRN, plus each item's
-- pending_qty (ordered_qty minus what's already been received via GRN).
-- @jsonInput optional: { gate_entry_no }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPendingGateEntriesForGRN', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPendingGateEntriesForGRN;
GO

CREATE PROCEDURE dbo.sp_nt_GetPendingGateEntriesForGRN
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gate_entry_no NVARCHAR(30) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @gate_entry_no = JSON_VALUE(@jsonInput, '$.gate_entry_no');

    SELECT
        g.gate_entry_sno,
        g.gate_entry_no,
        g.invoice_no,
        CONVERT(VARCHAR(10), g.invoice_date, 120)   AS invoice_date,
        g.received_qty                              AS gate_received_qty,
        CONVERT(VARCHAR(10), g.received_date, 120)  AS gate_received_date,
        g.status                                    AS gate_entry_status,
        p.po_basic_sno,
        p.po_df_no                                AS po_no,
        p.pr_basic_sno,
        pr.pr_no                                  AS pr_no,
        p.vendor_sno,
        k.company_name                            AS vendor_name,
        c.com_name                                AS com_name,
        CONVERT(VARCHAR(10), p.po_date, 120)      AS po_date,
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
                i.qty              AS ordered_qty,
                ISNULL(i.unit_name, um.uom_name) AS unit_name,
                i.agreed_unit_price AS unit_price,
                i.net_cost         AS total_amount,
                ISNULL(rq.received_so_far, 0)          AS received_qty,
                (i.qty - ISNULL(rq.received_so_far, 0)) AS pending_qty
            FROM dbo.po_item_details i
            LEFT JOIN dbo.product_master pm ON pm.prod_sno = i.prod_sno
            LEFT JOIN dbo.uom_master um     ON um.uom_sno  = i.unit
            LEFT JOIN (
                SELECT po_item_sno, SUM(received_qty) AS received_so_far
                FROM dbo.nt_grn_item_details
                GROUP BY po_item_sno
            ) rq ON rq.po_item_sno = i.po_item_sno
            WHERE i.po_basic_sno = p.po_basic_sno
              -- po_item_details.is_active has been observed as '1' rather than 'Y' in production
              AND i.is_active IN ('1', 'Y')
            FOR JSON PATH
        )                                          AS items
    FROM dbo.nt_gate_entry g
    JOIN dbo.po_request_info p       ON p.po_basic_sno = g.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.company_master c   ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = p.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = p.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = p.dept_sno
    LEFT JOIN dbo.pr_basic_info pr   ON pr.pr_basic_sno = p.pr_basic_sno
    WHERE g.status <> 'GRN Done'
      AND (@gate_entry_no IS NULL OR g.gate_entry_no = @gate_entry_no)
    ORDER BY g.gate_entry_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_CreateGRN
-- @jsonInput: { gate_entry_sno, po_basic_sno, vendor_sno, received_date,
--               doc_ref_no, vehicle_no, challan_no, remarks, created_by,
--               items: [{ po_item_sno, prod_sno, prod_name, specification,
--                         ordered_qty, received_qty, rejected_qty,
--                         unit_name, condition, remarks }] }
-- Returns the created GRN header row (grn_basic_sno, grn_no, ...).
-- Does NOT flip the gate entry's status — the caller (grn.service.js) does
-- that via sp_nt_UpdateGateEntryStatus after this succeeds.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateGRN', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateGRN;
GO

CREATE PROCEDURE dbo.sp_nt_CreateGRN
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @gate_entry_sno INT           = JSON_VALUE(@jsonInput, '$.gate_entry_sno');
    DECLARE @po_basic_sno   INT           = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @vendor_sno     INT           = JSON_VALUE(@jsonInput, '$.vendor_sno');
    DECLARE @received_date  DATE          = JSON_VALUE(@jsonInput, '$.received_date');
    DECLARE @doc_ref_no     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.doc_ref_no');
    DECLARE @vehicle_no     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.vehicle_no');
    DECLARE @challan_no     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.challan_no');
    DECLARE @remarks        VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @created_by     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @items          NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.items');

    IF @gate_entry_sno IS NULL OR @po_basic_sno IS NULL OR @received_date IS NULL
    BEGIN
        RAISERROR('gate_entry_sno, po_basic_sno and received_date are required.', 16, 1);
        RETURN;
    END

    IF @items IS NULL OR NOT EXISTS (SELECT 1 FROM OPENJSON(@items))
    BEGIN
        RAISERROR('At least one item is required.', 16, 1);
        RETURN;
    END

    DECLARE @grn_basic_sno INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
        DECLARE @seq  INT;

        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(grn_no, 6) AS INT)), 0) + 1
        FROM dbo.nt_grn_basic_info
        WHERE grn_no LIKE 'GRN-' + @year + '-%';

        DECLARE @grn_no VARCHAR(30) = 'GRN-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        INSERT INTO dbo.nt_grn_basic_info (
            grn_no, gate_entry_sno, po_basic_sno, vendor_sno, received_date,
            doc_ref_no, vehicle_no, challan_no, remarks, status, created_by, created_at
        )
        VALUES (
            @grn_no, @gate_entry_sno, @po_basic_sno, @vendor_sno, @received_date,
            @doc_ref_no, @vehicle_no, @challan_no, @remarks, 'Received', @created_by, GETDATE()
        );

        SET @grn_basic_sno = SCOPE_IDENTITY();

        INSERT INTO dbo.nt_grn_item_details (
            grn_basic_sno, po_item_sno, prod_sno, prod_name, specification,
            ordered_qty, received_qty, rejected_qty, unit_name, condition, remarks
        )
        SELECT
            @grn_basic_sno,
            j.po_item_sno,
            j.prod_sno,
            j.prod_name,
            j.specification,
            j.ordered_qty,
            j.received_qty,
            ISNULL(j.rejected_qty, 0),
            j.unit_name,
            ISNULL(j.condition, 'Good'),
            j.remarks
        FROM OPENJSON(@items)
        WITH (
            po_item_sno   INT           '$.po_item_sno',
            prod_sno      INT           '$.prod_sno',
            prod_name     VARCHAR(255)  '$.prod_name',
            specification VARCHAR(500)  '$.specification',
            ordered_qty   DECIMAL(18,2) '$.ordered_qty',
            received_qty  DECIMAL(18,2) '$.received_qty',
            rejected_qty  DECIMAL(18,2) '$.rejected_qty',
            unit_name     VARCHAR(50)   '$.unit_name',
            condition     VARCHAR(20)   '$.condition',
            remarks       VARCHAR(500)  '$.remarks'
        ) j;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT
        b.grn_basic_sno,
        b.grn_no,
        b.gate_entry_sno,
        b.po_basic_sno,
        b.vendor_sno,
        CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        CONVERT(VARCHAR(30), b.created_at, 120) AS created_at
    FROM dbo.nt_grn_basic_info b
    WHERE b.grn_basic_sno = @grn_basic_sno;
END;
GO

-- ============================================================
-- sp_nt_GetGRNsByPO
-- @jsonInput: { po_basic_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetGRNsByPO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetGRNsByPO;
GO

CREATE PROCEDURE dbo.sp_nt_GetGRNsByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    SELECT
        b.grn_basic_sno,
        b.grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                 AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)  AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.created_by                                AS received_by,
        b.created_by                                AS received_by_name,
        CONVERT(VARCHAR(30), b.created_at, 120)      AS created_at,
        (
            SELECT
                gi.grn_item_sno,
                gi.po_item_sno,
                gi.prod_sno,
                gi.prod_name,
                gi.specification,
                gi.ordered_qty,
                gi.received_qty,
                gi.rejected_qty,
                gi.unit_name,
                gi.condition,
                gi.remarks
            FROM dbo.nt_grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
            FOR JSON PATH
        )                                            AS items
    FROM dbo.nt_grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge   ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.po_basic_sno = @po_basic_sno
    ORDER BY b.grn_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetAllGRNs
-- @jsonInput optional: { status }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetAllGRNs', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAllGRNs;
GO

CREATE PROCEDURE dbo.sp_nt_GetAllGRNs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status VARCHAR(20) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @status = JSON_VALUE(@jsonInput, '$.status');

    SELECT
        b.grn_basic_sno,
        b.grn_no,
        b.gate_entry_sno,
        ge.gate_entry_no,
        b.po_basic_sno,
        p.po_df_no                                 AS po_no,
        b.vendor_sno,
        k.company_name                              AS vendor_name,
        CONVERT(VARCHAR(10), b.received_date, 120)  AS received_date,
        b.doc_ref_no,
        b.vehicle_no,
        b.challan_no,
        b.remarks,
        b.status,
        b.created_by                                AS received_by_name,
        CONVERT(VARCHAR(30), b.created_at, 120)      AS created_at,
        (
            SELECT
                gi.grn_item_sno,
                gi.po_item_sno,
                gi.prod_sno,
                gi.prod_name,
                gi.specification,
                gi.ordered_qty,
                gi.received_qty,
                gi.rejected_qty,
                gi.unit_name,
                gi.condition,
                gi.remarks
            FROM dbo.nt_grn_item_details gi
            WHERE gi.grn_basic_sno = b.grn_basic_sno
            FOR JSON PATH
        )                                            AS items
    FROM dbo.nt_grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge   ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE (@status IS NULL OR b.status = @status)
    ORDER BY b.grn_basic_sno DESC;
END;
GO
