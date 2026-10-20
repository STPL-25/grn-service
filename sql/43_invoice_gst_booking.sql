-- ============================================================
-- 43_invoice_gst_booking.sql   (Non_trade_Dev ONLY)
--
-- Phase 3a: book a supplier invoice with GST and clear GRNI.
--
--   Dr  GRNI Clearing            value of the approved GRN lines allocated to this invoice (capped at taxable value)
--   Dr  Input CGST + SGST  | Input IGST      (intra-state | inter-state, from the supplier/company GSTIN)
--   Dr/Cr Purchase Price Variance           invoice taxable vs GRN value, when within the tolerance (default 1%)
--   Dr  Suspense - Unmapped                 invoice value ABOVE the GRN value and beyond the tolerance (flagged)
--   Cr  Supplier Payable                    taxable + tax
--
--   Invoice BELOW the GRN value and beyond tolerance: only the invoiced value clears GRNI, the rest stays open.
--   Input GST is booked immediately with itc_status = 'Pending 2B'; the GSTR-2B screen (phase 4) flips it.
--   TDS is NOT booked here - it is computed and deducted when the payment is made (sql/44).
-- Re-runnable.
-- ============================================================

-- ── invoice tax columns ─────────────────────────────────────────────────────
IF COL_LENGTH('dbo.invoice_info', 'supplier_gstin')      IS NULL ALTER TABLE dbo.invoice_info ADD supplier_gstin VARCHAR(20) NULL;
IF COL_LENGTH('dbo.invoice_info', 'taxable_value')       IS NULL ALTER TABLE dbo.invoice_info ADD taxable_value DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.invoice_info', 'cgst_amount')         IS NULL ALTER TABLE dbo.invoice_info ADD cgst_amount DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.invoice_info', 'sgst_amount')         IS NULL ALTER TABLE dbo.invoice_info ADD sgst_amount DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.invoice_info', 'igst_amount')         IS NULL ALTER TABLE dbo.invoice_info ADD igst_amount DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.invoice_info', 'is_intrastate')       IS NULL ALTER TABLE dbo.invoice_info ADD is_intrastate BIT NULL;
IF COL_LENGTH('dbo.invoice_info', 'itc_status')          IS NULL ALTER TABLE dbo.invoice_info ADD itc_status VARCHAR(12) NULL;   -- Pending 2B | Eligible | Ineligible
IF COL_LENGTH('dbo.invoice_info', 'tds_section_code')    IS NULL ALTER TABLE dbo.invoice_info ADD tds_section_code VARCHAR(10) NULL;
IF COL_LENGTH('dbo.invoice_info', 'gst_journal_sno')     IS NULL ALTER TABLE dbo.invoice_info ADD gst_journal_sno INT NULL;
IF COL_LENGTH('dbo.invoice_info', 'gst_booked_at')       IS NULL ALTER TABLE dbo.invoice_info ADD gst_booked_at DATETIME NULL;
IF COL_LENGTH('dbo.invoice_info', 'price_variance_flag') IS NULL ALTER TABLE dbo.invoice_info ADD price_variance_flag BIT NULL;
GO

-- ── settings + extra heads ──────────────────────────────────────────────────
IF OBJECT_ID('dbo.acct_setting', 'U') IS NULL
CREATE TABLE dbo.acct_setting (
    setting_key   VARCHAR(40) PRIMARY KEY,
    setting_value VARCHAR(100) NOT NULL,
    modified_by   VARCHAR(30) NULL,
    modified_at   DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.acct_setting WHERE setting_key = 'PPV_TOLERANCE_PCT')
    INSERT INTO dbo.acct_setting (setting_key, setting_value, modified_by) VALUES ('PPV_TOLERANCE_PCT', '1', 'system');
