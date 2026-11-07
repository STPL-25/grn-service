import bcrypt from "bcryptjs";
import crypto from "crypto";
import path from "path";
import SupplierRepository from "./supplier.repository.js";
import { signSupplierToken } from "../middleware/supplierAuth.js";
import { sendSupplierInviteEmail } from "../utils/notifyClient.js";
import { parseKycChange, sortKycFiles } from "./supplierKyc.validation.js";

const SALT_ROUNDS = 10;
const PORTAL_URL = process.env.SUPPLIER_PORTAL_URL || "http://localhost:5173/supplier";

function generateTempPassword() {
  // 10 URL-safe chars, e.g. "aZ3-kQ9pLm" — easy to read out/paste, no ambiguous separators
  return crypto.randomBytes(8).toString("base64url").slice(0, 10);
}

class SupplierService {
  static repo = new SupplierRepository();

  static async invite({ kyc_basic_info_sno, login_email, company_name, supp_code, created_by }) {
    if (!kyc_basic_info_sno || !login_email) {
      throw new Error("kyc_basic_info_sno and login_email are required.");
    }

    const tempPassword = generateTempPassword();
    const password_hash = await bcrypt.hash(tempPassword, SALT_ROUNDS);

    const [login] = await this.repo.createOrResetLogin({
      kyc_basic_info_sno,
      login_email,
      password_hash,
      created_by,
    });

    const mailResult = await sendSupplierInviteEmail({
      to: login_email,
      companyName: company_name || "Supplier",
      suppCode: supp_code,
      tempPassword,
      portalUrl: PORTAL_URL,
    });

    return { login, emailSent: mailResult.sent };
  }

  static async login({ supp_code, password }) {
    if (!supp_code || !password) {
      throw new Error("supp_code and password are required.");
    }

    const [account] = await this.repo.findLoginByCode(supp_code);
    if (!account || account.is_active !== "Y") {
      throw new Error("Invalid supplier code or password.");
    }

    const matches = await bcrypt.compare(password, account.password_hash);
    if (!matches) {
      throw new Error("Invalid supplier code or password.");
    }

    const supplier = {
      kyc_basic_info_sno: account.kyc_basic_info_sno,
      supp_code: account.supp_code,
      company_name: account.company_name,
      email: account.login_email,
    };

    const token = signSupplierToken(supplier);
    return { token, must_reset_password: account.must_reset_password === "Y", supplier };
  }

  static async resetPassword(kyc_basic_info_sno, new_password, supp_code) {
    if (!new_password || new_password.length < 6) {
      throw new Error("New password must be at least 6 characters.");
    }
    if (supp_code && new_password.toUpperCase().includes(String(supp_code).toUpperCase())) {
      throw new Error("Password must not contain your supplier code.");
    }
    const password_hash = await bcrypt.hash(new_password, SALT_ROUNDS);
    const [result] = await this.repo.setPassword({ kyc_basic_info_sno, password_hash });
    return result;
  }

  static async getPOs(kyc_basic_info_sno) {
    return this.repo.getPOsForSupplier(kyc_basic_info_sno);
  }

  static async getPODetail(kyc_basic_info_sno, po_basic_sno) {
    const [po] = await this.repo.getPODetailForSupplier(kyc_basic_info_sno, po_basic_sno);
    if (!po) throw new Error("PO not found.");
    return po;
  }

  static async acceptPO(kyc_basic_info_sno, po_basic_sno) {
    const [result] = await this.repo.acceptPO(kyc_basic_info_sno, po_basic_sno);
    return result;
  }

  static async getTransporters() {
    return this.repo.getTransporters();
  }

  static async createDispatch(kyc_basic_info_sno, po_basic_sno, dispatchDetails) {
    const { transport_sno, transport_name, deliveries } = dispatchDetails;
    const dispatch_mode = dispatchDetails.dispatch_mode === "Direct" ? "Direct" : "Transport";

    if (!Array.isArray(deliveries) || deliveries.length === 0) {
      throw new Error("At least one delivery is required.");
    }
    if (dispatch_mode === "Transport" && !transport_sno && !transport_name) {
      throw new Error("Select a transporter, or choose Direct delivery.");
    }
    for (const d of deliveries) {
      if (!d.invoice_no || !d.invoice_date) {
        throw new Error("Each delivery requires invoice_no and invoice_date.");
      }
      if (dispatch_mode === "Transport") {
        // Via transporter: the LR number is compulsory (it is what the gate scans)
        if (!d.lr_no) throw new Error("Each delivery requires an LR no. when dispatching via a transporter.");
        if (!d.invoice_file_url) throw new Error("An invoice copy upload is required for every delivery.");
      } else {
        // Direct delivery: no LR needed, but the shipment details are compulsory
        if (d.qty == null || d.pieces == null || d.bundles == null) {
          throw new Error("Direct dispatch requires qty, pieces and bundles on every delivery.");
        }
      }
    }

    const { header, deliveries: created } = await this.repo.createDispatchSlip({
      po_basic_sno,
      kyc_basic_info_sno,
      dispatch_mode,
      transport_sno: transport_sno || undefined,
      transport_name,
      deliveries,
    });
    return { ...header, deliveries: created };
  }

