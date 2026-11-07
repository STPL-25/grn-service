-- ROLLBACK of sql/95_kyc_change_in_kyc_approval_screen.sql: puts every user's screens_json and the separate screen's is_active back
-- exactly as they were before sql/95 (from bk_sql95_screens), then removes the backup table.
-- Anything an administrator changed on those users' permissions AFTER sql/95 is overwritten by the old copy - review first:
--   SELECT * FROM dbo.bk_sql95_screens;
-- Run: cd grn-service && node sql/run_sql.mjs sql/backups/kyc_change_in_kyc_approval_screen_2026-11-08_ROLLBACK.sql
IF OBJECT_ID('dbo.bk_sql95_screens', 'U') IS NULL
    THROW 58698, N'bk_sql95_screens does not exist: sql/95 was not run (or was already rolled back).', 1;
GO
UPDATE u
SET screens_json = b.old_value, updated_date = GETDATE()
FROM dbo.nt_user_permissions_json u
JOIN dbo.bk_sql95_screens b ON b.kind = 'USER' AND b.ref_id = u.user_perm_json_sno;
GO
UPDATE s
SET is_active = b.old_value
FROM dbo.screens s
JOIN dbo.bk_sql95_screens b ON b.kind = 'SCREEN' AND b.ref_id = s.screen_id;
GO
DROP TABLE dbo.bk_sql95_screens;
GO
