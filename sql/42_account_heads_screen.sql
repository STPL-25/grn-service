-- ============================================================
-- 42_account_heads_screen.sql   (Non_trade_Dev ONLY)
-- Account Heads screen: map each sub-category to an account head, review suspense journals.
-- Re-runnable.
-- ============================================================

-- sub-category list for the mapping grid (+ how much value is parked in Suspense for it)
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetSubcategoryAccountMap
AS
BEGIN
    SET NOCOUNT ON;
    SELECT sc.subcat_sno, sc.subcat_name, sc.cat_sno, c.cat_name, sc.subcat_stock_type,
           sc.subcat_account_head_sno AS account_head_sno, h.head_code, h.head_name,
           ISNULL(s.suspense_amount, 0) AS suspense_amount
    FROM dbo.subcategory_master sc
    LEFT JOIN dbo.category_master c ON c.cat_sno = sc.cat_sno
    LEFT JOIN dbo.acct_account_head h ON h.head_sno = sc.subcat_account_head_sno
    OUTER APPLY (
        SELECT SUM(l.debit) AS suspense_amount
        FROM dbo.acct_journal_line l
        JOIN dbo.acct_journal j ON j.journal_sno = l.journal_sno AND j.status = 'Posted'
        WHERE l.is_suspense = 1 AND l.subcat_sno = sc.subcat_sno
    ) s
    WHERE sc.subcat_active = 'Y'
    ORDER BY c.cat_name, sc.subcat_name;
END
GO

-- Accounting group screen next to the GRN group (6)
IF NOT EXISTS (SELECT 1 FROM dbo.screens WHERE comp = 'AccountHeadsPage')
    INSERT INTO dbo.screens (screen_name, screen_code, comp, comp_img, group_id, display_order, is_active)
    VALUES (N'Account Heads', 'S16', 'AccountHeadsPage', 'BookOpen', 6, 22, 'Y');
GO

-- Screen access is NOT granted here: give 'Account Heads' to the Accounts users on the permissions screen.
