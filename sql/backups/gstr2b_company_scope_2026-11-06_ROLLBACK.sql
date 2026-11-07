-- ROLLBACK for sql/90_gstr2b_company_scope.sql
-- The definitions below are the live Non_trade_Dev ones read on 2026-11-06 before 90 was written (unchanged since sql/45).
-- Run with: cd grn-service && node sql/run_sql.mjs sql/backups/gstr2b_company_scope_2026-11-06_ROLLBACK.sql
-- Then put grn-service/src/gstr2b and the GSTR-2B screen back to their pre-90 versions too (they send com_sno / hierarchy).

CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bListUploads
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.upload_sno, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at,
           SUM(CASE WHEN r.match_status = 'Matched' THEN 1 ELSE 0 END) AS matched,
           SUM(CASE WHEN r.match_status = 'Mismatch' THEN 1 ELSE 0 END) AS mismatch,
           SUM(CASE WHEN r.match_status = 'Unmatched' THEN 1 ELSE 0 END) AS unmatched,
           SUM(CASE WHEN r.match_status = 'Added' THEN 1 ELSE 0 END) AS added
    FROM dbo.gstr2b_upload u LEFT JOIN dbo.gstr2b_row r ON r.upload_sno = u.upload_sno
    GROUP BY u.upload_sno, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at
    ORDER BY u.upload_sno DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bSummary
    @upload_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.upload_sno, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at,
           SUM(CASE WHEN r.match_status = 'Matched' THEN 1 ELSE 0 END) AS matched,
           SUM(CASE WHEN r.match_status = 'Mismatch' THEN 1 ELSE 0 END) AS mismatch,
           SUM(CASE WHEN r.match_status = 'Unmatched' THEN 1 ELSE 0 END) AS unmatched,
           SUM(CASE WHEN r.match_status = 'Added' THEN 1 ELSE 0 END) AS added,
           SUM(CASE WHEN r.match_status = 'Info' THEN 1 ELSE 0 END) AS notes_info
    FROM dbo.gstr2b_upload u LEFT JOIN dbo.gstr2b_row r ON r.upload_sno = u.upload_sno
    WHERE u.upload_sno = @upload_sno
    GROUP BY u.upload_sno, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bMissingIn2B
AS
BEGIN
    SET NOCOUNT ON;
    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no, CONVERT(VARCHAR(10), i.invoice_date, 120) AS invoice_date, i.vendor_sno, k.company_name AS vendor_name, k.gst_no,
           i.invoice_amount, i.taxable_value, i.itc_status, i.payment_hold_override
    FROM dbo.invoice_info i JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    WHERE i.is_active = 'Y' AND LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, 'Pending 2B') = 'Pending 2B'
    ORDER BY i.invoice_date, i.invoice_sno;
END
GO

IF OBJECT_ID('dbo.sp_nt_Gstr2bScopeOf', 'P') IS NOT NULL DROP PROCEDURE dbo.sp_nt_Gstr2bScopeOf;
GO
