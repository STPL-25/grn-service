-- ============================================================
-- ROLLBACK of sql/82_statutory_payee_online_payment.sql (Non_trade_Dev)
--
-- Puts the statutory payee / run procedures back to how sql/73 left them (definitions copied from Non_trade_Dev on
-- 2026-11-03 before sql/82), drops sp_nt_RecordStatutoryOnlinePayment and the columns sql/82 added.
-- It REFUSES to run while an online payee or an online payment exists - those rows would lose their meaning. Switch such
-- payees back to a bank account (or remove them) first; an online payment already recorded cannot be undone by this script.
--
--   cd grn-service && node sql/run_sql.mjs sql/backups/statutory_payee_online_2026-11-03_ROLLBACK.sql
-- ============================================================
IF COL_LENGTH('dbo.statutory_payee', 'pay_via_portal') IS NOT NULL
   AND EXISTS (SELECT 1 FROM dbo.statutory_payee WHERE pay_via_portal = 'Y')
    THROW 57299, N'Rollback stopped: there are online payees. Change them to a bank account (or delete them) first.', 1;
GO
IF COL_LENGTH('dbo.statutory_batch', 'pay_channel') IS NOT NULL
   AND EXISTS (SELECT 1 FROM dbo.statutory_batch WHERE pay_channel = 'ONLINE')
    THROW 57299, N'Rollback stopped: online statutory payments are recorded (SO-...). They cannot be rolled back by this script.', 1;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_RecordStatutoryOnlinePayment;
GO
-- ── 2. payees ───────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStatutoryPayees
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kind VARCHAR(5) = NULLIF(JSON_VALUE(@jsonInput, '$.kind'), '');
    SELECT p.payee_sno, p.kind, p.payee_name, RIGHT(p.ac_number, 4) AS ac_last4, p.ac_number, p.ifsc, p.bank_name, p.branch_name, p.reference_no,
           p.pay_mode, p.com_sno, c.com_name, p.is_default, p.is_active
    FROM dbo.statutory_payee p LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    WHERE (@kind IS NULL OR p.kind = @kind)
    ORDER BY p.kind, p.is_active DESC, p.payee_name;
