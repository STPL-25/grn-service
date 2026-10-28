-- ============================================================
-- 69_portal_payments_and_tds_records.sql   (Non_trade_Dev ONLY, re-runnable)
--
-- Suppliers whose KYC says pay_via_portal = 'Y' are paid on their own portal (UPI, card, ...): no bank file, no run.
--   * sp_nt_RecordPortalPayment  after the payment is approved and paid on the portal, the transaction is recorded: how (UPI / Credit Card /
--     Debit Card / Net Banking / Wallet / Other), transaction id and date, amount paid and the discount (paid + discount = the net amount).
--     The payment becomes Processed and its journal is posted (discount credited to Purchases / Consumables Expense).
--   * sp_nt_GetPortalPayments    what was recorded
--   * sp_nt_GetTdsRecords        TDS deducted per invoice: invoice, supplier (deductee), company + TAN (deductor), section, rate, base, amount
--   * sp_nt_CreatePaymentBatch   = sql/68 + refuses a portal supplier's payment (error 56115)
-- Needs sql/68. Rollback: sql/backups/portal_payments_2026-10-23_ROLLBACK.sql
-- ============================================================
GO

-- ── 1. what was paid on the portal ──────────────────────────────────────────
IF OBJECT_ID('dbo.payment_portal_txn', 'U') IS NULL
CREATE TABLE dbo.payment_portal_txn (
    txn_sno          INT IDENTITY(1,1) PRIMARY KEY,
    payment_sno      INT           NOT NULL,
    portal_name      NVARCHAR(100) NULL,           -- the supplier's portal when it was paid (copy)
    txn_mode         VARCHAR(20)   NOT NULL,       -- UPI / Credit Card / Debit Card / Net Banking / Wallet / Other
    txn_id           VARCHAR(100)  NOT NULL,
    txn_date         DATE          NOT NULL,
    amount_paid      DECIMAL(18,2) NOT NULL,       -- what left the company's account
    discount_amount  DECIMAL(18,2) NOT NULL CONSTRAINT DF_payment_portal_txn_disc DEFAULT 0,   -- portal discount / cashback: amount_paid + discount = the payment's net amount
    remarks          NVARCHAR(500) NULL,
    recorded_by      VARCHAR(30)   NULL,
    recorded_at      DATETIME      NOT NULL CONSTRAINT DF_payment_portal_txn_at DEFAULT GETDATE(),
    CONSTRAINT FK_payment_portal_txn_payment FOREIGN KEY (payment_sno) REFERENCES dbo.payment_info (payment_sno)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_portal_txn_payment' AND object_id = OBJECT_ID('dbo.payment_portal_txn'))
    CREATE UNIQUE INDEX UX_payment_portal_txn_payment ON dbo.payment_portal_txn (payment_sno);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_portal_txn_id' AND object_id = OBJECT_ID('dbo.payment_portal_txn'))
    CREATE UNIQUE INDEX UX_payment_portal_txn_id ON dbo.payment_portal_txn (txn_mode, txn_id);
GO

-- ── 2. record a payment made on the supplier's portal ───────────────────────
-- @jsonInput: { payment_sno, txn_mode, txn_id, txn_date?, amount_paid, discount_amount?, remarks?, recorded_by, hierarchy? }
-- The payment must be 'Approved', belong to a supplier with pay_via_portal = 'Y', and amount_paid + discount_amount = its net amount.
-- It becomes 'Processed' (no run, no file) and its journal is posted like a run's: Dr Supplier Payable, Cr TDS / advances / notes,
-- Cr Bank for what was paid and Cr Purchases / Consumables Expense for the discount.
CREATE OR ALTER PROCEDURE dbo.sp_nt_RecordPortalPayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT),
            @mode VARCHAR(20) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.txn_mode'))), ''),
            @tid VARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.txn_id'))), ''),
            @tdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.txn_date') AS DATE), CAST(GETDATE() AS DATE)),
            @paid DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.amount_paid') AS DECIMAL(18,2)),
            @disc DECIMAL(18,2) = ISNULL(TRY_CAST(NULLIF(JSON_VALUE(@jsonInput, '$.discount_amount'), '') AS DECIMAL(18,2)), 0),
            @rem NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.recorded_by'),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @by IS NULL THROW 56300, 'recorded_by is required.', 1;
    IF @pay IS NULL THROW 56301, 'Payment not found.', 1;
    SET @mode = CASE UPPER(@mode) WHEN 'UPI' THEN 'UPI' WHEN 'CREDIT CARD' THEN 'Credit Card' WHEN 'DEBIT CARD' THEN 'Debit Card'
                                  WHEN 'NET BANKING' THEN 'Net Banking' WHEN 'WALLET' THEN 'Wallet' WHEN 'OTHER' THEN 'Other' END;
    IF @mode IS NULL THROW 56302, 'Choose how it was paid: UPI, Credit Card, Debit Card, Net Banking, Wallet or Other.', 1;
    IF @tid IS NULL THROW 56303, 'The transaction id is required.', 1;
    IF @tid LIKE '%[^A-Za-z0-9._/-]%' COLLATE Latin1_General_BIN2 THROW 56303, 'The transaction id can only have letters, digits and . _ / -', 1;
    IF @paid IS NULL OR @paid < 0 THROW 56304, 'Enter the amount paid.', 1;
    IF @disc < 0 THROW 56304, 'The discount cannot be negative.', 1;
    IF @tdate > CAST(GETDATE() AS DATE) THROW 56305, 'The transaction date cannot be in the future.', 1;

    DECLARE @net DECIMAL(18,2), @status VARCHAR(20), @batch INT, @vendor INT, @portal CHAR(1), @pname NVARCHAR(100), @pn VARCHAR(30);
    DECLARE @gross DECIMAL(18,2), @tds DECIMAL(18,2), @adv DECIMAL(18,2), @dn DECIMAL(18,2), @cn DECIMAL(18,2),
            @jc INT, @jd INT, @jb INT, @jdp INT, @j INT;
    DECLARE @h_pay INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUPPLIER_PAYABLE'),
            @h_tds INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'TDS_PAYABLE'),
            @h_adv INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'ADVANCE_SUPPLIER'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK'),
            @h_dn INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'DN_ADJ'),
            @h_disc INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'PURCHASE_EXPENSE');
    IF @h_pay IS NULL OR @h_tds IS NULL OR @h_adv IS NULL OR @h_bank IS NULL OR @h_dn IS NULL OR @h_disc IS NULL THROW 56108, 'System account heads are missing.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @net = ISNULL(p.net_paid, p.amount), @status = p.status, @batch = p.batch_sno, @vendor = p.vendor_sno, @pn = p.payment_no,
               @gross = ISNULL(p.gross_amount, p.amount), @tds = ISNULL(p.tds_amount, 0), @adv = ISNULL(p.advance_adjusted, 0),
               @jc = p.com_sno, @jd = p.div_sno, @jb = p.brn_sno, @jdp = p.dept_sno
        FROM dbo.payment_info p WITH (UPDLOCK, HOLDLOCK) WHERE p.payment_sno = @pay AND p.is_active = 'Y';
        IF @status IS NULL THROW 56301, 'Payment not found.', 1;
        IF @hier IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM dbo.payment_info pi WHERE pi.payment_sno = @pay AND EXISTS (
                SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                WHERE h.com_sno = pi.com_sno AND (h.div_sno IS NULL OR h.div_sno = pi.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = pi.brn_sno)))
            THROW 56110, 'You do not have access to this payment.', 1;
        IF @status <> 'Approved' OR @batch IS NOT NULL THROW 56306, 'This payment is not waiting for payment (it is not approved, or it was already paid).', 1;
        SELECT @portal = k.pay_via_portal, @pname = k.payment_portal_name FROM dbo.kyc_basic_info k WHERE k.kyc_basic_info_sno = @vendor;
        IF ISNULL(@portal, 'N') <> 'Y' THROW 56307, 'This supplier is not paid on a portal - pay it in a payment run.', 1;
        IF @net <= 0 THROW 56307, 'Nothing to pay out on this payment - the advances and notes settle it; pay it in a payment run.', 1;
        IF ABS(@paid + @disc - @net) > 0.005
        BEGIN
            DECLARE @mm NVARCHAR(300) = N'Amount paid + discount must equal the net amount of ' + FORMAT(@net, 'N2') + N' (now ' + FORMAT(@paid + @disc, 'N2') + N').';
            THROW 56308, @mm, 1;
        END
        IF EXISTS (SELECT 1 FROM dbo.payment_portal_txn WHERE txn_mode = @mode AND txn_id = @tid)
            THROW 56309, 'This transaction id is already recorded against another payment.', 1;

        INSERT INTO dbo.payment_portal_txn (payment_sno, portal_name, txn_mode, txn_id, txn_date, amount_paid, discount_amount, remarks, recorded_by)
        VALUES (@pay, @pname, @mode, @tid, @tdate, @paid, @disc, @rem, @by);

        UPDATE dbo.payment_info SET status = 'Processed', processed_at = GETDATE(), payment_date = @tdate, reference_no = @tid,
               modified_by = @by, modified_date = GETDATE()
        WHERE payment_sno = @pay;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
        VALUES (@pay, 'PAID', @by, LEFT(N'Paid on ' + ISNULL(@pname, N'the supplier portal') + N' by ' + @mode + N', transaction ' + @tid
                                         + CASE WHEN @disc > 0 THEN N', discount ' + FORMAT(@disc, 'N2') ELSE N'' END, 500));

        SELECT @dn = ISNULL(SUM(CASE WHEN adj_type = 'DEBIT_NOTE' THEN amount END), 0), @cn = ISNULL(SUM(CASE WHEN adj_type = 'CREDIT_NOTE' THEN amount END), 0)
        FROM dbo.payment_adjustment WHERE payment_sno = @pay;
        DECLARE @jl TABLE (head_sno INT, debit DECIMAL(18,2), credit DECIMAL(18,2));
        INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
        VALUES (@tdate, 'PAYMENT', @pay, N'Payment ' + @pn + N' (portal)', @jc, @jd, @jb, @jdp, @by);
        SET @j = SCOPE_IDENTITY();
        UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;
        INSERT INTO @jl VALUES (@h_pay, @gross + @cn, 0);
        IF @tds > 0  INSERT INTO @jl VALUES (@h_tds, 0, @tds);
        IF @adv > 0  INSERT INTO @jl VALUES (@h_adv, 0, @adv);
        IF @paid > 0 INSERT INTO @jl VALUES (@h_bank, 0, @paid);
        IF @disc > 0 INSERT INTO @jl VALUES (@h_disc, 0, @disc);
        IF @dn > 0   INSERT INTO @jl VALUES (@h_dn, 0, @dn);
        IF @cn > 0   BEGIN INSERT INTO @jl VALUES (@h_dn, @cn, 0); INSERT INTO @jl VALUES (@h_pay, 0, @cn); END
        IF (SELECT SUM(debit) - SUM(credit) FROM @jl) <> 0 THROW 56109, 'Payment journal is not balanced.', 1;
        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) SELECT @j, head_sno, debit, credit, @vendor FROM @jl;
        UPDATE dbo.payment_info SET journal_sno = @j WHERE payment_sno = @pay;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT t.txn_sno, t.payment_sno, @pn AS payment_no, @vendor AS vendor_sno, @net AS net_paid, t.txn_mode, t.txn_id, t.txn_date, t.amount_paid, t.discount_amount,
           @jc AS com_sno, @jd AS div_sno, @jb AS brn_sno, @jdp AS dept_sno
    FROM dbo.payment_portal_txn t WHERE t.payment_sno = @pay;
