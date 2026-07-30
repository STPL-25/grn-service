-- ============================================================
-- Branch-wise stock — one inventory row per item per com/div/brn
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/inventory + grn.service.js GRN auto-post
--
-- Requires 02_inventory.sql. Run this whole file after it.
--
-- Stock is maintained per (com_sno, div_sno, brn_sno) — dept_sno is left
-- alone (columns stay, but no stock logic keys on it). Each branch gets its
-- own nt_inventory_items row for the same item/product, so:
--   * item_code uniqueness becomes (item_code, com_sno, div_sno, brn_sno)
--   * GRN receipts land on the row whose com/div/brn matches the GRN header
--     (sp_nt_UpsertInventoryItemByProduct creates the branch row on first
--     receipt: item_code AUTO-<prod_sno>-B<brn_sno>)
--   * every stock movement is stamped with the ITEM row's own com/div/brn,
--     never caller-supplied values, so ledger and item always agree
--   * sp_nt_GetStockSummary returns overall totals (summed across branches)
--     plus the branch-wise breakdown
-- ============================================================

-- ── 1. item_code unique per branch instead of global ──────────────────────

DECLARE @uq sysname;
SELECT @uq = kc.name
FROM sys.key_constraints kc
JOIN sys.index_columns ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
JOIN sys.columns c        ON c.object_id  = ic.object_id        AND c.column_id = ic.column_id
WHERE kc.parent_object_id = OBJECT_ID('dbo.nt_inventory_items')
  AND kc.type = 'UQ'
  AND c.name = 'item_code';

IF @uq IS NOT NULL
    EXEC('ALTER TABLE dbo.nt_inventory_items DROP CONSTRAINT [' + @uq + ']');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_nt_inventory_items_code_org' AND object_id = OBJECT_ID('dbo.nt_inventory_items'))
    CREATE UNIQUE INDEX UQ_nt_inventory_items_code_org
        ON dbo.nt_inventory_items (item_code, com_sno, div_sno, brn_sno);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_inventory_items_org' AND object_id = OBJECT_ID('dbo.nt_inventory_items'))
    CREATE INDEX IX_nt_inventory_items_org
        ON dbo.nt_inventory_items (com_sno, div_sno, brn_sno) INCLUDE (current_stock);
GO

