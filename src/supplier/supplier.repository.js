import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class SupplierRepository {
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

  async findLoginByCode(supp_code) {
    return this.executeStoredProcedure("sp_nt_SupplierLoginByCode", { supp_code });
  }

  async createOrResetLogin({ kyc_basic_info_sno, login_email, password_hash, created_by }) {
    return this.executeStoredProcedure("sp_nt_CreateSupplierLogin", {
      kyc_basic_info_sno,
      login_email,
      password_hash,
      created_by,
    });
  }

  async setPassword({ kyc_basic_info_sno, password_hash }) {
    return this.executeStoredProcedure("sp_nt_SetSupplierPassword", { kyc_basic_info_sno, password_hash });
  }

  async getPOsForSupplier(kyc_basic_info_sno) {
    return this.executeStoredProcedure("sp_nt_GetPOsForSupplier", { kyc_basic_info_sno });
  }

  async getPODetailForSupplier(kyc_basic_info_sno, po_basic_sno) {
    console.log("Fetching PO detail for supplier:", { kyc_basic_info_sno, po_basic_sno });
    return this.executeStoredProcedure("sp_nt_GetPODetailForSupplier", { kyc_basic_info_sno, po_basic_sno });
  }

  async acceptPO(kyc_basic_info_sno, po_basic_sno) {
    return this.executeStoredProcedure("sp_nt_AcceptPO", { kyc_basic_info_sno, po_basic_sno });
  }

  async createDispatchSlip(dispatchData) {
    // sp_nt_CreateDispatchSlip returns two recordsets (header row, then one
    // row per created delivery) — executeStoredProcedure() only exposes
    // result.recordset (the first), so this runs the call directly.
    const pool = await initializeDatabase();
    const request = pool.request();
    request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(dispatchData));
    const result = await request.execute("sp_nt_CreateDispatchSlip");
    const [header] = result.recordsets[0] ?? [];
    const deliveries = result.recordsets[1] ?? [];
    return { header, deliveries };
  }

  async getDispatchSlip(dispatch_slip_sno, kyc_basic_info_sno) {
    return this.executeStoredProcedure("sp_nt_GetDispatchSlip", { dispatch_slip_sno, kyc_basic_info_sno });
  }

  async getDispatchDelivery(delivery_sno, kyc_basic_info_sno) {
    return this.executeStoredProcedure("sp_nt_GetDispatchDelivery", { delivery_sno, kyc_basic_info_sno });
  }

  async getTransporters() {
    return this.executeStoredProcedure("sp_nt_GetTransportRecords");
  }
}

export default SupplierRepository;
