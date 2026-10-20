-- ============================================================
-- 59_asset_tags_exclude_perishable.sql   (Non_trade_Dev)
-- GRN Asset Tags: only product lines (prod_sno set) whose subcategory stock type is
-- Regular or Non-Regular get tags. Perishable lines are skipped everywhere
-- (unit count on the GRN list, tag generation, tag listing).
-- Re-runnable.
-- ============================================================

-- approved GRNs with how many taggable units / tags each has
CREATE OR ALTER PROCEDURE dbo.sp_nt_GetGRNsForAssetTags
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT b.grn_basic_sno,
           'GRN-' + CAST(YEAR(b.created_date) AS VARCHAR(4)) + '-' + RIGHT('000000' + CAST(b.grn_no AS VARCHAR(6)), 6) AS grn_no,
           b.po_basic_sno, p.po_df_no AS po_no, k.company_name AS vendor_name,
           CONVERT(VARCHAR(10), b.received_date, 120) AS received_date,
           CONVERT(VARCHAR(30), b.approved_at, 120) AS approved_at,
           b.com_sno, b.div_sno, b.brn_sno, b.dept_sno,
           (SELECT COUNT(*) FROM dbo.grn_item_details gi
             WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y'
               AND gi.prod_sno IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dbo.product_master pm
                                 JOIN dbo.subcategory_master sc ON sc.subcat_sno = pm.subcat_sno
                                WHERE pm.prod_sno = gi.prod_sno AND sc.subcat_stock_type = 'Perishable')) AS item_count,
           (SELECT ISNULL(SUM(CASE WHEN gi.received_qty - ISNULL(gi.rejected_qty, 0) >= 1
                                   THEN CAST(FLOOR(gi.received_qty - ISNULL(gi.rejected_qty, 0)) AS INT) ELSE 0 END), 0)
              FROM dbo.grn_item_details gi
             WHERE gi.grn_basic_sno = b.grn_basic_sno AND gi.is_active = 'Y'
               AND gi.prod_sno IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM dbo.product_master pm
                                 JOIN dbo.subcategory_master sc ON sc.subcat_sno = pm.subcat_sno
                                WHERE pm.prod_sno = gi.prod_sno AND sc.subcat_stock_type = 'Perishable')) AS unit_count,
           (SELECT COUNT(*) FROM dbo.grn_asset_tags t WHERE t.grn_basic_sno = b.grn_basic_sno) AS tag_count
    FROM dbo.grn_basic_info b
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = b.po_basic_sno
    LEFT JOIN dbo.kyc_basic_info k ON k.kyc_basic_info_sno = b.vendor_sno
    WHERE b.is_active = 'Y' AND b.status IN ('Approved', 'Received')
    ORDER BY b.grn_basic_sno DESC;
END
GO

-- creates the missing tags of one GRN (max 1000 units per line); Perishable / non-product lines skipped
CREATE OR ALTER PROCEDURE dbo.sp_nt_GenerateGRNAssetTags
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @grn INT = TRY_CAST(JSON_VALUE(@jsonInput, '$.grn_basic_sno') AS INT),
            @by VARCHAR(30) = JSON_VALUE(@jsonInput, '$.created_by');
    IF @grn IS NULL THROW 53301, 'grn_basic_sno is required.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.grn_basic_info WHERE grn_basic_sno = @grn AND is_active = 'Y' AND status IN ('Approved', 'Received'))
        THROW 53302, 'Asset tags can be generated only for an approved GRN.', 1;

    ;WITH n AS (SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS u FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT INTO dbo.grn_asset_tags (tag_code, grn_basic_sno, grn_item_sno, unit_no, prod_sno, prod_name, created_by)
    SELECT 'AST-' + RIGHT('00000' + CAST(gi.grn_item_sno AS VARCHAR(10)), 5) + '-' + RIGHT('000' + CAST(n.u AS VARCHAR(4)), 3),
           gi.grn_basic_sno, gi.grn_item_sno, n.u, gi.prod_sno, gi.prod_name, @by
    FROM dbo.grn_item_details gi
    JOIN n ON n.u <= FLOOR(gi.received_qty - ISNULL(gi.rejected_qty, 0))
    WHERE gi.grn_basic_sno = @grn AND gi.is_active = 'Y'
      AND gi.prod_sno IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.product_master pm
                        JOIN dbo.subcategory_master sc ON sc.subcat_sno = pm.subcat_sno
                       WHERE pm.prod_sno = gi.prod_sno AND sc.subcat_stock_type = 'Perishable')
      AND NOT EXISTS (SELECT 1 FROM dbo.grn_asset_tags t WHERE t.grn_item_sno = gi.grn_item_sno AND t.unit_no = n.u);

    EXEC dbo.sp_nt_GetGRNAssetTags @jsonInput = @jsonInput;
END
GO
