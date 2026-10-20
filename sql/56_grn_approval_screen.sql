-- ============================================================
-- 56_grn_approval_screen.sql   (Non_trade_Dev)
-- Dedicated "GRN Approval Screen" (comp GRNApprovalScreen, GRN group next to GRN Page) + grant to KTM1148.
-- Re-runnable.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'GRNApprovalScreen')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    SELECT N'GRN Approval Screen', screen_code, 'GRNApprovalScreen', 'ShieldCheck', group_id, display_order + 1, 'Y'
    FROM dbo.screens WHERE comp = 'GRNPage';
GO
DECLARE @sid INT = (SELECT TOP 1 screen_id FROM dbo.screens WHERE comp = 'GRNApprovalScreen');
DECLARE @json NVARCHAR(MAX) = (SELECT 'KTM1148' AS ecno, @sid AS screen_id,
                                      JSON_QUERY('[2,3,4,5,7,8]') AS permission_ids FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
EXEC dbo.sp_nt_GrantScreenToUser @jsonInput = @json;
GO
SELECT s.screen_id, s.screen_name, s.comp, s.group_id, s.display_order FROM dbo.screens s WHERE comp = 'GRNApprovalScreen';
GO
