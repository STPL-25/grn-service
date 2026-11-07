-- ============================================================
-- 90_gstr2b_company_scope.sql   (Non_trade_Dev)
--
-- GSTR-2B Reconciliation: a 2B file belongs to one company, so only users with access to that company may see it.
--   Before: GET /api/gstr2b/uploads listed every upload of every company and the screen opened the latest one by default;
--           "Missing in 2B" listed every company's invoices.
--   Now:   the screen asks for a company, then one of that company's uploaded files, and shows nothing until both are picked.
--
--   * sp_nt_Gstr2bListUploads  takes { com_sno?, hierarchy? }; returns com_sno + com_name. An upload is visible when any of the
--                              caller's hierarchy rows is for its company (a 2B file is company-wide: one GSTIN).
--                              Uploads with no company are hidden from hierarchy-filtered callers.
--   * sp_nt_Gstr2bSummary      also returns com_sno + com_name (grn-service checks the caller's access with it).
--   * sp_nt_Gstr2bMissingIn2B  takes { com_sno?, hierarchy? }; filters on the invoice's company (invoice, else its PO's),
--                              division and branch, the same rule as sp_nt_GetUnpaidGst. Returns com_sno.
--   * sp_nt_Gstr2bScopeOf      (new) { upload_sno | row_sno | invoice_sno } -> com_sno, div_sno, brn_sno of that record, so the
--                              row / invoice actions can refuse records of another company.
--   hierarchy: JSON array of { com_sno, div_sno, brn_sno } (attachHierarchyScope). NULL/absent = no filter (internal callers only).
--   No parameter = old behaviour, so the procedures stay compatible with the code that ran before this file.
--
-- Re-runnable. Rollback: backups/gstr2b_company_scope_2026-11-06_ROLLBACK.sql (the definitions before this file);
-- also DROP PROCEDURE dbo.sp_nt_Gstr2bScopeOf.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bListUploads
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    SELECT u.upload_sno, u.com_sno, c.com_name, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at,
           SUM(CASE WHEN r.match_status = 'Matched' THEN 1 ELSE 0 END) AS matched,
           SUM(CASE WHEN r.match_status = 'Mismatch' THEN 1 ELSE 0 END) AS mismatch,
           SUM(CASE WHEN r.match_status = 'Unmatched' THEN 1 ELSE 0 END) AS unmatched,
           SUM(CASE WHEN r.match_status = 'Added' THEN 1 ELSE 0 END) AS added
    FROM dbo.gstr2b_upload u
    LEFT JOIN dbo.company_master c ON c.com_sno = u.com_sno
    LEFT JOIN dbo.gstr2b_row r ON r.upload_sno = u.upload_sno
    WHERE (@com IS NULL OR u.com_sno = @com)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno') h WHERE h.com_sno = u.com_sno))
    GROUP BY u.upload_sno, u.com_sno, c.com_name, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at
    ORDER BY u.upload_sno DESC;
END
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bSummary
    @upload_sno INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.upload_sno, u.com_sno, c.com_name, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at,
           SUM(CASE WHEN r.match_status = 'Matched' THEN 1 ELSE 0 END) AS matched,
           SUM(CASE WHEN r.match_status = 'Mismatch' THEN 1 ELSE 0 END) AS mismatch,
           SUM(CASE WHEN r.match_status = 'Unmatched' THEN 1 ELSE 0 END) AS unmatched,
           SUM(CASE WHEN r.match_status = 'Added' THEN 1 ELSE 0 END) AS added,
           SUM(CASE WHEN r.match_status = 'Info' THEN 1 ELSE 0 END) AS notes_info
    FROM dbo.gstr2b_upload u
    LEFT JOIN dbo.company_master c ON c.com_sno = u.com_sno
    LEFT JOIN dbo.gstr2b_row r ON r.upload_sno = u.upload_sno
    WHERE u.upload_sno = @upload_sno
    GROUP BY u.upload_sno, u.com_sno, c.com_name, u.return_period, u.file_name, u.row_count, u.uploaded_by, u.uploaded_at;
END
GO

-- our invoices that are not in 2B yet (GST-registered suppliers, still Pending 2B), for one company / the caller's companies
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bMissingIn2B
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @com INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.com_sno') AS INT),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy');
    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no, CONVERT(VARCHAR(10), i.invoice_date, 120) AS invoice_date, i.vendor_sno, k.company_name AS vendor_name, k.gst_no,
           i.invoice_amount, i.taxable_value, i.itc_status, i.payment_hold_override, COALESCE(i.com_sno, po.com_sno) AS com_sno
    FROM dbo.invoice_info i
    JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = i.po_basic_sno
    WHERE i.is_active = 'Y' AND LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, 'Pending 2B') = 'Pending 2B'
      AND (@com IS NULL OR COALESCE(i.com_sno, po.com_sno) = @com)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = COALESCE(i.com_sno, po.com_sno) AND (h.div_sno IS NULL OR h.div_sno = COALESCE(i.div_sno, po.div_sno))
                                      AND (h.brn_sno IS NULL OR h.brn_sno = COALESCE(i.brn_sno, po.brn_sno))))
    ORDER BY i.invoice_date, i.invoice_sno;
END
GO

-- which company a 2B upload / 2B row / books invoice belongs to. { upload_sno } | { row_sno } | { invoice_sno }. No row = not found.
CREATE OR ALTER PROCEDURE dbo.sp_nt_Gstr2bScopeOf
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @u INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.upload_sno') AS INT),
            @row INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.row_sno') AS INT),
            @inv INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.invoice_sno') AS INT);
    IF @u IS NOT NULL
        SELECT u.com_sno, CAST(NULL AS INT) AS div_sno, CAST(NULL AS INT) AS brn_sno FROM dbo.gstr2b_upload u WHERE u.upload_sno = @u;
    ELSE IF @row IS NOT NULL
        SELECT u.com_sno, CAST(NULL AS INT) AS div_sno, CAST(NULL AS INT) AS brn_sno
        FROM dbo.gstr2b_row r JOIN dbo.gstr2b_upload u ON u.upload_sno = r.upload_sno WHERE r.row_sno = @row;
    ELSE IF @inv IS NOT NULL
        SELECT COALESCE(i.com_sno, po.com_sno) AS com_sno, COALESCE(i.div_sno, po.div_sno) AS div_sno, COALESCE(i.brn_sno, po.brn_sno) AS brn_sno
        FROM dbo.invoice_info i LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = i.po_basic_sno WHERE i.invoice_sno = @inv;
    ELSE
        THROW 53630, 'upload_sno, row_sno or invoice_sno is required.', 1;
END
GO
