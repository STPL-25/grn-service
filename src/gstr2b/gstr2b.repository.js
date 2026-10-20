import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

// Every call is a stored procedure taking one @jsonInput (see sql/45_gstr2b_reconciliation.sql).
class Gstr2bRepository {
  async exec(procedureName, parameters, { allRecordsets = false } = {}) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      if (parameters !== undefined) request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      const result = await request.execute(procedureName);
      return allRecordsets ? result.recordsets : result.recordset;
    } catch (error) {
      // SP THROW text is user-facing validation - keep it clean
      throw new Error(error.message);
    }
  }

  import(payload) { return this.exec("sp_nt_Gstr2bImport", payload); }
  listUploads() { return this.exec("sp_nt_Gstr2bListUploads"); }
  async summary(upload_sno) {
    const pool = await initializeDatabase();
    const r = await pool.request().input("upload_sno", mssql.Int, upload_sno).execute("sp_nt_Gstr2bSummary");
    return r.recordset;
  }
  rows(filters) { return this.exec("sp_nt_Gstr2bGetRows", filters); }
  candidates(row_sno) { return this.exec("sp_nt_Gstr2bCandidates", { row_sno }); }
  confirmSupplier(payload) { return this.exec("sp_nt_Gstr2bConfirmSupplier", payload); }
  skipRow(payload) { return this.exec("sp_nt_Gstr2bSkipRow", payload); }
  missingIn2B() { return this.exec("sp_nt_Gstr2bMissingIn2B"); }
  setHoldOverride(payload) { return this.exec("sp_nt_SetInvoiceHoldOverride", payload); }
}

export default Gstr2bRepository;
