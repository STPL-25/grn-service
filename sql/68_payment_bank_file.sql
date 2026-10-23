-- ============================================================
-- 68_payment_bank_file.sql   (Non_trade_Dev ONLY, re-runnable)
--
-- The payment file of a Payment Run becomes the bank upload file (request 2026-10-22): one comma separated line per NEFT / RTGS
-- transfer, 28 positions, no header, named <prefix>_<client code>_<client code><DDMM>.<seq> (SPACETEX_SPA311_SPA3112210.100).
-- It replaces the generic CSV of sql/65. The line layout is written by grn-service (src/paymentnet/paymentFile.js); this script
-- gives it what it needs from the database:
--
--   * SENDER   the company's bank account the run is paid from, kept in the Payment Bank master (backend-stpl sql/138): its client
--              code and file name prefix (the file name), its alert e-mail (the e-mail position of every line). A run picks one of the
--              company's accounts (default: the company's default, or its only one). A run whose payments need no file (cheque, cash,
--              DD, portal, adjustments) needs no account.
--   * RECEIVER the supplier's account number, IFSC, bank and branch - snapshotted from the supplier KYC into payment_batch_item
--              when the run is made (unchanged since sql/65).
--
-- payment_batch remembers the sender it was paid from (payment_bank_sno + a copy of what the file used), so a later edit of the
-- master never changes an old run, and the file can be written again identically.
-- The file name and its sequence number are decided here, under the run's lock, so two runs never get the same name.
--
--   sp_nt_GetPaymentSenders    the company's active accounts for the run screen (last 4 digits only)
--   sp_nt_CreatePaymentBatch   = sql/65 + sender resolution + file name + sender snapshot      (error codes 56111-56114 added)
--   sp_nt_GetPaymentBatches    = sql/65 + the sender columns
--
-- Needs backend-stpl sql/138 first. Apply: cd grn-service && node sql/run_sql.mjs sql/68_payment_bank_file.sql
-- Rollback: sql/backups/payment_bank_file_2026-10-22_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.payment_bank_master', 'U') IS NULL
    THROW 56200, N'Run backend-stpl sql/138 first: the Payment Bank master does not exist.', 1;
GO

-- ── 1. what a run remembers about its sender ───────────────────────────────
IF COL_LENGTH('dbo.payment_batch', 'payment_bank_sno')   IS NULL ALTER TABLE dbo.payment_batch ADD payment_bank_sno INT NULL;
IF COL_LENGTH('dbo.payment_batch', 'file_type')          IS NULL ALTER TABLE dbo.payment_batch ADD file_type VARCHAR(20) NULL;
IF COL_LENGTH('dbo.payment_batch', 'sender_client_code') IS NULL ALTER TABLE dbo.payment_batch ADD sender_client_code VARCHAR(30) NULL;
IF COL_LENGTH('dbo.payment_batch', 'sender_alert_email') IS NULL ALTER TABLE dbo.payment_batch ADD sender_alert_email VARCHAR(100) NULL;
IF COL_LENGTH('dbo.payment_batch', 'sender_bank_name')   IS NULL ALTER TABLE dbo.payment_batch ADD sender_bank_name NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.payment_batch', 'sender_account_no')  IS NULL ALTER TABLE dbo.payment_batch ADD sender_account_no VARCHAR(30) NULL;
GO

-- ── 2. the company's bank accounts, for the run screen ──────────────────────
-- @jsonInput: { com_sno?, hierarchy? } -> active accounts, the company's default first. Only the last 4 digits of the account go out.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentSenders
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT), @h NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    SELECT m.payment_bank_sno, m.com_sno, c.com_name, m.profile_name, m.bank_name, m.branch_name, m.ac_holder_name,
           RIGHT(m.ac_number, 4) AS ac_last4, m.ifsc, m.file_type, m.client_code, m.alert_email, m.is_default
    FROM dbo.payment_bank_master m
    LEFT JOIN dbo.company_master c ON c.com_sno = m.com_sno
    WHERE m.is_active = 'Y' AND (@com IS NULL OR m.com_sno = @com)
      AND (@h IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@h) WITH (com_sno INT '$.com_sno') x WHERE x.com_sno = m.com_sno))
    ORDER BY m.com_sno, CASE WHEN m.is_default = 'Y' THEN 0 ELSE 1 END, m.payment_bank_sno;
