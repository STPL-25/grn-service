-- ============================================================
-- 83_payment_reverse_file.sql   (Non_trade_Dev, re-runnable)
--
-- Payment Run > Payment history > a bank run > "Upload reverse file" (request 2026-11-03): the bank's answer to the upload file.
-- One line per transfer of the run, matched on the reference the upload file carried (<supplier id>-<payment no>, paymentFile.js):
--
--   PAID      the supplier was credited: the UTR / bank reference, debit date and credit time are kept on the run line.
--   PENDING   the bank is still working on it: kept as pending, a later reverse file settles it.
--   REJECTED  the bank refused it, or
--   RETURNED  the supplier's bank sent it back (also after an earlier PAID - a NEFT return arrives a day later):
--             the payment was NOT paid, so it goes back to Payment Run to be paid again -
--               * its journal (Dr Supplier payable / Cr Bank, TDS, advance, notes) is reversed: a new journal with the lines swapped,
--                 reverses_journal_sno = the old one, the old one marked 'Reversed' (sql/41 convention);
--               * payment_info goes back to 'Approved' with no batch, so it is listed on Make payment again with what it reserved
--                 (invoices, TDS, advances, notes) unchanged;
--               * the run line keeps the bank's reason and is marked returned_to_run = 'Y'.
--             Make payment shows it with the bank's reason (sp_nt_GetPaymentBankFailures) and lets its mode be changed before it is
--             paid again (sp_nt_ChangeFailedPaymentMode: NEFT / RTGS / cheque / DD / cash), or it can be cancelled as before.
--
-- A payment could be in only one run line (UX_payment_batch_item_payment, sql/65). That stays true for the lines that still count
-- (returned_to_run = 'N'); a line the bank returned no longer counts, so the payment can be in a new run. Filtered unique index.
--
--   payment_batch_item    + bank_status, utr_no, bank_ref_no, bank_debit_date, bank_credit_at, bank_reason_code, bank_reason,
--                           bank_updated_at, bank_updated_by, reverse_file_sno, reversal_journal_sno, returned_to_run
--   payment_reverse_file  NEW - each reverse file uploaded for a run (the file itself + what it changed)
--   payment_bank_event    NEW - every change of a run line's bank status (PAID -> RETURNED keeps both)
--   sp_nt_ApplyPaymentReverseFile    NEW - applies the matched lines (the matching itself is grn-service reverseFile.js)
--   sp_nt_GetPaymentBatches          + bank result per run and per line, the reverse files of a run
--   sp_nt_GetPaymentBankFailures     NEW - payments back in Payment Run because the bank did not pay them, with the reason
--   sp_nt_ChangeFailedPaymentMode    NEW - change how such a payment is paid before paying it again
--
-- Not touched: a TDS amount already moved to Statutory Payments (sql/73 syncs TDS of 'Processed' payments) stays there - the
-- deduction is the same when the payment is paid again. Unpaid GST (sql/75) is not affected.
--
-- Needs sql/65, sql/68, sql/70. Apply: cd grn-service && node sql/run_sql.mjs sql/83_payment_reverse_file.sql
-- Rollback: sql/backups/payment_reverse_file_2026-11-03_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.payment_batch_item', 'U') IS NULL OR COL_LENGTH('dbo.payment_batch', 'file_no') IS NULL OR OBJECT_ID('dbo.payment_batch_item_invoice', 'U') IS NULL
    THROW 56300, N'Run grn-service sql/65, sql/68 and sql/70 first.', 1;
GO

-- ── 1. the bank's answer on each run line ───────────────────────────────────
IF COL_LENGTH('dbo.payment_batch_item', 'bank_status') IS NULL
    ALTER TABLE dbo.payment_batch_item ADD
        bank_status          VARCHAR(10)   NULL CONSTRAINT CK_payment_batch_item_bank_status CHECK (bank_status IN ('PAID', 'PENDING', 'REJECTED', 'RETURNED')),
        utr_no               VARCHAR(40)   NULL,
        bank_ref_no          VARCHAR(40)   NULL,
        bank_debit_date      DATE          NULL,
        bank_credit_at       DATETIME      NULL,
        bank_reason_code     VARCHAR(20)   NULL,
        bank_reason          NVARCHAR(300) NULL,
        bank_updated_at      DATETIME      NULL,
        bank_updated_by      VARCHAR(30)   NULL,
        reverse_file_sno     INT           NULL,
        reversal_journal_sno INT           NULL,
        returned_to_run      CHAR(1)       NOT NULL CONSTRAINT DF_payment_batch_item_returned_to_run DEFAULT 'N'
                                           CONSTRAINT CK_payment_batch_item_returned_to_run CHECK (returned_to_run IN ('Y', 'N'));
GO

