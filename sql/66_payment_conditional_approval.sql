-- ============================================================
-- 66_payment_conditional_approval.sql   (Non_trade_Dev ONLY, re-runnable)
--
-- Payment approval on the conditional approval engine (backend-stpl sql/99, already used by Purchase Requisitions):
--
--   * VALUE CONDITIONS.  A stage of a 'Payment' workflow can carry a condition on the payment value, e.g. "required when
--     Amount (net payable) is more than 50,000". A stage whose condition is not met is skipped ("not required"). The first
--     stage is always required (the same rule the Approval Workflows screen enforces). Registered fields:
--       amount        what is paid to the supplier (after TDS, advances, debit / credit notes)
--       gross_amount  the invoice value the payment settles (before those adjustments)
--     The Approval Workflows screen builds its condition editor from this registry, so a Payment workflow now offers
--     "Add condition" and "Alternates" on its stages with no screen change.
--   * FORWARD.  An approver whose stage has can_forward = 'Y' can pass the payment to a LATER stage, even one the rules did not
--     require (stages in between are skipped).
--   * SEND BACK.  An approver whose stage has can_backward = 'Y' can return it to an EARLIER approver who already acted on it.
--     That approver approves it onward again, and the chain resumes at the approver who sent it back.
--   * ALTERNATES.  A stage may list alternate approvers; they can act only once the stage has waited escalation_hours.
--   * Reject / Cancel behave as before (the invoices, TDS, advances and notes are given back).
--
-- State lives in the engine's tables (approval_instance + approval_action_log, entity_type 'Payment'); payment_info keeps
-- status / current_approver_id, and payment_approval_history stays the human trail. No workflow configured, or none of its
-- stages applying to the amount -> 'Approved' at once (unchanged).
--
-- Supersedes sql/65's versions of sp_nt_SubmitPaymentForApproval, sp_nt_ApprovePayment, sp_nt_CancelPayment,
-- sp_nt_GetPaymentActivity and sp_nt_GetPaymentEntries - on a database that has sql/66 do not re-run those batches of sql/65.
--
-- Needs backend-stpl sql/99 (approval_instance, approval_action_log, approval_condition_field, fn_approval_condition_met,
-- fn_approval_next_seq). Apply: cd grn-service && node sql/run_sql.mjs sql/66_payment_conditional_approval.sql
-- Rollback: sql/backups/payment_conditional_approval_2026-10-22_ROLLBACK.sql
-- ============================================================

IF OBJECT_ID('dbo.approval_instance', 'U') IS NULL OR OBJECT_ID('dbo.approval_action_log', 'U') IS NULL OR OBJECT_ID('dbo.approval_condition_field', 'U') IS NULL
   OR OBJECT_ID('dbo.fn_approval_condition_met', 'FN') IS NULL OR OBJECT_ID('dbo.fn_approval_next_seq', 'FN') IS NULL
    THROW 56800, N'The conditional approval engine (backend-stpl sql/99) is not installed in this database.', 1;
GO

-- ── 1. what a Payment workflow's rules can test ─────────────────────────────
MERGE dbo.approval_condition_field AS t
USING (VALUES
    ('Payment', 'amount',       N'Amount (net payable)',  'number', NULL, 'INR', N'What is paid to the supplier after TDS, advances and debit / credit notes', 1),
    ('Payment', 'gross_amount', N'Invoice value (gross)', 'number', NULL, 'INR', N'The invoice amount the payment settles, before TDS, advances and notes',      2)
) AS s (entity_type, field_key, field_label, value_kind, option_source, unit, help_text, sort_order)
ON t.entity_type = s.entity_type AND t.field_key = s.field_key
WHEN MATCHED THEN
    UPDATE SET field_label = s.field_label, value_kind = s.value_kind, option_source = s.option_source,
               unit = s.unit, help_text = s.help_text, sort_order = s.sort_order, is_active = 'Y'
WHEN NOT MATCHED THEN
    INSERT (entity_type, field_key, field_label, value_kind, option_source, unit, help_text, sort_order)
    VALUES (s.entity_type, s.field_key, s.field_label, s.value_kind, s.option_source, s.unit, s.help_text, s.sort_order);
GO

-- The values a payment's rules are evaluated against (one key per registered field).
CREATE OR ALTER FUNCTION dbo.fn_payment_approval_context (@payment_sno INT)
RETURNS TABLE
AS
RETURN
(
    SELECT CAST(ISNULL(p.net_paid, p.amount) AS DECIMAL(18,2))          AS amount,
           CAST(ISNULL(p.gross_amount, p.amount) AS DECIMAL(18,2))      AS gross_amount,
           CONCAT('{"amount":', CAST(ISNULL(p.net_paid, p.amount) AS DECIMAL(18,2)),
                  ',"gross_amount":', CAST(ISNULL(p.gross_amount, p.amount) AS DECIMAL(18,2)), '}') AS context_json
    FROM dbo.payment_info p
    WHERE p.payment_sno = @payment_sno
);
GO

