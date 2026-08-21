import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class InvoiceRepository {
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

  async createInvoice(payload) {
    return this.executeStoredProcedure("sp_nt_CreateInvoice", payload);
  }

  async linkInvoiceToPO(payload) {
    return this.executeStoredProcedure("sp_nt_LinkInvoiceToPO", payload);
  }

  async allocateInvoice(payload) {
    return this.executeStoredProcedure("sp_nt_AllocateInvoice", payload);
  }

  async matchInvoiceBucket(payload) {
    return this.executeStoredProcedure("sp_nt_MatchInvoiceBucket", payload);
  }

  async getInvoicesByPO(po_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetInvoicesByPO", { po_basic_sno });
  }

  async getAllInvoices(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetAllInvoices", filters);
  }

  async getPendingInvoiceMatches() {
    return this.executeStoredProcedure("sp_nt_GetPendingInvoiceMatches");
  }
}

export default InvoiceRepository;