END
GO
-- { payee_sno?, kind, payee_name, ac_number, ifsc, bank_name?, branch_name?, reference_no?, pay_mode?, com_sno?, is_default?, is_active?, modified_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_UpsertStatutoryPayee
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payee_sno') AS INT),
            @kind VARCHAR(5) = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.kind'))), '')),
            @name NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payee_name'))), ''),
            @ac VARCHAR(40) = NULLIF(REPLACE(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ac_number'))), ' ', ''), ''),
            @ifsc VARCHAR(20) = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ifsc'))), '')),
            @bank NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.bank_name'))), ''),
            @branch NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.branch_name'))), ''),
            @ref NVARCHAR(40) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reference_no'))), ''),
            @mode VARCHAR(5) = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.pay_mode'))), ''), 'NEFT')),
            @com INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @def CHAR(1) = CASE WHEN JSON_VALUE(@jsonInput, '$.is_default') IN ('Y', 'true', '1') THEN 'Y' ELSE 'N' END,
            @act CHAR(1) = CASE WHEN JSON_VALUE(@jsonInput, '$.is_active') IN ('N', 'false', '0') THEN 'N' ELSE 'Y' END,
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.modified_by');
    IF @kind IS NULL OR @kind NOT IN ('TDS', 'GST', 'OTHER') THROW 57201, 'Choose TDS, GST or OTHER.', 1;
    IF @name IS NULL THROW 57202, 'Payee name is required.', 1;
    IF @ac IS NULL OR @ac NOT LIKE '%[0-9]%' THROW 57203, 'Account number is required.', 1;
    IF @ifsc IS NULL OR @ifsc NOT LIKE '[A-Z][A-Z][A-Z][A-Z]0[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]' THROW 57204, 'IFSC must be 11 characters, e.g. SBIN0000001.', 1;
    IF @mode NOT IN ('NEFT', 'RTGS') THROW 57205, 'Pay mode must be NEFT or RTGS.', 1;
    IF @id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.statutory_payee WHERE payee_sno = @id) THROW 57206, 'Payee not found.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        IF @def = 'Y' AND @act = 'Y'   -- one default per kind and company
            UPDATE dbo.statutory_payee SET is_default = 'N' WHERE kind = @kind AND ISNULL(com_sno, 0) = ISNULL(@com, 0) AND payee_sno <> ISNULL(@id, 0);
        IF @id IS NULL
        BEGIN
            INSERT INTO dbo.statutory_payee (kind, payee_name, ac_number, ifsc, bank_name, branch_name, reference_no, pay_mode, com_sno, is_default, is_active, created_by)
            VALUES (@kind, @name, @ac, @ifsc, @bank, @branch, @ref, @mode, @com, @def, @act, @by);
            SET @id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE dbo.statutory_payee SET kind = @kind, payee_name = @name, ac_number = @ac, ifsc = @ifsc, bank_name = @bank, branch_name = @branch,
                   reference_no = @ref, pay_mode = @mode, com_sno = @com, is_default = @def, is_active = @act, modified_by = @by, modified_at = GETDATE()
            WHERE payee_sno = @id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT @id AS payee_sno;
END
GO
-- ── 4. the register ─────────────────────────────────────────────────────────
-- { kind?, status?, hierarchy?, limit? } -> 1: amounts   2: GST held on supplier bills until GSTR-2B (shown on the GST tab, paid through Payment)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStatutoryPayables
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kind VARCHAR(5) = NULLIF(JSON_VALUE(@jsonInput, '$.kind'), ''), @status VARCHAR(10) = NULLIF(JSON_VALUE(@jsonInput, '$.status'), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'), @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 1000);
    BEGIN TRY EXEC dbo.sp_nt_SyncStatutoryTds; END TRY BEGIN CATCH END CATCH   -- a sync problem must never take the list down

    SELECT TOP (@limit) s.stat_sno, s.kind, s.source_type, s.com_sno, c.com_name, s.div_sno, s.brn_sno, s.head_name, s.ref_no, s.period_label, s.party_name,
           s.payment_sno, p.payment_no, s.payee_sno, y.payee_name, y.reference_no AS payee_ref, s.amount, s.due_date,
           CASE WHEN s.status = 'Open' AND s.due_date < CAST(GETDATE() AS DATE) THEN DATEDIFF(DAY, s.due_date, CAST(GETDATE() AS DATE)) END AS days_overdue,
           s.narration, s.status, s.batch_sno, b.batch_no, s.paid_at, s.cancel_reason, s.created_by, CONVERT(VARCHAR(30), s.created_at, 120) AS created_at
    FROM dbo.statutory_payable s
    LEFT JOIN dbo.company_master c ON c.com_sno = s.com_sno
    LEFT JOIN dbo.payment_info p ON p.payment_sno = s.payment_sno
    LEFT JOIN dbo.statutory_payee y ON y.payee_sno = s.payee_sno
    LEFT JOIN dbo.statutory_batch b ON b.batch_sno = s.batch_sno
    WHERE (@kind IS NULL OR s.kind = @kind) AND (@status IS NULL OR s.status = @status) AND s.status <> 'Cancelled'
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = s.com_sno AND (h.div_sno IS NULL OR h.div_sno = s.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = s.brn_sno)))
    ORDER BY CASE WHEN s.status = 'Open' THEN 0 ELSE 1 END, CASE WHEN s.due_date IS NULL THEN 1 ELSE 0 END, s.due_date, s.stat_sno DESC;

    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no AS supplier_invoice_no, k.company_name AS vendor_name,
           bp.gst_part AS gst_amount
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    CROSS APPLY dbo.fn_nt_BillPayable(iad.invoice_alloc_sno) bp
    WHERE @kind IN ('GST') AND iad.is_active = 'Y' AND bp.outstanding > 0.01 AND bp.on_hold_2b = 1 AND bp.taxable_known = 1 AND bp.gst_part > 0
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = i.com_sno AND (h.div_sno IS NULL OR h.div_sno = i.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = i.brn_sno)))
    ORDER BY i.invoice_date, i.invoice_sno;
