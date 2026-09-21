// Unit conversion for stock receipts.
//
// A GRN line can be received in a different unit than the one its inventory
// item is stocked in — e.g. a Tin of sunflower oil received against an item
// held in Liters. Posting the raw quantity (1 Tin -> +1 Liter) silently
// understates stock, so receiveFromGRN converts through here first.
//
// Two kinds of ratio are known:
//   * the product's own pack size — product_master.prod_uom_con_factor on its
//     purchase unit (Tin/Box/Bag differ per product: 1 Tin = 15 for this oil).
//     By convention the factor is expressed in the unit the product is stocked
//     in, so pack -> stock unit multiplies and stock unit -> pack divides.
//   * fixed ratios between units of the same class in uom_master (Milliliter ->
//     Liter, Gram -> Kilogram, Dozen -> Piece).
//
// Anything else is "unknown": the caller keeps the raw quantity rather than
// guessing (and logs it), so a synonym pair like Nos/Pcs never blocks a GRN.

const norm = (s) => String(s ?? "").trim().toLowerCase();

const round = (n, dp) => {
  const f = 10 ** dp;
  return Math.round((n + Number.EPSILON) * f) / f;
};

/**
 * Multiplier turning a quantity in `fromUnit` into `toUnit`, or null if the
 * two units can't be related from the data we have.
 *
 * @param {string} fromUnit  unit the GRN line was received in
 * @param {string} toUnit    unit the inventory item is stocked in
 * @param {{ pack?: { uom_name?: string, factor?: number },
 *           units?: Record<string, { uom_class?: string, uom_con_factor?: number }> }} info
 *        `units` is keyed by lower-cased unit name.
 */
export function unitMultiplier(fromUnit, toUnit, info = {}) {
  const from = norm(fromUnit);
  const to = norm(toUnit);
  if (!from || !to || from === to) return 1;

  const pack = norm(info.pack?.uom_name);
  const factor = Number(info.pack?.factor);
  if (pack && factor > 0) {
    if (from === pack) return factor;      // Tin -> Liter
    if (to === pack) return 1 / factor;    // Liter -> Tin
  }

  const f = info.units?.[from];
  const t = info.units?.[to];
  if (
    f && t && f.uom_class && norm(f.uom_class) === norm(t.uom_class)
    && Number(f.uom_con_factor) > 0 && Number(t.uom_con_factor) > 0
  ) {
    return Number(f.uom_con_factor) / Number(t.uom_con_factor);
  }

  return null;
}

/**
 * Converts one receipt line into the inventory item's unit.
 * Quantity is rounded to 2 dp (the stock columns are DECIMAL(18,2)).
 * `unitCost` is per received unit; it comes back per stock unit so FIFO batch
 * costing stays in step with the quantity (Rs 2250/Tin -> Rs 150/Liter).
 *
 * @returns {{ qty: number, unitCost: number|null, converted: boolean, multiplier: number|null, note: string|null }}
 */
export function convertReceipt({ qty, unitCost, fromUnit, toUnit, info }) {
  const multiplier = unitMultiplier(fromUnit, toUnit, info);

  if (multiplier === null) {
    return { qty, unitCost: unitCost ?? null, converted: false, multiplier: null, note: null };
  }
  if (multiplier === 1) {
    return { qty, unitCost: unitCost ?? null, converted: false, multiplier: 1, note: null };
  }

  const stockQty = round(qty * multiplier, 2);
  const stockCost = unitCost == null ? null : round(Number(unitCost) / multiplier, 4);
  const note = `received ${round(qty, 2)} ${String(fromUnit).trim()}, stocked as ${stockQty} ${String(toUnit).trim()}`;
  return { qty: stockQty, unitCost: stockCost, converted: true, multiplier, note };
}
