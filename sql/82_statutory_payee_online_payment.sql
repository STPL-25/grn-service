-- ============================================================
-- 82_statutory_payee_online_payment.sql   (Non_trade_Dev, re-runnable)
--
-- Statutory Payments > Payees (request 2026-11-03): a payee is paid either
--   BANK ACCOUNT  as before - account, IFSC, NEFT/RTGS - its amounts go in the statutory bank upload file, or
--   ONLINE        on a website / portal (Income Tax e-Pay, GST portal, EPFO ...) - portal name, portal URL and optional payment
--                 instructions, the same details the Supplier KYC asks for when a supplier is paid on its portal (backend sql/109).
--
-- An online payee never goes in a bank file. Its amounts are paid on the portal and then recorded here: how it was paid, the
-- challan / transaction number and the date. One record may settle several amounts of ONE payee (one challan for the month).
-- It is kept in statutory_batch with pay_channel = 'ONLINE' and number SO-yyyy-nnnnnn, so the Paid list and Previous runs show it
-- next to the bank files. A TDS one posts the same journal as a TDS run: Dr TDS Payable / Cr Bank. GST / OTHER post none (as sql/73).
--
--   statutory_payee      + pay_via_portal, payment_portal_name, payment_portal_url, payment_instructions; ac_number / ifsc may be NULL (online)
--   statutory_batch      + pay_channel, payee_sno, portal_name, portal_url, txn_mode, txn_id, txn_date, remarks
--   statutory_batch_item   mode widened to VARCHAR(20) (an online line holds the transaction mode)
--   sp_nt_GetStatutoryPayees / sp_nt_UpsertStatutoryPayee    the new payee fields
--   sp_nt_GetStatutoryPayables   + the payee each OPEN amount will be paid to (its own, else the kind's default) and whether it is online
--   sp_nt_CreateStatutoryBatch   refuses online payees (they are recorded, not written to a bank file)
--   sp_nt_RecordStatutoryOnlinePayment   NEW - records an online payment of the ticked amounts
--   sp_nt_GetStatutoryBatches    + the online fields
--
-- Needs sql/73. Apply: cd grn-service && node sql/run_sql.mjs sql/82_statutory_payee_online_payment.sql
-- Rollback: sql/backups/statutory_payee_online_2026-11-03_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.statutory_payee', 'U') IS NULL OR OBJECT_ID('dbo.statutory_batch', 'U') IS NULL OR OBJECT_ID('dbo.sp_nt_CreateStatutoryBatch', 'P') IS NULL
    THROW 57243, N'Run sql/73 first: statutory payments are not set up in this database.', 1;
GO

-- ── 1. tables ───────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.statutory_payee', 'pay_via_portal') IS NULL
    ALTER TABLE dbo.statutory_payee ADD pay_via_portal CHAR(1) NOT NULL CONSTRAINT DF_statutory_payee_pay_via_portal DEFAULT 'N';
IF COL_LENGTH('dbo.statutory_payee', 'payment_portal_name') IS NULL ALTER TABLE dbo.statutory_payee ADD payment_portal_name NVARCHAR(150) NULL;
IF COL_LENGTH('dbo.statutory_payee', 'payment_portal_url') IS NULL ALTER TABLE dbo.statutory_payee ADD payment_portal_url NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.statutory_payee', 'payment_instructions') IS NULL ALTER TABLE dbo.statutory_payee ADD payment_instructions NVARCHAR(500) NULL;
GO
-- an online payee has no bank account
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.statutory_payee') AND name = 'ac_number' AND is_nullable = 0)
    ALTER TABLE dbo.statutory_payee ALTER COLUMN ac_number VARCHAR(40) NULL;
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.statutory_payee') AND name = 'ifsc' AND is_nullable = 0)
    ALTER TABLE dbo.statutory_payee ALTER COLUMN ifsc VARCHAR(20) NULL;
GO
-- ...but every payee has one way to be paid: a bank account, or a portal
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_statutory_payee_channel')
    ALTER TABLE dbo.statutory_payee WITH CHECK ADD CONSTRAINT CK_statutory_payee_channel CHECK (
        (pay_via_portal = 'N' AND ac_number IS NOT NULL AND ifsc IS NOT NULL)
     OR (pay_via_portal = 'Y' AND payment_portal_name IS NOT NULL AND payment_portal_url IS NOT NULL));
GO

IF COL_LENGTH('dbo.statutory_batch', 'pay_channel') IS NULL
    ALTER TABLE dbo.statutory_batch ADD pay_channel VARCHAR(10) NOT NULL CONSTRAINT DF_statutory_batch_pay_channel DEFAULT 'BANK_FILE'
        CONSTRAINT CK_statutory_batch_pay_channel CHECK (pay_channel IN ('BANK_FILE', 'ONLINE'));
IF COL_LENGTH('dbo.statutory_batch', 'payee_sno') IS NULL   ALTER TABLE dbo.statutory_batch ADD payee_sno   INT           NULL;   -- online: who was paid
IF COL_LENGTH('dbo.statutory_batch', 'portal_name') IS NULL ALTER TABLE dbo.statutory_batch ADD portal_name NVARCHAR(150) NULL;   -- copied from the payee
IF COL_LENGTH('dbo.statutory_batch', 'portal_url') IS NULL  ALTER TABLE dbo.statutory_batch ADD portal_url  NVARCHAR(500) NULL;
IF COL_LENGTH('dbo.statutory_batch', 'txn_mode') IS NULL    ALTER TABLE dbo.statutory_batch ADD txn_mode    VARCHAR(20)   NULL;   -- Net Banking, UPI ...
IF COL_LENGTH('dbo.statutory_batch', 'txn_id') IS NULL      ALTER TABLE dbo.statutory_batch ADD txn_id      VARCHAR(100)  NULL;   -- challan / CIN / CPIN / UTR
IF COL_LENGTH('dbo.statutory_batch', 'txn_date') IS NULL    ALTER TABLE dbo.statutory_batch ADD txn_date    DATE          NULL;
IF COL_LENGTH('dbo.statutory_batch', 'remarks') IS NULL     ALTER TABLE dbo.statutory_batch ADD remarks     NVARCHAR(500) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_statutory_batch_online_txn')
    CREATE UNIQUE INDEX UX_statutory_batch_online_txn ON dbo.statutory_batch (txn_id) WHERE txn_id IS NOT NULL;
GO
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.statutory_batch_item') AND name = 'mode' AND max_length < 20)
    ALTER TABLE dbo.statutory_batch_item ALTER COLUMN mode VARCHAR(20) NOT NULL;
GO

-- ── 2. payees ───────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetStatutoryPayees
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @kind VARCHAR(5) = NULLIF(JSON_VALUE(@jsonInput, '$.kind'), '');
    SELECT p.payee_sno, p.kind, p.payee_name, RIGHT(p.ac_number, 4) AS ac_last4, p.ac_number, p.ifsc, p.bank_name, p.branch_name, p.reference_no,
           p.pay_mode, p.com_sno, c.com_name, p.is_default, p.is_active,
           p.pay_via_portal, p.payment_portal_name, p.payment_portal_url, p.payment_instructions
    FROM dbo.statutory_payee p LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    WHERE (@kind IS NULL OR p.kind = @kind)
    ORDER BY p.kind, p.is_active DESC, p.payee_name;
END
GO

-- { payee_sno?, kind, payee_name, reference_no?, com_sno?, is_default?, is_active?, modified_by,
--   pay_via_portal: 'N' -> ac_number, ifsc, bank_name?, branch_name?, pay_mode?
--   pay_via_portal: 'Y' -> payment_portal_name, payment_portal_url, payment_instructions? }
-- Switching a payee between the two clears the other side's details, so a payee is never half bank, half portal.
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
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.modified_by'),
            @portal CHAR(1) = CASE WHEN JSON_VALUE(@jsonInput, '$.pay_via_portal') IN ('Y', 'true', '1') THEN 'Y' ELSE 'N' END,
            @pname NVARCHAR(150) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_portal_name'))), ''),
            @purl NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_portal_url'))), ''),
            @pinst NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.payment_instructions'))), '');
    IF @kind IS NULL OR @kind NOT IN ('TDS', 'GST', 'OTHER') THROW 57201, 'Choose TDS, GST or OTHER.', 1;
    IF @name IS NULL THROW 57202, 'Payee name is required.', 1;
    IF @portal = 'Y'
    BEGIN
        IF @pname IS NULL THROW 57244, 'Enter the portal / website name.', 1;
        IF @purl IS NULL OR @purl LIKE '% %' OR (@purl NOT LIKE 'http://_%._%' AND @purl NOT LIKE 'https://_%._%')
            THROW 57245, 'Enter the portal URL, starting with https:// - e.g. https://eportal.incometax.gov.in', 1;
        SELECT @ac = NULL, @ifsc = NULL, @bank = NULL, @branch = NULL, @mode = 'NEFT';   -- paid on the portal: no bank account
    END
    ELSE
    BEGIN
        IF @ac IS NULL OR @ac NOT LIKE '%[0-9]%' THROW 57203, 'Account number is required.', 1;
        IF @ifsc IS NULL OR @ifsc NOT LIKE '[A-Z][A-Z][A-Z][A-Z]0[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]' THROW 57204, 'IFSC must be 11 characters, e.g. SBIN0000001.', 1;
        IF @mode NOT IN ('NEFT', 'RTGS') THROW 57205, 'Pay mode must be NEFT or RTGS.', 1;
        SELECT @pname = NULL, @purl = NULL, @pinst = NULL;
    END
    IF @id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.statutory_payee WHERE payee_sno = @id) THROW 57206, 'Payee not found.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        IF @def = 'Y' AND @act = 'Y'   -- one default per kind and company
            UPDATE dbo.statutory_payee SET is_default = 'N' WHERE kind = @kind AND ISNULL(com_sno, 0) = ISNULL(@com, 0) AND payee_sno <> ISNULL(@id, 0);
        IF @id IS NULL
        BEGIN
            INSERT INTO dbo.statutory_payee (kind, payee_name, ac_number, ifsc, bank_name, branch_name, reference_no, pay_mode, com_sno, is_default, is_active, created_by,
                                             pay_via_portal, payment_portal_name, payment_portal_url, payment_instructions)
            VALUES (@kind, @name, @ac, @ifsc, @bank, @branch, @ref, @mode, @com, @def, @act, @by, @portal, @pname, @purl, @pinst);
            SET @id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE dbo.statutory_payee SET kind = @kind, payee_name = @name, ac_number = @ac, ifsc = @ifsc, bank_name = @bank, branch_name = @branch,
                   reference_no = @ref, pay_mode = @mode, com_sno = @com, is_default = @def, is_active = @act, modified_by = @by, modified_at = GETDATE(),
                   pay_via_portal = @portal, payment_portal_name = @pname, payment_portal_url = @purl, payment_instructions = @pinst
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

