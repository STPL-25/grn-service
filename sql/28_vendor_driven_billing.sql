-- ============================================================
-- Vendor-Driven billing: list billable child POs + payable-bills qty/filters
-- Database: Non_trade_Dev (MSSQL)
--
-- Closes the "vendor bill page — see requested vs GRN qty per child PO,
-- select several spanning multiple days, consolidate into one bill, then
-- pay later" part of the Vendor-Driven Purchase Requisition feature (see
-- backend-stpl/sql/61_vendor_driven_purchase_requisition_v2.sql for the
-- PR->child-PO side). Billing/payment is deliberately NOT automatic on
-- each GRN — a separate, later, explicit action, per direct user
-- confirmation this session.
-- ============================================================

-- ============================================================
-- sp_nt_GetVendorDrivenBillableChildPOs — child POs (VPO- prefixed, i.e.
-- pr_basic_info.request_mode='VENDOR_DRIVEN') for one vendor that have at
-- least one GRN receipt and no invoice yet. Per-line requested vs received
-- qty uses the exact same sub-select shape as
-- sp_nt_GetPoItemsForInvoiceAllocation (17_invoice_po_items_for_allocation.sql)
-- so the two stay consistent. vendor_invoice_no/invoice_date come from the
-- MOST RECENT gate entry against this PO (a PO can have several across
-- multiple delivery days) — same "seller's invoice number already captured
-- at Gate Entry" precedent as the Debit Note feature.
-- @jsonInput: { vendor_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetVendorDrivenBillableChildPOs', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetVendorDrivenBillableChildPOs;
GO
CREATE PROCEDURE dbo.sp_nt_GetVendorDrivenBillableChildPOs
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

    IF @vendor_sno IS NULL
        THROW 61001, 'vendor_sno is required.', 1;

    SELECT
        po.po_basic_sno,
        po.po_df_no,
        CONVERT(VARCHAR(10), po.po_date, 120) AS po_date,
        po.vendor_sno,
        k.company_name AS vendor_name,
        po.com_sno,
        po.div_sno,
        po.brn_sno,
        po.dept_sno,
        pr.pr_basic_sno,
        pr.pr_no,
        pr.payment_cycle_days,
        ge.vendor_invoice_no,
        ge.vendor_invoice_date,
        (
            SELECT
                poi.po_item_sno,
                poi.prod_sno,
                ISNULL(poi.prod_name, pm.prod_name) AS prod_name,
                poi.qty AS requested_qty,
                poi.unit_name,
                poi.net_cost AS line_value,
                (
                    SELECT ISNULL(SUM(g.received_qty - ISNULL(g.rejected_qty, 0)), 0)
                    FROM dbo.grn_item_details g
                    WHERE g.po_item_sno = poi.po_item_sno AND g.is_active = 'Y'
                ) AS received_qty
            FROM dbo.po_item_details poi
            LEFT JOIN dbo.product_master pm ON pm.prod_sno = poi.prod_sno
            WHERE poi.po_basic_sno = po.po_basic_sno
              AND poi.is_active IN ('1', 'Y')
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info po
    JOIN dbo.pr_basic_info pr ON pr.pr_basic_sno = po.pr_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = po.vendor_sno
    OUTER APPLY (
        SELECT TOP 1 g.vendor_invoice_no, g.vendor_invoice_date
        FROM (
            SELECT ge.invoice_no AS vendor_invoice_no, ge.invoice_date AS vendor_invoice_date, ge.received_date
            FROM dbo.grn_basic_info gb
            JOIN dbo.nt_gate_entry ge ON ge.gate_entry_sno = gb.gate_entry_sno
            WHERE gb.po_basic_sno = po.po_basic_sno AND gb.is_active = 'Y'
        ) g
        ORDER BY g.received_date DESC
    ) ge
    WHERE pr.request_mode = 'VENDOR_DRIVEN'
      AND po.vendor_sno = @vendor_sno
      AND po.is_active = 'Y'
      AND po.status = 'A'
      AND EXISTS (
          SELECT 1 FROM dbo.grn_basic_info gb
          WHERE gb.po_basic_sno = po.po_basic_sno AND gb.is_active = 'Y'
      )
      AND NOT EXISTS (
          SELECT 1 FROM dbo.invoice_info inv
          WHERE inv.po_basic_sno = po.po_basic_sno AND inv.is_active = 'Y'
      )
    ORDER BY po.po_basic_sno;
END;
GO

-- ============================================================
-- sp_nt_GetPayableBills v3 — adds real @jsonInput filtering (vendor_sno,
-- previously declared but unused) and a per-bill requested/received qty
-- rollup (aggregated across the PO's lines — the payment screen shows one
-- qty summary per bill, not per line) so the Payment page can show
-- "requested X, received Y" the way the Vendor Bill page does.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPayableBills
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @vendor_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.vendor_sno') AS INT);

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
        iad.release_amount - ISNULL(paid.paidSoFar, 0) AS outstanding,
        qty.requested_qty,
        qty.received_qty
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.pr_basic_info pr ON pr.pr_basic_sno = p.pr_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = i.vendor_sno
    OUTER APPLY (
        SELECT MAX(g.received_date) AS last_received_date
        FROM dbo.grn_basic_info g WHERE g.po_basic_sno = p.po_basic_sno AND g.is_active = 'Y'
    ) arrivals
    OUTER APPLY (
        SELECT ISNULL(SUM(pad.amount), 0) AS paidSoFar
        FROM dbo.payment_allocation_details pad WHERE pad.invoice_alloc_sno = iad.invoice_alloc_sno
    ) paid
    OUTER APPLY (
        SELECT
            SUM(poi.qty) AS requested_qty,
            SUM(rq.line_received_qty) AS received_qty
        FROM dbo.po_item_details poi
        CROSS APPLY (
            SELECT ISNULL(SUM(g.received_qty - ISNULL(g.rejected_qty, 0)), 0) AS line_received_qty
            FROM dbo.grn_item_details g
            WHERE g.po_item_sno = poi.po_item_sno AND g.is_active = 'Y'
        ) rq
        WHERE poi.po_basic_sno = p.po_basic_sno AND poi.is_active IN ('1', 'Y')
    ) qty
    WHERE iad.is_active = 'Y'
      AND iad.release_amount > ISNULL(paid.paidSoFar, 0) + 0.01
      AND (@vendor_sno IS NULL OR i.vendor_sno = @vendor_sno)
    ORDER BY arrivals.last_received_date, iad.invoice_alloc_sno;
END;
GO
