-- ============================================================
-- 44_payment_net_tds_advances.sql   (Non_trade_Dev ONLY)
--
-- Phase 3b: payment net-payable.
--
--   net paid = gross settled  - TDS  - advance adjusted  - debit notes  + credit notes
--
--   Dr Supplier Payable (gross + credit notes)        Cr TDS Payable, Cr Advance to Suppliers, Cr Bank (net),
--   Cr Debit/Credit Note Adjustments (debit notes)    Dr Debit/Credit Note Adjustments + Cr Supplier Payable (credit notes)
--
--   * gross = the sum of the invoice-bucket allocations (same buckets / release limits as sp_nt_ReleasePayment).
--   * TDS: per invoice, from its tds_section_code, on the invoice TAXABLE value share of the amount paid (GST excluded),
--     using the editable tds_section_master and a per-supplier / per-financial-year (Apr-Mar) running total.
--   * Advances: supplier advances recorded with sp_nt_RecordSupplierAdvance (Dr Advance to Suppliers / Cr Bank).
--   * Notes: unadjusted debit/credit notes of the same supplier; each can be set off once.
--   sp_nt_ReleasePaymentNet with preview=true returns the numbers without saving. The old sp_nt_ReleasePayment is untouched.
-- Rates below are starting values for the TDS master - confirm with your tax consultant; they are editable.
-- Re-runnable.
-- ============================================================

-- columns the payment hold reads (also created by sql/43 + sql/45; idempotent)
IF COL_LENGTH('dbo.invoice_info', 'itc_status')            IS NULL ALTER TABLE dbo.invoice_info ADD itc_status VARCHAR(12) NULL;
IF COL_LENGTH('dbo.invoice_info', 'payment_hold_override') IS NULL ALTER TABLE dbo.invoice_info ADD payment_hold_override CHAR(1) NULL;
GO

-- ── TDS master ──────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.tds_section_master', 'U') IS NULL
CREATE TABLE dbo.tds_section_master (
    section_code     VARCHAR(10)   PRIMARY KEY,
    description      NVARCHAR(150) NOT NULL,
    rate_individual  DECIMAL(6,3)  NOT NULL,      -- individual / HUF / proprietor
    rate_other       DECIMAL(6,3)  NOT NULL,      -- company / firm / others
    rate_no_pan      DECIMAL(6,3)  NOT NULL DEFAULT 20,   -- applied when it is higher and the supplier has no PAN
    single_threshold DECIMAL(18,2) NOT NULL DEFAULT 0,    -- one payment above this is always deducted (0 = none)
    annual_threshold DECIMAL(18,2) NOT NULL DEFAULT 0,    -- deduct once the financial-year total crosses this
    excess_only      CHAR(1)       NOT NULL DEFAULT 'N',  -- 'Y' = tax only the amount above annual_threshold (194Q)
    is_active        CHAR(1)       NOT NULL DEFAULT 'Y',
    modified_by      VARCHAR(30)   NULL,
    modified_at      DATETIME      NOT NULL DEFAULT GETDATE()
);
GO
MERGE dbo.tds_section_master AS t
USING (VALUES
  ('194C', N'Payment to contractors / service providers',        1.0,  2.0, 20, 30000,   100000, 'N'),
  ('194J', N'Professional / technical fees',                     10.0, 10.0, 20, 0,       50000,  'N'),
  ('194I', N'Rent',                                              10.0, 10.0, 20, 0,       600000, 'N'),
  ('194H', N'Commission / brokerage',                            2.0,  2.0, 20, 0,        20000,  'N'),
  ('194Q', N'Purchase of goods (above Rs 50 lakh a year)',       0.1,  0.1, 20, 0,        5000000,'Y'),
  ('194A', N'Interest other than on securities',                 10.0, 10.0, 20, 0,       10000,  'N')
) AS s(section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only)
ON t.section_code = s.section_code
WHEN NOT MATCHED THEN INSERT (section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, modified_by)
     VALUES (s.section_code, s.description, s.rate_individual, s.rate_other, s.rate_no_pan, s.single_threshold, s.annual_threshold, s.excess_only, 'system');
GO

