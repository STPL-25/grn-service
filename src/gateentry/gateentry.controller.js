import GateEntryService from "./gateentry.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../middleware/redisCache.js";
import { ftpUploader } from "../utils/ftpUpload.js";
import { broadcast } from "../utils/socketBroadcast.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class GateEntryController {
  static async getApprovedPOs(req, res) {
    try {
      const data = await GateEntryService.getApprovedPOs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getAllGateEntries(req, res) {
    try {
      console.log("Received request to get all gate entries with query:", req.query);
      const data = await GateEntryService.getAllGateEntries(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGateEntriesByPO(req, res) {
    try {
      const { po_basic_sno } = req.params;
      const data = await GateEntryService.getGateEntriesByPO(Number(po_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createGateEntry(req, res) {
    try {
      console.log("Received request to create gate entry with body:", req.body, "and files:", req.files);
      const user = getAuthUser(req);
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Gate entry data is required" });

      const photoFile = Array.isArray(req.files)
        ? req.files.find((f) => f.fieldname === "photo") || req.files[0]
        : undefined;
      const photo_url = photoFile
        ? await ftpUploader.uploadFileIfExists(photoFile, "NON_TRADE_DATAS/GATE_ENTRY_PHOTOS")
        : undefined;

      const data = await GateEntryService.createGateEntry({
        ...req.body,
        ...(photo_url ? { photo_url } : {}),
        created_by: user?.ecno,
      });
      await invalidateCache(req.redisClient, "gate:all");
      await invalidateCacheByPattern(req.redisClient, "gate:by_po:*");
      broadcast("grn:live", "gate_entry:created", data?.[0]);
      res.json({ success: true, data, message: "Gate entry created" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // Scan-to-fill: resolve a dispatch-slip QR code (LR no / DSD-<sno>) to the
  // dispatch delivery so the gate entry form can be prefilled.
  static async getDispatchByLr(req, res) {
    try {
      const { lr_code } = req.params;
      const data = await GateEntryService.getDispatchByLr(lr_code);
      if (!data || data.length === 0)
        return res.status(404).json({ success: false, error: "No dispatch found for this LR / code" });
      res.json({ success: true, data: data[0] });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // POs dispatched but not yet GRN-complete — feeds the sidebar Pending Inward widget
  static async getPendingInward(req, res) {
    try {
      const data = await GateEntryService.getPendingInwardPOs();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateGateEntry(req, res) {
    try {
      const user = getAuthUser(req);
      const { gate_entry_sno } = req.params;
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Gate entry data is required" });

      const photoFile = Array.isArray(req.files)
        ? req.files.find((f) => f.fieldname === "photo") || req.files[0]
        : undefined;
      const photo_url = photoFile
        ? await ftpUploader.uploadFileIfExists(photoFile, "NON_TRADE_DATAS/GATE_ENTRY_PHOTOS")
        : undefined;

      const data = await GateEntryService.updateGateEntry(Number(gate_entry_sno), {
        ...req.body,
        ...(photo_url ? { photo_url } : {}),
        updated_by: user?.ecno,
      });
      await invalidateCache(req.redisClient, "gate:all");
      await invalidateCacheByPattern(req.redisClient, "gate:by_po:*");
      broadcast("grn:live", "gate_entry:updated", data?.[0]);
      res.json({ success: true, data, message: "Gate entry updated" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateGateEntryStatus(req, res) {
    try {
      const user = getAuthUser(req);
      const { gate_entry_sno } = req.params;
      const { status } = req.body ?? {};
      if (!status)
        return res.status(400).json({ success: false, error: "status is required" });

      const data = await GateEntryService.updateGateEntryStatus(
        Number(gate_entry_sno),
        status,
        user?.ecno
      );
      await invalidateCache(req.redisClient, "gate:all");
      await invalidateCacheByPattern(req.redisClient, "gate:by_po:*");
      broadcast("grn:live", "gate_entry:status_updated", data?.[0]);
      res.json({ success: true, data, message: "Gate entry status updated" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default GateEntryController;
