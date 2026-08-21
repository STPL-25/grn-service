-- ============================================================
-- GRN Warehouse Location -> Inventory item "Location" sync
-- Database : Non_Trade (MSSQL, 10.0.21.8)
--
-- Problem: nt_inventory_items.location (the "Bin / Rack" free-text field
-- shown on the Inventory table/detail drawer and manually editable via
-- InventoryItemDialog) was never touched by the GRN receipt path.
-- sp_nt_UpsertInventoryItemByProduct (grn-service/sql/08_branch_stock.sql)
-- only ever wrote `warehouse` (hardcoded 'Main Warehouse'), and only on
-- first creation of the item row — on every later receipt against an
-- already-existing item it did nothing at all. So even after
-- 15_warehouse_location_grn_integration.sql let a GRN line record which
-- Warehouse Location it went into, the Inventory table's own Location
-- column never reflected it.
--
-- Fix: sp_nt_UpsertInventoryItemByProduct now accepts @location_sno (the
-- same warehouse_location_sno already carried on each GRN item — see
-- grn.repository.js#createGRN / grn.service.js#receiveFromGRN) and
-- resolves it to that location's code via a join, never trusting a
-- client-supplied string, matching how sp_nt_CreateGRN itself already
-- resolves warehouse_location_name server-side.
--   - Sets nt_inventory_items.location on first creation of the item row.
--   - Also UPDATEs it on every later receipt — whichever location the most
--     recent GRN line was assigned to is "where this item currently is",
--     matching how sp_nt_AdjustStock already overwrites `warehouse` on a
--     TRANSFER.
--   - A receipt with no location selected (@location_sno NULL) leaves the
--     existing value alone, so GRNs into org scopes with no locations
--     configured yet keep working exactly as before.
-- ============================================================

IF OBJECT_ID('dbo.sp_nt_UpsertInventoryItemByProduct', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_nt_UpsertInventoryItemByProduct;
GO

CREATE PROCEDURE dbo.sp_nt_UpsertInventoryItemByProduct
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
    DECLARE @location_sno INT          = JSON_VALUE(@jsonInput, '$.location_sno');

    IF @prod_sno IS NULL
    BEGIN
        RAISERROR('prod_sno is required.', 16, 1);
        RETURN;
    END

    DECLARE @location VARCHAR(100);
    IF @location_sno IS NOT NULL
        SELECT @location = location_code FROM dbo.warehouse_location_master WHERE location_sno = @location_sno;

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
            max_stock, reorder_qty, warehouse, location, cost_price, selling_price,
            status, prod_sno, com_sno, div_sno, brn_sno, created_by, created_at
        )
        VALUES (
            @item_code,
            ISNULL(@prod_name, 'Product ' + CAST(@prod_sno AS VARCHAR(20))),
            'Raw Material', ISNULL(@uom_name, 'Nos'), 0, 0,
            0, 0, 'Main Warehouse', @location, 0, 0,
            'Active', @prod_sno, @com_sno, @div_sno, @brn_sno, 'system', GETDATE()
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
           com_sno, div_sno, brn_sno
    FROM dbo.nt_inventory_items
    WHERE item_sno = @item_sno;
END;
GO

-- ============================================================
-- After running, confirm:
--   SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_UpsertInventoryItemByProduct'));
-- ============================================================
