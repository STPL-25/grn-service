-- ============================================================
-- Inventory module — item master + stock ledger + stored procedures
-- Database : Non_Trade (MSSQL, 10.0.21.8)
-- Used by  : grn-service/src/inventory (port 8084, mounted at /api/inventory)
--
-- NOT YET RUN on the live DB — review before executing on 10.0.21.8, then
-- run this whole file. Stock only ever changes through sp_nt_AdjustStock so
-- every change leaves a row in nt_stock_movements (IN / OUT / ADJUSTMENT /
-- TRANSFER) — sp_nt_UpdateInventoryItem intentionally never touches
-- current_stock (master-data fields only).
--
-- prod_sno links an item back to dbo.product_master so GRN receipts
-- (grn-service/src/grn/grn.service.js) can auto-locate or auto-create the
-- matching inventory item via sp_nt_UpsertInventoryItemByProduct and post an
-- IN movement without a human creating the item first.
--
-- All procedures follow this codebase's convention: a single optional
-- @jsonInput NVARCHAR(MAX) parameter, fields read via JSON_VALUE. This
-- matches grn-service/src/inventory/inventory.repository.js.
--
-- NOTE: 08_branch_stock.sql supersedes sp_nt_AdjustStock and
-- sp_nt_UpsertInventoryItemByProduct below and replaces the global
-- item_code UNIQUE constraint — stock is kept per com/div/brn (one item row
-- per branch). Always run 08 after this file.
-- ============================================================

-- ── Tables ────────────────────────────────────────────────────────────────