-- ── 2. the approval instance of a pending payment ───────────────────────────
-- Normally created by sp_nt_SubmitPaymentForApproval. This rebuilds a missing one (a payment saved before sql/66) from its
-- workflow, at the stage its current approver holds; a workflow that has since lost its stages becomes a single stage held
-- by the current approver. Does nothing for a payment that is not pending.
CREATE OR ALTER PROCEDURE dbo.sp_nt_EnsurePaymentApprovalInstance
    @payment_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.approval_instance WHERE entity_type = 'Payment' AND entity_ref_id = @payment_sno) RETURN;

    DECLARE @wf INT, @cur_appr VARCHAR(30), @status VARCHAR(20), @stages NVARCHAR(MAX), @cur INT;
    SELECT @wf = workflow_types_id, @cur_appr = current_approver_id, @status = status FROM dbo.payment_info WHERE payment_sno = @payment_sno;
    IF @status IS NULL OR @status <> 'Pending Approval' RETURN;

    SELECT TOP 1 @stages = stage_order_json FROM dbo.workflow_stage
    WHERE workflow_types_id = @wf AND is_active = 'Y' AND ISJSON(stage_order_json) = 1 ORDER BY stage_id;
    IF @stages IS NULL
    BEGIN
        IF @cur_appr IS NULL THROW 56019, N'No approval stages are configured for this payment.', 1;
        SET @stages = (SELECT @cur_appr AS approver_ecno, N'Approval' AS stage, '1' AS required_approvals, 'Y' AS is_mandatory,
                              '24' AS escalation_hours, '' AS approver_condition, '' AS next_approver_ecno,
                              'N' AS can_forward, 'N' AS can_backward, 'N' AS can_edit_data FOR JSON PATH);
    END

    SELECT TOP 1 @cur = CAST(s.[key] AS INT) FROM OPENJSON(@stages) s
    WHERE JSON_VALUE(s.value, '$.approver_ecno') = @cur_appr ORDER BY CAST(s.[key] AS INT);
    IF @cur IS NULL THROW 56017, N'Could not work out the current approval stage for this payment.', 1;

    INSERT INTO dbo.approval_instance (entity_type, entity_ref_id, workflow_types_id, stages_json, cycle_no, current_seq, status, current_since)
    VALUES ('Payment', @payment_sno, @wf, @stages, 1, @cur, 'P', GETDATE());
END
GO

-- ── 3. submit ───────────────────────────────────────────────────────────────
-- The first stage whose condition holds for this payment's value becomes the current one. @jsonInput: { payment_sno, created_by }.
-- @silent = 1 when called from inside sp_nt_ReleasePaymentNet (no result set; runs in its transaction).
CREATE OR ALTER PROCEDURE dbo.sp_nt_SubmitPaymentForApproval
    @jsonInput NVARCHAR(MAX), @silent BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    DECLARE @com INT, @div INT, @brn INT, @dept INT, @wf INT, @stages NVARCHAR(MAX), @ctx NVARCHAR(MAX),
            @first INT, @first_appr VARCHAR(30), @now DATETIME = GETDATE(), @inst INT, @why NVARCHAR(200);

    SELECT @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno FROM dbo.payment_info WHERE payment_sno = @pay;
    IF @@ROWCOUNT = 0 THROW 56001, 'Payment not found.', 1;

    DECLARE @entity VARCHAR(50) = dbo.fn_resolve_approval_entity('Payment', 'STANDARD');
    SELECT TOP 1 @wf = wt.workflow_types_id
    FROM dbo.workflow_types wt
    JOIN dbo.approval_workflow_master awm ON awm.workflow_id = wt.workflow_id AND awm.is_active = 'Y'
    WHERE wt.is_active = 'Y' AND awm.entity_type = @entity
      AND wt.com_sno = @com AND wt.div_sno = @div AND wt.brn_sno = @brn AND wt.dept_sno = @dept
    ORDER BY wt.workflow_types_id DESC;

    IF @wf IS NULL
        SET @why = N'No Payment approval workflow is configured for this department';
    ELSE
    BEGIN
        SELECT TOP 1 @stages = ws.stage_order_json FROM dbo.workflow_stage ws
        WHERE ws.workflow_types_id = @wf AND ws.is_active = 'Y' AND ISJSON(ws.stage_order_json) = 1 ORDER BY ws.stage_id;
        IF @stages IS NULL
            SET @why = N'The Payment approval workflow of this department has no stages';
        ELSE
        BEGIN
            SELECT @ctx = context_json FROM dbo.fn_payment_approval_context(@pay);
            SET @first = dbo.fn_approval_next_seq(@stages, -1, @ctx);
            IF @first IS NULL
                SET @why = N'No approval stage applies to this payment amount';
            ELSE
            BEGIN
                SET @first_appr = NULLIF(LTRIM(RTRIM((SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@first AS NVARCHAR(10))))), '');
                IF @first_appr IS NULL SET @why = N'The first approval stage has no approver';
            END
        END
    END

    IF @why IS NULL
    BEGIN
        INSERT INTO dbo.approval_instance (entity_type, entity_ref_id, workflow_types_id, stages_json, cycle_no, current_seq, status, current_since)
        VALUES ('Payment', @pay, @wf, @stages, 1, @first, 'P', @now);
        SET @inst = SCOPE_IDENTITY();
        INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
        SELECT @inst, 'Payment', @pay, 1, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM', N'Not required - approval condition not met'
        FROM OPENJSON(@stages) s WHERE CAST(s.[key] AS INT) < @first;

        UPDATE dbo.payment_info SET status = 'Pending Approval', workflow_types_id = @wf, current_approver_id = @first_appr, approved_at = NULL WHERE payment_sno = @pay;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
        VALUES (@pay, 'SUBMITTED', @by, N'Submitted for approval to ' + @first_appr);
    END
    ELSE
    BEGIN
        UPDATE dbo.payment_info SET status = 'Approved', workflow_types_id = NULL, current_approver_id = NULL, approved_at = @now WHERE payment_sno = @pay;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'AUTO_APPROVED', @by, @why);
    END

    IF @silent = 0
        SELECT payment_sno, payment_no, status, current_approver_id, workflow_types_id,
               CASE WHEN status = 'Approved' THEN 1 ELSE 0 END AS is_final
        FROM dbo.payment_info WHERE payment_sno = @pay;