END
GO
-- ── 5. the run ──────────────────────────────────────────────────────────────
-- { stat_snos: [..], payment_date?, payment_bank_sno?, created_by, hierarchy? } -> recordsets: batch, items
-- One kind, one company/division/branch per file. Needs a payee on every amount.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CreateStatutoryBatch
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @list NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.stat_snos'), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by'),
            @vdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_date') AS DATE), CAST(GETDATE() AS DATE)),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'), @bank_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_bank_sno') AS INT);
    IF @by IS NULL THROW 57230, 'created_by is required.', 1;
    DECLARE @sel TABLE (line_no INT, stat_sno INT PRIMARY KEY);
    INSERT INTO @sel SELECT MIN(TRY_CAST(j.[key] AS INT) + 1), TRY_CAST(j.value AS INT) FROM OPENJSON(@list) j GROUP BY TRY_CAST(j.value AS INT);
    IF NOT EXISTS (SELECT 1 FROM @sel) OR EXISTS (SELECT 1 FROM @sel WHERE stat_sno IS NULL) THROW 57231, 'Select at least one amount.', 1;

    DECLARE @h_tds INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'TDS_PAYABLE'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK');
    DECLARE @bsno INT, @bno VARCHAR(30);
    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'pay_run_batch', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;   -- the same lock as a supplier run: one file number at a time
        IF @lk < 0 THROW 57232, 'Another payment run is being created right now - please try again in a moment.', 1;

        DECLARE @bad NVARCHAR(500) = (SELECT STRING_AGG(CAST(x.stat_sno AS VARCHAR(12)), ', ')
            FROM @sel x LEFT JOIN dbo.statutory_payable s WITH (UPDLOCK, HOLDLOCK) ON s.stat_sno = x.stat_sno
            WHERE s.stat_sno IS NULL OR s.status <> 'Open');
        IF @bad IS NOT NULL
        BEGIN
            DECLARE @badMsg NVARCHAR(700) = N'No longer open (already paid or cancelled): ' + @bad + N'. Refresh the list.';
            THROW 57233, @badMsg, 1;
        END
        IF @hier IS NOT NULL AND EXISTS (
            SELECT 1 FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno
            WHERE NOT EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                              WHERE h.com_sno = s.com_sno AND (h.div_sno IS NULL OR h.div_sno = s.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = s.brn_sno)))
            THROW 57234, 'You do not have access to one or more of the selected amounts.', 1;
        IF (SELECT COUNT(DISTINCT s.kind) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno) > 1
            THROW 57235, 'A statutory file holds one kind at a time (TDS, GST or other) - pay each from its own tab.', 1;
        IF (SELECT COUNT(*) FROM (SELECT DISTINCT ISNULL(s.com_sno, -1) c, ISNULL(s.div_sno, -1) d, ISNULL(s.brn_sno, -1) b
                                  FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno) q) > 1
            THROW 57236, 'A payment file covers one company, division and branch at a time - untick amounts from the other scope.', 1;

        -- every amount needs its payee's bank account: the one chosen on it, else the kind's default for the company
        DECLARE @res TABLE (stat_sno INT PRIMARY KEY, payee_sno INT NULL);
        INSERT INTO @res
        SELECT x.stat_sno, COALESCE(
            (SELECT y.payee_sno FROM dbo.statutory_payee y WHERE y.payee_sno = s.payee_sno AND y.is_active = 'Y'),
            (SELECT TOP 1 y.payee_sno FROM dbo.statutory_payee y WHERE y.kind = s.kind AND y.is_active = 'Y' AND (y.com_sno = s.com_sno OR y.com_sno IS NULL)
             ORDER BY CASE WHEN y.com_sno = s.com_sno THEN 0 ELSE 1 END, CASE WHEN y.is_default = 'Y' THEN 0 ELSE 1 END, y.payee_sno))
        FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno;
        IF EXISTS (SELECT 1 FROM @res WHERE payee_sno IS NULL)
            THROW 57237, N'No payee (bank account to pay) is set up for this kind. Add one under "Payees", then run again.', 1;

        DECLARE @kind VARCHAR(5) = (SELECT TOP 1 s.kind FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno),
                @com INT = (SELECT MIN(s.com_sno) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno),
                @div INT = (SELECT MIN(s.div_sno) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno),
                @brn INT = (SELECT MIN(s.brn_sno) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno),
                @total DECIMAL(18,2) = (SELECT SUM(s.amount) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno);

        -- the sender: which of the company's bank accounts pays (same rules as a supplier run)
        DECLARE @pb INT = NULL;
        IF @bank_sno IS NOT NULL
        BEGIN
            SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master WHERE payment_bank_sno = @bank_sno AND is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn;
            IF @pb IS NULL THROW 57238, N'The chosen bank account is not available for this company/division/branch (or it was switched off). Choose another.', 1;
        END
        ELSE
        BEGIN
            SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn AND is_default = 'Y';
            IF @pb IS NULL
            BEGIN
                DECLARE @n_banks INT = (SELECT COUNT(*) FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn);
                IF @n_banks = 0 THROW 57239, N'No bank account is set up for this company/division/branch. Add one in Masters > Payment Bank, then run again.', 1;
                IF @n_banks > 1 THROW 57240, N'This company/division/branch has more than one bank account - choose which one this run is paid from.', 1;
                SELECT @pb = payment_bank_sno FROM dbo.payment_bank_master WHERE is_active = 'Y' AND com_sno = @com AND div_sno = @div AND brn_sno = @brn;
            END
        END
        DECLARE @pb_type VARCHAR(20), @pb_prefix VARCHAR(30), @pb_client VARCHAR(30), @pb_file_code INT, @pb_bank NVARCHAR(100), @pb_acno VARCHAR(30);
        SELECT @pb_type = file_type, @pb_prefix = file_prefix, @pb_client = client_code, @pb_file_code = file_code, @pb_bank = bank_name, @pb_acno = ac_number
        FROM dbo.payment_bank_master WHERE payment_bank_sno = @pb;
        IF @pb_type <> 'BANK_UPLOAD' THROW 57241, N'This bank account has a payment file type the run cannot write yet.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(batch_no, 6) AS INT)), 0) + 1 FROM dbo.statutory_batch WITH (UPDLOCK, HOLDLOCK) WHERE batch_no LIKE 'SB-' + @year + '-%';
        SET @bno = 'SB-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        -- file name from the shared daily register so it never repeats a supplier run's name
        DECLARE @base VARCHAR(120) = @pb_prefix + '_' + @pb_client + '_' + @pb_client
                                     + RIGHT('0' + CAST(DAY(@vdate) AS VARCHAR(2)), 2) + RIGHT('0' + CAST(MONTH(@vdate) AS VARCHAR(2)), 2),
                @fseq INT, @fname VARCHAR(200), @fcs BIGINT;
        SELECT @fseq = ISNULL(MAX(file_no) + 1, @pb_file_code) FROM dbo.payment_file_creation_no WITH (UPDLOCK, HOLDLOCK)
        WHERE file_prefix = @pb_prefix AND client_code = @pb_client AND file_date = @vdate;
        IF @fseq < @pb_file_code SET @fseq = @pb_file_code;
        SET @fname = @base + '.' + CAST(@fseq AS VARCHAR(10));
        INSERT INTO dbo.payment_file_creation_no (payment_bank_sno, file_prefix, client_code, file_date, file_no, file_name, created_by)
        VALUES (@pb, @pb_prefix, @pb_client, @vdate, @fseq, @fname, @by);
        SET @fcs = SCOPE_IDENTITY();

        INSERT INTO dbo.statutory_batch (batch_no, batch_date, kind, com_sno, div_sno, brn_sno, total_amount, item_count, payment_bank_sno, file_creation_sno, file_name, file_no,
                                         file_type, sender_client_code, sender_bank_name, sender_account_no, created_by)
        VALUES (@bno, @vdate, @kind, @com, @div, @brn, @total, (SELECT COUNT(*) FROM @sel), @pb, @fcs, @fname, @fseq, @pb_type, @pb_client, @pb_bank, @pb_acno, @by);
        SET @bsno = SCOPE_IDENTITY();

        INSERT INTO dbo.statutory_batch_item (batch_sno, stat_sno, line_no, amount, mode, payee_name, account_no, ifsc, bank_name, branch_name, reference_no, head_name, period_label)
        SELECT @bsno, s.stat_sno, ROW_NUMBER() OVER (ORDER BY x.line_no), s.amount, y.pay_mode, y.payee_name, y.ac_number, y.ifsc, y.bank_name, y.branch_name,
               ISNULL(s.ref_no, y.reference_no), s.head_name, s.period_label
        FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno JOIN @res r ON r.stat_sno = s.stat_sno JOIN dbo.statutory_payee y ON y.payee_sno = r.payee_sno;

        UPDATE s SET status = 'Paid', batch_sno = @bsno, paid_at = GETDATE(), payee_sno = r.payee_sno
        FROM dbo.statutory_payable s JOIN @res r ON r.stat_sno = s.stat_sno;
        -- (the register's batch_sno stays NULL: it is for supplier runs; this file is linked from statutory_batch.file_creation_sno)

        -- TDS paid out: Dr TDS Payable / Cr Bank
        IF @kind = 'TDS'
        BEGIN
            IF @h_tds IS NULL OR @h_bank IS NULL THROW 57242, 'System account heads are missing.', 1;
            INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, created_by)
            VALUES (@vdate, 'STAT_BATCH', @bsno, N'TDS remitted ' + @bno, @com, @div, @brn, @by);
            DECLARE @j INT = SCOPE_IDENTITY();
            UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@j AS VARCHAR(6)), 6) WHERE journal_sno = @j;
            INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit) VALUES (@j, @h_tds, @total, 0), (@j, @h_bank, 0, @total);
            UPDATE dbo.statutory_batch SET journal_sno = @j WHERE batch_sno = @bsno;
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT * FROM dbo.statutory_batch WHERE batch_sno = @bsno;
    SELECT i.*, s.kind, s.com_sno, s.div_sno, s.brn_sno FROM dbo.statutory_batch_item i JOIN dbo.statutory_payable s ON s.stat_sno = i.stat_sno WHERE i.batch_sno = @bsno ORDER BY i.line_no;
