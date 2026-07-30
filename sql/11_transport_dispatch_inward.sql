-- ============================================================
-- Transporter master + dispatch transport/Direct mode + invoice upload
-- + staff LR lookup for Gate Entry QR scan + pending-inward list.
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : backend/src/Masters (TransportMaster), grn-service/src/supplier,
--            grn-service/src/gateentry
--
-- Apply with:  cd backend && node sql/run_sql.mjs ../grn-service/sql/11_transport_dispatch_inward.sql
-- Everything is guarded / CREATE OR ALTER — safe to re-run.
--
-- All procedures follow the codebase convention: a single optional
-- @jsonInput NVARCHAR(MAX) parameter, fields read via JSON_VALUE
-- (OPENJSON for arrays).
-- ============================================================

-- ── nt_transport_master ───────────────────────────────────────────────────

IF OBJECT_ID('dbo.nt_transport_master', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_transport_master (
        transport_sno    INT IDENTITY(1,1) PRIMARY KEY,
        transport_code   VARCHAR(50)   NULL,
        transport_name   VARCHAR(255)  NOT NULL,
        contact_person   VARCHAR(100)  NULL,
        phone_no         VARCHAR(20)   NULL,
        gst_no           VARCHAR(20)   NULL,
        address          VARCHAR(500)  NULL,
        is_active        CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by       VARCHAR(50)   NULL,
        created_date     DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by      VARCHAR(50)   NULL,
        modified_date    DATETIME      NULL
    );
END
GO

-- ── nt_dispatch_slip: transport linkage + dispatch mode ───────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.nt_dispatch_slip') AND name = 'transport_sno')
    ALTER TABLE dbo.nt_dispatch_slip ADD transport_sno INT NULL;
GO

-- 'Transport' = shipped via a transporter (LR compulsory);
-- 'Direct'    = supplier delivers directly (LR optional, qty/pieces/bundles compulsory)
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.nt_dispatch_slip') AND name = 'dispatch_mode')
    ALTER TABLE dbo.nt_dispatch_slip ADD dispatch_mode VARCHAR(10) NOT NULL CONSTRAINT DF_nt_dispatch_slip_mode DEFAULT 'Transport';
GO

-- ── nt_dispatch_slip_delivery: LR optional (Direct mode) + invoice copy ───

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.nt_dispatch_slip_delivery') AND name = 'lr_no' AND is_nullable = 0
)
    ALTER TABLE dbo.nt_dispatch_slip_delivery ALTER COLUMN lr_no VARCHAR(100) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.nt_dispatch_slip_delivery') AND name = 'invoice_file_url')
    ALTER TABLE dbo.nt_dispatch_slip_delivery ADD invoice_file_url VARCHAR(500) NULL;
GO

