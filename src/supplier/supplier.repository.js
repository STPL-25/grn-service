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

  // ── Debit / credit note ledgers (sql/87_supplier_note_ledger.sql) ────────────────────────────────────
  // Errors 58101-58107 are written for the supplier ("None of your debit / credit notes is on that invoice."), so they pass
  // through as-is instead of being wrapped as "Database error: ...".
  async runNoteLedger(procedureName, payload) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(payload));
      const result = await request.execute(procedureName);
      return result.recordset;
    } catch (error) {
      if (error?.number >= 58100 && error?.number < 58200) throw new Error(error.message);
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getNoteLedgersForSupplier(kyc_basic_info_sno) {
    return this.runNoteLedger("sp_nt_GetSupplierNoteLedgers", { kyc_basic_info_sno });
  }

  async addNoteLedger(payload) {
    const rows = await this.runNoteLedger("sp_nt_AddSupplierNoteLedger", payload);
    return rows[0];
  }

  async removeNoteLedger(kyc_basic_info_sno, ledger_sno) {
    return this.runNoteLedger("sp_nt_RemoveSupplierNoteLedger", { kyc_basic_info_sno, ledger_sno });
  }

  // ── Request For Quotation (sql/86_supplier_rfq_portal.sql) ──────────────────────────────────────────
  // Business-rule failures are THROW 53xxx in the procedures and are written for the supplier ("The response
  // due date has passed ..."), so they pass through as-is instead of being wrapped as "Database error: ...".
  async runRfq(procedureName, payload) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(payload));
      return await request.execute(procedureName);
    } catch (error) {
      if (error?.number >= 53000 && error?.number < 54000) throw new Error(error.message);
      throw new Error(`Database error: ${error.message}`);
    }
  }

  async getRfqsForSupplier(kyc_basic_info_sno) {
    const result = await this.runRfq("sp_nt_GetRfqsForSupplier", { kyc_basic_info_sno });
    return result.recordset;
  }

  // header, items, latest response header, versions, payment-terms choices
  async getRfqDetailForSupplier(kyc_basic_info_sno, rfq_supplier_sno) {
    const result = await this.runRfq("sp_nt_GetRfqDetailForSupplier", { kyc_basic_info_sno, rfq_supplier_sno });
    const [header, items, response, versions, paymentTerms] = result.recordsets;
    return {
      header: header?.[0] ?? null,
      items: items ?? [],
      response: response?.[0] ?? null,
      versions: versions ?? [],
      payment_terms: (paymentTerms ?? []).map((r) => r.payment_terms_name),
    };
  }

  async submitRfqResponse(payload) {
    const result = await this.runRfq("sp_nt_SubmitRfqResponse", payload);
    return result.recordset[0];
  }

  async declineRfq(payload) {
    const result = await this.runRfq("sp_nt_DeclineRfq", payload);
    return result.recordset[0];
  }

  // ── Supplier KYC: view my own KYC and change it (sql/92_supplier_kyc_modification.sql) ──────────────────
  // Errors 58601-58612 are written for the supplier ("Upload the authorization letter for this change."), so they pass through
  // as-is instead of being wrapped as "Database error: ...".
  async runKyc(procedureName, payload) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(payload));
      return await request.execute(procedureName);
    } catch (error) {
      if (error?.number >= 58600 && error?.number < 58700) throw new Error(error.message);
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // head (+ snapshot JSON and its hash), the changes made so far, business types, bank account types
  async getOwnKyc(kyc_basic_info_sno) {
    const result = await this.runKyc("sp_nt_GetSupplierOwnKyc", { kyc_basic_info_sno });
    const [head, history, businessTypes, accountTypes] = result.recordsets;
    return { head: head?.[0] ?? null, history: history ?? [], businessTypes: businessTypes ?? [], accountTypes: accountTypes ?? [] };
  }

  // sql/93: saves a change REQUEST (status P, waiting for the approval stages) - the live KYC changes only when the last stage approves
  async modifyKyc(payload) {
    const result = await this.runKyc("sp_nt_SupplierModifyKyc", payload);
    return result.recordset[0];
  }

  async withdrawKyc(payload) {
    const result = await this.runKyc("sp_nt_WithdrawKycChange", payload);
    return result.recordset[0];
  }
}

export default SupplierRepository;
