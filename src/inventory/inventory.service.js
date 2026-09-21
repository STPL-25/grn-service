import InventoryRepository from "./inventory.repository.js";
import { createInAppNotification } from "../utils/notifyClient.js";
import { convertReceipt } from "./unitConversion.js";

const MOVEMENT_TYPES = ["IN", "OUT", "ADJUSTMENT", "TRANSFER"];

class InventoryService {
  static repo = new InventoryRepository();

  static async getItems(filters) {
    const items = await this.repo.getItems(filters);
    return this.withPackUnits(items);
  }

  // Attaches pack_uom_name / pack_factor (e.g. Tin / 15) to each item that has
  // a per-product pack size, so the Inventory list can show stock in both
  // units (115 Liter ≈ 7.67 Tin). Display-only: if the lookup fails the list
  // still loads, just without the pack view.
  static async withPackUnits(items) {
    if (!Array.isArray(items) || items.length === 0) return items;
    try {
      const prodSnos = [...new Set(items.map((i) => i.prod_sno).filter(Boolean))];
      const packs = new Map((await this.repo.getPackUnits(prodSnos)).map((p) => [p.prod_sno, p]));
      return items.map((i) => {
        const pack = packs.get(i.prod_sno);
        return pack ? { ...i, pack_uom_name: pack.pack_uom_name, pack_factor: Number(pack.pack_factor) } : i;
      });
    } catch (err) {
      console.warn("[grn-service] could not attach pack units to inventory list:", err.message);
      return items;
    }
  }

  // Converts a received quantity into the unit its inventory item is held in
  // (1 Tin -> 15 Liter). When the two units can't be related, or the lookup
  // itself fails, the raw quantity is kept — the behaviour before conversion
  // existed — and logged, so an unrelated unit-name mismatch (say Nos vs Pcs)
  // never blocks a GRN from reaching stock.
  static async toStockUnit(item, qty, stockUnit) {
    const raw = { qty, unitCost: item.received_unit_price ?? null, converted: false, multiplier: 1, note: null };
    const fromUnit = item.unit_name;
    if (!fromUnit || !stockUnit) return raw;
    if (String(fromUnit).trim().toLowerCase() === String(stockUnit).trim().toLowerCase()) return raw;

    let info;
    try {
      info = await this.repo.getUnitConversionInfo(item.prod_sno, [fromUnit, stockUnit]);
    } catch (err) {
      console.warn(`[grn-service] unit lookup failed for product ${item.prod_sno}; posting ${qty} ${fromUnit} unconverted:`, err.message);
      return raw;
    }

    const receipt = convertReceipt({ qty, unitCost: item.received_unit_price, fromUnit, toUnit: stockUnit, info });
    if (receipt.multiplier === null) {
      console.warn(`[grn-service] no known conversion from ${fromUnit} to ${stockUnit} for product ${item.prod_sno}; posting ${qty} unconverted.`);
      return raw;
    }
    return receipt;
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

  static async getBatches(item_sno) {
    return this.repo.getBatches(item_sno);
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

    // The line may be received in a different unit than the item is stocked
    // in (1 Tin against a Liter item) — convert before anything is posted, so
    // the movement, the FIFO batch cost and the auto-issue all agree on it.
    const receipt = await this.toStockUnit(item, qty, upserted.uom);

    // grn_basic_sno/grn_item_sno tell sp_nt_AdjustStock to create one FIFO
    // batch for this receipt; received_date/unit_cost seed that batch (the
    // GRN's actual, possibly backdated, receipt date — not GETDATE()).
    const [movement] = await this.repo.adjustStock({
      item_sno: upserted.item_sno,
      movement_type: "IN",
      quantity: receipt.qty,
      reference_no: grn_no,
      reason: receipt.note ? `GRN Receipt (${receipt.note})` : "GRN Receipt",
      created_by,
      ...orgScope,
      grn_basic_sno: grn_basic_sno ?? item.grn_basic_sno ?? null,
      grn_item_sno: item.grn_item_sno ?? null,
      grn_no,
      received_date: item.received_date ?? null,
      unit_cost: receipt.unitCost,
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
          qty: receipt.qty,
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

    return { item: upserted, movement, autoStockRequest, conversion: receipt.converted ? receipt : null };
  }
}

export default InventoryService;
