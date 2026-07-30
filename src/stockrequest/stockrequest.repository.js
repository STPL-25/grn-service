import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class StockRequestRepository {
  async executeStoredProcedure(procedureName, parameters = {}, { allRecordsets = false } = {}) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      if (Object.keys(parameters).length > 0) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return allRecordsets ? result.recordsets : result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getRequests(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetStockRequests", filters);
  }

  async getRequestItems(request_sno) {
    return this.executeStoredProcedure("sp_nt_GetStockRequestItems", { request_sno });
  }

  async createRequest(requestData) {
    return this.executeStoredProcedure("sp_nt_CreateStockRequest", requestData);
  }

  // Returns [ [header], [movements] ]
  async issueRequest(issueData) {
    return this.executeStoredProcedure("sp_nt_IssueStockRequest", issueData, { allRecordsets: true });
  }

  async updateStatus(statusData) {
    return this.executeStoredProcedure("sp_nt_UpdateStockRequestStatus", statusData);
  }
}

export default StockRequestRepository;