END
GO

-- ── 4. approve / reject / forward / send back ───────────────────────────────
-- @jsonInput: { payment_sno, action: 'approve'|'reject'|'forward'|'send_back', approved_by, comments?, target_seq? }
--   forward   target_seq = a later stage (default: the caller picks one; stages in between are skipped)
--   send_back target_seq = an earlier stage that already acted in this round; remarks required
--   reject    remarks required
-- result = APPROVED_NEXT | FINAL | REJECTED | FORWARDED | SENT_BACK (+ next_approver). Errors are THROWN (56001-56019).
-- Like the PR engine this has no XACT_ABORT: a validation error leaves the caller's transaction rollback-able to our savepoint.
CREATE OR ALTER PROCEDURE dbo.sp_nt_ApprovePayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    IF ISJSON(@jsonInput) = 0 THROW 56000, N'Invalid JSON payload.', 1;

    DECLARE @own_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT),
            @action VARCHAR(20) = LOWER(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.action')))),
            @by VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.approved_by'))), ''),
            @comments NVARCHAR(1000) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.comments'))), ''),
            @target_seq INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.target_seq') AS INT);

    IF @pay IS NULL THROW 56001, N'Payment not found.', 1;
    IF @by IS NULL THROW 56003, N'The approver is required.', 1;
    IF @action IS NULL OR @action NOT IN ('approve', 'reject', 'forward', 'send_back') THROW 56005, N'action must be approve, reject, forward or send_back.', 1;
    IF @action IN ('reject', 'send_back') AND @comments IS NULL THROW 56004, N'Remarks are required for this action.', 1;

    DECLARE @status VARCHAR(20), @cur_appr VARCHAR(30), @wf INT, @creator VARCHAR(30), @pno VARCHAR(30), @vendor INT, @net DECIMAL(18,2),
            @com INT, @div INT, @brn INT, @dept INT;
    DECLARE @inst INT, @stages NVARCHAR(MAX), @cycle INT, @cur INT, @ret INT, @since DATETIME, @istatus CHAR(1);
    DECLARE @stage NVARCHAR(MAX), @stage_name NVARCHAR(100), @primary VARCHAR(30), @esc_h INT, @role VARCHAR(10);
    DECLARE @ctx NVARCHAR(MAX), @next INT, @next_appr VARCHAR(30), @result VARCHAR(20), @newstatus VARCHAR(20), @msg NVARCHAR(2048), @now DATETIME = GETDATE();

    BEGIN TRY
        IF @own_tran = 1
        BEGIN
            BEGIN TRAN;
        END
        ELSE
        BEGIN
            SAVE TRAN payment_approval_act;
        END

        SELECT @status = status, @cur_appr = current_approver_id, @wf = workflow_types_id, @creator = created_by, @pno = payment_no,
               @vendor = vendor_sno, @net = ISNULL(net_paid, amount), @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
        FROM dbo.payment_info WITH (UPDLOCK) WHERE payment_sno = @pay AND is_active = 'Y';
        IF @status IS NULL THROW 56001, N'Payment not found.', 1;
        IF @status <> 'Pending Approval' THROW 56002, N'This payment is not awaiting approval.', 1;

        EXEC dbo.sp_nt_EnsurePaymentApprovalInstance @payment_sno = @pay;
        SELECT @inst = instance_id, @stages = stages_json, @cycle = cycle_no, @cur = current_seq, @ret = return_to_seq, @since = current_since, @istatus = status
        FROM dbo.approval_instance WITH (UPDLOCK, HOLDLOCK) WHERE entity_type = 'Payment' AND entity_ref_id = @pay;
        IF @inst IS NULL OR @istatus <> 'P' OR @cur IS NULL THROW 56002, N'This payment is not awaiting approval.', 1;

        SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
        SELECT @stage_name = JSON_VALUE(@stage, '$.stage'), @primary = JSON_VALUE(@stage, '$.approver_ecno'),
               @esc_h = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);

        -- Self-heal: the payment was re-assigned outside the engine (manual SQL, a workflow approver replaced).
        IF ISNULL(@primary, '') <> ISNULL(@cur_appr, '')
        BEGIN
            DECLARE @healed INT;
            SELECT TOP 1 @healed = CAST(s.[key] AS INT) FROM OPENJSON(@stages) s WHERE JSON_VALUE(s.value, '$.approver_ecno') = @cur_appr ORDER BY CAST(s.[key] AS INT);
            IF @healed IS NULL THROW 56017, N'The approval chain and the current approver are out of step; ask an administrator to check the workflow.', 1;
            SET @cur = @healed;
            SET @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
            SELECT @stage_name = JSON_VALUE(@stage, '$.stage'), @primary = JSON_VALUE(@stage, '$.approver_ecno'),
                   @esc_h = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);
            UPDATE dbo.approval_instance SET current_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            SET @since = @now;
        END

        -- who may act now
        IF @by = @primary
            SET @role = 'PRIMARY';
        ELSE IF EXISTS (SELECT 1 FROM OPENJSON(@stage, '$.alternates') a WHERE a.value COLLATE DATABASE_DEFAULT = @by)
        BEGIN
            IF DATEDIFF(MINUTE, @since, @now) >= @esc_h * 60
                SET @role = 'ALTERNATE';
            ELSE
            BEGIN
                SET @msg = CONCAT(N'You are the alternate approver for this stage. You can act once it has been pending for ', @esc_h,
                                  N' hours (from ', CONVERT(VARCHAR(16), DATEADD(HOUR, @esc_h, @since), 120), N').');
                THROW 56018, @msg, 1;
            END
        END
        ELSE
            THROW 56003, N'You are not the current approver of this payment.', 1;

        SELECT @ctx = context_json FROM dbo.fn_payment_approval_context(@pay);

        -- ════════ APPROVE ════════
        IF @action = 'approve'
        BEGIN
            SET @next = CASE WHEN @ret IS NOT NULL THEN @ret ELSE dbo.fn_approval_next_seq(@stages, @cur, @ctx) END;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'APPROVE', @cur, @next, @stage_name, @by, @role, @comments);

            IF @ret IS NULL
                INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
                SELECT @inst, 'Payment', @pay, @cycle, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM', N'Not required - approval condition not met'
                FROM OPENJSON(@stages) s WHERE CAST(s.[key] AS INT) > @cur AND (@next IS NULL OR CAST(s.[key] AS INT) < @next);

            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'APPROVED', @by, LEFT(@comments, 500));

            IF @next IS NULL
            BEGIN
                UPDATE dbo.approval_instance SET status = 'A', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.payment_info SET status = 'Approved', current_approver_id = NULL, approved_at = @now, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
                SET @next_appr = NULL; SET @result = 'FINAL'; SET @newstatus = 'Approved';
            END
            ELSE
            BEGIN
                SET @next_appr = (SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@next AS NVARCHAR(10)));
                IF @next_appr IS NULL THROW 56013, N'The next approval stage has no approver configured.', 1;
                UPDATE dbo.approval_instance SET current_seq = @next, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
                UPDATE dbo.payment_info SET current_approver_id = @next_appr, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
                SET @result = 'APPROVED_NEXT'; SET @newstatus = 'Pending Approval';
            END
        END

        -- ════════ REJECT ════════
        ELSE IF @action = 'reject'
        BEGIN
            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'REJECT', @cur, @stage_name, @by, @role, @comments);
            EXEC dbo.sp_nt_ReversePaymentReservation @payment_sno = @pay, @by = @by, @reason = @comments;
            UPDATE dbo.approval_instance SET status = 'R', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.payment_info SET status = 'Rejected', current_approver_id = NULL, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'REJECTED', @by, LEFT(@comments, 500));
            SET @next_appr = NULL; SET @next = NULL; SET @result = 'REJECTED'; SET @newstatus = 'Rejected';
        END

        -- ════════ FORWARD (to a later stage, even one the rules did not require) ════════
        ELSE IF @action = 'forward'
        BEGIN
            IF ISNULL(JSON_VALUE(@stage, '$.can_forward'), 'N') <> 'Y' THROW 56011, N'This stage is not allowed to forward.', 1;
            IF @target_seq IS NULL OR @target_seq <= @cur THROW 56012, N'Choose a later stage to forward to.', 1;
            SET @next_appr = NULLIF(LTRIM(RTRIM((SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@target_seq AS NVARCHAR(10))))), '');
            IF @next_appr IS NULL THROW 56013, N'That stage does not exist or has no approver.', 1;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'FORWARD', @cur, @target_seq, @stage_name, @by, @role, @next_appr, @comments);
            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, stage_name, acted_by, acted_as, comments)
            SELECT @inst, 'Payment', @pay, @cycle, 'SKIP', CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), @by, 'SYSTEM', N'Bypassed - forwarded past this stage'
            FROM OPENJSON(@stages) s WHERE CAST(s.[key] AS INT) > @cur AND CAST(s.[key] AS INT) < @target_seq;

            UPDATE dbo.approval_instance SET current_seq = @target_seq, return_to_seq = NULL, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.payment_info SET current_approver_id = @next_appr, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
            VALUES (@pay, 'FORWARDED', @by, LEFT(CONCAT(N'Forwarded to ', @next_appr, CASE WHEN @comments IS NULL THEN N'' ELSE N': ' + @comments END), 500));
            SET @next = @target_seq; SET @result = 'FORWARDED'; SET @newstatus = 'Pending Approval';
        END

        -- ════════ SEND BACK (to an earlier approver who already acted in this round) ════════
        ELSE IF @action = 'send_back'
        BEGIN
            IF ISNULL(JSON_VALUE(@stage, '$.can_backward'), 'N') <> 'Y' THROW 56014, N'This stage is not allowed to send back.', 1;
            IF @target_seq IS NULL OR @target_seq >= @cur THROW 56015, N'Choose an earlier approver to send this back to.', 1;
            IF NOT EXISTS (SELECT 1 FROM dbo.approval_action_log
                           WHERE instance_id = @inst AND cycle_no = @cycle AND from_seq = @target_seq AND action IN ('APPROVE', 'FORWARD'))
                THROW 56016, N'You can send back only to an approver who has already acted on this payment.', 1;
            SET @next_appr = NULLIF(LTRIM(RTRIM((SELECT JSON_VALUE(s.value, '$.approver_ecno') FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@target_seq AS NVARCHAR(10))))), '');
            IF @next_appr IS NULL THROW 56013, N'That stage does not exist or has no approver.', 1;

            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, to_seq, stage_name, acted_by, acted_as, target_ecno, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'SEND_BACK', @cur, @target_seq, @stage_name, @by, @role, @next_appr, @comments);

            UPDATE dbo.approval_instance SET current_seq = @target_seq, return_to_seq = @cur, current_since = @now, updated_at = @now WHERE instance_id = @inst;
            UPDATE dbo.payment_info SET current_approver_id = @next_appr, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
            INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment)
            VALUES (@pay, 'SENT_BACK', @by, LEFT(CONCAT(N'Sent back to ', @next_appr, N': ', @comments), 500));
            SET @next = @target_seq; SET @result = 'SENT_BACK'; SET @newstatus = 'Pending Approval';
        END

        IF @own_tran = 1 COMMIT TRAN;

        SELECT @result AS result, @pay AS payment_sno, @pno AS payment_no, @vendor AS vendor_sno, @net AS net_paid, @creator AS created_by,
               @next_appr AS next_approver, @newstatus AS status, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno,
               @role AS acted_as, @stage_name AS stage_name, @next AS next_seq;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1
        BEGIN
            IF XACT_STATE() <> 0 ROLLBACK TRAN;
        END
        ELSE IF XACT_STATE() = 1
        BEGIN
            ROLLBACK TRAN payment_approval_act;      -- undo only our own writes; the caller decides the rest
        END;
        THROW;
    END CATCH