-- ============================================================
-- sp_nt_UpsertInventoryItemByProduct — branch-scoped
-- Used only by the GRN receipt auto-post path (grn.service.js): finds the
-- inventory item linked to this product IN THE SAME com/div/brn bucket, or
-- creates that branch's row. dept_sno is intentionally not part of the match.
-- @jsonInput: { prod_sno, prod_name, uom_name, com_sno, div_sno, brn_sno }
-- Returns: { item_sno, item_code, item_name, uom, current_stock, warehouse,
--            com_sno, div_sno, brn_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_UpsertInventoryItemByProduct', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpsertInventoryItemByProduct;
GO

CREATE PROCEDURE dbo.sp_nt_UpsertInventoryItemByProduct
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @prod_sno  INT          = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @prod_name VARCHAR(255) = JSON_VALUE(@jsonInput, '$.prod_name');
    DECLARE @uom_name  VARCHAR(20)  = JSON_VALUE(@jsonInput, '$.uom_name');
    DECLARE @com_sno   INT          = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno   INT          = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno   INT          = JSON_VALUE(@jsonInput, '$.brn_sno');

    IF @prod_sno IS NULL
    BEGIN
        RAISERROR('prod_sno is required.', 16, 1);
        RETURN;
    END

    DECLARE @item_sno INT;

    -- NULL-safe match: a receipt with no branch hits the no-branch row only,
    -- never some other branch's stock.
    SELECT @item_sno = item_sno
    FROM dbo.nt_inventory_items
    WHERE prod_sno = @prod_sno
      AND ((@com_sno IS NULL AND com_sno IS NULL) OR com_sno = @com_sno)
      AND ((@div_sno IS NULL AND div_sno IS NULL) OR div_sno = @div_sno)
      AND ((@brn_sno IS NULL AND brn_sno IS NULL) OR brn_sno = @brn_sno);

    IF @item_sno IS NULL
    BEGIN
        DECLARE @item_code VARCHAR(50) =
            'AUTO-' + CAST(@prod_sno AS VARCHAR(20))
            + CASE WHEN @brn_sno IS NOT NULL THEN '-B' + CAST(@brn_sno AS VARCHAR(20)) ELSE '' END;

        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, uom, current_stock, min_stock,
            max_stock, reorder_qty, warehouse, cost_price, selling_price,
            status, prod_sno, com_sno, div_sno, brn_sno, created_by, created_at
        )
        VALUES (
            @item_code,
            ISNULL(@prod_name, 'Product ' + CAST(@prod_sno AS VARCHAR(20))),
            'Raw Material', ISNULL(@uom_name, 'Nos'), 0, 0,
            0, 0, 'Main Warehouse', 0, 0,
            'Active', @prod_sno, @com_sno, @div_sno, @brn_sno, 'system', GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();
    END

    SELECT item_sno, item_code, item_name, uom, current_stock, warehouse,
           com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

-- ============================================================
-- sp_nt_AdjustStock — the only way current_stock ever changes
-- @jsonInput: { item_sno, movement_type, quantity, reference_no,
--               to_warehouse (required for TRANSFER), reason, created_by }
--   IN         -> current_stock += quantity
--   OUT        -> current_stock -= quantity
--   ADJUSTMENT -> current_stock  = quantity (absolute set)
--   TRANSFER   -> warehouse = to_warehouse (current_stock unchanged)
-- The movement row is stamped with the item's own com/div/brn (dept_sno is
-- carried as-is, never keyed on), so branch ledgers always reconcile with
-- the branch item rows. Caller-supplied hierarchy values are ignored.
-- Returns the created movement row (balance_after = new current_stock).
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_AdjustStock', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_AdjustStock;
GO

CREATE PROCEDURE dbo.sp_nt_AdjustStock
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @movement_type VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.movement_type');
    DECLARE @quantity      DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.quantity');
    DECLARE @reference_no  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.reference_no');
    DECLARE @to_warehouse  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.to_warehouse');
    DECLARE @reason        VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.reason');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @item_sno IS NULL OR @movement_type IS NULL
    BEGIN
        RAISERROR('item_sno and movement_type are required.', 16, 1);
        RETURN;
    END

    DECLARE @current_stock DECIMAL(18,2), @warehouse VARCHAR(100), @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20);
    DECLARE @com_sno INT, @div_sno INT, @brn_sno INT, @dept_sno INT;

    SELECT
        @current_stock = current_stock,
        @warehouse     = warehouse,
        @item_code     = item_code,
        @item_name     = item_name,
        @uom           = uom,
        @com_sno       = com_sno,
        @div_sno       = div_sno,
        @brn_sno       = brn_sno,
        @dept_sno      = dept_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;

    IF @current_stock IS NULL
    BEGIN
        RAISERROR('Inventory item not found.', 16, 1);
        RETURN;
    END

    DECLARE @new_stock DECIMAL(18,2) = @current_stock;
    DECLARE @new_warehouse VARCHAR(100) = @warehouse;

    IF @movement_type = 'IN'
        SET @new_stock = @current_stock + ISNULL(@quantity, 0);
    ELSE IF @movement_type = 'OUT'
        SET @new_stock = @current_stock - ISNULL(@quantity, 0);
    ELSE IF @movement_type = 'ADJUSTMENT'
        SET @new_stock = ISNULL(@quantity, @current_stock);
    ELSE IF @movement_type = 'TRANSFER'
    BEGIN
        IF @to_warehouse IS NULL
        BEGIN
            RAISERROR('to_warehouse is required for TRANSFER.', 16, 1);
            RETURN;
        END
        SET @new_warehouse = @to_warehouse;
    END
    ELSE
    BEGIN
        RAISERROR('Invalid movement_type ''%s''.', 16, 1, @movement_type);
        RETURN;
    END

    UPDATE dbo.nt_inventory_items
    SET current_stock = @new_stock,
        warehouse      = @new_warehouse,
        updated_by     = @created_by,
        updated_at     = GETDATE()
    WHERE item_sno = @item_sno;

    INSERT INTO dbo.nt_stock_movements (
        item_sno, item_code, item_name, movement_type, quantity,
        balance_after, uom, reference_no, warehouse, reason,
        com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
    )
    VALUES (
        @item_sno, @item_code, @item_name, @movement_type, ISNULL(@quantity, 0),
        @new_stock, @uom, @reference_no, @new_warehouse, @reason,
        @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE()
    );

    SELECT
        movement_sno, item_sno, item_code, item_name, movement_type, quantity,
        balance_after, uom, reference_no, warehouse, reason,
        com_sno, div_sno, brn_sno, created_by,
        CONVERT(VARCHAR(30), created_at, 120) AS created_at
    FROM dbo.nt_stock_movements
    WHERE movement_sno = SCOPE_IDENTITY();
