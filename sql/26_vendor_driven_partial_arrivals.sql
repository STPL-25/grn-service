-- ============================================================
-- Multiple gate entries for partially delivered purchase orders
-- Database: Non_Trade (MSSQL)
--
-- A gate entry belongs to one physical arrival, not to the lifetime of a PO.
-- This replaces the old one-gate-entry-per-PO filter with a pending-quantity
-- filter, so the same approved PO remains available for the next truck/day
-- until every item has been fully GRN-received.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPOsPendingGateEntry
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @po_no NVARCHAR(50) = NULL;
    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
        SET @po_no = JSON_VALUE(@jsonInput, '$.po_no');

    SELECT
        p.po_basic_sno,
        p.po_df_no AS po_no,
        p.pr_basic_sno,
        pr.pr_no,
        pr.request_mode,
        p.vendor_sno,
        k.company_name AS vendor_name,
        c.com_name,
        CONVERT(VARCHAR(10), p.po_date, 120) AS po_date,
        CONVERT(VARCHAR(10), p.required_date, 120) AS required_date,
        p.delivery_address,
        p.terms_conditions,
        p.purpose,
        p.com_sno,
        p.div_sno,
        dv.div_name,
        p.brn_sno,
        br.brn_name,
        p.dept_sno,
        dp.dept_name,
        p.status,
        (
            SELECT
                i.po_item_sno,
                i.prod_sno,
                ISNULL(i.prod_name, product.prod_name) AS prod_name,
                i.specification,
                i.qty AS ordered_qty,
                ISNULL(uom.uom_name, i.unit_name) AS unit_name,
                i.agreed_unit_price AS unit_price,
                i.net_cost AS total_amount,
                ISNULL(receipts.received_qty, 0) AS received_qty,
                i.qty - ISNULL(receipts.received_qty, 0) AS pending_qty
            FROM dbo.po_item_details i
            LEFT JOIN dbo.product_master product ON product.prod_sno = i.prod_sno
            LEFT JOIN dbo.uom_master uom ON uom.uom_sno = i.unit
            OUTER APPLY (
                SELECT SUM(grn.received_qty) AS received_qty
                FROM dbo.grn_item_details grn
                WHERE grn.po_item_sno = i.po_item_sno
                  AND grn.is_active = 'Y'
            ) receipts
            WHERE i.po_basic_sno = p.po_basic_sno
              AND i.is_active IN ('1', 'Y')
            FOR JSON PATH
        ) AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.pr_basic_info pr ON pr.pr_basic_sno = p.pr_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = p.vendor_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = p.div_sno
    LEFT JOIN dbo.branch_master br ON br.brn_sno = p.brn_sno
    LEFT JOIN dbo.dept_master dp ON dp.dept_sno = p.dept_sno
    WHERE p.is_active = 'Y'
      AND p.status = 'A'
      AND (@po_no IS NULL OR p.po_df_no = @po_no)
      AND EXISTS (
          SELECT 1
          FROM dbo.po_item_details i
          OUTER APPLY (
              SELECT SUM(grn.received_qty) AS received_qty
              FROM dbo.grn_item_details grn
              WHERE grn.po_item_sno = i.po_item_sno
                AND grn.is_active = 'Y'
          ) receipts
          WHERE i.po_basic_sno = p.po_basic_sno
            AND i.is_active IN ('1', 'Y')
            AND i.qty > ISNULL(receipts.received_qty, 0)
      )
    ORDER BY p.po_basic_sno DESC;
END;
GO