IF OBJECT_ID('dbo.tds_deduction', 'U') IS NULL
CREATE TABLE dbo.tds_deduction (
    deduction_sno  INT IDENTITY(1,1) PRIMARY KEY,
    vendor_sno     INT NOT NULL,
    section_code   VARCHAR(10) NOT NULL,
    fin_year       INT NOT NULL,                  -- starting year of the Apr-Mar financial year
    invoice_sno    INT NULL,
    payment_sno    INT NULL,
    base_amount    DECIMAL(18,2) NOT NULL,        -- taxable value paid in this payment (recorded even when TDS = 0, to track thresholds)
    base_deducted  DECIMAL(18,2) NOT NULL DEFAULT 0,  -- the part of the cumulative base that tax was actually cut on
    rate_pct       DECIMAL(6,3) NOT NULL DEFAULT 0,
    tds_amount     DECIMAL(18,2) NOT NULL DEFAULT 0,
    created_at     DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_tds_deduction_vendor_fy')
    CREATE INDEX IX_tds_deduction_vendor_fy ON dbo.tds_deduction (vendor_sno, section_code, fin_year);
GO

-- edit / add a section: { section_code, description, rate_individual, rate_other, rate_no_pan?, single_threshold?, annual_threshold?, excess_only?, is_active?, modified_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpsertTdsSection
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @c VARCHAR(10) = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.section_code'))), ''));
    IF @c IS NULL THROW 53501, 'section_code is required.', 1;
    DECLARE @d NVARCHAR(150) = JSON_VALUE(@jsonInput, '$.description'),
            @ri DECIMAL(6,3) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_individual') AS DECIMAL(6,3)),
            @ro DECIMAL(6,3) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_other') AS DECIMAL(6,3)),
            @rn DECIMAL(6,3) = TRY_CAST(JSON_VALUE(@jsonInput, '$.rate_no_pan') AS DECIMAL(6,3)),
            @st DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.single_threshold') AS DECIMAL(18,2)),
            @at DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.annual_threshold') AS DECIMAL(18,2)),
            @ex CHAR(1) = JSON_VALUE(@jsonInput, '$.excess_only'),
            @ac CHAR(1) = JSON_VALUE(@jsonInput, '$.is_active'),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.modified_by');
    IF EXISTS (SELECT 1 FROM dbo.tds_section_master WHERE section_code = @c)
        UPDATE dbo.tds_section_master SET
            description = ISNULL(@d, description), rate_individual = ISNULL(@ri, rate_individual), rate_other = ISNULL(@ro, rate_other),
            rate_no_pan = ISNULL(@rn, rate_no_pan), single_threshold = ISNULL(@st, single_threshold), annual_threshold = ISNULL(@at, annual_threshold),
            excess_only = ISNULL(@ex, excess_only), is_active = ISNULL(@ac, is_active), modified_by = @by, modified_at = GETDATE()
        WHERE section_code = @c;
    ELSE
    BEGIN
        IF @d IS NULL OR @ri IS NULL OR @ro IS NULL THROW 53502, 'description, rate_individual and rate_other are required for a new section.', 1;
        INSERT INTO dbo.tds_section_master (section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, is_active, modified_by)
        VALUES (@c, @d, @ri, @ro, ISNULL(@rn, 20), ISNULL(@st, 0), ISNULL(@at, 0), ISNULL(@ex, 'N'), ISNULL(@ac, 'Y'), @by);
    END
    SELECT * FROM dbo.tds_section_master WHERE section_code = @c;
END
GO

-- ── TDS for one base amount ─────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_CalcTDS
    @vendor_sno INT, @section VARCHAR(10), @base DECIMAL(18,2), @on_date DATE,
    @extra_prior DECIMAL(18,2) = 0,          -- base already counted earlier in the same payment
    @extra_deducted DECIMAL(18,2) = 0,       -- base already taxed earlier in the same payment
    @tds DECIMAL(18,2) OUTPUT, @rate DECIMAL(6,3) OUTPUT, @taxable DECIMAL(18,2) OUTPUT, @fy INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @tds = 0; SET @rate = 0; SET @taxable = 0;
    SET @on_date = ISNULL(@on_date, CAST(GETDATE() AS DATE));
    SET @fy = YEAR(@on_date) - CASE WHEN MONTH(@on_date) < 4 THEN 1 ELSE 0 END;

    DECLARE @ri DECIMAL(6,3), @ro DECIMAL(6,3), @rn DECIMAL(6,3), @st DECIMAL(18,2), @at DECIMAL(18,2), @ex CHAR(1);
    SELECT @ri = rate_individual, @ro = rate_other, @rn = rate_no_pan, @st = single_threshold, @at = annual_threshold, @ex = excess_only
    FROM dbo.tds_section_master WHERE section_code = @section AND is_active = 'Y';
    IF @ri IS NULL THROW 53510, 'Unknown or inactive TDS section.', 1;

    DECLARE @pan VARCHAR(20), @btype NVARCHAR(100);
    SELECT @pan = pan_no, @btype = business_type FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = @vendor_sno;
    DECLARE @indiv BIT = CASE WHEN @btype LIKE '%roprietor%' OR @btype LIKE '%ndividual%' OR @btype LIKE '%HUF%' THEN 1 ELSE 0 END;
    SET @rate = CASE WHEN @indiv = 1 THEN @ri ELSE @ro END;
    IF LEN(ISNULL(LTRIM(RTRIM(@pan)), '')) < 10 AND @rn > @rate SET @rate = @rn;

    DECLARE @prior DECIMAL(18,2), @deducted DECIMAL(18,2);
    SELECT @prior = ISNULL(SUM(base_amount), 0) + @extra_prior, @deducted = ISNULL(SUM(base_deducted), 0) + @extra_deducted
    FROM dbo.tds_deduction WHERE vendor_sno = @vendor_sno AND section_code = @section AND fin_year = @fy;
    IF @prior IS NULL BEGIN SET @prior = @extra_prior; SET @deducted = @extra_deducted; END

    DECLARE @cum DECIMAL(18,2) = @prior + @base;
    IF @ex = 'Y'
        SET @taxable = CASE WHEN @cum > @at THEN (CASE WHEN @cum - @at < @base THEN @cum - @at ELSE @base END) ELSE 0 END;
    ELSE IF (@st > 0 AND @base > @st) OR @cum > @at
        SET @taxable = CASE WHEN @cum - @deducted > 0 THEN @cum - @deducted ELSE 0 END;   -- catch-up once the threshold is crossed
    IF @taxable > @base AND @ex = 'Y' SET @taxable = @base;
    SET @tds = ROUND(@taxable * @rate / 100.0, 0);
END
GO

-- ── supplier advances ───────────────────────────────────────────────────────
IF OBJECT_ID('dbo.nt_supplier_advance_payment', 'U') IS NULL
CREATE TABLE dbo.nt_supplier_advance_payment (
    advance_sno     INT IDENTITY(1,1) PRIMARY KEY,
    advance_no      VARCHAR(30) NULL,
    vendor_sno      INT NOT NULL,
    po_basic_sno    INT NULL,
    paid_date       DATE NOT NULL,
    amount          DECIMAL(18,2) NOT NULL CHECK (amount > 0),
    adjusted_amount DECIMAL(18,2) NOT NULL DEFAULT 0,
    mode            VARCHAR(10) NULL,
    reference_no    VARCHAR(100) NULL,
    remarks         VARCHAR(500) NULL,
    journal_sno     INT NULL,
    is_active       CHAR(1) NOT NULL DEFAULT 'Y',
    created_by      VARCHAR(30) NULL,
    created_at      DATETIME NOT NULL DEFAULT GETDATE()
);
GO

-- { vendor_sno, po_basic_sno?, amount, paid_date, mode?, reference_no?, remarks?, created_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_RecordSupplierAdvance
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @po INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT),
            @amt DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.amount') AS DECIMAL(18,2)),
            @dt DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.paid_date') AS DATE), CAST(GETDATE() AS DATE)),
            @mode VARCHAR(10) = JSON_VALUE(@jsonInput, '$.mode'), @ref VARCHAR(100) = JSON_VALUE(@jsonInput, '$.reference_no'),
            @rem VARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    IF @v IS NULL OR @amt IS NULL OR @amt <= 0 OR @by IS NULL THROW 53520, 'vendor_sno, a positive amount and created_by are required.', 1;
    IF @po IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.po_request_info WHERE po_basic_sno = @po AND vendor_sno = @v)
        THROW 53521, 'That PO does not belong to this supplier.', 1;

    DECLARE @h_adv INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'ADVANCE_SUPPLIER'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK'), @adv INT, @j INT;
    IF @h_adv IS NULL OR @h_bank IS NULL THROW 53522, 'System account heads are missing.', 1;
    DECLARE @com INT, @div INT, @brn INT, @dept INT;
    SELECT @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno FROM dbo.po_request_info WHERE po_basic_sno = @po;

    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.nt_supplier_advance_payment (vendor_sno, po_basic_sno, paid_date, amount, mode, reference_no, remarks, created_by)
        VALUES (@v, @po, @dt, @amt, @mode, @ref, @rem, @by);
        SET @adv = SCOPE_IDENTITY();
        UPDATE dbo.nt_supplier_advance_payment SET advance_no = 'ADV-' + RIGHT('000000' + CAST(@adv AS VARCHAR(6)), 6) WHERE advance_sno = @adv;

        INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
        VALUES (@dt, 'ADVANCE', @adv, N'Advance paid to supplier', @com, @div, @brn, @dept, @by);
        SET @j = SCOPE_IDENTITY();
        UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;
        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) VALUES (@j, @h_adv, @amt, 0, @v), (@j, @h_bank, 0, @amt, @v);
        UPDATE dbo.nt_supplier_advance_payment SET journal_sno = @j WHERE advance_sno = @adv;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT advance_sno, advance_no, amount, amount - adjusted_amount AS balance FROM dbo.nt_supplier_advance_payment WHERE advance_sno = @adv;
