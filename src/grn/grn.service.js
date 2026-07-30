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
  static async createGRN(grnData) {
    const grn = await this.repo.createGRN(grnData);
    const { gate_entry_sno, created_by, items = [], com_sno, div_sno, brn_sno } = grnData;
    // Stock is held per company/division/branch, so the GRN header scope has
    // to travel with every receipt for the right branch bucket to be hit.
    const scope = { com_sno, div_sno, brn_sno };
    let gateEntryUpdate = null;
    if (gate_entry_sno) {
      try {
        const updated = await this.gateEntryRepo.updateGateEntryStatus(gate_entry_sno, "GRN Done", created_by);
        gateEntryUpdate = updated?.[0] ?? null;
      } catch (err) {
        console.error("[grn-service] failed to flip gate entry status:", err.message);
      }
    }

    const inventoryUpdates = [];
    for (const item of items) {
      try {
        const result = await InventoryService.receiveFromGRN(item, grn?.[0]?.grn_no, created_by, scope);
        if (result) inventoryUpdates.push(result);
      } catch (err) {
        console.error("[grn-service] failed to post inventory receipt:", err.message);
      }
    }

    return { grn, gateEntryUpdate, inventoryUpdates };
  }

  static async getAllGRNs(filters) {
    return this.repo.getAllGRNs(filters);
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
