import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class InventoryRepository {
  async executeStoredProcedure(procedureName, parameters = {}) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      if (Object.keys(parameters).length > 0) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Same as executeStoredProcedure but returns every recordset, for procs
  // that select more than one result (e.g. sp_nt_GetStockSummary).
  async executeStoredProcedureMulti(procedureName, parameters = {}) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      if (Object.keys(parameters).length > 0) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordsets;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getItems(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetInventoryItems", filters);
  }

  async createItem(itemData) {
    console.log("Creating inventory item with data:", itemData);
    return this.executeStoredProcedure("sp_nt_CreateInventoryItem", itemData);
  }

  async updateItem(item_sno, itemData) {
    return this.executeStoredProcedure("sp_nt_UpdateInventoryItem", { ...itemData, item_sno });
  }

  async deleteItem(item_sno, updated_by) {
    return this.executeStoredProcedure("sp_nt_DeleteInventoryItem", { item_sno, updated_by });
  }

  async getMovements(item_sno) {
    return this.executeStoredProcedure("sp_nt_GetStockMovements", { item_sno });
  }

  // FIFO-ordered batch list for one item (see sql/32_grn_stock_batches_fifo.sql)
  async getBatches(item_sno) {
    return this.executeStoredProcedure("sp_nt_GetStockBatches", { item_sno });
  }

  async adjustStock(adjustmentData) {
    return this.executeStoredProcedure("sp_nt_AdjustStock", adjustmentData);
  }

  // Overall totals across branches + branch-wise breakdown (two recordsets).
  async getStockSummary(filters = {}) {
    return this.executeStoredProcedureMulti("sp_nt_GetStockSummary", filters);
  }

  // Stock is bucketed per com/div/brn/dept — an item with a real dept_sno
  // (currently only department-driven purchases, e.g. Canteen) gets its own
  // item row per department, so department-scoped access (nt_user_
  // permissions_json hierarchy rows with a dept_sno) can actually narrow
  // the Inventory list to it; an item with no department context (the vast
  // majority) still matches on com/div/brn alone exactly as before, since
  // dept_sno stays NULL on both sides of the upsert's NULL-safe match.
  // location_sno (a Warehouse Location master row) is resolved to its code
  // server-side and written to the item's own `location` (Bin/Rack) field.
  async upsertItemByProduct(prod_sno, prod_name, uom_name, orgScope, location_sno) {
    return this.executeStoredProcedure("sp_nt_UpsertInventoryItemByProduct", {
      prod_sno,
      prod_name,
      uom_name,
      com_sno: orgScope.com_sno,
      div_sno: orgScope.div_sno,
      brn_sno: orgScope.brn_sno,
      dept_sno: orgScope.dept_sno,
      location_sno,
    });
  }

  // Non-regular items only: auto-creates a Pending nt_stock_requests row so
  // the requester never has to raise a manual Store Requisition. No-ops
  // (empty recordset) for regular items or GRN lines with no PR linkage —
  // see sp_nt_AutoCreateStockIssueFromGRN for the gating logic.
  async autoCreateStockIssueFromGRN(data) {
    return this.executeStoredProcedure("sp_nt_AutoCreateStockIssueFromGRN", data);
  }

  // ── Unit conversion lookups ─────────────────────────────────────────────
  // Plain parameterised SELECTs (no proc needed): they only read product/UOM
  // master data, and adding a proc would mean another migration per database.

  // Everything needed to relate a received unit to the unit the item is
  // stocked in: the product's pack unit + per-product factor (Tin = 15), and
  // the fixed class/ratio of each named unit (Milliliter -> Liter).
  // Returns { pack: { uom_name, factor } | null, units: { [lowerName]: {...} } }.
  async getUnitConversionInfo(prod_sno, unitNames = []) {
    try {
      const pool = await initializeDatabase();
      const result = await pool.request()
        .input("prod_sno", mssql.Int, prod_sno)
        .input("names", mssql.NVarChar(mssql.MAX), JSON.stringify(unitNames.filter(Boolean).map((n) => String(n).trim().toLowerCase())))
        .query(`
          SELECT um.uom_name, pm.prod_uom_con_factor AS factor
          FROM dbo.product_master pm
          JOIN dbo.uom_master um ON um.uom_sno = pm.uom_sno
          WHERE pm.prod_sno = @prod_sno AND pm.prod_uom_con_factor > 0;

          SELECT LOWER(LTRIM(RTRIM(uom_name))) AS unit_key, uom_class, uom_con_factor
          FROM dbo.uom_master
          WHERE LOWER(LTRIM(RTRIM(uom_name))) IN (SELECT value FROM OPENJSON(@names));
        `);
      const [packRows, unitRows] = result.recordsets;
      return {
        pack: packRows[0] ?? null,
        units: Object.fromEntries(unitRows.map((u) => [u.unit_key, u])),
      };
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // Pack unit + factor per product, for the Inventory list's "Tin and Liters"
  // display. Only products that actually have a per-product pack size come back.
  async getPackUnits(prodSnos = []) {
    if (prodSnos.length === 0) return [];
    try {
      const pool = await initializeDatabase();
      const result = await pool.request()
        .input("ids", mssql.NVarChar(mssql.MAX), JSON.stringify(prodSnos))
        .query(`
          SELECT pm.prod_sno, um.uom_name AS pack_uom_name, pm.prod_uom_con_factor AS pack_factor
          FROM dbo.product_master pm
          JOIN dbo.uom_master um ON um.uom_sno = pm.uom_sno
          WHERE pm.prod_uom_con_factor > 0
            AND pm.prod_sno IN (SELECT CAST(value AS INT) FROM OPENJSON(@ids));
        `);
      return result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }
}

export default InventoryRepository;
