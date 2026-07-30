import bcrypt from "bcryptjs";
import crypto from "crypto";
import SupplierRepository from "./supplier.repository.js";
import { signSupplierToken } from "../middleware/supplierAuth.js";
import { sendMail, buildSupplierInviteEmail } from "../utils/mailer.js";

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

    const mailResult = await sendMail(
      buildSupplierInviteEmail({
        to: login_email,
        companyName: company_name || "Supplier",
        suppCode: supp_code,
        tempPassword,
        portalUrl: PORTAL_URL,
      })
    );

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
}

export default SupplierService;
