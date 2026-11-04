-- ============================================================
-- 73_statutory_payments.sql   (Non_trade_Dev ONLY, re-runnable, NOT APPLIED until the user OKs it)
--
-- Statutory payments (TDS payable, GST payable, others) get their own screen and their own payment file, apart from the
-- supplier Payment Run (request 2026-10-28).
--
--   statutory_payee      who is paid: Income Tax Dept (TDS), GST dept (GST), PF / ESI / ... (OTHER) - name, account, IFSC, bank, mode
--   statutory_payable    one amount owed: TDS fills itself from tds_deduction (a paid payment's deduction), GST / OTHER are keyed in
--   statutory_batch      one statutory payment run = one bank upload file of ONE kind (TDS, GST or OTHER) - SB-yyyy-nnnnnn
--   statutory_batch_item the lines of that file with the payee's bank details copied (so a later edit never changes an old file)
--
-- The file uses the SAME bank upload layout as the supplier run (grn-service src/paymentnet/paymentFile.js) and the SAME daily file
-- number register (payment_file_creation_no): a statutory file and a supplier file of the same bank account and day can never
-- share a name. TDS paid out posts Dr TDS Payable / Cr Bank. GST / OTHER post no journal (the chart of accounts has no head for them).
-- GST held until GSTR-2B stays a supplier bill matter - it is shown (not paid) on the GST tab so it cannot be paid twice.
--
--   sp_nt_GetStatutoryPayables  list (+ TDS sync) and the GST waiting for 2B     sp_nt_AddStatutoryPayable / sp_nt_CancelStatutoryPayable
--   sp_nt_GetStatutoryPayees / sp_nt_UpsertStatutoryPayee
--   sp_nt_CreateStatutoryBatch  pays the ticked amounts: batch, items, journal      sp_nt_SetStatutoryBatchFile / sp_nt_GetStatutoryBatches
--
-- Needs sql/68 (payment_bank_master + payment_file_creation_no). Apply: cd grn-service && node sql/run_sql.mjs sql/73_statutory_payments.sql
-- Rollback: sql/backups/statutory_payments_2026-10-28_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.payment_file_creation_no', 'U') IS NULL OR OBJECT_ID('dbo.payment_bank_master', 'U') IS NULL
    THROW 57200, N'Run sql/68 first: the payment bank master and the file number register do not exist.', 1;
GO

-- ── 1. tables ───────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.statutory_payee', 'U') IS NULL
CREATE TABLE dbo.statutory_payee (
    payee_sno     INT IDENTITY(1,1) PRIMARY KEY,
    kind          VARCHAR(5)    NOT NULL CHECK (kind IN ('TDS', 'GST', 'OTHER')),
    payee_name    NVARCHAR(100) NOT NULL,
    ac_number     VARCHAR(40)   NOT NULL,
    ifsc          VARCHAR(20)   NOT NULL,
    bank_name     NVARCHAR(100) NULL,
    branch_name   NVARCHAR(100) NULL,
    reference_no  NVARCHAR(40)  NULL,                          -- TAN / GSTIN / registration no shown on the file
    pay_mode      VARCHAR(5)    NOT NULL DEFAULT 'NEFT' CHECK (pay_mode IN ('NEFT', 'RTGS')),
    com_sno       INT           NULL,                          -- NULL = every company
    is_default    CHAR(1)       NOT NULL DEFAULT 'N',
    is_active     CHAR(1)       NOT NULL DEFAULT 'Y',
    created_by    VARCHAR(30)   NULL,
    created_at    DATETIME      NOT NULL DEFAULT GETDATE(),
    modified_by   VARCHAR(30)   NULL,
    modified_at   DATETIME      NULL
);
GO
IF OBJECT_ID('dbo.statutory_batch', 'U') IS NULL
CREATE TABLE dbo.statutory_batch (
    batch_sno           INT IDENTITY(1,1) PRIMARY KEY,
    batch_no            VARCHAR(30)  NOT NULL UNIQUE,
    batch_date          DATE         NOT NULL,
    kind                VARCHAR(5)   NOT NULL,
    com_sno INT NULL, div_sno INT NULL, brn_sno INT NULL,
    total_amount        DECIMAL(18,2) NOT NULL,
    item_count          INT          NOT NULL,
    status              VARCHAR(12)  NOT NULL DEFAULT 'Generated',
    payment_bank_sno    INT          NULL,
    file_creation_sno   BIGINT       NULL,
    file_name           VARCHAR(200) NULL,
    file_no             INT          NULL,
    file_type           VARCHAR(20)  NULL,
    file_content        NVARCHAR(MAX) NULL,
    sender_client_code  VARCHAR(30)  NULL,
    sender_bank_name    NVARCHAR(100) NULL,
    sender_account_no   VARCHAR(30)  NULL,
    journal_sno         INT          NULL,
    created_by          VARCHAR(30)  NULL,
    created_at          DATETIME     NOT NULL DEFAULT GETDATE()
);
GO
IF OBJECT_ID('dbo.statutory_payable', 'U') IS NULL
CREATE TABLE dbo.statutory_payable (
    stat_sno      INT IDENTITY(1,1) PRIMARY KEY,
    kind          VARCHAR(5)    NOT NULL CHECK (kind IN ('TDS', 'GST', 'OTHER')),
    source_type   VARCHAR(10)   NOT NULL CHECK (source_type IN ('TDS', 'MANUAL')),
    deduction_sno INT           NULL,                          -- tds_deduction row this came from (TDS only)
    com_sno INT NULL, div_sno INT NULL, brn_sno INT NULL, dept_sno INT NULL,
    head_name     NVARCHAR(100) NOT NULL,                      -- "TDS u/s 194C", "GST - GSTR-3B Sep", "Provident Fund"
    ref_no        NVARCHAR(40)  NULL,                          -- section / GSTIN / return
    period_label  NVARCHAR(30)  NULL,                          -- "Sep 2026" / "FY 2026-27"
    party_name    NVARCHAR(120) NULL,                          -- TDS: the supplier it was deducted from
    payment_sno   INT           NULL,                          -- TDS: the supplier payment that deducted it
    payee_sno     INT           NULL REFERENCES dbo.statutory_payee (payee_sno),
    amount        DECIMAL(18,2) NOT NULL CHECK (amount > 0),
    due_date      DATE          NULL,
    narration     NVARCHAR(200) NULL,
    status        VARCHAR(10)   NOT NULL DEFAULT 'Open' CHECK (status IN ('Open', 'Paid', 'Cancelled')),
    batch_sno     INT           NULL REFERENCES dbo.statutory_batch (batch_sno),
    paid_at       DATETIME      NULL,
    cancel_reason NVARCHAR(200) NULL,
    created_by    VARCHAR(30)   NULL,
    created_at    DATETIME      NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_statutory_payable_deduction')
    CREATE UNIQUE INDEX UX_statutory_payable_deduction ON dbo.statutory_payable (deduction_sno) WHERE deduction_sno IS NOT NULL;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_statutory_payable_kind_status')
    CREATE INDEX IX_statutory_payable_kind_status ON dbo.statutory_payable (kind, status, com_sno);
GO
IF OBJECT_ID('dbo.statutory_batch_item', 'U') IS NULL
CREATE TABLE dbo.statutory_batch_item (
    item_sno      INT IDENTITY(1,1) PRIMARY KEY,
    batch_sno     INT NOT NULL REFERENCES dbo.statutory_batch (batch_sno),
    stat_sno      INT NOT NULL REFERENCES dbo.statutory_payable (stat_sno),
    line_no       INT NOT NULL,
    amount        DECIMAL(18,2) NOT NULL,
    mode          VARCHAR(5)    NOT NULL,
    payee_name    NVARCHAR(100) NULL,
    account_no    VARCHAR(40)   NULL,
    ifsc          VARCHAR(20)   NULL,
    bank_name     NVARCHAR(100) NULL,
    branch_name   NVARCHAR(100) NULL,
    reference_no  NVARCHAR(40)  NULL,
    head_name     NVARCHAR(100) NULL,
    period_label  NVARCHAR(30)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_statutory_batch_item_stat')
    CREATE UNIQUE INDEX UX_statutory_batch_item_stat ON dbo.statutory_batch_item (stat_sno);
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

-- ── 3. TDS fills the register ───────────────────────────────────────────────
-- A deduction of a PAID supplier payment (status Processed) is owed to the Income Tax Dept: due on the 7th of the next month
-- (30 April for March). Idempotent: one row per deduction (unique index), safe to call on every list.
CREATE OR ALTER PROCEDURE dbo.sp_nt_SyncStatutoryTds
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @lk INT;
    BEGIN TRANSACTION;
    EXEC @lk = sp_getapplock @Resource = N'stat_tds_sync', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 10000;
    IF @lk >= 0
    INSERT INTO dbo.statutory_payable (kind, source_type, deduction_sno, com_sno, div_sno, brn_sno, dept_sno, head_name, ref_no, period_label, party_name,
                                       payment_sno, payee_sno, amount, due_date, narration, created_by)
    SELECT 'TDS', 'TDS', d.deduction_sno, p.com_sno, p.div_sno, p.brn_sno, p.dept_sno,
           N'TDS u/s ' + d.section_code, d.section_code, FORMAT(p.payment_date, 'MMM yyyy'), k.company_name,
           p.payment_sno,
           (SELECT TOP 1 y.payee_sno FROM dbo.statutory_payee y WHERE y.kind = 'TDS' AND y.is_active = 'Y' AND (y.com_sno = p.com_sno OR y.com_sno IS NULL)
            ORDER BY CASE WHEN y.com_sno = p.com_sno THEN 0 ELSE 1 END, CASE WHEN y.is_default = 'Y' THEN 0 ELSE 1 END, y.payee_sno),
           d.tds_amount,
           CASE WHEN MONTH(p.payment_date) = 3 THEN DATEFROMPARTS(YEAR(p.payment_date), 4, 30)
                ELSE DATEADD(DAY, 6, DATEADD(DAY, 1, EOMONTH(p.payment_date))) END,
           LEFT(N'TDS on ' + ISNULL(p.payment_no, ''), 200), 'system'
    FROM dbo.tds_deduction d
    JOIN dbo.payment_info p ON p.payment_sno = d.payment_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = d.vendor_sno
    WHERE d.tds_amount > 0 AND p.status = 'Processed' AND p.payment_date IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.statutory_payable s WHERE s.deduction_sno = d.deduction_sno);
    COMMIT TRANSACTION;
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

-- manual GST / OTHER: { kind, head_name, ref_no?, period_label?, payee_sno?, amount, due_date?, narration?, com_sno, div_sno?, brn_sno?, created_by }
CREATE OR ALTER PROCEDURE dbo.sp_nt_AddStatutoryPayable
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kind VARCHAR(5) = UPPER(NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.kind'))), '')),
            @head NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.head_name'))), ''),
            @amount DECIMAL(18,2) = TRY_CAST(JSON_VALUE(@jsonInput, '$.amount') AS DECIMAL(18,2)),
            @com INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT), @div INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.div_sno') AS INT), @brn INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.brn_sno') AS INT),
            @payee INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payee_sno') AS INT), @due DATE = TRY_CAST(JSON_VALUE(@jsonInput, '$.due_date') AS DATE),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    IF @kind IS NULL OR @kind NOT IN ('GST', 'OTHER') THROW 57210, 'Only GST and other amounts are keyed in - TDS comes from the supplier payments.', 1;
    IF @head IS NULL THROW 57211, 'Say what the amount is for.', 1;
    IF @amount IS NULL OR @amount <= 0 THROW 57212, 'Enter an amount above zero.', 1;
    IF @com IS NULL THROW 57213, 'Choose the company.', 1;
    IF @payee IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.statutory_payee WHERE payee_sno = @payee AND is_active = 'Y' AND kind = @kind AND (com_sno IS NULL OR com_sno = @com))
        THROW 57214, 'That payee is not available for this kind and company.', 1;
    IF @hier IS NOT NULL AND NOT EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                         WHERE h.com_sno = @com AND (h.div_sno IS NULL OR h.div_sno = @div) AND (h.brn_sno IS NULL OR h.brn_sno = @brn))
        THROW 57215, 'You do not have access to that company / division / branch.', 1;
    INSERT INTO dbo.statutory_payable (kind, source_type, com_sno, div_sno, brn_sno, head_name, ref_no, period_label, payee_sno, amount, due_date, narration, created_by)
    VALUES (@kind, 'MANUAL', @com, @div, @brn, @head, NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ref_no'))), ''), NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.period_label'))), ''),
            @payee, @amount, @due, NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.narration'))), ''), @by);
    SELECT SCOPE_IDENTITY() AS stat_sno;