END;
GO

-- ============================================================
-- sp_nt_GetStockSummary — overall totals + branch-wise breakdown
-- @jsonInput optional: { com_sno, div_sno, brn_sno, category, status }
-- Items are grouped across branches by prod_sno when linked to a product,
-- otherwise by item_code (the same code at two branches is the same item).
-- Recordset 1: one row per item — total_stock summed across every matching
--              branch row, branch_count, total stock value.
-- Recordset 2: one row per item per branch with hierarchy names.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetStockSummary', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetStockSummary;
GO

CREATE PROCEDURE dbo.sp_nt_GetStockSummary
    @jsonInput NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @com_sno  INT         = NULL;
    DECLARE @div_sno  INT         = NULL;
    DECLARE @brn_sno  INT         = NULL;
    DECLARE @category VARCHAR(50) = NULL;
    DECLARE @status   VARCHAR(20) = NULL;

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @com_sno  = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno  = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno  = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @category = JSON_VALUE(@jsonInput, '$.category');
        SET @status   = JSON_VALUE(@jsonInput, '$.status');
    END

    SELECT
        i.item_sno, i.item_code, i.item_name, i.category, i.uom,
        i.current_stock, i.min_stock, i.warehouse, i.status, i.prod_sno,
        i.com_sno, i.div_sno, i.brn_sno,
        ISNULL('P' + CAST(i.prod_sno AS VARCHAR(20)), 'C' + i.item_code) AS item_key
    INTO #scoped
    FROM dbo.nt_inventory_items i
    WHERE (@com_sno  IS NULL OR i.com_sno  = @com_sno)
      AND (@div_sno  IS NULL OR i.div_sno  = @div_sno)
      AND (@brn_sno  IS NULL OR i.brn_sno  = @brn_sno)
      AND (@category IS NULL OR i.category = @category)
      AND (@status   IS NULL OR i.status   = @status);

    -- 1) Overall stock per item across all matching branches
    SELECT
        s.item_key,
        MIN(s.prod_sno)               AS prod_sno,
        MIN(s.item_code)              AS item_code,
        MIN(s.item_name)              AS item_name,
        MIN(s.category)               AS category,
        MIN(s.uom)                    AS uom,
        SUM(s.current_stock)          AS total_stock,
        SUM(s.min_stock)              AS total_min_stock,
        COUNT(*)                      AS branch_count
    FROM #scoped s
    GROUP BY s.item_key
    ORDER BY MIN(s.item_name);

    -- 2) Branch-wise stock for the same items
    SELECT
        s.item_key,
        s.item_sno, s.item_code, s.item_name, s.category, s.uom,
        s.current_stock, s.min_stock, s.warehouse, s.status, s.prod_sno,
        s.com_sno, c.com_name,
        s.div_sno, dv.div_name,
        s.brn_sno, br.brn_name
    FROM #scoped s
    LEFT JOIN dbo.company_master c   ON c.com_sno  = s.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = s.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = s.brn_sno
    ORDER BY s.item_name, br.brn_name;

    DROP TABLE #scoped;
END;
GO
