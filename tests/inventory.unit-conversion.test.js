// Unit conversion on GRN -> inventory posting (src/inventory/unitConversion.js and
// InventoryService.receiveFromGRN). Regression for: a GRN received as 1 Tin of
// sunflower oil (1 Tin = 15 Liter) was posted into a Liter-held inventory item as
// +1 Liter instead of +15 Liter.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import { unitMultiplier, convertReceipt } from "../src/inventory/unitConversion.js";
import InventoryService from "../src/inventory/inventory.service.js";

const OIL_PACK = { uom_name: "Tin", factor: 15 };
const FIXED_UNITS = {
  liter:      { uom_class: "VOLUME", uom_con_factor: 1 },
  milliliter: { uom_class: "VOLUME", uom_con_factor: 0.001 },
  kilogram:   { uom_class: "MASS",   uom_con_factor: 1 },
  tin:        { uom_class: "QUANTITY", uom_con_factor: null },
};

describe("unitMultiplier", () => {
  it("is 1 when the units match, ignoring case and padding", () => {
    expect(unitMultiplier("Liter", " liter ", {})).toBe(1);
  });

  it("is 1 when either unit is missing (nothing to convert)", () => {
    expect(unitMultiplier(null, "Liter", {})).toBe(1);
    expect(unitMultiplier("Tin", "", {})).toBe(1);
  });

  it("converts the product's pack unit to the stocked unit: Tin -> Liter = x15", () => {
    expect(unitMultiplier("Tin", "Liter", { pack: OIL_PACK })).toBe(15);
  });

  it("converts the stocked unit back to the pack unit: Liter -> Tin = /15", () => {
    expect(unitMultiplier("Liter", "Tin", { pack: OIL_PACK })).toBeCloseTo(1 / 15, 10);
  });

  it("uses fixed same-class ratios when no pack size applies: Milliliter -> Liter", () => {
    expect(unitMultiplier("Milliliter", "Liter", { units: FIXED_UNITS })).toBeCloseTo(0.001, 10);
  });

  it("returns null for units it cannot relate (different class, no pack size)", () => {
    expect(unitMultiplier("Kilogram", "Liter", { units: FIXED_UNITS })).toBeNull();
    expect(unitMultiplier("Nos", "Pcs", {})).toBeNull();
  });

  it("does not apply the pack factor to units unrelated to the pack", () => {
    // 15 is "per Tin" — it must not scale Kilogram <-> Liter
    expect(unitMultiplier("Kilogram", "Liter", { pack: OIL_PACK, units: FIXED_UNITS })).toBeNull();
  });
});

describe("convertReceipt", () => {
  it("1 Tin at Rs 2250 into a Liter item -> 15 Liter at Rs 150 per Liter", () => {
    const r = convertReceipt({ qty: 1, unitCost: 2250, fromUnit: "Tin", toUnit: "Liter", info: { pack: OIL_PACK } });
    expect(r).toMatchObject({ qty: 15, unitCost: 150, converted: true, multiplier: 15 });
    expect(r.note).toBe("received 1 Tin, stocked as 15 Liter");
  });

  it("105 Liter into a Tin item -> 7 Tin", () => {
    const r = convertReceipt({ qty: 105, unitCost: 150, fromUnit: "Liter", toUnit: "Tin", info: { pack: OIL_PACK } });
    expect(r.qty).toBe(7);
    expect(r.unitCost).toBe(2250);
  });

  it("rounds stock quantity to 2 dp (stock columns are DECIMAL(18,2))", () => {
    const r = convertReceipt({ qty: 100, unitCost: null, fromUnit: "Liter", toUnit: "Tin", info: { pack: OIL_PACK } });
    expect(r.qty).toBe(6.67);
    expect(r.unitCost).toBeNull();
  });

  it("leaves quantity and cost alone when no conversion is needed", () => {
    const r = convertReceipt({ qty: 10, unitCost: 5, fromUnit: "Nos", toUnit: "nos", info: {} });
    expect(r).toMatchObject({ qty: 10, unitCost: 5, converted: false, multiplier: 1, note: null });
  });

  it("flags an unrelatable pair with a null multiplier so the caller can fall back", () => {
    const r = convertReceipt({ qty: 4, unitCost: 9, fromUnit: "Nos", toUnit: "Pcs", info: {} });
    expect(r).toMatchObject({ qty: 4, converted: false, multiplier: null });
  });
});

