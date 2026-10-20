-- ============================================================
-- 52_accounts_and_payment_group.sql   (Non_trade_Dev ONLY)
-- New menu group "Accounts and Payment": Payment, GSTR-2B Reconciliation and Journals.
-- The old Account Heads screen is replaced by the Account Head master (Masters > Account Head, sql/131),
-- so that screen is switched off; its suspense-journal view lives on in the new Journals screen.
-- Re-runnable.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.screen_group WHERE group_name = N'Accounts and Payment')
    INSERT INTO dbo.screen_group (group_name, is_active) VALUES (N'Accounts and Payment', 'Y');
GO

DECLARE @g INT = (SELECT group_id FROM dbo.screen_group WHERE group_name = N'Accounts and Payment');

IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'JournalsPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Journals', 'S18', 'JournalsPage', 'BookOpen', @g, 3, 'Y');

UPDATE dbo.screens SET group_id = @g, display_order = 1, is_active = 'Y' WHERE comp = 'PaymentPage';
UPDATE dbo.screens SET group_id = @g, display_order = 2 WHERE comp = 'Gstr2bPage';
UPDATE dbo.screens SET group_id = @g, display_order = 3 WHERE comp = 'JournalsPage';
UPDATE dbo.screens SET is_active = 'N' WHERE comp = 'AccountHeadsPage';   -- replaced by the Account Head master
GO

DECLARE @screen_id INT, @json NVARCHAR(200);
SELECT @screen_id = screen_id FROM dbo.screens WHERE comp = 'JournalsPage';
SET @json = N'{"ecno":"KTM1148","screen_id":' + CAST(@screen_id AS VARCHAR(10)) + N',"permission_ids":[2,3,4,5]}';
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO
