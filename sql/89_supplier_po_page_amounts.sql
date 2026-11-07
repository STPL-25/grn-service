-- sql/89: the supplier portal's "Purchase Orders" page showed wrong amounts, blank item names, and could list unapproved POs.
--
-- 1) WRONG AMOUNTS. sp_nt_GetPODetailForSupplier returned po_item_details.net_cost as the line "Amount" (and the page summed it into
--    "Order value" / "Grand total"). That column is not one thing: on regular PO lines it holds the GST AMOUNT (500 x Rs 700 at 12% GST
--    -> net_cost 42,000, total_cost 392,000), on Service PO lines it holds the total incl. GST (35,000 + 12% -> net_cost 39,200,
--    total_cost 35,000). On Dev that made 59 of 159 active lines show the tax instead of the amount. total_cost is not reliable either
--    (15 lines). So the amounts are now COMPUTED from the line's own components, the same for every PO:
--        taxable = qty x unit price x (1 - discount%)      gst = taxable x GST%      total = taxable + gst     (each rounded to paise)
--    On Dev this equals a stored incl-GST column on all 159 lines. The item keys the page already reads (ordered_qty, unit_price,
--    total_amount, ...) keep their names - total_amount is now the line total incl. GST - and discount_pct / tax_pct / taxable_amount /
--    tax_amount are added so the page can show how the amount is made up.
--
-- 2) BLANK NAMES. po_item_details.prod_name / unit_name are NULL on 60 of 109 regular lines (the PO was saved with the product id only).
--    The detail now falls back to product_master / uom_master, exactly as the GRN and gate-entry procedures already do.
--
-- 3) UNAPPROVED POs. The list showed every active PO of the supplier whatever its status, so a PO still waiting for approval
--    (status 'P', e.g. a Service PO in workflow) was shown as "issued" and could be accepted. The list, the detail and Accept now
--    require status 'A' (approved). The list also accepts is_active 'Y' or '1' like the detail already did.
--
-- Re-runnable.  Rollback: sql/backups/supplier_po_page_2026-11-05_ROLLBACK.sql (the three procedures exactly as they were).

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPOsForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');

    SELECT
        p.po_basic_sno,
        p.po_df_no                              AS po_no,
        CONVERT(VARCHAR(10), p.po_date, 120)     AS po_date,
        CONVERT(VARCHAR(10), p.required_date,120) AS required_date,
        p.delivery_address,
        p.status,
        p.supplier_ack_status,
        CONVERT(VARCHAR(30), p.supplier_ack_date, 120) AS supplier_ack_date,
        c.com_name                              AS com_name,
        (
            SELECT COUNT(*)
            FROM dbo.nt_dispatch_slip d
            WHERE d.po_basic_sno = p.po_basic_sno
        )                                        AS dispatch_count
    FROM dbo.po_request_info p
    LEFT JOIN dbo.company_master c ON c.com_sno = p.com_sno
    WHERE p.is_active IN ('Y','1')
      AND p.status = 'A'                        -- approved POs only: a PO still in approval is not "issued" to the supplier yet
      AND p.vendor_sno = @kyc_basic_info_sno
    ORDER BY p.po_basic_sno DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetPODetailForSupplier
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @po_basic_sno       INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    SELECT
        p.po_basic_sno,
        p.po_df_no                              AS po_no,
        CONVERT(VARCHAR(10), p.po_date, 120)     AS po_date,
        CONVERT(VARCHAR(10), p.required_date,120) AS required_date,
        COALESCE(NULLIF(LTRIM(RTRIM(p.delivery_address)), ''),
                 NULLIF(LTRIM(RTRIM(addr.branch_address)), ''),
                 NULLIF(LTRIM(RTRIM(addr.company_address)), '')) AS delivery_address,
        p.terms_conditions,
        p.purpose,
        p.status,
        p.supplier_ack_status,
        CONVERT(VARCHAR(30), p.supplier_ack_date, 120) AS supplier_ack_date,
        p.po_pdf_url,
        c.com_name                              AS com_name,
        k.company_name                          AS vendor_name,
        (
            SELECT
                i.po_item_sno,
                i.prod_sno,
                COALESCE(NULLIF(LTRIM(RTRIM(i.prod_name)), ''), pm.prod_name) AS prod_name,
                i.specification,
                i.qty                                                          AS ordered_qty,
                COALESCE(NULLIF(LTRIM(RTRIM(i.unit_name)), ''), um.uom_name)   AS unit_name,
                i.agreed_unit_price                                            AS unit_price,
                ISNULL(i.discount_pct, 0)                                      AS discount_pct,
                ISNULL(i.tax_pct, 0)                                           AS tax_pct,
                amt.taxable_amount,
                amt.tax_amount,
                amt.taxable_amount + amt.tax_amount                            AS total_amount
            FROM dbo.po_item_details i
            LEFT JOIN dbo.product_master pm ON pm.prod_sno = i.prod_sno
            LEFT JOIN dbo.uom_master     um ON um.uom_sno  = i.unit
            CROSS APPLY (
                SELECT CAST(ROUND(ISNULL(i.qty, 0) * ISNULL(i.agreed_unit_price, 0) * (1 - ISNULL(i.discount_pct, 0) / 100.0), 2) AS DECIMAL(18,2)) AS taxable_amount
            ) b
            CROSS APPLY (
                SELECT b.taxable_amount,
                       CAST(ROUND(b.taxable_amount * ISNULL(i.tax_pct, 0) / 100.0, 2) AS DECIMAL(18,2)) AS tax_amount
            ) amt
            WHERE i.po_basic_sno = p.po_basic_sno
              AND i.is_active IN ('Y','1')
            ORDER BY i.po_item_sno
            FOR JSON PATH
        )                                        AS items
    FROM dbo.po_request_info p
    LEFT JOIN dbo.company_master c   ON c.com_sno  = p.com_sno
    LEFT JOIN dbo.kyc_basic_info k   ON k.kyc_basic_info_sno = p.vendor_sno
    OUTER APPLY (
        SELECT TOP 1 v.branch_address, v.company_address
        FROM dbo.vw_ActiveDeptRecords v
        WHERE v.brn_sno = p.brn_sno AND v.dept_sno = p.dept_sno
    ) addr
    WHERE p.is_active IN ('Y','1')
      AND p.status = 'A'
      AND p.po_basic_sno = @po_basic_sno
      AND p.vendor_sno = @kyc_basic_info_sno;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_nt_AcceptPO
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @kyc_basic_info_sno INT = JSON_VALUE(@jsonInput, '$.kyc_basic_info_sno');
    DECLARE @po_basic_sno       INT = JSON_VALUE(@jsonInput, '$.po_basic_sno');

    -- Only the supplier's own, approved PO can be accepted (a PO still in approval is not theirs to accept yet).
    IF NOT EXISTS (
        SELECT 1 FROM dbo.po_request_info
        WHERE po_basic_sno = @po_basic_sno AND vendor_sno = @kyc_basic_info_sno AND is_active IN ('Y','1') AND status = 'A'
    )
    BEGIN
        RAISERROR('PO not found for this supplier.', 16, 1);
        RETURN;
    END

    UPDATE dbo.po_request_info
    SET supplier_ack_status = 'Accepted',
        supplier_ack_date = GETDATE()
    WHERE po_basic_sno = @po_basic_sno;

    INSERT INTO dbo.po_history_data (po_basic_sno, action_type, status_by, comment, is_active)
    VALUES (@po_basic_sno, 'SUPPLIER_ACK', CAST(@kyc_basic_info_sno AS VARCHAR(50)), 'PO accepted by supplier', 'Y');

    SELECT po_basic_sno, supplier_ack_status,
           CONVERT(VARCHAR(30), supplier_ack_date, 120) AS supplier_ack_date
    FROM dbo.po_request_info
    WHERE po_basic_sno = @po_basic_sno;
END;
GO
