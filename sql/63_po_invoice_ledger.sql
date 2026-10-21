-- ============================================================
-- 63_po_invoice_ledger.sql   (Non_trade_Dev ONLY, read-only, re-runnable)
-- Invoice-wise view for the Payment page: every supplier invoice on a PO (paid and unpaid, allocated or not)
-- plus what each GRN captured about its supplier invoice. sp_nt_GetPayableBillsNet only returns allocations that
-- still have an outstanding balance, so a settled invoice - or a PO whose GRN carries no invoice at all (GRNs
-- raised before sql/54 made the invoice mandatory) - was invisible and the page just said "invoice awaited".
-- { vendor_sno? }  ->  two recordsets
--   1) invoices : one row per active invoice_info row
--        payment_status = Paid | Part paid | Unpaid | Not allocated (no allocation yet, so it cannot be paid)
--        dup_count      = OTHER active invoices of the same supplier with the same supplier invoice no (a possible duplicate)
--   2) grns     : one row per active GRN (Approved / Received / Pending Approval) with the invoice data it captured
--        has_invoice_data = invoice no + date + amount all present;  dup_count = other GRNs/invoices with the same invoice no
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPoInvoiceLedger
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no AS supplier_invoice_no, i.po_basic_sno, p.po_df_no AS po_no,
           i.vendor_sno, i.invoice_date, i.due_date, i.invoice_amount, i.match_status, i.verification_status,
           i.invoice_file_url,
           ISNULL(a.release_total, 0) AS release_total,
           ISNULL(a.paid_total, 0)    AS paid_total,
           ISNULL(a.release_total, 0) - ISNULL(a.paid_total, 0) AS outstanding,
           CASE WHEN a.alloc_count IS NULL THEN 'Not allocated'
                WHEN a.release_total - a.paid_total <= 0.01 AND a.paid_total > 0 THEN 'Paid'
                WHEN a.paid_total > 0 THEN 'Part paid'
                ELSE 'Unpaid' END AS payment_status,
           a.payment_nos,
           (SELECT COUNT(*) FROM dbo.invoice_info d
             WHERE d.is_active = 'Y' AND d.invoice_sno <> i.invoice_sno AND d.vendor_sno = i.vendor_sno
               AND LEN(ISNULL(i.vendor_invoice_no, '')) > 0
               AND UPPER(LTRIM(RTRIM(d.vendor_invoice_no))) = UPPER(LTRIM(RTRIM(i.vendor_invoice_no)))) AS dup_count
    FROM dbo.invoice_info i
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    OUTER APPLY (
        SELECT COUNT(*) AS alloc_count,
               SUM(iad.release_amount) AS release_total,
               SUM(ISNULL(pd.paid, 0)) AS paid_total,
               (SELECT STRING_AGG(x.payment_no, ', ') FROM (
                    SELECT DISTINCT pi.payment_no
                    FROM dbo.invoice_allocation_details iad2
                    JOIN dbo.payment_allocation_details pad ON pad.invoice_alloc_sno = iad2.invoice_alloc_sno
                    JOIN dbo.payment_info pi ON pi.payment_sno = pad.payment_sno
                    WHERE iad2.invoice_sno = i.invoice_sno AND iad2.is_active = 'Y') x) AS payment_nos
        FROM dbo.invoice_allocation_details iad
        OUTER APPLY (SELECT SUM(pad.amount) AS paid FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno) pd
        WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
    ) a
    WHERE i.is_active = 'Y' AND i.po_basic_sno IS NOT NULL
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY i.po_basic_sno, i.invoice_date, i.invoice_sno;

    SELECT g.grn_basic_sno, g.grn_no, g.po_basic_sno, p.po_df_no AS po_no, g.vendor_sno, g.status, g.received_date,
           NULLIF(LTRIM(RTRIM(g.doc_ref_no)), '') AS invoice_no, g.invoice_date, g.invoice_amount, g.invoice_doc_url,
           CAST(CASE WHEN NULLIF(LTRIM(RTRIM(g.doc_ref_no)), '') IS NOT NULL AND g.invoice_date IS NOT NULL AND g.invoice_amount IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS has_invoice_data,
           CASE WHEN NULLIF(LTRIM(RTRIM(g.doc_ref_no)), '') IS NULL THEN 0
                ELSE (SELECT COUNT(*) FROM dbo.grn_basic_info d
                       WHERE d.is_active = 'Y' AND d.grn_basic_sno <> g.grn_basic_sno AND d.vendor_sno = g.vendor_sno
                         AND UPPER(LTRIM(RTRIM(d.doc_ref_no))) = UPPER(LTRIM(RTRIM(g.doc_ref_no))))
                   + (SELECT COUNT(*) FROM dbo.invoice_info d
                       WHERE d.is_active = 'Y' AND d.vendor_sno = g.vendor_sno AND d.po_basic_sno <> g.po_basic_sno
                         AND UPPER(LTRIM(RTRIM(d.vendor_invoice_no))) = UPPER(LTRIM(RTRIM(g.doc_ref_no)))) END AS dup_count
    FROM dbo.grn_basic_info g
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = g.po_basic_sno
    WHERE g.is_active = 'Y' AND g.status IN ('Approved', 'Received', 'Pending Approval')
      AND (@vendor_sno IS NULL OR g.vendor_sno = @vendor_sno)
    ORDER BY g.po_basic_sno, g.grn_basic_sno;
END
GO