-- ── 3. the register: + who each open amount will be paid to ────────────────
-- { kind?, status?, hierarchy?, limit? } -> 1: amounts   2: GST held on supplier bills until GSTR-2B
-- pay_to_* (open amounts only): the amount's own payee when it is active, else the kind's default for the company - the same choice
-- the run / the online record makes - so the screen knows which amounts go in a bank file and which are paid online.
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
           s.narration, s.status, s.batch_sno, b.batch_no, s.paid_at, s.cancel_reason, s.created_by, CONVERT(VARCHAR(30), s.created_at, 120) AS created_at,
           e.payee_sno AS pay_to_sno, e.payee_name AS pay_to_name, e.pay_via_portal AS pay_to_online,
           e.payment_portal_name AS pay_to_portal_name, e.payment_portal_url AS pay_to_portal_url, e.payment_instructions AS pay_to_instructions,
           b.pay_channel, b.txn_mode, b.txn_id, b.txn_date
    FROM dbo.statutory_payable s
    LEFT JOIN dbo.company_master c ON c.com_sno = s.com_sno
    LEFT JOIN dbo.payment_info p ON p.payment_sno = s.payment_sno
    LEFT JOIN dbo.statutory_payee y ON y.payee_sno = s.payee_sno
    LEFT JOIN dbo.statutory_batch b ON b.batch_sno = s.batch_sno
    OUTER APPLY (SELECT TOP 1 z.payee_sno, z.payee_name, z.pay_via_portal, z.payment_portal_name, z.payment_portal_url, z.payment_instructions
                 FROM dbo.statutory_payee z
                 WHERE s.status = 'Open' AND z.is_active = 'Y'
                   AND (z.payee_sno = s.payee_sno OR (z.kind = s.kind AND (z.com_sno = s.com_sno OR z.com_sno IS NULL)))
                 ORDER BY CASE WHEN z.payee_sno = s.payee_sno THEN 0 ELSE 1 END, CASE WHEN z.com_sno = s.com_sno THEN 0 ELSE 1 END,
                          CASE WHEN z.is_default = 'Y' THEN 0 ELSE 1 END, z.payee_sno) e
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