END
GO
-- { batch_sno?, hierarchy?, with_file?, kind?, limit? } -> 1: batches   2: items (only for one batch)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStatutoryBatches
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bsno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.batch_sno') AS INT), @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @with BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.with_file') IN ('true', '1') THEN 1 ELSE 0 END, @kind VARCHAR(5) = NULLIF(JSON_VALUE(@jsonInput, '$.kind'), ''),
            @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 30);
    SELECT TOP (@limit) b.batch_sno, b.batch_no, b.batch_date, b.kind, b.com_sno, c.com_name, b.div_sno, b.brn_sno, b.total_amount, b.item_count, b.status, b.payment_bank_sno,
           b.file_name, b.file_no, b.file_type, CAST(CASE WHEN b.file_content IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS has_file,
           b.sender_client_code, b.sender_bank_name, b.sender_account_no, b.created_by, CONVERT(VARCHAR(30), b.created_at, 120) AS created_at,
           CASE WHEN @with = 1 THEN b.file_content END AS file_content
    FROM dbo.statutory_batch b LEFT JOIN dbo.company_master c ON c.com_sno = b.com_sno
    WHERE (@bsno IS NULL OR b.batch_sno = @bsno) AND (@kind IS NULL OR b.kind = @kind)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = b.com_sno AND (h.div_sno IS NULL OR h.div_sno = b.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno)))
    ORDER BY b.batch_sno DESC;

    SELECT i.*, s.kind, s.com_sno, s.div_sno, s.brn_sno
    FROM dbo.statutory_batch_item i JOIN dbo.statutory_payable s ON s.stat_sno = i.stat_sno
    WHERE @bsno IS NOT NULL AND i.batch_sno = @bsno ORDER BY i.line_no;