GO
MERGE dbo.acct_account_head AS t
USING (VALUES
  ('5150', N'Purchase Price Variance',                'EXPENSE', 'PPV'),
  ('5200', N'Debit / Credit Note Adjustments',        'EXPENSE', 'DN_ADJ')
) AS s(head_code, head_name, head_type, system_key)
ON t.head_code = s.head_code
WHEN NOT MATCHED THEN INSERT (head_code, head_name, head_type, system_key, created_by) VALUES (s.head_code, s.head_name, s.head_type, s.system_key, 'system');
GO

-- how much of each GRN line's journalled value has been cleared by invoices
IF OBJECT_ID('dbo.acct_grni_clearing', 'U') IS NULL
CREATE TABLE dbo.acct_grni_clearing (
    clearing_sno INT IDENTITY(1,1) PRIMARY KEY,
    grn_item_sno INT NOT NULL,
    invoice_sno  INT NOT NULL,
    amount       DECIMAL(18,2) NOT NULL,
    created_at   DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_acct_grni_clearing_item')
    CREATE INDEX IX_acct_grni_clearing_item ON dbo.acct_grni_clearing (grn_item_sno);
GO

-- ── book an invoice ─────────────────────────────────────────────────────────
-- @jsonInput: { invoice_sno, taxable_value, cgst_amount?, sgst_amount?, igst_amount?, supplier_gstin?, tds_section_code?, booked_by, preview? }
-- intra-state -> igst must be 0; inter-state -> cgst and sgst must be 0. taxable + tax must equal invoice_amount (+-1.00).
-- preview=true computes and returns the lines without saving.
CREATE OR ALTER PROCEDURE dbo.sp_nt_BookInvoiceGST
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inv INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT),
            @taxable DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.taxable_value') AS DECIMAL(18,2)),
            @cgst DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.cgst_amount') AS DECIMAL(18,2)), 0),
            @sgst DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.sgst_amount') AS DECIMAL(18,2)), 0),
            @igst DECIMAL(18,2) = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.igst_amount') AS DECIMAL(18,2)), 0),
            @gstin VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.supplier_gstin'), ''),
            @tds VARCHAR(10) = NULLIF(JSON_VALUE(@jsonInput, '$.tds_section_code'), ''),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.booked_by'),
            @preview BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.preview') IN ('1', 'true') THEN 1 ELSE 0 END;

    IF @inv IS NULL OR @taxable IS NULL OR @by IS NULL THROW 53401, 'invoice_sno, taxable_value and booked_by are required.', 1;
    IF @taxable < 0 OR @cgst < 0 OR @sgst < 0 OR @igst < 0 THROW 53402, 'Amounts cannot be negative.', 1;

    DECLARE @vendor INT, @amount DECIMAL(18,2), @com INT, @div INT, @brn INT, @dept INT, @idate DATE, @vno VARCHAR(50),
            @booked INT, @active CHAR(1), @inv_no VARCHAR(30);
    SELECT @vendor = vendor_sno, @amount = invoice_amount, @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno,
           @idate = invoice_date, @vno = vendor_invoice_no, @booked = gst_journal_sno, @active = is_active, @inv_no = invoice_no
    FROM dbo.invoice_info WHERE invoice_sno = @inv;
    IF @active IS NULL THROW 53403, 'Invoice not found.', 1;
    IF @active <> 'Y' THROW 53404, 'Invoice is inactive.', 1;
    IF @booked IS NOT NULL THROW 53405, 'This invoice is already booked.', 1;
    IF @vendor IS NULL THROW 53406, 'Invoice has no supplier.', 1;

    -- intra / inter state from the two GSTINs (same rule as the quotation screen)
    DECLARE @intra BIT = (SELECT is_intrastate FROM dbo.fn_nt_QuotationSupplyInfo(@vendor, @com));
    IF @intra IS NULL THROW 53407, 'Cannot tell intra/inter-state: the supplier GSTIN or our company GSTIN is missing.', 1;
    IF @intra = 1 AND @igst <> 0 THROW 53408, 'Intra-state supply: use CGST + SGST, not IGST.', 1;
    IF @intra = 0 AND (@cgst <> 0 OR @sgst <> 0) THROW 53409, 'Inter-state supply: use IGST, not CGST/SGST.', 1;
    IF @intra = 1 AND @cgst <> @sgst THROW 53410, 'CGST and SGST must be equal.', 1;

    DECLARE @tax DECIMAL(18,2) = @cgst + @sgst + @igst;
    IF ABS((@taxable + @tax) - @amount) > 1.00 THROW 53411, 'Taxable value + GST must equal the invoice amount (within Rs 1).', 1;

    -- GRN value available to clear, per allocated GRN line
    DECLARE @avail TABLE (grn_item_sno INT PRIMARY KEY, avail DECIMAL(18,2));
    INSERT INTO @avail (grn_item_sno, avail)
    SELECT g.grn_item_sno,
           ISNULL((SELECT SUM(l.debit) FROM dbo.acct_journal_line l JOIN dbo.acct_journal j ON j.journal_sno = l.journal_sno AND j.status = 'Posted'
                   WHERE l.grn_item_sno = g.grn_item_sno AND l.debit > 0), 0)
         - ISNULL((SELECT SUM(c.amount) FROM dbo.acct_grni_clearing c WHERE c.grn_item_sno = g.grn_item_sno), 0)
    FROM (SELECT DISTINCT grn_item_sno FROM dbo.invoice_allocation_details
          WHERE invoice_sno = @inv AND is_active = 'Y' AND grn_item_sno IS NOT NULL) g;
    DELETE FROM @avail WHERE avail <= 0;

    DECLARE @availTotal DECIMAL(18,2) = ISNULL((SELECT SUM(avail) FROM @avail), 0),
            @tolPct DECIMAL(9,4) = ISNULL((SELECT TRY_CAST(setting_value AS DECIMAL(9,4)) FROM dbo.acct_setting WHERE setting_key = 'PPV_TOLERANCE_PCT'), 1),
            @clear DECIMAL(18,2), @ppv DECIMAL(18,2) = 0, @excess DECIMAL(18,2) = 0, @flag BIT = 0;
    DECLARE @diff DECIMAL(18,2) = @taxable - @availTotal;

    IF @availTotal > 0 AND ABS(@diff) <= ROUND(@availTotal * @tolPct / 100.0, 2)
    BEGIN SET @clear = @availTotal; SET @ppv = @diff; END                       -- within tolerance: variance account absorbs it
    ELSE IF @diff > 0
    BEGIN SET @clear = @availTotal; SET @excess = @diff; SET @flag = 1; END      -- billed above received value, beyond tolerance
    ELSE
    BEGIN SET @clear = @taxable; SET @flag = 1; END                              -- billed below received value: remainder stays in GRNI

    DECLARE @h_grni INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'GRNI'),
            @h_pay  INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUPPLIER_PAYABLE'),
            @h_cg   INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'INPUT_CGST'),
            @h_sg   INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'INPUT_SGST'),
            @h_ig   INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'INPUT_IGST'),
            @h_ppv  INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'PPV'),
            @h_sus  INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUSPENSE');
    IF @h_grni IS NULL OR @h_pay IS NULL OR @h_cg IS NULL OR @h_sg IS NULL OR @h_ig IS NULL OR @h_ppv IS NULL OR @h_sus IS NULL
        THROW 53412, 'System account heads are missing.', 1;

    DECLARE @lines TABLE (head_sno INT, debit DECIMAL(18,2), credit DECIMAL(18,2), is_suspense BIT);
    IF @clear > 0   INSERT INTO @lines VALUES (@h_grni, @clear, 0, 0);
    IF @cgst > 0    INSERT INTO @lines VALUES (@h_cg, @cgst, 0, 0);
    IF @sgst > 0    INSERT INTO @lines VALUES (@h_sg, @sgst, 0, 0);
    IF @igst > 0    INSERT INTO @lines VALUES (@h_ig, @igst, 0, 0);
    IF @ppv > 0     INSERT INTO @lines VALUES (@h_ppv, @ppv, 0, 0);
    IF @ppv < 0     INSERT INTO @lines VALUES (@h_ppv, 0, -@ppv, 0);
    IF @excess > 0  INSERT INTO @lines VALUES (@h_sus, @excess, 0, 1);
    INSERT INTO @lines VALUES (@h_pay, 0, @taxable + @tax, 0);

    IF (SELECT SUM(debit) - SUM(credit) FROM @lines) <> 0 THROW 53413, 'Invoice journal is not balanced.', 1;

    IF @preview = 1
    BEGIN
        SELECT @intra AS is_intrastate, @availTotal AS grn_value_available, @clear AS grni_cleared, @ppv AS price_variance,
               @excess AS excess_to_suspense, @flag AS variance_flag, @taxable + @tax AS payable;
        SELECT h.head_code, h.head_name, l.debit, l.credit FROM @lines l JOIN dbo.acct_account_head h ON h.head_sno = l.head_sno;
        RETURN;
    END

    DECLARE @journal INT;
    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
        VALUES (ISNULL(@idate, CAST(GETDATE() AS DATE)), 'INVOICE', @inv, N'Invoice ' + ISNULL(@vno, @inv_no) + N' booked', @com, @div, @brn, @dept, @by);
        SET @journal = SCOPE_IDENTITY();
        UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@journal AS VARCHAR(6)), 6) WHERE journal_sno = @journal;

        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno, is_suspense)
        SELECT @journal, head_sno, debit, credit, @vendor, is_suspense FROM @lines;

        -- record how much of each GRN line this invoice cleared (proportional to what was available)
        IF @clear > 0 AND @availTotal > 0
            INSERT INTO dbo.acct_grni_clearing (grn_item_sno, invoice_sno, amount)
            SELECT grn_item_sno, @inv, ROUND(avail * (CASE WHEN @clear > @availTotal THEN @availTotal ELSE @clear END) / @availTotal, 2)
            FROM @avail;

        UPDATE dbo.invoice_info SET
            supplier_gstin = ISNULL(@gstin, (SELECT gst_no FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @vendor)),
            taxable_value = @taxable, cgst_amount = @cgst, sgst_amount = @sgst, igst_amount = @igst, is_intrastate = @intra,
            itc_status = CASE WHEN itc_status IN ('Eligible', 'Ineligible') THEN itc_status ELSE 'Pending 2B' END, tds_section_code = @tds, gst_journal_sno = @journal, gst_booked_at = GETDATE(),
            price_variance_flag = @flag, modified_by = @by, modified_date = GETDATE()
        WHERE invoice_sno = @inv;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT @inv AS invoice_sno, @journal AS journal_sno, @intra AS is_intrastate, @clear AS grni_cleared, @ppv AS price_variance,
           @excess AS excess_to_suspense, @flag AS variance_flag, @taxable + @tax AS payable,
           (SELECT itc_status FROM dbo.invoice_info WHERE invoice_sno = @inv) AS itc_status;
END
GO

-- read: the invoice's tax block (for the booking dialog) + the supply type derived from GSTINs
-- @jsonInput: { invoice_sno }
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetInvoiceGST
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inv INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no, i.vendor_sno, k.company_name AS vendor_name, i.invoice_amount,
           i.supplier_gstin, i.taxable_value, i.cgst_amount, i.sgst_amount, i.igst_amount, i.itc_status, i.tds_section_code,
           i.gst_journal_sno, i.price_variance_flag,
           ISNULL(i.is_intrastate, s.is_intrastate) AS is_intrastate, s.vendor_gst, s.company_gst
    FROM dbo.invoice_info i
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY dbo.fn_nt_QuotationSupplyInfo(i.vendor_sno, i.com_sno) s
    WHERE i.invoice_sno = @inv;
END
GO