END
GO

-- ── 5. cancel ───────────────────────────────────────────────────────────────
-- A payment that has not been paid yet (awaiting approval, or approved and still waiting in the Payment Run).
-- @jsonInput: { payment_sno, cancelled_by, reason }
CREATE OR ALTER PROCEDURE dbo.sp_nt_CancelPayment
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @own_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT), @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.cancelled_by'),
            @reason NVARCHAR(500) = JSON_VALUE(@jsonInput, '$.reason'), @now DATETIME = GETDATE();
    DECLARE @status VARCHAR(20), @pno VARCHAR(30), @vendor INT, @net DECIMAL(18,2), @creator VARCHAR(30), @cur VARCHAR(30),
            @com INT, @div INT, @brn INT, @dept INT;
    SELECT @status = status, @pno = payment_no, @vendor = vendor_sno, @net = net_paid, @creator = created_by, @cur = current_approver_id,
           @com = com_sno, @div = div_sno, @brn = brn_sno, @dept = dept_sno
    FROM dbo.payment_info WHERE payment_sno = @pay AND is_active = 'Y';
    IF @status IS NULL THROW 56001, 'Payment not found.', 1;
    IF @status NOT IN ('Pending Approval', 'Approved') THROW 56006, 'Only a payment that has not been paid yet can be cancelled.', 1;
    IF @by IS NULL OR @reason IS NULL OR LTRIM(RTRIM(@reason)) = '' THROW 56007, 'A reason is required to cancel a payment.', 1;

    BEGIN TRY
        IF @own_tran = 1
        BEGIN
            BEGIN TRAN;
        END
        ELSE
        BEGIN
            SAVE TRAN payment_cancel;
        END
        EXEC dbo.sp_nt_ReversePaymentReservation @payment_sno = @pay, @by = @by, @reason = @reason;
        UPDATE dbo.payment_info SET status = 'Cancelled', current_approver_id = NULL, modified_by = @by, modified_date = @now WHERE payment_sno = @pay;
        INSERT INTO dbo.payment_approval_history (payment_sno, action_type, status_by, comment) VALUES (@pay, 'CANCELLED', @by, @reason);

        DECLARE @inst INT, @cycle INT, @cseq INT;
        SELECT @inst = instance_id, @cycle = cycle_no, @cseq = current_seq FROM dbo.approval_instance WHERE entity_type = 'Payment' AND entity_ref_id = @pay AND status = 'P';
        IF @inst IS NOT NULL
        BEGIN
            INSERT INTO dbo.approval_action_log (instance_id, entity_type, entity_ref_id, cycle_no, action, from_seq, acted_by, acted_as, comments)
            VALUES (@inst, 'Payment', @pay, @cycle, 'CANCEL', @cseq, @by, 'PRIMARY', @reason);
            UPDATE dbo.approval_instance SET status = 'X', current_seq = NULL, return_to_seq = NULL, updated_at = @now WHERE instance_id = @inst;
        END
        IF @own_tran = 1 COMMIT TRAN;
    END TRY
    BEGIN CATCH
        IF @own_tran = 1
        BEGIN
            IF XACT_STATE() <> 0 ROLLBACK TRAN;
        END
        ELSE IF XACT_STATE() = 1
        BEGIN
            ROLLBACK TRAN payment_cancel;
        END;
        THROW;
    END CATCH
    SELECT 'CANCELLED' AS result, @pay AS payment_sno, @pno AS payment_no, @vendor AS vendor_sno, @net AS net_paid, @creator AS created_by,
           @cur AS was_waiting_on, @status AS was_status, 'Cancelled' AS status, @com AS com_sno, @div AS div_sno, @brn AS brn_sno, @dept AS dept_sno;