-- ── 4. the bank-file run: refuses online payees ─────────────────────────────
-- { stat_snos: [..], payment_date?, payment_bank_sno?, created_by, hierarchy? } -> recordsets: batch, items
-- One kind, one company/division/branch per file. Needs a payee on every amount, and that payee must be paid by bank account.
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
        -- a payee paid online has no bank account: its amounts are paid on the portal and recorded, never put in a file
        DECLARE @online NVARCHAR(400) = (SELECT STRING_AGG(q.payee_name, N', ') FROM (
            SELECT DISTINCT y.payee_name FROM @res r JOIN dbo.statutory_payee y ON y.payee_sno = r.payee_sno WHERE y.pay_via_portal = 'Y') q);
        IF @online IS NOT NULL
        BEGIN
            DECLARE @onlineMsg NVARCHAR(600) = @online + N' is paid online, not by bank file. Untick those amounts, or pay them on the portal and use "Record online payment".';
            THROW 57246, @onlineMsg, 1;
        END

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
                                         file_type, sender_client_code, sender_bank_name, sender_account_no, created_by, pay_channel)
        VALUES (@bno, @vdate, @kind, @com, @div, @brn, @total, (SELECT COUNT(*) FROM @sel), @pb, @fcs, @fname, @fseq, @pb_type, @pb_client, @pb_bank, @pb_acno, @by, 'BANK_FILE');
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

