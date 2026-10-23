-- ============================================================
-- 65_payment_approval_and_run.sql   (Non_trade_Dev ONLY, re-runnable)
--
-- Payment: entry -> approval -> pending payments -> fund-plan run -> payment file.
--
--   1. SAVE.  "Release Payment" on the Payment page now only SAVES the payment: sp_nt_ReleasePaymentNet creates it as
--      'Pending Approval' and reserves what it uses (the invoice buckets, TDS base, advances, debit / credit notes) exactly
--      as before - so nobody can pay the same bill twice - but it no longer posts the journal.
--   2. APPROVE.  sp_nt_SubmitPaymentForApproval looks up the 'Payment' workflow of the payment's company / division / branch /
--      department (entity routing: fn_resolve_approval_entity('Payment','STANDARD')) and walks the stage chain
--      (sp_nt_ApprovePayment, same rules as GRN: only the current approver, remarks to reject). No workflow configured ->
--      'Approved' straight away (as GRN does), so saving is never blocked. Rejecting - or cancelling - gives everything
--      back: allocations go to payment_allocation_archive, TDS rows are removed, advances and notes are freed.
--   3. PENDING PAYMENTS.  sp_nt_GetPaymentEntries (view 'run') lists the approved payments waiting to be paid with the dates
--      the user asked for - gate entry date, GRN date - the supplier's MSME class, and a due date:
--        MSME Micro / Small (or MSME with no type recorded): statutory limit = MSME_LIMIT_DAYS (45) from the day of acceptance
--          (earliest of gate entry / GRN date, else invoice date), or the invoice's own due date if that is earlier
--          (MSMED Act s.15; Income-tax s.43B(h) makes a late payment non-deductible).
--        everyone else: the invoice due date, else acceptance + DEFAULT_CREDIT_DAYS (30).
--      msme_tier orders them: 1 Micro, 2 Small, 3 Medium / MSME, 4 not MSME; then earliest due, then oldest receipt.
--   4. RUN.  sp_nt_CreatePaymentBatch takes the payments ticked against today's fund plan, checks the total fits, snapshots
--      the supplier bank details into payment_batch_item, marks the payments 'Processed' and posts each payment's journal
--      (Dr Supplier Payable / Cr TDS, Advance, Bank, DN-CN adjustment - the same entries sp_nt_ReleasePaymentNet used to post
--      at release). The payment file text is built by grn-service and stored with sp_nt_SetPaymentBatchFile.
--   5. 'Paid' now means settled: Pending Approval / Approved payments only RESERVE a bill. fn_nt_PaymentNoteScope (a note
--      raised against a bill is supplier-wide once that bill is closed), sp_nt_GetPayableBillsNet and sp_nt_GetPoInvoiceLedger
--      count only settled payments as paid; the ledger shows 'In payment' for the rest.
--
-- payment_info.status:  Pending Approval -> Approved -> Processed          (Rejected / Cancelled end it early)
-- Screens: Payment Approval (PaymentApprovalScreen) and Payment Run (PaymentRunPage) in group 'Accounts and Payment'.
--
-- Apply: cd grn-service && node sql/run_sql.mjs sql/65_payment_approval_and_run.sql
-- Rollback: sql/backups/payment_approval_run_2026-10-22_ROLLBACK.sql (restores the replaced procedures; keeps the new tables)
--
-- NOTE: sql/66 (value conditions, forward, send back) REPLACES sp_nt_SubmitPaymentForApproval, sp_nt_ApprovePayment,
-- sp_nt_CancelPayment, sp_nt_GetPaymentActivity and sp_nt_GetPaymentEntries from this file. On a database that has sql/66,
-- do NOT re-run those batches: apply sql/66 again afterwards, or they put the old versions back.
-- ============================================================

-- ── 1. schema ───────────────────────────────────────────────────────────────
IF COL_LENGTH('dbo.payment_info', 'workflow_types_id')   IS NULL ALTER TABLE dbo.payment_info ADD workflow_types_id INT NULL;
IF COL_LENGTH('dbo.payment_info', 'current_approver_id') IS NULL ALTER TABLE dbo.payment_info ADD current_approver_id VARCHAR(30) NULL;
IF COL_LENGTH('dbo.payment_info', 'approved_at')         IS NULL ALTER TABLE dbo.payment_info ADD approved_at DATETIME NULL;
IF COL_LENGTH('dbo.payment_info', 'com_sno')             IS NULL ALTER TABLE dbo.payment_info ADD com_sno INT NULL;
IF COL_LENGTH('dbo.payment_info', 'div_sno')             IS NULL ALTER TABLE dbo.payment_info ADD div_sno INT NULL;
IF COL_LENGTH('dbo.payment_info', 'brn_sno')             IS NULL ALTER TABLE dbo.payment_info ADD brn_sno INT NULL;
IF COL_LENGTH('dbo.payment_info', 'dept_sno')            IS NULL ALTER TABLE dbo.payment_info ADD dept_sno INT NULL;
IF COL_LENGTH('dbo.payment_info', 'batch_sno')           IS NULL ALTER TABLE dbo.payment_info ADD batch_sno INT NULL;
IF COL_LENGTH('dbo.payment_info', 'processed_at')        IS NULL ALTER TABLE dbo.payment_info ADD processed_at DATETIME NULL;
GO