END
GO

-- ── 3. portal payments already recorded ─────────────────────────────────────
-- @jsonInput: { hierarchy?, limit? } -> newest first
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPortalPayments
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'), @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 50);
    SELECT TOP (@limit) t.txn_sno, t.payment_sno, p.payment_no, k.company_name AS vendor_name, k.supp_code, t.portal_name, t.txn_mode, t.txn_id, t.txn_date,
           ISNULL(p.net_paid, p.amount) AS net_paid, t.amount_paid, t.discount_amount, t.remarks, t.recorded_by, CONVERT(VARCHAR(30), t.recorded_at, 120) AS recorded_at,
           p.com_sno, c.com_name
    FROM dbo.payment_portal_txn t
    JOIN dbo.payment_info p ON p.payment_sno = t.payment_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    WHERE @hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                   WHERE h.com_sno = p.com_sno AND (h.div_sno IS NULL OR h.div_sno = p.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = p.brn_sno))
    ORDER BY t.txn_sno DESC;
END
GO

-- ── 4. TDS deducted, one record per invoice ─────────────────────────────────
-- @jsonInput: { hierarchy?, vendor_sno?, limit? } -> the TDS taken on each invoice of a saved payment: which invoice, which supplier
-- (the deductee), which company deducted it (the deductor, with its TAN), section, rate, base and amount. A rejected / cancelled payment
-- has no rows (its deduction is released).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetTdsRecords
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'), @vendor INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 500);
    SELECT TOP (@limit) d.deduction_sno, d.payment_sno, p.payment_no, p.status AS payment_status, p.payment_date,
           d.invoice_sno, i.invoice_no, i.vendor_invoice_no AS supplier_invoice_no,
           d.vendor_sno, k.company_name AS vendor_name, k.supp_code, k.pan_no AS vendor_pan,
           p.com_sno, c.com_name AS deductor_name, a.add_tan AS deductor_tan, a.add_pan AS deductor_pan,
           d.section_code, s.description AS section_description, d.fin_year, d.base_amount, d.base_deducted, d.rate_pct, d.tds_amount,
           CONVERT(VARCHAR(30), d.created_at, 120) AS created_at
    FROM dbo.tds_deduction d
    JOIN dbo.payment_info p ON p.payment_sno = d.payment_sno
    LEFT JOIN dbo.invoice_info i ON i.invoice_sno = d.invoice_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = d.vendor_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    LEFT JOIN dbo.address_master a ON a.add_sno = c.add_sno
    LEFT JOIN dbo.tds_section_master s ON s.section_code = d.section_code
    WHERE (@vendor IS NULL OR d.vendor_sno = @vendor)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = p.com_sno AND (h.div_sno IS NULL OR h.div_sno = p.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = p.brn_sno)))
    ORDER BY d.deduction_sno DESC;