  static async getDispatchSlip(kyc_basic_info_sno, dispatch_slip_sno) {
    const [slip] = await this.repo.getDispatchSlip(dispatch_slip_sno, kyc_basic_info_sno);
    if (!slip) throw new Error("Dispatch slip not found.");
    return { ...slip, deliveries: JSON.parse(slip.deliveries ?? "[]") };
  }

  static async getDispatchDelivery(kyc_basic_info_sno, delivery_sno) {
    const [delivery] = await this.repo.getDispatchDelivery(delivery_sno, kyc_basic_info_sno);
    if (!delivery) throw new Error("Delivery not found.");
    return delivery;
  }

  static async getDebitNotes(kyc_basic_info_sno) {
    return this.repo.getDebitNotesForSupplier(kyc_basic_info_sno);
  }

  static async getPayments(kyc_basic_info_sno) {
    return this.repo.getPaymentsForSupplier(kyc_basic_info_sno);
  }

  static async getCreditNotes(kyc_basic_info_sno) {
    return this.repo.getCreditNotesForSupplier(kyc_basic_info_sno);
  }

  static async getCreditNoteDetail(kyc_basic_info_sno, credit_note_sno) {
    const [note] = await this.repo.getCreditNoteDetailForSupplier(kyc_basic_info_sno, credit_note_sno);
    if (!note) throw new Error("Credit note not found.");
    return note;
  }

  static async getDebitNoteDetail(kyc_basic_info_sno, debit_note_sno) {
    const [note] = await this.repo.getDebitNoteDetailForSupplier(kyc_basic_info_sno, debit_note_sno);
    if (!note) throw new Error("Debit note not found.");
    return note;
  }

  // ── Debit / credit note ledgers ────────────────────────────────────────────────────────────────────
  static async getNoteLedgers(kyc_basic_info_sno) {
    return this.repo.getNoteLedgersForSupplier(kyc_basic_info_sno);
  }

  /**
   * What an upload form says the ledger is for: ONE note (scope NOTE: note_kind + note_sno) or an INVOICE (invoice_no - it covers
   * every debit and credit note on that invoice). Throws a message for the supplier; the controller calls this BEFORE the file is
   * sent to the FTP server so a bad request leaves nothing behind.
   */
  static parseNoteLedgerForm(form) {
    const scope = String(form?.scope ?? "").toUpperCase();
    const remarks = String(form?.remarks ?? "").trim() || undefined;
    if (scope === "NOTE") {
      const note_kind = String(form.note_kind ?? "").toUpperCase();
      const note_sno = Number(form.note_sno);
      if (!["DEBIT", "CREDIT"].includes(note_kind) || !Number.isInteger(note_sno) || note_sno <= 0) {
        throw new Error("Choose the debit or credit note this ledger is for.");
      }
      return { scope, note_kind, note_sno, remarks };
    }
    if (scope === "INVOICE") {
      const invoice_no = String(form.invoice_no ?? "").trim();
      if (!invoice_no) throw new Error("Choose the invoice this ledger is for.");
      return { scope, invoice_no, remarks };
    }
    throw new Error("Upload the ledger against a single note or against an invoice.");
  }

  /** Stores the ledger (the file is already on the FTP server). The procedure re-checks the note / invoice is the supplier's own. */
  static async addNoteLedger(supplier, target, file_url, file_name) {
    return this.repo.addNoteLedger({
      ...target,
      kyc_basic_info_sno: supplier.kyc_basic_info_sno,
      file_url,
      file_name,
      uploaded_by: supplier.email || supplier.supp_code,
    });
  }

  static async removeNoteLedger(kyc_basic_info_sno, ledger_sno) {
    if (!Number.isInteger(ledger_sno) || ledger_sno <= 0) throw new Error("That ledger was not found.");
    return this.repo.removeNoteLedger(kyc_basic_info_sno, ledger_sno);
  }

  // ── Request For Quotation ──────────────────────────────────────────────────────────────────────────
  static async getRfqs(kyc_basic_info_sno) {
    return this.repo.getRfqsForSupplier(kyc_basic_info_sno);
  }

  static async getRfqDetail(kyc_basic_info_sno, rfq_supplier_sno) {
    return this.repo.getRfqDetailForSupplier(kyc_basic_info_sno, rfq_supplier_sno);
  }

  /** Stores the submission as the next version (the procedure checks ownership, due date, status and the numbers). */
  static async submitRfqResponse(supplier, rfq_supplier_sno, form, quotation_file) {
    if (!Array.isArray(form?.items) || form.items.length === 0) {
      throw new Error("Enter your rates for the items.");
    }
    return this.repo.submitRfqResponse({
      ...form,
      kyc_basic_info_sno: supplier.kyc_basic_info_sno,
      rfq_supplier_sno,
      quotation_file: quotation_file || undefined,
      submitted_by: supplier.email || supplier.supp_code,
    });
  }

