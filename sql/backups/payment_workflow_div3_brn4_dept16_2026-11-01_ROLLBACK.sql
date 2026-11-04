-- ROLLBACK for 77_payment_workflow_div3_brn4_dept16.sql (Non_trade_Dev). Refuses while a payment is Pending Approval under it;
-- otherwise switches off its stages, scope and master (rows kept). Payments already saved keep their workflow_types_id.
IF EXISTS (SELECT 1 FROM dbo.payment_info p JOIN dbo.workflow_types wt ON wt.workflow_types_id = p.workflow_types_id
           WHERE p.status = 'Pending Approval' AND wt.workflow_types_description = N'IA approval for payments of div 3 / branch 4 / dept 16; Admin approval above the limit')
    THROW 56911, N'Payments are still awaiting approval under the sql/77 workflow - approve, reject or cancel them first.', 1;
GO
UPDATE ws SET ws.is_active = 'N' FROM dbo.workflow_stage ws JOIN dbo.workflow_types wt ON wt.workflow_types_id = ws.workflow_types_id
WHERE wt.workflow_types_description = N'IA approval for payments of div 3 / branch 4 / dept 16; Admin approval above the limit';
UPDATE dbo.workflow_types SET is_active = 'N' WHERE workflow_types_description = N'IA approval for payments of div 3 / branch 4 / dept 16; Admin approval above the limit';
UPDATE m SET m.is_active = 'N' FROM dbo.approval_workflow_master m
WHERE m.entity_type = 'Payment' AND m.workflow_name = N'Payment Approval (Div 3 / Brn 4 / Dept 16)'
  AND NOT EXISTS (SELECT 1 FROM dbo.workflow_types wt WHERE wt.workflow_id = m.workflow_id AND wt.is_active = 'Y');
GO
