import GRNService from "./grn.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../middleware/redisCache.js";
import { broadcast } from "../utils/socketBroadcast.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

// Broadcasts the side-effects of a GRN creation (the GRN itself, the linked
// gate entry flipping to 'GRN Done', and any auto-posted inventory receipts)
// to everyone watching the GRN/Inventory pages in real time.
function broadcastGRNCreated(result) {
  broadcast("grn:live", "grn:created", result.grn?.[0]);
  if (result.gateEntryUpdate) {
    broadcast("grn:live", "gate_entry:status_updated", result.gateEntryUpdate);
  }
  for (const inv of result.inventoryUpdates ?? []) {
    broadcast("inventory:live", "inventory:updated", {
      item: inv.item,
      movement: inv.movement,
      action: "grn_receipt",
    });
  }
}

class GRNController {
  // ── DB Operations ─────────────────────────────────────────────────────────
   static async getGRN(req, res) {
    try {
      res.json({ success: true, message: "GRN service is up and running" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
  static async getPendingPOs(req, res) {
    try {
      const data = await GRNService.getPendingPOs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPendingGateEntries(req, res) {
    try {
      const data = await GRNService.getPendingGateEntries(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGRNsByPO(req, res) {
    try {
      const { po_basic_sno } = req.params;
      const data = await GRNService.getGRNsByPO(Number(po_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createGRN(req, res) {
    try {
      const user = getAuthUser(req);
      const result = await GRNService.createGRN({ ...req.body, created_by: user?.ecno });
      await invalidateCache(req.redisClient, "grn:pending_pos", "grn:all", "grn:pending_gate_entries");
      await invalidateCacheByPattern(req.redisClient, "grn:by_po:*");
      broadcastGRNCreated(result);
      res.json({ success: true, data: result.grn, message: "GRN created" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getAllGRNs(req, res) {
    try {
      const data = await GRNService.getAllGRNs(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── Draft Operations ──────────────────────────────────────────────────────

  static async saveGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Draft data is required" });

      const result = await GRNService.saveGRNDraft(req.redisClient, ecno, req.body);
      broadcast("grn:live", "grn:draft:new", { ...result, ecno });
      res.json({ success: true, ...result, message: "GRN draft saved" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGRNDrafts(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const drafts = await GRNService.getGRNDrafts(req.redisClient, ecno);
      res.json({ success: true, data: drafts, count: drafts.length });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const draft = await GRNService.getGRNDraft(req.redisClient, ecno, draftId);
      if (!draft) return res.status(404).json({ success: false, error: "Draft not found" });

      res.json({ success: true, data: draft });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const result = await GRNService.updateGRNDraft(req.redisClient, ecno, draftId, req.body);
      if (!result) return res.status(404).json({ success: false, error: "Draft not found" });

      broadcast("grn:live", "grn:draft:updated", { ...result, draftId, ecno });
      res.json({ success: true, ...result, message: "GRN draft updated" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async deleteGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const deleted = await GRNService.deleteGRNDraft(req.redisClient, ecno, draftId);
      if (!deleted) return res.status(404).json({ success: false, error: "Draft not found" });

      broadcast("grn:live", "grn:draft:deleted", { draftId, ecno });
      res.json({ success: true, message: "GRN draft deleted" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async submitGRNDraft(req, res) {
    try {
      const user = getAuthUser(req);
      const ecno = user?.ecno;
      if (!ecno) return res.status(401).json({ success: false, error: "Unauthorized" });

      const { draftId } = req.params;
      const result = await GRNService.submitGRNDraftToDB(req.redisClient, ecno, draftId);
      if (!result) return res.status(404).json({ success: false, error: "Draft not found" });

      await invalidateCache(req.redisClient, "grn:pending_pos", "grn:all", "grn:pending_gate_entries");
      await invalidateCacheByPattern(req.redisClient, "grn:by_po:*");
      broadcast("grn:live", "grn:draft:submitted", { draftId, ecno });
      broadcastGRNCreated(result);
      res.json({ success: true, data: result.grn, message: "GRN submitted successfully" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default GRNController;
