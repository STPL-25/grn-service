-- 76: an invoice that is not in GSTR-2B is never held back from payment - it is paid WITHOUT its GST and the GST is listed as unpaid
--
-- sql/70 held the WHOLE invoice when it carried no taxable value (it could not be split into taxable and GST).  Now every invoice
-- can be split: the taxable value is the one on the invoice (typed on the GRN), else worked back from the GST % on the PO lines,
-- else - the PO carries no GST rate, so no GST is known - the whole invoice amount.  A GST-registered supplier's invoice that is not in
-- GSTR-2B (and has no Accounts hold release) is therefore payable up to its taxable value at once; the GST part goes to the Unpaid GST
-- screen and moves to Payment Run when a 2B upload has the invoice (sql/75).
--
-- Re-runnable.  Rollback: sql/backups/pay_without_gst_2026-11-01_ROLLBACK.sql

-- what can be paid on one bill right now
--   taxable_eff   the invoice's taxable value (see above)
--   taxable_part  the share of this bill that is taxable value - TDS base
--   gst_part      the rest (GST and anything else on top of the taxable value)
--   hold_2b       what may not be paid yet because 2B does not have the invoice (= the GST part)
--   payable_now   what can be paid now: release - hold_2b - settled - reserved
CREATE OR ALTER FUNCTION dbo.fn_nt_BillPayable (@invoice_alloc_sno INT)
RETURNS TABLE
AS
RETURN
(
    SELECT iad.invoice_alloc_sno, iad.invoice_sno, iad.release_amount,
           pd.settled, pd.reserved,
           CAST(iad.release_amount - pd.settled - pd.reserved AS DECIMAL(18,2)) AS outstanding,
           x.on_hold_2b, x.taxable_known,
           t.taxable_part, CAST(iad.release_amount - t.taxable_part AS DECIMAL(18,2)) AS gst_part,
           h.hold_2b,
           CAST(CASE WHEN iad.release_amount - h.hold_2b - pd.settled - pd.reserved > 0 THEN iad.release_amount - h.hold_2b - pd.settled - pd.reserved ELSE 0 END AS DECIMAL(18,2)) AS payable_now,
           te.taxable_eff
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN 0 ELSE pad.amount END), 0) AS settled,
               ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN pad.amount ELSE 0 END), 0) AS reserved
        FROM dbo.payment_allocation_details pad
        JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) pd
    OUTER APPLY (
        SELECT ISNULL(SUM(ISNULL(p.net_cost, 0) * ISNULL(p.tax_pct, 0)) / NULLIF(SUM(ISNULL(p.net_cost, 0)), 0), 0) AS pct
        FROM dbo.po_item_details p WHERE p.po_basic_sno = i.po_basic_sno AND p.is_active IN ('Y', '1')
    ) pp
    CROSS APPLY (
        SELECT CAST(CASE WHEN ISNULL(i.invoice_amount, 0) <= 0 THEN NULL
                         WHEN i.taxable_value IS NOT NULL AND i.taxable_value > 0 AND i.taxable_value <= i.invoice_amount THEN i.taxable_value
                         WHEN pp.pct > 0 THEN ROUND(i.invoice_amount / (1 + pp.pct / 100.0), 2)
                         ELSE i.invoice_amount END AS DECIMAL(18,2)) AS taxable_eff
    ) te
    CROSS APPLY (
        SELECT CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, '') NOT IN ('Eligible', 'Ineligible')
                              AND ISNULL(i.payment_hold_override, 'N') <> 'Y' THEN 1 ELSE 0 END AS BIT) AS on_hold_2b,
               CAST(CASE WHEN te.taxable_eff IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS taxable_known
    ) x
    CROSS APPLY (
        SELECT CAST(CASE WHEN x.taxable_known = 1 THEN ROUND(iad.release_amount * te.taxable_eff / i.invoice_amount, 2) ELSE iad.release_amount END AS DECIMAL(18,2)) AS taxable_part
    ) t
    CROSS APPLY (
        SELECT CAST(CASE WHEN x.on_hold_2b = 0 THEN 0
                         WHEN x.taxable_known = 1 THEN iad.release_amount - t.taxable_part
                         ELSE iad.release_amount END AS DECIMAL(18,2)) AS hold_2b
    ) h
    WHERE (@invoice_alloc_sno IS NULL OR iad.invoice_alloc_sno = @invoice_alloc_sno)
);
GO

