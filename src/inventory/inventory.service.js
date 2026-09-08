import InventoryRepository from "./inventory.repository.js";
import { createInAppNotification } from "../utils/notifyClient.js";

const MOVEMENT_TYPES = ["IN", "OUT", "ADJUSTMENT", "TRANSFER"];

class InventoryService {
  static repo = new InventoryRepository();

  static async getItems(filters) {
    return this.repo.getItems(filters);
  }

  static async createItem(itemData) {
    if (!itemData.item_code || !itemData.item_name) {
      throw new Error("item_code and item_name are required");
    }
    return this.repo.createItem(itemData);
  }

  static async updateItem(item_sno, itemData) {
    return this.repo.updateItem(item_sno, itemData);
  }

  static async deleteItem(item_sno, updated_by) {
    return this.repo.deleteItem(item_sno, updated_by);
  }

  static async getMovements(item_sno) {
    return this.repo.getMovements(item_sno);
  }

  static async adjustStock(adjustmentData) {
    const { item_sno, movement_type, quantity } = adjustmentData;
    if (!item_sno) throw new Error("item_sno is required");
    if (!MOVEMENT_TYPES.includes(movement_type)) {
      throw new Error(`Invalid movement_type '${movement_type}'. Allowed: ${MOVEMENT_TYPES.join(", ")}`);
    }
    if (movement_type !== "TRANSFER" && (quantity == null || Number(quantity) < 0)) {
      throw new Error("quantity must be a non-negative number");
    }
    return this.repo.adjustStock(adjustmentData);
  }

  // Called by GRN creation to auto-post a stock-in movement for each
  // received item, finding or creating the matching inventory item by
  // product. Silently skips items with no prod_sno (e.g. free-text items).
  // `scope` carries the GRN header's com/div/brn/dept so the item and its
  // movement land in the right stock bucket; item-level values win if present.
  // `grn_basic_sno` additionally lets a Non-Regular item auto-generate its
  // Store Issue record (see autoCreateStockIssueFromGRN below).
  static async receiveFromGRN(item, grn_no, created_by, scope = {}, grn_basic_sno = null) {
    if (!item?.prod_sno) return null;
    const qty = Number(item.received_qty ?? 0) - Number(item.rejected_qty ?? 0);
    if (qty <= 0) return null;

    const orgScope = {
      com_sno: item.com_sno ?? scope.com_sno,
      div_sno: item.div_sno ?? scope.div_sno,
      brn_sno: item.brn_sno ?? scope.brn_sno,
      dept_sno: item.dept_sno ?? scope.dept_sno,
    };

    const [upserted] = await this.repo.upsertItemByProduct(
      item.prod_sno,
      item.prod_name,
      item.unit_name,
      orgScope,
      item.warehouse_location_sno ?? null
    );
    if (!upserted?.item_sno) return null;

    const [movement] = await this.repo.adjustStock({
      item_sno: upserted.item_sno,
      movement_type: "IN",
      quantity: qty,
      reference_no: grn_no,
      reason: "GRN Receipt",
      created_by,
      ...orgScope,
    });

    // sp_nt_AutoCreateStockIssueFromGRN returns zero result sets (recordset
    // is undefined, not []) whenever the line isn't PR-traceable — the
    // common case for a direct/Store PO GRN — so this must not
    // array-destructure the raw result. When it IS PR-traceable it always
    // returns the requester info (regardless of Regular/Non-Regular), and
    // additionally creates the auto-issue request (request_sno populated)
    // only for Non-Regular items.
    let autoStockRequest = null;
    if (item.po_item_sno && grn_basic_sno) {
      try {
        const rows = await this.repo.autoCreateStockIssueFromGRN({
          po_item_sno: item.po_item_sno,
          item_sno: upserted.item_sno,
          qty,
          grn_basic_sno,
          grn_no,
          created_by,
        });
        const origin = rows?.[0];
        if (origin?.request_sno) autoStockRequest = origin;

        if (origin?.requester_ecno) {
          const readyMessage = origin.request_sno
            ? "It's ready for you to collect directly from the store — no requisition needed."
            : "Raise a Store Requisition to collect it.";
          createInAppNotification({
            ecno: origin.requester_ecno,
            type: origin.request_sno ? "success" : "info",
            title: "Stock received at store",
            message: `Your requested item "${origin.item_name}" (qty ${origin.qty} ${origin.uom ?? ""}) `
              + `for PR ${origin.pr_no} has arrived at the store. ${readyMessage}`,
            data: {
              pr_basic_sno: origin.pr_basic_sno,
              pr_no: origin.pr_no,
              item_sno: upserted.item_sno,
              qty: origin.qty,
              request_sno: origin.request_sno ?? null,
              request_no: origin.request_no ?? null,
            },
          }).catch((err) => console.error("[grn-service] failed to notify PR requester:", err.message));
        }
      } catch (err) {
        console.error("[grn-service] failed to resolve/auto-create non-regular stock issue:", err.message);
      }
    }

    return { item: upserted, movement, autoStockRequest };
  }
}

export default InventoryService;
