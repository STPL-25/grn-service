-- ============================================================
-- Vendor-driven purchase: ONE consolidated bill per supplier per period
-- Database: Non_trade_Dev (MSSQL). Re-runnable. Rollback:
--   sql/backups/vendor_consolidated_bill_2026-10-26_ROLLBACK.sql
--
-- Vendor-driven (canteen / daily grocery) POs are received day by day and
-- paid on a cycle. "Raise Bill" used to create unrelated per-PO invoices;
-- the paying side had no way to see them as one thing. Now the bills raised
-- in one action are tied to a consolidated bill header (VBC-yyyy-nnnnnn)
-- for one supplier and one period. Payment itself is UNCHANGED: the
-- consolidated bill is paid through the normal Payment page -> approval
-- workflow -> Payment Run, because every member invoice is an ordinary
-- invoice_info row with ordinary allocations.
--   * invoice_info.consolidation_sno (nullable) links a member invoice.
--   * All members share company / division / branch / department so the
--     payment approval workflow lookup is unambiguous.
-- ============================================================

IF OBJECT_ID('dbo.vendor_bill_consolidation', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.vendor_bill_consolidation (
        consolidation_sno INT IDENTITY(1,1) PRIMARY KEY,
        consolidation_no  VARCHAR(30)  NOT NULL,
        vendor_sno        INT          NOT NULL,
        com_sno           INT          NULL,
        div_sno           INT          NULL,
        brn_sno           INT          NULL,
        dept_sno          INT          NULL,
        period_from       DATE         NULL,
        period_to         DATE         NULL,
        total_amount      DECIMAL(18,2) NOT NULL DEFAULT 0,
        invoice_count     INT          NOT NULL DEFAULT 0,
        is_active         CHAR(1)      NOT NULL DEFAULT 'Y',
        created_by        VARCHAR(50)  NULL,
        created_date      DATETIME     NOT NULL DEFAULT GETDATE(),
        CONSTRAINT UQ_vendor_bill_consolidation_no UNIQUE (consolidation_no)
    );
END
GO

IF COL_LENGTH('dbo.invoice_info', 'consolidation_sno') IS NULL
    ALTER TABLE dbo.invoice_info ADD consolidation_sno INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_invoice_info_consolidation')
    ALTER TABLE dbo.invoice_info ADD CONSTRAINT FK_invoice_info_consolidation
        FOREIGN KEY (consolidation_sno) REFERENCES dbo.vendor_bill_consolidation (consolidation_sno);
GO

-- ============================================================
-- Billable child POs: optional period filter on the date the goods last
-- arrived (@jsonInput: { vendor_sno, from_date?, to_date? }), and the
-- last-received date + cycle due date in the result. Everything else is as
-- in sql/28.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetVendorDrivenBillableChildPOs
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno INT  = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @from_date  DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.from_date') AS DATE);
    DECLARE @to_date    DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.to_date') AS DATE);

    IF @vendor_sno IS NULL
        THROW 61001, 'vendor_sno is required.', 1;

    SELECT
        po.po_basic_sno,
        po.po_df_no,
        CONVERT(VARCHAR(10), po.po_date, 120) AS po_date,
        po.vendor_sno,
        k.company_name AS vendor_name,
        po.com_sno,
        po.div_sno,
        po.brn_sno,
        po.dept_sno,
        pr.pr_basic_sno,
        pr.pr_no,
        pr.payment_cycle_days,
        ge.vendor_invoice_no,
        ge.vendor_invoice_date,
        CONVERT(VARCHAR(10), arr.last_received_date, 120) AS last_received_date,
        (
            SELECT gb.grn_no, CONVERT(VARCHAR(10), gb.received_date, 120) AS received_date,
                   ge2.invoice_no AS supplier_invoice_no, gb.status
            FROM dbo.grn_basic_info gb
            LEFT JOIN dbo.nt_gate_entry ge2 ON ge2.gate_entry_sno = gb.gate_entry_sno
            WHERE gb.po_basic_sno = po.po_basic_sno AND gb.is_active = 'Y'
            ORDER BY gb.received_date, gb.grn_basic_sno
            FOR JSON PATH
        ) AS receipts,
        (
            SELECT
                poi.po_item_sno,
                poi.prod_sno,
                ISNULL(poi.prod_name, pm.prod_name) AS prod_name,
                poi.qty AS requested_qty,
                poi.unit_name,
                poi.net_cost AS line_value,
                (
                    SELECT ISNULL(SUM(g.received_qty - ISNULL(g.rejected_qty, 0)), 0)
                    FROM dbo.grn_item_details g
                    WHERE g.po_item_sno = poi.po_item_sno AND g.is_active = 'Y'
                ) AS received_qty
            FROM dbo.po_item_details poi
            LEFT JOIN dbo.product_master pm ON pm.prod_sno = poi.prod_sno
            WHERE poi.po_basic_sno = po.po_basic_sno
              AND poi.is_active IN ('1', 'Y')
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info po
    JOIN dbo.pr_basic_info pr ON pr.pr_basic_sno = po.pr_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    OUTER APPLY (
        SELECT TOP 1 g.vendor_invoice_no, g.vendor_invoice_date
        FROM (
            SELECT ge.invoice_no AS vendor_invoice_no, ge.invoice_date AS vendor_invoice_date, ge.received_date
            FROM dbo.grn_basic_info gb
            JOIN dbo.nt_gate_entry ge ON ge.gate_entry_sno = gb.gate_entry_sno
            WHERE gb.po_basic_sno = po.po_basic_sno AND gb.is_active = 'Y'
        ) g
        ORDER BY g.received_date DESC
    ) ge
    OUTER APPLY (
        SELECT MAX(gb.received_date) AS last_received_date
        FROM dbo.grn_basic_info gb
        WHERE gb.po_basic_sno = po.po_basic_sno AND gb.is_active = 'Y'
    ) arr
    WHERE pr.request_mode = 'VENDOR_DRIVEN'
      AND po.vendor_sno = @vendor_sno
      AND po.is_active = 'Y'
      AND po.status = 'A'
      AND arr.last_received_date IS NOT NULL
      AND (@from_date IS NULL OR CAST(arr.last_received_date AS DATE) >= @from_date)
      AND (@to_date   IS NULL OR CAST(arr.last_received_date AS DATE) <= @to_date)
      AND NOT EXISTS (
          SELECT 1 FROM dbo.invoice_info inv
          WHERE inv.po_basic_sno = po.po_basic_sno AND inv.is_active = 'Y'
      )
    ORDER BY po.po_basic_sno;
END;
GO

-- ============================================================
-- sp_nt_CreateVendorBillConsolidation — ties already-created invoices
-- together under one header.
-- @jsonInput: { vendor_sno, period_from?, period_to?, invoice_snos:[..], created_by }
-- Guards: every invoice must be this supplier's, active, not yet
-- consolidated, and all must share com/div/brn/dept (one approval route).
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateVendorBillConsolidation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @vendor_sno  INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    DECLARE @from        DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_from') AS DATE);
    DECLARE @to          DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.period_to') AS DATE);
    DECLARE @created_by  VARCHAR(50) = JSON_VALUE(@jsonInput, '$.created_by');

    IF @vendor_sno IS NULL THROW 61101, 'vendor_sno is required.', 1;

    DECLARE @ids TABLE (invoice_sno INT PRIMARY KEY);
    INSERT INTO @ids (invoice_sno)
    SELECT DISTINCT TRY_CAST([value] AS INT) FROM OPENJSON(@jsonInput, '$.invoice_snos')
    WHERE TRY_CAST([value] AS INT) IS NOT NULL;

    IF NOT EXISTS (SELECT 1 FROM @ids) THROW 61102, 'At least one invoice is required.', 1;

    IF EXISTS (
        SELECT 1 FROM @ids x
        LEFT JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno
        WHERE i.invoice_sno IS NULL OR i.is_active <> 'Y' OR i.vendor_sno <> @vendor_sno OR i.consolidation_sno IS NOT NULL
    ) THROW 61103, 'Every invoice must be an active invoice of this supplier that is not already in a consolidated bill.', 1;

    IF (SELECT COUNT(*) FROM (
            SELECT DISTINCT i.com_sno, i.div_sno, i.brn_sno, i.dept_sno
            FROM @ids x JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno) o) > 1
        THROW 61104, 'Bills of different company / division / branch / department cannot be consolidated together (they follow different payment approvals).', 1;

    BEGIN TRAN;

    -- one number at a time; the unique index is the backstop
    DECLARE @lock INT;
    EXEC @lock = sp_getapplock @Resource = 'vendor_bill_consolidation_no', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
    IF @lock < 0 THROW 61105, 'Could not get the bill-number lock. Try again.', 1;

    DECLARE @yr VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4));
    DECLARE @seq INT = ISNULL((
        SELECT MAX(TRY_CAST(RIGHT(consolidation_no, 6) AS INT))
        FROM dbo.vendor_bill_consolidation WHERE consolidation_no LIKE 'VBC-' + @yr + '-%'), 0) + 1;
    DECLARE @no VARCHAR(30) = 'VBC-' + @yr + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

    DECLARE @com INT, @div INT, @brn INT, @dept INT;
    SELECT TOP 1 @com = i.com_sno, @div = i.div_sno, @brn = i.brn_sno, @dept = i.dept_sno
    FROM @ids x JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno;

    INSERT INTO dbo.vendor_bill_consolidation
        (consolidation_no, vendor_sno, com_sno, div_sno, brn_sno, dept_sno, period_from, period_to, created_by)
    VALUES (@no, @vendor_sno, @com, @div, @brn, @dept, @from, @to, @created_by);
    DECLARE @sno INT = SCOPE_IDENTITY();

    UPDATE i SET consolidation_sno = @sno
    FROM dbo.invoice_info i JOIN @ids x ON x.invoice_sno = i.invoice_sno;

    UPDATE dbo.vendor_bill_consolidation
    SET total_amount = t.amt, invoice_count = t.cnt
    FROM (SELECT SUM(i.invoice_amount) amt, COUNT(*) cnt
          FROM dbo.invoice_info i WHERE i.consolidation_sno = @sno) t
    WHERE consolidation_sno = @sno;

    COMMIT;

    SELECT consolidation_sno, consolidation_no, vendor_sno, total_amount, invoice_count
    FROM dbo.vendor_bill_consolidation WHERE consolidation_sno = @sno;
END;
GO

-- ============================================================
-- sp_nt_GetVendorBillConsolidations — consolidated bills with their member
-- invoices (JSON). @jsonInput: { vendor_sno? }
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetVendorBillConsolidations
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    SELECT
        c.consolidation_sno, c.consolidation_no, c.vendor_sno,
        k.company_name AS vendor_name,
        CONVERT(VARCHAR(10), c.period_from, 120) AS period_from,
        CONVERT(VARCHAR(10), c.period_to, 120)   AS period_to,
        c.total_amount, c.invoice_count, c.created_by,
        CONVERT(VARCHAR(19), c.created_date, 120) AS created_date,
        (
            SELECT i.invoice_sno, i.invoice_no, i.invoice_amount, p.po_df_no AS po_no
            FROM dbo.invoice_info i
            LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
            WHERE i.consolidation_sno = c.consolidation_sno AND i.is_active = 'Y'
            FOR JSON PATH
        ) AS invoices
    FROM dbo.vendor_bill_consolidation c
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = c.vendor_sno
    WHERE c.is_active = 'Y' AND (@vendor_sno IS NULL OR c.vendor_sno = @vendor_sno)
    ORDER BY c.consolidation_sno DESC;
END;
GO
