import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class GateEntryRepository {
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

  // Approved POs that don't have a gate entry yet — a PO only ever gets one.
  async getApprovedPOs(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetPOsPendingGateEntry", filters);
  }

  async getAllGateEntries(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetAllGateEntries", filters);
  }

  async getGateEntriesByPO(po_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetGateEntriesByPO", { po_basic_sno });
  }

  async createGateEntry(entryData) {
    console.log("Creating gate entry with data:", entryData);
    return this.executeStoredProcedure("sp_nt_CreateGateEntry", entryData);
  }

  async updateGateEntry(entryData) {
    return this.executeStoredProcedure("sp_nt_UpdateGateEntry", entryData);
  }

  async updateGateEntryStatus(gate_entry_sno, status, updated_by) {
    return this.executeStoredProcedure("sp_nt_UpdateGateEntryStatus", {
      gate_entry_sno,
      status,
      updated_by,
    });
  }

  // Dispatch delivery looked up by the code in a dispatch-slip QR
  // (an LR number, or the DSD-<delivery_sno> fallback on Direct slips)
  async getDispatchDeliveryByLr(lr_code) {
    return this.executeStoredProcedure("sp_nt_GetDispatchDeliveryByLr", { lr_code });
  }

  // POs dispatched by the supplier but not yet through GRN
  async getPendingInwardPOs() {
    return this.executeStoredProcedure("sp_nt_GetPendingInwardPOs");
  }
}

export default GateEntryRepository;