IF OBJECT_ID('dbo.payment_approval_history', 'U') IS NULL
CREATE TABLE dbo.payment_approval_history (
    history_sno INT IDENTITY(1,1) PRIMARY KEY,
    payment_sno INT NOT NULL,
    action_type VARCHAR(20) NOT NULL,      -- SUBMITTED / APPROVED / AUTO_APPROVED / REJECTED / CANCELLED / PAID
    status_by   VARCHAR(30) NULL,
    comment     NVARCHAR(500) NULL,
    created_at  DATETIME NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_approval_history_payment' AND object_id = OBJECT_ID('dbo.payment_approval_history'))
    CREATE INDEX IX_payment_approval_history_payment ON dbo.payment_approval_history (payment_sno);
GO

-- what a rejected / cancelled payment had reserved, kept so its detail can still be shown
IF OBJECT_ID('dbo.payment_allocation_archive', 'U') IS NULL
CREATE TABLE dbo.payment_allocation_archive (
    archive_sno       INT IDENTITY(1,1) PRIMARY KEY,
    payment_sno       INT NOT NULL,
    invoice_alloc_sno INT NOT NULL,
    amount            DECIMAL(18,2) NOT NULL,
    created_date      DATETIME NULL,
    reversed_at       DATETIME NOT NULL DEFAULT GETDATE(),
    reversed_by       VARCHAR(30) NULL,
    reason            NVARCHAR(500) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_allocation_archive_payment' AND object_id = OBJECT_ID('dbo.payment_allocation_archive'))
    CREATE INDEX IX_payment_allocation_archive_payment ON dbo.payment_allocation_archive (payment_sno);
GO

-- tunables of the Payment Run (the payment-file folder will live here too once it is arranged)
IF OBJECT_ID('dbo.nt_payment_run_setting', 'U') IS NULL
CREATE TABLE dbo.nt_payment_run_setting (
    setting_key   VARCHAR(40)   NOT NULL PRIMARY KEY,
    setting_value VARCHAR(200)  NOT NULL,
    description   NVARCHAR(300) NULL,
    modified_by   VARCHAR(30)   NULL,
    modified_at   DATETIME      NOT NULL DEFAULT GETDATE()
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.nt_payment_run_setting WHERE setting_key = 'MSME_LIMIT_DAYS')
    INSERT INTO dbo.nt_payment_run_setting (setting_key, setting_value, description, modified_by)
    VALUES ('MSME_LIMIT_DAYS', '45', N'Days from acceptance of goods within which a Micro / Small supplier must be paid (MSMED Act s.15: 45 with a written agreement, 15 without).', 'system');
IF NOT EXISTS (SELECT 1 FROM dbo.nt_payment_run_setting WHERE setting_key = 'DEFAULT_CREDIT_DAYS')
    INSERT INTO dbo.nt_payment_run_setting (setting_key, setting_value, description, modified_by)
    VALUES ('DEFAULT_CREDIT_DAYS', '30', N'Days from acceptance used as the due date when an invoice carries no due date (and the supplier is not Micro / Small).', 'system');
GO

IF OBJECT_ID('dbo.payment_batch', 'U') IS NULL
CREATE TABLE dbo.payment_batch (
    batch_sno        INT IDENTITY(1,1) PRIMARY KEY,
    batch_no         VARCHAR(30)   NOT NULL UNIQUE,
    batch_date       DATE          NOT NULL,
    com_sno          INT           NULL,
    fund_plan_amount DECIMAL(18,2) NOT NULL,
    total_amount     DECIMAL(18,2) NOT NULL,
    item_count       INT           NOT NULL,
    file_name        VARCHAR(200)  NULL,
    file_content     NVARCHAR(MAX) NULL,
    status           VARCHAR(20)   NOT NULL DEFAULT 'Generated',
    created_by       VARCHAR(30)   NULL,
    created_at       DATETIME      NOT NULL DEFAULT GETDATE()
);
GO
IF OBJECT_ID('dbo.payment_batch_item', 'U') IS NULL
CREATE TABLE dbo.payment_batch_item (
    batch_item_sno       INT IDENTITY(1,1) PRIMARY KEY,
    batch_sno            INT           NOT NULL,
    payment_sno          INT           NOT NULL,
    line_no              INT           NOT NULL,
    vendor_sno           INT           NULL,
    vendor_name          NVARCHAR(200) NULL,
    supp_code            VARCHAR(50)   NULL,
    vendor_email         NVARCHAR(200) NULL,
    amount               DECIMAL(18,2) NOT NULL,
    mode                 VARCHAR(10)   NULL,
    debit_account        VARCHAR(100)  NULL,
    channel              VARCHAR(12)   NOT NULL,   -- BANK (in the file) / PORTAL / MANUAL (cheque, cash, DD) / ADJUSTMENT (nothing to pay out)
    beneficiary_name     NVARCHAR(100) NULL,
    account_no           VARCHAR(40)   NULL,
    ifsc                 VARCHAR(20)   NULL,
    bank_name            NVARCHAR(100) NULL,
    branch_name          NVARCHAR(100) NULL,
    invoice_nos          NVARCHAR(500) NULL,
    supplier_invoice_nos NVARCHAR(500) NULL,
    msme_label           VARCHAR(20)   NULL,
    narration            NVARCHAR(200) NULL,
    CONSTRAINT FK_payment_batch_item_batch FOREIGN KEY (batch_sno) REFERENCES dbo.payment_batch (batch_sno)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_payment_batch_item_payment' AND object_id = OBJECT_ID('dbo.payment_batch_item'))
    CREATE UNIQUE INDEX UX_payment_batch_item_payment ON dbo.payment_batch_item (payment_sno);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_batch_item_batch' AND object_id = OBJECT_ID('dbo.payment_batch_item'))
    CREATE INDEX IX_payment_batch_item_batch ON dbo.payment_batch_item (batch_sno);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_payment_info_batch')
    ALTER TABLE dbo.payment_info ADD CONSTRAINT FK_payment_info_batch FOREIGN KEY (batch_sno) REFERENCES dbo.payment_batch (batch_sno);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_payment_info_status' AND object_id = OBJECT_ID('dbo.payment_info'))
    CREATE INDEX IX_payment_info_status ON dbo.payment_info (status, batch_sno);
GO

-- existing payments: give them the org the approval / run screens filter on, and a processed time
UPDATE pi SET com_sno = o.com_sno, div_sno = o.div_sno, brn_sno = o.brn_sno, dept_sno = o.dept_sno
FROM dbo.payment_info pi
CROSS APPLY (
    SELECT TOP 1 IIF(i.com_sno IS NULL, p.com_sno, i.com_sno)   AS com_sno, IIF(i.com_sno IS NULL, p.div_sno, i.div_sno)   AS div_sno,
                 IIF(i.com_sno IS NULL, p.brn_sno, i.brn_sno)   AS brn_sno, IIF(i.com_sno IS NULL, p.dept_sno, i.dept_sno) AS dept_sno
    FROM dbo.payment_allocation_details pad
    JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = pad.invoice_alloc_sno
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    WHERE pad.payment_sno = pi.payment_sno
    ORDER BY i.invoice_sno
) o
WHERE pi.com_sno IS NULL;
UPDATE dbo.payment_info SET processed_at = ISNULL(modified_date, created_date)
WHERE processed_at IS NULL AND status NOT IN ('Pending Approval', 'Approved', 'Rejected', 'Cancelled');
GO

-- ── 2. a payment's invoice lines, with the receipt dates ────────────────────
-- One row per payment x invoice: what the payment pays on it, and when the goods came in (gate entry / approved GRN of the
-- invoice's PO). @payment_sno NULL = every payment. Rejected / cancelled payments are read from the archive.
CREATE OR ALTER FUNCTION dbo.fn_nt_PaymentLines (@payment_sno INT)
RETURNS TABLE
AS
RETURN
(
    WITH alloc AS (
        SELECT pad.payment_sno, pad.invoice_alloc_sno, pad.amount FROM dbo.payment_allocation_details pad
        WHERE @payment_sno IS NULL OR pad.payment_sno = @payment_sno
        UNION ALL
        SELECT a.payment_sno, a.invoice_alloc_sno, a.amount FROM dbo.payment_allocation_archive a
        WHERE @payment_sno IS NULL OR a.payment_sno = @payment_sno
    ),
    per_inv AS (
        SELECT a.payment_sno, i.invoice_sno, i.invoice_no, i.vendor_invoice_no, i.po_basic_sno, i.invoice_date, i.due_date,
               SUM(a.amount) AS amount, MIN(iad.bucket_type) AS bucket_type
        FROM alloc a
        JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
        JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
        GROUP BY a.payment_sno, i.invoice_sno, i.invoice_no, i.vendor_invoice_no, i.po_basic_sno, i.invoice_date, i.due_date
    )
    SELECT x.payment_sno, x.invoice_sno, x.invoice_no, x.vendor_invoice_no AS supplier_invoice_no, x.po_basic_sno, p.po_df_no AS po_no,
           x.invoice_date, x.due_date AS agreed_due_date, x.amount, x.bucket_type,
           ge.gate_entry_nos, ge.gate_entry_date, g.grn_nos, g.grn_date,
           CAST(CASE WHEN ge.gate_entry_date IS NULL THEN g.grn_date
                     WHEN g.grn_date IS NULL THEN ge.gate_entry_date
                     WHEN ge.gate_entry_date <= g.grn_date THEN ge.gate_entry_date ELSE g.grn_date END AS DATE) AS received_date
    FROM per_inv x
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = x.po_basic_sno
    OUTER APPLY (
        SELECT STRING_AGG(e.gate_entry_no, ', ') WITHIN GROUP (ORDER BY e.gate_entry_sno) AS gate_entry_nos, MIN(e.received_date) AS gate_entry_date
        FROM dbo.nt_gate_entry e WHERE e.po_basic_sno = x.po_basic_sno
    ) ge
    OUTER APPLY (
        SELECT STRING_AGG('GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6), ', ')
                   WITHIN GROUP (ORDER BY b.grn_basic_sno) AS grn_nos,
               MIN(b.received_date) AS grn_date
        FROM dbo.grn_basic_info b WHERE b.po_basic_sno = x.po_basic_sno AND b.is_active = 'Y' AND b.status IN ('Approved', 'Received')
    ) g
);
GO

-- ── 3. "paid" means settled: a saved / approved payment only reserves its bills ──
-- Same as sql/64 except `paid` counts only payments that are not Pending Approval / Approved (Rejected / Cancelled hold no
-- allocations), so a bill is "closed" - and its notes become supplier-wide - only once the money has actually gone.
CREATE OR ALTER FUNCTION dbo.fn_nt_PaymentNoteScope (@vendor_sno INT)
RETURNS TABLE
AS
RETURN
(
    WITH n AS (
        SELECT CAST('DEBIT' AS VARCHAR(6)) AS note_type, d.debit_note_sno AS note_sno, d.debit_note_no AS note_no,
               d.po_basic_sno, d.grn_basic_sno, d.com_sno, d.debit_note_date AS note_date, d.total_amount AS amount, d.remarks
        FROM dbo.debit_note_basic_info d
        WHERE d.vendor_sno = @vendor_sno AND d.is_active = 'Y' AND ISNULL(d.total_amount, 0) > 0
          AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'DEBIT_NOTE' AND pa.ref_sno = d.debit_note_sno)
        UNION ALL
        SELECT 'CREDIT', c.credit_note_sno, c.credit_note_no,
               c.po_basic_sno, c.grn_basic_sno, c.com_sno, c.credit_note_date, c.total_amount, c.remarks
        FROM dbo.credit_note_basic_info c
        WHERE c.vendor_sno = @vendor_sno AND c.is_active = 'Y' AND ISNULL(c.total_amount, 0) > 0
          AND NOT EXISTS (SELECT 1 FROM dbo.payment_adjustment pa WHERE pa.adj_type = 'CREDIT_NOTE' AND pa.ref_sno = c.credit_note_sno)
    ),
    inv AS (   -- the supplier's live invoices, and whether each is paid in full (settled payments only)
        SELECT i.invoice_sno, i.po_basic_sno,
               i.invoice_no + CASE WHEN NULLIF(LTRIM(RTRIM(i.vendor_invoice_no)), '') IS NULL THEN '' ELSE ' (' + LTRIM(RTRIM(i.vendor_invoice_no)) + ')' END AS invoice_label,
               CAST(CASE WHEN a.alloc_count > 0 AND a.paid_total > 0 AND a.release_total - a.paid_total <= 0.01 THEN 1 ELSE 0 END AS BIT) AS is_closed
        FROM dbo.invoice_info i
        OUTER APPLY (
            SELECT COUNT(*) AS alloc_count, SUM(iad.release_amount) AS release_total, SUM(ISNULL(pd.paid, 0)) AS paid_total
            FROM dbo.invoice_allocation_details iad
            OUTER APPLY (SELECT SUM(pad.amount) AS paid
                         FROM dbo.payment_allocation_details pad
                         JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno AND pyi.status NOT IN ('Pending Approval', 'Approved', 'Rejected', 'Cancelled')
                         WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno) pd
            WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
        ) a
        WHERE i.vendor_sno = @vendor_sno AND i.is_active = 'Y'
    ),
    line AS (  -- bills that allocate the same PO line(s) the note was raised on
        SELECT DISTINCT it.note_type, it.note_sno, iad.invoice_sno
        FROM (
            SELECT 'DEBIT' AS note_type, di.debit_note_sno AS note_sno, di.po_item_sno
            FROM dbo.debit_note_item_details di WHERE di.is_active = 'Y' AND di.po_item_sno IS NOT NULL
            UNION ALL
            SELECT 'CREDIT', ci.credit_note_sno, ci.po_item_sno
            FROM dbo.credit_note_item_details ci WHERE ci.is_active = 'Y' AND ci.po_item_sno IS NOT NULL
        ) it
        JOIN n ON n.note_type = it.note_type AND n.note_sno = it.note_sno
        JOIN dbo.invoice_allocation_details iad ON iad.po_item_sno = it.po_item_sno AND iad.is_active = 'Y'
        JOIN inv ON inv.invoice_sno = iad.invoice_sno
    ),
    src AS (
        SELECT l.note_type, l.note_sno, l.invoice_sno FROM line l
        UNION ALL   -- no bill allocates those lines: every live invoice on the note's PO
        SELECT n.note_type, n.note_sno, inv.invoice_sno
        FROM n JOIN inv ON inv.po_basic_sno = n.po_basic_sno
        WHERE NOT EXISTS (SELECT 1 FROM line l WHERE l.note_type = n.note_type AND l.note_sno = n.note_sno)
    )
    SELECT n.note_type, n.note_sno, n.note_no, n.po_basic_sno, n.grn_basic_sno, n.com_sno, n.note_date, n.amount, n.remarks,
           s.invoice_sno, inv.invoice_label, inv.is_closed
    FROM n
    LEFT JOIN src s ON s.note_type = n.note_type AND s.note_sno = n.note_sno
    LEFT JOIN inv ON inv.invoice_sno = s.invoice_sno
);
GO

-- Payment screen list: same as the live version (sql/48 + the Service PO invoice sync), but what a saved / approved payment
-- has reserved is no longer shown as "paid" and is no longer outstanding.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPayableBillsNet
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    BEGIN TRY
        EXEC dbo.sp_nt_SyncServicePoInvoicesToPayables;
    END TRY
    BEGIN CATCH
        -- a sync problem must never take the whole Payment list down
    END CATCH

    SELECT
        iad.invoice_alloc_sno AS bill_sno, i.invoice_sno, i.invoice_no AS bill_no, i.vendor_invoice_no AS supplier_invoice_no,
        p.po_df_no AS po_no, i.vendor_sno, k.company_name AS vendor_name, i.invoice_date, i.due_date, iad.bucket_type,
        iad.allocated_amount, iad.hold_amount, iad.release_amount AS net_payable,
        paid.paidSoFar AS paid_amount, paid.reservedSoFar AS reserved_amount,
        iad.release_amount - paid.paidSoFar - paid.reservedSoFar AS outstanding,
        i.invoice_amount, i.taxable_value, i.tds_section_code, i.itc_status, i.payment_hold_override,
        CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 THEN 1 ELSE 0 END AS BIT) AS gst_supplier,
        CAST(CASE WHEN i.gst_journal_sno IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS gst_booked,
        CASE WHEN iad.bucket_type = 'SERVICE' THEN 'NA'
             WHEN EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.po_basic_sno = i.po_basic_sno AND g.is_active = 'Y' AND g.status IN ('Approved', 'Received')) THEN 'Done'
             WHEN EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.po_basic_sno = i.po_basic_sno AND g.is_active = 'Y' AND g.status = 'Pending Approval') THEN 'Pending approval'
             ELSE 'No GRN' END AS grn_state,
        CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, '') NOT IN ('Eligible', 'Ineligible')
                       AND ISNULL(i.payment_hold_override, 'N') <> 'Y' THEN 1 ELSE 0 END AS BIT) AS on_hold_2b
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN 0 ELSE pad.amount END), 0) AS paidSoFar,
               ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN pad.amount ELSE 0 END), 0) AS reservedSoFar
        FROM dbo.payment_allocation_details pad
        JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    WHERE iad.is_active = 'Y' AND iad.release_amount > paid.paidSoFar + paid.reservedSoFar + 0.01
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY i.invoice_date, iad.invoice_alloc_sno;
END
GO

