-- ============================================================
-- sp_nt_GetPoItemsForInvoiceAllocation — PO line picker for the Invoice
-- Allocation screen
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : new grn-service/src/invoice InvoiceAllocationForm.tsx (via a new
--            GET /api/invoice/getPoItemsForAllocation/:po_basic_sno)
--
-- Why this is needed
-- ------------------
-- sp_nt_AllocateInvoice (13_invoice.sql) takes a flat list of
-- {po_item_sno, allocated_amount} and needs the caller to already know which
-- po_item_sno values exist on the invoice's PO and what they're worth. No
-- existing SP returns that for an arbitrary PO regardless of GRN/Service
-- Entry state — the closest analog, sp_nt_GetPendingPOs
-- (grn-service/sql/07_grn_procs_v2.sql), filters to gate-entry-linked POs
-- still awaiting GRN, which would wrongly exclude fully-received or
-- service-only POs that still need invoicing.
--
-- Also returns each line's already-allocated total across any other
-- non-superseded invoice (invoice_allocation_details rows are wiped and
-- re-inserted per invoice on re-allocation by sp_nt_AllocateInvoice, so this
-- is a live "how much of this line's value is already claimed by some other
-- invoice" figure) so the allocation form can flag over-allocation before
-- the user submits, without needing a second round trip.
--
-- Table note: joins dbo.grn_item_details (NOT nt_grn_item_details) for the
-- same reason documented in backend-stpl/sql/19_pr_line_routing_status.sql —
-- nt_grn_item_details is a stale, abandoned table frozen at po_basic_sno<=37;
-- sp_nt_CreateGRN writes into the no-prefix grn_item_details today.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_GetPoItemsForInvoiceAllocation', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetPoItemsForInvoiceAllocation;
GO

CREATE PROCEDURE dbo.sp_nt_GetPoItemsForInvoiceAllocation
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_basic_sno INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.po_basic_sno') AS INT);

    IF @po_basic_sno IS NULL
        THROW 54020, 'po_basic_sno is required.', 1;

    SELECT
        poi.po_item_sno,
        ISNULL(poi.po_section, 'MATERIAL')          AS po_section,
        poi.prod_sno,
        ISNULL(poi.prod_name, pm.prod_name)         AS prod_name,
        poi.service_sno,
        sm.service_name,
        poi.qty,
        poi.unit_name,
        poi.net_cost                                AS line_value,
        ISNULL(alloc.already_allocated, 0)          AS already_allocated,
        (
            SELECT ISNULL(SUM(g.received_qty - ISNULL(g.rejected_qty, 0)), 0)
            FROM dbo.grn_item_details g
            WHERE g.po_item_sno = poi.po_item_sno AND g.is_active = 'Y'
        ) AS received_qty
    FROM dbo.po_item_details poi
    LEFT JOIN dbo.product_master pm ON pm.prod_sno = poi.prod_sno
    LEFT JOIN dbo.service_master sm ON sm.service_sno = poi.service_sno
    OUTER APPLY (
        SELECT SUM(iad.allocated_amount) AS already_allocated
        FROM dbo.invoice_allocation_details iad
        WHERE iad.po_item_sno = poi.po_item_sno AND iad.is_active = 'Y'
    ) alloc
    WHERE poi.po_basic_sno = @po_basic_sno
      AND poi.is_active IN ('1', 'Y')  -- po_item_details.is_active observed as '1' in production
    ORDER BY poi.po_item_sno;
END;
GO

-- ============================================================
-- After running, confirm:
--   EXEC dbo.sp_nt_GetPoItemsForInvoiceAllocation @jsonInput = N'{"po_basic_sno":<a real po_basic_sno>}';
-- ============================================================