END
GO

-- ── payment adjustments storage ─────────────────────────────────────────────
IF COL_LENGTH('dbo.payment_info', 'gross_amount')     IS NULL ALTER TABLE dbo.payment_info ADD gross_amount DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.payment_info', 'tds_amount')       IS NULL ALTER TABLE dbo.payment_info ADD tds_amount DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.payment_info', 'advance_adjusted') IS NULL ALTER TABLE dbo.payment_info ADD advance_adjusted DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.payment_info', 'note_adjusted')    IS NULL ALTER TABLE dbo.payment_info ADD note_adjusted DECIMAL(18,2) NULL;   -- debit notes - credit notes
IF COL_LENGTH('dbo.payment_info', 'net_paid')         IS NULL ALTER TABLE dbo.payment_info ADD net_paid DECIMAL(18,2) NULL;
IF COL_LENGTH('dbo.payment_info', 'journal_sno')      IS NULL ALTER TABLE dbo.payment_info ADD journal_sno INT NULL;
GO
IF OBJECT_ID('dbo.payment_adjustment', 'U') IS NULL
CREATE TABLE dbo.payment_adjustment (
    adjustment_sno INT IDENTITY(1,1) PRIMARY KEY,
    payment_sno    INT NOT NULL,
    adj_type       VARCHAR(12) NOT NULL CHECK (adj_type IN ('TDS', 'ADVANCE', 'DEBIT_NOTE', 'CREDIT_NOTE')),
    ref_sno        INT NULL,               -- advance_sno / debit_note_sno / credit_note_sno
    invoice_sno    INT NULL,               -- TDS only
    amount         DECIMAL(18,2) NOT NULL,
    created_at     DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_adjustment_note')
    CREATE UNIQUE INDEX UX_payment_adjustment_note ON dbo.payment_adjustment (adj_type, ref_sno) WHERE adj_type IN ('DEBIT_NOTE', 'CREDIT_NOTE');
GO

-- ── what can be adjusted against a supplier's payment ───────────────────────
-- { vendor_sno }  -> 4 recordsets: advances, debit notes, credit notes, TDS sections
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentAdjustments
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);
    SELECT advance_sno, advance_no, po_basic_sno, paid_date, amount, amount - adjusted_amount AS balance
    FROM dbo.nt_supplier_advance_payment WHERE vendor_sno = @v AND is_active = 'Y' AND amount - adjusted_amount > 0 ORDER BY paid_date, advance_sno;

    SELECT d.debit_note_sno AS note_sno, d.debit_note_no AS note_no, d.po_basic_sno, d.grn_basic_sno, d.debit_note_date AS note_date, d.total_amount AS amount, d.remarks
    FROM dbo.debit_note_basic_info d
    WHERE d.vendor_sno = @v AND d.is_active = 'Y' AND ISNULL(d.total_amount, 0) > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'DEBIT_NOTE' AND pa.ref_sno = d.debit_note_sno)
    ORDER BY d.debit_note_sno;

    SELECT c.credit_note_sno AS note_sno, c.credit_note_no AS note_no, c.po_basic_sno, c.grn_basic_sno, c.credit_note_date AS note_date, c.total_amount AS amount, c.remarks
    FROM dbo.credit_note_basic_info c
    WHERE c.vendor_sno = @v AND c.is_active = 'Y' AND ISNULL(c.total_amount, 0) > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'CREDIT_NOTE' AND pa.ref_sno = c.credit_note_sno)
    ORDER BY c.credit_note_sno;

    SELECT section_code, description, rate_individual, rate_other, rate_no_pan, single_threshold, annual_threshold, excess_only, is_active
    FROM dbo.tds_section_master ORDER BY section_code;
