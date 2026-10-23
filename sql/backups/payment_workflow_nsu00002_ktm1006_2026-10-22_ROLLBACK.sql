-- ============================================================
-- ROLLBACK for 67_seed_payment_workflow_nsu00002_ktm1006.sql   (Non_trade_Dev)
-- Before 67 there was no Payment workflow at all (every payment was approved at once) and neither KTM1006 nor NSU00002 had the
-- Payment Approval screen (checked 2026-10-22 before applying). This puts that back:
-- 1. refuses to run while a payment is still 'Pending Approval' under one of the seeded workflows (switching the workflow
--    off would strand it - approve, reject or cancel those payments first)
-- 2. switches the seeded Payment workflows off: the workflow master, its department scopes and their stages get
--    is_active = 'N' (rows are kept). Only the rows 67 made are touched - found by their description - so a Payment workflow
--    someone added later on the Approval Workflows screen stays. Payments already saved keep their workflow_types_id.
-- 3. takes the Payment Approval screen away from KTM1006 (permissions by ecno) and NSU00002 (non-staff, by login_id) again
-- Run this BEFORE payment_conditional_approval_2026-10-22_ROLLBACK.sql.
-- Run: cd grn-service && node sql/run_sql.mjs sql/backups/payment_workflow_nsu00002_ktm1006_2026-10-22_ROLLBACK.sql
-- ============================================================
GO

IF EXISTS (
    SELECT 1
    FROM dbo.payment_info p
    JOIN dbo.workflow_types wt ON wt.workflow_types_id = p.workflow_types_id
    JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id AND m.entity_type = 'Payment'
    WHERE p.status = 'Pending Approval' AND wt.workflow_types_description = N'IA approval for every payment; Admin approval above the limit')
    THROW 56901, N'Payments are still awaiting approval under the seeded Payment workflow - approve, reject or cancel them before rolling back sql/67.', 1;
GO

UPDATE ws SET ws.is_active = 'N'
FROM dbo.workflow_stage ws
JOIN dbo.workflow_types wt ON wt.workflow_types_id = ws.workflow_types_id
JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id AND m.entity_type = 'Payment'
WHERE wt.workflow_types_description = N'IA approval for every payment; Admin approval above the limit';

UPDATE wt SET wt.is_active = 'N'
FROM dbo.workflow_types wt
JOIN dbo.approval_workflow_master m ON m.workflow_id = wt.workflow_id AND m.entity_type = 'Payment'
WHERE wt.workflow_types_description = N'IA approval for every payment; Admin approval above the limit';

-- a master with no active department scope left is switched off too
UPDATE m SET m.is_active = 'N'
FROM dbo.approval_workflow_master m
WHERE m.entity_type = 'Payment' AND m.workflow_name = N'Payment Approval Workflow'
  AND NOT EXISTS (SELECT 1 FROM dbo.workflow_types wt WHERE wt.workflow_id = m.workflow_id AND wt.is_active = 'Y');
GO

-- the Payment Approval screen: remove the entry 67 added, nothing else in their permissions
DECLARE @sid INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'PaymentApprovalScreen');
UPDATE u
SET screens_json = ISNULL((SELECT '[' + STRING_AGG(CAST(j.value AS NVARCHAR(MAX)), ',') WITHIN GROUP (ORDER BY CAST(j.[key] AS INT)) + ']'
                           FROM OPENJSON(u.screens_json) j
                           WHERE ISNULL(TRY_CAST(JSON_VALUE(j.value, '$.screen_id') AS INT), -1) <> @sid), '[]'),
    updated_date = GETDATE()
FROM dbo.nt_user_permissions_json u
WHERE (u.ecno = 'KTM1006' OR u.login_id = 'NSU00002') AND u.is_active = 'Y'
  AND EXISTS (SELECT 1 FROM OPENJSON(u.screens_json) WITH (screen_id INT '$.screen_id') WHERE screen_id = @sid);
GO