describe("InventoryService.receiveFromGRN — unit conversion", () => {
  const oilLine = (over = {}) => ({
    prod_sno: 30, prod_name: "Mr Gold Sunflower Oil- 15 l", unit_name: "Tin",
    received_qty: 1, rejected_qty: 0, received_unit_price: 2250,
    grn_item_sno: 114, grn_basic_sno: 7, po_item_sno: 900, com_sno: 1, div_sno: 3, brn_sno: 4,
    ...over,
  });

  let upsert, adjust, lookup, autoIssue;
  beforeEach(() => {
    jest.restoreAllMocks();
    upsert = jest.spyOn(InventoryService.repo, "upsertItemByProduct")
      .mockResolvedValue([{ item_sno: 62, uom: "Liter", current_stock: 106 }]);
    adjust = jest.spyOn(InventoryService.repo, "adjustStock")
      .mockResolvedValue([{ movement_sno: 1, balance_after: 120 }]);
    lookup = jest.spyOn(InventoryService.repo, "getUnitConversionInfo")
      .mockResolvedValue({ pack: OIL_PACK, units: FIXED_UNITS });
    autoIssue = jest.spyOn(InventoryService.repo, "autoCreateStockIssueFromGRN").mockResolvedValue([]);
  });

  it("posts 1 Tin against a Liter item as +15 Liter, at per-Liter cost, and says so in the log", async () => {
    const out = await InventoryService.receiveFromGRN(oilLine(), "GRN-2026-000007", "KTM1148", {}, 7);

    const posted = adjust.mock.calls[0][0];
    expect(posted).toMatchObject({ item_sno: 62, movement_type: "IN", quantity: 15, unit_cost: 150 });
    expect(posted.reason).toBe("GRN Receipt (received 1 Tin, stocked as 15 Liter)");
    expect(out.conversion).toMatchObject({ converted: true, multiplier: 15 });
  });

  it("converts the net of rejected quantity (3 received, 1 rejected -> 2 Tin -> 30 Liter)", async () => {
    await InventoryService.receiveFromGRN(oilLine({ received_qty: 3, rejected_qty: 1 }), "GRN-X", "KTM1148", {}, 7);
    expect(adjust.mock.calls[0][0].quantity).toBe(30);
  });

  it("hands the auto stock-issue the converted quantity too", async () => {
    await InventoryService.receiveFromGRN(oilLine(), "GRN-X", "KTM1148", {}, 7);
    expect(autoIssue.mock.calls[0][0].qty).toBe(15);
  });

  it("does no unit lookup and keeps the plain reason when the GRN unit already matches the item", async () => {
    upsert.mockResolvedValue([{ item_sno: 62, uom: "Liter" }]);
    await InventoryService.receiveFromGRN(oilLine({ unit_name: "Liter", received_qty: 105, received_unit_price: 150 }), "GRN-X", "KTM1148", {}, 7);

    expect(lookup).not.toHaveBeenCalled();
    expect(adjust.mock.calls[0][0]).toMatchObject({ quantity: 105, unit_cost: 150, reason: "GRN Receipt" });
  });

  it("falls back to the raw quantity — and still posts — when the units cannot be related", async () => {
    lookup.mockResolvedValue({ pack: null, units: {} });
    silenceWarnings();
    const out = await InventoryService.receiveFromGRN(oilLine({ unit_name: "Nos" }), "GRN-X", "KTM1148", {}, 7);

    expect(adjust.mock.calls[0][0]).toMatchObject({ quantity: 1, unit_cost: 2250, reason: "GRN Receipt" });
    expect(out.conversion).toBeNull();
  });

  it("falls back to the raw quantity instead of failing the GRN when the unit lookup errors", async () => {
    lookup.mockRejectedValue(new Error("Database error: timeout"));
    silenceWarnings();
    const out = await InventoryService.receiveFromGRN(oilLine(), "GRN-X", "KTM1148", {}, 7);

    expect(adjust.mock.calls[0][0].quantity).toBe(1);
    expect(out).not.toBeNull();
  });
});

describe("InventoryService.getItems — pack units for display", () => {
  beforeEach(() => jest.restoreAllMocks());

  it("attaches pack unit and factor to items whose product has a pack size, leaves others alone", async () => {
    jest.spyOn(InventoryService.repo, "getItems").mockResolvedValue([
      { item_sno: 62, prod_sno: 30, uom: "Liter", current_stock: 115 },
      { item_sno: 63, prod_sno: 99, uom: "Nos", current_stock: 4 },
    ]);
    jest.spyOn(InventoryService.repo, "getPackUnits")
      .mockResolvedValue([{ prod_sno: 30, pack_uom_name: "Tin", pack_factor: "15" }]);

    const items = await InventoryService.getItems({});

    expect(items[0]).toMatchObject({ pack_uom_name: "Tin", pack_factor: 15 });
    expect(items[1].pack_uom_name).toBeUndefined();
  });

  it("still returns the list when the pack lookup fails", async () => {
    const rows = [{ item_sno: 62, prod_sno: 30, uom: "Liter", current_stock: 115 }];
    jest.spyOn(InventoryService.repo, "getItems").mockResolvedValue(rows);
    jest.spyOn(InventoryService.repo, "getPackUnits").mockRejectedValue(new Error("boom"));
    silenceWarnings();

    expect(await InventoryService.getItems({})).toBe(rows);
  });
});

// Keep the expected fallback warnings out of the test output.
function silenceWarnings() {
  jest.spyOn(console, "warn").mockImplementation(() => {});
}
