-- ============================================================
-- Invoice — the first Invoice table in this codebase
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new grn-service/src/invoice module (port 8084, mounted at /api/invoice)
--
-- Why this is needed
-- ------------------
-- Recurring/composite invoice intake (Service_Procurement_Flow.pdf) and
-- composite invoice matching (Civil_Electrical_Transportation_Requisition_
-- Flow.pdf's INV-SCH-77410 worked example). invoice_allocation_details is
-- the SINGLE matching abstraction for every service type and for the
-- product/service split — even a plain Type-1 exact match gets exactly one
-- allocation row. This avoids a special-cased "simple" vs "composite"
-- matching code path.
--
-- Ratio computation (sp_nt_MatchInvoiceBucket), reproduces the PDF example
-- exactly:
--   MATERIAL bucket : ratio = SUM(grn received_qty - rejected_qty) / po_item.qty
--                     (GRN always carries a physical qty)
--   SERVICE bucket   : if po_item.qty is set (discrete count, e.g. "6 panels
--                      tested") -> ratio = SUM(service_entry billed_qty) / po_item.qty
--                      else (pure amount-based Type 1/2 recurring, no unit
--                      count) -> ratio = SUM(confirmed_amount) / SUM(po_amount)
--   hold_amount   = allocated_amount * (1 - ratio)
--   release_amount = allocated_amount - hold_amount
-- Worked check: Electrical PO, service bucket allocated Rs.1,06,200, 5 of 6
-- panels confirmed -> ratio 0.8333 -> hold ~Rs.17,700, release ~Rs.88,500;
-- material bucket 6 of 6 -> ratio 1.0 -> release Rs.5,66,400 in full;
-- invoice_info.net_payable rolls up to Rs.6,54,900. Matches the PDF exactly.
--
-- po_item_details.po_section is read to route each allocation to the right
-- bucket type; NULL po_section (pre-existing product-only POs, before the
-- Part B grouping patch stamps it) defaults to 'MATERIAL' so invoice
-- matching keeps working for the untouched product flow.
-- ============================================================

IF OBJECT_ID('dbo.invoice_info', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.invoice_info (
        invoice_sno       INT IDENTITY(1,1) PRIMARY KEY,
        invoice_no         VARCHAR(30)   NOT NULL UNIQUE,
        vendor_invoice_no  VARCHAR(50)   NULL,
        vendor_sno          INT           NULL,
        po_basic_sno         INT           NULL,   -- nullable: Type-3 pre-PO capture
        com_sno               INT           NULL,
        div_sno               INT           NULL,
        brn_sno               INT           NULL,
        dept_sno              INT           NULL,
        invoice_date          DATE          NULL,
        due_date              DATE          NULL,
        invoice_amount        DECIMAL(18,2) NOT NULL DEFAULT 0,
        invoice_file_url      NVARCHAR(500) NULL,
        invoice_type          VARCHAR(20)   NOT NULL DEFAULT 'MATERIAL',  -- SERVICE | MATERIAL | COMPOSITE
        source_type           VARCHAR(20)   NOT NULL DEFAULT 'STANDARD', -- STANDARD | RETROSPECTIVE
        match_status           VARCHAR(20)   NOT NULL DEFAULT 'Pending',  -- Pending | Allocated | Matched | PartialRelease | Rejected
        net_payable            DECIMAL(18,2) NULL,
        remarks                VARCHAR(500)  NULL,
        is_active               CHAR(1)       NOT NULL DEFAULT 'Y',
        created_by              VARCHAR(20)   NULL,
        created_date            DATETIME      NOT NULL DEFAULT GETDATE(),
        modified_by             VARCHAR(20)   NULL,
        modified_date           DATETIME      NULL,
        CONSTRAINT FK_invoice_info_po FOREIGN KEY (po_basic_sno) REFERENCES dbo.po_request_info (po_basic_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_invoice_info_po' AND object_id = OBJECT_ID('dbo.invoice_info'))
    CREATE INDEX IX_invoice_info_po ON dbo.invoice_info (po_basic_sno);
GO

IF OBJECT_ID('dbo.invoice_allocation_details', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.invoice_allocation_details (
        invoice_alloc_sno       INT IDENTITY(1,1) PRIMARY KEY,
        invoice_sno               INT           NOT NULL,
        po_item_sno                 INT           NOT NULL,
        bucket_type                  VARCHAR(10)   NOT NULL,  -- MATERIAL | SERVICE
        grn_item_sno                  INT           NULL,
        service_entry_item_sno         INT           NULL,
        allocated_amount               DECIMAL(18,2) NOT NULL DEFAULT 0,
        matched_qty_ratio               DECIMAL(9,6)  NULL,
        hold_amount                      DECIMAL(18,2) NOT NULL DEFAULT 0,
        release_amount                   DECIMAL(18,2) NOT NULL DEFAULT 0,
        match_status                      VARCHAR(20)   NOT NULL DEFAULT 'Pending',
        created_by                         VARCHAR(20)   NULL,
        created_date                       DATETIME      NOT NULL DEFAULT GETDATE(),
        is_active                           CHAR(1)       NOT NULL DEFAULT 'Y',
        CONSTRAINT FK_invoice_allocation_details_invoice
            FOREIGN KEY (invoice_sno) REFERENCES dbo.invoice_info (invoice_sno),
        CONSTRAINT FK_invoice_allocation_details_po_item
            FOREIGN KEY (po_item_sno) REFERENCES dbo.po_item_details (po_item_sno)
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_invoice_allocation_details_invoice' AND object_id = OBJECT_ID('dbo.invoice_allocation_details'))
    CREATE INDEX IX_invoice_allocation_details_invoice ON dbo.invoice_allocation_details (invoice_sno);
GO

-- pr_basic_info.source_invoice_sno (added nullable, no FK, in
-- 06_usp_InsertPurchaseRequest_v2.sql) can now get its FK constraint.
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_pr_basic_info_source_invoice'
)
    ALTER TABLE dbo.pr_basic_info
        ADD CONSTRAINT FK_pr_basic_info_source_invoice FOREIGN KEY (source_invoice_sno) REFERENCES dbo.invoice_info (invoice_sno);
GO

-- ============================================================
-- sp_nt_CreateInvoice
-- @jsonInput: { vendor_invoice_no, vendor_sno, po_basic_sno?, com_sno?,
--   div_sno?, brn_sno?, dept_sno?, invoice_date, due_date?, invoice_amount,
--   invoice_file_url?, invoice_type?, source_type?, remarks?, created_by }
-- File upload already happened in the controller (multer + ftpUploader,
-- mirroring grn-service/src/supplier/supplier.controller.js's pattern) — this
-- proc just persists the resulting URL.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateInvoice', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateInvoice;
GO
CREATE PROCEDURE dbo.sp_nt_CreateInvoice
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_invoice_no VARCHAR(50)  = JSON_VALUE(@jsonInput, '$.vendor_invoice_no');
    DECLARE @vendor_sno        INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @po_basic_sno      INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);
    DECLARE @com_sno           INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT);
    DECLARE @div_sno           INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT);
    DECLARE @brn_sno           INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT);
    DECLARE @dept_sno          INT          = TRY_CAST(JSON_VALUE(@jsonInput, '$.dept_sno') AS INT);
    DECLARE @invoice_date      DATE         = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_date') AS DATE);
    DECLARE @due_date          DATE         = TRY_CAST(JSON_VALUE(@jsonInput, '$.due_date') AS DATE);
    DECLARE @invoice_amount    DECIMAL(18,2)= TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_amount') AS DECIMAL(18,2));
    DECLARE @invoice_file_url  NVARCHAR(500)= JSON_VALUE(@jsonInput, '$.invoice_file_url');
    DECLARE @invoice_type      VARCHAR(20)  = ISNULL(JSON_VALUE(@jsonInput, '$.invoice_type'), 'MATERIAL');
    DECLARE @source_type       VARCHAR(20)  = ISNULL(JSON_VALUE(@jsonInput, '$.source_type'), 'STANDARD');
    DECLARE @remarks           VARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks');
    DECLARE @created_by        VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.created_by');

    IF @vendor_sno IS NULL OR @invoice_amount IS NULL OR @created_by IS NULL
    BEGIN
        RAISERROR('vendor_sno, invoice_amount and created_by are required.', 16, 1);
        RETURN;
    END

    IF @po_basic_sno IS NULL AND @source_type <> 'RETROSPECTIVE'
    BEGIN
        RAISERROR('po_basic_sno is required unless source_type is RETROSPECTIVE.', 16, 1);
        RETURN;
    END

    DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
    DECLARE @seq  INT;
    SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(invoice_no, 6) AS INT)), 0) + 1
    FROM dbo.invoice_info WITH (UPDLOCK, HOLDLOCK)
    WHERE invoice_no LIKE 'INV-' + @year + '-%';
    DECLARE @invoice_no VARCHAR(30) = 'INV-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

    INSERT INTO dbo.invoice_info (
        invoice_no, vendor_invoice_no, vendor_sno, po_basic_sno, com_sno, div_sno, brn_sno, dept_sno,
        invoice_date, due_date, invoice_amount, invoice_file_url, invoice_type, source_type,
        match_status, remarks, is_active, created_by, created_date
    )
    VALUES (
        @invoice_no, @vendor_invoice_no, @vendor_sno, @po_basic_sno, @com_sno, @div_sno, @brn_sno, @dept_sno,
        @invoice_date, @due_date, @invoice_amount, @invoice_file_url, @invoice_type, @source_type,
        'Pending', @remarks, 'Y', @created_by, GETDATE()
    );

    DECLARE @invoice_sno INT = SCOPE_IDENTITY();

    SELECT invoice_sno = @invoice_sno, invoice_no = @invoice_no, 'SUCCESS' AS result
    FROM dbo.invoice_info WHERE invoice_sno = @invoice_sno;