-- ============================================================
-- Transporter master procedures (generic-master engine contract:
-- backend/src/Masters/Repository/CommonMasterRepo.js)
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTransportRecords
AS
BEGIN
    SET NOCOUNT ON;

    SELECT transport_sno, transport_code, transport_name, contact_person,
           phone_no, gst_no, address, is_active,
           created_by, CONVERT(VARCHAR(30), created_date, 120) AS created_date
    FROM dbo.nt_transport_master
    WHERE is_active = 'Y'
    ORDER BY transport_name;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateTransportRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @transport_name VARCHAR(255) = JSON_VALUE(@jsonInput, '$.transport_name');
    DECLARE @transport_code VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.transport_code');

    IF @transport_name IS NULL OR LTRIM(RTRIM(@transport_name)) = ''
    BEGIN
        RAISERROR('transport_name is required.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.nt_transport_master WHERE transport_name = @transport_name AND is_active = 'Y')
    BEGIN
        RAISERROR('A transporter with this name already exists.', 16, 1);
        RETURN;
    END

    IF @transport_code IS NULL OR LTRIM(RTRIM(@transport_code)) = ''
        SET @transport_code = 'TRN-' + RIGHT('0000' + CAST(
            (SELECT ISNULL(MAX(transport_sno), 0) + 1 FROM dbo.nt_transport_master) AS VARCHAR(4)), 4);

    INSERT INTO dbo.nt_transport_master (
        transport_code, transport_name, contact_person, phone_no, gst_no, address, is_active, created_by
    )
    VALUES (
        @transport_code,
        @transport_name,
        JSON_VALUE(@jsonInput, '$.contact_person'),
        JSON_VALUE(@jsonInput, '$.phone_no'),
        JSON_VALUE(@jsonInput, '$.gst_no'),
        JSON_VALUE(@jsonInput, '$.address'),
        'Y',
        JSON_VALUE(@jsonInput, '$.created_by')
    );

    SELECT transport_sno, transport_code, transport_name, contact_person,
           phone_no, gst_no, address, is_active
    FROM dbo.nt_transport_master
    WHERE transport_sno = SCOPE_IDENTITY();
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_UpdateTransportRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);
    IF @id IS NULL SET @id = TRY_CAST(JSON_VALUE(@jsonInput, '$.transport_sno') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.nt_transport_master WHERE transport_sno = @id)
    BEGIN
        RAISERROR('Transporter not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_transport_master
    SET transport_code = ISNULL(JSON_VALUE(@jsonInput, '$.transport_code'), transport_code),
        transport_name = ISNULL(JSON_VALUE(@jsonInput, '$.transport_name'), transport_name),
        contact_person = ISNULL(JSON_VALUE(@jsonInput, '$.contact_person'), contact_person),
        phone_no       = ISNULL(JSON_VALUE(@jsonInput, '$.phone_no'),       phone_no),
        gst_no         = ISNULL(JSON_VALUE(@jsonInput, '$.gst_no'),         gst_no),
        address        = ISNULL(JSON_VALUE(@jsonInput, '$.address'),        address),
        is_active      = ISNULL(JSON_VALUE(@jsonInput, '$.is_active'),      is_active),
        modified_by    = JSON_VALUE(@jsonInput, '$.modified_by'),
        modified_date  = GETDATE()
    WHERE transport_sno = @id;

    SELECT transport_sno, transport_code, transport_name, contact_person,
           phone_no, gst_no, address, is_active
    FROM dbo.nt_transport_master
    WHERE transport_sno = @id;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_DeleteTransportRecords
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.id') AS INT);

    IF @id IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.nt_transport_master WHERE transport_sno = @id)
    BEGIN
        RAISERROR('Transporter not found.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_transport_master
    SET is_active = 'N', modified_date = GETDATE()
    WHERE transport_sno = @id;

    SELECT @id AS transport_sno, 'N' AS is_active, 'SUCCESS' AS status;
END;
GO

-- ============================================================
-- sp_nt_CreateDispatchSlip (REPLACED)
-- @jsonInput: {
--   po_basic_sno, kyc_basic_info_sno,
--   dispatch_mode ('Transport' | 'Direct'), transport_sno, transport_name,
--   deliveries: [ { lr_no, invoice_no, invoice_date, qty, pieces, bundles,
--                   invoice_file_url }, ... ]
-- }
-- Mode rules:
--   Transport : a transporter (sno or name) is required and every delivery
--               must carry an lr_no.
--   Direct    : lr_no optional, but qty, pieces and bundles are compulsory
--               per delivery.
-- invoice_no + invoice_date stay compulsory in both modes.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateDispatchSlip
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno       INT           = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @kyc_basic_info_sno INT           = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @transport_sno      INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.transport_sno') AS INT);
    DECLARE @transport_name     VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.transport_name');
    DECLARE @dispatch_mode      VARCHAR(10)   = ISNULL(JSON_VALUE(@jsonInput, '$.dispatch_mode'), 'Transport');

    IF @po_basic_sno IS NULL OR @kyc_basic_info_sno IS NULL
    BEGIN
        RAISERROR('po_basic_sno and kyc_basic_info_sno are required.', 16, 1);
        RETURN;
    END

    IF @dispatch_mode NOT IN ('Transport', 'Direct')
    BEGIN
        RAISERROR('dispatch_mode must be Transport or Direct.', 16, 1);
        RETURN;
    END

    IF NOT EXISTS (
        SELECT 1 FROM dbo.po_request_info
        WHERE po_basic_sno = @po_basic_sno
          AND vendor_sno = @kyc_basic_info_sno
          AND is_active = 'Y'
          AND supplier_ack_status = 'Accepted'
    )
    BEGIN
        RAISERROR('PO must be accepted by this supplier before it can be dispatched.', 16, 1);
        RETURN;
    END

    -- Resolve the transporter from the master when an sno is supplied.
    IF @transport_sno IS NOT NULL
    BEGIN
        SELECT @transport_name = transport_name
        FROM dbo.nt_transport_master
        WHERE transport_sno = @transport_sno AND is_active = 'Y';

        IF @transport_name IS NULL
        BEGIN
            RAISERROR('Selected transporter was not found in the transporter master.', 16, 1);
            RETURN;
        END
    END

    IF @dispatch_mode = 'Transport' AND @transport_name IS NULL
    BEGIN
        RAISERROR('A transporter is required unless the dispatch is Direct.', 16, 1);
        RETURN;
    END

    IF @dispatch_mode = 'Direct'
        SET @transport_name = ISNULL(@transport_name, 'Direct / Self Delivery');

    DECLARE @deliveries TABLE (
        lr_no            VARCHAR(100),
        invoice_no       VARCHAR(100),
        invoice_date     DATE,
        qty              DECIMAL(18,2),
        pieces           INT,
        bundles          INT,
        invoice_file_url VARCHAR(500)
    );

    INSERT INTO @deliveries (lr_no, invoice_no, invoice_date, qty, pieces, bundles, invoice_file_url)
    SELECT NULLIF(LTRIM(RTRIM(lr_no)), ''), invoice_no, invoice_date, qty, pieces, bundles, invoice_file_url
    FROM OPENJSON(@jsonInput, '$.deliveries')
    WITH (
        lr_no            VARCHAR(100) '$.lr_no',
        invoice_no       VARCHAR(100) '$.invoice_no',
        invoice_date     DATE         '$.invoice_date',
        qty              DECIMAL(18,2)'$.qty',
        pieces           INT          '$.pieces',
        bundles          INT          '$.bundles',
        invoice_file_url VARCHAR(500) '$.invoice_file_url'
    );

    IF NOT EXISTS (SELECT 1 FROM @deliveries)
    BEGIN
        RAISERROR('At least one delivery is required.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @deliveries WHERE invoice_no IS NULL OR invoice_date IS NULL)
    BEGIN
        RAISERROR('Each delivery requires invoice_no and invoice_date.', 16, 1);
        RETURN;
    END

    IF @dispatch_mode = 'Transport' AND EXISTS (SELECT 1 FROM @deliveries WHERE lr_no IS NULL)
    BEGIN
        RAISERROR('Each delivery requires an LR no. when dispatching via a transporter.', 16, 1);
        RETURN;
    END

    IF @dispatch_mode = 'Direct' AND EXISTS (
        SELECT 1 FROM @deliveries WHERE qty IS NULL OR pieces IS NULL OR bundles IS NULL
    )
    BEGIN
        RAISERROR('Direct dispatch requires qty, pieces and bundles on every delivery.', 16, 1);
        RETURN;
    END

    DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
    DECLARE @seq  INT;

    SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(dispatch_slip_no, 6) AS INT)), 0) + 1
    FROM dbo.nt_dispatch_slip
    WHERE dispatch_slip_no LIKE 'DS-' + @year + '-%';

    DECLARE @dispatch_slip_no VARCHAR(30) = 'DS-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);
    DECLARE @dispatch_slip_sno INT;

    INSERT INTO dbo.nt_dispatch_slip (
        dispatch_slip_no, po_basic_sno, kyc_basic_info_sno,
        transport_sno, transport_name, dispatch_mode, status, created_at
    )
    VALUES (
        @dispatch_slip_no, @po_basic_sno, @kyc_basic_info_sno,
        @transport_sno, @transport_name, @dispatch_mode, 'Dispatched', GETDATE()
    );

    SET @dispatch_slip_sno = SCOPE_IDENTITY();

    INSERT INTO dbo.nt_dispatch_slip_delivery (
        dispatch_slip_sno, lr_no, invoice_no, invoice_date, qty, pieces, bundles, invoice_file_url, created_at
    )
    SELECT @dispatch_slip_sno, lr_no, invoice_no, invoice_date, qty, pieces, bundles, invoice_file_url, GETDATE()
    FROM @deliveries;

    SELECT dispatch_slip_sno, dispatch_slip_no, dispatch_mode, transport_sno, transport_name, status
    FROM dbo.nt_dispatch_slip
    WHERE dispatch_slip_sno = @dispatch_slip_sno;

    SELECT delivery_sno, lr_no, invoice_no
    FROM dbo.nt_dispatch_slip_delivery
    WHERE dispatch_slip_sno = @dispatch_slip_sno
    ORDER BY delivery_sno;