-- ── one payment's invoices: everything an approver needs to decide ──────────
-- @jsonInput: { payment_sno } -> per invoice: dates, PO, taxable value / GST, 2B status, what the invoice may be paid in all, what OTHER
-- payments hold or have paid, what this payment pays, what is left after it, the GST that waits for GSTR-2B, the TDS taken on it by this
-- payment (section / rate / amount) and the invoice as captured at GRN (number, date, amount, file).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPaymentInvoiceFigures
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @pay INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.payment_sno') AS INT);
    DECLARE @own BIT = CASE WHEN EXISTS (SELECT 1 FROM dbo.payment_info WHERE payment_sno = @pay AND status NOT IN ('Rejected', 'Cancelled')) THEN 1 ELSE 0 END;
    SELECT l.invoice_sno, l.invoice_no, l.supplier_invoice_no, i.invoice_amount,
           CAST(i.invoice_amount - t.taxable_eff AS DECIMAL(18,2)) AS gst_amount,
           t.payable_total, CAST(t.paid_all - CASE WHEN @own = 1 THEN l.amount ELSE 0 END AS DECIMAL(18,2)) AS paid_other,
           l.amount AS this_amount,
           CAST(t.payable_total - (t.paid_all - CASE WHEN @own = 1 THEN l.amount ELSE 0 END) - l.amount AS DECIMAL(18,2)) AS balance_after,
           CAST(t.on_hold_2b AS BIT) AS on_hold_2b, t.hold_2b,
           -- (sql/75)
           i.invoice_date, i.due_date, l.po_no, t.taxable_eff AS taxable_value, i.itc_status, i.invoice_file_url, k.gst_no AS supplier_gstin,
           CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) < 15 THEN 'No GST'
                WHEN ISNULL(i.itc_status, '') IN ('Eligible', 'Ineligible') THEN 'In GSTR-2B'
                WHEN ISNULL(i.payment_hold_override, 'N') = 'Y' THEN 'Hold released by Accounts'
                ELSE 'Not in GSTR-2B' END AS gstr2b_status,
           r.filing_period AS gstr2b_period,
           td.section_code AS tds_section, td.rate_pct AS tds_rate_pct, td.base_amount AS tds_base, td.tds_amount AS tds_this_payment,
           gr.grn_label, gr.grn_invoice_no, gr.grn_invoice_date, gr.grn_invoice_amount, gr.grn_invoice_doc_url, gr.grn_taxable_value
    FROM dbo.fn_nt_PaymentLines(@pay) l
    JOIN dbo.invoice_info i ON i.invoice_sno = l.invoice_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    LEFT JOIN dbo.gstr2b_row r ON r.row_sno = i.gstr2b_row_sno
    CROSS APPLY (
        SELECT SUM(bp.release_amount) AS payable_total, SUM(bp.settled + bp.reserved) AS paid_all,
               MAX(CAST(bp.on_hold_2b AS INT)) AS on_hold_2b, SUM(bp.hold_2b) AS hold_2b, MAX(bp.taxable_eff) AS taxable_eff
        FROM dbo.invoice_allocation_details a CROSS APPLY dbo.fn_nt_BillPayable(a.invoice_alloc_sno) bp
        WHERE a.invoice_sno = l.invoice_sno AND a.is_active = 'Y'
    ) t
    OUTER APPLY (
        SELECT TOP 1 d.section_code, d.rate_pct, SUM(d.base_amount) OVER () AS base_amount, SUM(d.tds_amount) OVER () AS tds_amount
        FROM dbo.tds_deduction d WHERE d.payment_sno = @pay AND d.invoice_sno = l.invoice_sno
    ) td
    OUTER APPLY (
        SELECT TOP 1 'GRN-' + CAST(YEAR(g.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(g.grn_no AS VARCHAR(6)), 6) AS grn_label,
               g.doc_ref_no AS grn_invoice_no, g.invoice_date AS grn_invoice_date, g.invoice_amount AS grn_invoice_amount,
               g.invoice_doc_url AS grn_invoice_doc_url, g.invoice_taxable_value AS grn_taxable_value
        FROM dbo.grn_basic_info g
        WHERE g.is_active = 'Y' AND g.vendor_sno = i.vendor_sno
          AND (g.payable_invoice_sno = i.invoice_sno OR dbo.fn_nt_NormInvoiceNo(g.doc_ref_no) = dbo.fn_nt_NormInvoiceNo(i.vendor_invoice_no))
        ORDER BY CASE WHEN g.payable_invoice_sno = i.invoice_sno THEN 0 ELSE 1 END, g.grn_basic_sno
    ) gr
    ORDER BY l.invoice_sno;
END
GO

-- The Unpaid GST screen: one row per invoice with GST left unpaid (or released since).
-- @jsonInput: { status? ('Awaiting 2B'|'Released'|'Closed'), vendor_sno?, hierarchy?, limit? }.  Refreshes the register first (no payments created).
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetUnpaidGst
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @status VARCHAR(20) = NULLIF(JSON_VALUE(@jsonInput, '$.status'), ''),
            @v INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT),
            @hier NVARCHAR(MAX) = JSON_QUERY(@jsonInput, '$.hierarchy'),
            @limit INT = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.limit') AS INT), 500);

    EXEC dbo.sp_nt_ReleaseGstAfter2b @jsonInput = N'{"release":false}';

    SELECT TOP (@limit)
           g.invoice_sno, i.invoice_no, i.vendor_invoice_no AS supplier_invoice_no, i.invoice_date, i.invoice_amount, MAX(bp.taxable_eff) AS taxable_value,
           i.vendor_sno, k.company_name AS vendor_name, k.gst_no AS supplier_gstin, po.po_df_no AS po_no,
           g.status,
           CAST(SUM(CASE WHEN g.status = 'Awaiting 2B' THEN bp.outstanding ELSE 0 END) AS DECIMAL(18,2)) AS gst_unpaid,
           CAST(SUM(ISNULL(rel.amount, 0)) AS DECIMAL(18,2)) AS gst_released,
           CAST(SUM(bp.settled + bp.reserved) - SUM(ISNULL(rel.amount, 0)) AS DECIMAL(18,2)) AS paid_before,
           i.itc_status, i.payment_hold_override,
           CASE WHEN ISNULL(i.itc_status, '') IN ('Eligible', 'Ineligible') THEN 'In GSTR-2B'
                WHEN ISNULL(i.payment_hold_override, 'N') = 'Y' THEN 'Hold released by Accounts'
                ELSE 'Not in GSTR-2B' END AS gstr2b_status,
           MAX(r.filing_period) AS gstr2b_period,
           MIN(g.noted_at) AS noted_at, DATEDIFF(DAY, MIN(g.noted_at), GETDATE()) AS days_waiting,
           MAX(g.released_at) AS released_at, MAX(rp.payment_no) AS released_payment_no, MAX(rp.status) AS released_payment_status,
           (SELECT STRING_AGG(x.payment_no, ', ') FROM (
                SELECT DISTINCT py.payment_no FROM dbo.invoice_allocation_details a2
                JOIN dbo.payment_allocation_details pad ON pad.invoice_alloc_sno = a2.invoice_alloc_sno
                JOIN dbo.payment_info py ON py.payment_sno = pad.payment_sno AND py.status NOT IN ('Rejected', 'Cancelled')
                WHERE a2.invoice_sno = g.invoice_sno AND (g.released_payment_sno IS NULL OR py.payment_sno <> g.released_payment_sno)) x) AS earlier_payment_nos
    FROM dbo.payment_gst_pending g
    JOIN dbo.invoice_info i ON i.invoice_sno = g.invoice_sno AND i.is_active = 'Y'
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.gstr2b_row r ON r.row_sno = i.gstr2b_row_sno
    LEFT JOIN dbo.payment_info rp ON rp.payment_sno = g.released_payment_sno
    CROSS APPLY dbo.fn_nt_BillPayable(g.invoice_alloc_sno) bp
    OUTER APPLY (SELECT SUM(pad.amount) AS amount FROM dbo.payment_allocation_details pad
                 WHERE pad.payment_sno = g.released_payment_sno AND pad.invoice_alloc_sno = g.invoice_alloc_sno) rel
    WHERE (@status IS NULL AND g.status <> 'Closed' OR g.status = @status)
      AND (@v IS NULL OR i.vendor_sno = @v)
      AND (@hier IS NULL OR EXISTS (SELECT 1 FROM OPENJSON(@hier) WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno') h
                                    WHERE h.com_sno = COALESCE(i.com_sno, po.com_sno) AND (h.div_sno IS NULL OR h.div_sno = COALESCE(i.div_sno, po.div_sno))
                                      AND (h.brn_sno IS NULL OR h.brn_sno = COALESCE(i.brn_sno, po.brn_sno))))
    GROUP BY g.invoice_sno, g.status, g.released_payment_sno, i.invoice_no, i.vendor_invoice_no, i.invoice_date, i.invoice_amount, i.vendor_sno, k.company_name, k.gst_no,
             po.po_df_no, i.itc_status, i.payment_hold_override
    ORDER BY CASE g.status WHEN 'Awaiting 2B' THEN 0 WHEN 'Released' THEN 1 ELSE 2 END, MIN(g.noted_at), g.invoice_sno;
