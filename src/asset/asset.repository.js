import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class AssetRepository {
  async executeStoredProcedure(procedureName, parameters = {}, { allRecordsets = false } = {}) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      const result = await request.execute(procedureName);
      return allRecordsets ? result.recordsets : result.recordset;
    } catch (error) {
      // SP THROW/RAISERROR messages are user-facing validation text — keep them clean.
      throw new Error(error.message);
    }
  }

  getRegister(filters) { return this.executeStoredProcedure("sp_nt_GetAssetRegister", filters); }
  getRequests(filters) { return this.executeStoredProcedure("sp_nt_GetAssetRequests", filters); }
  getRequestDetail(asset_req_sno) {
    return this.executeStoredProcedure("sp_nt_GetAssetRequestDetail", { asset_req_sno }, { allRecordsets: true });
  }
  getSuppliers() { return this.executeStoredProcedure("sp_nt_GetAssetSuppliers"); }
  isStoreIncharge(ecno) { return this.executeStoredProcedure("sp_nt_AssetIsStoreIncharge", { ecno }); }
  createRequest(data) { return this.executeStoredProcedure("sp_nt_CreateAssetRequest", data); }
  act(data) { return this.executeStoredProcedure("sp_nt_AssetRequestAction", data); }
}

export default AssetRepository;
