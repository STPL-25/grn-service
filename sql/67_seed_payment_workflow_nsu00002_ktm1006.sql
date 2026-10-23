-- ============================================================
-- 67_seed_payment_workflow_nsu00002_ktm1006.sql   (Non_trade_Dev ONLY, re-runnable)
--
-- A Payment approval workflow (request 2026-10-22: "payment approval for NSU00002 and KTM1006, with value conditions, and
-- forward and backward"), created through sp_nt_SaveFullWorkflow - the Approval Workflows screen's own path - so it shows
-- up there and can be edited there:
--
--   stage 1  IA Approval     NSU00002 (Interal Auditor)   every payment
--   stage 2  Admin Approval  KTM1006  (V.NATARAJAN)       only when the payment amount (net payable) is MORE THAN @limit
--   both stages: can forward and can send back (a payment under the limit can still be forwarded to stage 2, and stage 2
--   can return it to stage 1).
--
--   >>> @limit below is a PROVISIONAL value: the limit was not given. Change it on the Approval Workflows screen
--       (Payment workflow -> stage 2 -> condition), no SQL needed. <<<
--
-- Departments: every one where NSU00002 -> KTM1006 already approve GRNs (the 'CBE3-IT' GRN workflows); a department that
-- already has a Payment workflow is left alone. Add more departments on the Approval Workflows screen.
--
-- Access: both approvers are granted the Payment Approval screen (view, approve, reject). KTM1006 is staff (permissions by
-- ecno); NSU00002 is a non-staff user whose permissions are stored by login_id, which sp_nt_GrantScreenToUser does not match.
--
-- Needs sql/65 (the screen) and sql/66 (the Payment condition fields). Re-runnable.
-- Rollback: sql/backups/payment_workflow_nsu00002_ktm1006_2026-10-22_ROLLBACK.sql
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM dbo.approval_condition_field WHERE entity_type = 'Payment' AND field_key = 'amount' AND is_active = 'Y')
    THROW 56801, N'Run sql/66 first: the Payment condition fields are not registered.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'PaymentApprovalScreen')
    THROW 56802, N'Run sql/65 first: the Payment Approval screen is not registered.', 1;
GO

DECLARE @limit DECIMAL(18,2) = 50000;      -- PROVISIONAL: the amount above which KTM1006 must approve
DECLARE @entity VARCHAR(50) = dbo.fn_resolve_approval_entity('Payment', 'STANDARD');

DECLARE @stages NVARCHAR(MAX) = N'['
  + N'{"approver_ecno":"NSU00002","stage":"IA Approval","required_approvals":"1","is_mandatory":"Y","escalation_hours":"24","approver_condition":"","next_approver_ecno":"KTM1006","can_forward":"Y","can_backward":"Y","can_edit_data":"N"},'
  + N'{"approver_ecno":"KTM1006","stage":"Admin Approval","required_approvals":"1","is_mandatory":"Y","escalation_hours":"24","approver_condition":"","next_approver_ecno":"0","can_forward":"Y","can_backward":"Y","can_edit_data":"N",'
  + N'"condition":{"match":"all","rules":[{"field":"amount","op":"gt","value":' + CAST(@limit AS NVARCHAR(30)) + N'}]}}'
  + N']';

DECLARE @scopes TABLE (workflow_types_name NVARCHAR(200), workflow_types_description NVARCHAR(500), brn_sno INT, dept_sno INT, com_sno INT, div_sno INT, is_active CHAR(1), stage_order_json NVARCHAR(MAX));
INSERT INTO @scopes
SELECT DISTINCT
       CASE WHEN wt.workflow_types_name LIKE N'%-GRN' THEN LEFT(wt.workflow_types_name, LEN(wt.workflow_types_name) - 3) + N'PAY' ELSE N'Payment Approval' END,
       N'IA approval for every payment; Admin approval above the limit',
       wt.brn_sno, wt.dept_sno, wt.com_sno, wt.div_sno, 'Y', @stages