END
GO

-- ── Payment list: posts GRN invoices; carries the invoice TDS rate ──
-- ── 4. Payment screen list: adds what can be paid now ───────────────────────
-- Same as before plus: gst_amount (the GST share of the bill), gst_held (the part kept back until the invoice shows in GSTR-2B),
-- payable_now (what can be paid today; below `outstanding` while the GST is held) and taxable_known.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPayableBillsNet
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    BEGIN TRY
        EXEC dbo.sp_nt_SyncServicePoInvoicesToPayables;
    END TRY
    BEGIN CATCH
        -- a sync problem must never take the whole Payment list down
    END CATCH

    -- invoices captured on approved GRNs become payable here (sql/75)
    BEGIN TRY
        EXEC dbo.sp_nt_SyncGrnInvoicesToPayables;
    END TRY
    BEGIN CATCH
    END CATCH

    SELECT
        iad.invoice_alloc_sno AS bill_sno, i.invoice_sno, i.invoice_no AS bill_no, i.vendor_invoice_no AS supplier_invoice_no,
        p.po_df_no AS po_no, i.vendor_sno, k.company_name AS vendor_name, i.invoice_date, i.due_date, iad.bucket_type,
        iad.allocated_amount, iad.hold_amount, iad.release_amount AS net_payable,
        paid.paidSoFar AS paid_amount, paid.reservedSoFar AS reserved_amount,
        iad.release_amount - paid.paidSoFar - paid.reservedSoFar AS outstanding,
        i.invoice_amount, bp.taxable_eff AS taxable_value, i.tds_section_code, i.tds_rate_override, i.itc_status, i.payment_hold_override,
        CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 THEN 1 ELSE 0 END AS BIT) AS gst_supplier,
        CAST(CASE WHEN i.gst_journal_sno IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS gst_booked,
        CASE WHEN iad.bucket_type = 'SERVICE' THEN 'NA'
             WHEN EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.po_basic_sno = i.po_basic_sno AND g.is_active = 'Y' AND g.status IN ('Approved', 'Received')) THEN 'Done'
             WHEN EXISTS (SELECT 1 FROM dbo.grn_basic_info g WHERE g.po_basic_sno = i.po_basic_sno AND g.is_active = 'Y' AND g.status = 'Pending Approval') THEN 'Pending approval'
             ELSE 'No GRN' END AS grn_state,
        CAST(CASE WHEN LEN(ISNULL(LTRIM(RTRIM(k.gst_no)), '')) >= 15 AND ISNULL(i.itc_status, '') NOT IN ('Eligible', 'Ineligible')
                       AND ISNULL(i.payment_hold_override, 'N') <> 'Y' THEN 1 ELSE 0 END AS BIT) AS on_hold_2b,
        CASE WHEN bp.on_hold_2b = 1 AND bp.taxable_known = 1 THEN bp.gst_part ELSE 0 END AS gst_held,
        bp.gst_part AS gst_amount, bp.taxable_known, bp.payable_now
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN 0 ELSE pad.amount END), 0) AS paidSoFar,
               ISNULL(SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN pad.amount ELSE 0 END), 0) AS reservedSoFar
        FROM dbo.payment_allocation_details pad
        JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno
        WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    CROSS APPLY dbo.fn_nt_BillPayable(iad.invoice_alloc_sno) bp
    WHERE iad.is_active = 'Y' AND iad.release_amount > paid.paidSoFar + paid.reservedSoFar + 0.01
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY i.invoice_date, iad.invoice_alloc_sno;
END
GO