  static async declineRfq(supplier, rfq_supplier_sno, reason) {
    return this.repo.declineRfq({
      kyc_basic_info_sno: supplier.kyc_basic_info_sno,
      rfq_supplier_sno,
      reason,
      submitted_by: supplier.email || supplier.supp_code,
    });
  }

  // ── My KYC (sql/92_supplier_kyc_modification.sql) ──────────────────────────────────────────────────────
  static #json(text, fallback) {
    if (!text) return fallback;
    try {
      return JSON.parse(text);
    } catch {
      return fallback;
    }
  }

  /**
   * The supplier's own KYC (the id comes from the login, never from the request), the changes made so far and the form choices.
   * `snapshot_hash` goes back with a change so a form opened on an older KYC is refused instead of overwriting.
   */
  static async getOwnKyc(kyc_basic_info_sno) {
    const { head, history, businessTypes, accountTypes } = await this.repo.getOwnKyc(kyc_basic_info_sno);
    if (!head) throw new Error("Your KYC record was not found. Please contact the purchase team.");
    const { snapshot, snapshot_hash, ...fixed } = head;
    return {
      kyc: { ...fixed, ...this.#json(snapshot, {}), snapshot_hash },
      history: history.map((h) => ({
        ...h,
        old_data: this.#json(h.old_data, null),
        new_data: this.#json(h.new_data, null),
        files: this.#json(h.files, []),
        approvals: this.#json(h.approvals, []),
      })),
      business_types: businessTypes,
      account_types: accountTypes,
    };
  }

  /**
   * Saves a change. `rawForm` is what the portal sent, `files` is multer's req.files (authorization letter + any new KYC
   * documents), `upload(file, folder)` stores one file and returns its URL ("" when it could not be stored).
   * Everything is checked BEFORE the first file is sent to the FTP server, so a bad request leaves nothing behind.
   * The change is saved as a REQUEST waiting for the approval stages (sql/93); the live KYC does not change yet.
   * Returns the procedure's row: { kyc_modified_sno, version_no, changed_sections, status 'P', current_approver_ecno, stage_name,
   * stage_no, stage_total, company_name, supp_code }.
   */
  static async modifyKyc(supplier, rawForm, files, upload) {
    const { head, businessTypes, accountTypes } = await this.repo.getOwnKyc(supplier.kyc_basic_info_sno);
    if (!head) throw new Error("Your KYC record was not found. Please contact the purchase team.");
    const current = this.#json(head.snapshot, {});

    // a value already on file stays valid even if the master has since retired it
    const form = parseKycChange(rawForm, {
      pan_no: head.pan_no,
      current_business_type: current.basic?.business_type,
      business_types: businessTypes.map((b) => b.value),
      account_types: [...accountTypes.map((a) => a.value), ...(current.banks ?? []).map((b) => b.ac_type).filter(Boolean)],
    });
    const { authorization, documents } = sortKycFiles(files, path.extname);

    const store = async (file, folder) => {
      const url = await upload(file, folder);
      if (!url) throw new Error(`"${file.originalname}" could not be uploaded. Please try again.`);
      return { file_name: file.originalname, file_path: url, file_size: file.size };
    };
    const authorizationFiles = [];
    for (const f of authorization) {
      authorizationFiles.push({ file_kind: "AUTHORIZATION", ...(await store(f, "NON_TRADE_DATAS/KYC_MODIFICATIONS")) });
    }
    const newDocuments = [];
    for (const d of documents) {
      const saved = await store(d.file, "NON_TRADE_DATAS/KYC_DATAS");
      newDocuments.push({ document_type: d.type, document_name: saved.file_name, document_path: saved.file_path, file_size: saved.file_size });
    }

    return this.repo.modifyKyc({
      kyc_basic_info_sno: supplier.kyc_basic_info_sno,
      snapshot_hash: form.snapshot_hash,
      reason: form.reason,
      modified_by: supplier.email || supplier.supp_code,
      modified_by_code: supplier.supp_code,
      basic: form.basic,
      addresses: form.addresses,
      banks: form.banks,
      contacts: form.contacts,
      documents: newDocuments,
      files: [
        ...authorizationFiles,
        ...newDocuments.map((d) => ({ file_kind: d.document_type, file_name: d.document_name, file_path: d.document_path, file_size: d.file_size })),
      ],
    });
  }

  /** Withdraws the supplier's own request while it is still waiting. The procedure checks it is this supplier's and still waiting. */
  static async withdrawKyc(supplier, kyc_modified_sno) {
    if (!Number.isInteger(kyc_modified_sno) || kyc_modified_sno <= 0) throw new Error("That request was not found.");
    return this.repo.withdrawKyc({
      kyc_basic_info_sno: supplier.kyc_basic_info_sno,
      kyc_modified_sno,
      by: supplier.email || supplier.supp_code,
    });
  }
}

export default SupplierService;
