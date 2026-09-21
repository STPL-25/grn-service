-- ============================================================
-- Fix: nt_inventory_items never carried a department, so department-scoped
-- access (e.g. "Canteen only") could never actually narrow the Inventory
-- list — see backend-stpl/sql/80_dept_scope_fix.sql for the full root-cause
-- writeup (KTM1006's report, 2026-09-15).
-- Database: Non_trade_Dev (MSSQL)
--
-- sp_nt_UpsertInventoryItemByProduct already receives dept_sno in its
-- caller's orgScope (grn-service/src/inventory/inventory.service.js's
-- receiveFromGRN, which resolves it from the GRN's own dept_sno — itself
-- traced from the originating PR) but silently dropped it: not accepted as
-- a parameter, not part of the item-matching WHERE, not stored, not
-- returned. All four fixed here, additively — items with no department
-- context (dept_sno IS NULL on both sides) match exactly as before.
-- ============================================================

CREATE OR ALTER PROCEDURE [dbo].[sp_nt_UpsertInventoryItemByProduct]
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @prod_sno     INT          = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @prod_name    VARCHAR(255) = JSON_VALUE(@jsonInput, '$.prod_name');
    DECLARE @uom_name     VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.uom_name');
    DECLARE @com_sno      INT          = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno      INT          = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno      INT          = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @dept_sno     INT          = JSON_VALUE(@jsonInput, '$.dept_sno');
    DECLARE @location_sno INT          = JSON_VALUE(@jsonInput, '$.location_sno');

    IF @prod_sno IS NULL
    BEGIN
        RAISERROR('prod_sno is required.', 16, 1);
        RETURN;
    END

    DECLARE @location VARCHAR(100);

    IF @location_sno IS NOT NULL
        SELECT @location = location_code
        FROM dbo.warehouse_location_master
        WHERE location_sno = @location_sno;

    DECLARE @item_sno INT;

    -- NULL-safe match: a receipt with no branch/department hits the
    -- no-branch/no-department row only, never some other branch's or
    -- department's stock.
    SELECT @item_sno = item_sno
    FROM dbo.nt_inventory_items
    WHERE prod_sno = @prod_sno
      AND ((@com_sno  IS NULL AND com_sno  IS NULL) OR com_sno  = @com_sno)
      AND ((@div_sno  IS NULL AND div_sno  IS NULL) OR div_sno  = @div_sno)
      AND ((@brn_sno  IS NULL AND brn_sno  IS NULL) OR brn_sno  = @brn_sno)
      AND ((@dept_sno IS NULL AND dept_sno IS NULL) OR dept_sno = @dept_sno);

    IF @item_sno IS NULL
    BEGIN
        DECLARE @item_code VARCHAR(50) =
            'AUTO-' + CAST(@prod_sno AS VARCHAR(20))
            + CASE WHEN @brn_sno IS NOT NULL
                   THEN '-B' + CAST(@brn_sno AS VARCHAR(20))
                   ELSE ''
              END
            + CASE WHEN @dept_sno IS NOT NULL
                   THEN '-D' + CAST(@dept_sno AS VARCHAR(20))
                   ELSE ''
              END;

        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, uom, current_stock, min_stock,
            max_stock, reorder_qty, warehouse, location, cost_price, selling_price,
            status, prod_sno, com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
        )
        VALUES (
            @item_code,
            ISNULL(@prod_name, 'Product ' + CAST(@prod_sno AS VARCHAR(20))),
            'Raw Material', ISNULL(@uom_name, 'Nos'), 0, 0,
            0, 0, 'Main Warehouse', ISNULL(@location, 'B1'), 0, 0,
            'Active', @prod_sno, @com_sno, @div_sno, @brn_sno, @dept_sno, 'system', GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();
    END
    ELSE IF @location IS NOT NULL
    BEGIN
        UPDATE dbo.nt_inventory_items
        SET location   = @location,
            updated_at = GETDATE()
        WHERE item_sno = @item_sno;
    END

    SELECT item_sno, item_code, item_name, uom, current_stock, warehouse, location,
           com_sno, div_sno, brn_sno, dept_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

-- ── sp_nt_GetInventoryItems: HierarchyJson now also matches dept_sno ─────
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
    DECLARE @HierarchyJson NVARCHAR(MAX) = NULL;

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
        SET @HierarchyJson = JSON_QUERY(@jsonInput, '$.hierarchy');
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
        scm.subcat_stock_type,
        scm.perishable_days,
        CONVERT(VARCHAR(10), lr.last_received_date, 120) AS last_received_date,
        CASE WHEN lr.last_received_date IS NOT NULL
             THEN DATEDIFF(DAY, lr.last_received_date, GETDATE())
             ELSE NULL END AS days_since_last_received,
        CASE WHEN scm.subcat_stock_type = 'Perishable'
                  AND scm.perishable_days IS NOT NULL
                  AND i.current_stock > 0
                  AND lr.last_received_date IS NOT NULL
                  AND DATEDIFF(DAY, lr.last_received_date, GETDATE()) > scm.perishable_days
             THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_expiry_stock,
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
    OUTER APPLY (
        SELECT MAX(gb.received_date) AS last_received_date
        FROM dbo.grn_item_details gi
        JOIN dbo.grn_basic_info gb ON gb.grn_basic_sno = gi.grn_basic_sno
        WHERE i.prod_sno IS NOT NULL
          AND gi.prod_sno = i.prod_sno
          AND gi.is_active = 'Y'
          AND gb.is_active = 'Y'
    ) lr
    WHERE (@category  IS NULL OR i.category  = @category)
      AND (@warehouse IS NULL OR i.warehouse = @warehouse)
      AND (@status    IS NULL OR i.status    = @status)
      AND (@com_sno   IS NULL OR i.com_sno   = @com_sno)
      AND (@div_sno   IS NULL OR i.div_sno   = @div_sno)
      AND (@brn_sno   IS NULL OR i.brn_sno   = @brn_sno)
      AND (@dept_sno  IS NULL OR i.dept_sno  = @dept_sno)
      AND (@exclude_non_regular = 0 OR ISNULL(scm.subcat_stock_type, 'Regular') NOT IN ('Non-Regular', 'Perishable'))
      AND (
            @HierarchyJson IS NULL
            OR EXISTS (
                SELECT 1 FROM OPENJSON(@HierarchyJson)
                WITH (com_sno INT '$.com_sno', div_sno INT '$.div_sno', brn_sno INT '$.brn_sno', dept_sno INT '$.dept_sno') h
                WHERE h.com_sno = i.com_sno
                  AND (h.div_sno IS NULL OR h.div_sno = i.div_sno)
                  AND (h.brn_sno IS NULL OR h.brn_sno = i.brn_sno)
                  AND (h.dept_sno IS NULL OR h.dept_sno = i.dept_sno)
          )
      )
    ORDER BY i.item_sno DESC;
END;
GO

-- ── Backfill: the 3 Canteen items received before this fix existed
-- (Carrot/Tomato/Onion, item_sno 28/29/30) — their real GRN history shows
-- dept_sno=16 (Canteen) for every receipt, so this reflects reality, not a
-- guess. Without this, a correctly Canteen-scoped user would see zero
-- items until the next GRN receipt happened to re-trigger the upsert.
UPDATE dbo.nt_inventory_items
SET dept_sno = 16
WHERE item_sno IN (28, 29, 30) AND dept_sno IS NULL;
GO