END
GO

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

        IF (SELECT COUNT(DISTINCT ISNULL(pi.com_sno, -1)) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno) > 1
            THROW 56105, 'A payment file covers one company at a time - untick the payments of the other company.', 1;

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

        -- the sender: which of the company's bank accounts this run is paid from. Needed only when the file will hold a bank
        -- transfer (a NEFT / RTGS payment to a supplier's account); a run of cheques, cash, portal payments and adjustments has no file.
        DECLARE @com INT = (SELECT MIN(pi.com_sno) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno);
        DECLARE @file_lines INT = (
            SELECT COUNT(*) FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno
            LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
            WHERE ISNULL(pi.net_paid, pi.amount) > 0 AND ISNULL(k.pay_via_portal, 'N') <> 'Y' AND UPPER(pi.mode) IN ('NEFT', 'RTGS'));
        DECLARE @pb INT = NULL, @pb_type VARCHAR(20), @pb_prefix VARCHAR(30), @pb_client VARCHAR(30), @pb_email VARCHAR(100), @pb_bank NVARCHAR(100), @pb_acno VARCHAR(30);
        IF @file_lines > 0
        BEGIN
            IF @bank_sno IS NOT NULL
            BEGIN
                SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master WHERE payment_bank_sno = @bank_sno AND is_active = 'Y' AND com_sno = @com;
                IF @pb IS NULL THROW 56113, N'The chosen bank account is not available for this company (or it was switched off). Choose another.', 1;
            END
            ELSE
            BEGIN
                SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com AND is_default = 'Y';
                IF @pb IS NULL
                BEGIN
                    DECLARE @n_banks INT = (SELECT COUNT(*) FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com);
                    IF @n_banks = 0 THROW 56111, N'No bank account to pay from is set up for this company. Add one in Masters > Payment Bank, then run again.', 1;
                    IF @n_banks > 1 THROW 56112, N'This company has more than one bank account to pay from - choose which one this run is paid from.', 1;
                    SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com;
                END
            END
            SELECT @pb_type = file_type, @pb_prefix = file_prefix, @pb_client = client_code, @pb_email = alert_email, @pb_bank = bank_name, @pb_acno = ac_number
            FROM dbo.payment_bank_master WHERE payment_bank_sno = @pb;
            IF @pb_type <> 'BANK_UPLOAD' THROW 56114, N'This bank account has a payment file type the run cannot write yet.', 1;
        END

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(batch_no, 6) AS INT)), 0) + 1 FROM dbo.payment_batch WITH (UPDLOCK, HOLDLOCK) WHERE batch_no LIKE 'PB-' + @year + '-%';
        SET @bno = 'PB-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        -- the file name: <prefix>_<client>_<client><DDMM>.<seq>. The sequence counts the files of that name made before, from 100.
        DECLARE @fname VARCHAR(200) = NULL;
        IF @pb IS NOT NULL
        BEGIN
            DECLARE @base VARCHAR(120) = @pb_prefix + '_' + @pb_client + '_' + @pb_client
                                         + RIGHT('0' + CAST(DAY(@vdate) AS VARCHAR(2)), 2) + RIGHT('0' + CAST(MONTH(@vdate) AS VARCHAR(2)), 2);
            DECLARE @fseq INT = ISNULL((SELECT MAX(TRY_CAST(SUBSTRING(file_name, LEN(@base) + 2, 10) AS INT))
                                        FROM dbo.payment_batch WITH (UPDLOCK, HOLDLOCK)
                                        WHERE LEFT(file_name, LEN(@base) + 1) = @base + '.'), 99) + 1;
            SET @fname = @base + '.' + CAST(@fseq AS VARCHAR(10));
        END

        INSERT INTO dbo.payment_batch (batch_no, batch_date, com_sno, fund_plan_amount, total_amount, item_count, status, created_by,
                                       file_name, payment_bank_sno, file_type, sender_client_code, sender_alert_email, sender_bank_name, sender_account_no)
        SELECT @bno, @vdate, MIN(pi.com_sno), @fund, @total, COUNT(*), 'Generated', @by,
               @fname, @pb, @pb_type, @pb_client, @pb_email, @pb_bank, @pb_acno
        FROM @sel s JOIN dbo.payment_info pi ON pi.payment_sno = s.payment_sno;
        SET @bsno = SCOPE_IDENTITY();

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

    SELECT b.batch_sno, b.batch_no, b.batch_date, b.com_sno, b.fund_plan_amount, b.total_amount, b.item_count, b.status, b.created_by,
           CONVERT(VARCHAR(30), b.created_at, 120) AS created_at,
           b.file_name, b.payment_bank_sno, b.file_type, b.sender_client_code, b.sender_alert_email, b.sender_bank_name, b.sender_account_no
    FROM dbo.payment_batch b WHERE b.batch_sno = @bsno;
    SELECT i.batch_item_sno, i.batch_sno, i.payment_sno, p.payment_no, i.line_no, i.vendor_sno, i.vendor_name, i.supp_code, i.vendor_email, i.amount, i.mode, i.debit_account,
           i.channel, i.beneficiary_name, i.account_no, i.ifsc, i.bank_name, i.branch_name, i.invoice_nos, i.supplier_invoice_nos, i.msme_label, i.narration,
           p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
    WHERE i.batch_sno = @bsno ORDER BY i.line_no;
