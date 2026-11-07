// supplierEvents.job.js - the supplier-portal bell for debit notes, credit notes and payments (sql/88).
// What matters here is the contract with sp_nt_GetPendingSupplierEvents: an event is only marked delivered once its notification
// was actually accepted (so a notification-service outage retries instead of losing it), an event with nothing to say is closed
// without sending, and the wording is right. The SQL itself was verified against Dev data in a rolled-back transaction
// (sql/_verify_88.mjs).
import { describe, it, expect, jest, beforeEach } from "@jest/globals";

jest.unstable_mockModule("../src/config/db.js", () => ({ initializeDatabase: async () => { throw new Error("no real DB in unit tests"); } }));
jest.unstable_mockModule("../src/utils/notifyClient.js", () => ({ notifySupplier: async () => ({ sent: true }) }));

const { buildSupplierNotification, sweepSupplierEvents } = await import("../src/supplier/supplierEvents.job.js");

describe("buildSupplierNotification", () => {
  it("debit note: warning, amount in rupees, PO and reason, opens the notes screen", () => {
    const n = buildSupplierNotification({ event_kind: "DEBIT_NOTE", ref_no: "DN-2026-000005", amount: 100000, po_no: "PO-9", remarks: "Auto: received less than invoice qty" });
    expect(n.type).toBe("warning");
    expect(n.title).toBe("Debit note raised");
    expect(n.message).toContain("DN-2026-000005");
    expect(n.message).toContain("₹1,00,000.00");
    expect(n.message).toContain("against PO PO-9");
    expect(n.message).toContain("Reason: Auto: received less than invoice qty.");
    expect(n.data).toEqual({ kind: "debit_note", view: "debit-notes", ref_no: "DN-2026-000005" });
  });

  it("credit note: success, says it adds to what the supplier is paid", () => {
    const n = buildSupplierNotification({ event_kind: "CREDIT_NOTE", ref_no: "CN-2026-000004", amount: 1400 });
    expect(n.type).toBe("success");
    expect(n.message).toContain("₹1,400.00");
    expect(n.message).toContain("adds to what you are paid");
    expect(n.message).not.toContain("against PO");
    expect(n.data.view).toBe("debit-notes");
  });

  it("scheduled payment: info; an advance names its planned date", () => {
    const bill = buildSupplierNotification({ event_kind: "PAY_SCHEDULED", ref_no: "PAY-1", amount: 51220.31, payment_type: "BILL", planned_for: "12 Nov 2026" });
    expect(bill.title).toBe("Payment scheduled");
    expect(bill.message).toBe("Payment PAY-1 of ₹51,220.31 is scheduled.");

    const adv = buildSupplierNotification({ event_kind: "PAY_SCHEDULED", ref_no: "PAY-2", amount: 5000, payment_type: "ADVANCE", planned_for: "12 Nov 2026" });
    expect(adv.title).toBe("Advance payment scheduled");
    expect(adv.message).toContain("is scheduled for 12 Nov 2026");
    expect(adv.data.view).toBe("payments");
  });

  it("paid payment: success, with mode and date when known and without them when not", () => {
    const full = buildSupplierNotification({ event_kind: "PAY_PAID", ref_no: "PAY-3", amount: 6101.69, mode: "NEFT", paid_on: "03 Nov 2026" });
    expect(full.type).toBe("success");
    expect(full.message).toBe("Payment PAY-3: ₹6,101.69 has been paid by NEFT on 03 Nov 2026.");
    const bare = buildSupplierNotification({ event_kind: "PAY_PAID", ref_no: "PAY-4", amount: 10 });
    expect(bare.message).toBe("Payment PAY-4: ₹10.00 has been paid.");
  });

  it("returns null when there is nothing to announce (source went inactive, or an unknown kind)", () => {
    expect(buildSupplierNotification({ event_kind: "DEBIT_NOTE", ref_no: null })).toBeNull();
    expect(buildSupplierNotification({ event_kind: "WHAT", ref_no: "X" })).toBeNull();
    expect(buildSupplierNotification(undefined)).toBeNull();
  });

  it("clips a very long remark so the message stays readable", () => {
    const n = buildSupplierNotification({ event_kind: "DEBIT_NOTE", ref_no: "DN-1", amount: 1, remarks: "x".repeat(900) });
    expect(n.message.length).toBeLessThan(500);
    expect(n.message).toContain("…");
  });
});