-- ── 5. record an online payment ─────────────────────────────────────────────
-- { stat_snos: [..], txn_mode, txn_id, txn_date?, remarks?, recorded_by, hierarchy? } -> recordsets: batch, items
-- The ticked amounts were paid on their payee's portal. One kind, one company/division/branch and ONE online payee per record
-- (one challan / transaction). They become Paid under an SO-yyyy-nnnnnn record; TDS posts Dr TDS Payable / Cr Bank.
CREATE OR ALTER PROCEDURE dbo.sp_nt_RecordStatutoryOnlinePayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @list NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.stat_snos'), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.recorded_by'),
            @mode VARCHAR(20) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.txn_mode'))), ''),
            @tid VARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.txn_id'))), ''),
            @tdate DATE = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.txn_date') AS DATE), CAST(GETDATE() AS DATE)),
            @rem NVARCHAR(500) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.remarks'))), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    IF @by IS NULL THROW 57247, 'recorded_by is required.', 1;
    SET @mode = CASE UPPER(@mode) WHEN 'NET BANKING' THEN 'Net Banking' WHEN 'UPI' THEN 'UPI' WHEN 'DEBIT CARD' THEN 'Debit Card' WHEN 'CREDIT CARD' THEN 'Credit Card'
                                  WHEN 'NEFT/RTGS' THEN 'NEFT/RTGS' WHEN 'OTHER' THEN 'Other' END;
    IF @mode IS NULL THROW 57248, 'Choose how it was paid: Net Banking, UPI, Debit Card, Credit Card, NEFT/RTGS or Other.', 1;
    IF @tid IS NULL THROW 57249, 'Enter the challan / transaction number.', 1;
    IF @tid LIKE '%[^A-Za-z0-9._/-]%' COLLATE Latin1_General_BIN2 THROW 57249, 'The challan / transaction number can only have letters, digits and . _ / -', 1;
    IF @tdate > CAST(GETDATE() AS DATE) THROW 57250, 'The payment date cannot be in the future.', 1;
    DECLARE @sel TABLE (line_no INT, stat_sno INT PRIMARY KEY);
    INSERT INTO @sel SELECT MIN(TRY_CAST(j.[key] AS INT) + 1), TRY_CAST(j.value AS INT) FROM OPENJSON(@list) j GROUP BY TRY_CAST(j.value AS INT);
    IF NOT EXISTS (SELECT 1 FROM @sel) OR EXISTS (SELECT 1 FROM @sel WHERE stat_sno IS NULL) THROW 57251, 'Select at least one amount.', 1;

    DECLARE @h_tds INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'TDS_PAYABLE'),
            @h_bank INT = (SELECT head_sno FROM dbo.acct_account_head WHERE system_key = 'BANK');
    DECLARE @bsno INT, @bno VARCHAR(30);
    BEGIN TRANSACTION;
    BEGIN TRY
        DECLARE @lk INT;
        EXEC @lk = sp_getapplock @Resource = N'stat_online_pay', @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 57252, 'Another statutory payment is being recorded right now - please try again in a moment.', 1;

        DECLARE @bad NVARCHAR(500) = (SELECT STRING_AGG(CAST(x.stat_sno AS VARCHAR(12)), ', ')
            FROM @sel x LEFT JOIN dbo.statutory_payable s WITH (UPDLOCK, HOLDLOCK) ON s.stat_sno = x.stat_sno
            WHERE s.stat_sno IS NULL OR s.status <> 'Open');
        IF @bad IS NOT NULL
        BEGIN
            DECLARE @badMsg NVARCHAR(700) = N'No longer open (already paid or cancelled): ' + @bad + N'. Refresh the list.';
            THROW 57253, @badMsg, 1;
        END
        IF @hier IS NOT NULL AND EXISTS (
            SELECT 1 FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno
            WHERE NOT EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                              WHERE h.com_sno = s.com_sno AND (h.div_sno IS NULL OR h.div_sno = s.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = s.brn_sno)))
            THROW 57254, 'You do not have access to one or more of the selected amounts.', 1;
        IF (SELECT COUNT(DISTINCT s.kind) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno) > 1
            THROW 57255, 'One payment covers one kind at a time (TDS, GST or other) - record each from its own tab.', 1;
        IF (SELECT COUNT(*) FROM (SELECT DISTINCT ISNULL(s.com_sno, -1) c, ISNULL(s.div_sno, -1) d, ISNULL(s.brn_sno, -1) b
                                  FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno) q) > 1
            THROW 57256, 'One payment covers one company, division and branch at a time - untick amounts from the other scope.', 1;

        -- the payee of each amount: the one chosen on it, else the kind's default for the company (the same choice as the bank-file run)
        DECLARE @res TABLE (stat_sno INT PRIMARY KEY, payee_sno INT NULL);
        INSERT INTO @res
        SELECT x.stat_sno, COALESCE(
            (SELECT y.payee_sno FROM dbo.statutory_payee y WHERE y.payee_sno = s.payee_sno AND y.is_active = 'Y'),
            (SELECT TOP 1 y.payee_sno FROM dbo.statutory_payee y WHERE y.kind = s.kind AND y.is_active = 'Y' AND (y.com_sno = s.com_sno OR y.com_sno IS NULL)
             ORDER BY CASE WHEN y.com_sno = s.com_sno THEN 0 ELSE 1 END, CASE WHEN y.is_default = 'Y' THEN 0 ELSE 1 END, y.payee_sno))
        FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno;
        IF EXISTS (SELECT 1 FROM @res WHERE payee_sno IS NULL)
            THROW 57257, N'No payee is set up for this kind. Add one under "Payees", then try again.', 1;
        DECLARE @bankPayees NVARCHAR(400) = (SELECT STRING_AGG(q.payee_name, N', ') FROM (
            SELECT DISTINCT y.payee_name FROM @res r JOIN dbo.statutory_payee y ON y.payee_sno = r.payee_sno WHERE y.pay_via_portal <> 'Y') q);
        IF @bankPayees IS NOT NULL
        BEGIN
            DECLARE @bankMsg NVARCHAR(600) = @bankPayees + N' is paid by bank account - pay those amounts with "Pay & generate file".';
            THROW 57258, @bankMsg, 1;
        END
        IF (SELECT COUNT(DISTINCT payee_sno) FROM @res) > 1
            THROW 57259, 'One online payment pays one payee - tick the amounts of one payee at a time.', 1;
        DECLARE @dup VARCHAR(30) = (SELECT TOP 1 batch_no FROM dbo.statutory_batch WHERE txn_id = @tid);
        IF @dup IS NOT NULL
        BEGIN
            DECLARE @dupMsg NVARCHAR(300) = N'This challan / transaction number is already recorded (' + @dup + N').';
            THROW 57260, @dupMsg, 1;
        END

        DECLARE @payee INT = (SELECT TOP 1 payee_sno FROM @res), @pname NVARCHAR(150), @purl NVARCHAR(500);
        SELECT @pname = payment_portal_name, @purl = payment_portal_url FROM dbo.statutory_payee WHERE payee_sno = @payee;
        DECLARE @kind VARCHAR(5) = (SELECT TOP 1 s.kind FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno),
                @com INT = (SELECT MIN(s.com_sno) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno),
                @div INT = (SELECT MIN(s.div_sno) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno),
                @brn INT = (SELECT MIN(s.brn_sno) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno),
                @total DECIMAL(18,2) = (SELECT SUM(s.amount) FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno);

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(batch_no, 6) AS INT)), 0) + 1 FROM dbo.statutory_batch WITH (UPDLOCK, HOLDLOCK) WHERE batch_no LIKE 'SO-' + @year + '-%';
        SET @bno = 'SO-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        INSERT INTO dbo.statutory_batch (batch_no, batch_date, kind, com_sno, div_sno, brn_sno, total_amount, item_count, status, created_by,
                                         pay_channel, payee_sno, portal_name, portal_url, txn_mode, txn_id, txn_date, remarks)
        VALUES (@bno, @tdate, @kind, @com, @div, @brn, @total, (SELECT COUNT(*) FROM @sel), 'Recorded', @by,
                'ONLINE', @payee, @pname, @purl, @mode, @tid, @tdate, @rem);
        SET @bsno = SCOPE_IDENTITY();

        INSERT INTO dbo.statutory_batch_item (batch_sno, stat_sno, line_no, amount, mode, payee_name, account_no, ifsc, bank_name, branch_name, reference_no, head_name, period_label)
        SELECT @bsno, s.stat_sno, ROW_NUMBER() OVER (ORDER BY x.line_no), s.amount, @mode, y.payee_name, NULL, NULL, NULL, NULL,
               ISNULL(s.ref_no, y.reference_no), s.head_name, s.period_label
        FROM @sel x JOIN dbo.statutory_payable s ON s.stat_sno = x.stat_sno JOIN @res r ON r.stat_sno = s.stat_sno JOIN dbo.statutory_payee y ON y.payee_sno = r.payee_sno;

        UPDATE s SET status = 'Paid', batch_sno = @bsno, paid_at = CAST(@tdate AS DATETIME), payee_sno = r.payee_sno
        FROM dbo.statutory_payable s JOIN @res r ON r.stat_sno = s.stat_sno;

        -- TDS paid out: Dr TDS Payable / Cr Bank (as a bank-file run)
        IF @kind = 'TDS'
        BEGIN
            IF @h_tds IS NULL OR @h_bank IS NULL THROW 57242, 'System account heads are missing.', 1;
            INSERT INTO dbo.acct_journal (journal_date, source_type, source_sno, narration, com_sno, div_sno, brn_sno, created_by)
            VALUES (@tdate, 'STAT_BATCH', @bsno, LEFT(N'TDS paid online ' + @bno + N' (' + @mode + N' ' + @tid + N')', 200), @com, @div, @brn, @by);
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

-- ── 6. earlier runs: + the online ones ──────────────────────────────────────
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
           CASE WHEN @with = 1 THEN b.file_content END AS file_content,
           b.pay_channel, b.payee_sno, y.payee_name, b.portal_name, b.portal_url, b.txn_mode, b.txn_id, b.txn_date, b.remarks
    FROM dbo.statutory_batch b LEFT JOIN dbo.company_master c ON c.com_sno = b.com_sno
    LEFT JOIN dbo.statutory_payee y ON y.payee_sno = b.payee_sno
    WHERE (@bsno IS NULL OR b.batch_sno = @bsno) AND (@kind IS NULL OR b.kind = @kind)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = b.com_sno AND (h.div_sno IS NULL OR h.div_sno = b.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = b.brn_sno)))
    ORDER BY b.batch_sno DESC;

    SELECT i.*, s.kind, s.com_sno, s.div_sno, s.brn_sno
    FROM dbo.statutory_batch_item i JOIN dbo.statutory_payable s ON s.stat_sno = i.stat_sno
    WHERE @bsno IS NOT NULL AND i.batch_sno = @bsno ORDER BY i.line_no;
END
GO