-- one counting run line per payment (was: one run line per payment, ever)
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_batch_item_payment' AND object_id = OBJECT_ID('dbo.payment_batch_item') AND has_filter = 0)
    DROP INDEX UX_payment_batch_item_payment ON dbo.payment_batch_item;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_batch_item_payment' AND object_id = OBJECT_ID('dbo.payment_batch_item'))
    CREATE UNIQUE INDEX UX_payment_batch_item_payment ON dbo.payment_batch_item (payment_sno) WHERE returned_to_run = 'N';
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_batch_item_returned' AND object_id = OBJECT_ID('dbo.payment_batch_item'))
    CREATE INDEX IX_payment_batch_item_returned ON dbo.payment_batch_item (payment_sno, bank_updated_at) WHERE returned_to_run = 'Y';
GO

IF OBJECT_ID('dbo.payment_reverse_file', 'U') IS NULL
CREATE TABLE dbo.payment_reverse_file (
    reverse_file_sno INT IDENTITY(1,1) CONSTRAINT PK_payment_reverse_file PRIMARY KEY,
    batch_sno        INT NOT NULL CONSTRAINT FK_payment_reverse_file_batch REFERENCES dbo.payment_batch (batch_sno),
    file_name        NVARCHAR(260) NOT NULL,
    file_content     NVARCHAR(MAX) NULL,
    line_count       INT NOT NULL DEFAULT 0,      -- lines of the file that belong to this run
    paid_count       INT NOT NULL DEFAULT 0,
    failed_count     INT NOT NULL DEFAULT 0,      -- rejected / returned -> back in Payment Run
    pending_count    INT NOT NULL DEFAULT 0,
    unchanged_count  INT NOT NULL DEFAULT 0,      -- the run line already had this answer, or a final one
    error_count      INT NOT NULL DEFAULT 0,
    unmatched_count  INT NOT NULL DEFAULT 0,      -- lines of the file no run line matched (counted by grn-service)
    uploaded_by      VARCHAR(30) NOT NULL,
    uploaded_at      DATETIME NOT NULL CONSTRAINT DF_payment_reverse_file_at DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_reverse_file_batch' AND object_id = OBJECT_ID('dbo.payment_reverse_file'))
    CREATE INDEX IX_payment_reverse_file_batch ON dbo.payment_reverse_file (batch_sno, uploaded_at);
GO

IF OBJECT_ID('dbo.payment_bank_event', 'U') IS NULL
CREATE TABLE dbo.payment_bank_event (
    event_sno        INT IDENTITY(1,1) CONSTRAINT PK_payment_bank_event PRIMARY KEY,
    batch_item_sno   INT NOT NULL CONSTRAINT FK_payment_bank_event_item REFERENCES dbo.payment_batch_item (batch_item_sno),
    reverse_file_sno INT NULL CONSTRAINT FK_payment_bank_event_file REFERENCES dbo.payment_reverse_file (reverse_file_sno),
    payment_sno      INT NOT NULL,
    old_status       VARCHAR(10) NULL,
    new_status       VARCHAR(10) NOT NULL,
    utr_no           VARCHAR(40) NULL,
    bank_reason_code VARCHAR(20) NULL,
    bank_reason      NVARCHAR(300) NULL,
    reversal_journal_sno INT NULL,
    created_by       VARCHAR(30) NOT NULL,
    created_at       DATETIME NOT NULL CONSTRAINT DF_payment_bank_event_at DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_bank_event_item' AND object_id = OBJECT_ID('dbo.payment_bank_event'))
    CREATE INDEX IX_payment_bank_event_item ON dbo.payment_bank_event (batch_item_sno, event_sno);
GO

-- ── 2. apply a reverse file ─────────────────────────────────────────────────
-- @jsonInput: { batch_sno, uploaded_by, file_name, file_content, hierarchy?, unmatched_count?,
--               lines: [{ batch_item_sno, line_no, status: PAID|PENDING|REJECTED|RETURNED, amount, utr_no?, bank_ref_no?,
--                         debit_date? 'yyyy-mm-dd', credit_at? 'yyyy-mm-dd hh:mm:ss', reason_code?, reason? }] }
-- grn-service matched each line of the file to a line of this run (reverseFile.js); this checks it again and applies it.
-- -> 1: the reverse file row with its counts   2: one row per line - what it was, what it is now, and what happened (result):
--       PAID | UPDATED (new UTR on a paid line) | PENDING | FAILED (back in Payment Run) | UNCHANGED | IGNORED (an older answer) | ERROR
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApplyPaymentReverseFile
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @bsno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.batch_sno') AS INT),
            @by VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.uploaded_by'))), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @unmatched INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.unmatched_count') AS INT), 0),
            @fname NVARCHAR(260), @content NVARCHAR(MAX);
    -- OPENJSON ... WITH: JSON_VALUE would cut the file at 4000 characters
    SELECT @fname = LEFT(NULLIF(LTRIM(RTRIM(f.file_name)), N''), 260), @content = f.file_content
    FROM OPENJSON(@jsonInput) WITH (file_name NVARCHAR(400) '$.file_name', file_content NVARCHAR(MAX) '$.file_content') f;

    IF @by IS NULL THROW 56301, 'uploaded_by is required.', 1;
    IF @bsno IS NULL OR NOT EXISTS (SELECT 1 FROM dbo.payment_batch WHERE batch_sno = @bsno) THROW 56302, 'Payment run not found.', 1;
    IF @hier IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM dbo.payment_batch b
        CROSS APPLY OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
        WHERE b.batch_sno = @bsno AND h.com_sno = b.com_sno AND (h.div_sno IS NULL OR h.div_sno = b.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno))
        THROW 56303, 'You do not have access to this payment run.', 1;
    IF @fname IS NULL SET @fname = N'reverse file';

    DECLARE @in TABLE (rn INT IDENTITY(1,1), batch_item_sno INT, line_no INT, status VARCHAR(10), amount DECIMAL(18,2), utr_no VARCHAR(40), bank_ref_no VARCHAR(40),
                       debit_date DATE, credit_at DATETIME, reason_code VARCHAR(20), reason NVARCHAR(300));
    INSERT INTO @in (batch_item_sno, line_no, status, amount, utr_no, bank_ref_no, debit_date, credit_at, reason_code, reason)
    SELECT TRY_CAST(j.batch_item_sno AS INT), TRY_CAST(j.line_no AS INT), LEFT(UPPER(LTRIM(RTRIM(j.status))), 10), TRY_CAST(j.amount AS DECIMAL(18,2)),
           LEFT(NULLIF(LTRIM(RTRIM(j.utr_no)), ''), 40), LEFT(NULLIF(LTRIM(RTRIM(j.bank_ref_no)), ''), 40),
           TRY_CAST(j.debit_date AS DATE), TRY_CONVERT(DATETIME, j.credit_at, 120),
           LEFT(NULLIF(LTRIM(RTRIM(j.reason_code)), ''), 20), LEFT(NULLIF(LTRIM(RTRIM(j.reason)), N''), 300)
    FROM OPENJSON(@jsonInput, '$.lines') WITH (
        batch_item_sno NVARCHAR(30) '$.batch_item_sno', line_no NVARCHAR(30) '$.line_no', status NVARCHAR(30) '$.status', amount NVARCHAR(40) '$.amount',
        utr_no NVARCHAR(100) '$.utr_no', bank_ref_no NVARCHAR(100) '$.bank_ref_no', debit_date NVARCHAR(30) '$.debit_date', credit_at NVARCHAR(30) '$.credit_at',
        reason_code NVARCHAR(100) '$.reason_code', reason NVARCHAR(1000) '$.reason') j;

    IF NOT EXISTS (SELECT 1 FROM @in) THROW 56304, 'The reverse file has no line for this payment run.', 1;
    IF EXISTS (SELECT 1 FROM @in WHERE batch_item_sno IS NULL OR status IS NULL OR status NOT IN ('PAID', 'PENDING', 'REJECTED', 'RETURNED'))
        THROW 56305, 'Every line needs a run line and a status of PAID, PENDING, REJECTED or RETURNED.', 1;
    IF EXISTS (SELECT batch_item_sno FROM @in GROUP BY batch_item_sno HAVING COUNT(*) > 1)
        THROW 56306, 'The same payment is in the reverse file more than once.', 1;
    IF EXISTS (SELECT 1 FROM @in x LEFT JOIN dbo.payment_batch_item i ON i.batch_item_sno = x.batch_item_sno AND i.batch_sno = @bsno WHERE i.batch_item_sno IS NULL)
        THROW 56307, 'A line of the reverse file is not a payment of this run.', 1;
    IF EXISTS (SELECT 1 FROM @in x JOIN dbo.payment_batch_item i ON i.batch_item_sno = x.batch_item_sno
               WHERE i.channel <> 'BANK' OR UPPER(ISNULL(i.mode, '')) NOT IN ('NEFT', 'RTGS'))
        THROW 56308, 'Only the NEFT / RTGS transfers of the bank file can have a bank answer.', 1;
    DECLARE @badAmt NVARCHAR(500) = (
        SELECT STRING_AGG(CAST(i.line_no AS VARCHAR(10)), ', ') FROM @in x JOIN dbo.payment_batch_item i ON i.batch_item_sno = x.batch_item_sno
        WHERE x.amount IS NULL OR ABS(x.amount - i.amount) > 0.004);
    IF @badAmt IS NOT NULL
    BEGIN
        DECLARE @badAmtMsg NVARCHAR(700) = N'The amount in the reverse file is not what the run sent, on line(s) ' + @badAmt + N'.';
        THROW 56309, @badAmtMsg, 1;
    END
    IF EXISTS (SELECT 1 FROM @in WHERE status = 'PAID' AND utr_no IS NULL AND bank_ref_no IS NULL)
        THROW 56310, 'A paid line needs its UTR (or the bank''s reference).', 1;

    DECLARE @res TABLE (batch_item_sno INT PRIMARY KEY, payment_sno INT, old_status VARCHAR(10), new_status VARCHAR(10), result VARCHAR(10), message NVARCHAR(400));
    DECLARE @bno VARCHAR(30) = (SELECT batch_no FROM dbo.payment_batch WHERE batch_sno = @bsno), @rf INT, @now DATETIME = GETDATE();

    BEGIN TRANSACTION;
    BEGIN TRY
        -- the same lock as making a run: a payment going back to Payment Run must not be picked by a run being made right now
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'pay_run_batch', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 56311, 'A payment run is being made right now - please upload the reverse file again in a moment.', 1;

        INSERT INTO dbo.payment_reverse_file (batch_sno, file_name, file_content, line_count, unmatched_count, uploaded_by)
        VALUES (@bsno, @fname, @content, (SELECT COUNT(*) FROM @in), @unmatched, @by);
        SET @rf = SCOPE_IDENTITY();

        DECLARE @rn INT = 1, @last INT = (SELECT MAX(rn) FROM @in),
                @bi INT, @st VARCHAR(10), @utr VARCHAR(40), @ref VARCHAR(40), @dd DATE, @ca DATETIME, @rc VARCHAR(20), @rs NVARCHAR(300),
                @cur VARCHAR(10), @curUtr VARCHAR(40), @p INT, @pstatus VARCHAR(20), @pbatch INT, @pno VARCHAR(30), @j INT, @rj INT, @result VARCHAR(10), @msg NVARCHAR(400);
        WHILE @rn <= @last
        BEGIN
            SELECT @bi = batch_item_sno, @st = status, @utr = utr_no, @ref = bank_ref_no, @dd = debit_date, @ca = credit_at, @rc = reason_code, @rs = reason
            FROM @in WHERE rn = @rn;
            SELECT @cur = i.bank_status, @curUtr = i.utr_no, @p = i.payment_sno FROM dbo.payment_batch_item i WITH (UPDLOCK) WHERE i.batch_item_sno = @bi;
            SELECT @pstatus = status, @pbatch = batch_sno, @pno = payment_no, @j = journal_sno FROM dbo.payment_info WITH (UPDLOCK) WHERE payment_sno = @p;
            SELECT @result = NULL, @msg = NULL, @rj = NULL;

            IF @st = 'PAID'
            BEGIN
                IF @cur IS NULL OR @cur = 'PENDING'
                BEGIN
                    UPDATE dbo.payment_batch_item
                    SET bank_status = 'PAID', utr_no = @utr, bank_ref_no = ISNULL(@ref, bank_ref_no), bank_debit_date = @dd, bank_credit_at = @ca,
                        bank_reason_code = NULL, bank_reason = NULL, bank_updated_at = @now, bank_updated_by = @by, reverse_file_sno = @rf
                    WHERE batch_item_sno = @bi;
                    INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
                    VALUES (@p, 'BANK_PAID', @by, LEFT(N'Bank paid it in ' + @bno + ISNULL(N' · UTR ' + @utr, N'') + ISNULL(N' · ref ' + @ref, N''), 500));
                    SELECT @result = 'PAID', @msg = N'Paid' + ISNULL(N' · UTR ' + @utr, N'');
                END
                ELSE IF @cur = 'PAID'
                BEGIN
                    IF @utr IS NOT NULL AND ISNULL(@curUtr, '') <> @utr
                    BEGIN
                        UPDATE dbo.payment_batch_item
                        SET utr_no = @utr, bank_ref_no = ISNULL(@ref, bank_ref_no), bank_debit_date = ISNULL(@dd, bank_debit_date), bank_credit_at = ISNULL(@ca, bank_credit_at),
                            bank_updated_at = @now, bank_updated_by = @by, reverse_file_sno = @rf
                        WHERE batch_item_sno = @bi;
                        SELECT @result = 'UPDATED', @msg = N'Already paid - UTR changed from ' + ISNULL(@curUtr, N'(none)') + N' to ' + @utr;
                    END
                    ELSE SELECT @result = 'UNCHANGED', @msg = N'Already marked paid';
                END
                ELSE SELECT @result = 'IGNORED', @msg = N'The bank had already ' + LOWER(@cur) + N' it, so it went back to Payment Run - this older answer is not used';
            END
            ELSE IF @st = 'PENDING'
            BEGIN
                IF @cur IS NULL
                BEGIN
                    UPDATE dbo.payment_batch_item
                    SET bank_status = 'PENDING', utr_no = ISNULL(@utr, utr_no), bank_ref_no = ISNULL(@ref, bank_ref_no), bank_debit_date = ISNULL(@dd, bank_debit_date),
                        bank_reason_code = @rc, bank_reason = @rs, bank_updated_at = @now, bank_updated_by = @by, reverse_file_sno = @rf
                    WHERE batch_item_sno = @bi;
                    SELECT @result = 'PENDING', @msg = N'Bank is still processing it';
                END
                ELSE IF @cur = 'PENDING' SELECT @result = 'UNCHANGED', @msg = N'Still pending at the bank';
                ELSE SELECT @result = 'IGNORED', @msg = N'The bank already answered ' + @cur + N' - this older answer is not used';
            END
            ELSE   -- REJECTED / RETURNED: not paid
            BEGIN
                IF @cur IN ('REJECTED', 'RETURNED') SELECT @result = 'UNCHANGED', @msg = N'Already back in Payment Run';
                ELSE IF @pstatus <> 'Processed' OR ISNULL(@pbatch, -1) <> @bsno
                    SELECT @result = 'IGNORED', @msg = N'The payment is no longer paid in this run (now ' + ISNULL(@pstatus, N'?') + N')';
                ELSE IF EXISTS (SELECT 1 FROM dbo.nt_supplier_advance_payment a WHERE a.payment_sno = @p AND a.is_active = 'Y' AND a.adjusted_amount > 0)
                    SELECT @result = 'ERROR', @msg = N'This payment created a supplier advance that a later payment already used - reverse that payment first';
                ELSE
                BEGIN
                    -- 1. reverse its journal (lines swapped), the old one is marked Reversed
                    IF @j IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.acct_journal WHERE journal_sno = @j AND status = 'Posted')
                    BEGIN
                        INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, dept_sno, status, reverses_journal_sno, created_by)
                        SELECT CAST(@now AS DATE), 'PAYMENT_REVERSAL', @p,
                               LEFT(N'Bank ' + LOWER(@st) + N' payment ' + @pno + N' (' + @bno + N')' + ISNULL(N': ' + @rs, N''), 300),
                               com_sno, div_sno, brn_sno, dept_sno, 'Posted', @j, @by
                        FROM dbo.acct_journal WHERE journal_sno = @j;
                        SET @rj = SCOPE_IDENTITY();
                        UPDATE dbo.acct_journal SET journal_no = 'JV-' + RIGHT('000000' + CAST(@rj AS VARCHAR(6)), 6) WHERE journal_sno = @rj;
                        INSERT INTO dbo.acct_journal_line (journal_sno, head_sno, debit, credit, vendor_sno, grn_item_sno, qty, subcat_sno, is_suspense)
                        SELECT @rj, head_sno, credit, debit, vendor_sno, grn_item_sno, qty, subcat_sno, is_suspense FROM dbo.acct_journal_line WHERE journal_sno = @j;
                        UPDATE dbo.acct_journal SET status = 'Reversed' WHERE journal_sno = @j;
                    END
                    -- 2. an advance this payment created (none is used yet - checked above) is not real either
                    UPDATE dbo.nt_supplier_advance_payment SET is_active = 'N' WHERE payment_sno = @p AND is_active = 'Y';
                    -- 3. back to Payment Run, with everything it reserved
                    UPDATE dbo.payment_info
                    SET status = 'Approved', batch_sno = NULL, processed_at = NULL, journal_sno = NULL, modified_by = @by, modified_date = @now
                    WHERE payment_sno = @p;
                    INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
                    VALUES (@p, 'BANK_FAILED', @by, LEFT(N'Bank ' + LOWER(@st) + N' it in ' + @bno + ISNULL(N' · ' + @rc, N'') + ISNULL(N' · ' + @rs, N'') + N'. Back in Payment Run.', 500));
                    UPDATE dbo.payment_batch_item
                    SET bank_status = @st, utr_no = ISNULL(@utr, utr_no), bank_ref_no = ISNULL(@ref, bank_ref_no), bank_debit_date = ISNULL(@dd, bank_debit_date),
                        bank_credit_at = ISNULL(@ca, bank_credit_at), bank_reason_code = @rc, bank_reason = @rs, bank_updated_at = @now, bank_updated_by = @by,
                        reverse_file_sno = @rf, reversal_journal_sno = @rj, returned_to_run = 'Y'
                    WHERE batch_item_sno = @bi;
                    SELECT @result = 'FAILED', @msg = N'Not paid' + ISNULL(N' - ' + @rs, N'') + N'. Back in Payment Run';
                END
            END

            IF @result IN ('PAID', 'UPDATED', 'PENDING', 'FAILED')
                INSERT INTO dbo.payment_bank_event (batch_item_sno, reverse_file_sno, payment_sno, old_status, new_status, utr_no, bank_reason_code, bank_reason, reversal_journal_sno, created_by)
                VALUES (@bi, @rf, @p, @cur, @st, @utr, @rc, @rs, @rj, @by);
            INSERT INTO @res (batch_item_sno, payment_sno, old_status, new_status, result, message)
            VALUES (@bi, @p, @cur, CASE WHEN @result IN ('PAID', 'UPDATED', 'PENDING', 'FAILED') THEN @st ELSE @cur END, @result, @msg);
            SET @rn += 1;
        END

        UPDATE dbo.payment_reverse_file
        SET paid_count = (SELECT COUNT(*) FROM @res WHERE result IN ('PAID', 'UPDATED')),
            failed_count = (SELECT COUNT(*) FROM @res WHERE result = 'FAILED'),
            pending_count = (SELECT COUNT(*) FROM @res WHERE result = 'PENDING'),
            unchanged_count = (SELECT COUNT(*) FROM @res WHERE result IN ('UNCHANGED', 'IGNORED')),
            error_count = (SELECT COUNT(*) FROM @res WHERE result = 'ERROR')
        WHERE reverse_file_sno = @rf;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT r.reverse_file_sno, r.batch_sno, @bno AS batch_no, r.file_name, r.line_count, r.paid_count, r.failed_count, r.pending_count, r.unchanged_count,
           r.error_count, r.unmatched_count, r.uploaded_by, CONVERT(VARCHAR(30), r.uploaded_at, 120) AS uploaded_at
    FROM dbo.payment_reverse_file r WHERE r.reverse_file_sno = @rf;
    SELECT x.batch_item_sno, x.payment_sno, p.payment_no, i.line_no, i.vendor_name, i.amount, x.old_status, x.new_status, x.result, x.message,
           i.utr_no, i.bank_reason_code, i.bank_reason, rj.journal_no AS reversal_journal_no,
           p.status AS payment_status, p.created_by, p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM @res x
    JOIN dbo.payment_batch_item i ON i.batch_item_sno = x.batch_item_sno
    JOIN dbo.payment_info p ON p.payment_sno = x.payment_sno
    LEFT JOIN dbo.acct_journal rj ON rj.journal_sno = i.reversal_journal_sno
    ORDER BY i.line_no;
END
GO

-- ── 3. past runs: + the bank's answer ───────────────────────────────────────
-- Past payment runs.  @jsonInput: { batch_sno?, hierarchy?, with_file?, limit? }
-- -> 1 batches (file_content only when with_file and one batch) + bank result counts   2 items of that batch + bank answer
--    3 invoice lines of that batch   4 reverse files uploaded for that batch
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentBatches
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @bsno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.batch_sno') AS INT),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @withFile BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.with_file') IN ('1', 'true') THEN 1 ELSE 0 END,
            @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 30);

    SELECT TOP (@limit) b.batch_sno, b.batch_no, b.batch_date, b.com_sno, c.com_name, b.div_sno, d.div_name, b.brn_sno, br.brn_name,
           b.fund_plan_amount, b.total_amount, b.item_count, b.status,
           b.file_name, CASE WHEN @withFile = 1 AND @bsno IS NOT NULL THEN b.file_content END AS file_content,
           CAST(CASE WHEN b.file_content IS NULL THEN 0 ELSE 1 END AS BIT) AS has_file,
           b.file_no, b.file_type, b.payment_bank_sno, pb.profile_name AS sender_name, b.sender_bank_name, RIGHT(b.sender_account_no, 4) AS sender_ac_last4,
           b.sender_client_code, b.sender_alert_email,
           b.created_by, CONVERT(VARCHAR(30), b.created_at, 120) AS created_at,
           ISNULL(bs.bank_lines, 0) AS bank_lines, ISNULL(bs.bank_paid, 0) AS bank_paid, ISNULL(bs.bank_pending, 0) AS bank_pending,
           ISNULL(bs.bank_failed, 0) AS bank_failed, ISNULL(bs.bank_unconfirmed, 0) AS bank_unconfirmed,
           ISNULL(bs.bank_paid_amount, 0) AS bank_paid_amount, ISNULL(bs.bank_failed_amount, 0) AS bank_failed_amount,
           ISNULL(rf.reverse_files, 0) AS reverse_files, CONVERT(VARCHAR(30), rf.last_reverse_at, 120) AS last_reverse_at
    FROM dbo.payment_batch b
    LEFT JOIN dbo.company_master c ON c.com_sno = b.com_sno
    LEFT JOIN dbo.division_master d ON d.div_sno = b.div_sno
    LEFT JOIN dbo.branch_master br ON br.brn_sno = b.brn_sno
    LEFT JOIN dbo.payment_bank_master pb ON pb.payment_bank_sno = b.payment_bank_sno
    OUTER APPLY (SELECT COUNT(*) AS bank_lines,
                        SUM(CASE WHEN i.bank_status = 'PAID' THEN 1 ELSE 0 END) AS bank_paid,
                        SUM(CASE WHEN i.bank_status = 'PENDING' THEN 1 ELSE 0 END) AS bank_pending,
                        SUM(CASE WHEN i.bank_status IN ('REJECTED', 'RETURNED') THEN 1 ELSE 0 END) AS bank_failed,
                        SUM(CASE WHEN i.bank_status IS NULL THEN 1 ELSE 0 END) AS bank_unconfirmed,
                        SUM(CASE WHEN i.bank_status = 'PAID' THEN i.amount ELSE 0 END) AS bank_paid_amount,
                        SUM(CASE WHEN i.bank_status IN ('REJECTED', 'RETURNED') THEN i.amount ELSE 0 END) AS bank_failed_amount
                 FROM dbo.payment_batch_item i
                 WHERE i.batch_sno = b.batch_sno AND i.channel = 'BANK' AND UPPER(ISNULL(i.mode, '')) IN ('NEFT', 'RTGS')) bs
    OUTER APPLY (SELECT COUNT(*) AS reverse_files, MAX(r.uploaded_at) AS last_reverse_at FROM dbo.payment_reverse_file r WHERE r.batch_sno = b.batch_sno) rf
    WHERE (@bsno IS NULL OR b.batch_sno = @bsno)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = b.com_sno AND (h.div_sno IS NULL OR h.div_sno = b.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno)))
    ORDER BY b.batch_sno DESC;

    SELECT i.batch_item_sno, i.batch_sno, i.payment_sno, p.payment_no, i.line_no, i.vendor_sno, i.vendor_name, i.supp_code, i.vendor_email, i.amount, i.mode, i.debit_account,
           i.channel, i.beneficiary_name, i.account_no, i.ifsc, i.bank_name, i.branch_name, i.invoice_nos, i.supplier_invoice_nos, i.msme_label, i.narration, i.gross_amount, i.tds_amount, i.advance_amount, i.note_amount,
           p.com_sno, p.div_sno, p.brn_sno, p.dept_sno,
           i.bank_status, i.utr_no, i.bank_ref_no, CONVERT(VARCHAR(10), i.bank_debit_date, 23) AS bank_debit_date, CONVERT(VARCHAR(30), i.bank_credit_at, 120) AS bank_credit_at,
           i.bank_reason_code, i.bank_reason, CONVERT(VARCHAR(30), i.bank_updated_at, 120) AS bank_updated_at, i.bank_updated_by,
           i.returned_to_run, rj.journal_no AS reversal_journal_no,
           p.status AS payment_status, CASE WHEN p.batch_sno IS NOT NULL AND p.batch_sno <> i.batch_sno THEN nb.batch_no END AS paid_again_batch_no
    FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
    LEFT JOIN dbo.acct_journal rj ON rj.journal_sno = i.reversal_journal_sno
    LEFT JOIN dbo.payment_batch nb ON nb.batch_sno = p.batch_sno
    WHERE @bsno IS NOT NULL AND i.batch_sno = @bsno
    ORDER BY i.line_no;

    SELECT l.batch_item_sno, l.batch_sno, l.payment_sno, l.invoice_sno, l.invoice_no, l.supplier_invoice_no, l.invoice_date, l.invoice_amount, l.gst_amount,
           l.payable_total, l.paid_before, l.this_gross, l.tds_amount, l.balance_after, l.awaiting_2b, l.part_no, l.kind
    FROM dbo.payment_batch_item_invoice l WHERE @bsno IS NOT NULL AND l.batch_sno = @bsno
    ORDER BY l.batch_item_sno, l.invoice_sno;

    SELECT r.reverse_file_sno, r.batch_sno, r.file_name, r.line_count, r.paid_count, r.failed_count, r.pending_count, r.unchanged_count, r.error_count, r.unmatched_count,
           r.uploaded_by, CONVERT(VARCHAR(30), r.uploaded_at, 120) AS uploaded_at
    FROM dbo.payment_reverse_file r WHERE @bsno IS NOT NULL AND r.batch_sno = @bsno
    ORDER BY r.reverse_file_sno DESC;