END
GO

-- { stat_sno, reason, cancelled_by, hierarchy? } - an Open amount keyed in by hand. A TDS amount is not cancelled: it is owed.
CREATE OR ALTER PROCEDURE dbo.sp_nt_CancelStatutoryPayable
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.stat_sno') AS INT), @reason NVARCHAR(200) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.reason'))), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @reason IS NULL THROW 57220, 'Give the reason.', 1;
    UPDATE s SET status = 'Cancelled', cancel_reason = @reason
    FROM dbo.statutory_payable s
    WHERE s.stat_sno = @id AND s.status = 'Open' AND s.source_type = 'MANUAL'
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = s.com_sno AND (h.div_sno IS NULL OR h.div_sno = s.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = s.brn_sno)));
    IF @@ROWCOUNT = 0 THROW 57221, 'Only an open amount keyed in by hand, inside your access, can be cancelled.', 1;
    SELECT @id AS stat_sno;
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

CREATE OR ALTER PROCEDURE dbo.sp_nt_SetStatutoryBatchFile
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.statutory_batch SET file_name = JSON_VALUE(@jsonInput, '$.file_name'), file_content = JSON_VALUE(@jsonInput, '$.file_content')
    WHERE batch_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.batch_sno') AS INT);
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

-- ── 6. screen: Accounts and Payment > Statutory Payments ────────────────────
DECLARE @g INT = (SELECT group_id FROM dbo.screen_group WHERE group_name = N'Accounts and Payment');
IF @g IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'StatutoryPaymentPage')
        INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
        SELECT N'Statutory Payments', screen_code, 'StatutoryPaymentPage', 'Landmark', @g, 4, 'Y' FROM dbo.screens WHERE comp = 'PaymentPage';
    UPDATE dbo.screens SET display_order = 5 WHERE comp = 'Gstr2bPage';
    UPDATE dbo.screens SET display_order = 6 WHERE comp = 'JournalsPage';
END
GO
DECLARE @sid INT, @json NVARCHAR(MAX);
SELECT @sid = screen_id FROM dbo.screens WHERE comp = 'StatutoryPaymentPage';
IF @sid IS NOT NULL
BEGIN
    SET @json = (SELECT 'KTM1148' AS ecno, @sid AS screen_id, JSON_QUERY('[2,3,4,5]') AS permission_ids FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
END
GO