-- Invoice-wise ledger: same as sql/63, with settled vs reserved. payment_status = Paid | In payment (a saved / approved
-- payment holds it) | Part paid | Unpaid | Not allocated.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPoInvoiceLedger
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no AS supplier_invoice_no, i.po_basic_sno, p.po_df_no AS po_no,
           i.vendor_sno, i.invoice_date, i.due_date, i.invoice_amount, i.match_status, i.verification_status,
           i.invoice_file_url,
           ISNULL(a.release_total, 0) AS release_total,
           ISNULL(a.paid_total, 0)    AS paid_total,
           ISNULL(a.reserved_total, 0) AS reserved_total,
           ISNULL(a.release_total, 0) - ISNULL(a.paid_total, 0) - ISNULL(a.reserved_total, 0) AS outstanding,
           CASE WHEN a.alloc_count IS NULL THEN 'Not allocated'
                WHEN a.release_total - a.paid_total <= 0.01 AND a.paid_total > 0 THEN 'Paid'
                WHEN a.reserved_total > 0 THEN 'In payment'
                WHEN a.paid_total > 0 THEN 'Part paid'
                ELSE 'Unpaid' END AS payment_status,
           a.payment_nos,
           (SELECT COUNT(*) FROM dbo.invoice_info d
             WHERE d.is_active = 'Y' AND d.invoice_sno <> i.invoice_sno AND d.vendor_sno = i.vendor_sno
               AND LEN(ISNULL(i.vendor_invoice_no, '')) > 0
               AND UPPER(LTRIM(RTRIM(d.vendor_invoice_no))) = UPPER(LTRIM(RTRIM(i.vendor_invoice_no)))) AS dup_count
    FROM dbo.invoice_info i
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    OUTER APPLY (
        SELECT COUNT(*) AS alloc_count,
               SUM(iad.release_amount) AS release_total,
               SUM(ISNULL(pd.paid, 0)) AS paid_total,
               SUM(ISNULL(pd.reserved, 0)) AS reserved_total,
               (SELECT STRING_AGG(x.payment_no, ', ') FROM (
                    SELECT DISTINCT pi.payment_no
                    FROM dbo.invoice_allocation_details iad2
                    JOIN dbo.payment_allocation_details pad ON pad.invoice_alloc_sno = iad2.invoice_alloc_sno
                    JOIN dbo.payment_info pi ON pi.payment_sno = pad.payment_sno
                    WHERE iad2.invoice_sno = i.invoice_sno AND iad2.is_active = 'Y') x) AS payment_nos
        FROM dbo.invoice_allocation_details iad
        OUTER APPLY (
            SELECT SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN 0 ELSE pad.amount END) AS paid,
                   SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN pad.amount ELSE 0 END) AS reserved
            FROM dbo.payment_allocation_details pad
            JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno
            WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
        ) pd
        WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
    ) a
    WHERE i.is_active = 'Y' AND i.po_basic_sno IS NOT NULL
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY i.po_basic_sno, i.invoice_date, i.invoice_sno;

    SELECT g.grn_basic_sno, g.grn_no, g.po_basic_sno, p.po_df_no AS po_no, g.vendor_sno, g.status, g.received_date,
           NULLIF(LTRIM(RTRIM(g.doc_ref_no)), '') AS invoice_no, g.invoice_date, g.invoice_amount, g.invoice_doc_url,
           CAST(CASE WHEN NULLIF(LTRIM(RTRIM(g.doc_ref_no)), '') IS NOT NULL AND g.invoice_date IS NOT NULL AND g.invoice_amount IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS has_invoice_data,
           CASE WHEN NULLIF(LTRIM(RTRIM(g.doc_ref_no)), '') IS NULL THEN 0
                ELSE (SELECT COUNT(*) FROM dbo.grn_basic_info d
                       WHERE d.is_active = 'Y' AND d.grn_basic_sno <> g.grn_basic_sno AND d.vendor_sno = g.vendor_sno
                         AND UPPER(LTRIM(RTRIM(d.doc_ref_no))) = UPPER(LTRIM(RTRIM(g.doc_ref_no))))
                   + (SELECT COUNT(*) FROM dbo.invoice_info d
                       WHERE d.is_active = 'Y' AND d.vendor_sno = g.vendor_sno AND d.po_basic_sno <> g.po_basic_sno
                         AND UPPER(LTRIM(RTRIM(d.vendor_invoice_no))) = UPPER(LTRIM(RTRIM(g.doc_ref_no)))) END AS dup_count
    FROM dbo.grn_basic_info g
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = g.po_basic_sno
    WHERE g.is_active = 'Y' AND g.status IN ('Approved', 'Received', 'Pending Approval')
      AND (@vendor_sno IS NULL OR g.vendor_sno = @vendor_sno)
    ORDER BY g.po_basic_sno, g.grn_basic_sno;
END
GO

-- ── 4. approval ─────────────────────────────────────────────────────────────
-- Gives back everything a saved payment reserved. Call inside the caller's transaction.
CREATE OR ALTER PROCEDURE dbo.sp_nt_ReversePaymentReservation
    @payment_sno INT, @by VARCHAR(30) = NULL, @reason NVARCHAR(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE s SET adjusted_amount = s.adjusted_amount - a.amount
    FROM dbo.nt_supplier_advance_payment s
    JOIN dbo.payment_adjustment a ON a.adj_type = 'ADVANCE' AND a.ref_sno = s.advance_sno AND a.payment_sno = @payment_sno;
    DELETE FROM dbo.payment_adjustment WHERE payment_sno = @payment_sno;       -- frees its debit / credit notes too
    DELETE FROM dbo.tds_deduction WHERE payment_sno = @payment_sno;
    INSERT INTO dbo.payment_allocation_archive (payment_sno, invoice_alloc_sno, amount, created_date, reversed_by, reason)
    SELECT payment_sno, invoice_alloc_sno, amount, created_date, @by, @reason FROM dbo.payment_allocation_details WHERE payment_sno = @payment_sno;
    DELETE FROM dbo.payment_allocation_details WHERE payment_sno = @payment_sno;
END
GO

-- Submit a saved payment: workflow found -> 'Pending Approval' with the first approver, none -> 'Approved'.
-- @jsonInput: { payment_sno, created_by }.  @silent = 1 when called from inside sp_nt_ReleasePaymentNet (no result set).
CREATE OR ALTER PROCEDURE dbo.sp_nt_SubmitPaymentForApproval
    @jsonInput NVARCHAR(MAX), @silent BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @com INT, @div INT, @brn INT, @dept INT, @wf INT, @first VARCHAR(30);

    SELECT @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno FROM dbo.payment_info WHERE payment_sno = @pay;
    IF @@ROWCOUNT = 0 THROW 56001, 'Payment not found.', 1;

    DECLARE @entity VARCHAR(50) = dbo.fn_resolve_approval_entity('Payment', 'STANDARD');
    SELECT TOP 1 @wf = wt.workflow_types_id
    FROM dbo.workflow_types wt
    JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id AND awm.is_active = 'Y'
    WHERE wt.is_active = 'Y' AND awm.entity_type = @entity
      AND wt.com_sno = @com AND wt.div_sno = @div AND wt.brn_sno = @brn AND wt.dept_sno = @dept
    ORDER BY wt.workflow_types_id DESC;

    IF @wf IS NOT NULL
        SELECT TOP 1 @first = JSON_VALUE(j.[value], '$.approver_ecno')
        FROM dbo.workflow_stage ws
        CROSS APPLY OPENJSON(ws.stage_order_json) j
        WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y'
        ORDER BY CAST(j.[key] AS INT);

    IF @wf IS NOT NULL AND @first IS NOT NULL
    BEGIN
        UPDATE dbo.payment_info SET status = 'Pending Approval', workflow_types_id = @wf, current_approver_id = @first, approved_at = NULL WHERE payment_sno = @pay;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
        VALUES (@pay, 'SUBMITTED', @by, N'Submitted for approval to ' + @first);
    END
    ELSE
    BEGIN
        UPDATE dbo.payment_info SET status = 'Approved', workflow_types_id = NULL, current_approver_id = NULL, approved_at = GETDATE() WHERE payment_sno = @pay;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
        VALUES (@pay, 'AUTO_APPROVED', @by, N'No Payment approval workflow is configured for this department');
    END

    IF @silent = 0
        SELECT payment_sno, payment_no, status, current_approver_id, workflow_types_id,
               CASE WHEN status = 'Approved' THEN 1 ELSE 0 END AS is_final
        FROM dbo.payment_info WHERE payment_sno = @pay;
END
GO

-- Approve / reject.  @jsonInput: { payment_sno, action: 'approve'|'reject', approved_by, comments }
-- result = APPROVED_NEXT | FINAL | REJECTED (+ next_approver)
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApprovePayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT),
            @action VARCHAR(10) = LOWER(JSON_VALUE(@jsonInput, '$.action')),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.approved_by'),
            @comments NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.comments');

    IF @action IS NULL OR @action NOT IN ('approve', 'reject') THROW 56005, 'action must be approve or reject.', 1;

    DECLARE @status VARCHAR(20), @cur VARCHAR(30), @wf INT, @creator VARCHAR(30), @pno VARCHAR(30), @vendor INT, @net DECIMAL(18,2),
            @com INT, @div INT, @brn INT, @dept INT;
    SELECT @status = status, @cur = current_approver_id, @wf = workflow_types_id, @creator = created_by, @pno = payment_no,
           @vendor = vendor_sno, @net = net_paid, @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
    FROM dbo.payment_info WHERE payment_sno = @pay AND is_active = 'Y';

    IF @status IS NULL THROW 56001, 'Payment not found.', 1;
    IF @status <> 'Pending Approval' THROW 56002, 'This payment is not awaiting approval.', 1;
    IF @cur IS NULL OR @cur <> @by THROW 56003, 'You are not the current approver of this payment.', 1;
    IF @action = 'reject' AND (@comments IS NULL OR LTRIM(RTRIM(@comments)) = '') THROW 56004, 'Remarks are required to reject.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        IF @action = 'reject'
        BEGIN
            EXEC dbo.sp_nt_ReversePaymentReservation @payment_sno = @pay, @by = @by, @reason = @comments;
            UPDATE dbo.payment_info SET status = 'Rejected', current_approver_id = NULL, modified_by = @by, modified_date = GETDATE() WHERE payment_sno = @pay;
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'REJECTED', @by, @comments);
            COMMIT TRANSACTION;
            SELECT 'REJECTED' AS result, @pay AS payment_sno, @pno AS payment_no, @vendor AS vendor_sno, @net AS net_paid, @creator AS created_by,
                   CAST(NULL AS VARCHAR(30)) AS next_approver, 'Rejected' AS status, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno;
            RETURN;
        END

        DECLARE @next VARCHAR(30) = NULL;
        DECLARE @stages TABLE (seq INT, ecno VARCHAR(30));
        INSERT INTO @stages (seq, ecno)
        SELECT CAST(j.[key] AS INT), JSON_VALUE(j.[value], '$.approver_ecno')
        FROM dbo.workflow_stage ws CROSS APPLY OPENJSON(ws.stage_order_json) j
        WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y';
        DECLARE @curseq INT = (SELECT MIN(seq) FROM @stages WHERE ecno = @cur);
        SELECT TOP 1 @next = ecno FROM @stages WHERE seq > ISNULL(@curseq, 2147483647) ORDER BY seq;

        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'APPROVED', @by, @comments);

        IF @next IS NULL
        BEGIN
            UPDATE dbo.payment_info SET status = 'Approved', current_approver_id = NULL, approved_at = GETDATE(), modified_by = @by, modified_date = GETDATE() WHERE payment_sno = @pay;
            COMMIT TRANSACTION;
            SELECT 'FINAL' AS result, @pay AS payment_sno, @pno AS payment_no, @vendor AS vendor_sno, @net AS net_paid, @creator AS created_by,
                   CAST(NULL AS VARCHAR(30)) AS next_approver, 'Approved' AS status, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno;
        END
        ELSE
        BEGIN
            UPDATE dbo.payment_info SET current_approver_id = @next, modified_by = @by, modified_date = GETDATE() WHERE payment_sno = @pay;
            COMMIT TRANSACTION;
            SELECT 'APPROVED_NEXT' AS result, @pay AS payment_sno, @pno AS payment_no, @vendor AS vendor_sno, @net AS net_paid, @creator AS created_by,
                   @next AS next_approver, 'Pending Approval' AS status, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- Cancel a payment that has not been paid yet (awaiting approval, or approved and still waiting in the Payment Run).