END
GO

-- ── release a payment with TDS / advance / note adjustments ─────────────────
-- @jsonInput: { vendor_sno, payment_date, mode, bank_account?, reference_no?, remarks?, created_by, preview?, apply_tds?,
--   allocations: [{ invoice_alloc_sno, amount }], advances: [{ advance_sno, amount }], notes: [{ type: 'DEBIT'|'CREDIT', note_sno }] }
CREATE OR ALTER PROCEDURE dbo.sp_nt_ReleasePaymentNet
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @pdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE), CAST(GETDATE() AS DATE)),
            @mode VARCHAR(10) = JSON_VALUE(@jsonInput, '$.mode'), @bank VARCHAR(100) = JSON_VALUE(@jsonInput, '$.bank_account'),
            @ref VARCHAR(100) = JSON_VALUE(@jsonInput, '$.reference_no'), @rem VARCHAR(500) = JSON_VALUE(@jsonInput, '$.remarks'),
            @by VARCHAR(20) = JSON_VALUE(@jsonInput, '$.created_by'),
            @preview BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.preview') IN ('1', 'true') THEN 1 ELSE 0 END,
            @applyTds BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.apply_tds') IN ('0', 'false') THEN 0 ELSE 1 END,
            @allocJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.allocations'),
            @advJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.advances'),
            @noteJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.notes');
    IF @v IS NULL OR @mode IS NULL OR @by IS NULL OR @allocJson IS NULL THROW 55011, 'vendor_sno, mode, created_by and allocations are required.', 1;

    DECLARE @alloc TABLE (invoice_alloc_sno INT, amount DECIMAL(18,2));
    INSERT INTO @alloc SELECT TRY_CAST(JSON_VALUE(value, '$.invoice_alloc_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)) FROM OPENJSON(@allocJson);
    IF NOT EXISTS (SELECT 1 FROM @alloc) OR EXISTS (SELECT 1 FROM @alloc WHERE invoice_alloc_sno IS NULL OR amount IS NULL OR amount <= 0)
        THROW 55012, 'Each allocation needs an invoice_alloc_sno and a positive amount.', 1;

    -- same release limit rule as sp_nt_ReleasePayment, plus every bucket must belong to this supplier
    IF EXISTS (
        SELECT 1 FROM @alloc a
        LEFT JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
        LEFT JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
        OUTER APPLY (SELECT ISNULL(SUM(pad.amount), 0) AS paid FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = a.invoice_alloc_sno) p
        WHERE iad.invoice_alloc_sno IS NULL OR i.vendor_sno <> @v OR a.amount > (iad.release_amount - p.paid) + 0.01
    )
        THROW 55013, 'An allocation is unknown, belongs to another supplier, or exceeds its unpaid release amount.', 1;

    DECLARE @gross DECIMAL(18,2) = (SELECT SUM(amount) FROM @alloc);

    -- per-invoice TDS
    DECLARE @inv TABLE (invoice_sno INT PRIMARY KEY, gross DECIMAL(18,2), base DECIMAL(18,2), section VARCHAR(10),
                        taxable DECIMAL(18,2) NULL, rate DECIMAL(6,3) NULL, tds DECIMAL(18,2) NOT NULL DEFAULT 0, fy INT NULL);
    INSERT INTO @inv (invoice_sno, gross, base, section)
    SELECT i.invoice_sno, SUM(a.amount),
           ROUND(SUM(a.amount) * CASE WHEN ISNULL(i.invoice_amount, 0) > 0 AND i.taxable_value IS NOT NULL THEN i.taxable_value / i.invoice_amount ELSE 1 END, 2),
           i.tds_section_code
    FROM @alloc a JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    GROUP BY i.invoice_sno, i.invoice_amount, i.taxable_value, i.tds_section_code;

    -- optional per-invoice TDS section chosen on the payment screen: tds_overrides [{ invoice_sno, section }] ('' = no TDS)
    DECLARE @tdsJson NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.tds_overrides');
    IF @tdsJson IS NOT NULL
        UPDATE x SET section = NULLIF(UPPER(LTRIM(RTRIM(JSON_VALUE(o.value, '$.section')))), '')
        FROM @inv x JOIN OPENJSON(@tdsJson) o ON x.invoice_sno = TRY_CAST(JSON_VALUE(o.value, '$.invoice_sno') AS INT);

    -- GSTR-2B hold: a GST-registered supplier's invoice cannot be paid until 2B has matched it, unless Accounts released the hold (sql/45)
    IF EXISTS (SELECT 1 FROM @inv x JOIN dbo.invoice_info inv ON inv.invoice_sno = x.invoice_sno
               JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = inv.vendor_sno
               WHERE LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(inv.itc_status, '') NOT IN ('Eligible', 'Ineligible') AND ISNULL(inv.payment_hold_override, 'N') <> 'Y')
    BEGIN
        DECLARE @held NVARCHAR(400) = (SELECT STRING_AGG(inv.invoice_no, ', ') FROM @inv x JOIN dbo.invoice_info inv ON inv.invoice_sno = x.invoice_sno
               JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = inv.vendor_sno
               WHERE LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(inv.itc_status, '') NOT IN ('Eligible', 'Ineligible') AND ISNULL(inv.payment_hold_override, 'N') <> 'Y');
        DECLARE @heldMsg NVARCHAR(500) = N'Payment held until the invoice appears in GSTR-2B (or Accounts releases the hold): ' + @held;
        THROW 55021, @heldMsg, 1;
    END

    IF @applyTds = 1
    BEGIN
        DECLARE @isno INT, @ibase DECIMAL(18,2), @isec VARCHAR(10), @t DECIMAL(18,2), @r DECIMAL(6,3), @tx DECIMAL(18,2), @fy INT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT invoice_sno, base, section FROM @inv WHERE section IS NOT NULL ORDER BY invoice_sno;
        OPEN cur; FETCH NEXT FROM cur INTO @isno, @ibase, @isec;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @xp DECIMAL(18,2) = ISNULL((SELECT SUM(base) FROM @inv WHERE section = @isec AND taxable IS NOT NULL), 0),
                    @xd DECIMAL(18,2) = ISNULL((SELECT SUM(taxable) FROM @inv WHERE section = @isec AND taxable IS NOT NULL), 0);
            EXEC dbo.sp_nt_CalcTDS @vendor_sno = @v, @section = @isec, @base = @ibase, @on_date = @pdate,
                 @extra_prior = @xp, @extra_deducted = @xd, @tds = @t OUTPUT, @rate = @r OUTPUT, @taxable = @tx OUTPUT, @fy = @fy OUTPUT;
            UPDATE @inv SET taxable = @tx, rate = @r, tds = @t, fy = @fy WHERE invoice_sno = @isno;
            FETCH NEXT FROM cur INTO @isno, @ibase, @isec;
        END
        CLOSE cur; DEALLOCATE cur;
    END
    DECLARE @tds DECIMAL(18,2) = ISNULL((SELECT SUM(tds) FROM @inv), 0);

    -- advances
    DECLARE @adv TABLE (advance_sno INT, amount DECIMAL(18,2));
    IF @advJson IS NOT NULL
        INSERT INTO @adv SELECT TRY_CAST(JSON_VALUE(value, '$.advance_sno') AS INT), TRY_CAST(JSON_VALUE(value, '$.amount') AS DECIMAL(18,2)) FROM OPENJSON(@advJson);
    IF EXISTS (SELECT 1 FROM @adv a LEFT JOIN dbo.nt_supplier_advance_payment s ON s.advance_sno = a.advance_sno AND s.vendor_sno = @v AND s.is_active = 'Y'
               WHERE a.amount IS NULL OR a.amount <= 0 OR s.advance_sno IS NULL OR a.amount > s.amount - s.adjusted_amount + 0.01)
        THROW 55014, 'An advance is unknown, belongs to another supplier, or the amount exceeds its balance.', 1;
    DECLARE @advTotal DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @adv), 0);
    IF @advTotal > @gross - @tds + 0.01 THROW 55015, 'Advance adjusted cannot exceed the amount payable after TDS.', 1;

    -- notes
    DECLARE @notes TABLE (note_type VARCHAR(6), note_sno INT, amount DECIMAL(18,2));
    IF @noteJson IS NOT NULL
        INSERT INTO @notes (note_type, note_sno) SELECT UPPER(JSON_VALUE(value, '$.type')), TRY_CAST(JSON_VALUE(value, '$.note_sno') AS INT) FROM OPENJSON(@noteJson);
    IF EXISTS (SELECT 1 FROM @notes WHERE note_type NOT IN ('DEBIT', 'CREDIT') OR note_sno IS NULL) THROW 55016, 'Each note needs type DEBIT or CREDIT and a note_sno.', 1;
    UPDATE n SET amount = d.total_amount FROM @notes n JOIN dbo.debit_note_basic_info d ON d.debit_note_sno = n.note_sno AND d.vendor_sno = @v AND d.is_active = 'Y'
        WHERE n.note_type = 'DEBIT' AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'DEBIT_NOTE' AND pa.ref_sno = n.note_sno);
    UPDATE n SET amount = c.total_amount FROM @notes n JOIN dbo.credit_note_basic_info c ON c.credit_note_sno = n.note_sno AND c.vendor_sno = @v AND c.is_active = 'Y'
        WHERE n.note_type = 'CREDIT' AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'CREDIT_NOTE' AND pa.ref_sno = n.note_sno);
    IF EXISTS (SELECT 1 FROM @notes WHERE amount IS NULL) THROW 55017, 'A note is unknown, belongs to another supplier, or was already adjusted.', 1;
    DECLARE @dn DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @notes WHERE note_type = 'DEBIT'), 0),
            @cn DECIMAL(18,2) = ISNULL((SELECT SUM(amount) FROM @notes WHERE note_type = 'CREDIT'), 0);

    DECLARE @net DECIMAL(18,2) = @gross - @tds - @advTotal - @dn + @cn;
    IF @net < 0 THROW 55018, 'Debit notes and advances exceed what is payable - nothing to pay.', 1;

    IF @preview = 1
    BEGIN
        SELECT @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted, @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid;
        SELECT i.invoice_sno, inv.invoice_no, i.gross, i.base AS taxable_base, i.section AS tds_section, i.rate AS tds_rate_pct, i.taxable AS tds_taxable, i.tds AS tds_amount
        FROM @inv i JOIN dbo.invoice_info inv ON inv.invoice_sno = i.invoice_sno;
        RETURN;
    END

    DECLARE @h_pay INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUPPLIER_PAYABLE'),
            @h_tds INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'TDS_PAYABLE'),
            @h_adv INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'ADVANCE_SUPPLIER'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK'),
            @h_dn INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'DN_ADJ');
    IF @h_pay IS NULL OR @h_tds IS NULL OR @h_adv IS NULL OR @h_bank IS NULL OR @h_dn IS NULL THROW 55019, 'System account heads are missing.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(payment_no, 6) AS INT)), 0) + 1 FROM dbo.payment_info WITH (UPDLOCK, HOLDLOCK) WHERE payment_no LIKE 'PAY-' + @year + '-%';
        DECLARE @pno VARCHAR(30) = 'PAY-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6), @psno INT;

        INSERT INTO dbo.payment_info (payment_no, vendor_sno, payment_date, amount, mode, bank_account, reference_no, status, remarks, is_active, created_by, created_date,
                                      gross_amount, tds_amount, advance_adjusted, note_adjusted, net_paid)
        VALUES (@pno, @v, @pdate, @gross, @mode, @bank, @ref, 'Processed', @rem, 'Y', @by, GETDATE(), @gross, @tds, @advTotal, @dn - @cn, @net);
        SET @psno = SCOPE_IDENTITY();

        INSERT INTO dbo.payment_allocation_details (payment_sno, invoice_alloc_sno, amount, created_date) SELECT @psno, invoice_alloc_sno, amount, GETDATE() FROM @alloc;
        IF @tdsJson IS NOT NULL   -- remember the chosen section on the invoice for its later part-payments
            UPDATE inv SET tds_section_code = x.section FROM dbo.invoice_info inv JOIN @inv x ON x.invoice_sno = inv.invoice_sno;

        -- TDS: track every payment base (even when TDS = 0) so annual thresholds work
        INSERT INTO dbo.tds_deduction (vendor_sno, section_code, fin_year, invoice_sno, payment_sno, base_amount, base_deducted, rate_pct, tds_amount)
        SELECT @v, section, fy, invoice_sno, @psno, base, ISNULL(taxable, 0), ISNULL(rate, 0), tds FROM @inv WHERE section IS NOT NULL AND fy IS NOT NULL;
        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, invoice_sno, amount) SELECT @psno, 'TDS', NULL, invoice_sno, tds FROM @inv WHERE tds > 0;

        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, amount) SELECT @psno, 'ADVANCE', advance_sno, amount FROM @adv;
        UPDATE s SET adjusted_amount = s.adjusted_amount + a.amount FROM dbo.nt_supplier_advance_payment s JOIN @adv a ON a.advance_sno = s.advance_sno;
        INSERT INTO dbo.payment_adjustment (payment_sno, adj_type, ref_sno, amount) SELECT @psno, CASE note_type WHEN 'DEBIT' THEN 'DEBIT_NOTE' ELSE 'CREDIT_NOTE' END, note_sno, amount FROM @notes;

        -- journal
        DECLARE @com INT, @div INT, @brn INT, @dept INT, @j INT;
        SELECT TOP 1 @com = i.com_sno, @div = i.div_sno, @brn = i.brn_sno, @dept = i.dept_sno
        FROM @inv x JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno;
        INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
        VALUES (@pdate, 'PAYMENT', @psno, N'Payment ' + @pno, @com, @div, @brn, @dept, @by);
        SET @j = SCOPE_IDENTITY();
        UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;

        DECLARE @jl TABLE (head_sno INT, debit DECIMAL(18,2), credit DECIMAL(18,2));
        INSERT INTO @jl VALUES (@h_pay, @gross + @cn, 0);
        IF @tds > 0      INSERT INTO @jl VALUES (@h_tds, 0, @tds);
        IF @advTotal > 0 INSERT INTO @jl VALUES (@h_adv, 0, @advTotal);
        IF @net > 0      INSERT INTO @jl VALUES (@h_bank, 0, @net);
        IF @dn > 0       INSERT INTO @jl VALUES (@h_dn, 0, @dn);
        IF @cn > 0       BEGIN INSERT INTO @jl VALUES (@h_dn, @cn, 0); INSERT INTO @jl VALUES (@h_pay, 0, @cn); END
        IF (SELECT SUM(debit) - SUM(credit) FROM @jl) <> 0 THROW 55020, 'Payment journal is not balanced.', 1;
        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) SELECT @j, head_sno, debit, credit, @v FROM @jl;
        UPDATE dbo.payment_info SET journal_sno = @j WHERE payment_sno = @psno;

        COMMIT TRANSACTION;
        SELECT @psno AS payment_sno, @pno AS payment_no, @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted,
               @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid, @j AS journal_sno, 'SUCCESS' AS result;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO
