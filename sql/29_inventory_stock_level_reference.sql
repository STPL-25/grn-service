-- =============================================================================
-- 29_inventory_stock_level_reference.sql
--
-- Surfaces backend-stpl's new Product Stock Level master (a per-product,
-- per-scope Min Qty / Max Qty / Reorder Level policy — see
-- backend-stpl/sql/65_product_stock_level_master.sql for the full design
-- rationale) on the Inventory Stock page.
--
-- Per product decision (2026-09-08 AskUserQuestion): this does NOT change the
-- stored nt_inventory_items.min_stock/max_stock/reorder_qty columns, and does
-- NOT alter sp_nt_AdjustStock. It only adds three new, purely additive
-- columns to sp_nt_GetInventoryItems' result set. A product with no master
-- entry (a "rare"/untracked product) simply gets NULLs here — that is the
-- normal, expected case, not an error.
--
-- UPDATE (2026-09-08, later same day): the frontend's getStockStatus
-- (nt-frontend-stpl/src/Application/Inventory/Inventory/helpers.ts) now DOES
-- read these master_* columns to color the Status badge — master_min_qty/
-- master_max_qty/master_reorder_level take priority over the item's own
-- min_stock/max_stock/reorder_qty when a master policy is configured, falling
-- back to the item's own fields otherwise. This SP itself is unchanged by
-- that — it already returned everything needed; only the frontend's
-- interpretation of "reference only" was reversed.
--
-- product_stock_level_master lives in backend-stpl's migrations but is a
-- plain table in the SAME physical database (both services connect to the
-- same DATABASE=Non_trade_Dev / Non_Trade instance — confirmed via each
-- service's own .env), so a direct JOIN here needs no cross-service call.
--
-- Match logic (mirrors backend-stpl's sp_nt_GetApplicableStockLevel):
--   - LOCATION-scoped row wins if the item's own location code resolves to a
--     warehouse_location_master row that a LOCATION-scoped entry targets.
--   - Otherwise the most specific ORG-scoped row wins: branch-level match >
--     division-level match > company-level-only match (NULL div/brn on the
--     master row means "applies to every division/branch under it").
-- =============================================================================

CREATE OR ALTER PROCEDURE dbo.sp_nt_GetInventoryItems
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @category  VARCHAR(50)  = NULL;
    DECLARE @warehouse VARCHAR(100) = NULL;
    DECLARE @status    VARCHAR(20)  = NULL;
    DECLARE @com_sno   INT          = NULL;
    DECLARE @div_sno   INT          = NULL;
    DECLARE @brn_sno   INT          = NULL;
    DECLARE @dept_sno  INT          = NULL;
    DECLARE @exclude_non_regular BIT = 0;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @category  = JSON_VALUE(@jsonInput, '$.category');
        SET @warehouse = JSON_VALUE(@jsonInput, '$.warehouse');
        SET @status    = JSON_VALUE(@jsonInput, '$.status');
        SET @com_sno   = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno   = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno   = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno  = JSON_VALUE(@jsonInput, '$.dept_sno');
        SET @exclude_non_regular = ISNULL(TRY_CAST(JSON_VALUE(@jsonInput, '$.exclude_non_regular') AS BIT), 0);
    END

    SELECT
        i.item_sno, i.item_code, i.item_name, i.category, i.sub_category, i.uom,
        i.current_stock, i.min_stock, i.max_stock, i.reorder_qty, i.warehouse,
        i.location AS location_code,
        wl.location_name,
        i.cost_price, i.selling_price, i.status, i.hsn_code, i.description, i.prod_sno,
        i.com_sno, c.com_name,
        i.div_sno, dv.div_name,
        i.brn_sno, br.brn_name,
        i.dept_sno, dp.dept_name,
        sl.min_qty       AS master_min_qty,
        sl.max_qty       AS master_max_qty,
        sl.reorder_level AS master_reorder_level,
        sl.scope_type    AS master_scope_type,
        CONVERT(VARCHAR(30), i.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), i.updated_at, 120) AS updated_at
    FROM dbo.nt_inventory_items i
    LEFT JOIN dbo.company_master c   ON c.com_sno  = i.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = i.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = i.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = i.dept_sno
    LEFT JOIN dbo.product_master pm      ON pm.prod_sno   = i.prod_sno
    LEFT JOIN dbo.subcategory_master scm ON scm.subcat_sno = pm.subcat_sno
    LEFT JOIN dbo.warehouse_location_master wl ON wl.location_code = i.location
    OUTER APPLY (
        SELECT TOP 1
            p.min_qty, p.max_qty, p.reorder_level, p.scope_type,
            CASE
                WHEN p.scope_type = 'LOCATION' THEN 100
                WHEN p.brn_sno IS NOT NULL THEN 3
                WHEN p.div_sno IS NOT NULL THEN 2
                ELSE 1
            END AS specificity
        FROM dbo.product_stock_level_master p
        WHERE i.prod_sno IS NOT NULL
          AND p.prod_sno = i.prod_sno
          AND p.is_active = 'Y'
          AND (
                (p.scope_type = 'LOCATION' AND wl.location_sno IS NOT NULL AND p.location_sno = wl.location_sno)
             OR (p.scope_type = 'ORG' AND p.com_sno = i.com_sno
                 AND (p.div_sno IS NULL OR p.div_sno = i.div_sno)
                 AND (p.brn_sno IS NULL OR p.brn_sno = i.brn_sno))
              )
        ORDER BY specificity DESC
    ) sl
    WHERE (@category  IS NULL OR i.category  = @category)
      AND (@warehouse IS NULL OR i.warehouse = @warehouse)
      AND (@status    IS NULL OR i.status    = @status)
      AND (@com_sno   IS NULL OR i.com_sno   = @com_sno)
      AND (@div_sno   IS NULL OR i.div_sno   = @div_sno)
      AND (@brn_sno   IS NULL OR i.brn_sno   = @brn_sno)
      AND (@dept_sno  IS NULL OR i.dept_sno  = @dept_sno)
      AND (@exclude_non_regular = 0 OR ISNULL(scm.subcat_stock_type, 'Regular') <> 'Non-Regular')
    ORDER BY i.item_sno DESC;
END;
GO