-- ── invoice ledger: file, taxable value, 2B status, GRN taxable ──
-- Invoice-wise ledger: same as sql/63, with settled vs reserved. payment_status = Paid | In payment (a saved / approved
-- payment holds it) | Part paid | Unpaid | Not allocated.
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPoInvoiceLedger
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    BEGIN TRY
        EXEC dbo.sp_nt_SyncGrnInvoicesToPayables;   -- sql/75
    END TRY
    BEGIN CATCH
    END CATCH

    SELECT i.invoice_sno, i.invoice_no, i.vendor_invoice_no AS supplier_invoice_no, i.po_basic_sno, p.po_df_no AS po_no,
           i.vendor_sno, i.invoice_date, i.due_date, i.invoice_amount, i.match_status, i.verification_status,
           i.invoice_file_url,
           (SELECT MAX(bp.taxable_eff) FROM dbo.invoice_allocation_details a3 CROSS APPLY dbo.fn_nt_BillPayable(a3.invoice_alloc_sno) bp
             WHERE a3.invoice_sno = i.invoice_sno AND a3.is_active = 'Y') AS taxable_value, i.itc_status, i.payment_hold_override,
           ISNULL(a.release_total, 0) AS release_total,
           ISNULL(a.paid_total, 0)    AS paid_total,
           ISNULL(a.reserved_total, 0) AS reserved_total,
           ISNULL(a.release_total, 0) - ISNULL(a.paid_total, 0) - ISNULL(a.reserved_total, 0) AS outstanding,
           CASE WHEN a.alloc_count IS NULL THEN 'Not allocated'
                WHEN a.release_total - a.paid_total <= 0.01 AND a.paid_total > 0 THEN 'Paid'
                WHEN a.reserved_total > 0 THEN 'In payment'
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
               SUM(ISNULL(pd.reserved, 0)) AS reserved_total,
               (SELECT STRING_AGG(x.payment_no, ', ') FROM (
                    SELECT DISTINCT pi.payment_no
                    FROM dbo.invoice_allocation_details iad2
                    JOIN dbo.payment_allocation_details pad ON pad.invoice_alloc_sno = iad2.invoice_alloc_sno
                    JOIN dbo.payment_info pi ON pi.payment_sno = pad.payment_sno
                    WHERE iad2.invoice_sno = i.invoice_sno AND iad2.is_active = 'Y') x) AS payment_nos
        FROM dbo.invoice_allocation_details iad
        OUTER APPLY (
            SELECT SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN 0 ELSE pad.amount END) AS paid,
                   SUM(CASE WHEN pyi.status IN ('Pending Approval', 'Approved') THEN pad.amount ELSE 0 END) AS reserved
            FROM dbo.payment_allocation_details pad
            JOIN dbo.payment_info pyi ON pyi.payment_sno = pad.payment_sno
            WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
        ) pd
        WHERE iad.invoice_sno = i.invoice_sno AND iad.is_active = 'Y'
    ) a
    WHERE i.is_active = 'Y' AND i.po_basic_sno IS NOT NULL
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY i.po_basic_sno, i.invoice_date, i.invoice_sno;

    SELECT g.grn_basic_sno, g.grn_no, g.po_basic_sno, p.po_df_no AS po_no, g.vendor_sno, g.status, g.received_date,
           NULLIF(LTRIM(RTRIM(g.doc_ref_no)), '') AS invoice_no, g.invoice_date, g.invoice_amount, g.invoice_doc_url, g.invoice_taxable_value, g.payable_invoice_sno,
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