END
GO

-- ── 4. payments back in Payment Run because the bank did not pay them ───────
-- @jsonInput: { payment_snos?: [..] }  -> the latest failed attempt of each such payment, and whether the supplier's KYC bank
-- account has changed since (so the screen can tell "fix the KYC" from "it is fixed, pay again").
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentBankFailures
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ids NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.payment_snos');
    SELECT p.payment_sno, f.batch_item_sno, f.batch_sno, b.batch_no, b.file_name, f.bank_status, f.bank_reason_code, f.bank_reason, f.utr_no,
           CONVERT(VARCHAR(30), f.bank_updated_at, 120) AS failed_at, f.amount, f.mode,
           RIGHT(f.account_no, 4) AS account_last4, f.ifsc, f.bank_name, f.beneficiary_name, n.attempts,
           CAST(CASE WHEN bk.ac_number IS NULL THEN 0
                     WHEN CAST(bk.ac_number AS VARCHAR(40)) <> ISNULL(f.account_no, '') OR UPPER(LTRIM(RTRIM(bk.ifsc))) <> UPPER(ISNULL(f.ifsc, '')) THEN 1
                     ELSE 0 END AS BIT) AS kyc_bank_changed
    FROM dbo.payment_info p
    CROSS APPLY (SELECT TOP 1 i.batch_item_sno, i.batch_sno, i.bank_status, i.bank_reason_code, i.bank_reason, i.utr_no, i.bank_updated_at, i.amount, i.mode,
                        i.account_no, i.ifsc, i.bank_name, i.beneficiary_name
                 FROM dbo.payment_batch_item i WHERE i.payment_sno = p.payment_sno AND i.returned_to_run = 'Y'
                 ORDER BY i.bank_updated_at DESC, i.batch_item_sno DESC) f
    CROSS APPLY (SELECT COUNT(*) AS attempts FROM dbo.payment_batch_item i2 WHERE i2.payment_sno = p.payment_sno AND i2.returned_to_run = 'Y') n
    JOIN dbo.payment_batch b ON b.batch_sno = f.batch_sno
    -- the account a new run would use (same pick as sp_nt_CreatePaymentBatch)
    OUTER APPLY (SELECT TOP 1 x.ac_number, x.ifsc FROM dbo.kyc_bank_info x
                 WHERE x.kyc_basic_info_sno = p.vendor_sno AND ISNULL(x.is_active, 'Y') = 'Y' AND x.ac_number IS NOT NULL AND NULLIF(LTRIM(RTRIM(x.ifsc)), '') IS NOT NULL
                 ORDER BY CASE WHEN x.is_primary = 'Y' THEN 0 ELSE 1 END, x.kyc_address_sno DESC) bk
    WHERE p.is_active = 'Y' AND p.status = 'Approved' AND p.batch_sno IS NULL
      AND (@ids IS NULL OR p.payment_sno IN (SELECT TRY_CAST([value] AS INT) FROM OPENJSON(@ids)));
