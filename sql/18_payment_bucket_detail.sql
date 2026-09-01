-- ============================================================
-- sp_nt_GetPayableBills / sp_nt_GetPaymentHistory v2 — add hold_amount +
-- matched_qty_ratio to the bucket detail already returned
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : nt-frontend-stpl Payment/{types,PayableBillSidebar,PaymentHistoryView}.tsx
--
-- Why this is needed
-- ------------------
-- Both procs (14_payment.sql) already return one row per bucket
-- (invoice_alloc_sno aliased bill_sno) and already select iad.bucket_type —
-- the frontend types/components just never surfaced it. What's genuinely
-- missing is hold_amount and matched_qty_ratio, so a partially-matched
-- bucket's non-payable portion is visible before someone tries to pay it.
-- Purely additive SELECT columns — DROP+CREATE per this repo's sp_nt_*
-- convention, byte-identical WHERE/JOIN logic otherwise.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_GetPayableBills', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPayableBills;
GO
CREATE PROCEDURE dbo.sp_nt_GetPayableBills
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
        iad.bucket_type,
        iad.allocated_amount,
        iad.hold_amount,
        iad.matched_qty_ratio,
        iad.release_amount    AS net_payable,
        ISNULL(paid.paidSoFar, 0)                       AS paid_amount,
        (iad.release_amount - ISNULL(paid.paidSoFar, 0)) AS outstanding
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i        ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k  ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT paidSoFar = ISNULL(SUM(pad.amount), 0)
        FROM dbo.payment_allocation_details pad
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    WHERE iad.is_active = 'Y'
      AND iad.release_amount > ISNULL(paid.paidSoFar, 0) + 0.01
    ORDER BY iad.invoice_alloc_sno DESC;
END;
GO

IF OBJECT_ID('dbo.sp_nt_GetPaymentHistory', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPaymentHistory;
GO
CREATE PROCEDURE dbo.sp_nt_GetPaymentHistory
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @bill_sno INT = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @bill_sno = TRY_CAST(JSON_VALUE(@jsonInput, '$.bill_sno') AS INT);

    SELECT
        pi.payment_sno,
        pi.payment_no,
        pad.invoice_alloc_sno AS bill_sno,
        i.invoice_no          AS bill_no,
        i.vendor_invoice_no   AS supplier_invoice_no,
        p.po_df_no            AS po_no,
        pi.vendor_sno,
        k.company_name        AS vendor_name,
        iad.bucket_type,
        iad.hold_amount,
        iad.matched_qty_ratio,
        pi.payment_date,
        pad.amount,
        pi.mode,
        pi.bank_account,
        pi.reference_no,
        pi.status,
        pi.remarks,
        pi.created_by         AS created_by_name,
        pi.created_date       AS created_at
    FROM dbo.payment_allocation_details pad
    JOIN dbo.payment_info pi              ON pi.payment_sno = pad.payment_sno
    JOIN dbo.invoice_allocation_details iad ON iad.invoice_alloc_sno = pad.invoice_alloc_sno
    JOIN dbo.invoice_info i               ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p        ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k          ON k.kyc_basic_info_sno = pi.vendor_sno
    WHERE pi.is_active = 'Y'
      AND (@bill_sno IS NULL OR pad.invoice_alloc_sno = @bill_sno)
    ORDER BY pi.payment_sno DESC;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('dbo.sp_nt_GetPayableBills');
--   -- should now include hold_amount, matched_qty_ratio in the SELECT list.
-- ============================================================