END;
GO

-- ============================================================
-- sp_nt_LinkInvoiceToPO — Type-3: backfill po_basic_sno once the call-off
-- PO is approved (the invoice was captured before any PO existed).
-- @jsonInput: { invoice_sno, po_basic_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_LinkInvoiceToPO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_LinkInvoiceToPO;
GO
CREATE PROCEDURE dbo.sp_nt_LinkInvoiceToPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @invoice_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
    DECLARE @po_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);

    IF @invoice_sno IS NULL OR @po_basic_sno IS NULL
    BEGIN
        RAISERROR('invoice_sno and po_basic_sno are required.', 16, 1);
        RETURN;
    END

    UPDATE dbo.invoice_info SET po_basic_sno = @po_basic_sno, modified_date = GETDATE()
    WHERE invoice_sno = @invoice_sno;

    SELECT invoice_sno, po_basic_sno, 'SUCCESS' AS result FROM dbo.invoice_info WHERE invoice_sno = @invoice_sno;
END;
GO

-- ============================================================
-- sp_nt_AllocateInvoice — splits the invoice into buckets per po_item_sno.
-- Rejects any split whose amounts don't sum to invoice_amount (1-rupee
-- rounding tolerance).
-- @jsonInput: { invoice_sno, allocations: [{ po_item_sno, allocated_amount }], created_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_AllocateInvoice', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_AllocateInvoice;
GO
CREATE PROCEDURE dbo.sp_nt_AllocateInvoice
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @invoice_sno INT           = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
        DECLARE @created_by  VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.created_by');
        DECLARE @allocations NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.allocations');

        IF @invoice_sno IS NULL OR @allocations IS NULL
            THROW 54001, 'invoice_sno and allocations are required.', 1;

        DECLARE @invoice_amount DECIMAL(18,2);
        SELECT @invoice_amount = invoice_amount FROM dbo.invoice_info WHERE invoice_sno = @invoice_sno;
        IF @invoice_amount IS NULL
            THROW 54002, 'Invoice not found.', 1;

        DECLARE @allocTable TABLE (po_item_sno INT, allocated_amount DECIMAL(18,2));
        INSERT INTO @allocTable (po_item_sno, allocated_amount)
        SELECT TRY_CAST(JSON_VALUE(value, '$.po_item_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.allocated_amount') AS DECIMAL(18,2))
        FROM OPENJSON(@allocations);

        DECLARE @allocatedTotal DECIMAL(18,2);
        SELECT @allocatedTotal = SUM(allocated_amount) FROM @allocTable;

        IF ABS(ISNULL(@allocatedTotal, 0) - @invoice_amount) > 1.00
            THROW 54003, 'Allocation amounts must sum to the invoice amount.', 1;

        -- Clear any prior allocation for this invoice (re-allocation supported)
        DELETE FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno;

        INSERT INTO dbo.invoice_allocation_details (
            invoice_sno, po_item_sno, bucket_type, allocated_amount, match_status, created_by, created_date, is_active
        )
        SELECT
            @invoice_sno,
            a.po_item_sno,
            ISNULL(pid.po_section, 'MATERIAL'),
            a.allocated_amount,
            'Pending',
            @created_by, GETDATE(), 'Y'
        FROM @allocTable a
        JOIN dbo.po_item_details pid ON pid.po_item_sno = a.po_item_sno;

        UPDATE dbo.invoice_info SET match_status = 'Allocated', modified_date = GETDATE() WHERE invoice_sno = @invoice_sno;

        COMMIT TRANSACTION;

        SELECT invoice_alloc_sno, po_item_sno, bucket_type, allocated_amount
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- sp_nt_MatchInvoiceBucket — per-bucket 2-way/3-way match, independent per
-- allocation row (a shortfall on one bucket never holds another bucket).
-- @jsonInput: { invoice_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_MatchInvoiceBucket', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_MatchInvoiceBucket;
GO
CREATE PROCEDURE dbo.sp_nt_MatchInvoiceBucket
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @invoice_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
        IF @invoice_sno IS NULL
            THROW 54010, 'invoice_sno is required.', 1;

        -- Per-bucket ratio: MATERIAL from GRN receipts, SERVICE from
        -- Service Entry (qty-based when the PO line carries a qty, else
        -- amount-based against the budgeted po_amount). Capped at 1.0.
        UPDATE iad
        SET matched_qty_ratio = ratios.ratio,
            hold_amount       = iad.allocated_amount * (1 - ratios.ratio),
            release_amount    = iad.allocated_amount * ratios.ratio,
            match_status      = CASE WHEN ratios.ratio >= 0.999999 THEN 'Matched' ELSE 'Partial' END
        FROM dbo.invoice_allocation_details iad
        JOIN dbo.po_item_details pid ON pid.po_item_sno = iad.po_item_sno
        CROSS APPLY (
            SELECT
                received_qty = (
                    SELECT ISNULL(SUM(gi.received_qty - ISNULL(gi.rejected_qty, 0)), 0)
                    FROM dbo.grn_item_details gi
                    WHERE gi.po_item_sno = pid.po_item_sno AND gi.is_active = 'Y'
                ),
                billed_qty_sum = (
                    SELECT ISNULL(SUM(sei.billed_qty), 0)
                    FROM dbo.service_entry_item_details sei
                    JOIN dbo.service_entry_info se ON se.service_entry_sno = sei.service_entry_sno
                    WHERE sei.po_item_sno = pid.po_item_sno AND sei.is_active = 'Y' AND se.status = 'Approved'
                ),
                confirmed_amt_sum = (
                    SELECT ISNULL(SUM(sei.confirmed_amount), 0)
                    FROM dbo.service_entry_item_details sei
                    JOIN dbo.service_entry_info se ON se.service_entry_sno = sei.service_entry_sno
                    WHERE sei.po_item_sno = pid.po_item_sno AND sei.is_active = 'Y' AND se.status = 'Approved'
                )
        ) raw
        CROSS APPLY (
            SELECT rawRatio = CASE
                WHEN iad.bucket_type = 'MATERIAL' THEN
                    CASE WHEN ISNULL(pid.qty, 0) = 0 THEN 0
                         ELSE CAST(raw.received_qty AS DECIMAL(18,6)) / pid.qty
                    END
                ELSE -- SERVICE
                    CASE
                        WHEN ISNULL(pid.qty, 0) > 0 THEN CAST(raw.billed_qty_sum AS DECIMAL(18,6)) / pid.qty
                        WHEN ISNULL(pid.net_cost, 0) > 0 THEN CAST(raw.confirmed_amt_sum AS DECIMAL(18,6)) / pid.net_cost
                        ELSE 0
                    END
                END
        ) computed
        CROSS APPLY (SELECT ratio = CASE WHEN computed.rawRatio > 1 THEN 1.0 ELSE computed.rawRatio END) ratios
        WHERE iad.invoice_sno = @invoice_sno AND iad.is_active = 'Y';

        DECLARE @totalRelease DECIMAL(18,2), @bucketCount INT, @matchedCount INT;
        SELECT
            @totalRelease = SUM(release_amount),
            @bucketCount  = COUNT(*),
            @matchedCount = SUM(CASE WHEN match_status = 'Matched' THEN 1 ELSE 0 END)
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';

        UPDATE dbo.invoice_info
        SET net_payable = ISNULL(@totalRelease, 0),
            match_status = CASE WHEN @matchedCount = @bucketCount THEN 'Matched' ELSE 'PartialRelease' END,
            modified_date = GETDATE()
        WHERE invoice_sno = @invoice_sno;

        COMMIT TRANSACTION;

        SELECT invoice_alloc_sno, po_item_sno, bucket_type, allocated_amount, matched_qty_ratio, hold_amount, release_amount, match_status
        FROM dbo.invoice_allocation_details WHERE invoice_sno = @invoice_sno AND is_active = 'Y';
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ============================================================
-- List/query support
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetInvoicesByPO', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetInvoicesByPO;
GO
CREATE PROCEDURE dbo.sp_nt_GetInvoicesByPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @po_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);

    SELECT i.*,
        (
            SELECT iad.invoice_alloc_sno, iad.po_item_sno, iad.bucket_type, iad.allocated_amount,
                   iad.matched_qty_ratio, iad.hold_amount, iad.release_amount, iad.match_status
            FROM dbo.invoice_allocation_details iad
            WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
            FOR JSON PATH
        ) AS allocations
    FROM dbo.invoice_info i
    WHERE i.po_basic_sno = @po_basic_sno AND i.is_active = 'Y'
    ORDER BY i.invoice_sno DESC;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetAllInvoices', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetAllInvoices;
GO
CREATE PROCEDURE dbo.sp_nt_GetAllInvoices
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @match_status VARCHAR(20) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @match_status = JSON_VALUE(@jsonInput, '$.match_status');

    SELECT
        i.invoice_sno, i.invoice_no, i.vendor_invoice_no, i.vendor_sno, k.company_name AS vendor_name,
        i.po_basic_sno, p.po_df_no AS po_no, i.invoice_date, i.due_date, i.invoice_amount,
        i.invoice_file_url, i.invoice_type, i.source_type, i.match_status, i.net_payable, i.created_date,
        (
            SELECT iad.invoice_alloc_sno, iad.po_item_sno, iad.bucket_type, iad.allocated_amount,
                   iad.matched_qty_ratio, iad.hold_amount, iad.release_amount, iad.match_status
            FROM dbo.invoice_allocation_details iad
            WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
            FOR JSON PATH
        ) AS allocations
    FROM dbo.invoice_info i
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = i.vendor_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    WHERE i.is_active = 'Y'
      AND (@match_status IS NULL OR i.match_status = @match_status)
    ORDER BY i.invoice_sno DESC;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetPendingInvoiceMatches', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPendingInvoiceMatches;
GO
CREATE PROCEDURE dbo.sp_nt_GetPendingInvoiceMatches
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.invoice_sno, i.invoice_no, i.vendor_sno, k.company_name AS vendor_name,
           i.po_basic_sno, p.po_df_no AS po_no, i.invoice_amount, i.match_status
    FROM dbo.invoice_info i
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = i.vendor_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    WHERE i.is_active = 'Y' AND i.match_status IN ('Pending', 'Allocated')
    ORDER BY i.invoice_sno DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT name FROM sys.procedures WHERE name LIKE 'sp_nt_%Invoice%';
-- ============================================================