END
GO

-- ── 3b. keep the file with its run ──────────────────────────────────────────
-- sql/65 read the content with JSON_VALUE, which returns NULL for a value over 4000 characters - a bank file of about 26 lines or
-- more was silently not stored. OPENJSON ... WITH (NVARCHAR(MAX)) has no such limit.
CREATE OR ALTER PROCEDURE dbo.sp_nt_SetPaymentBatchFile
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE b SET file_name = j.file_name, file_content = j.file_content
    FROM dbo.payment_batch b
    CROSS APPLY OPENJSON(@jsonInput) WITH (batch_sno INT '$.batch_sno', file_name VARCHAR(200) '$.file_name', file_content NVARCHAR(MAX) '$.file_content') j
    WHERE b.batch_sno = j.batch_sno;
END
GO

-- ── 4. past payment runs ────────────────────────────────────────────────────
-- Past payment runs.  @jsonInput: { batch_sno?, hierarchy?, with_file?, limit? }
-- -> batches (file_content only when with_file and one batch), items of that batch
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentBatches
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bsno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.batch_sno') AS INT),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @withFile BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.with_file') IN ('1', 'true') THEN 1 ELSE 0 END,
            @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 30);

    SELECT TOP (@limit) b.batch_sno, b.batch_no, b.batch_date, b.com_sno, c.com_name, b.fund_plan_amount, b.total_amount, b.item_count, b.status,
           b.file_name, CASE WHEN @withFile = 1 AND @bsno IS NOT NULL THEN b.file_content END AS file_content,
           CAST(CASE WHEN b.file_content IS NULL THEN 0 ELSE 1 END AS BIT) AS has_file,
           b.file_type, b.payment_bank_sno, pb.profile_name AS sender_name, b.sender_bank_name, RIGHT(b.sender_account_no, 4) AS sender_ac_last4,
           b.sender_client_code, b.sender_alert_email,
           b.created_by, CONVERT(VARCHAR(30), b.created_at, 120) AS created_at
    FROM dbo.payment_batch b
    LEFT JOIN dbo.company_master c ON c.com_sno = b.com_sno
    LEFT JOIN dbo.payment_bank_master pb ON pb.payment_bank_sno = b.payment_bank_sno
    WHERE (@bsno IS NULL OR b.batch_sno = @bsno)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno') h WHERE h.com_sno = b.com_sno))
    ORDER BY b.batch_sno DESC;

    SELECT i.batch_item_sno, i.batch_sno, i.payment_sno, p.payment_no, i.line_no, i.vendor_sno, i.vendor_name, i.supp_code, i.vendor_email, i.amount, i.mode, i.debit_account,
           i.channel, i.beneficiary_name, i.account_no, i.ifsc, i.bank_name, i.branch_name, i.invoice_nos, i.supplier_invoice_nos, i.msme_label, i.narration,
           p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
    WHERE @bsno IS NOT NULL AND i.batch_sno = @bsno
    ORDER BY i.line_no;
END
GO
