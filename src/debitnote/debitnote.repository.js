import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class DebitNoteRepository {
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

  async getGRNDiscrepancyItems(grn_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetGRNDiscrepancyItems", { grn_basic_sno });
  }

  async createDebitNote(debitNoteData) {
    return this.executeStoredProcedure("sp_nt_CreateDebitNote", debitNoteData);
  }

  async getAllDebitNotes(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetAllDebitNotes", filters);
  }

  async getDebitNotesByGRN(grn_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetDebitNotesByGRN", { grn_basic_sno });
  }
}

export default DebitNoteRepository;