describe("sweepSupplierEvents", () => {
  let executed;
  const poolReturning = (events) => ({
    request: () => {
      const req = {
        input: (name, _type, value) => { req.params = { ...req.params, [name]: value }; return req; },
        execute: async (proc) => { executed.push({ proc, params: req.params }); return { recordset: proc === "sp_nt_GetPendingSupplierEvents" ? events : [{ marked: 1 }] }; },
      };
      return req;
    },
  });

  beforeEach(() => { executed = []; });

  const ev = (over) => ({ event_sno: 1, event_kind: "DEBIT_NOTE", ref_sno: 5, vendor_sno: 122, ref_no: "DN-1", amount: 100, ...over });

  it("sends one notification per event to the right supplier, then marks exactly those delivered", async () => {
    const notify = jest.fn(async () => ({ sent: true }));
    const events = [ev({ event_sno: 1, vendor_sno: 122 }), ev({ event_sno: 2, event_kind: "PAY_PAID", ref_no: "PAY-9", vendor_sno: 106 })];

    const r = await sweepSupplierEvents({ getPool: async () => poolReturning(events), notify });

    expect(r).toEqual({ found: 2, sent: 2, skipped: 0, failed: 0 });
    expect(notify).toHaveBeenCalledTimes(2);
    expect(notify.mock.calls[0][0]).toMatchObject({ supplier_sno: 122, title: "Debit note raised" });
    expect(notify.mock.calls[1][0]).toMatchObject({ supplier_sno: 106, title: "Payment made" });
    const mark = executed.find((e) => e.proc === "sp_nt_MarkSupplierEventsDelivered");
    expect(JSON.parse(mark.params.jsonInput)).toEqual({ event_snos: [1, 2] });
  });

  it("does NOT mark an event delivered when its notification failed - it is retried after the lease", async () => {
    const notify = jest.fn()
      .mockResolvedValueOnce({ sent: false, reason: "notification-service HTTP 503" })
      .mockResolvedValueOnce({ sent: true });
    const events = [ev({ event_sno: 1 }), ev({ event_sno: 2, ref_no: "DN-2" })];
    jest.spyOn(console, "error").mockImplementation(() => {});

    const r = await sweepSupplierEvents({ getPool: async () => poolReturning(events), notify });

    expect(r).toMatchObject({ sent: 1, failed: 1 });
    const mark = executed.find((e) => e.proc === "sp_nt_MarkSupplierEventsDelivered");
    expect(JSON.parse(mark.params.jsonInput).event_snos).toEqual([2]);
  });

  it("closes an event with nothing to say without sending anything", async () => {
    const notify = jest.fn(async () => ({ sent: true }));
    const r = await sweepSupplierEvents({ getPool: async () => poolReturning([ev({ event_sno: 7, ref_no: null })]), notify });

    expect(notify).not.toHaveBeenCalled();
    expect(r).toMatchObject({ skipped: 1, sent: 0 });
    expect(JSON.parse(executed.find((e) => e.proc === "sp_nt_MarkSupplierEventsDelivered").params.jsonInput).event_snos).toEqual([7]);
  });

  it("does nothing - not even the mark call - when there is nothing pending", async () => {
    const notify = jest.fn();
    const r = await sweepSupplierEvents({ getPool: async () => poolReturning([]), notify });
    expect(r).toEqual({ found: 0, sent: 0, skipped: 0, failed: 0 });
    expect(notify).not.toHaveBeenCalled();
    expect(executed.map((e) => e.proc)).toEqual(["sp_nt_GetPendingSupplierEvents"]);
  });

  it("lets a database failure propagate so the loop can log it once", async () => {
    await expect(sweepSupplierEvents({ getPool: async () => { throw new Error("db down"); }, notify: jest.fn() })).rejects.toThrow("db down");
  });
});