END
GO

-- ── 6. one payment's approval: trail, adjustments, path, what the caller may do ─
-- @jsonInput: { payment_sno, ecno }   Eight result sets, always in this order (shapes fixed even with no instance):
--   RS1 trail (payment_approval_history)         RS2 TDS / advances / notes
--   RS3 the stages with their state              RS4 summary + what the caller may do
--   RS5 forward targets (later stages)           RS6 send-back targets (earlier stages that acted)
--   RS7 the action log                           RS8 the condition fields of this workflow type (labels, units)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentActivity
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT), @ecno VARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@jsonInput, '$.ecno'))), '');
    DECLARE @wf INT, @pstatus VARCHAR(20), @creator VARCHAR(30), @entity VARCHAR(50), @net DECIMAL(18,2), @gross DECIMAL(18,2), @ctx NVARCHAR(MAX);
    SELECT @wf = workflow_types_id, @pstatus = status, @creator = created_by, @net = ISNULL(net_paid, amount), @gross = ISNULL(gross_amount, amount)
    FROM dbo.payment_info WHERE payment_sno = @pay;
    SELECT @entity = m.entity_type FROM dbo.workflow_types wt JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id WHERE wt.workflow_types_id = @wf;
    SET @entity = ISNULL(@entity, dbo.fn_resolve_approval_entity('Payment', 'STANDARD'));
    SELECT @ctx = context_json FROM dbo.fn_payment_approval_context(@pay);

    DECLARE @inst INT, @stages NVARCHAR(MAX), @cycle INT, @cur INT, @ret INT, @since DATETIME, @istatus CHAR(1);
    SELECT @inst = instance_id, @stages = stages_json, @cycle = cycle_no, @cur = current_seq, @ret = return_to_seq, @since = current_since, @istatus = status
    FROM dbo.approval_instance WHERE entity_type = 'Payment' AND entity_ref_id = @pay;

    CREATE TABLE #stg (seq INT PRIMARY KEY, stage_name NVARCHAR(100), approver_ecno VARCHAR(30), approver_name NVARCHAR(200),
                       alternates_json NVARCHAR(MAX), alternate_names NVARCHAR(MAX), escalation_hours INT,
                       can_forward CHAR(1), can_backward CHAR(1), condition_json NVARCHAR(MAX), condition_met BIT, state VARCHAR(16),
                       acted_by VARCHAR(30), acted_by_name NVARCHAR(200), acted_at DATETIME, comments NVARCHAR(1000));
    CREATE TABLE #codes (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
    CREATE TABLE #people (code VARCHAR(50) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, name NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL);

    DECLARE @my_role VARCHAR(20) = 'NONE', @alt_at DATETIME = NULL, @stage NVARCHAR(MAX), @primary VARCHAR(30), @esc_h INT;
    DECLARE @can_act BIT = 0, @can_forward BIT = 0, @can_back BIT = 0;

    IF @inst IS NOT NULL
    BEGIN
        INSERT INTO #stg (seq, stage_name, approver_ecno, alternates_json, escalation_hours, can_forward, can_backward, condition_json)
        SELECT CAST(s.[key] AS INT), JSON_VALUE(s.value, '$.stage'), JSON_VALUE(s.value, '$.approver_ecno'), JSON_QUERY(s.value, '$.alternates'),
               ISNULL(TRY_CAST(JSON_VALUE(s.value, '$.escalation_hours') AS INT), 24),
               ISNULL(JSON_VALUE(s.value, '$.can_forward'), 'N'), ISNULL(JSON_VALUE(s.value, '$.can_backward'), 'N'), JSON_QUERY(s.value, '$.condition')
        FROM OPENJSON(@stages) s;

        UPDATE o SET condition_met = dbo.fn_approval_condition_met(o.condition_json, @ctx) FROM #stg o;

        -- the state of each stage in THIS round: the latest thing that happened to it, else where it sits in the path
        UPDATE o
        SET state = CASE
                        WHEN @istatus = 'P' AND o.seq = @cur THEN 'CURRENT'
                        WHEN la.action = 'REJECT'    THEN 'REJECTED'
                        WHEN la.action = 'APPROVE'   THEN 'DONE'
                        WHEN la.action = 'FORWARD'   THEN 'FORWARDED'
                        WHEN la.action = 'SKIP'      THEN 'SKIPPED'
                        WHEN la.action = 'SEND_BACK' THEN 'SENT_BACK'
                        WHEN @istatus = 'P' AND o.seq > @cur THEN CASE WHEN o.condition_met = 1 THEN 'UPCOMING' ELSE 'NOT_REQUIRED' END
                        WHEN @istatus = 'P' AND o.seq < @cur THEN 'DONE'
                        ELSE 'NOT_REQUIRED'
                    END,
            acted_by = la.acted_by, acted_at = la.acted_at, comments = la.comments
        FROM #stg o
        OUTER APPLY (SELECT TOP 1 l.action, l.acted_by, l.acted_at, l.comments
                     FROM dbo.approval_action_log l
                     WHERE l.instance_id = @inst AND l.cycle_no = @cycle AND l.from_seq = o.seq
                       AND l.action IN ('APPROVE', 'FORWARD', 'REJECT', 'SKIP', 'SEND_BACK')
                     ORDER BY l.log_id DESC) la;

        INSERT INTO #codes (code)
        SELECT DISTINCT LTRIM(RTRIM(c)) FROM (
            SELECT @creator AS c
            UNION SELECT approver_ecno FROM #stg
            UNION SELECT a.value COLLATE DATABASE_DEFAULT FROM #stg o CROSS APPLY OPENJSON(o.alternates_json) a
            UNION SELECT acted_by FROM #stg
            UNION SELECT acted_by FROM dbo.approval_action_log WHERE instance_id = @inst
            UNION SELECT target_ecno FROM dbo.approval_action_log WHERE instance_id = @inst
        ) x WHERE c IS NOT NULL AND LTRIM(RTRIM(c)) <> '';

        INSERT INTO #people (code, name)
        SELECT c.code, MAX(COALESCE(NULLIF(LTRIM(RTRIM(e.ename)), ''), ns.full_name))
        FROM #codes c
        LEFT JOIN dbo.vw_verified_employees e ON e.ecno = c.code
        LEFT JOIN dbo.nt_nonstaff_login ns ON ns.login_id = c.code
        GROUP BY c.code;

        UPDATE o SET approver_name = ISNULL(p.name, o.approver_ecno), acted_by_name = ISNULL(pa.name, o.acted_by),
                     alternate_names = (SELECT STRING_AGG(ISNULL(pp.name, a.value COLLATE DATABASE_DEFAULT), N', ')
                                        FROM OPENJSON(o.alternates_json) a LEFT JOIN #people pp ON pp.code = a.value COLLATE DATABASE_DEFAULT)
        FROM #stg o LEFT JOIN #people p ON p.code = o.approver_ecno LEFT JOIN #people pa ON pa.code = o.acted_by;

        IF @istatus = 'P' AND @cur IS NOT NULL
        BEGIN
            SELECT @stage = (SELECT s.value FROM OPENJSON(@stages) s WHERE s.[key] = CAST(@cur AS NVARCHAR(10)));
            SELECT @primary = JSON_VALUE(@stage, '$.approver_ecno'), @esc_h = ISNULL(TRY_CAST(JSON_VALUE(@stage, '$.escalation_hours') AS INT), 24);
            IF @ecno IS NOT NULL AND @ecno = @primary
                SET @my_role = 'PRIMARY';
            ELSE IF @ecno IS NOT NULL AND EXISTS (SELECT 1 FROM OPENJSON(@stage, '$.alternates') a WHERE a.value COLLATE DATABASE_DEFAULT = @ecno)
            BEGIN
                SET @alt_at = DATEADD(HOUR, @esc_h, @since);
                SET @my_role = CASE WHEN GETDATE() >= @alt_at THEN 'ALTERNATE' ELSE 'ALTERNATE_WAITING' END;
            END
            SET @can_act = CASE WHEN @my_role IN ('PRIMARY', 'ALTERNATE') THEN 1 ELSE 0 END;
            SET @can_forward = CASE WHEN @can_act = 1 AND EXISTS (SELECT 1 FROM #stg WHERE seq = @cur AND can_forward = 'Y')
                                         AND EXISTS (SELECT 1 FROM #stg WHERE seq > @cur) THEN 1 ELSE 0 END;
            SET @can_back = CASE WHEN @can_act = 1 AND EXISTS (SELECT 1 FROM #stg WHERE seq = @cur AND can_backward = 'Y')
                                      AND EXISTS (SELECT 1 FROM dbo.approval_action_log l WHERE l.instance_id = @inst AND l.cycle_no = @cycle
                                                  AND l.from_seq < @cur AND l.action IN ('APPROVE', 'FORWARD')) THEN 1 ELSE 0 END;
        END
    END

    -- RS1
    SELECT h.action_type, h.status_by, h.comment, CONVERT(VARCHAR(30), h.created_at, 120) AS created_at
    FROM dbo.payment_approval_history h WHERE h.payment_sno = @pay ORDER BY h.history_sno DESC;

    -- RS2
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

    -- RS3
    SELECT seq, stage_name, approver_ecno, approver_name, alternates_json, alternate_names, escalation_hours, can_forward, can_backward,
           condition_json, condition_met, state, acted_by, acted_by_name, acted_at, comments
    FROM #stg ORDER BY seq;

    -- RS4
    SELECT @pay AS payment_sno, @pstatus AS payment_status, CAST(CASE WHEN @inst IS NULL THEN 0 ELSE 1 END AS BIT) AS has_instance,
           @cycle AS cycle_no, @cur AS current_seq, @ret AS return_to_seq, @since AS current_since,
           @my_role AS my_role, @alt_at AS alternate_available_at,
           @can_act AS can_approve, @can_act AS can_reject, @can_forward AS can_forward, @can_back AS can_send_back,
           @entity AS entity_type, @net AS amount, @gross AS gross_amount, @creator AS created_by;

    -- RS5: later stages, including ones the rules did not require
    SELECT seq, stage_name, approver_ecno, approver_name, condition_met AS required_by_rule
    FROM #stg WHERE @can_forward = 1 AND seq > @cur ORDER BY seq;

    -- RS6: every earlier stage that already acted in this round
    SELECT o.seq, o.stage_name, o.approver_ecno, o.approver_name, 'STAGE' AS target_type
    FROM #stg o
    WHERE @can_back = 1 AND o.seq < @cur
      AND EXISTS (SELECT 1 FROM dbo.approval_action_log l
                  WHERE l.instance_id = @inst AND l.cycle_no = @cycle AND l.from_seq = o.seq AND l.action IN ('APPROVE', 'FORWARD'))
    ORDER BY o.seq;

    -- RS7
    SELECT l.log_id, l.cycle_no, l.action, l.from_seq, l.to_seq, l.stage_name, l.acted_by, ISNULL(pa.name, l.acted_by) AS acted_by_name,
           l.acted_as, l.target_ecno, ISNULL(pt.name, l.target_ecno) AS target_name, l.comments, l.before_json, l.after_json, l.acted_at
    FROM dbo.approval_action_log l
    LEFT JOIN #people pa ON pa.code = l.acted_by
    LEFT JOIN #people pt ON pt.code = l.target_ecno
    WHERE l.instance_id = ISNULL(@inst, -1)
    ORDER BY l.log_id;

    -- RS8
    SELECT field_key, field_label, value_kind, option_source, unit, help_text, sort_order
    FROM dbo.approval_condition_field
    WHERE is_active = 'Y' AND entity_type = dbo.fn_approval_field_entity(@entity)
    ORDER BY sort_order, field_key;

    DROP TABLE #stg; DROP TABLE #codes; DROP TABLE #people;
END
GO

-- ── 7. entries: the "awaiting me" list also holds payments the caller is an overdue ALTERNATE for, and a payment
--      stays visible to everyone who handled it ───────────────────────────────────────────────────────────────────────
-- Same as sql/65 (see its header for the views) except the two predicates marked (66).
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
                             OR (@view = 'mine' AND pi.status = 'Pending Approval'
                                 AND ( pi.current_approver_id = @ecno
                                    OR EXISTS (SELECT 1 FROM dbo.approval_instance a2 CROSS APPLY OPENJSON(a2.stages_json) st      -- (66) an overdue alternate
                                               WHERE a2.entity_type = 'Payment' AND a2.entity_ref_id = pi.payment_sno AND a2.status = 'P'
                                                 AND st.[key] = CAST(a2.current_seq AS NVARCHAR(10))
                                                 AND EXISTS (SELECT 1 FROM OPENJSON(st.value, '$.alternates') al WHERE al.value COLLATE DATABASE_DEFAULT = @ecno)
                                                 AND DATEDIFF(MINUTE, a2.current_since, GETDATE()) >= ISNULL(TRY_CAST(JSON_VALUE(st.value, '$.escalation_hours') AS INT), 24) * 60)))
                             OR  @view = 'all') ) )
      AND (@status IS NULL OR pi.status = @status)
      AND (@vendor IS NULL OR pi.vendor_sno = @vendor)
      AND (@comf IS NULL OR pi.com_sno = @comf)
      AND (@view = 'mine' OR @hier IS NULL
           OR (@view <> 'run' AND (pi.created_by = @ecno OR pi.current_approver_id = @ecno
                                   OR EXISTS (SELECT 1 FROM dbo.payment_approval_history h WHERE h.payment_sno = pi.payment_sno AND h.status_by = @ecno)))   -- (66) everyone who handled it
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

-- ── 8. payments already waiting for approval get an instance (none expected: sql/65 is new) ─────
DECLARE @p INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT pi.payment_sno FROM dbo.payment_info pi
    WHERE pi.status = 'Pending Approval' AND pi.is_active = 'Y'
      AND NOT EXISTS (SELECT 1 FROM dbo.approval_instance a WHERE a.entity_type = 'Payment' AND a.entity_ref_id = pi.payment_sno);
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC dbo.sp_nt_EnsurePaymentApprovalInstance @payment_sno = @p; END TRY BEGIN CATCH END CATCH
    FETCH NEXT FROM c INTO @p;
END
CLOSE c; DEALLOCATE c;
GO