FROM dbo.workflow_types wt
JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id AND m.entity_type = 'GRN' AND m.is_active = 'Y'
JOIN dbo.workflow_stage ws ON ws.workflow_types_id = wt.workflow_types_id AND ws.is_active = 'Y' AND ISJSON(ws.stage_order_json) = 1
WHERE wt.is_active = 'Y'
  AND EXISTS (SELECT 1 FROM OPENJSON(ws.stage_order_json) s WHERE JSON_VALUE(s.value, '$.approver_ecno') = 'NSU00002')
  AND EXISTS (SELECT 1 FROM OPENJSON(ws.stage_order_json) s WHERE JSON_VALUE(s.value, '$.approver_ecno') = 'KTM1006')
  AND NOT EXISTS (SELECT 1 FROM dbo.workflow_types p
                  JOIN dbo.approval_workflow_master pm ON pm.workflow_id = p.workflow_id AND pm.entity_type = @entity AND pm.is_active = 'Y'
                  WHERE p.is_active = 'Y' AND p.com_sno = wt.com_sno AND p.div_sno = wt.div_sno AND p.brn_sno = wt.brn_sno AND p.dept_sno = wt.dept_sno);

IF EXISTS (SELECT 1 FROM @scopes)
BEGIN
    DECLARE @json NVARCHAR(MAX) = (
        SELECT N'Payment Approval Workflow' AS workflow_name, @entity AS entity_type,
               N'Supplier payment approval: IA (NSU00002), then Admin (KTM1006) above the limit; both can forward and send back' AS description,
               'Y' AS is_active, 'system' AS created_by,
               (SELECT workflow_types_name, workflow_types_description, brn_sno, dept_sno, com_sno, div_sno, is_active, stage_order_json FROM @scopes FOR JSON PATH) AS workflow_types
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_nt_SaveFullWorkflow @jsonInput = @json;
END
ELSE
    PRINT 'No department needed a Payment workflow (none has the NSU00002 -> KTM1006 GRN chain, or each already has one).';
GO

-- ── access to the Payment Approval screen ───────────────────────────────────
DECLARE @sid INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'PaymentApprovalScreen');
DECLARE @json NVARCHAR(MAX) = (SELECT 'KTM1006' AS ecno, @sid AS screen_id, JSON_QUERY('[2,7,8]') AS permission_ids FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
IF EXISTS (SELECT 1 FROM dbo.nt_user_permissions_json WHERE ecno = 'KTM1006' AND is_active = 'Y')
    EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;

DECLARE @row INT, @sj NVARCHAR(MAX);
SELECT TOP 1 @row = user_perm_json_sno, @sj = RTRIM(screens_json)
FROM dbo.nt_user_permissions_json WHERE login_id = 'NSU00002' AND is_active = 'Y' ORDER BY user_perm_json_sno DESC;
IF @row IS NOT NULL AND NOT EXISTS (SELECT 1 FROM OPENJSON(@sj) WITH (screen_id INT '$.screen_id') WHERE screen_id = @sid)
BEGIN
    DECLARE @entry NVARCHAR(MAX) = (SELECT @sid AS screen_id, JSON_QUERY('[2,7,8]') AS permissions FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    UPDATE dbo.nt_user_permissions_json
    SET screens_json = CASE WHEN @sj IS NULL OR @sj IN ('[]', '') THEN '[' + @entry + ']' ELSE LEFT(@sj, LEN(@sj) - 1) + ',' + @entry + ']' END,
        updated_date = GETDATE()
    WHERE user_perm_json_sno = @row;
END
GO

-- what exists now
SELECT m.workflow_code, m.entity_type, wt.workflow_types_id, wt.workflow_types_name, wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno
FROM dbo.workflow_types wt JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id
WHERE m.entity_type = 'Payment' ORDER BY wt.workflow_types_id;
GO