END;
GO

-- ============================================================
-- sp_nt_GetDispatchSlip (REPLACED) — surfaces mode/transport/invoice file
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetDispatchSlip
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @dispatch_slip_sno  INT = JSON_VALUE(@jsonInput, '$.dispatch_slip_sno');
    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');

    SELECT
        d.dispatch_slip_sno,
        d.dispatch_slip_no,
        d.po_basic_sno,
        p.po_df_no          AS po_no,
        d.transport_sno,
        d.transport_name,
        d.dispatch_mode,
        d.status,
        CONVERT(VARCHAR(30), d.created_at, 120) AS created_at,
        (
            SELECT
                del.delivery_sno,
                del.lr_no,
                del.invoice_no,
                CONVERT(VARCHAR(10), del.invoice_date, 120) AS invoice_date,
                del.qty,
                del.pieces,
                del.bundles,
                del.invoice_file_url
            FROM dbo.nt_dispatch_slip_delivery del
            WHERE del.dispatch_slip_sno = d.dispatch_slip_sno
            ORDER BY del.delivery_sno
            FOR JSON PATH
        )                    AS deliveries
    FROM dbo.nt_dispatch_slip d
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = d.po_basic_sno
    WHERE d.dispatch_slip_sno = @dispatch_slip_sno
      AND d.kyc_basic_info_sno = @kyc_basic_info_sno;
