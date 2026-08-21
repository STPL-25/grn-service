import InvoiceService from "./invoice.service.js";
import { ftpUploader } from "../utils/ftpUpload.js";
import { invalidateCache, invalidateCacheByPattern } from "../middleware/redisCache.js";
import { broadcast } from "../utils/socketBroadcast.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class InvoiceController {
  // multipart: fields as usual form fields, file under "invoice_file"
  static async createInvoice(req, res) {
    try {
      const user = getAuthUser(req);
      const body = req.body ?? {};

      let invoice_file_url = "";
      if (req.file) {
        invoice_file_url = await ftpUploader.uploadFileIfExists(req.file, "NON_TRADE_DATAS/SERVICE_INVOICES");
        if (!invoice_file_url) {
          return res.status(500).json({ success: false, error: "Invoice file upload failed." });
        }
      }

      const data = await InvoiceService.createInvoice({
        ...body,
        po_basic_sno: body.po_basic_sno ? Number(body.po_basic_sno) : null,
        invoice_amount: Number(body.invoice_amount),
        invoice_file_url: invoice_file_url || body.invoice_file_url || null,
        created_by: user?.ecno,
      });

      await invalidateCache(req.redisClient, "invoice:all", "invoice:pending_matches");
      await invalidateCacheByPattern(req.redisClient, "invoice:by_po:*");
      broadcast("invoice:live", "invoice:created", data?.[0]);

      res.json({ success: true, data, message: "Invoice created" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async linkInvoiceToPO(req, res) {
    try {
      const { invoice_sno, po_basic_sno } = req.body;
      if (!invoice_sno || !po_basic_sno) {
        return res.status(400).json({ success: false, error: "invoice_sno and po_basic_sno are required" });
      }
      const data = await InvoiceService.linkInvoiceToPO({ invoice_sno, po_basic_sno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async allocateInvoice(req, res) {
    try {
      const user = getAuthUser(req);
      const { invoice_sno, allocations } = req.body;
      if (!invoice_sno || !Array.isArray(allocations) || allocations.length === 0) {
        return res.status(400).json({ success: false, error: "invoice_sno and at least one allocation are required" });
      }
      const data = await InvoiceService.allocateInvoice({ invoice_sno, allocations, created_by: user?.ecno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async matchInvoice(req, res) {
    try {
      const { invoice_sno } = req.body;
      if (!invoice_sno) {
        return res.status(400).json({ success: false, error: "invoice_sno is required" });
      }
      const data = await InvoiceService.matchInvoiceBucket({ invoice_sno });
      await invalidateCache(req.redisClient, "invoice:all");
      broadcast("invoice:live", "invoice:matched", { invoice_sno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getInvoicesByPO(req, res) {
    try {
      const { po_basic_sno } = req.params;
      const data = await InvoiceService.getInvoicesByPO(Number(po_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getAllInvoices(req, res) {
    try {
      const { match_status } = req.query;
      const data = await InvoiceService.getAllInvoices({ match_status });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPendingMatches(req, res) {
    try {
      const data = await InvoiceService.getPendingInvoiceMatches();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default InvoiceController;