END
GO
-- columns and constraints
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_statutory_payee_channel') ALTER TABLE dbo.statutory_payee DROP CONSTRAINT CK_statutory_payee_channel;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_statutory_payee_pay_via_portal') ALTER TABLE dbo.statutory_payee DROP CONSTRAINT DF_statutory_payee_pay_via_portal;
GO
IF COL_LENGTH('dbo.statutory_payee', 'pay_via_portal') IS NOT NULL ALTER TABLE dbo.statutory_payee DROP COLUMN pay_via_portal;
IF COL_LENGTH('dbo.statutory_payee', 'payment_portal_name') IS NOT NULL ALTER TABLE dbo.statutory_payee DROP COLUMN payment_portal_name;
IF COL_LENGTH('dbo.statutory_payee', 'payment_portal_url') IS NOT NULL ALTER TABLE dbo.statutory_payee DROP COLUMN payment_portal_url;
IF COL_LENGTH('dbo.statutory_payee', 'payment_instructions') IS NOT NULL ALTER TABLE dbo.statutory_payee DROP COLUMN payment_instructions;
GO
ALTER TABLE dbo.statutory_payee ALTER COLUMN ac_number VARCHAR(40) NOT NULL;
ALTER TABLE dbo.statutory_payee ALTER COLUMN ifsc VARCHAR(20) NOT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_statutory_batch_online_txn') DROP INDEX UX_statutory_batch_online_txn ON dbo.statutory_batch;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_statutory_batch_pay_channel') ALTER TABLE dbo.statutory_batch DROP CONSTRAINT CK_statutory_batch_pay_channel;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = 'DF_statutory_batch_pay_channel') ALTER TABLE dbo.statutory_batch DROP CONSTRAINT DF_statutory_batch_pay_channel;
GO
IF COL_LENGTH('dbo.statutory_batch', 'pay_channel') IS NOT NULL ALTER TABLE dbo.statutory_batch DROP COLUMN pay_channel;
IF COL_LENGTH('dbo.statutory_batch', 'payee_sno') IS NOT NULL ALTER TABLE dbo.statutory_batch DROP COLUMN payee_sno;
IF COL_LENGTH('dbo.statutory_batch', 'portal_name') IS NOT NULL ALTER TABLE dbo.statutory_batch DROP COLUMN portal_name;
IF COL_LENGTH('dbo.statutory_batch', 'portal_url') IS NOT NULL ALTER TABLE dbo.statutory_batch DROP COLUMN portal_url;
IF COL_LENGTH('dbo.statutory_batch', 'txn_mode') IS NOT NULL ALTER TABLE dbo.statutory_batch DROP COLUMN txn_mode;
IF COL_LENGTH('dbo.statutory_batch', 'txn_id') IS NOT NULL ALTER TABLE dbo.statutory_batch DROP COLUMN txn_id;
IF COL_LENGTH('dbo.statutory_batch', 'txn_date') IS NOT NULL ALTER TABLE dbo.statutory_batch DROP COLUMN txn_date;
IF COL_LENGTH('dbo.statutory_batch', 'remarks') IS NOT NULL ALTER TABLE dbo.statutory_batch DROP COLUMN remarks;
GO
-- statutory_batch_item.mode stays VARCHAR(20): narrowing it back is not needed and could fail on data.
