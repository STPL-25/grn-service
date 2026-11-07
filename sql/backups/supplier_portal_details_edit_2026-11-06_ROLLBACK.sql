-- ROLLBACK of sql/91_supplier_portal_details_edit.sql (2026-11-06).
-- Removes sp_nt_UpdateSupplierPortalDetails and kyc_portal_detail_log. Nothing else existed before sql/91.
--
-- Refuses while the log has rows: those are portal details the payments team changed on suppliers' KYC. Rolling back does not
-- undo those changes (kyc_basic_info keeps the new values) - it would only lose who changed what. Review the rows first:
--   SELECT * FROM dbo.kyc_portal_detail_log ORDER BY log_sno;
-- and, only if you mean to throw that history away, run the two DROP statements below by hand.
IF OBJECT_ID('dbo.kyc_portal_detail_log', 'U') IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.kyc_portal_detail_log)
    THROW 56339, 'kyc_portal_detail_log has changes logged - review them before rolling back sql/91 (see the header).', 1;
GO
DROP PROCEDURE IF EXISTS dbo.sp_nt_UpdateSupplierPortalDetails;
GO
DROP TABLE IF EXISTS dbo.kyc_portal_detail_log;
GO
