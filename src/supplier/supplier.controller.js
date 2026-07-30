import SupplierService from "./supplier.service.js";
import { ftpUploader } from "../utils/ftpUpload.js";

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
}

export default SupplierController;
