-- ============================================================
-- 77_payment_workflow_div3_brn4_dept16.sql   (Non_trade_Dev ONLY, re-runnable)
-- Payments saved for company 1 / division 3 / branch 4 / department 16 (e.g. SILVER ZONE) had no Payment workflow, so they were
-- approved the moment they were saved and never reached Payment Approval. Same chain as sql/67: stage 1 IA Approval NSU00002
-- (every payment), stage 2 Admin Approval KTM1006 above @limit (PROVISIONAL, same as 67 - editable on Approval Workflows).
-- Payments already saved for this scope (53147, 59164, 59165) stay Approved. Both approvers already hold the Payment Approval
-- screen (sql/67). Rollback: sql/backups/payment_workflow_div3_brn4_dept16_2026-11-01_ROLLBACK.sql
-- ============================================================
DECLARE @limit DECIMAL(18,2) = 50000;
DECLARE @entity VARCHAR(50) = dbo.fn_resolve_approval_entity('Payment', 'STANDARD');
DECLARE @stages NVARCHAR(MAX) = N'['
  + N'{"approver_ecno":"NSU00002","stage":"IA Approval","required_approvals":"1","is_mandatory":"Y","escalation_hours":"24","approver_condition":"","next_approver_ecno":"KTM1006","can_forward":"Y","can_backward":"Y","can_edit_data":"N"},'
  + N'{"approver_ecno":"KTM1006","stage":"Admin Approval","required_approvals":"1","is_mandatory":"Y","escalation_hours":"24","approver_condition":"","next_approver_ecno":"0","can_forward":"Y","can_backward":"Y","can_edit_data":"N",'
  + N'"condition":{"match":"all","rules":[{"field":"amount","op":"gt","value":' + CAST(@limit AS NVARCHAR(30)) + N'}]}}'
  + N']';

IF EXISTS (SELECT 1 FROM dbo.workflow_types p
           JOIN dbo.approval_workflow_master pm ON pm.workflow_id = p.workflow_id AND pm.entity_type = @entity AND pm.is_active = 'Y'
           WHERE p.is_active = 'Y' AND p.com_sno = 1 AND p.div_sno = 3 AND p.brn_sno = 4 AND p.dept_sno = 16)
    PRINT 'Scope 1/3/4/16 already has a Payment workflow - nothing to do.';
ELSE
BEGIN
    DECLARE @json NVARCHAR(MAX) = (
        SELECT N'Payment Approval (Div 3 / Brn 4 / Dept 16)' AS workflow_name, @entity AS entity_type,
               N'Supplier payment approval: IA (NSU00002), then Admin (KTM1006) above the limit; both can forward and send back' AS description,
               'Y' AS is_active, 'system' AS created_by,
               (SELECT N'CBE3-IT-PAY' AS workflow_types_name, N'IA approval for payments of div 3 / branch 4 / dept 16; Admin approval above the limit' AS workflow_types_description,
                       4 AS brn_sno, 16 AS dept_sno, 1 AS com_sno, 3 AS div_sno, 'Y' AS is_active, @stages AS stage_order_json
                FOR JSON PATH) AS workflow_types
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC dbo.sp_nt_SaveFullWorkflow @jsonInput = @json;
END
GO
SELECT m.workflow_code, m.entity_type, wt.workflow_types_id, wt.workflow_types_name, wt.com_sno, wt.div_sno, wt.brn_sno, wt.dept_sno
FROM dbo.workflow_types wt JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id
WHERE m.entity_type = 'Payment' AND wt.is_active = 'Y' ORDER BY wt.workflow_types_id;
GO
