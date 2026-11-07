import path from "path";
import SupplierService from "./supplier.service.js";
import { ftpUploader } from "../utils/ftpUpload.js";
import { broadcastPrTrack } from "../utils/prTracking.js";
import { createInAppNotification } from "../utils/notifyClient.js";
import { describeSections } from "./supplierKyc.validation.js";

// A supplier's ledger (statement of account) usually arrives as a PDF, a scan/photo, or an Excel / CSV export.
const LEDGER_FILE_EXT = new Set([".pdf", ".png", ".jpg", ".jpeg", ".webp", ".xls", ".xlsx", ".csv"]);

function getAuthEcno(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user?.ecno;
}

class SupplierController {
  // Staff-only (verifyJWT) — sends/resets a supplier's portal invite
  static async invite(req, res) {
    try {
      const { kyc_basic_info_sno, login_email, company_name } = req.body ?? {};
      const result = await SupplierService.invite({
        kyc_basic_info_sno,
        login_email,
        company_name,
        created_by: getAuthEcno(req),
      });
      res.json({ success: true, data: result, message: "Supplier invite sent" });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async login(req, res) {
    try {
      const { supp_code, password } = req.body ?? {};
      const data = await SupplierService.login({ supp_code, password });
      res.json({ success: true, data });
    } catch (error) {
      res.status(401).json({ success: false, error: error.message });
    }
  }

  static async resetPassword(req, res) {
    try {
      const { new_password } = req.body ?? {};
      const data = await SupplierService.resetPassword(
        req.supplier.kyc_basic_info_sno,
        new_password,
        req.supplier.supp_code
      );
      res.json({ success: true, data, message: "Password updated" });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async getPOs(req, res) {
    try {
      const data = await SupplierService.getPOs(req.supplier.kyc_basic_info_sno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPODetail(req, res) {
    try {
      const { po_basic_sno } = req.params;
      const data = await SupplierService.getPODetail(req.supplier.kyc_basic_info_sno, Number(po_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(404).json({ success: false, error: error.message });
    }
  }

  static async acceptPO(req, res) {
    try {
      const { po_basic_sno } = req.params;
      const data = await SupplierService.acceptPO(req.supplier.kyc_basic_info_sno, Number(po_basic_sno));
      res.json({ success: true, data, message: "PO accepted" });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async getTransporters(req, res) {
    try {
      const data = await SupplierService.getTransporters();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createDispatch(req, res) {
    try {
      const { po_basic_sno } = req.params;
      const body = req.body ?? {};

      // Multipart submissions send `deliveries` as a JSON string plus one
      // `invoice_file_<rowIndex>` file per delivery; plain JSON sends the
      // array directly (no files).
      let deliveries = body.deliveries;
      if (typeof deliveries === "string") {
        try {
          deliveries = JSON.parse(deliveries);
        } catch {
          return res.status(400).json({ success: false, error: "deliveries is not valid JSON" });
        }
      }

      if (Array.isArray(req.files) && Array.isArray(deliveries)) {
        for (const file of req.files) {
          const match = /^invoice_file_(\d+)$/.exec(file.fieldname);
          if (!match) continue;
          const idx = Number(match[1]);
          if (!deliveries[idx]) continue;
          const url = await ftpUploader.uploadFileIfExists(file, "NON_TRADE_DATAS/DISPATCH_INVOICES");
          if (!url) throw new Error(`Invoice copy upload failed for delivery ${idx + 1}.`);
          deliveries[idx].invoice_file_url = url;
        }
      }

      const data = await SupplierService.createDispatch(
        req.supplier.kyc_basic_info_sno,
        Number(po_basic_sno),
        {
          dispatch_mode: body.dispatch_mode,
          transport_sno: body.transport_sno ? Number(body.transport_sno) : undefined,
          transport_name: body.transport_name || undefined,
          deliveries,
        }
      );
      res.json({ success: true, data, message: "Dispatch slip created" });

      // Additive PR-tracking push — never affects the response above.
      broadcastPrTrack(Number(po_basic_sno), "Dispatched", "DISPATCHED", {
        dispatch_mode: body.dispatch_mode,
        transport_name: body.transport_name,
      }).catch(() => {});
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async getDispatchSlip(req, res) {
    try {
      const { dispatch_slip_sno } = req.params;
      const data = await SupplierService.getDispatchSlip(req.supplier.kyc_basic_info_sno, Number(dispatch_slip_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(404).json({ success: false, error: error.message });
    }
  }

  static async getDispatchDelivery(req, res) {
    try {
      const { delivery_sno } = req.params;
      const data = await SupplierService.getDispatchDelivery(req.supplier.kyc_basic_info_sno, Number(delivery_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(404).json({ success: false, error: error.message });
    }
  }

  static async getDebitNotes(req, res) {
    try {
      console.log(res.body)
      const data = await SupplierService.getDebitNotes(req.supplier.kyc_basic_info_sno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPayments(req, res) {
    try {
      const data = await SupplierService.getPayments(req.supplier.kyc_basic_info_sno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getCreditNotes(req, res) {
    try {
      const data = await SupplierService.getCreditNotes(req.supplier.kyc_basic_info_sno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getCreditNoteDetail(req, res) {
    try {
      const { credit_note_sno } = req.params;
      const data = await SupplierService.getCreditNoteDetail(req.supplier.kyc_basic_info_sno, Number(credit_note_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(404).json({ success: false, error: error.message });
    }
  }

  static async getDebitNoteDetail(req, res) {
    try {
      const { debit_note_sno } = req.params;
      const data = await SupplierService.getDebitNoteDetail(req.supplier.kyc_basic_info_sno, Number(debit_note_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(404).json({ success: false, error: error.message });
    }
  }

  // ── Debit / credit note ledgers (sql/87) ────────────────────────────────────────────────────────
  static async getNoteLedgers(req, res) {
    try {
      const data = await SupplierService.getNoteLedgers(req.supplier.kyc_basic_info_sno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // multipart: `ledger_file` + scope (NOTE | INVOICE) + note_kind/note_sno (NOTE) or invoice_no (INVOICE) + optional remarks
  static async uploadNoteLedger(req, res) {
    try {
      const file = req.file;
      if (!file) return res.status(400).json({ success: false, error: "Choose the ledger file to upload." });
      if (!LEDGER_FILE_EXT.has(path.extname(file.originalname).toLowerCase())) {
        return res.status(400).json({ success: false, error: "The ledger must be a PDF, an image, or an Excel / CSV file." });
      }

      // validate the form first so a bad request never leaves a file on the FTP server
      const target = SupplierService.parseNoteLedgerForm(req.body ?? {});

      const url = await ftpUploader.uploadFileIfExists(file, "NON_TRADE_DATAS/NOTE_LEDGERS");
      if (!url) return res.status(502).json({ success: false, error: "The ledger could not be uploaded. Please try again." });

      const data = await SupplierService.addNoteLedger(req.supplier, target, url, file.originalname);
      res.json({ success: true, data, message: "Ledger uploaded" });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async removeNoteLedger(req, res) {
    try {
      await SupplierService.removeNoteLedger(req.supplier.kyc_basic_info_sno, Number(req.params.ledger_sno));
      res.json({ success: true, message: "Ledger removed" });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // ── Request For Quotation ────────────────────────────────────────────────────────────────────────
  static async getRfqs(req, res) {
    try {
      const data = await SupplierService.getRfqs(req.supplier.kyc_basic_info_sno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getRfqDetail(req, res) {
    try {
      const data = await SupplierService.getRfqDetail(req.supplier.kyc_basic_info_sno, Number(req.params.rfq_supplier_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(404).json({ success: false, error: error.message });
    }
  }

  // multipart: `payload` (JSON string of the form) + optional `quotation_file`; plain JSON works too (no document)
  static async submitRfqResponse(req, res) {
    try {
      const rfq_supplier_sno = Number(req.params.rfq_supplier_sno);
      let form = req.body ?? {};
      if (typeof form.payload === "string") {
        try {
          form = JSON.parse(form.payload);
        } catch {
          return res.status(400).json({ success: false, error: "The quotation form is not valid JSON." });
        }
      }

      let quotationFileUrl;
      const file = Array.isArray(req.files) ? (req.files.find((f) => f.fieldname === "quotation_file") ?? req.files[0]) : undefined;
      if (file) {
        const okType = file.mimetype === "application/pdf" || /^image\//.test(file.mimetype);
        if (!okType) return res.status(400).json({ success: false, error: "The quotation document must be a PDF or an image." });
        quotationFileUrl = await ftpUploader.uploadFileIfExists(file, "NON_TRADE_DATAS/QUOTATION_DATAS");
        if (!quotationFileUrl) return res.status(502).json({ success: false, error: "The quotation document could not be uploaded. Please try again." });
      }

      const data = await SupplierService.submitRfqResponse(req.supplier, rfq_supplier_sno, form, quotationFileUrl);
      res.json({ success: true, data, message: data.version_no > 1 ? `Revised quotation submitted (version ${data.version_no})` : "Quotation submitted" });

      // Best-effort bell for the buyer who raised the RFQ - never affects the response above.
      if (data?.created_by) {
        createInAppNotification({
          ecno: data.created_by,
          type: "info",
          title: data.version_no > 1 ? "Revised quotation received" : "Quotation received",
          message: `${data.company_name} submitted ${data.version_no > 1 ? `a revised quotation (v${data.version_no})` : "a quotation"} for ${data.rfq_no}${data.pr_no ? ` (${data.pr_no})` : ""}. Open Purchase Team to review it.`,
          data: { kind: "rfq_response", rfq_supplier_sno, rfq_no: data.rfq_no, pr_no: data.pr_no },
        }).catch(() => {});
      }
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // ── My KYC (sql/92) ──────────────────────────────────────────────────────────────────────────────────
  static async getKyc(req, res) {
    try {
      const data = await SupplierService.getOwnKyc(req.supplier.kyc_basic_info_sno);
      res.json({ success: true, data });
    } catch (error) {
      res.status(404).json({ success: false, error: error.message });
    }
  }

  // multipart: `payload` (JSON string of the form) + `authorization_file` (1-3) + optional `doc_<document type>` files
  static async modifyKyc(req, res) {
    try {
      let form = req.body ?? {};
      if (typeof form.payload === "string") {
        try {
          form = JSON.parse(form.payload);
        } catch {
          return res.status(400).json({ success: false, error: "The KYC form is not valid JSON." });
        }
      }

      // The change is saved as a REQUEST (status P). It goes live only when the last approval stage approves it (sql/93).
      const row = await SupplierService.modifyKyc(req.supplier, form, req.files, (file, folder) => ftpUploader.uploadFileIfExists(file, folder));
      const data = {
        kyc_modified_sno: row.kyc_modified_sno, version_no: row.version_no, changed_sections: row.changed_sections,
        status: row.status, stage_no: row.stage_no, stage_total: row.stage_total, stage_name: row.stage_name,
      };
      res.json({ success: true, data, message: "Your change has been sent for approval. It goes live once it is approved." });

      // Best-effort bell for the first approver - never affects the response above.
      const who = `${row.company_name}${row.supp_code ? ` (${row.supp_code})` : ""}`;
      if (row.current_approver_ecno) {
        createInAppNotification({
          ecno: String(row.current_approver_ecno).trim(),
          type: "info",
          title: "Supplier KYC change to approve",
          message: `${who} asked to change their ${describeSections(row.changed_sections)} (request ${row.version_no}) and attached an authorization letter. Open KYC Approval to review it.`,
          data: { kind: "supplier_kyc_change_pending", kyc_modified_sno: row.kyc_modified_sno, version_no: row.version_no, screen: "KYCApprovalScreen" },
        }).catch(() => {});
      }
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // The supplier takes back a request that is still waiting for approval.
  static async withdrawKyc(req, res) {
    try {
      const kyc_modified_sno = Number(req.body?.kyc_modified_sno);
      const row = await SupplierService.withdrawKyc(req.supplier, kyc_modified_sno);
      res.json({ success: true, data: { kyc_modified_sno: row.kyc_modified_sno, status: row.status }, message: "Your request has been withdrawn" });

      if (row.current_approver_ecno) {
        createInAppNotification({
          ecno: String(row.current_approver_ecno).trim(),
          type: "info",
          title: "Supplier KYC change withdrawn",
          message: `${row.company_name}${row.supp_code ? ` (${row.supp_code})` : ""} withdrew their KYC change request ${row.version_no}. Nothing is waiting for you on it any more.`,
          data: { kind: "supplier_kyc_change_withdrawn", kyc_modified_sno: row.kyc_modified_sno, screen: "KYCApprovalScreen" },
        }).catch(() => {});
      }
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async declineRfq(req, res) {
    try {
      const rfq_supplier_sno = Number(req.params.rfq_supplier_sno);
      const data = await SupplierService.declineRfq(req.supplier, rfq_supplier_sno, req.body?.reason);
      res.json({ success: true, data, message: "Request declined" });

      if (data?.created_by) {
        createInAppNotification({
          ecno: data.created_by,
          type: "warning",
          title: "Supplier declined to quote",
          message: `${data.company_name} declined ${data.rfq_no}${data.pr_no ? ` (${data.pr_no})` : ""}: ${req.body?.reason}`,
          data: { kind: "rfq_declined", rfq_supplier_sno, rfq_no: data.rfq_no, pr_no: data.pr_no },
        }).catch(() => {});
      }
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }
}

export default SupplierController;
