-- ============================================================
-- Vendor-driven receipt settlement detail
-- Database: Non_Trade (MSSQL)
--
-- Payment continues to be released only from matched invoice allocation
-- buckets. This adds the requisition mode, GRN arrival date and selected
-- supplier settlement interval so Accounts can group verified arrivals by
-- date without bypassing the existing invoice-match safeguard.
-- Run after backend-stpl/sql/59_vendor_driven_purchase_requisition.sql.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPayableBills
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        iad.invoice_alloc_sno AS bill_sno,
        i.invoice_no          AS bill_no,
        i.vendor_invoice_no   AS supplier_invoice_no,
        p.po_df_no            AS po_no,
        i.vendor_sno,
        k.company_name        AS vendor_name,
        i.invoice_date,
        i.due_date,
        pr.request_mode,
        pr.payment_cycle_days,
        CONVERT(VARCHAR(10), arrivals.last_received_date, 120) AS received_date,
        iad.bucket_type,
        iad.allocated_amount,
        iad.hold_amount,
        iad.matched_qty_ratio,
        iad.release_amount AS net_payable,
        ISNULL(paid.paidSoFar, 0) AS paid_amount,
        iad.release_amount - ISNULL(paid.paidSoFar, 0) AS outstanding
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.pr_basic_info pr ON pr.pr_basic_sno = p.pr_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT MAX(g.received_date) AS last_received_date
        FROM dbo.grn_basic_info g
        WHERE g.po_basic_sno = p.po_basic_sno
          AND g.is_active = 'Y'
    ) arrivals
    OUTER APPLY (
        SELECT ISNULL(SUM(pad.amount), 0) AS paidSoFar
        FROM dbo.payment_allocation_details pad
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    WHERE iad.is_active = 'Y'
      AND iad.release_amount > ISNULL(paid.paidSoFar, 0) + 0.01
    ORDER BY arrivals.last_received_date, iad.invoice_alloc_sno;
END;
GO
