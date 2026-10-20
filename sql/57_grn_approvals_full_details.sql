-- ============================================================
-- 57_grn_approvals_full_details.sql   (Non_trade_Dev)
-- sp_nt_GetGRNApprovals now returns the full GRN for the approval screen: PO no, supplier, gate entry,
-- uploaded invoice (no / date / amount / document), challan, vehicle, remarks, org names and the lines
-- (items JSON incl. shortage / excess). Same inputs and result sets as sql/40. Re-runnable.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNApprovals
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @appr VARCHAR(30) = NULLIF(JSON_VALUE(@jsonInput, '$.approver_ecno'), ''),
            @grn INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.grn_basic_sno') AS INT);

    SELECT b.grn_basic_sno,
           'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
           b.po_basic_sno, p.po_df_no AS po_no, b.vendor_sno, k.company_name AS vendor_name,
           CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
           b.status, b.current_approver_id, b.created_by, CONVERT(VARCHAR(30), b.created_date, 120) AS created_at,
           b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
           ge.gate_entry_no, b.doc_ref_no, CONVERT(VARCHAR(10), b.invoice_date, 120) AS invoice_date,
           b.invoice_amount, b.invoice_doc_url, b.vehicle_no, b.challan_no, b.remarks,
           (SELECT COUNT(*) FROM dbo.grn_item_details gi WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y') AS item_count,
           (SELECT ISNULL(SUM(gi.received_qty), 0) FROM dbo.grn_item_details gi WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y') AS total_received_qty,
           (SELECT gi.grn_item_sno, gi.prod_name, gi.specification, gi.po_qty AS ordered_qty, gi.received_qty, gi.rejected_qty,
                   gi.unit_name, gi.condition, gi.hsn_code, gi.remarks, gi.warehouse_location_name,
                   gi.invoice_qty, gi.invoice_uom, gi.shortage_qty, gi.excess_qty, gi.hold_qty, gi.excess_status
            FROM dbo.grn_item_details gi WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y'
            FOR JSON PATH) AS items
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.nt_gate_entry ge ON ge.gate_entry_sno = b.gate_entry_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.is_active = 'Y'
      AND ((@grn IS NOT NULL AND b.grn_basic_sno = @grn)
        OR (@grn IS NULL AND b.status = 'Pending Approval' AND (@appr IS NULL OR b.current_approver_id = @appr)))
    ORDER BY b.grn_basic_sno DESC;

    SELECT h.grn_basic_sno, h.action_type, h.status_by, h.comment, CONVERT(VARCHAR(30), h.created_at, 120) AS created_at
    FROM dbo.grn_approval_history h
    WHERE (@grn IS NOT NULL AND h.grn_basic_sno = @grn)
    ORDER BY h.history_sno;
END
GO
