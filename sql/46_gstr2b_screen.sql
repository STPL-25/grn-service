-- ============================================================
-- 46_gstr2b_screen.sql   (Non_trade_Dev ONLY)
-- Registers the GSTR-2B Reconciliation screen in the GRN group (6). Access is NOT granted here:
-- give 'GSTR-2B Reconciliation' to the Accounts users on the permissions screen.
-- Re-runnable.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'Gstr2bPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'GSTR-2B Reconciliation', 'S17', 'Gstr2bPage', 'FileSpreadsheet', 6, 23, 'Y');
GO
