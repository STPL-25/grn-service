import GRNRepository from "./grn.repository.js";
import GateEntryRepository from "../gateentry/gateentry.repository.js";
import InventoryService from "../inventory/inventory.service.js";
import { createInAppNotification } from "../utils/notifyClient.js";

class GRNService {
  static repo = new GRNRepository();
  static gateEntryRepo = new GateEntryRepository();

  static async getPendingPOs(filters) {
    return this.repo.getPendingPOs(filters);
  }

  static async getPendingGateEntries(filters) {
    return this.repo.getPendingGateEntries(filters);
  }

  static async getGRNsByPO(po_basic_sno, hierarchyJson) {
    return this.repo.getGRNsByPO(po_basic_sno, hierarchyJson);
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

    // Approval gate (sql/40): inventory / store-requisition posting waits for final approval.
    // With no GRN workflow configured the GRN is auto-approved and posts right away.
    const [submitted] = grn_basic_sno ? await this.repo.submitForApproval({ grn_basic_sno, created_by }) : [];
    if (grn?.[0] && submitted) grn[0].status = submitted.status;
    const inventoryUpdates = submitted?.is_final ? await this.postApprovedGRN(grn_basic_sno, created_by) : [];

    if (submitted && !submitted.is_final && submitted.current_approver_id) {
      createInAppNotification({
        ecno: submitted.current_approver_id,
        type: "info",
        title: "GRN awaiting your approval",
        message: `${grn[0].grn_no} needs your approval before stock is posted. Open the GRN page > Approvals.`,
        data: { kind: "grn_approval", grn_basic_sno },
      }).catch(() => {});
    }

    // Qty above the PO was held for approval — tell the approver (best-effort).
    const excessRequests = grn_basic_sno ? await this.repo.getExcessRequests({ grn_basic_sno, status: "Pending" }) : [];
    for (const r of excessRequests) {
      createInAppNotification({
        ecno: r.approver_ecno,
        type: "warning",
        title: "Excess receipt needs approval",
        message: `${r.grn_no}: ${r.excess_qty} ${r.unit_name ?? ""} of ${r.prod_name} received above PO ${r.po_no ?? ""}. Accept or reject it on the GRN page.`,
        data: { kind: "grn_excess", excess_sno: r.excess_sno, grn_basic_sno: r.grn_basic_sno },
      }).catch(() => {});
    }

    return { grn, gateEntryUpdate, inventoryUpdates, excessRequests };
  }

  // Posts every line of an approved GRN to inventory (+ auto store requisition).
  static async postApprovedGRN(grn_basic_sno, actor) {
    const persistedItems = await this.repo.getItemsForInventorySync(grn_basic_sno);
    const outcomes = await this.postInventoryForItems(persistedItems, actor);
    return outcomes.filter((o) => o.status === "Synced").map((o) => o.result);
  }

  static async getGRNApprovals(filters) {
    const [grns = [], history = []] = await this.repo.getGRNApprovals(filters);
    return { grns, history };
  }

  // action: 'approve' | 'reject'. On final approval, posts inventory.
  static async approveGRN({ grn_basic_sno, action, comments, approved_by }) {
    const [row] = await this.repo.approveGRN({ grn_basic_sno, action, comments, approved_by });
    if (!row) throw new Error("Approval failed");
    let inventoryUpdates = [];
    if (row.result === "FINAL") {
      inventoryUpdates = await this.postApprovedGRN(grn_basic_sno, approved_by);
    }
    if (row.result === "APPROVED_NEXT" && row.next_approver) {
      createInAppNotification({
        ecno: row.next_approver, type: "info", title: "GRN awaiting your approval",
        message: "A GRN was approved by the previous approver and now needs yours.",
        data: { kind: "grn_approval", grn_basic_sno },
      }).catch(() => {});
    }
    if ((row.result === "FINAL" || row.result === "REJECTED") && row.created_by) {
      createInAppNotification({
        ecno: row.created_by,
        type: row.result === "FINAL" ? "success" : "warning",
        title: row.result === "FINAL" ? "GRN approved" : "GRN rejected",
        message: row.result === "FINAL"
          ? "Your GRN was approved and stock has been posted."
          : `Your GRN was rejected${comments ? `: ${comments}` : ""}. Re-receive the goods against the gate entry.`,
        data: { kind: "grn_approval", grn_basic_sno },
      }).catch(() => {});
    }
    return { row, inventoryUpdates };
  }

  static async getUomList() {
    return this.repo.getUomList();
  }

  static async getExcessRequests(filters) {
    return this.repo.getExcessRequests(filters);
  }

  static async getCreditNotesByGRN(grn_basic_sno) {
    return this.repo.getCreditNotesByGRN(grn_basic_sno);
  }

  // Approver accepts/rejects the qty held above the PO. The SP does the data
  // change + raises the debit/credit notes; here we post stock for an accept
  // (the held qty was excluded from the original inventory posting).
  static async decideExcess({ excess_sno, action, remarks, acted_by }) {
    const [row] = await this.repo.decideExcess({ excess_sno, action, remarks, acted_by });
    if (!row) throw new Error("Decision failed");

    let inventoryUpdate = null;
    if (row.status === "Accepted") {
      // If the original line posting Failed it is still re-runnable and will now include this qty.
      const baseDone = row.inventory_sync_status === "Synced" || row.inventory_sync_status === "Skipped";
      if (baseDone) {
        try {
          inventoryUpdate = await InventoryService.receiveFromGRN(
            { ...row, received_qty: row.excess_qty, rejected_qty: 0 },
            row.grn_no, acted_by, {}, row.grn_basic_sno
          );
        } catch (err) {
          console.error("[grn-service] failed to post accepted excess to inventory:", err.message);
        }
      }
    }

    if (row.requested_by) {
      createInAppNotification({
        ecno: row.requested_by,
        type: row.status === "Accepted" ? "success" : "warning",
        title: `Excess receipt ${row.status.toLowerCase()}`,
        message: row.status === "Accepted"
          ? `${row.grn_no}: ${row.excess_qty} ${row.unit_name ?? ""} of ${row.prod_name} accepted.`
          : `${row.grn_no}: ${row.excess_qty} ${row.unit_name ?? ""} of ${row.prod_name} rejected — reissue/return it to the supplier.${row.remarks ? ` Reason: ${row.remarks}` : ""}`,
        data: { kind: "grn_excess", excess_sno: row.excess_sno, grn_basic_sno: row.grn_basic_sno },
      }).catch(() => {});
    }
    return { request: row, inventoryUpdate };
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
    const [grnRow] = (await this.repo.getGRNApprovals({ grn_basic_sno: item.grn_basic_sno }))[0] ?? [];
    if (grnRow && grnRow.status !== "Approved" && grnRow.status !== "Received") {
      throw new Error(`GRN is ${grnRow.status} - stock is posted only after final approval.`);
    }
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