END;
GO

-- ============================================================
-- sp_nt_GetDispatchDelivery (REPLACED) — adds mode/invoice file to the
-- printable-slip payload.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetDispatchDelivery
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @delivery_sno       INT = JSON_VALUE(@jsonInput, '$.delivery_sno');
    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');

    SELECT
        del.delivery_sno,
        del.lr_no,
        del.invoice_no,
        CONVERT(VARCHAR(10), del.invoice_date, 120) AS invoice_date,
        del.qty,
        del.pieces,
        del.bundles,
        del.invoice_file_url,
        d.dispatch_slip_sno,
        d.dispatch_slip_no,
        d.transport_sno,
        d.transport_name,
        d.dispatch_mode,
        d.po_basic_sno,
        p.po_df_no                               AS po_no,
        k.company_name                            AS supplier_name,
        addr.door_no                              AS from_door_no,
        addr.street                               AS from_street,
        addr.area                                 AS from_area,
        addr.city                                 AS from_city,
        addr.state                                AS from_state,
        addr.pincode                              AS from_pincode,
        p.delivery_address                        AS to_address
    FROM dbo.nt_dispatch_slip_delivery del
    JOIN dbo.nt_dispatch_slip d       ON d.dispatch_slip_sno = del.dispatch_slip_sno
    LEFT JOIN dbo.po_request_info p  ON p.po_basic_sno = d.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = d.kyc_basic_info_sno
    OUTER APPLY (
        SELECT TOP 1 a.door_no, a.street, a.area, a.city, a.state, a.pincode
        FROM dbo.kyc_address_info a
        WHERE a.kyc_basic_info_sno = d.kyc_basic_info_sno
          AND a.is_active = 'Y'
        ORDER BY CASE WHEN a.is_primary = 'Y' THEN 0 ELSE 1 END, a.kyc_address_sno
    ) addr
    WHERE del.delivery_sno = @delivery_sno
      AND d.kyc_basic_info_sno = @kyc_basic_info_sno;
END;
GO