-- @jsonInput: { payment_sno, cancelled_by, reason }
CREATE OR ALTER PROCEDURE dbo.sp_nt_CancelPayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.cancelled_by'),
            @reason NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.reason');
    DECLARE @status VARCHAR(20), @pno VARCHAR(30), @vendor INT, @net DECIMAL(18,2), @creator VARCHAR(30), @cur VARCHAR(30),
            @com INT, @div INT, @brn INT, @dept INT;
    SELECT @status = status, @pno = payment_no, @vendor = vendor_sno, @net = net_paid, @creator = created_by, @cur = current_approver_id,
           @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
    FROM dbo.payment_info WHERE payment_sno = @pay AND is_active = 'Y';
    IF @status IS NULL THROW 56001, 'Payment not found.', 1;
    IF @status NOT IN ('Pending Approval', 'Approved') THROW 56006, 'Only a payment that has not been paid yet can be cancelled.', 1;
    IF @by IS NULL OR @reason IS NULL OR LTRIM(RTRIM(@reason)) = '' THROW 56007, 'A reason is required to cancel a payment.', 1;

    BEGIN TRANSACTION;
    BEGIN TRY
        EXEC dbo.sp_nt_ReversePaymentReservation @payment_sno = @pay, @by = @by, @reason = @reason;
        UPDATE dbo.payment_info SET status = 'Cancelled', current_approver_id = NULL, modified_by = @by, modified_date = GETDATE() WHERE payment_sno = @pay;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'CANCELLED', @by, @reason);
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
    SELECT 'CANCELLED' AS result, @pay AS payment_sno, @pno AS payment_no, @vendor AS vendor_sno, @net AS net_paid, @creator AS created_by,
           @cur AS was_waiting_on, @status AS was_status, 'Cancelled' AS status, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno;
