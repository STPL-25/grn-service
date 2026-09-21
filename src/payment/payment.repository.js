import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

class PaymentRepository {
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

  async getPayableBills(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetPayableBills", filters);
  }

  async releasePayment(payload) {
    return this.executeStoredProcedure("sp_nt_ReleasePayment", payload);
  }

  async getPaymentHistory(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetPaymentHistory", filters);
  }
}

export default PaymentRepository;
