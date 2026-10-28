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

  async getDebitNotesForSupplier(kyc_basic_info_sno) {
    console.log("Fetching debit notes for supplier:", { kyc_basic_info_sno });
    return this.executeStoredProcedure("sp_nt_GetDebitNotesForSupplier", { kyc_basic_info_sno });
  }

  async getPaymentsForSupplier(kyc_basic_info_sno) {
    // two recordsets (payments, then advances) - executeStoredProcedure() only exposes the first
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify({ kyc_basic_info_sno }));
      const result = await request.execute("sp_nt_GetPaymentsForSupplier");
      return { payments: result.recordsets[0] ?? [], advances: result.recordsets[1] ?? [] };
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // credit notes (sql/71): raised when more arrived than the supplier invoiced - they add to what the supplier is paid
  async getCreditNotesForSupplier(kyc_basic_info_sno) {
    return this.executeStoredProcedure("sp_nt_GetCreditNotesForSupplier", { kyc_basic_info_sno });
  }

  async getCreditNoteDetailForSupplier(kyc_basic_info_sno, credit_note_sno) {
    return this.executeStoredProcedure("sp_nt_GetCreditNoteDetailForSupplier", { kyc_basic_info_sno, credit_note_sno });
  }

  async getDebitNoteDetailForSupplier(kyc_basic_info_sno, debit_note_sno) {
    console.log("Fetching debit note detail for supplier:", { kyc_basic_info_sno, debit_note_sno });
    return this.executeStoredProcedure("sp_nt_GetDebitNoteDetailForSupplier", { kyc_basic_info_sno, debit_note_sno });
  }
}

export default SupplierRepository;
