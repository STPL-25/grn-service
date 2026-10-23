-- ============================================================
-- ROLLBACK for 66_payment_conditional_approval.sql   (Non_trade_Dev)
-- 1. restores the five procedures 66 replaced, exactly as they were live before 66 (the sql/65 versions, dumped with
--    OBJECT_DEFINITION on 2026-10-22 before 66 was applied)
-- 2. drops the function / procedure 66 added (fn_payment_approval_context, sp_nt_EnsurePaymentApprovalInstance)
-- 3. switches the two Payment condition fields off (rows are kept, is_active = 'N': the Approval Workflows screen offers no
--    "Add condition" for a Payment workflow again)
-- The engine rows of payments approved meanwhile (approval_instance / approval_action_log, entity_type 'Payment') are LEFT IN
-- PLACE as history - nothing reads them once the old procedures are back. A payment still 'Pending Approval' when this runs
-- carries on under the old rules: every stage of its workflow approves in turn (value conditions are ignored). Re-applying 66
-- later picks such a payment up again (the approve procedure re-aligns an instance with the current approver).
-- Run payment_workflow_nsu00002_ktm1006_2026-10-22_ROLLBACK.sql FIRST if sql/67 was applied.
-- Run: cd grn-service && node sql/run_sql.mjs sql/backups/payment_conditional_approval_2026-10-22_ROLLBACK.sql
-- ============================================================
GO

-- restore sp_nt_SubmitPaymentForApproval
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

-- restore sp_nt_ApprovePayment
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

-- restore sp_nt_CancelPayment
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

-- restore sp_nt_GetPaymentActivity
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

-- restore sp_nt_GetPaymentEntries
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

DROP FUNCTION IF EXISTS dbo.fn_payment_approval_context;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_EnsurePaymentApprovalInstance;
GO

UPDATE dbo.approval_condition_field SET is_active = 'N' WHERE entity_type = 'Payment' AND field_key IN ('amount', 'gross_amount');
GO