END
GO

-- ── 5. Save (was: release) ──────────────────────────────────────────────────
-- @jsonInput: { vendor_sno, payment_date, mode, bank_account?, reference_no?, remarks?, created_by, preview?, apply_tds?,
--   allocations: [{ invoice_alloc_sno, amount }], advances: [{ advance_sno, amount }], notes: [{ type: 'DEBIT'|'CREDIT', note_sno }] }
-- Same checks and the same TDS / advance / note working as sql/64. What changed: the payment is created 'Pending Approval' and
-- submitted for approval (so it comes back 'Approved' at once when no workflow is configured), the org it belongs to is
-- stored on it, and NO journal is posted - that happens when the payment is paid in a Payment Run (sp_nt_CreatePaymentBatch).
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

    -- every bucket must belong to this supplier and still have that much unpaid release amount (a saved / approved payment has already reserved its share)
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

    -- notes (sql/64: only notes offered for the bills being paid; a note already redeemed elsewhere is named)
    DECLARE @notes TABLE (note_type VARCHAR(6), note_sno INT, amount DECIMAL(18,2), note_no VARCHAR(60));
    IF @noteJson IS NOT NULL
        INSERT INTO @notes (note_type, note_sno) SELECT DISTINCT UPPER(JSON_VALUE(value, '$.type')), TRY_CAST(JSON_VALUE(value, '$.note_sno') AS INT) FROM OPENJSON(@noteJson);
    IF EXISTS (SELECT 1 FROM @notes WHERE note_type NOT IN ('DEBIT', 'CREDIT') OR note_sno IS NULL) THROW 55016, 'Each note needs type DEBIT or CREDIT and a note_sno.', 1;
    UPDATE n SET amount = d.total_amount, note_no = d.debit_note_no FROM @notes n JOIN dbo.debit_note_basic_info d ON d.debit_note_sno = n.note_sno AND d.vendor_sno = @v AND d.is_active = 'Y'
        WHERE n.note_type = 'DEBIT';
    UPDATE n SET amount = c.total_amount, note_no = c.credit_note_no FROM @notes n JOIN dbo.credit_note_basic_info c ON c.credit_note_sno = n.note_sno AND c.vendor_sno = @v AND c.is_active = 'Y'
        WHERE n.note_type = 'CREDIT';
    IF EXISTS (SELECT 1 FROM @notes WHERE amount IS NULL) THROW 55017, 'A note is unknown, belongs to another supplier, or is no longer active.', 1;

    DECLARE @gone NVARCHAR(400) = (SELECT STRING_AGG(n.note_no + ' (' + ISNULL(pi.payment_no, 'another payment') + ')', ', ')
        FROM @notes n JOIN dbo.payment_adjustment pa ON pa.adj_type = CASE n.note_type WHEN 'DEBIT' THEN 'DEBIT_NOTE' ELSE 'CREDIT_NOTE' END AND pa.ref_sno = n.note_sno
        LEFT JOIN dbo.payment_info pi ON pi.payment_sno = pa.payment_sno);
    IF @gone IS NOT NULL
    BEGIN
        DECLARE @goneMsg NVARCHAR(500) = N'Already redeemed in another payment - refresh and untick it: ' + @gone;
        THROW 55024, @goneMsg, 1;
    END

    DECLARE @invJson NVARCHAR(MAX) = (SELECT '[' + STRING_AGG(CAST(invoice_sno AS VARCHAR(12)), ',') + ']' FROM @inv);
    DECLARE @offered TABLE (note_type VARCHAR(6), note_sno INT);
    INSERT INTO @offered SELECT note_type, note_sno FROM dbo.fn_nt_PaymentNotesForBills(@v, @invJson);
    IF EXISTS (SELECT 1 FROM @notes n WHERE NOT EXISTS (SELECT 1 FROM @offered o WHERE o.note_type = n.note_type AND o.note_sno = n.note_sno))
    BEGIN
        DECLARE @off NVARCHAR(400) = (SELECT STRING_AGG(n.note_no, ', ') FROM @notes n WHERE NOT EXISTS (SELECT 1 FROM @offered o WHERE o.note_type = n.note_type AND o.note_sno = n.note_sno));
        DECLARE @offMsg NVARCHAR(500) = N'Not available for the invoices being paid (its own bill is still open, or it belongs to another company): ' + @off;
        THROW 55022, @offMsg, 1;
    END

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

    -- org of the payment: the invoice's own, else its PO's (some invoices carry no company) - the approval workflow is looked up on it
    DECLARE @com INT, @div INT, @brn INT, @dept INT;
    SELECT TOP 1 @com  = IIF(i.com_sno IS NULL, p.com_sno,  i.com_sno),  @div  = IIF(i.com_sno IS NULL, p.div_sno,  i.div_sno),
                 @brn  = IIF(i.com_sno IS NULL, p.brn_sno,  i.brn_sno),  @dept = IIF(i.com_sno IS NULL, p.dept_sno, i.dept_sno)
    FROM @inv x JOIN dbo.invoice_info i ON i.invoice_sno = x.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    ORDER BY x.invoice_sno;

    BEGIN TRANSACTION;
    BEGIN TRY
        -- one save per supplier at a time: the re-check below cannot race another payment for the same note
        DECLARE @lockName NVARCHAR(100) = N'pay_release_vendor_' + CAST(@v AS NVARCHAR(12)), @lk INT;
        EXEC @lk = sp_getapplock @Resource = @lockName, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;
        IF @lk < 0 THROW 55023, 'Another payment for this supplier is being saved right now - please try again in a moment.', 1;
        SET @gone = (SELECT STRING_AGG(n.note_no + ' (' + ISNULL(pi.payment_no, 'another payment') + ')', ', ')
            FROM @notes n JOIN dbo.payment_adjustment pa ON pa.adj_type = CASE n.note_type WHEN 'DEBIT' THEN 'DEBIT_NOTE' ELSE 'CREDIT_NOTE' END AND pa.ref_sno = n.note_sno
            LEFT JOIN dbo.payment_info pi ON pi.payment_sno = pa.payment_sno);
        IF @gone IS NOT NULL
        BEGIN
            SET @goneMsg = N'Already redeemed in another payment - refresh and untick it: ' + @gone;
            THROW 55024, @goneMsg, 1;
        END
        -- the bills may have been reserved by another payment since the check above
        IF EXISTS (
            SELECT 1 FROM @alloc a
            JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = a.invoice_alloc_sno
            OUTER APPLY (SELECT ISNULL(SUM(pad.amount), 0) AS paid FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = a.invoice_alloc_sno) p
            WHERE a.amount > (iad.release_amount - p.paid) + 0.01
        )
            THROW 55013, 'An allocation exceeds its unpaid release amount - another payment has just used it. Refresh and try again.', 1;

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(payment_no, 6) AS INT)), 0) + 1 FROM dbo.payment_info WITH (UPDLOCK, HOLDLOCK) WHERE payment_no LIKE 'PAY-' + @year + '-%';
        DECLARE @pno VARCHAR(30) = 'PAY-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6), @psno INT;

        INSERT INTO dbo.payment_info (payment_no, vendor_sno, payment_date, amount, mode, bank_account, reference_no, status, remarks, is_active, created_by, created_date,
                                      gross_amount, tds_amount, advance_adjusted, note_adjusted, net_paid, com_sno, div_sno, brn_sno, dept_sno)
        VALUES (@pno, @v, @pdate, @gross, @mode, @bank, @ref, 'Pending Approval', @rem, 'Y', @by, GETDATE(),
                @gross, @tds, @advTotal, @dn - @cn, @net, @com, @div, @brn, @dept);
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

        DECLARE @sub NVARCHAR(200) = (SELECT @psno AS payment_sno, @by AS created_by FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC dbo.sp_nt_SubmitPaymentForApproval @jsonInput = @sub, @silent = 1;

        COMMIT TRANSACTION;
        SELECT p.payment_sno, p.payment_no, @gross AS gross_amount, @tds AS tds_amount, @advTotal AS advance_adjusted,
               @dn AS debit_notes, @cn AS credit_notes, @net AS net_paid, CAST(NULL AS INT) AS journal_sno, 'SUCCESS' AS result,
               p.com_sno, p.div_sno, p.brn_sno, p.dept_sno,
               p.status, p.current_approver_id, CAST(CASE WHEN p.status = 'Approved' THEN 1 ELSE 0 END AS BIT) AS is_final
        FROM dbo.payment_info p WHERE p.payment_sno = @psno;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

-- ── 6. read side: entries (approval screen + pending payments), activity ────
-- @jsonInput: { view: 'run' | 'mine' | 'all', payment_sno?, vendor_sno?, com_sno?, status?, ecno?, hierarchy?, with_lines?, limit? }
--   run  : Approved payments not yet in a batch - the Payment Run list, in priority order (msme_tier, due date, oldest receipt)
--   mine : Pending Approval payments waiting on `ecno`
--   all  : every payment (newest first, up to `limit`, default 300); restricted to the caller's hierarchy unless the caller
--          created it or is its current approver
--   payment_sno : just that payment, whatever its status
-- -> 3 recordsets: entries, lines (when with_lines; default for run / one payment), settings
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentEntries
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @view VARCHAR(10) = LOWER(ISNULL(NULLIF(JSON_VALUE(@jsonInput, '$.view'), ''), 'run')),
            @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT),
            @vendor INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @comf INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @status VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.status'), ''),
            @ecno VARCHAR(30) = NULLIF(JSON_VALUE(@jsonInput, '$.ecno'), ''),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 300),
            @today DATE = CAST(GETDATE() AS DATE);
    DECLARE @withLines BIT = CASE WHEN JSON_VALUE(@jsonInput, '$.with_lines') IN ('0', 'false') THEN 0
                                  WHEN JSON_VALUE(@jsonInput, '$.with_lines') IN ('1', 'true') THEN 1
                                  WHEN @pay IS NOT NULL OR @view = 'run' THEN 1 ELSE 0 END,
            @msmeDays INT = ISNULL((SELECT TRY_CAST(setting_value AS INT) FROM dbo.nt_payment_run_setting WHERE setting_key = 'MSME_LIMIT_DAYS'), 45),
            @creditDays INT = ISNULL((SELECT TRY_CAST(setting_value AS INT) FROM dbo.nt_payment_run_setting WHERE setting_key = 'DEFAULT_CREDIT_DAYS'), 30);

    -- which payments
    SELECT TOP (@limit) pi.payment_sno
    INTO #p
    FROM dbo.payment_info pi
    WHERE pi.is_active = 'Y'
      AND ( (@pay IS NOT NULL AND pi.payment_sno = @pay)
         OR (@pay IS NULL AND ( (@view = 'run'  AND pi.status = 'Approved' AND pi.batch_sno IS NULL)
                             OR (@view = 'mine' AND pi.status = 'Pending Approval' AND pi.current_approver_id = @ecno)
                             OR  @view = 'all') ) )
      AND (@status IS NULL OR pi.status = @status)
      AND (@vendor IS NULL OR pi.vendor_sno = @vendor)
      AND (@comf IS NULL OR pi.com_sno = @comf)
      AND (@view = 'mine' OR @hier IS NULL
           OR (@view <> 'run' AND (pi.created_by = @ecno OR pi.current_approver_id = @ecno))
           OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                      WHERE h.com_sno = pi.com_sno AND (h.div_sno IS NULL OR h.div_sno = pi.div_sno) AND (h.brn_sno IS NULL OR h.brn_sno = pi.brn_sno)))
    ORDER BY pi.payment_sno DESC;

    -- supplier's MSME class
    SELECT pi.payment_sno,
           CASE WHEN ISNULL(k.is_msme_avail, 'N') <> 'Y' AND NULLIF(LTRIM(RTRIM(k.msme_type)), '') IS NULL THEN NULL
                WHEN UPPER(LTRIM(RTRIM(k.msme_type))) = 'MICRO'  THEN 'MICRO'
                WHEN UPPER(LTRIM(RTRIM(k.msme_type))) = 'SMALL'  THEN 'SMALL'
                WHEN UPPER(LTRIM(RTRIM(k.msme_type))) = 'MEDIUM' THEN 'MEDIUM'
                ELSE 'MSME' END AS msme_class
    INTO #v
    FROM #p JOIN dbo.payment_info pi ON pi.payment_sno = #p.payment_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno;

    -- lines, with the due date of each
    SELECT l.payment_sno, l.invoice_sno, l.invoice_no, l.supplier_invoice_no, l.po_no, l.invoice_date, l.amount, l.bucket_type,
           l.gate_entry_nos, l.gate_entry_date, l.grn_nos, l.grn_date, l.received_date,
           COALESCE(l.received_date, l.invoice_date) AS start_date,
           CAST(CASE WHEN v.msme_class IN ('MICRO', 'SMALL', 'MSME') AND COALESCE(l.received_date, l.invoice_date) IS NOT NULL
                     THEN DATEADD(DAY, @msmeDays, COALESCE(l.received_date, l.invoice_date)) END AS DATE) AS statutory_due,
           CAST(CASE WHEN l.agreed_due_date >= ISNULL(l.invoice_date, '19000101') THEN l.agreed_due_date END AS DATE) AS agreed_due
    INTO #l0
    FROM #p JOIN dbo.fn_nt_PaymentLines(@pay) l ON l.payment_sno = #p.payment_sno
    JOIN #v v ON v.payment_sno = l.payment_sno;

    SELECT x.*,
           CAST(CASE WHEN x.statutory_due IS NOT NULL AND x.agreed_due IS NOT NULL THEN (CASE WHEN x.agreed_due < x.statutory_due THEN x.agreed_due ELSE x.statutory_due END)
                     WHEN x.statutory_due IS NOT NULL THEN x.statutory_due
                     WHEN x.agreed_due IS NOT NULL THEN x.agreed_due
                     WHEN x.start_date IS NOT NULL THEN DATEADD(DAY, @creditDays, x.start_date) END AS DATE) AS due_date
    INTO #l
    FROM #l0 x;

    -- one row per payment
    SELECT pi.payment_sno, pi.payment_no, pi.vendor_sno, k.company_name AS vendor_name, k.supp_code, k.email AS vendor_email,
           pi.mode, pi.bank_account AS debit_account, pi.reference_no, pi.remarks, pi.payment_date,
           pi.status, pi.current_approver_id, pi.workflow_types_id, pi.created_by, pi.created_date AS created_at, pi.approved_at, pi.processed_at,
           pi.batch_sno, b.batch_no,
           pi.gross_amount, pi.tds_amount, pi.advance_adjusted, pi.note_adjusted, ISNULL(pi.net_paid, pi.amount) AS net_paid, pi.amount,
           pi.com_sno, pi.div_sno, pi.brn_sno, pi.dept_sno, c.com_name,
           v.msme_class,
           CASE v.msme_class WHEN 'MICRO' THEN 'Micro' WHEN 'SMALL' THEN 'Small' WHEN 'MEDIUM' THEN 'Medium' WHEN 'MSME' THEN 'MSME' END AS msme_label,
           CASE v.msme_class WHEN 'MICRO' THEN 1 WHEN 'SMALL' THEN 2 WHEN 'MEDIUM' THEN 3 WHEN 'MSME' THEN 3 ELSE 4 END AS msme_tier,
           k.msme_no,
           CAST(CASE WHEN v.msme_class IN ('MICRO', 'SMALL', 'MSME') THEN 1 ELSE 0 END AS BIT) AS is_statutory,
           CAST(CASE WHEN k.pay_via_portal = 'Y' THEN 1 ELSE 0 END AS BIT) AS pay_via_portal, k.payment_portal_name, k.payment_portal_url,
           bk.ac_holder_name, CAST(bk.ac_number AS VARCHAR(30)) AS ac_number, bk.ifsc, bk.bank_name, bk.bank_branch_name,
           ch.channel,
           CAST(CASE WHEN ch.channel <> 'BANK' THEN 1
                     WHEN bk.ac_number IS NOT NULL AND NULLIF(LTRIM(RTRIM(bk.ifsc)), '') IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS bank_ready,
           agg.invoice_count, agg.invoice_nos, agg.supplier_invoice_nos, agg.po_nos, agg.gate_entry_nos, agg.grn_nos,
           agg.first_gate_entry_date, agg.first_grn_date, agg.accepted_date, agg.due_date, agg.statutory_due_date,
           DATEDIFF(DAY, @today, agg.due_date) AS days_to_due,
           CAST(CASE WHEN agg.due_date < @today THEN 1 ELSE 0 END AS BIT) AS is_overdue
    INTO #e
    FROM #p
    JOIN dbo.payment_info pi ON pi.payment_sno = #p.payment_sno
    JOIN #v v ON v.payment_sno = pi.payment_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = pi.vendor_sno
    LEFT JOIN dbo.payment_batch b ON b.batch_sno = pi.batch_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = pi.com_sno
    OUTER APPLY (SELECT TOP 1 x.ac_holder_name, x.ac_number, x.ifsc, x.bank_name, x.bank_branch_name
                 FROM dbo.kyc_bank_info x
                 WHERE x.kyc_basic_info_sno = pi.vendor_sno AND ISNULL(x.is_active, 'Y') = 'Y'
                 ORDER BY CASE WHEN x.is_primary = 'Y' THEN 0 ELSE 1 END, x.kyc_address_sno DESC) bk
    CROSS APPLY (SELECT CASE WHEN ISNULL(pi.net_paid, pi.amount) = 0 THEN 'ADJUSTMENT'
                             WHEN k.pay_via_portal = 'Y' THEN 'PORTAL'
                             WHEN UPPER(pi.mode) IN ('CHEQUE', 'CASH', 'DD') THEN 'MANUAL'
                             ELSE 'BANK' END AS channel) ch
    OUTER APPLY (
        SELECT COUNT(*) AS invoice_count,
               STRING_AGG(l.invoice_no, ', ') WITHIN GROUP (ORDER BY l.invoice_sno) AS invoice_nos,
               STRING_AGG(NULLIF(LTRIM(RTRIM(l.supplier_invoice_no)), ''), ', ') WITHIN GROUP (ORDER BY l.invoice_sno) AS supplier_invoice_nos,
               (SELECT STRING_AGG(d.po_no, ', ') FROM (SELECT DISTINCT po_no FROM #l WHERE payment_sno = pi.payment_sno AND po_no IS NOT NULL) d) AS po_nos,
               (SELECT STRING_AGG(d.gate_entry_nos, ', ') FROM (SELECT DISTINCT gate_entry_nos FROM #l WHERE payment_sno = pi.payment_sno AND gate_entry_nos IS NOT NULL) d) AS gate_entry_nos,
               (SELECT STRING_AGG(d.grn_nos, ', ') FROM (SELECT DISTINCT grn_nos FROM #l WHERE payment_sno = pi.payment_sno AND grn_nos IS NOT NULL) d) AS grn_nos,
               MIN(l.gate_entry_date) AS first_gate_entry_date, MIN(l.grn_date) AS first_grn_date, MIN(l.start_date) AS accepted_date,
               MIN(l.due_date) AS due_date, MIN(l.statutory_due) AS statutory_due_date
        FROM #l l WHERE l.payment_sno = pi.payment_sno
    ) agg;

    IF @view = 'run' AND @pay IS NULL
        SELECT * FROM #e ORDER BY msme_tier, CASE WHEN due_date IS NULL THEN 1 ELSE 0 END, due_date, accepted_date, net_paid, payment_sno;
    ELSE
        SELECT * FROM #e ORDER BY payment_sno DESC;

    SELECT l.payment_sno, l.invoice_sno, l.invoice_no, l.supplier_invoice_no, l.po_no, l.invoice_date, l.amount, l.bucket_type,
           l.gate_entry_nos, l.gate_entry_date, l.grn_nos, l.grn_date, l.start_date AS received_date, l.due_date
    FROM #l l WHERE @withLines = 1
    ORDER BY l.payment_sno, l.invoice_sno;

    SELECT setting_key, setting_value FROM dbo.nt_payment_run_setting;
END
GO

-- One payment's approval trail, what it adjusted and its approver chain.  @jsonInput: { payment_sno }
-- -> 3 recordsets: history, adjustments, stages
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentActivity
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT), @wf INT;
    SELECT @wf = workflow_types_id FROM dbo.payment_info WHERE payment_sno = @pay;

    SELECT h.action_type, h.status_by, h.comment, CONVERT(VARCHAR(30), h.created_at, 120) AS created_at
    FROM dbo.payment_approval_history h WHERE h.payment_sno = @pay ORDER BY h.history_sno DESC;

    SELECT a.adj_type, a.ref_sno, a.invoice_sno, a.amount,
           CASE a.adj_type WHEN 'ADVANCE' THEN adv.advance_no WHEN 'DEBIT_NOTE' THEN dn.debit_note_no WHEN 'CREDIT_NOTE' THEN cn.credit_note_no END AS ref_no,
           inv.invoice_no
    FROM dbo.payment_adjustment a
    LEFT JOIN dbo.nt_supplier_advance_payment adv ON a.adj_type = 'ADVANCE' AND adv.advance_sno = a.ref_sno
    LEFT JOIN dbo.debit_note_basic_info dn ON a.adj_type = 'DEBIT_NOTE' AND dn.debit_note_sno = a.ref_sno
    LEFT JOIN dbo.credit_note_basic_info cn ON a.adj_type = 'CREDIT_NOTE' AND cn.credit_note_sno = a.ref_sno
    LEFT JOIN dbo.invoice_info inv ON inv.invoice_sno = a.invoice_sno
    WHERE a.payment_sno = @pay
    ORDER BY a.adjustment_sno;

    SELECT CAST(j.[key] AS INT) AS seq, JSON_VALUE(j.[value], '$.approver_ecno') AS approver_ecno, JSON_VALUE(j.[value], '$.stage') AS stage
    FROM dbo.workflow_stage ws CROSS APPLY OPENJSON(ws.stage_order_json) j
    WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y'
    ORDER BY CAST(j.[key] AS INT);
END
GO

-- ── 7. the run: pay what today's fund covers ────────────────────────────────
-- @jsonInput: { payment_snos: [..in the order they should appear in the file], fund_plan_amount, created_by, payment_date?, hierarchy? }
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
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
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

        DECLARE @year VARCHAR(4) = CAST(YEAR(GETDATE()) AS VARCHAR(4)), @seq INT;
        SELECT @seq = ISNULL(MAX(TRY_CAST(RIGHT(batch_no, 6) AS INT)), 0) + 1 FROM dbo.payment_batch WITH (UPDLOCK, HOLDLOCK) WHERE batch_no LIKE 'PB-' + @year + '-%';
        SET @bno = 'PB-' + @year + '-' + RIGHT('000000' + CAST(@seq AS VARCHAR(6)), 6);

        INSERT INTO dbo.payment_batch (batch_no, batch_date, com_sno, fund_plan_amount, total_amount, item_count, status, created_by)
        SELECT @bno, @vdate, MIN(pi.com_sno), @fund, @total, COUNT(*), 'Generated', @by
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
           CONVERT(VARCHAR(30), b.created_at, 120) AS created_at
    FROM dbo.payment_batch b WHERE b.batch_sno = @bsno;
    SELECT i.batch_item_sno, i.batch_sno, i.payment_sno, p.payment_no, i.line_no, i.vendor_sno, i.vendor_name, i.supp_code, i.vendor_email, i.amount, i.mode, i.debit_account,
           i.channel, i.beneficiary_name, i.account_no, i.ifsc, i.bank_name, i.branch_name, i.invoice_nos, i.supplier_invoice_nos, i.msme_label, i.narration,
           p.com_sno, p.div_sno, p.brn_sno, p.dept_sno
    FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
    WHERE i.batch_sno = @bsno ORDER BY i.line_no;
END
GO

-- keeps the generated payment file with its batch (built in grn-service, paymentFile.js)
CREATE OR ALTER PROCEDURE dbo.sp_nt_SetPaymentBatchFile
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.payment_batch SET file_name = JSON_VALUE(@jsonInput, '$.file_name'), file_content = JSON_VALUE(@jsonInput, '$.file_content')
    WHERE batch_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.batch_sno') AS INT);
END
GO

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
           b.created_by, CONVERT(VARCHAR(30), b.created_at, 120) AS created_at
    FROM dbo.payment_batch b
    LEFT JOIN dbo.company_master c ON c.com_sno = b.com_sno
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

-- ── 8. screens: Payment Approval, Payment Run ───────────────────────────────
DECLARE @g INT = (SELECT group_id FROM dbo.screen_group WHERE group_name = N'Accounts and Payment');
IF @g IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'PaymentApprovalScreen')
        INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
        SELECT N'Payment Approval', screen_code, 'PaymentApprovalScreen', 'ClipboardCheck', @g, 2, 'Y' FROM dbo.screens WHERE comp = 'PaymentPage';
    IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'PaymentRunPage')
        INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
        SELECT N'Payment Run', screen_code, 'PaymentRunPage', 'Banknote', @g, 3, 'Y' FROM dbo.screens WHERE comp = 'PaymentPage';
    -- menu order follows the flow: entry, approval, run, then the accounts screens
    UPDATE dbo.screens SET display_order = 1 WHERE comp = 'PaymentPage';
    UPDATE dbo.screens SET display_order = 2 WHERE comp = 'PaymentApprovalScreen';
    UPDATE dbo.screens SET display_order = 3 WHERE comp = 'PaymentRunPage';
    UPDATE dbo.screens SET display_order = 4 WHERE comp = 'Gstr2bPage';
    UPDATE dbo.screens SET display_order = 5 WHERE comp = 'JournalsPage';
END
GO
DECLARE @sid INT, @json NVARCHAR(MAX);
SELECT @sid = screen_id FROM dbo.screens WHERE comp = 'PaymentApprovalScreen';
IF @sid IS NOT NULL
BEGIN
    SET @json = (SELECT 'KTM1148' AS ecno, @sid AS screen_id, JSON_QUERY('[2,3,4,5,7,8]') AS permission_ids FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
END
SELECT @sid = screen_id FROM dbo.screens WHERE comp = 'PaymentRunPage';
IF @sid IS NOT NULL
BEGIN
    SET @json = (SELECT 'KTM1148' AS ecno, @sid AS screen_id, JSON_QUERY('[2,3,4,5]') AS permission_ids FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
END
GO
