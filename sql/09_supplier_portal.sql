-- ============================================================
-- Supplier Portal module — tables + stored procedures
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/supplier (port 8084, mounted at /api/supplier)
--
-- Live-DB status (2026-07-27):
--   - nt_supplier_login + sp_nt_CreateSupplierLogin / sp_nt_SupplierLoginByCode /
--     sp_nt_SetSupplierPassword are ALREADY APPLIED (see sp_nt_SupplierLoginByCode
--     below — this replaced the email-based sp_nt_SupplierLoginByEmail originally
--     drafted here). Re-running those CREATE TABLE/PROCEDURE statements is a
--     no-op / safe re-deploy.
--   - Everything else in this file (supplier_ack_* columns, PO-for-supplier
--     procs, dispatch tables + procs) is NEW as of 2026-07-27 and must be
--     applied.
--
-- All procedures follow this codebase's convention: a single optional
-- @jsonInput NVARCHAR(MAX) parameter, fields read via JSON_VALUE (or
-- OPENJSON for array fields). This matches
-- grn-service/src/supplier/supplier.repository.js, which always calls
-- procedures with one JSON-serialised parameters object (or none).
-- ============================================================

-- ── Tables ────────────────────────────────────────────────────────────────

IF OBJECT_ID('dbo.nt_supplier_login', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_supplier_login (
        supplier_login_sno   INT IDENTITY(1,1) PRIMARY KEY,
        kyc_basic_info_sno   INT           NOT NULL UNIQUE,
        login_email          VARCHAR(255)  NOT NULL UNIQUE,
        password_hash        VARCHAR(255)  NOT NULL,
        must_reset_password  CHAR(1)       NOT NULL DEFAULT 'Y',
        is_active             CHAR(1)       NOT NULL DEFAULT 'Y',
        last_login_at         DATETIME      NULL,
        created_by            VARCHAR(50)   NULL,
        created_at            DATETIME      NOT NULL DEFAULT GETDATE()
    );
END
GO

-- Dispatch header — one row per dispatch action a supplier performs on a PO.
-- Every dispatch can cover several physical shipments (multiple LRs), each
-- captured as its own row in nt_dispatch_slip_delivery below.
IF OBJECT_ID('dbo.nt_dispatch_slip', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_dispatch_slip (
        dispatch_slip_sno   INT IDENTITY(1,1) PRIMARY KEY,
        dispatch_slip_no    VARCHAR(30)   NOT NULL UNIQUE,
        po_basic_sno         INT           NOT NULL,
        kyc_basic_info_sno   INT           NOT NULL,
        transport_name        VARCHAR(255)  NULL,
        status                VARCHAR(20)   NOT NULL DEFAULT 'Dispatched',
        created_at            DATETIME      NOT NULL DEFAULT GETDATE()
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_dispatch_slip_po_basic_sno' AND object_id = OBJECT_ID('dbo.nt_dispatch_slip'))
    CREATE INDEX IX_nt_dispatch_slip_po_basic_sno ON dbo.nt_dispatch_slip (po_basic_sno);
GO

-- Dispatch delivery detail — one row per LR/shipment within a dispatch.
-- "qty" is the quantity dispatched in this shipment (the "how many" the
-- supplier enters against ordered qty on the PO); pieces/bundles describe
-- the physical packing so gate/GRN staff can tally against the LR.
IF OBJECT_ID('dbo.nt_dispatch_slip_delivery', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_dispatch_slip_delivery (
        delivery_sno        INT IDENTITY(1,1) PRIMARY KEY,
        dispatch_slip_sno   INT           NOT NULL,
        lr_no                VARCHAR(100)  NOT NULL,
        invoice_no           VARCHAR(100)  NOT NULL,
        invoice_date         DATE          NOT NULL,
        qty                  DECIMAL(18,2) NULL,
        pieces                INT           NULL,
        bundles               INT           NULL,
        created_at            DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_nt_dispatch_slip_delivery_slip
            FOREIGN KEY (dispatch_slip_sno) REFERENCES dbo.nt_dispatch_slip (dispatch_slip_sno)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_dispatch_slip_delivery_slip_sno' AND object_id = OBJECT_ID('dbo.nt_dispatch_slip_delivery'))
    CREATE INDEX IX_nt_dispatch_slip_delivery_slip_sno ON dbo.nt_dispatch_slip_delivery (dispatch_slip_sno);
GO

-- ── po_request_info: supplier-acknowledgement columns ──────────────────────

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'supplier_ack_status')
    ALTER TABLE dbo.po_request_info ADD supplier_ack_status VARCHAR(20) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.po_request_info') AND name = 'supplier_ack_date')
    ALTER TABLE dbo.po_request_info ADD supplier_ack_date DATETIME NULL;
GO

-- ============================================================
-- sp_nt_SupplierLoginByCode
-- @jsonInput: { supp_code }
-- Returns the login row + joined kyc_basic_info for the auth flow to
-- verify the password against and build the JWT. Login is by supplier
-- code, not email (login_email remains a contact field only).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_SupplierLoginByCode', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_SupplierLoginByCode;
GO

CREATE PROCEDURE dbo.sp_nt_SupplierLoginByCode
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @supp_code VARCHAR(50) = JSON_VALUE(@jsonInput, '$.supp_code');

    SELECT
        l.supplier_login_sno,
        l.kyc_basic_info_sno,
        l.login_email,
        l.password_hash,
        l.must_reset_password,
        l.is_active,
        k.company_name,
        k.supp_code,
        k.email
    FROM dbo.nt_supplier_login l
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = l.kyc_basic_info_sno
    WHERE k.supp_code = @supp_code;
END;
GO

-- ============================================================
-- sp_nt_CreateSupplierLogin
-- @jsonInput: { kyc_basic_info_sno, login_email, password_hash, created_by }
-- Creates the login row if it doesn't exist yet; if it does (re-invite),
-- resets the email/password/must_reset_password on the existing row.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateSupplierLogin', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateSupplierLogin;
GO

CREATE PROCEDURE dbo.sp_nt_CreateSupplierLogin
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT          = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @login_email        VARCHAR(255) = JSON_VALUE(@jsonInput, '$.login_email');
    DECLARE @password_hash      VARCHAR(255) = JSON_VALUE(@jsonInput, '$.password_hash');
    DECLARE @created_by         VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.created_by');

    IF @kyc_basic_info_sno IS NULL OR @login_email IS NULL OR @password_hash IS NULL
    BEGIN
        RAISERROR('kyc_basic_info_sno, login_email and password_hash are required.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.nt_supplier_login WHERE kyc_basic_info_sno = @kyc_basic_info_sno)
    BEGIN
        UPDATE dbo.nt_supplier_login
        SET login_email = @login_email,
            password_hash = @password_hash,
            must_reset_password = 'Y',
            is_active = 'Y',
            created_by = @created_by
        WHERE kyc_basic_info_sno = @kyc_basic_info_sno;
    END
    ELSE
    BEGIN
        INSERT INTO dbo.nt_supplier_login (
            kyc_basic_info_sno, login_email, password_hash, must_reset_password, is_active, created_by, created_at
        )
        VALUES (
            @kyc_basic_info_sno, @login_email, @password_hash, 'Y', 'Y', @created_by, GETDATE()
        );
    END

    SELECT supplier_login_sno, kyc_basic_info_sno, login_email, must_reset_password
    FROM dbo.nt_supplier_login
    WHERE kyc_basic_info_sno = @kyc_basic_info_sno;
END;
GO

-- ============================================================
-- sp_nt_SetSupplierPassword
-- @jsonInput: { kyc_basic_info_sno, password_hash }
-- Used by the forced first-login reset; clears must_reset_password.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_SetSupplierPassword', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_SetSupplierPassword;
GO

CREATE PROCEDURE dbo.sp_nt_SetSupplierPassword
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT          = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @password_hash      VARCHAR(255) = JSON_VALUE(@jsonInput, '$.password_hash');

    UPDATE dbo.nt_supplier_login
    SET password_hash = @password_hash,
        must_reset_password = 'N'
    WHERE kyc_basic_info_sno = @kyc_basic_info_sno;

    SELECT supplier_login_sno, kyc_basic_info_sno, must_reset_password
    FROM dbo.nt_supplier_login
    WHERE kyc_basic_info_sno = @kyc_basic_info_sno;
END;
GO

-- ============================================================
-- sp_nt_GetPOsForSupplier
-- @jsonInput: { kyc_basic_info_sno }
-- POs issued to this supplier, one row per PO.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPOsForSupplier', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPOsForSupplier;
GO

CREATE PROCEDURE dbo.sp_nt_GetPOsForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');

    SELECT
        p.po_basic_sno,
        p.po_df_no                              AS po_no,
        CONVERT(VARCHAR(10), p.po_date, 120)     AS po_date,
        CONVERT(VARCHAR(10), p.required_date,120) AS required_date,
        p.delivery_address,
        p.status,
        p.supplier_ack_status,
        CONVERT(VARCHAR(30), p.supplier_ack_date, 120) AS supplier_ack_date,
        c.com_name                              AS com_name,
        (
            SELECT COUNT(*)
            FROM dbo.nt_dispatch_slip d
            WHERE d.po_basic_sno = p.po_basic_sno
        )                                        AS dispatch_count
    FROM dbo.po_request_info p
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    WHERE p.is_active = 'Y'
      AND p.vendor_sno = @kyc_basic_info_sno
    ORDER BY p.po_basic_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_GetPODetailForSupplier
-- @jsonInput: { kyc_basic_info_sno, po_basic_sno }
-- Ownership-checked: only returns a row if the PO belongs to this supplier.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetPODetailForSupplier', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPODetailForSupplier;
GO

CREATE PROCEDURE dbo.sp_nt_GetPODetailForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @po_basic_sno       INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    SELECT
        p.po_basic_sno,
        p.po_df_no                              AS po_no,
        CONVERT(VARCHAR(10), p.po_date, 120)     AS po_date,
        CONVERT(VARCHAR(10), p.required_date,120) AS required_date,
        p.delivery_address,
        p.terms_conditions,
        p.purpose,
        p.status,
        p.supplier_ack_status,
        CONVERT(VARCHAR(30), p.supplier_ack_date, 120) AS supplier_ack_date,
        c.com_name                              AS com_name,
        k.company_name                          AS vendor_name,
        (
            SELECT
                i.po_item_sno,
                i.prod_sno,
                i.prod_name,
                i.specification,
                i.qty            AS ordered_qty,
                i.unit_name      AS unit_name,
                i.agreed_unit_price AS unit_price,
                i.net_cost       AS total_amount
            FROM dbo.po_item_details i
            WHERE i.po_basic_sno = p.po_basic_sno
              AND i.is_active = 'Y'
            FOR JSON PATH
        )                                        AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.company_master c   ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = p.vendor_sno
    WHERE p.is_active = 'Y'
      AND p.po_basic_sno = @po_basic_sno
      AND p.vendor_sno = @kyc_basic_info_sno;
END;
GO

-- ============================================================
-- sp_nt_AcceptPO
-- @jsonInput: { kyc_basic_info_sno, po_basic_sno }
-- Ownership-checked. Sets supplier_ack_status='Accepted' and logs a
-- po_history_data row (reusing the existing PO audit-trail table).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_AcceptPO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_AcceptPO;
GO

CREATE PROCEDURE dbo.sp_nt_AcceptPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @po_basic_sno       INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    IF NOT EXISTS (
        SELECT 1 FROM dbo.po_request_info
        WHERE po_basic_sno = @po_basic_sno AND vendor_sno = @kyc_basic_info_sno AND is_active = 'Y'
    )
    BEGIN
        RAISERROR('PO not found for this supplier.', 16, 1);
        RETURN;
    END

    UPDATE dbo.po_request_info
    SET supplier_ack_status = 'Accepted',
        supplier_ack_date = GETDATE()
    WHERE po_basic_sno = @po_basic_sno;

    INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
    VALUES (@po_basic_sno, 'SUPPLIER_ACK', CAST(@kyc_basic_info_sno AS VARCHAR(50)), 'PO accepted by supplier', 'Y');

    SELECT po_basic_sno, supplier_ack_status,
           CONVERT(VARCHAR(30), supplier_ack_date, 120) AS supplier_ack_date
    FROM dbo.po_request_info
    WHERE po_basic_sno = @po_basic_sno;
END;
GO

-- ============================================================
-- sp_nt_CreateDispatchSlip
-- @jsonInput: {
--   po_basic_sno, kyc_basic_info_sno, transport_name,
--   deliveries: [ { lr_no, invoice_no, invoice_date, qty, pieces, bundles }, ... ]
-- }
-- Ownership-checked; requires the PO to already be Accepted. Creates one
-- dispatch header row plus one nt_dispatch_slip_delivery row per entry in
-- the deliveries array (a single dispatch can cover several LRs/shipments).
-- Returns the header, then one row per created delivery (delivery_sno +
-- lr_no) so the caller can offer a "print" action per delivery.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateDispatchSlip', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateDispatchSlip;
GO

CREATE PROCEDURE dbo.sp_nt_CreateDispatchSlip
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno       INT           = JSON_VALUE(@jsonInput, '$.po_basic_sno');
    DECLARE @kyc_basic_info_sno INT           = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @transport_name     VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.transport_name');

    IF @po_basic_sno IS NULL OR @kyc_basic_info_sno IS NULL
    BEGIN
        RAISERROR('po_basic_sno and kyc_basic_info_sno are required.', 16, 1);
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

    -- Parse + validate the deliveries array up front (SQL Server's OPENJSON
    -- silently skips malformed elements rather than erroring, so an empty
    -- result here means the caller sent no usable rows).
    DECLARE @deliveries TABLE (
        lr_no        VARCHAR(100),
        invoice_no   VARCHAR(100),
        invoice_date DATE,
        qty          DECIMAL(18,2),
        pieces       INT,
        bundles      INT
    );

    INSERT INTO @deliveries (lr_no, invoice_no, invoice_date, qty, pieces, bundles)
    SELECT lr_no, invoice_no, invoice_date, qty, pieces, bundles
    FROM OPENJSON(@jsonInput, '$.deliveries')
    WITH (
        lr_no        VARCHAR(100) '$.lr_no',
        invoice_no   VARCHAR(100) '$.invoice_no',
        invoice_date DATE         '$.invoice_date',
        qty          DECIMAL(18,2)'$.qty',
        pieces       INT          '$.pieces',
        bundles      INT          '$.bundles'
    );

    IF NOT EXISTS (SELECT 1 FROM @deliveries)
    BEGIN
        RAISERROR('At least one delivery (LR no. and invoice no.) is required.', 16, 1);
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM @deliveries WHERE lr_no IS NULL OR invoice_no IS NULL OR invoice_date IS NULL)
    BEGIN
        RAISERROR('Each delivery requires lr_no, invoice_no and invoice_date.', 16, 1);
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
        dispatch_slip_no, po_basic_sno, kyc_basic_info_sno, transport_name, status, created_at
    )
    VALUES (
        @dispatch_slip_no, @po_basic_sno, @kyc_basic_info_sno, @transport_name, 'Dispatched', GETDATE()
    );

    SET @dispatch_slip_sno = SCOPE_IDENTITY();

    INSERT INTO dbo.nt_dispatch_slip_delivery (
        dispatch_slip_sno, lr_no, invoice_no, invoice_date, qty, pieces, bundles, created_at
    )
    SELECT @dispatch_slip_sno, lr_no, invoice_no, invoice_date, qty, pieces, bundles, GETDATE()
    FROM @deliveries;

    SELECT dispatch_slip_sno, dispatch_slip_no, status
    FROM dbo.nt_dispatch_slip
    WHERE dispatch_slip_sno = @dispatch_slip_sno;

    SELECT delivery_sno, lr_no, invoice_no
    FROM dbo.nt_dispatch_slip_delivery
    WHERE dispatch_slip_sno = @dispatch_slip_sno
    ORDER BY delivery_sno;
END;
GO

-- ============================================================
-- sp_nt_GetDispatchSlip
-- @jsonInput: { dispatch_slip_sno, kyc_basic_info_sno }
-- Ownership-checked recap of a dispatch: header fields + the full list of
-- deliveries created under it (used by the post-save summary screen so the
-- supplier can jump into printing any one of them).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetDispatchSlip', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetDispatchSlip;
GO

CREATE PROCEDURE dbo.sp_nt_GetDispatchSlip
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
        d.transport_name,
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
                del.bundles
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
-- sp_nt_GetDispatchDelivery
-- @jsonInput: { delivery_sno, kyc_basic_info_sno }
-- Ownership-checked. Returns everything the printable slip needs for ONE
-- delivery row: its own LR/invoice/qty/pieces/bundles, the PO no, the
-- supplier's "from" address (primary kyc_address_info row), and the PO's
-- delivery ("to") address. One printable paper is generated per delivery.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetDispatchDelivery', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetDispatchDelivery;
GO

CREATE PROCEDURE dbo.sp_nt_GetDispatchDelivery
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
        d.dispatch_slip_sno,
        d.dispatch_slip_no,
        d.transport_name,
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
