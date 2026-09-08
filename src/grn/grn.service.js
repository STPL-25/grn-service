import GRNRepository from "./grn.repository.js";
import GateEntryRepository from "../gateentry/gateentry.repository.js";
import InventoryService from "../inventory/inventory.service.js";

class GRNService {
  static repo = new GRNRepository();
  static gateEntryRepo = new GateEntryRepository();

  static async getPendingPOs(filters) {
    return this.repo.getPendingPOs(filters);
  }

  static async getPendingGateEntries(filters) {
    return this.repo.getPendingGateEntries(filters);
  }

  static async getGRNsByPO(po_basic_sno) {
    return this.repo.getGRNsByPO(po_basic_sno);
  }

  // Creates the GRN, then (best-effort, does not fail the GRN if either
  // side-effect fails): flips the linked gate entry to 'GRN Done' and posts
  // an IN stock movement for every item that has a prod_sno. Returns all
  // three so the controller can broadcast real-time events for each.
  //
  // Re-reads the just-created lines from grn_item_details (rather than
  // trusting the raw request body) so each has its real grn_item_sno to
  // record the sync outcome against — see postInventoryForItems below.
  static async createGRN(grnData) {
    const grn = await this.repo.createGRN(grnData);
    const { gate_entry_sno, created_by } = grnData;
    let gateEntryUpdate = null;
    if (gate_entry_sno) {
      try {
        const updated = await this.gateEntryRepo.updateGateEntryStatus(gate_entry_sno, "GRN Done", created_by);
        gateEntryUpdate = updated?.[0] ?? null;
      } catch (err) {
        console.error("[grn-service] failed to flip gate entry status:", err.message);
      }
    }

    const grn_basic_sno = grn?.[0]?.grn_basic_sno;
    const persistedItems = grn_basic_sno ? await this.repo.getItemsForInventorySync(grn_basic_sno) : [];
    const outcomes = await this.postInventoryForItems(persistedItems, created_by);
    const inventoryUpdates = outcomes.filter((o) => o.status === "Synced").map((o) => o.result);

    return { grn, gateEntryUpdate, inventoryUpdates };
  }

  // Runs receiveFromGRN for each line and records the outcome on
  // grn_item_details.inventory_sync_status so a transient failure (DB
  // hiccup, connection pool exhaustion, etc.) is visible and re-runnable
  // afterwards instead of only ever reaching a server console log. Returns
  // one { grn_item_sno, status, result, error } per item.
  static async postInventoryForItems(items, created_by) {
    const outcomes = [];
    for (const item of items) {
      try {
        const result = await InventoryService.receiveFromGRN(item, item.grn_no, created_by, {}, item.grn_basic_sno);
        // Intentional no-op (no prod_sno / free-text line, or net qty <= 0)
        // vs. an actual post — both are non-errors, just different outcomes.
        const status = result ? "Synced" : "Skipped";
        await this.markInventorySyncSafe(item.grn_item_sno, status, null);
        outcomes.push({ grn_item_sno: item.grn_item_sno, status, result, error: null });
      } catch (err) {
        console.error("[grn-service] failed to post inventory receipt:", err.message);
        const error = err.message?.slice(0, 500);
        await this.markInventorySyncSafe(item.grn_item_sno, "Failed", error);
        outcomes.push({ grn_item_sno: item.grn_item_sno, status: "Failed", result: null, error });
      }
    }
    return outcomes;
  }

  static async markInventorySyncSafe(grn_item_sno, status, error_message) {
    try {
      await this.repo.markInventorySync(grn_item_sno, status, error_message);
    } catch (err) {
      console.error("[grn-service] failed to record inventory sync status:", err.message);
    }
  }

  // Re-runs the inventory posting for one GRN line, e.g. from an admin
  // "Resync" action once a Failed row is spotted. Fetches the line fresh
  // from the DB rather than trusting anything the caller supplies.
  static async resyncInventoryItem(grn_item_sno, actor_ecno) {
    const [item] = await this.repo.getItemForInventorySync(grn_item_sno);
    if (!item) throw new Error("GRN item not found");
    if (item.inventory_sync_status === "Synced") {
      return { alreadySynced: true, status: "Synced" };
    }

    const [outcome] = await this.postInventoryForItems([item], actor_ecno ?? item.created_by);
    if (outcome.status === "Failed") throw new Error(outcome.error ?? "Resync failed");
    return outcome;
  }

  static async getUnsyncedInventoryItems() {
    return this.repo.getUnsyncedInventoryItems();
  }

  static async getAllGRNs(filters) {
    return this.repo.getAllGRNs(filters);
  }

  static async getWarehouseLocationsForGRN(scope) {
    return this.repo.getWarehouseLocationsForGRN(scope);
  }

  static async saveGRNDraft(redisClient, ecno, draftData) {
    return this.repo.saveGRNDraft(redisClient, ecno, draftData);
  }

  static async getGRNDrafts(redisClient, ecno) {
    return this.repo.getGRNDrafts(redisClient, ecno);
  }

  static async getGRNDraft(redisClient, ecno, draftId) {
    return this.repo.getGRNDraft(redisClient, ecno, draftId);
  }

  static async updateGRNDraft(redisClient, ecno, draftId, draftData) {
    return this.repo.updateGRNDraft(redisClient, ecno, draftId, draftData);
  }

  static async deleteGRNDraft(redisClient, ecno, draftId) {
    return this.repo.deleteGRNDraft(redisClient, ecno, draftId);
  }

  static async submitGRNDraftToDB(redisClient, ecno, draftId) {
    const draft = await this.repo.getGRNDraft(redisClient, ecno, draftId);
    if (!draft) return null;
    const result = await this.createGRN(draft);
    await this.repo.deleteGRNDraft(redisClient, ecno, draftId);
    return result;
  }
}

export default GRNService;