-- ============================================================
-- sp_nt_GetDispatchDeliveryByLr  (NEW — staff-side, no supplier ownership
-- check; called by Gate Entry when a dispatch-slip QR is scanned or an LR
-- no is keyed in.)
-- @jsonInput: { lr_code }
--   lr_code is either the LR number, or the 'DSD-<delivery_sno>' fallback
--   code printed on Direct-dispatch slips that have no LR.
-- Returns everything Gate Entry needs to prefill its form. Newest match
-- wins if the same LR number appears on more than one delivery.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetDispatchDeliveryByLr
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @lr_code VARCHAR(100) = LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.lr_code')));
    DECLARE @delivery_sno INT = NULL;

    IF @lr_code IS NULL OR @lr_code = ''
    BEGIN
        RAISERROR('lr_code is required.', 16, 1);
        RETURN;
    END

    IF @lr_code LIKE 'DSD-%'
        SET @delivery_sno = TRY_CAST(SUBSTRING(@lr_code, 5, 20) AS INT);

    SELECT TOP 1
        del.delivery_sno,
        del.lr_no,
        del.invoice_no,
        CONVERT(VARCHAR(10), del.invoice_date, 120) AS invoice_date,
        del.qty,
        del.pieces,
        del.bundles,
        del.invoice_file_url,
        d.dispatch_slip_sno,
        d.dispatch_slip_no,
        d.transport_sno,
        d.transport_name,
        d.dispatch_mode,
        d.status                                  AS dispatch_status,
        CONVERT(VARCHAR(30), d.created_at, 120)    AS dispatched_at,
        d.po_basic_sno,
        p.po_df_no                                AS po_no,
        p.vendor_sno,
        k.company_name                             AS vendor_name
    FROM dbo.nt_dispatch_slip_delivery del
    JOIN dbo.nt_dispatch_slip d      ON d.dispatch_slip_sno = del.dispatch_slip_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = d.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = d.kyc_basic_info_sno
    WHERE (@delivery_sno IS NOT NULL AND del.delivery_sno = @delivery_sno)
       OR (@delivery_sno IS NULL AND del.lr_no = @lr_code)
    ORDER BY del.delivery_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetPendingInwardPOs  (NEW — "sidebar shows the PO till GRN
-- completes": every PO that has at least one dispatch but whose inward is
-- not finished, with a derived stage for the widget.)
--   Dispatched  : dispatched, nothing recorded at the gate yet
--   GRN Pending : gate entry exists but at least one is not 'GRN Done'
-- A PO drops off this list once every one of its gate entries is
-- 'GRN Done' (i.e. the GRN side is complete).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPendingInwardPOs
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.po_basic_sno,
        p.po_df_no                                 AS po_no,
        k.company_name                              AS vendor_name,
        ds.dispatch_count,
        CONVERT(VARCHAR(30), ds.last_dispatch_at, 120) AS last_dispatch_at,
        ISNULL(ge.gate_entry_count, 0)              AS gate_entry_count,
        ISNULL(ge.gate_open_count, 0)               AS gate_open_count,
        ISNULL(gr.grn_count, 0)                     AS grn_count,
        CASE
            WHEN ISNULL(ge.gate_entry_count, 0) = 0 THEN 'Dispatched'
            ELSE 'GRN Pending'
        END                                          AS stage
    FROM dbo.po_request_info p
    JOIN (
        SELECT po_basic_sno, COUNT(*) AS dispatch_count, MAX(created_at) AS last_dispatch_at
        FROM dbo.nt_dispatch_slip
        GROUP BY po_basic_sno
    ) ds ON ds.po_basic_sno = p.po_basic_sno
    LEFT JOIN (
        SELECT po_basic_sno,
               COUNT(*) AS gate_entry_count,
               SUM(CASE WHEN status <> 'GRN Done' THEN 1 ELSE 0 END) AS gate_open_count
        FROM dbo.nt_gate_entry
        GROUP BY po_basic_sno
    ) ge ON ge.po_basic_sno = p.po_basic_sno
    LEFT JOIN (
        SELECT po_basic_sno, COUNT(*) AS grn_count
        FROM dbo.grn_basic_info
        WHERE is_active = 'Y'
        GROUP BY po_basic_sno
    ) gr ON gr.po_basic_sno = p.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE p.is_active = 'Y'
      AND (ISNULL(ge.gate_entry_count, 0) = 0 OR ISNULL(ge.gate_open_count, 0) > 0)
    ORDER BY ds.last_dispatch_at DESC;
END;
GO
