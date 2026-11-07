-- ============================================================
-- sql/95: a supplier's KYC change request is decided on the EXISTING "KYC Approval Screen" - no separate screen.
-- Database: Non_trade_Dev. Re-runnable.
--
-- sql/93 + sql/94 first gave the requests a screen of their own ("KYC Change Approvals"). The requests are now listed on the KYC
-- Approval Screen next to the KYC submissions (previous record vs current record, reason, authorization letter, the same approve /
-- reject), so this:
--   1. takes the separate screen away: it is removed from every user's screens_json and switched off (is_active = 'N' - the row is
--      not deleted). Where sql/94 never ran there is nothing to remove;
--   2. makes sure the people the requests are routed to can open the KYC Approval Screen: every approver named in the stages of the
--      KYC workflow (new submissions) and of the supplier-change workflow (the same one unless re-routed on Approval Routing) who
--      does not have it yet gets it with View / Edit / Approve / Reject (permission ids 2, 4, 7, 8 - what KYC approvers have).
--      A non-staff approver such as ED001 is matched on login_id. Nobody loses or changes any other screen.
--
-- It changes who can see what, so every user_perm_json row it touches is first copied to bk_sql95_screens (once - a second run
-- never overwrites the original copy), and the rollback puts those rows back exactly.
-- Rollback: sql/backups/kyc_change_in_kyc_approval_screen_2026-11-08_ROLLBACK.sql
-- ============================================================
IF OBJECT_ID('dbo.bk_sql95_screens', 'U') IS NULL
    CREATE TABLE dbo.bk_sql95_screens (
        bk_sno        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_bk_sql95_screens PRIMARY KEY,
        kind          VARCHAR(10)   NOT NULL,      -- USER (nt_user_permissions_json.screens_json) | SCREEN (screens.is_active)
        ref_id        INT           NOT NULL,
        old_value     NVARCHAR(MAX) NULL,
        backed_up_at  DATETIME      NOT NULL CONSTRAINT DF_bk_sql95_screens_at DEFAULT (GETDATE())
    );
GO

DECLARE @old INT = (SELECT screen_id FROM dbo.screens WHERE comp = 'KycChangeApprovalScreen');
DECLARE @kyc INT = (SELECT screen_id FROM dbo.screens WHERE comp = 'KYCApprovalScreen');
IF @kyc IS NULL
    THROW 58641, N'The KYC Approval Screen was not found, so nobody can be given access to it.', 1;

DECLARE @oldTxt VARCHAR(10) = ISNULL(CAST(@old AS VARCHAR(10)), '-1');
DECLARE @kycTxt VARCHAR(10) = CAST(@kyc AS VARCHAR(10));

-- everyone the requests / new submissions are routed to
DECLARE @approvers TABLE (who VARCHAR(30) PRIMARY KEY);
INSERT @approvers
SELECT DISTINCT UPPER(LTRIM(RTRIM(JSON_VALUE(v.value, '$.approver_ecno'))))
FROM (SELECT dbo.fn_scopeless_workflow_types(dbo.fn_resolve_approval_entity('KYC', 'SUPPLIER')) AS wf
      UNION
      SELECT dbo.fn_scopeless_workflow_types(dbo.fn_resolve_approval_entity('KYC', 'SUPPLIER_CHANGE'))) w
JOIN dbo.vw_workflow_stages ws ON ws.workflow_types_id = w.wf
CROSS APPLY OPENJSON(ws.stages_json) s
CROSS APPLY OPENJSON(JSON_VALUE(s.value, '$.stage_order_json')) v
WHERE s.[key] = '0' AND NULLIF(LTRIM(RTRIM(JSON_VALUE(v.value, '$.approver_ecno'))), '') IS NOT NULL;

-- the rows this will change, copied first (only the first time)
INSERT dbo.bk_sql95_screens (kind, ref_id, old_value)
SELECT 'USER', u.user_perm_json_sno, u.screens_json
FROM dbo.nt_user_permissions_json u
WHERE u.is_active = 'Y' AND ISJSON(u.screens_json) = 1
  AND (   EXISTS (SELECT 1 FROM OPENJSON(u.screens_json) x WHERE JSON_VALUE(x.value, '$.screen_id') = @oldTxt)
       OR (    (UPPER(u.ecno) IN (SELECT who FROM @approvers) OR UPPER(u.login_id) IN (SELECT who FROM @approvers))
           AND NOT EXISTS (SELECT 1 FROM OPENJSON(u.screens_json) x WHERE JSON_VALUE(x.value, '$.screen_id') = @kycTxt)))
  AND NOT EXISTS (SELECT 1 FROM dbo.bk_sql95_screens b WHERE b.kind = 'USER' AND b.ref_id = u.user_perm_json_sno);

IF @old IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.bk_sql95_screens WHERE kind = 'SCREEN' AND ref_id = @old)
    INSERT dbo.bk_sql95_screens (kind, ref_id, old_value)
    SELECT 'SCREEN', screen_id, is_active FROM dbo.screens WHERE screen_id = @old;

-- 1. the separate screen goes: out of everyone's screens_json, and switched off
IF @old IS NOT NULL
BEGIN
    UPDATE u
    SET screens_json = ISNULL((SELECT '[' + STRING_AGG(CAST(x.value AS NVARCHAR(MAX)), ',') WITHIN GROUP (ORDER BY CAST(x.[key] AS INT)) + ']'
                               FROM OPENJSON(u.screens_json) x
                               WHERE JSON_VALUE(x.value, '$.screen_id') <> @oldTxt), '[]'),
        updated_date = GETDATE()
    FROM dbo.nt_user_permissions_json u
    WHERE ISJSON(u.screens_json) = 1
      AND EXISTS (SELECT 1 FROM OPENJSON(u.screens_json) x WHERE JSON_VALUE(x.value, '$.screen_id') = @oldTxt);

    UPDATE dbo.screens SET is_active = 'N' WHERE screen_id = @old;
END

-- 2. the approvers can open the KYC Approval Screen
UPDATE u
SET screens_json = JSON_MODIFY(u.screens_json, 'append $', JSON_QUERY(CONCAT('{"screen_id":', @kyc, ',"permissions":[2,4,7,8]}'))),
    updated_date = GETDATE()
FROM dbo.nt_user_permissions_json u
WHERE u.is_active = 'Y' AND ISJSON(u.screens_json) = 1
  AND (UPPER(u.ecno) IN (SELECT who FROM @approvers) OR UPPER(u.login_id) IN (SELECT who FROM @approvers))
  AND NOT EXISTS (SELECT 1 FROM OPENJSON(u.screens_json) x WHERE JSON_VALUE(x.value, '$.screen_id') = @kycTxt);

SELECT (SELECT COUNT(*) FROM dbo.bk_sql95_screens WHERE kind = 'USER') AS users_backed_up;
GO
