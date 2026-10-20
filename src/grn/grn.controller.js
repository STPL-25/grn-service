import GRNService from "./grn.service.js";
import { invalidateCache, invalidateCacheByPattern } from "../middleware/redisCache.js";
import { broadcast } from "../utils/socketBroadcast.js";
import { ftpUploader } from "../utils/ftpUpload.js";
import { broadcastPrTrack } from "../utils/prTracking.js";
import { orgRoomTargets } from "../middleware/hierarchyScope.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

// Broadcasts the side-effects of a GRN creation (the GRN itself, the linked
// gate entry flipping to 'GRN Done', and any auto-posted inventory receipts)
// to everyone watching the GRN/Inventory pages in real time. grn:created and
// inventory:updated are org-scoped (orgRoomTargets); gate_entry:status_updated
// stays on the flat grn:live room for now (not yet converted).
function broadcastGRNCreated(result) {
  const grn = result.grn?.[0];
  broadcast(orgRoomTargets("grn", grn), "grn:created", grn);
  if (result.gateEntryUpdate) {
    broadcast("grn:live", "gate_entry:status_updated", result.gateEntryUpdate);
  }
  for (const inv of result.inventoryUpdates ?? []) {
    broadcast(orgRoomTargets("inventory", inv.item ?? inv.movement), "inventory:updated", {
      item: inv.item,
      movement: inv.movement,
      action: "grn_receipt",
    });
  }

  // Additive PR-tracking push — GRN creation covers both the "GRN" stage and,
  // when it auto-posted inventory, the final "Received Stock" stage.
  const po_basic_sno = result.grn?.[0]?.po_basic_sno;
  if (po_basic_sno) {
    broadcastPrTrack(po_basic_sno, "GRN", result.grn?.[0]?.status, result.grn?.[0]);
    if (result.inventoryUpdates?.length) {
      broadcastPrTrack(po_basic_sno, "Received Stock", "RECEIVED", {
        movements: result.inventoryUpdates.map((i) => i.movement),
      });
    }
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
      const data = await GRNService.getGRNsByPO(Number(po_basic_sno), req.hierarchyJson);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createGRN(req, res) {
    try {
      const user = getAuthUser(req);
      const body = { ...req.body };
      // multipart sends nested values as strings
      if (typeof body.items === "string") {
        try { body.items = JSON.parse(body.items); } catch { return res.status(400).json({ success: false, error: "Invalid items" }); }
      }
      if (!String(body.doc_ref_no ?? "").trim() || !body.invoice_date || !(Number(body.invoice_amount) > 0)) {
        return res.status(400).json({ success: false, error: "Invoice number, invoice date and invoice amount are required" });
      }
      const invoiceFile = Array.isArray(req.files)
        ? req.files.find((f) => f.fieldname === "invoice_document") || req.files[0]
        : undefined;
      if (!invoiceFile) return res.status(400).json({ success: false, error: "The supplier invoice document is required" });
      const invoice_doc_url = await ftpUploader.uploadFileIfExists(invoiceFile, "NON_TRADE_DATAS/GRN_INVOICES");
      if (!invoice_doc_url) return res.status(502).json({ success: false, error: "Invoice upload failed, please retry" });
      const result = await GRNService.createGRN({ ...body, invoice_doc_url, created_by: user?.ecno });
      await invalidateCache(req.redisClient, "grn:pending_pos", "grn:all", "grn:pending_gate_entries");
      await invalidateCacheByPattern(req.redisClient, "grn:by_po:*");
      broadcastGRNCreated(result);
      res.json({ success: true, data: result.grn, message: "GRN created" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getUomList(req, res) {
    try {
      res.json({ success: true, data: await GRNService.getUomList() });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ?mine=1 limits to requests where the caller is the approver.
  static async getExcessRequests(req, res) {
    try {
      const user = getAuthUser(req);
      const { mine, status, grn_basic_sno } = req.query;
      const data = await GRNService.getExcessRequests({
        status: status || undefined,
        grn_basic_sno: grn_basic_sno ? Number(grn_basic_sno) : undefined,
        approver_ecno: mine ? user?.ecno : undefined,
      });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async decideExcess(req, res) {
    try {
      const user = getAuthUser(req);
      const { excess_sno, action, remarks } = req.body;
      if (!excess_sno) return res.status(400).json({ success: false, error: "excess_sno is required" });
      const result = await GRNService.decideExcess({ excess_sno: Number(excess_sno), action, remarks, acted_by: user?.ecno });
      const inv = result.inventoryUpdate;
      if (inv) {
        broadcast(orgRoomTargets("inventory", inv.item ?? inv.movement), "inventory:updated", {
          item: inv.item, movement: inv.movement, action: "grn_receipt",
        });
      }
      await invalidateCache(req.redisClient, "grn:all");
      await invalidateCacheByPattern(req.redisClient, "grn:by_po:*");
      broadcast("grn:live", "grn:excess_decided", result.request);
      res.json({ success: true, data: result.request, message: `Excess ${result.request.status.toLowerCase()}` });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  // ?mine=1 -> only GRNs waiting on the caller; ?grn_basic_sno=n -> that GRN + its approval history.
  static async getGRNApprovals(req, res) {
    try {
      const user = getAuthUser(req);
      const { mine, grn_basic_sno } = req.query;
      const data = await GRNService.getGRNApprovals({
        grn_basic_sno: grn_basic_sno ? Number(grn_basic_sno) : undefined,
        approver_ecno: mine ? user?.ecno : undefined,
      });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getGRNsForAssetTags(req, res) {
    try {
      res.json({ success: true, data: await GRNService.getGRNsForAssetTags() });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async generateAssetTags(req, res) {
    try {
      const user = getAuthUser(req);
      const { grn_basic_sno } = req.body;
      if (!grn_basic_sno) return res.status(400).json({ success: false, error: "grn_basic_sno is required" });
      const data = await GRNService.generateAssetTags({ grn_basic_sno: Number(grn_basic_sno), created_by: user?.ecno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async claimAssetTagsForPrint(req, res) {
    try {
      const { tag_codes } = req.body;
      if (!Array.isArray(tag_codes) || tag_codes.length === 0) return res.status(400).json({ success: false, error: "tag_codes is required" });
      res.json({ success: true, data: { claimed: await GRNService.claimAssetTagsForPrint(tag_codes) } });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async decideGRN(req, res) {
    try {
      const user = getAuthUser(req);
      const { grn_basic_sno, action, comments } = req.body;
      if (!grn_basic_sno) return res.status(400).json({ success: false, error: "grn_basic_sno is required" });
      const result = await GRNService.approveGRN({
        grn_basic_sno: Number(grn_basic_sno), action, comments, approved_by: user?.ecno,
      });
      for (const inv of result.inventoryUpdates ?? []) {
        broadcast(orgRoomTargets("inventory", inv.item ?? inv.movement), "inventory:updated", {
          item: inv.item, movement: inv.movement, action: "grn_receipt",
        });
      }
      await invalidateCache(req.redisClient, "grn:all", "grn:pending_pos");
      await invalidateCacheByPattern(req.redisClient, "grn:by_po:*");
      broadcast("grn:live", "grn:approval_decided", result.row);
      res.json({ success: true, data: result.row, message: `GRN ${result.row.result === "REJECTED" ? "rejected" : "approved"}` });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async getJournals(req, res) {
    try {
      const { source_type, source_sno, suspense_only } = req.query;
      const data = await GRNService.getJournals({
        source_type: source_type || undefined,
        source_sno: source_sno ? Number(source_sno) : undefined,
        suspense_only: suspense_only ? 1 : undefined,
      });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getAccountHeads(req, res) {
    try {
      res.json({ success: true, data: await GRNService.getAccountHeads() });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getSubcategoryAccountMap(req, res) {
    try {
      res.json({ success: true, data: await GRNService.getSubcategoryAccountMap() });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async setSubcategoryAccountHead(req, res) {
    try {
      const user = getAuthUser(req);
      const { subcat_sno, head_sno } = req.body;
      if (!subcat_sno) return res.status(400).json({ success: false, error: "subcat_sno is required" });
      const data = await GRNService.setSubcategoryAccountHead({
        subcat_sno: Number(subcat_sno), head_sno: head_sno ? Number(head_sno) : null, modified_by: user?.ecno,
      });
      res.json({ success: true, data });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async getCreditNotesByGRN(req, res) {
    try {
      const data = await GRNService.getCreditNotesByGRN(Number(req.params.grn_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getAllGRNs(req, res) {
    try {
      const data = await GRNService.getAllGRNs({ ...req.query, hierarchy: req.hierarchyJson });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  // ── Inventory sync tracking (see sql/24_grn_inventory_sync_tracking.sql) ──

  static async getUnsyncedInventoryItems(req, res) {
    try {
      const data = await GRNService.getUnsyncedInventoryItems();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async resyncInventoryItem(req, res) {
    try {
      const user = getAuthUser(req);
      const { grn_item_sno } = req.body;
      if (!grn_item_sno) return res.status(400).json({ success: false, error: "grn_item_sno is required" });

      const data = await GRNService.resyncInventoryItem(Number(grn_item_sno), user?.ecno);
      if (data.result) {
        broadcast(orgRoomTargets("inventory", data.result.item ?? data.result.movement), "inventory:updated", {
          item: data.result.item,
          movement: data.result.movement,
          action: "grn_receipt",
        });
      }
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getWarehouseLocationsForGRN(req, res) {
    try {
      const { com_sno, div_sno, brn_sno } = req.query;
      const data = await GRNService.getWarehouseLocationsForGRN({
        com_sno: com_sno ? Number(com_sno) : null,
        div_sno: div_sno ? Number(div_sno) : null,
        brn_sno: brn_sno ? Number(brn_sno) : null,
      });
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