IF OBJECT_ID('dbo.nt_inventory_items', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_inventory_items (
        item_sno        INT IDENTITY(1,1) PRIMARY KEY,
        item_code       VARCHAR(50)   NOT NULL UNIQUE,
        item_name       VARCHAR(255)  NOT NULL,
        category        VARCHAR(50)   NULL,
        sub_category    VARCHAR(100)  NULL,
        uom             VARCHAR(20)   NULL,
        current_stock   DECIMAL(18,2) NOT NULL DEFAULT 0,
        min_stock       DECIMAL(18,2) NOT NULL DEFAULT 0,
        max_stock       DECIMAL(18,2) NOT NULL DEFAULT 0,
        reorder_qty     DECIMAL(18,2) NOT NULL DEFAULT 0,
        warehouse       VARCHAR(100)  NULL,
        location        VARCHAR(100)  NULL,
        cost_price      DECIMAL(18,2) NOT NULL DEFAULT 0,
        selling_price   DECIMAL(18,2) NOT NULL DEFAULT 0,
        status          VARCHAR(20)   NOT NULL DEFAULT 'Active',   -- Active | Inactive | Discontinued
        hsn_code        VARCHAR(20)   NULL,
        description     VARCHAR(500)  NULL,
        prod_sno        INT           NULL,                        -- link to dbo.product_master (GRN auto-post)
        com_sno         INT           NULL,                        -- org hierarchy (see company_master/division_master/branch_master/dept_master)
        div_sno         INT           NULL,
        brn_sno         INT           NULL,
        dept_sno        INT           NULL,
        created_by      VARCHAR(50)   NULL,
        created_at      DATETIME      NOT NULL DEFAULT GETDATE(),
        updated_by      VARCHAR(50)   NULL,
        updated_at      DATETIME      NULL
    );
END
GO

-- Adds the org-hierarchy columns to an nt_inventory_items table created before they existed.
IF COL_LENGTH('dbo.nt_inventory_items', 'com_sno') IS NULL
    ALTER TABLE dbo.nt_inventory_items ADD com_sno INT NULL, div_sno INT NULL, brn_sno INT NULL, dept_sno INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_inventory_items_prod_sno' AND object_id = OBJECT_ID('dbo.nt_inventory_items'))
    CREATE INDEX IX_nt_inventory_items_prod_sno ON dbo.nt_inventory_items (prod_sno);
GO

IF OBJECT_ID('dbo.nt_stock_movements', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.nt_stock_movements (
        movement_sno    INT IDENTITY(1,1) PRIMARY KEY,
        item_sno        INT           NOT NULL,
        item_code       VARCHAR(50)   NULL,
        item_name       VARCHAR(255)  NULL,
        movement_type   VARCHAR(20)   NOT NULL,   -- IN | OUT | ADJUSTMENT | TRANSFER
        quantity        DECIMAL(18,2) NOT NULL,
        balance_after   DECIMAL(18,2) NOT NULL,
        uom             VARCHAR(20)   NULL,
        reference_no    VARCHAR(100)  NULL,
        warehouse       VARCHAR(100)  NULL,
        reason          VARCHAR(255)  NULL,
        com_sno         INT           NULL,                        -- org hierarchy the movement was posted under
        div_sno         INT           NULL,
        brn_sno         INT           NULL,
        dept_sno        INT           NULL,
        created_by      VARCHAR(50)   NULL,
        created_at      DATETIME      NOT NULL DEFAULT GETDATE(),
        CONSTRAINT FK_nt_stock_movements_item
            FOREIGN KEY (item_sno) REFERENCES dbo.nt_inventory_items (item_sno)
    );
END
GO

-- Adds the org-hierarchy columns to an nt_stock_movements table created before they existed.
IF COL_LENGTH('dbo.nt_stock_movements', 'com_sno') IS NULL
    ALTER TABLE dbo.nt_stock_movements ADD com_sno INT NULL, div_sno INT NULL, brn_sno INT NULL, dept_sno INT NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_nt_stock_movements_item_sno' AND object_id = OBJECT_ID('dbo.nt_stock_movements'))
    CREATE INDEX IX_nt_stock_movements_item_sno ON dbo.nt_stock_movements (item_sno);
GO

-- ============================================================
-- sp_nt_GetInventoryItems
-- @jsonInput optional: { category, warehouse, status, com_sno, div_sno, brn_sno, dept_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetInventoryItems', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetInventoryItems;
GO

CREATE PROCEDURE dbo.sp_nt_GetInventoryItems
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

    IF @jsonInput IS NOT NULL AND LEN(LTRIM(RTRIM(@jsonInput))) > 0
    BEGIN
        SET @category  = JSON_VALUE(@jsonInput, '$.category');
        SET @warehouse = JSON_VALUE(@jsonInput, '$.warehouse');
        SET @status    = JSON_VALUE(@jsonInput, '$.status');
        SET @com_sno   = JSON_VALUE(@jsonInput, '$.com_sno');
        SET @div_sno   = JSON_VALUE(@jsonInput, '$.div_sno');
        SET @brn_sno   = JSON_VALUE(@jsonInput, '$.brn_sno');
        SET @dept_sno  = JSON_VALUE(@jsonInput, '$.dept_sno');
    END

    SELECT
        i.item_sno, i.item_code, i.item_name, i.category, i.sub_category, i.uom,
        i.current_stock, i.min_stock, i.max_stock, i.reorder_qty, i.warehouse, i.location,
        i.cost_price, i.selling_price, i.status, i.hsn_code, i.description, i.prod_sno,
        i.com_sno, c.com_name,
        i.div_sno, dv.div_name,
        i.brn_sno, br.brn_name,
        i.dept_sno, dp.dept_name,
        CONVERT(VARCHAR(30), i.created_at, 120) AS created_at,
        CONVERT(VARCHAR(30), i.updated_at, 120) AS updated_at
    FROM dbo.nt_inventory_items i
    LEFT JOIN dbo.company_master c   ON c.com_sno  = i.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = i.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = i.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = i.dept_sno
    WHERE (@category  IS NULL OR i.category  = @category)
      AND (@warehouse IS NULL OR i.warehouse = @warehouse)
      AND (@status    IS NULL OR i.status    = @status)
      AND (@com_sno   IS NULL OR i.com_sno   = @com_sno)
      AND (@div_sno   IS NULL OR i.div_sno   = @div_sno)
      AND (@brn_sno   IS NULL OR i.brn_sno   = @brn_sno)
      AND (@dept_sno  IS NULL OR i.dept_sno  = @dept_sno)
    ORDER BY i.item_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_CreateInventoryItem
-- @jsonInput: { item_code, item_name, category, sub_category, uom,
--               current_stock, min_stock, max_stock, reorder_qty, warehouse,
--               location, cost_price, selling_price, status, hsn_code,
--               description, prod_sno, com_sno, div_sno, brn_sno, dept_sno,
--               created_by }
-- A non-zero current_stock is logged as an 'Opening Stock' IN movement.
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_CreateInventoryItem', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_CreateInventoryItem;
GO

CREATE PROCEDURE dbo.sp_nt_CreateInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_code      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.item_code');
    DECLARE @item_name      VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.item_name');
    DECLARE @category       VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.category');
    DECLARE @sub_category   VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.sub_category');
    DECLARE @uom            VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.uom');
    DECLARE @current_stock  DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.current_stock');
    DECLARE @min_stock      DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.min_stock');
    DECLARE @max_stock      DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.max_stock');
    DECLARE @reorder_qty    DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.reorder_qty');
    DECLARE @warehouse      VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.warehouse');
    DECLARE @location       VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.location');
    DECLARE @cost_price     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.cost_price');
    DECLARE @selling_price  DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.selling_price');
    DECLARE @status         VARCHAR(20)   = ISNULL(JSON_VALUE(@jsonInput, '$.status'), 'Active');
    DECLARE @hsn_code       VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.hsn_code');
    DECLARE @description    VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.description');
    DECLARE @prod_sno       INT           = JSON_VALUE(@jsonInput, '$.prod_sno');
    DECLARE @com_sno        INT           = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno        INT           = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno        INT           = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @dept_sno       INT           = JSON_VALUE(@jsonInput, '$.dept_sno');
    DECLARE @created_by     VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @item_code IS NULL OR @item_name IS NULL
    BEGIN
        RAISERROR('item_code and item_name are required.', 16, 1);
        RETURN;
    END

    SET @current_stock = ISNULL(@current_stock, 0);

    DECLARE @item_sno INT;

    BEGIN TRANSACTION;
    BEGIN TRY
        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, sub_category, uom, current_stock,
            min_stock, max_stock, reorder_qty, warehouse, location, cost_price,
            selling_price, status, hsn_code, description, prod_sno,
            com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
        )
        VALUES (
            @item_code, @item_name, @category, @sub_category, @uom, @current_stock,
            ISNULL(@min_stock, 0), ISNULL(@max_stock, 0), ISNULL(@reorder_qty, 0),
            @warehouse, @location, ISNULL(@cost_price, 0),
            ISNULL(@selling_price, 0), @status, @hsn_code, @description, @prod_sno,
            @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();

        IF @current_stock > 0
        BEGIN
            INSERT INTO dbo.nt_stock_movements (
                item_sno, item_code, item_name, movement_type, quantity,
                balance_after, uom, reference_no, warehouse, reason,
                com_sno, div_sno, brn_sno, dept_sno, created_by, created_at
            )
            VALUES (
                @item_sno, @item_code, @item_name, 'IN', @current_stock,
                @current_stock, @uom, NULL, @warehouse, 'Opening Stock',
                @com_sno, @div_sno, @brn_sno, @dept_sno, @created_by, GETDATE()
            );
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT item_sno, item_code, item_name, category, uom, current_stock, warehouse, status,
           com_sno, div_sno, brn_sno, dept_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

-- ============================================================
-- sp_nt_UpdateInventoryItem — master fields only, current_stock untouched
-- @jsonInput: { item_sno, item_name, category, sub_category, uom, min_stock,
--               max_stock, reorder_qty, warehouse, location, cost_price,
--               selling_price, status, hsn_code, description,
--               com_sno, div_sno, brn_sno, dept_sno, updated_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_UpdateInventoryItem', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpdateInventoryItem;
GO

CREATE PROCEDURE dbo.sp_nt_UpdateInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno      INT           = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @item_name     VARCHAR(255)  = JSON_VALUE(@jsonInput, '$.item_name');
    DECLARE @category      VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.category');
    DECLARE @sub_category  VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.sub_category');
    DECLARE @uom           VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.uom');
    DECLARE @min_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.min_stock');
    DECLARE @max_stock     DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.max_stock');
    DECLARE @reorder_qty   DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.reorder_qty');
    DECLARE @warehouse     VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.warehouse');
    DECLARE @location      VARCHAR(100)  = JSON_VALUE(@jsonInput, '$.location');
    DECLARE @cost_price    DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.cost_price');
    DECLARE @selling_price DECIMAL(18,2) = JSON_VALUE(@jsonInput, '$.selling_price');
    DECLARE @status        VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.status');
    DECLARE @hsn_code      VARCHAR(20)   = JSON_VALUE(@jsonInput, '$.hsn_code');
    DECLARE @description   VARCHAR(500)  = JSON_VALUE(@jsonInput, '$.description');
    DECLARE @com_sno       INT           = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno       INT           = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno       INT           = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @dept_sno      INT           = JSON_VALUE(@jsonInput, '$.dept_sno');
    DECLARE @updated_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.updated_by');

    IF @item_sno IS NULL
    BEGIN
        RAISERROR('item_sno is required.', 16, 1);
        RETURN;
    END

    UPDATE dbo.nt_inventory_items
    SET item_name     = ISNULL(@item_name, item_name),
        category      = ISNULL(@category, category),
        sub_category  = @sub_category,
        uom           = ISNULL(@uom, uom),
        min_stock     = ISNULL(@min_stock, min_stock),
        max_stock     = ISNULL(@max_stock, max_stock),
        reorder_qty   = ISNULL(@reorder_qty, reorder_qty),
        warehouse     = ISNULL(@warehouse, warehouse),
        location      = @location,
        cost_price    = ISNULL(@cost_price, cost_price),
        selling_price = ISNULL(@selling_price, selling_price),
        status        = ISNULL(@status, status),
        hsn_code      = @hsn_code,
        description   = @description,
        com_sno       = ISNULL(@com_sno, com_sno),
        div_sno       = ISNULL(@div_sno, div_sno),
        brn_sno       = ISNULL(@brn_sno, brn_sno),
        dept_sno      = ISNULL(@dept_sno, dept_sno),
        updated_by    = @updated_by,
        updated_at    = GETDATE()
    WHERE item_sno = @item_sno;

    SELECT item_sno, item_code, item_name, category, uom, current_stock, warehouse, status,
           com_sno, div_sno, brn_sno, dept_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

-- ============================================================
-- sp_nt_DeleteInventoryItem — soft delete (status -> Discontinued)
-- @jsonInput: { item_sno, updated_by }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_DeleteInventoryItem', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_DeleteInventoryItem;
GO

CREATE PROCEDURE dbo.sp_nt_DeleteInventoryItem
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno   INT         = JSON_VALUE(@jsonInput, '$.item_sno');
    DECLARE @updated_by VARCHAR(50) = JSON_VALUE(@jsonInput, '$.updated_by');

    UPDATE dbo.nt_inventory_items
    SET status     = 'Discontinued',
        updated_by = @updated_by,
        updated_at = GETDATE()
    WHERE item_sno = @item_sno;

    SELECT item_sno, item_code, item_name, status
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

-- ============================================================
-- sp_nt_GetStockMovements
-- @jsonInput: { item_sno }
-- ============================================================
IF OBJECT_ID('dbo.sp_nt_GetStockMovements', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_GetStockMovements;
GO

CREATE PROCEDURE dbo.sp_nt_GetStockMovements
    @jsonInput NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @item_sno INT = JSON_VALUE(@jsonInput, '$.item_sno');

    SELECT
        m.movement_sno, m.item_sno, m.item_code, m.item_name, m.movement_type, m.quantity,
        m.balance_after, m.uom, m.reference_no, m.warehouse, m.reason,
        m.com_sno, c.com_name,
        m.div_sno, dv.div_name,
        m.brn_sno, br.brn_name,
        m.dept_sno, dp.dept_name,
        m.created_by,
        CONVERT(VARCHAR(30), m.created_at, 120) AS created_at
    FROM dbo.nt_stock_movements m
    LEFT JOIN dbo.company_master c   ON c.com_sno  = m.com_sno
    LEFT JOIN dbo.division_master dv ON dv.div_sno = m.div_sno
    LEFT JOIN dbo.branch_master br   ON br.brn_sno = m.brn_sno
    LEFT JOIN dbo.dept_master dp     ON dp.dept_sno = m.dept_sno
    WHERE m.item_sno = @item_sno
    ORDER BY m.movement_sno DESC;
END;
GO

-- ============================================================
-- sp_nt_AdjustStock — the only way current_stock ever changes
-- @jsonInput: { item_sno, movement_type, quantity, reference_no,
--               to_warehouse (required for TRANSFER), reason,
--               com_sno, div_sno, brn_sno, dept_sno (optional — default to the
--               item's own hierarchy when omitted), created_by }
--   IN         -> current_stock += quantity
--   OUT        -> current_stock -= quantity
--   ADJUSTMENT -> current_stock  = quantity (absolute set)
--   TRANSFER   -> warehouse = to_warehouse (current_stock unchanged)
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
    DECLARE @com_sno       INT           = JSON_VALUE(@jsonInput, '$.com_sno');
    DECLARE @div_sno       INT           = JSON_VALUE(@jsonInput, '$.div_sno');
    DECLARE @brn_sno       INT           = JSON_VALUE(@jsonInput, '$.brn_sno');
    DECLARE @dept_sno      INT           = JSON_VALUE(@jsonInput, '$.dept_sno');
    DECLARE @created_by    VARCHAR(50)   = JSON_VALUE(@jsonInput, '$.created_by');

    IF @item_sno IS NULL OR @movement_type IS NULL
    BEGIN
        RAISERROR('item_sno and movement_type are required.', 16, 1);
        RETURN;
    END

    DECLARE @current_stock DECIMAL(18,2), @warehouse VARCHAR(100), @item_code VARCHAR(50), @item_name VARCHAR(255), @uom VARCHAR(20);
    DECLARE @item_com_sno INT, @item_div_sno INT, @item_brn_sno INT, @item_dept_sno INT;

    SELECT
        @current_stock  = current_stock,
        @warehouse      = warehouse,
        @item_code      = item_code,
        @item_name      = item_name,
        @uom            = uom,
        @item_com_sno   = com_sno,
        @item_div_sno   = div_sno,
        @item_brn_sno   = brn_sno,
        @item_dept_sno  = dept_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;

    SET @com_sno  = ISNULL(@com_sno, @item_com_sno);
    SET @div_sno  = ISNULL(@div_sno, @item_div_sno);
    SET @brn_sno  = ISNULL(@brn_sno, @item_brn_sno);
    SET @dept_sno = ISNULL(@dept_sno, @item_dept_sno);

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
        com_sno, div_sno, brn_sno, dept_sno, created_by,
        CONVERT(VARCHAR(30), created_at, 120) AS created_at
    FROM dbo.nt_stock_movements
    WHERE movement_sno = SCOPE_IDENTITY();
END;
GO

-- ============================================================
-- sp_nt_UpsertInventoryItemByProduct
-- Used only by the GRN receipt auto-post path (grn.service.js): finds the
-- inventory item already linked to this product, or creates a minimal one.
-- @jsonInput: { prod_sno, prod_name, uom_name }
-- Returns: { item_sno, item_code, item_name, uom, current_stock, warehouse }
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

    IF @prod_sno IS NULL
    BEGIN
        RAISERROR('prod_sno is required.', 16, 1);
        RETURN;
    END

    DECLARE @item_sno INT;

    SELECT @item_sno = item_sno FROM dbo.nt_inventory_items WHERE prod_sno = @prod_sno;

    IF @item_sno IS NULL
    BEGIN
        INSERT INTO dbo.nt_inventory_items (
            item_code, item_name, category, uom, current_stock, min_stock,
            max_stock, reorder_qty, warehouse, cost_price, selling_price,
            status, prod_sno, created_by, created_at
        )
        VALUES (
            'AUTO-' + CAST(@prod_sno AS VARCHAR(20)),
            ISNULL(@prod_name, 'Product ' + CAST(@prod_sno AS VARCHAR(20))),
            'Raw Material', ISNULL(@uom_name, 'Nos'), 0, 0,
            0, 0, 'Main Warehouse', 0, 0,
            'Active', @prod_sno, 'system', GETDATE()
        );

        SET @item_sno = SCOPE_IDENTITY();
    END

    SELECT item_sno, item_code, item_name, uom, current_stock, warehouse
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO
