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

  async adjustStock(adjustmentData) {
    return this.executeStoredProcedure("sp_nt_AdjustStock", adjustmentData);
  }

  // Overall totals across branches + branch-wise breakdown (two recordsets).
  async getStockSummary(filters = {}) {
    return this.executeStoredProcedureMulti("sp_nt_GetStockSummary", filters);
  }

  // Stock is bucketed per com/div/brn (dept is not part of the stock key),
  // so the branch scope travels with the product lookup.
  async upsertItemByProduct(prod_sno, prod_name, uom_name, location) {
    return this.executeStoredProcedure("sp_nt_UpsertInventoryItemByProduct", {
      prod_sno,
      prod_name,
      uom_name,
      com_sno: location.com_sno,
      div_sno: location.div_sno,
      brn_sno: location.brn_sno,
    });
  }
}

export default InventoryRepository;