END
GO

-- ── 5. a run refuses a portal supplier's payment ──
-- ── 3. the run: pay what today's fund covers ────────────────────────────────
-- @jsonInput: { payment_snos: [..in the order they should appear in the file], fund_plan_amount, created_by, payment_date?, hierarchy?,
--               payment_bank_sno? }   (payment_bank_sno: the account to pay from; default = the company's default / only account)
-- Marks the payments 'Processed', snapshots the payee bank details, and posts each payment's journal. -> batch row, items.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreatePaymentBatch
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @list NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.payment_snos'),
            @fund DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.fund_plan_amount') AS DECIMAL(18,2)),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by'),
            @vdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE), CAST(GETDATE() AS DATE)),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @bank_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_bank_sno') AS INT);
    IF @by IS NULL THROW 56100, 'created_by is required.', 1;

    DECLARE @raw TABLE (line_no INT, payment_sno INT);
    INSERT INTO @raw SELECT TRY_CAST(j.[key] AS INT) + 1, TRY_CAST(j.value AS INT) FROM OPENJSON(@list) j;
    IF NOT EXISTS (SELECT 1 FROM @raw) OR EXISTS (SELECT 1 FROM @raw WHERE payment_sno IS NULL) THROW 56101, 'Select at least one payment.', 1;
    DECLARE @sel TABLE (line_no INT, payment_sno INT PRIMARY KEY);
    INSERT INTO @sel SELECT MIN(line_no), payment_sno FROM @raw GROUP BY payment_sno;
    IF @fund IS NULL OR @fund <= 0 THROW 56103, 'Enter today''s fund plan before proceeding.', 1;

    DECLARE @h_pay INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'SUPPLIER_PAYABLE'),
            @h_tds INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'TDS_PAYABLE'),
            @h_adv INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'ADVANCE_SUPPLIER'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK'),
            @h_dn INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'DN_ADJ');
    IF @h_pay IS NULL OR @h_tds IS NULL OR @h_adv IS NULL OR @h_bank IS NULL OR @h_dn IS NULL THROW 56108, 'System account heads are missing.', 1;

    DECLARE @bsno INT, @bno VARCHAR(30);
    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'pay_run_batch', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 56107, 'Another payment run is being created right now - please try again in a moment.', 1;

        DECLARE @bad NVARCHAR(500) = (
            SELECT STRING_AGG(ISNULL(pi.payment_no, CAST(s.payment_sno AS VARCHAR(12))), ', ')
            FROM @sel s LEFT JOIN dbo.payment_info pi WITH (UPDLOCK, HOLDLOCK) ON pi.payment_sno = s.payment_sno
            WHERE pi.payment_sno IS NULL OR pi.is_active <> 'Y' OR pi.status <> 'Approved' OR pi.batch_sno IS NOT NULL);
        IF @bad IS NOT NULL
        BEGIN
            DECLARE @badMsg NVARCHAR(700) = N'No longer waiting for payment (already paid, cancelled, or not approved): ' + @bad + N'. Refresh the list.';
            THROW 56102, @badMsg, 1;
        END

        IF @hier IS NOT NULL AND EXISTS (
            SELECT 1 FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            WHERE NOT EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                              WHERE h.com_sno = pi.com_sno AND (h.div_sno IS NULL OR h.div_sno = pi.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = pi.brn_sno)))
            THROW 56110, 'You do not have access to one or more of the selected payments.', 1;

        IF (SELECT COUNT(*) FROM (SELECT DISTINCT ISNULL(pi.com_sno, -1) com_sno, ISNULL(pi.div_sno, -1) div_sno, ISNULL(pi.brn_sno, -1) brn_sno
                                  FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno) scopes) > 1
            THROW 56105, 'A payment file covers one company, division and branch at a time - untick payments from the other scope.', 1;

        DECLARE @total DECIMAL(18,2) = (SELECT SUM(ISNULL(pi.net_paid, pi.amount)) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno);
        IF @total > @fund + 0.005
        BEGIN
            DECLARE @fundMsg NVARCHAR(300) = N'The selected payments total ' + FORMAT(@total, 'N2') + N', more than the fund plan of ' + FORMAT(@fund, 'N2') + N'.';
            THROW 56104, @fundMsg, 1;
        END

        -- a bank transfer needs the supplier's bank account
        DECLARE @nobank NVARCHAR(500) = (
            SELECT STRING_AGG(ISNULL(k.company_name, '?') + ' (' + pi.payment_no + ')', ', ')
            FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
            WHERE ISNULL(pi.net_paid, pi.amount) > 0 AND ISNULL(k.pay_via_portal, 'N') <> 'Y' AND UPPER(pi.mode) NOT IN ('CHEQUE', 'CASH', 'DD')
              AND NOT EXISTS (SELECT 1 FROM dbo.kyc_bank_info x WHERE x.kyc_basic_info_sno = pi.vendor_sno AND ISNULL(x.is_active, 'Y') = 'Y'
                              AND x.ac_number IS NOT NULL AND NULLIF(LTRIM(RTRIM(x.ifsc)), '') IS NOT NULL));
        IF @nobank IS NOT NULL
        BEGIN
            DECLARE @nobankMsg NVARCHAR(700) = N'Supplier bank details (account number and IFSC) are missing for: ' + @nobank + N'. Update the supplier KYC, or untick them.';
            THROW 56106, @nobankMsg, 1;
        END

        -- a supplier paid on their portal is paid there and then recorded (sp_nt_RecordPortalPayment, sql/69) - never put in a run or a file
        DECLARE @portal NVARCHAR(500) = (
            SELECT STRING_AGG(ISNULL(k.company_name, '?') + ' (' + pi.payment_no + ')', ', ')
            FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
            WHERE k.pay_via_portal = 'Y' AND ISNULL(pi.net_paid, pi.amount) > 0);
        IF @portal IS NOT NULL
        BEGIN
            DECLARE @portalMsg NVARCHAR(700) = N'Paid on the supplier''s portal, not in a run: ' + @portal + N'. Pay it there and record the transaction, or untick it.';
            THROW 56115, @portalMsg, 1;
        END

        -- the sender: which of the company's bank accounts this run is paid from. Needed only when the file will hold a bank
        -- transfer (a NEFT / RTGS payment to a supplier's account); a run of cheques, cash, portal payments and adjustments has no file.
        DECLARE @com INT = (SELECT MIN(pi.com_sno) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno),
                @div INT = (SELECT MIN(pi.div_sno) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno),
                @brn INT = (SELECT MIN(pi.brn_sno) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno);
        DECLARE @file_lines INT = (
            SELECT COUNT(*) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
            WHERE ISNULL(pi.net_paid, pi.amount) > 0 AND ISNULL(k.pay_via_portal, 'N') <> 'Y' AND UPPER(pi.mode) IN ('NEFT', 'RTGS'));
        DECLARE @pb INT = NULL, @pb_type VARCHAR(20), @pb_prefix VARCHAR(30), @pb_client VARCHAR(30), @pb_file_code INT,
                @pb_email VARCHAR(100), @pb_bank NVARCHAR(100), @pb_acno VARCHAR(30);
        IF @file_lines > 0
        BEGIN
            IF @bank_sno IS NOT NULL
            BEGIN
                SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master
                WHERE payment_bank_sno = @bank_sno AND is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn;
                IF @pb IS NULL THROW 56113, N'The chosen bank account is not available for this company/division/branch (or it was switched off). Choose another.', 1;
            END
            ELSE
            BEGIN
                SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master
                WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn AND is_default = 'Y';
                IF @pb IS NULL
                BEGIN
                    DECLARE @n_banks INT = (SELECT COUNT(*) FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn);
                    IF @n_banks = 0 THROW 56111, N'No bank account is set up for this company/division/branch. Add one in Masters > Payment Bank, then run again.', 1;
                    IF @n_banks > 1 THROW 56112, N'This company/division/branch has more than one bank account - choose which one this run is paid from.', 1;
                    SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn;
                END
            END
            SELECT @pb_type = file_type, @pb_prefix = file_prefix, @pb_client = client_code, @pb_file_code = file_code,
                   @pb_email = alert_email, @pb_bank = bank_name, @pb_acno = ac_number
            FROM dbo.payment_bank_master WHERE payment_bank_sno = @pb;
            IF @pb_type <> 'BANK_UPLOAD' THROW 56114, N'This bank account has a payment file type the run cannot write yet.', 1;
        END

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(batch_no, 6) AS INT)), 0) + 1 FROM dbo.payment_batch WITH (UPDLOCK, HOLDLOCK) WHERE batch_no LIKE 'PB-' + @year + '-%';
        SET @bno = 'PB-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        -- The file name: <prefix>_<client>_<client><DDMM>.<seq>. Reserve its number in the daily register while the run lock
        -- is held. The unique constraint is a second concurrency guard, independent of payment_batch/file-name parsing.
        DECLARE @fname VARCHAR(200) = NULL, @fseq INT = NULL, @file_creation_sno BIGINT = NULL;
        IF @pb IS NOT NULL
        BEGIN
            DECLARE @base VARCHAR(120) = @pb_prefix + '_' + @pb_client + '_' + @pb_client
                                         + RIGHT('0' + CAST(DAY(@vdate) AS VARCHAR(2)), 2) + RIGHT('0' + CAST(MONTH(@vdate) AS VARCHAR(2)), 2);
            SELECT @fseq = ISNULL(MAX(file_no) + 1, @pb_file_code)
            FROM dbo.payment_file_creation_no WITH (UPDLOCK, HOLDLOCK)
            WHERE file_prefix = @pb_prefix AND client_code = @pb_client AND file_date = @vdate;
            IF @fseq < @pb_file_code SET @fseq = @pb_file_code;
            SET @fname = @base + '.' + CAST(@fseq AS VARCHAR(10));
            INSERT INTO dbo.payment_file_creation_no (payment_bank_sno, file_prefix, client_code, file_date, file_no, file_name, created_by)
            VALUES (@pb, @pb_prefix, @pb_client, @vdate, @fseq, @fname, @by);
            SET @file_creation_sno = SCOPE_IDENTITY();
        END

        INSERT INTO dbo.payment_batch (batch_no, batch_date, com_sno, div_sno, brn_sno, fund_plan_amount, total_amount, item_count, status, created_by,
                                       file_name, file_no, payment_bank_sno, file_type, sender_client_code, sender_alert_email, sender_bank_name, sender_account_no)
        SELECT @bno, @vdate, MIN(pi.com_sno), MIN(pi.div_sno), MIN(pi.brn_sno), @fund, @total, COUNT(*), 'Generated', @by,
               @fname, @fseq, @pb, @pb_type, @pb_client, @pb_email, @pb_bank, @pb_acno
        FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno;
        SET @bsno = SCOPE_IDENTITY();
        IF @file_creation_sno IS NOT NULL
            UPDATE dbo.payment_file_creation_no SET batch_sno = @bsno WHERE payment_file_creation_sno = @file_creation_sno;

        INSERT INTO dbo.payment_batch_item (batch_sno, payment_sno, line_no, vendor_sno, vendor_name, supp_code, vendor_email, amount, mode, debit_account, channel,
                                            beneficiary_name, account_no, ifsc, bank_name, branch_name, invoice_nos, supplier_invoice_nos, msme_label, narration)
        SELECT @bsno, pi.payment_sno, ROW_NUMBER() OVER (ORDER BY s.line_no), pi.vendor_sno, k.company_name, k.supp_code, k.email,
               ISNULL(pi.net_paid, pi.amount), pi.mode, pi.bank_account, ch.channel,
               CASE WHEN ch.channel = 'BANK' THEN bk.ac_holder_name END, CASE WHEN ch.channel = 'BANK' THEN CAST(bk.ac_number AS VARCHAR(40)) END,
               CASE WHEN ch.channel = 'BANK' THEN bk.ifsc END, CASE WHEN ch.channel = 'BANK' THEN bk.bank_name END, CASE WHEN ch.channel = 'BANK' THEN bk.bank_branch_name END,
               inv.invoice_nos, inv.supplier_invoice_nos,
               CASE WHEN ISNULL(k.is_msme_avail, 'N') = 'Y' OR NULLIF(LTRIM(RTRIM(k.msme_type)), '') IS NOT NULL THEN ISNULL(NULLIF(LTRIM(RTRIM(k.msme_type)), ''), 'MSME') END,
               LEFT(pi.payment_no + ISNULL(' ' + inv.first_supplier_invoice, ''), 60)
        FROM @sel s
        JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
        LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
        OUTER APPLY (SELECT TOP 1 x.ac_holder_name, x.ac_number, x.ifsc, x.bank_name, x.bank_branch_name
                     FROM dbo.kyc_bank_info x
                     WHERE x.kyc_basic_info_sno = pi.vendor_sno AND ISNULL(x.is_active, 'Y') = 'Y'
                       AND x.ac_number IS NOT NULL AND NULLIF(LTRIM(RTRIM(x.ifsc)), '') IS NOT NULL   -- same test as the 56106 guard: the account snapshotted is one the guard accepted
                     ORDER BY CASE WHEN x.is_primary = 'Y' THEN 0 ELSE 1 END, x.kyc_address_sno DESC) bk
        CROSS APPLY (SELECT CASE WHEN ISNULL(pi.net_paid, pi.amount) = 0 THEN 'ADJUSTMENT'
                                 WHEN k.pay_via_portal = 'Y' THEN 'PORTAL'
                                 WHEN UPPER(pi.mode) IN ('CHEQUE', 'CASH', 'DD') THEN 'MANUAL'
                                 ELSE 'BANK' END AS channel) ch
        OUTER APPLY (SELECT STRING_AGG(l.invoice_no, ', ') WITHIN GROUP (ORDER BY l.invoice_sno) AS invoice_nos,
                            STRING_AGG(NULLIF(LTRIM(RTRIM(l.supplier_invoice_no)), ''), ', ') WITHIN GROUP (ORDER BY l.invoice_sno) AS supplier_invoice_nos,
                            MIN(NULLIF(LTRIM(RTRIM(l.supplier_invoice_no)), '')) AS first_supplier_invoice
                     FROM dbo.fn_nt_PaymentLines(pi.payment_sno) l) inv;

        UPDATE pi SET status = 'Processed', batch_sno = @bsno, processed_at = GETDATE(), payment_date = @vdate, modified_by = @by, modified_date = GETDATE()
        FROM dbo.payment_info pi JOIN @sel s ON s.payment_sno = pi.payment_sno;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
        SELECT s.payment_sno, 'PAID', @by, N'Paid in ' + @bno FROM @sel s;

        -- journals: the same entries the release used to post
        DECLARE @jl TABLE (head_sno INT, debit DECIMAL(18,2), credit DECIMAL(18,2));
        DECLARE @p INT, @pn VARCHAR(30), @pv INT, @gross DECIMAL(18,2), @tds DECIMAL(18,2), @adv DECIMAL(18,2), @net DECIMAL(18,2), @dn DECIMAL(18,2), @cn DECIMAL(18,2),
                @jc INT, @jd INT, @jb INT, @jdp INT, @j INT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT payment_sno FROM @sel ORDER BY line_no;
        OPEN cur; FETCH NEXT FROM cur INTO @p;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @pn = payment_no, @pv = vendor_sno, @gross = ISNULL(gross_amount, amount), @tds = ISNULL(tds_amount, 0), @adv = ISNULL(advance_adjusted, 0),
                   @net = ISNULL(net_paid, amount), @jc = com_sno, @jd = div_sno, @jb = brn_sno, @jdp = dept_sno
            FROM dbo.payment_info WHERE payment_sno = @p;
            SELECT @dn = ISNULL(SUM(CASE WHEN adj_type = 'DEBIT_NOTE' THEN amount END), 0), @cn = ISNULL(SUM(CASE WHEN adj_type = 'CREDIT_NOTE' THEN amount END), 0)
            FROM dbo.payment_adjustment WHERE payment_sno = @p;

            INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, created_by)
            VALUES (@vdate, 'PAYMENT', @p, N'Payment ' + @pn, @jc, @jd, @jb, @jdp, @by);
            SET @j = SCOPE_IDENTITY();
            UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;

            DELETE FROM @jl;
            INSERT INTO @jl VALUES (@h_pay, @gross + @cn, 0);
            IF @tds > 0 INSERT INTO @jl VALUES (@h_tds, 0, @tds);
            IF @adv > 0 INSERT INTO @jl VALUES (@h_adv, 0, @adv);
            IF @net > 0 INSERT INTO @jl VALUES (@h_bank, 0, @net);
            IF @dn > 0  INSERT INTO @jl VALUES (@h_dn, 0, @dn);
            IF @cn > 0  BEGIN INSERT INTO @jl VALUES (@h_dn, @cn, 0); INSERT INTO @jl VALUES (@h_pay, 0, @cn); END
            IF (SELECT SUM(debit) - SUM(credit) FROM @jl) <> 0 THROW 56109, 'Payment journal is not balanced.', 1;
            INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno) SELECT @j, head_sno, debit, credit, @pv FROM @jl;
            UPDATE dbo.payment_info SET journal_sno = @j WHERE payment_sno = @p;

            FETCH NEXT FROM cur INTO @p;
        END
        CLOSE cur; DEALLOCATE cur;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT b.batch_sno, b.batch_no, b.batch_date, b.com_sno, b.div_sno, b.brn_sno, b.fund_plan_amount, b.total_amount, b.item_count, b.status, b.created_by,
           CONVERT(VARCHAR(30), b.created_at, 120) AS created_at,
           b.file_name, b.file_no, b.payment_bank_sno, b.file_type, b.sender_client_code, b.sender_alert_email, b.sender_bank_name, b.sender_account_no
    FROM dbo.payment_batch b WHERE b.batch_sno = @bsno;
    SELECT i.batch_item_sno, i.batch_sno, i.payment_sno, p.payment_no, i.line_no, i.vendor_sno, i.vendor_name, i.supp_code, i.vendor_email, i.amount, i.mode, i.debit_account,
           i.channel, i.beneficiary_name, i.account_no, i.ifsc, i.bank_name, i.branch_name, i.invoice_nos, i.supplier_invoice_nos, i.msme_label, i.narration,
           p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
    WHERE i.batch_sno = @bsno ORDER BY i.line_no;
END
GO