END
GO

-- ── 5. change how a payment the bank did not pay is paid ────────────────────
-- @jsonInput: { payment_sno, mode: NEFT|RTGS|CHEQUE|DD|CASH, reason?, changed_by, hierarchy? } -> the payment
CREATE OR ALTER PROCEDURE dbo.sp_nt_ChangeFailedPaymentMode
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @p INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT),
            @mode VARCHAR(10) = UPPER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.mode')))),
            @reason NVARCHAR(300) = LEFT(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), N''), 300),
            @by VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.changed_by'))), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @by IS NULL THROW 56320, 'changed_by is required.', 1;
    IF @mode IS NULL OR @mode NOT IN ('NEFT', 'RTGS', 'CHEQUE', 'DD', 'CASH') THROW 56321, 'Choose NEFT, RTGS, cheque, DD or cash.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'pay_run_batch', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 56322, 'A payment run is being made right now - please try again in a moment.', 1;

        DECLARE @status VARCHAR(20), @batch INT, @old VARCHAR(10), @net DECIMAL(18,2), @active CHAR(1), @pno VARCHAR(30), @com INT, @div INT, @brn INT;
        SELECT @status = status, @batch = batch_sno, @old = mode, @net = ISNULL(net_paid, amount), @active = is_active, @pno = payment_no,
               @com = com_sno, @div = div_sno, @brn = brn_sno
        FROM dbo.payment_info WITH (UPDLOCK) WHERE payment_sno = @p;
        IF @status IS NULL THROW 56323, 'Payment not found.', 1;
        IF @hier IS NOT NULL AND NOT EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                             WHERE h.com_sno = @com AND (h.div_sno IS NULL OR h.div_sno = @div) AND (h.brn_sno IS NULL OR h.brn_sno = @brn))
            THROW 56324, 'You do not have access to this payment.', 1;
        IF @active <> 'Y' OR @status <> 'Approved' OR @batch IS NOT NULL THROW 56325, 'Only a payment waiting in Payment Run can change how it is paid.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.payment_batch_item WHERE payment_sno = @p AND returned_to_run = 'Y')
            THROW 56326, 'Only a payment the bank did not pay can change how it is paid here.', 1;
        IF @mode = 'RTGS' AND @net < 200000 THROW 56327, 'RTGS is for Rs 2,00,000 and above - use NEFT for a smaller amount.', 1;

        IF UPPER(ISNULL(@old, '')) <> @mode
        BEGIN
            UPDATE dbo.payment_info SET mode = @mode, modified_by = @by, modified_date = GETDATE() WHERE payment_sno = @p;
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
            VALUES (@p, 'MODE_CHANGED', @by, LEFT(N'Paid by ' + ISNULL(@old, N'?') + N' -> ' + @mode + ISNULL(N': ' + @reason, N''), 500));
        END
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT p.payment_sno, p.payment_no, p.mode, @old AS old_mode, ISNULL(p.net_paid, p.amount) AS net_paid, p.status, p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM dbo.payment_info p WHERE p.payment_sno = @p;
END
GO
