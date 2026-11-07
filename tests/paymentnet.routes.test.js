// paymentnet.routes.js - the HTTP edge of the Payment screens: which bills the notes lookup is asked about, the live
// payment:released / payment:updated broadcasts, the approval and cancel calls, the Payment Run list and the payment file.
// Which bill may redeem which debit / credit note, and the approval / MSME / fund rules, are decided in SQL (sql/64, sql/65)
// and are exercised against the database, not here.
import { describe, it, expect, jest, beforeAll, afterAll, beforeEach } from "@jest/globals";
import express from "express";

const input = jest.fn();
const execute = jest.fn();
const schema = { c: 1, p: 1, n: 1, t: 1 };               // what the database says about the sql/68 objects
const query = jest.fn(async () => ({ recordset: [schema] }));
const request = { input, execute, query };
input.mockReturnValue(request);
const broadcast = jest.fn();
const createInAppNotification = jest.fn(async () => ({ sent: true }));

jest.unstable_mockModule("../src/config/db.js", () => ({
  initializeDatabase: async () => ({ request: () => request }),
}));
jest.unstable_mockModule("../src/paymentnet/bankFileLayout.js", async () => {
  const { STD_LAYOUT } = await import("./fixtures/standardLayout.js");
  return { loadBankFileLayout: async () => STD_LAYOUT };
});
jest.unstable_mockModule("../src/utils/socketBroadcast.js", () => ({ broadcast }));
jest.unstable_mockModule("../src/utils/notifyClient.js", () => ({ createInAppNotification }));
// the org scope of the caller: a user who may see company 1 only
const hierarchy = [{ com_sno: 1, div_sno: null, brn_sno: null }];
jest.unstable_mockModule("../src/middleware/hierarchyScope.js", () => ({
  attachHierarchyScope: (req, _res, next) => { req.hierarchyJson = hierarchy; next(); },
  orgRoomTargets: (domain, { com_sno, div_sno, brn_sno, dept_sno } = {}) => {
    if (com_sno == null) return [`${domain}:live`];
    const rooms = [`${domain}:live:com:${com_sno}`];
    if (div_sno != null) { rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}`);
      if (brn_sno != null) { rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}:brn:${brn_sno}`);
        if (dept_sno != null) rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}:brn:${brn_sno}:dept:${dept_sno}`); } }
    return rooms;
  },
}));

const { default: PaymentNetRouter } = await import("../src/paymentnet/paymentnet.routes.js");

let server;
let base;
beforeAll(async () => {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => { req.user = { ecno: "TEST001" }; next(); });
  app.use("/api/payment_net", PaymentNetRouter);
  server = app.listen(0);
  base = `http://127.0.0.1:${server.address().port}/api/payment_net`;
});
afterAll(() => new Promise((resolve) => server.close(resolve)));

const getJson = async (path) => (await fetch(base + path)).json();
const postJson = async (path, body) =>
  (await fetch(base + path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })).json();
const sentTo = (proc) => {
  const i = execute.mock.calls.findIndex(([p]) => p === proc);
  return i < 0 ? null : JSON.parse(input.mock.calls[i][2]);
};

beforeEach(() => {
  execute.mockReset();
  input.mockClear();
  broadcast.mockClear();
  createInAppNotification.mockClear();
});

describe("GET /adjustments", () => {
  beforeEach(() => {
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentAdjustments"
      ? { recordsets: [[], [{ note_sno: 7, note_no: "DN-7", scope: "OWN" }], []], recordset: [] }
      : { recordset: [], recordsets: [[]] }));
  });

  it("asks about the invoices being paid - cleaned and de-duplicated - not just the supplier", async () => {
    const res = await getJson("/adjustments?vendor_sno=107&invoice_snos=12,14,14,abc,,-3,0,15.5");
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_GetPaymentAdjustments")).toEqual({ vendor_sno: 107, invoice_snos: [12, 14] });
    expect(res.data.debitNotes).toEqual([{ note_sno: 7, note_no: "DN-7", scope: "OWN" }]);
  });

  it("without invoice_snos passes an empty list (the procedure then offers no note)", async () => {
    await getJson("/adjustments?vendor_sno=107");
    expect(sentTo("sp_nt_GetPaymentAdjustments")).toEqual({ vendor_sno: 107, invoice_snos: [] });
  });
});

describe("POST /release", () => {
  const body = {
    vendor_sno: "107", mode: "NEFT",
    allocations: [{ invoice_alloc_sno: 17, amount: 1000 }, { invoice_alloc_sno: 18, amount: 500 }],
    notes: [{ type: "debit", note_sno: "9" }, { type: "CREDIT", note_sno: 3 }],
  };
  const released = { payment_sno: 55, payment_no: "PAY-2026-000099", net_paid: 1200, result: "SUCCESS", com_sno: 1, div_sno: 3, brn_sno: 4, dept_sno: 16 };

  it("tells the payment's org rooms what was redeemed, once the payment is committed", async () => {
    execute.mockResolvedValue({ recordset: [released], recordsets: [[released]] });

    const res = await postJson("/release", body);

    expect(res.success).toBe(true);
    expect(res.data.payment_no).toBe("PAY-2026-000099");
    expect(sentTo("sp_nt_ReleasePaymentNet")).toMatchObject({ vendor_sno: "107", created_by: "TEST001", preview: false });
    const released_ = broadcast.mock.calls.filter(([, e]) => e === "payment:released");
    expect(released_).toHaveLength(1);
    const [rooms, event, payload] = released_[0];
    expect(event).toBe("payment:released");
    expect(rooms).toEqual([
      "payment:live:com:1", "payment:live:com:1:div:3", "payment:live:com:1:div:3:brn:4", "payment:live:com:1:div:3:brn:4:dept:16",
    ]);
    expect(payload).toEqual({
      payment_sno: 55, payment_no: "PAY-2026-000099", vendor_sno: 107, bill_snos: [17, 18],
      notes: [{ type: "DEBIT", note_sno: 9 }, { type: "CREDIT", note_sno: 3 }],
    });
  });

  it("tells the approver a saved payment is waiting for them, and nobody when it was approved at once", async () => {
    execute.mockResolvedValue({ recordset: [{ ...released, status: "Pending Approval", current_approver_id: "KTM1004" }], recordsets: [[]] });
    await postJson("/release", body);
    expect(createInAppNotification).toHaveBeenCalledTimes(1);
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "KTM1004", title: "Payment awaiting your approval", data: { kind: "payment", payment_sno: 55 } });
    expect(broadcast.mock.calls.some(([, e, p]) => e === "payment:updated" && p.status === "Pending Approval")).toBe(true);

    createInAppNotification.mockClear();
    execute.mockResolvedValue({ recordset: [{ ...released, status: "Approved", current_approver_id: null }], recordsets: [[]] });
    await postJson("/release", body);
    expect(createInAppNotification).not.toHaveBeenCalled();
  });

  it("does not broadcast when the release fails (e.g. a note another payment just redeemed)", async () => {
    execute.mockRejectedValue(new Error("Already redeemed in another payment - refresh and untick it: DN-7 (PAY-2026-000098)"));

    const res = await postJson("/release", body);

    expect(res.success).toBe(false);
    expect(res.error).toMatch(/Already redeemed/);
    expect(broadcast).not.toHaveBeenCalled();
  });

  it("does not broadcast a preview", async () => {
    execute.mockResolvedValue({ recordsets: [[{ gross_amount: 1500, net_paid: 1200 }], []], recordset: [] });

    const res = await postJson("/preview", body);

    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_ReleasePaymentNet")).toMatchObject({ preview: true });
    expect(broadcast).not.toHaveBeenCalled();
  });
});

describe("approval", () => {
  const decided = (over = {}) => ({ result: "FINAL", payment_sno: 55, payment_no: "PAY-2026-000099", vendor_sno: 107, net_paid: 1200, created_by: "SAVER01", next_approver: null, status: "Approved", com_sno: 1, div_sno: 3, brn_sno: 4, dept_sno: 16, ...over });

  it("approves as the caller (an approver cannot name someone else) and tells the creator it is waiting in the Payment Run", async () => {
    execute.mockResolvedValue({ recordset: [decided()], recordsets: [[decided()]] });
    const res = await postJson("/approve", { payment_sno: "55", action: "approve", comments: "ok", approved_by: "SOMEONE_ELSE" });
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_ApprovePayment")).toEqual({ payment_sno: 55, action: "approve", comments: "ok", approved_by: "TEST001" });
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "SAVER01", type: "success", title: "Payment approved" });
    expect(broadcast.mock.calls[0][1]).toBe("payment:updated");
  });

  it("passes a payment on to the next approver", async () => {
    execute.mockResolvedValue({ recordset: [decided({ result: "APPROVED_NEXT", next_approver: "KTM1148", status: "Pending Approval" })], recordsets: [[]] });
    await postJson("/approve", { payment_sno: 55, action: "approve" });
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "KTM1148", title: "Payment awaiting your approval" });
  });

  it("forward names the stage it goes to (as a number) and tells that stage's approver who sent it and why", async () => {
    execute.mockResolvedValue({ recordset: [decided({ result: "FORWARDED", next_approver: "KTM1006", status: "Pending Approval", next_seq: 1 })], recordsets: [[]] });
    const res = await postJson("/approve", { payment_sno: 55, action: "forward", target_seq: "1", comments: "please look at this one" });
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_ApprovePayment")).toEqual({ payment_sno: 55, action: "forward", comments: "please look at this one", target_seq: 1, approved_by: "TEST001" });
    expect(createInAppNotification).toHaveBeenCalledTimes(1);
    const n = createInAppNotification.mock.calls[0][0];
    expect(n).toMatchObject({ ecno: "KTM1006", type: "info", title: "Payment forwarded to you", data: { kind: "payment", payment_sno: 55 } });
    expect(n.message).toMatch(/TEST001/);
    expect(n.message).toMatch(/please look at this one/);
    expect(broadcast.mock.calls[0][1]).toBe("payment:updated");
  });

  it("send back to the first stage keeps target_seq 0 (not dropped as 'empty') and warns the approver it goes back to", async () => {
    execute.mockResolvedValue({ recordset: [decided({ result: "SENT_BACK", next_approver: "NSU00002", status: "Pending Approval", next_seq: 0 })], recordsets: [[]] });
    await postJson("/approve", { payment_sno: 55, action: "send_back", target_seq: 0, comments: "bank account looks wrong" });
    expect(sentTo("sp_nt_ApprovePayment")).toMatchObject({ action: "send_back", target_seq: 0, comments: "bank account looks wrong" });
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "NSU00002", type: "warning", title: "Payment sent back to you" });
    expect(createInAppNotification.mock.calls[0][0].message).toMatch(/bank account looks wrong/);
  });

  it("a forward or send back tells nobody else - not the creator of the payment", async () => {
    execute.mockResolvedValue({ recordset: [decided({ result: "FORWARDED", next_approver: "KTM1006", status: "Pending Approval" })], recordsets: [[]] });
    await postJson("/approve", { payment_sno: 55, action: "forward", target_seq: 1 });
    expect(createInAppNotification.mock.calls.map(([n]) => n.ecno)).toEqual(["KTM1006"]);
  });

  it("an approve or reject sends no target_seq, and a stage that is not a number is refused before the database", async () => {
    execute.mockResolvedValue({ recordset: [decided()], recordsets: [[]] });
    await postJson("/approve", { payment_sno: 55, action: "approve", target_seq: null });
    expect(sentTo("sp_nt_ApprovePayment")).not.toHaveProperty("target_seq");
    execute.mockClear();
    input.mockClear();
    for (const bad of ["x", -1, 1.5]) {
      const res = await postJson("/approve", { payment_sno: 55, action: "forward", target_seq: bad });
      expect(res.success).toBe(false);
      expect(res.error).toMatch(/target_seq/);
    }
    expect(execute).not.toHaveBeenCalled();
  });

  it("the SQL reasons for a refused forward / send back reach the screen as they are", async () => {
    execute.mockRejectedValue(new Error("You can send back only to an approver who has already acted on this payment."));
    const res = await postJson("/approve", { payment_sno: 55, action: "send_back", target_seq: 1, comments: "x" });
    expect(res.success).toBe(false);
    expect(res.error).toMatch(/already acted/);
    expect(createInAppNotification).not.toHaveBeenCalled();
    expect(broadcast).not.toHaveBeenCalled();
  });

  it("a rejection carries the reason to the creator", async () => {
    execute.mockResolvedValue({ recordset: [decided({ result: "REJECTED", status: "Rejected" })], recordsets: [[]] });
    await postJson("/approve", { payment_sno: 55, action: "reject", comments: "wrong bank" });
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "SAVER01", type: "warning", title: "Payment rejected" });
    expect(createInAppNotification.mock.calls[0][0].message).toMatch(/wrong bank/);
  });

  it("rejects a call without a payment, and shows the SQL error when the caller is not the approver", async () => {
    expect((await postJson("/approve", { action: "approve" })).error).toMatch(/payment_sno/);
    execute.mockRejectedValue(new Error("You are not the current approver of this payment."));
    const res = await postJson("/approve", { payment_sno: 55, action: "approve" });
    expect(res.success).toBe(false);
    expect(res.error).toMatch(/not the current approver/);
    expect(createInAppNotification).not.toHaveBeenCalled();
  });

  it("cancel needs a payment, records who cancelled, and tells the creator and the waiting approver", async () => {
    expect((await postJson("/cancel", { reason: "x" })).success).toBe(false);
    const cancelled = { result: "CANCELLED", payment_sno: 55, payment_no: "PAY-2026-000099", net_paid: 1200, created_by: "SAVER01", was_waiting_on: "KTM1004", was_status: "Pending Approval", status: "Cancelled", com_sno: 1 };
    execute.mockResolvedValue({ recordset: [cancelled], recordsets: [[cancelled]] });
    const res = await postJson("/cancel", { payment_sno: 55, reason: "duplicate entry" });
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_CancelPayment")).toEqual({ payment_sno: 55, cancelled_by: "TEST001", reason: "duplicate entry" });
    expect(createInAppNotification.mock.calls.map(([n]) => n.ecno).sort()).toEqual(["KTM1004", "SAVER01"]);
  });
});

describe("POST /revise - the approver pays less now (sql/70)", () => {
  const revised = { payment_sno: 55, payment_no: "PAY-2026-000099", net_paid: 600, status: "Pending Approval", created_by: "SAVER01", com_sno: 1, div_sno: 3, brn_sno: 4, dept_sno: 16 };
  beforeEach(() => { execute.mockResolvedValue({ recordset: [revised], recordsets: [[revised]] }); });

  it("revises as the caller, per invoice, tells the live screens and the person who saved the payment", async () => {
    const res = await postJson("/revise", { payment_sno: "55", reason: "  cash is tight  ", revised_by: "SOMEONE_ELSE", allocations: [{ invoice_sno: "12", amount: "600" }, { invoice_sno: 14, amount: 0 }] });
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_RevisePayment")).toEqual({ payment_sno: 55, revised_by: "TEST001", reason: "cash is tight", allocations: [{ invoice_sno: 12, amount: 600 }, { invoice_sno: 14, amount: 0 }] });
    expect(broadcast.mock.calls[0][1]).toBe("payment:updated");
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "SAVER01", title: "Payment reduced" });
  });

  it("needs a payment, a reason and an amount for each invoice before touching the database", async () => {
    expect((await postJson("/revise", { reason: "x", allocations: [{ invoice_sno: 1, amount: 1 }] })).error).toMatch(/payment_sno/);
    expect((await postJson("/revise", { payment_sno: 55, reason: "  ", allocations: [{ invoice_sno: 1, amount: 1 }] })).error).toMatch(/reason/);
    expect((await postJson("/revise", { payment_sno: 55, reason: "x", allocations: [] })).success).toBe(false);
    expect((await postJson("/revise", { payment_sno: 55, reason: "x", allocations: [{ invoice_sno: 1, amount: -5 }] })).success).toBe(false);
    expect((await postJson("/revise", { payment_sno: 55, reason: "x", allocations: [{ invoice_sno: "a", amount: 5 }] })).success).toBe(false);
    expect(execute).not.toHaveBeenCalled();
  });

  it("shows the SQL reason (not the approver, can only reduce, ...) and broadcasts nothing", async () => {
    execute.mockRejectedValue(new Error("Only the approver this payment is with can pay less now."));
    const res = await postJson("/revise", { payment_sno: 55, reason: "x", allocations: [{ invoice_sno: 1, amount: 1 }] });
    expect(res).toEqual({ success: false, error: "Only the approver this payment is with can pay less now." });
    expect(broadcast).not.toHaveBeenCalled();
  });
});

describe("GET /entries", () => {
  it("asks for the Payment Run list under the caller's org scope, and returns the settings as a map", async () => {
    execute.mockResolvedValue({
      recordsets: [[{ payment_no: "PAY-1", msme_tier: 1 }], [{ payment_sno: 1, invoice_no: "INV-1" }], [{ setting_key: "MSME_LIMIT_DAYS", setting_value: "45" }]], recordset: [],
    });
    const res = await getJson("/entries?view=run&com_sno=1&vendor_sno=abc");
    expect(sentTo("sp_nt_GetPaymentEntries")).toEqual({ view: "run", ecno: "TEST001", hierarchy, com_sno: 1 });
    expect(res.data).toEqual({ entries: [{ payment_no: "PAY-1", msme_tier: 1 }], lines: [{ payment_sno: 1, invoice_no: "INV-1" }], settings: { MSME_LIMIT_DAYS: "45" } });
  });

  it("an unknown view falls back to the run list; the approval views are 'mine' and 'all'", async () => {
    execute.mockResolvedValue({ recordsets: [[], [], []], recordset: [] });
    await getJson("/entries?view=everything");
    expect(sentTo("sp_nt_GetPaymentEntries").view).toBe("run");
    execute.mockClear();
    input.mockClear();
    await getJson("/entries?view=mine");
    expect(sentTo("sp_nt_GetPaymentEntries").view).toBe("mine");
  });

  it("a supplier paid on its own portal carries the payment instructions from its KYC; bank payments are left as they are", async () => {
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentEntries"
      ? { recordset: [], recordsets: [[
          { payment_sno: 51, vendor_sno: 122, pay_via_portal: true, payment_portal_name: "Acme Pay", payment_portal_url: "https://pay.acme.example" },
          { payment_sno: 52, vendor_sno: 7, pay_via_portal: false, payment_portal_name: null, payment_portal_url: null },
          { payment_sno: 53, vendor_sno: 130, pay_via_portal: true, payment_portal_name: "Beta", payment_portal_url: "beta.example" },
        ], [], []] }
      : { recordset: [], recordsets: [[]] }));
    query.mockImplementationOnce(async () => ({ recordset: [{ vendor_sno: 122, payment_instructions: "Pay with the invoice no. as reference" }] }));
    const res = await getJson("/entries?view=run");
    expect(input.mock.calls.find(([name]) => name === "vendors")[2]).toBe("[122,130]");   // only the portal suppliers are looked up
    const [acme, bank, beta] = res.data.entries;
    expect(acme.payment_instructions).toBe("Pay with the invoice no. as reference");
    expect(beta.payment_instructions).toBeNull();                 // portal supplier that gave no instructions
    expect(bank).not.toHaveProperty("payment_instructions");
  });

  it("a portal supplier whose details the payments team changed (sql/91) says who did it last", async () => {
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentEntries"
      ? { recordset: [], recordsets: [[
          { payment_sno: 51, vendor_sno: 107, pay_via_portal: true, payment_portal_name: "AWS Billing", payment_portal_url: "https://console.aws.amazon.com/billing" },
          { payment_sno: 53, vendor_sno: 130, pay_via_portal: true, payment_portal_name: "Beta", payment_portal_url: "https://beta.example" },
        ], [], []] }
      : { recordset: [], recordsets: [[]] }));
    query.mockImplementationOnce(async () => ({
      recordset: [], recordsets: [
        [{ vendor_sno: 107, payment_instructions: "Pay by card" }, { vendor_sno: 130, payment_instructions: null }],
        [{ vendor_sno: 107, portal_edited_by: "KTM1148", portal_edited_at: "2026-11-06T13:10:00.000Z" }],
      ],
    }));
    const [aws, beta] = (await getJson("/entries?view=run")).data.entries;
    expect(aws).toMatchObject({ payment_instructions: "Pay by card", portal_edited_by: "KTM1148", portal_edited_at: "2026-11-06T13:10:00.000Z" });
    expect(beta).not.toHaveProperty("portal_edited_by");
  });

  it("the Payment Run list still loads when the portal instructions cannot be read", async () => {
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentEntries"
      ? { recordset: [], recordsets: [[{ payment_sno: 51, vendor_sno: 122, pay_via_portal: true, payment_portal_name: "Acme Pay" }], [], []] }
      : { recordset: [], recordsets: [[]] }));
    query.mockImplementationOnce(async () => { throw new Error("Invalid column name 'payment_instructions'."); });
    const res = await getJson("/entries?view=run");
    expect(res.success).toBe(true);
    expect(res.data.entries[0]).toMatchObject({ payment_sno: 51, payment_portal_name: "Acme Pay" });
    expect(res.data.entries[0]).not.toHaveProperty("payment_instructions");
  });

  it("one payment's detail is 404 when it is not visible to the caller", async () => {
    execute.mockResolvedValue({ recordsets: [[], [], []], recordset: [] });
    const res = await fetch(`${base}/entries/77`);
    expect(res.status).toBe(404);
    expect((await fetch(`${base}/entries/abc`)).status).toBe(400);
  });

  it("one payment's detail joins its lines, trail, adjustments and approver chain", async () => {
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentEntries"
      ? { recordsets: [[{ payment_sno: 77, status: "Approved" }], [{ payment_sno: 77, invoice_no: "INV-9" }], []], recordset: [] }
      : { recordsets: [[{ action_type: "APPROVED" }], [{ adj_type: "TDS", amount: 10 }], [{ seq: 0, approver_ecno: "KTM1004" }]], recordset: [] }));
    const res = await getJson("/entries/77");
    expect(sentTo("sp_nt_GetPaymentEntries")).toMatchObject({ view: "all", payment_sno: 77, ecno: "TEST001", hierarchy });
    expect(res.data.entry.status).toBe("Approved");
    expect(res.data.lines).toHaveLength(1);
    expect(res.data.history[0].action_type).toBe("APPROVED");
    expect(res.data.adjustments[0].adj_type).toBe("TDS");
    expect(res.data.stages[0].approver_ecno).toBe("KTM1004");
    expect(res.data.approval).toEqual({ summary: null, forward_targets: [], send_back_targets: [], log: [], condition_fields: [] });   // nothing awaiting approval: nothing to do
  });

  it("the detail asks the approval context as the caller and returns what they may do and where each action can go", async () => {
    const summary = { payment_sno: 77, payment_status: "Pending Approval", current_seq: 0, can_approve: true, can_forward: true, can_send_back: false, my_role: "PRIMARY", amount: 86400 };
    const stages = [
      { seq: 0, stage_name: "IA Approval", approver_ecno: "NSU00002", state: "CURRENT", condition_met: true },
      { seq: 1, stage_name: "Admin Approval", approver_ecno: "KTM1006", state: "UPCOMING", condition_met: true, condition_json: '{"match":"all","rules":[{"field":"amount","op":"gt","value":50000}]}' },
    ];
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentEntries"
      ? { recordsets: [[{ payment_sno: 77, status: "Pending Approval" }], []], recordset: [] }
      : { recordsets: [[], [], stages, [summary], [{ seq: 1, stage_name: "Admin Approval", approver_ecno: "KTM1006", required_by_rule: true }], [], [{ action: "SUBMITTED" }], [{ field_key: "amount", label: "Amount (net payable)" }]], recordset: [] }));
    const res = await getJson("/entries/77");
    expect(sentTo("sp_nt_GetPaymentActivity")).toEqual({ payment_sno: 77, ecno: "TEST001" });
    expect(res.data.stages.map((s) => s.state)).toEqual(["CURRENT", "UPCOMING"]);
    expect(res.data.approval.summary).toMatchObject({ can_approve: true, can_forward: true, can_send_back: false, my_role: "PRIMARY" });
    expect(res.data.approval.forward_targets).toEqual([{ seq: 1, stage_name: "Admin Approval", approver_ecno: "KTM1006", required_by_rule: true }]);
    expect(res.data.approval.send_back_targets).toEqual([]);
    expect(res.data.approval.log).toEqual([{ action: "SUBMITTED" }]);
    expect(res.data.approval.condition_fields[0].field_key).toBe("amount");
  });
});

describe("POST /run/proceed", () => {
  // what sp_nt_CreatePaymentBatch returns for a run paid from the company's HDFC account (sql/68)
  const batch = {
    batch_sno: 5, batch_no: "PB-2026-000005", batch_date: new Date("2026-10-22T00:00:00.000Z"), com_sno: 1, total_amount: 1500,
    file_name: "SPACETEX_SPA311_SPA3112210.100", payment_bank_sno: 3, file_type: "BANK_UPLOAD", sender_client_code: "SPA311",
    sender_alert_email: "payment.ktm@scmts.net", sender_bank_name: "HDFC BANK LIMITED", sender_account_no: "50200012345678",
  };
  const items = [
    { payment_sno: 55, payment_no: "PAY-55", line_no: 1, vendor_sno: 122, channel: "BANK", mode: "NEFT", amount: 1000, beneficiary_name: "NEO", account_no: "123", ifsc: "KKBK0000961", bank_name: "KOTAK", branch_name: "SURAT", com_sno: 1, div_sno: 3, brn_sno: 4, dept_sno: 16 },
    { payment_sno: 56, payment_no: "PAY-56", line_no: 2, vendor_sno: 9, channel: "MANUAL", mode: "Cheque", amount: 500, vendor_name: "ABC", com_sno: 1, div_sno: 3, brn_sno: 4, dept_sno: 16 },
  ];
  const created = (b = batch, rows = items) => async (proc) => (proc === "sp_nt_CreatePaymentBatch"
    ? { recordsets: [[b], rows], recordset: [] }
    : { recordset: [], recordsets: [[]] });
  beforeEach(() => { execute.mockImplementation(created()); });

  // first on purpose: the route remembers a positive answer about the schema, a negative one is asked again every time
  it("a database without sql/68 is refused BEFORE anything is paid (503) - no run procedure is called", async () => {
    schema.c = null;
    const res = await fetch(`${base}/run/proceed`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ payment_snos: [55], fund_plan_amount: 5000 }) });
    expect(res.status).toBe(503);
    expect((await res.json()).error).toMatch(/sql\/68/);
    expect(execute).not.toHaveBeenCalled();
    schema.c = 1;
  });

  it("creates the run under the caller's scope from the chosen bank account, writes the bank file, keeps it and returns it for download", async () => {
    const res = await postJson("/run/proceed", { payment_snos: [55, "56"], fund_plan_amount: "5000000", payment_date: "2026-10-23", payment_bank_sno: "3" });
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_CreatePaymentBatch")).toEqual({ payment_snos: [55, 56], fund_plan_amount: 5000000, payment_date: "2026-10-23", payment_bank_sno: 3, created_by: "TEST001", hierarchy });
    expect(res.data.file.file_name).toBe("SPACETEX_SPA311_SPA3112210.100");       // named by the run, not by the screen
    expect(res.data.file.mime_type).toBe("text/plain;charset=utf-8");
    expect(res.data.file.line_count).toBe(1);
    expect(res.data.file.total_amount).toBe(1000);
    const [line] = res.data.file.content.split("\n");
    expect(line.split(",")).toHaveLength(28);
    expect(line).toBe("N,,123,1000.00,NEO,,,,,,,,,122-PAY55,,,,,,,,,22/10/2026,,KKBK0000961,KOTAK,SURAT,");
    expect(res.data.file.content).not.toMatch(/PAY-56|PAY56/);                    // a cheque is not a bank transfer
    expect(res.data.skipped.map((s) => s.payment_no)).toEqual(["PAY-56"]);
    expect(sentTo("sp_nt_SetPaymentBatchFile")).toMatchObject({ batch_sno: 5, file_name: "SPACETEX_SPA311_SPA3112210.100", file_content: res.data.file.content });
    const ev = broadcast.mock.calls.find(([, e]) => e === "payment:updated");
    expect(ev[2]).toMatchObject({ status: "Processed", batch_no: "PB-2026-000005", payment_snos: [55, 56] });
  });

  it("never sends the sender's full account number to the browser - only its last 4 digits", async () => {
    const res = await postJson("/run/proceed", { payment_snos: [55], fund_plan_amount: 5000 });
    expect(res.data.batch).not.toHaveProperty("sender_account_no");
    expect(res.data.batch).toMatchObject({ sender_ac_last4: "5678", sender_bank_name: "HDFC BANK LIMITED", file_name: "SPACETEX_SPA311_SPA3112210.100" });
    expect(JSON.stringify(res)).not.toContain("50200012345678");
  });

  it("without a chosen account the database picks the company's default (no payment_bank_sno is sent)", async () => {
    await postJson("/run/proceed", { payment_snos: [55], fund_plan_amount: 5000, payment_bank_sno: "" });
    expect(sentTo("sp_nt_CreatePaymentBatch")).not.toHaveProperty("payment_bank_sno");
    execute.mockClear();
    input.mockClear();
    await postJson("/run/proceed", { payment_snos: [55], fund_plan_amount: 5000 });
    expect(sentTo("sp_nt_CreatePaymentBatch")).not.toHaveProperty("payment_bank_sno");
  });

  it("refuses an account that is not a number before touching the database", async () => {
    const res = await postJson("/run/proceed", { payment_snos: [55], fund_plan_amount: 5000, payment_bank_sno: "abc" });
    expect(res.success).toBe(false);
    expect(res.error).toMatch(/bank account/);
    expect(execute).not.toHaveBeenCalled();
  });

  it("a run with nothing to upload (cheque only) has no file: nothing is stored and the screen is told line_count 0", async () => {
    const noFile = { ...batch, file_name: null, payment_bank_sno: null, file_type: null, sender_client_code: null, sender_alert_email: null, sender_bank_name: null, sender_account_no: null };
    execute.mockImplementation(created(noFile, [items[1]]));
    const res = await postJson("/run/proceed", { payment_snos: [56], fund_plan_amount: 5000 });
    expect(res.success).toBe(true);
    expect(res.data.file).toMatchObject({ file_name: "", content: "", line_count: 0 });
    expect(sentTo("sp_nt_SetPaymentBatchFile")).toBeNull();
    expect(res.data.batch.sender_ac_last4).toBeNull();
  });

  it("UPI and other modes the bank file cannot carry are listed as 'pay separately', not written", async () => {
    execute.mockImplementation(created(batch, [items[0], { ...items[0], payment_sno: 57, payment_no: "PAY-57", mode: "UPI", line_no: 3 }]));
    const res = await postJson("/run/proceed", { payment_snos: [55, 57], fund_plan_amount: 5000 });
    expect(res.data.file.line_count).toBe(1);
    expect(res.data.skipped).toEqual([expect.objectContaining({ payment_no: "PAY-57", channel: "BANK", reason: expect.stringMatching(/UPI/) })]);
  });

  it("refuses an empty selection, a missing fund plan and junk ids before touching the database", async () => {
    expect((await postJson("/run/proceed", { payment_snos: [], fund_plan_amount: 100 })).error).toMatch(/at least one/);
    expect((await postJson("/run/proceed", { payment_snos: [55], fund_plan_amount: 0 })).error).toMatch(/fund plan/);
    expect((await postJson("/run/proceed", { payment_snos: [55, "x"], fund_plan_amount: 100 })).success).toBe(false);
    expect(execute).not.toHaveBeenCalled();
  });

  it("shows the SQL reason when the selection no longer fits (fund, already paid, missing bank details, no sender account) and broadcasts nothing", async () => {
    execute.mockRejectedValue(new Error("The selected payments total 6,000.00, more than the fund plan of 5,000.00."));
    const res = await postJson("/run/proceed", { payment_snos: [55], fund_plan_amount: 5000 });
    expect(res.success).toBe(false);
    expect(res.error).toMatch(/fund plan/);
    expect(broadcast).not.toHaveBeenCalled();

    execute.mockRejectedValue(new Error("No bank account to pay from is set up for this company. Add one in Masters > Payment Bank, then run again."));
    const noBank = await postJson("/run/proceed", { payment_snos: [55], fund_plan_amount: 5000 });
    expect(noBank.error).toMatch(/Masters > Payment Bank/);
    expect(broadcast).not.toHaveBeenCalled();
  });

  it("if the file cannot be written after the payments were paid, says so plainly instead of reporting a plain failure", async () => {
    execute.mockImplementation(async (proc) => {
      if (proc === "sp_nt_CreatePaymentBatch") return { recordsets: [[batch], items], recordset: [] };
      throw new Error("disk full");
    });
    const res = await postJson("/run/proceed", { payment_snos: [55], fund_plan_amount: 5000 });
    expect(res.success).toBe(false);
    expect(res.error).toMatch(/PB-2026-000005 was created, but its file could not be written: disk full/);
  });

  it("a past run's file: stored text is returned as is - a bank file as plain text, an older CSV as CSV", async () => {
    const stored = (b) => async (proc) => (proc === "sp_nt_GetPaymentBatches" ? { recordsets: [[b], []], recordset: [] } : { recordset: [], recordsets: [[]] });
    execute.mockImplementation(stored({ ...batch, file_content: "N,,123\n" }));
    expect((await getJson("/run/batches/5/file")).data).toEqual({ file_name: "SPACETEX_SPA311_SPA3112210.100", mime_type: "text/plain;charset=utf-8", content: "N,,123\n" });
    execute.mockImplementation(stored({ ...batch, file_type: null, file_name: "PaymentFile_PB-2026-000001_2026-10-22.csv", file_content: "a,b\r\n" }));
    expect((await getJson("/run/batches/5/file")).data).toEqual({ file_name: "PaymentFile_PB-2026-000001_2026-10-22.csv", mime_type: "text/csv;charset=utf-8", content: "a,b\r\n" });
  });

  it("a bank file that was never stored is written again from the lines and the sender the run remembers, and stored", async () => {
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentBatches"
      ? { recordsets: [[{ ...batch, file_content: null }], items], recordset: [] }
      : { recordset: [], recordsets: [[]] }));
    const rebuilt = (await getJson("/run/batches/5/file")).data;
    expect(rebuilt.file_name).toBe("SPACETEX_SPA311_SPA3112210.100");
    expect(rebuilt.content).toBe("N,,123,1000.00,NEO,,,,,,,,,122-PAY55,,,,,,,,,22/10/2026,,KKBK0000961,KOTAK,SURAT,");
    expect(sentTo("sp_nt_SetPaymentBatchFile")).toMatchObject({ batch_sno: 5, file_name: "SPACETEX_SPA311_SPA3112210.100" });
  });

  it("an older run with no stored file, or a run with no bank transfer, has no file to give (404)", async () => {
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentBatches"
      ? { recordsets: [[{ ...batch, file_type: null, file_name: null, file_content: null }], items], recordset: [] }
      : { recordset: [], recordsets: [[]] }));
    expect((await fetch(`${base}/run/batches/5/file`)).status).toBe(404);
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentBatches"
      ? { recordsets: [[{ ...batch, file_content: null }], [items[1]]], recordset: [] }
      : { recordset: [], recordsets: [[]] }));
    expect((await fetch(`${base}/run/batches/5/file`)).status).toBe(404);
  });

  it("the run carries what each payment paid on each invoice, and the verification sheet comes with it", async () => {
    const lines = [{ batch_item_sno: 1, batch_sno: 5, payment_sno: 55, invoice_sno: 9, invoice_no: "INV-9", supplier_invoice_no: "S-9", invoice_date: "2026-10-02", invoice_amount: 2000, payable_total: 2000, paid_before: 0, this_gross: 1000, tds_amount: 0, balance_after: 1000, awaiting_2b: false, part_no: 1, kind: "PART" }];
    execute.mockImplementation(async (proc) => (proc === "sp_nt_CreatePaymentBatch" ? { recordsets: [[batch], items, lines], recordset: [] } : { recordset: [], recordsets: [[]] }));
    const res = await postJson("/run/proceed", { payment_snos: [55, 56], fund_plan_amount: 5000 });
    expect(res.data.lines).toEqual(lines);
    const f = res.data.file.content.split(",");
    expect(f[14]).toBe("S-9");
    expect(f[15]).toBe("PART 1000.00/2000.00");
    expect(f[27]).toBe("");
    expect(res.data.verification.file_name).toBe("SPACETEX_SPA311_SPA3112210_verification.csv");
    expect(res.data.verification.content).toContain("Part payment");
    expect(res.data.verification.content).toContain("S-9");
  });

  it("a run with nothing to upload has no verification sheet", async () => {
    execute.mockImplementation(created({ ...batch, file_name: null, payment_bank_sno: null, file_type: null }, [items[1]]));
    const res = await postJson("/run/proceed", { payment_snos: [56], fund_plan_amount: 5000 });
    expect(res.data.verification).toBeNull();
  });

  it("a past run's verification sheet is built from its stored invoice lines; a run with no bank transfer has none (404)", async () => {
    const lines = [{ batch_item_sno: 1, payment_sno: 55, invoice_no: "INV-9", supplier_invoice_no: "S-9", invoice_amount: 2000, payable_total: 2000, paid_before: 0, this_gross: 1000, tds_amount: 0, balance_after: 1000, awaiting_2b: false, part_no: 1, kind: "PART" }];
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentBatches" ? { recordsets: [[batch], items, lines], recordset: [] } : { recordset: [], recordsets: [[]] }));
    const res = await getJson("/run/batches/5/verification");
    expect(res.data).toMatchObject({ file_name: "SPACETEX_SPA311_SPA3112210_verification.csv", mime_type: "text/csv;charset=utf-8", line_count: 1, total_amount: 1000 });
    expect(res.data.content).toContain("Part payment");
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetPaymentBatches" ? { recordsets: [[batch], [items[1]], []], recordset: [] } : { recordset: [], recordsets: [[]] }));
    expect((await fetch(`${base}/run/batches/5/verification`)).status).toBe(404);
  });

  it("payment history: asks for up to ?limit= runs (default 30, at most 1000) and lists the suppliers / payments of each run", async () => {
    execute.mockResolvedValue({ recordsets: [[{ batch_sno: 5, batch_no: "PB-5" }, { batch_sno: 6, batch_no: "PB-6" }]], recordset: [] });
    query.mockResolvedValueOnce({ recordset: [{ batch_sno: 5, vendor_names: "NEO\u001fSILVER\u001fNEO", supp_codes: "N1\u001f\u001fN1", payment_nos: "PAY-1\u001fPAY-2\u001fPAY-3" }] });
    const res = await getJson("/run/batches?limit=500");
    expect(sentTo("sp_nt_GetPaymentBatches")).toEqual({ hierarchy, limit: 500 });
    expect(res.data).toEqual([
      { batch_sno: 5, batch_no: "PB-5", vendor_names: ["NEO", "SILVER"], supp_codes: ["N1"], payment_nos: ["PAY-1", "PAY-2", "PAY-3"] },
      { batch_sno: 6, batch_no: "PB-6", vendor_names: [], supp_codes: [], payment_nos: [] },
    ]);
    execute.mockClear(); input.mockClear();
    await getJson("/run/batches?limit=99999");
    expect(sentTo("sp_nt_GetPaymentBatches").limit).toBe(1000);
    execute.mockClear(); input.mockClear();
    query.mockRejectedValueOnce(new Error("no table"));
    const plain = await getJson("/run/batches?limit=abc");
    expect(sentTo("sp_nt_GetPaymentBatches").limit).toBe(30);
    expect(plain.data[0]).toMatchObject({ batch_no: "PB-5", vendor_names: [] });
  });

  it("a run outside the caller's scope is 404", async () => {
    execute.mockResolvedValue({ recordsets: [[], []], recordset: [] });
    expect((await fetch(`${base}/run/batches/9`)).status).toBe(404);
    expect((await fetch(`${base}/run/batches/9/file`)).status).toBe(404);
  });
});

describe("portal payments and TDS records", () => {
  const rec = { txn_sno: 1, payment_sno: 55, payment_no: "PAY-55", net_paid: 1000, txn_mode: "UPI", txn_id: "T1", com_sno: 1, div_sno: 3, brn_sno: 4, dept_sno: 16 };

  it("records the transaction as the caller, under their org scope, and tells the live screens", async () => {
    execute.mockResolvedValue({ recordset: [rec], recordsets: [[rec]] });
    const res = await postJson("/run/portal-payment", { payment_sno: "55", txn_mode: "UPI", txn_id: "T1", txn_date: "2026-10-22", amount_paid: 900, discount_amount: 100, remarks: "r", recorded_by: "SOMEONE" });
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_RecordPortalPayment")).toEqual({ payment_sno: 55, txn_mode: "UPI", txn_id: "T1", txn_date: "2026-10-22", amount_paid: 900, discount_amount: 100, remarks: "r", recorded_by: "TEST001", hierarchy });
    expect(broadcast.mock.calls.find(([, e]) => e === "payment:updated")[2]).toMatchObject({ payment_sno: 55, status: "Processed" });
  });

  it("needs a payment, shows the SQL reason, and broadcasts nothing on failure", async () => {
    expect((await postJson("/run/portal-payment", { txn_id: "T1" })).error).toMatch(/payment_sno/);
    execute.mockRejectedValue(new Error("Amount paid + discount must equal the net amount of 1,000.00 (now 900.00)."));
    const res = await postJson("/run/portal-payment", { payment_sno: 55, txn_mode: "UPI", txn_id: "T1", amount_paid: 900 });
    expect(res.error).toMatch(/must equal the net/);
    expect(broadcast).not.toHaveBeenCalled();
  });

  it("editing portal details says to run sql/91 until it is applied", async () => {
    query.mockImplementationOnce(async () => ({ recordset: [{ p: null }] }));
    const res = await fetch(`${base}/run/portal-details`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ payment_sno: 51, payment_portal_name: "X", payment_portal_url: "https://x.example" }) });
    expect(res.status).toBe(503);
    expect((await res.json()).error).toMatch(/sql\/91/);
    expect(execute).not.toHaveBeenCalled();
  });

  it("changes a portal supplier's portal details as the caller, under their org scope, and tells the live screens", async () => {
    const row = { payment_sno: 51, payment_no: "PAY-51", vendor_sno: 107, payment_portal_name: "AWS Billing", payment_portal_url: "https://console.aws.amazon.com/billing",
      payment_instructions: null, portal_edited_by: "TEST001", com_sno: 1, div_sno: 3, brn_sno: 4, dept_sno: 16 };
    execute.mockResolvedValue({ recordset: [row], recordsets: [[row]] });
    const res = await postJson("/run/portal-details", { payment_sno: "51", payment_portal_name: "AWS Billing", payment_portal_url: "https://console.aws.amazon.com/billing",
      payment_instructions: 42, changed_by: "SOMEONE" });
    expect(res.data).toMatchObject({ portal_edited_by: "TEST001" });
    expect(sentTo("sp_nt_UpdateSupplierPortalDetails")).toEqual({ payment_sno: 51, payment_portal_name: "AWS Billing",
      payment_portal_url: "https://console.aws.amazon.com/billing", changed_by: "TEST001", hierarchy });   // non-text instructions dropped, login from the session
    expect(broadcast.mock.calls.find(([, e]) => e === "payment:updated")[2]).toMatchObject({ payment_sno: 51, status: "Approved", portal_details: true });
  });

  it("editing portal details needs a payment and shows the SQL reason", async () => {
    expect((await postJson("/run/portal-details", { payment_portal_name: "X" })).error).toMatch(/payment_sno/);
    execute.mockRejectedValue(new Error("This supplier is paid by bank transfer, not on a portal - its bank details are changed in KYC."));
    const res = await postJson("/run/portal-details", { payment_sno: 52, payment_portal_name: "X", payment_portal_url: "https://x.example" });
    expect(res.error).toMatch(/bank transfer/);
    expect(broadcast).not.toHaveBeenCalled();
  });

  it("lists recorded portal payments and TDS records under the caller's scope", async () => {
    execute.mockResolvedValue({ recordset: [{ x: 1 }], recordsets: [[{ x: 1 }]] });
    expect((await getJson("/run/portal-payments")).data).toEqual([{ x: 1 }]);
    expect(sentTo("sp_nt_GetPortalPayments")).toEqual({ hierarchy, limit: 50 });
    execute.mockClear(); input.mockClear();
    await getJson("/run/portal-payments?limit=5000");   // Payment history asks for more, capped at 1000
    expect(sentTo("sp_nt_GetPortalPayments")).toEqual({ hierarchy, limit: 1000 });
    await getJson("/tds-records?vendor_sno=122");
    expect(sentTo("sp_nt_GetTdsRecords")).toEqual({ hierarchy, vendor_sno: 122 });
  });

  it("lists who typed which TDS rate (sql/84): one invoice, or the newest entries under the caller's scope", async () => {
    execute.mockResolvedValue({ recordset: [{ log_sno: 3 }], recordsets: [[{ log_sno: 3 }]] });
    expect((await getJson("/tds-rate-log?invoice_sno=64")).data).toEqual([{ log_sno: 3 }]);
    expect(sentTo("sp_nt_GetTdsRateLog")).toEqual({ hierarchy, invoice_sno: 64, limit: 200 });
    execute.mockClear(); input.mockClear();
    await getJson("/tds-rate-log?limit=99999");
    expect(sentTo("sp_nt_GetTdsRateLog")).toEqual({ hierarchy, limit: 1000 });
  });
});

describe("GET /run/senders", () => {
  it("asks for the company/division/branch bank accounts under the caller's org scope and returns them as the database gave them", async () => {
    const senders = [{ payment_bank_sno: 3, com_sno: 1, div_sno: 3, brn_sno: 4, profile_name: "HDFC Current A/c", ac_last4: "5678", file_code: 100, is_default: "Y" }];
    execute.mockResolvedValue({ recordset: senders, recordsets: [senders] });
    const res = await getJson("/run/senders?com_sno=1&div_sno=3&brn_sno=4");
    expect(sentTo("sp_nt_GetPaymentSenders")).toEqual({ com_sno: 1, div_sno: 3, brn_sno: 4, hierarchy });
    expect(res.data).toEqual(senders);
  });

  it("without a usable company it asks for every company the caller may see", async () => {
    execute.mockResolvedValue({ recordset: [], recordsets: [[]] });
    await getJson("/run/senders?com_sno=abc&div_sno=x&brn_sno=0");
    expect(sentTo("sp_nt_GetPaymentSenders")).toEqual({ hierarchy });
  });
});

describe("statutory payments (/statutory)", () => {
  const batchRow = { batch_sno: 9, batch_no: "SB-2026-000001", batch_date: "2026-10-28", kind: "TDS", file_type: "BANK_UPLOAD", file_name: "SPACETEX_SPA311_SPA3112810.1000", sender_account_no: "123456785678", total_amount: 9520 };
  const itemRow = { line_no: 1, amount: 9520, mode: "NEFT", payee_name: "Income Tax Department", account_no: "000111222", ifsc: "SBIN0000001", bank_name: "SBI", branch_name: "Main", reference_no: "CHEN12345A", head_name: "TDS u/s 194LA", period_label: "Oct 2026" };

  it("lists the register of one kind under the caller's org scope, with the GST held until 2B", async () => {
    execute.mockResolvedValue({ recordset: [], recordsets: [[{ stat_sno: 1 }], [{ invoice_no: "INV-1", gst_amount: 18 }]] });
    const res = await getJson("/statutory/payables?kind=gst&status=Open");
    expect(sentTo("sp_nt_GetStatutoryPayables")).toEqual({ kind: "GST", status: "Open", hierarchy });
    expect(res.data).toEqual({ payables: [{ stat_sno: 1 }], gstHeld: [{ invoice_no: "INV-1", gst_amount: 18 }], waiting: [] });
  });

  it("passes on the agreement due dates waiting for an amount (sql/96, 3rd result)", async () => {
    execute.mockResolvedValue({ recordset: [], recordsets: [[], [], [{ cycle_sno: 7, agreement_no: "AGR-2026-0029" }]] });
    const res = await getJson("/statutory/payables?kind=OTHER");
    expect(res.data.waiting).toEqual([{ cycle_sno: 7, agreement_no: "AGR-2026-0029" }]);
  });

  it("enters an agreement due's amount as the caller, rounded to paise, and refuses a bad one before the database", async () => {
    execute.mockResolvedValue({ recordset: [{ stat_sno: 11, cycle_sno: 7 }], recordsets: [[{ stat_sno: 11, cycle_sno: 7 }]] });
    const ok = await postJson("/statutory/dues/amount", { cycle_sno: "7", amount: "48250.505", ref_no: "  CHLN-1 ", narration: " " });
    expect(ok.data).toEqual({ stat_sno: 11, cycle_sno: 7 });
    expect(sentTo("sp_nt_EnterStatutoryAgreementAmount")).toEqual({ cycle_sno: 7, amount: 48250.51, ref_no: "CHLN-1", entered_by: "TEST001", hierarchy });
    execute.mockClear();
    expect((await postJson("/statutory/dues/amount", { cycle_sno: 7, amount: 0 })).error).toMatch(/above zero/);
    expect((await postJson("/statutory/dues/amount", { amount: 5 })).error).toMatch(/cycle_sno/);
    expect(execute).not.toHaveBeenCalled();
  });

  it("skips an agreement due with the caller and the reason", async () => {
    execute.mockResolvedValue({ recordset: [{ cycle_sno: 7 }], recordsets: [[{ cycle_sno: 7 }]] });
    await postJson("/statutory/dues/skip", { cycle_sno: 7, reason: "no bill this month" });
    expect(sentTo("sp_nt_SkipStatutoryAgreementCycle")).toEqual({ cycle_sno: 7, reason: "no bill this month", skipped_by: "TEST001", hierarchy });
  });

  it("an unknown kind or status is simply not filtered on", async () => {
    execute.mockResolvedValue({ recordset: [], recordsets: [[], []] });
    await getJson("/statutory/payables?kind=BOGUS&status=Whatever");
    expect(sentTo("sp_nt_GetStatutoryPayables")).toEqual({ hierarchy });
  });

  it("keys in an amount as the caller, and refuses a missing kind before touching the database", async () => {
    execute.mockResolvedValue({ recordset: [{ stat_sno: 5 }], recordsets: [[{ stat_sno: 5 }]] });
    const ok = await postJson("/statutory/payables", { kind: "OTHER", head_name: "Provident Fund", amount: 1000, com_sno: "1", due_date: "2026-11-15", payee_sno: "2" });
    expect(ok.data).toEqual({ stat_sno: 5 });
    expect(sentTo("sp_nt_AddStatutoryPayable")).toMatchObject({ kind: "OTHER", head_name: "Provident Fund", amount: 1000, com_sno: 1, payee_sno: 2, due_date: "2026-11-15", created_by: "TEST001", hierarchy });
    execute.mockClear();
    const bad = await postJson("/statutory/payables", { head_name: "x", amount: 1 });
    expect(bad.success).toBe(false);
    expect(execute).not.toHaveBeenCalled();
  });

  it("saves a payee with its default / active flags", async () => {
    execute.mockResolvedValue({ recordset: [{ payee_sno: 4 }], recordsets: [[{ payee_sno: 4 }]] });
    await postJson("/statutory/payees", { kind: "TDS", payee_name: "ITD", ac_number: "1", ifsc: "SBIN0000001", is_default: true, is_active: false });
    expect(sentTo("sp_nt_UpsertStatutoryPayee")).toMatchObject({ kind: "TDS", is_default: "Y", is_active: "N", modified_by: "TEST001" });
  });

  it("a bank payee sends its bank details and no portal; an online payee sends its portal and no bank details (sql/82)", async () => {
    execute.mockResolvedValue({ recordset: [{ payee_sno: 4 }], recordsets: [[{ payee_sno: 4 }]] });
    await postJson("/statutory/payees", { kind: "TDS", payee_name: "ITD", ac_number: "1", ifsc: "SBIN0000001", pay_mode: "RTGS", payment_portal_url: "https://x.gov.in", is_default: true });
    const bank = sentTo("sp_nt_UpsertStatutoryPayee");
    expect(bank).toMatchObject({ pay_via_portal: "N", ac_number: "1", ifsc: "SBIN0000001", pay_mode: "RTGS" });
    expect(bank).not.toHaveProperty("payment_portal_url");
    execute.mockClear(); input.mockClear();
    await postJson("/statutory/payees", {
      kind: "gst", payee_name: "GST dept", pay_via_portal: true, payment_portal_name: "GST portal", payment_portal_url: "https://payment.gst.gov.in",
      payment_instructions: "PMT-06 challan", ac_number: "999", ifsc: "SBIN0000001", reference_no: "33ABCDE1234F1Z5",
    });
    const online = sentTo("sp_nt_UpsertStatutoryPayee");
    expect(online).toMatchObject({ kind: "GST", pay_via_portal: "Y", payment_portal_name: "GST portal", payment_portal_url: "https://payment.gst.gov.in",
      payment_instructions: "PMT-06 challan", reference_no: "33ABCDE1234F1Z5", modified_by: "TEST001" });
    expect(online).not.toHaveProperty("ac_number");
    expect(online).not.toHaveProperty("ifsc");
  });

  it("records an online payment of the ticked amounts as the caller, under the caller's scope", async () => {
    const online = { batch_sno: 12, batch_no: "SO-2026-000001", kind: "TDS", pay_channel: "ONLINE", txn_mode: "Net Banking", txn_id: "CIN-1", sender_account_no: null, total_amount: 7392 };
    execute.mockResolvedValue({ recordset: [online], recordsets: [[online], [{ stat_sno: 2 }, { stat_sno: 3 }]] });
    const res = await postJson("/statutory/online-payment", { stat_snos: ["2", 3], txn_mode: "net banking", txn_id: " CIN-1 ", txn_date: "2026-11-02", remarks: "  Oct TDS " });
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_RecordStatutoryOnlinePayment")).toEqual({
      stat_snos: [2, 3], txn_mode: "Net Banking", txn_id: "CIN-1", txn_date: "2026-11-02", remarks: "Oct TDS", recorded_by: "TEST001", hierarchy,
    });
    expect(res.data.batch).toMatchObject({ batch_no: "SO-2026-000001", sender_ac_last4: null });
    expect(res.data.items).toHaveLength(2);
  });

  it("an online payment needs amounts, a known mode and a challan number before touching the database", async () => {
    expect((await postJson("/statutory/online-payment", { stat_snos: [], txn_mode: "UPI", txn_id: "A" })).error).toMatch(/at least one/);
    expect((await postJson("/statutory/online-payment", { stat_snos: [1], txn_mode: "Wallet", txn_id: "A" })).error).toMatch(/Choose how it was paid/);
    expect((await postJson("/statutory/online-payment", { stat_snos: [1], txn_mode: "UPI", txn_id: "  " })).error).toMatch(/challan/);
    expect(execute).not.toHaveBeenCalled();
    execute.mockRejectedValue(new Error("Income Tax e-Pay is paid by bank account - pay those amounts with \"Pay & generate file\"."));
    expect((await postJson("/statutory/online-payment", { stat_snos: [1], txn_mode: "UPI", txn_id: "A1" })).error).toMatch(/paid by bank account/);
  });

  it("an online payment has no bank file to download", async () => {
    execute.mockResolvedValue({ recordset: [], recordsets: [[{ batch_sno: 12, batch_no: "SO-2026-000001", pay_channel: "ONLINE", txn_mode: "UPI", txn_id: "U1" }], []] });
    const res = await fetch(`${base}/statutory/runs/12/file`);
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("SO-2026-000001 was paid online (UPI U1) - there is no bank file for it.");
  });

  it("a run pays the ticked amounts, writes the bank file, stores it, and never sends the sender's full account out", async () => {
    execute.mockImplementation(async (proc) => {
      if (proc === "sp_nt_CreateStatutoryBatch") return { recordset: [batchRow], recordsets: [[batchRow], [itemRow]] };
      return { recordset: [], recordsets: [[]] };
    });
    const res = await postJson("/statutory/run", { stat_snos: [3, 4], payment_date: "2026-10-28", payment_bank_sno: "2" });
    expect(res.success).toBe(true);
    expect(sentTo("sp_nt_CreateStatutoryBatch")).toEqual({ stat_snos: [3, 4], payment_date: "2026-10-28", payment_bank_sno: 2, created_by: "TEST001", hierarchy });
    expect(res.data.file.file_name).toBe("SPACETEX_SPA311_SPA3112810.1000");
    expect(res.data.file.line_count).toBe(1);
    expect(res.data.file.content.split(",")).toHaveLength(28);
    expect(res.data.batch.sender_ac_last4).toBe("5678");
    expect(JSON.stringify(res.data)).not.toContain("123456785678");
    expect(sentTo("sp_nt_SetStatutoryBatchFile")).toMatchObject({ batch_sno: 9, file_name: "SPACETEX_SPA311_SPA3112810.1000" });
  });

  it("needs at least one amount, and shows the SQL reason when the run is refused", async () => {
    expect((await postJson("/statutory/run", { stat_snos: [] })).error).toMatch(/at least one/);
    execute.mockRejectedValue(new Error("A statutory file holds one kind at a time (TDS, GST or other) - pay each from its own tab."));
    expect((await postJson("/statutory/run", { stat_snos: [1, 2] })).error).toMatch(/one kind at a time/);
  });

  it("if the file cannot be written after the amounts were paid, says so plainly", async () => {
    execute.mockImplementation(async (proc) => (proc === "sp_nt_CreateStatutoryBatch"
      ? { recordset: [{ ...batchRow, file_name: null }], recordsets: [[{ ...batchRow, file_name: null }], [itemRow]] }
      : { recordset: [], recordsets: [[]] }));
    const res = await postJson("/statutory/run", { stat_snos: [3] });
    expect(res.error).toMatch(/SB-2026-000001 was created, but its file could not be written/);
  });

  it("gives a past run's stored file as is, and writes it again from the lines when it was never stored", async () => {
    execute.mockResolvedValueOnce({ recordset: [], recordsets: [[{ ...batchRow, file_content: "stored" }], []] });
    expect((await getJson("/statutory/runs/9/file")).data).toMatchObject({ file_name: "SPACETEX_SPA311_SPA3112810.1000", content: "stored" });
    execute.mockReset();
    execute.mockImplementation(async (proc) => (proc === "sp_nt_GetStatutoryBatches"
      ? { recordset: [], recordsets: [[{ ...batchRow, file_content: null }], [itemRow]] }
      : { recordset: [], recordsets: [[]] }));
    const again = await getJson("/statutory/runs/9/file");
    expect(again.data.content.split(",")).toHaveLength(28);
    expect(sentTo("sp_nt_SetStatutoryBatchFile")).toMatchObject({ batch_sno: 9 });
  });

  it("a run outside the caller's scope is 404", async () => {
    execute.mockResolvedValue({ recordset: [], recordsets: [[], []] });
    const res = await fetch(`${base}/statutory/runs/9/file`);
    expect(res.status).toBe(404);
  });
});

describe("reverse file (sql/83)", () => {
  const runRow = { batch_sno: 21, batch_no: "PB-2026-000021", file_name: "SPACETEX_SPA311_SPA3110311.100", file_type: "BANK_UPLOAD", com_sno: 1 };
  const runItem = (o) => ({ channel: "BANK", mode: "NEFT", bank_status: null, utr_no: null, payment_status: "Processed", ...o });
  const runItems = [
    runItem({ batch_item_sno: 1, line_no: 1, payment_sno: 31, payment_no: "PAY-2026-000031", vendor_sno: 122, vendor_name: "Aravali", amount: 48300, account_no: "1205012345" }),
    runItem({ batch_item_sno: 2, line_no: 2, payment_sno: 34, payment_no: "PAY-2026-000034", vendor_sno: 150, vendor_name: "Bluepeak", amount: 61500, account_no: "50100223344556" }),
    runItem({ batch_item_sno: 3, line_no: 3, payment_sno: 35, payment_no: "PAY-2026-000035", vendor_sno: 160, vendor_name: "Cheque Co", amount: 700, mode: "Cheque", channel: "MANUAL" }),
  ];
  const FILE = [
    "Customer Reference No,Status,Amount,UTR No,Reason Code,Reason",
    "122-PAY2026000031,Success,48300.00,HDFCN26307004512,,",
    "150-PAY2026000034,Rejected,61500.00,,AC01,Invalid account",
    "999-PAY2026000099,Paid,1,U9,,",
  ].join("\n");
  const applied = [
    { batch_item_sno: 1, payment_sno: 31, payment_no: "PAY-2026-000031", vendor_name: "Aravali", amount: 48300, result: "PAID", new_status: "PAID", payment_status: "Processed", created_by: "TEST001", com_sno: 1, div_sno: 2, brn_sno: 3, dept_sno: 4 },
    { batch_item_sno: 2, payment_sno: 34, payment_no: "PAY-2026-000034", vendor_name: "Bluepeak", amount: 61500, result: "FAILED", new_status: "REJECTED", bank_reason: "Invalid account", payment_status: "Approved", created_by: "KTM1006", com_sno: 1, div_sno: 2, brn_sno: 3, dept_sno: 4 },
  ];
  beforeEach(() => {
    execute.mockImplementation(async (proc) => {
      if (proc === "sp_nt_GetPaymentBatches") return { recordset: [runRow], recordsets: [[runRow], runItems, [], [{ reverse_file_sno: 7 }]] };
      if (proc === "sp_nt_ApplyPaymentReverseFile") return { recordset: [], recordsets: [[{ reverse_file_sno: 8, paid_count: 1, failed_count: 1 }], applied] };
      return { recordset: [], recordsets: [[]] };
    });
  });

  it("the run detail gives each file transfer the reference the bank quotes back, and the run's reverse files", async () => {
    const res = await getJson("/run/batches/21");
    expect(res.data.items.map((i) => i.reference)).toEqual(["122-PAY2026000031", "150-PAY2026000034", null]);
    expect(res.data.reverse_files).toEqual([{ reverse_file_sno: 7 }]);
  });

  it("preview says what each line would do and changes nothing", async () => {
    const res = await postJson("/run/batches/21/reverse-file/preview", { file_name: "rev.csv", content: FILE });
    expect(res.success).toBe(true);
    expect(res.data.summary).toMatchObject({ lines: 3, matched: 2, problems: 1, paid: 1, failed: 1 });
    expect(res.data.lines.map((l) => l.action ?? l.problem)).toEqual(["MARK_PAID", "RETURN_TO_RUN", expect.stringMatching(/No transfer of PB-2026-000021/)]);
    expect(sentTo("sp_nt_ApplyPaymentReverseFile")).toBeNull();
    expect(sentTo("sp_nt_GetPaymentBatches")).toMatchObject({ batch_sno: 21, hierarchy });
  });

  it("applies only the matched lines, refreshes the screens and tells the payment's maker it was not paid", async () => {
    const res = await postJson("/run/batches/21/reverse-file", { file_name: "rev.csv", content: FILE });
    expect(res.success).toBe(true);
    const sent = sentTo("sp_nt_ApplyPaymentReverseFile");
    expect(sent).toMatchObject({ batch_sno: 21, uploaded_by: "TEST001", file_name: "rev.csv", file_content: FILE, unmatched_count: 1, hierarchy });
    expect(sent.lines).toEqual([
      expect.objectContaining({ batch_item_sno: 1, status: "PAID", amount: 48300, utr_no: "HDFCN26307004512" }),
      expect.objectContaining({ batch_item_sno: 2, status: "REJECTED", amount: 61500, reason_code: "AC01", reason: "Invalid account" }),
    ]);
    expect(res.data.problems).toHaveLength(1);
    expect(broadcast).toHaveBeenCalledTimes(2);
    expect(broadcast.mock.calls[1][2]).toMatchObject({ payment_sno: 34, status: "Approved", bank_status: "REJECTED" });
    expect(createInAppNotification).toHaveBeenCalledTimes(1);
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "KTM1006", title: "Payment not paid by the bank" });
    expect(createInAppNotification.mock.calls[0][0].message).toMatch(/rejected by the bank: Invalid account\. It is back in Payment Run/);
  });

  it("refuses an empty or unreadable file, a file nothing matches, and a run with no bank transfer", async () => {
    expect((await postJson("/run/batches/21/reverse-file", { content: "" })).error).toMatch(/Choose the reverse file/);
    expect((await postJson("/run/batches/21/reverse-file", { content: "Amount\n1" })).error).toMatch(/reference column/);
    expect((await postJson("/run/batches/21/reverse-file", { content: "Reference,Status\nX-1,Paid" })).error).toMatch(/nothing was changed/);
    expect(sentTo("sp_nt_ApplyPaymentReverseFile")).toBeNull();
    execute.mockImplementation(async () => ({ recordset: [], recordsets: [[runRow], [runItems[2]], []] }));
    expect((await postJson("/run/batches/21/reverse-file/preview", { content: FILE })).error).toMatch(/no NEFT \/ RTGS transfer/);
  });

  it("changes how a payment the bank did not pay is paid", async () => {
    execute.mockResolvedValue({ recordset: [{ payment_sno: 34, payment_no: "PAY-2026-000034", mode: "RTGS", old_mode: "NEFT", status: "Approved", com_sno: 1 }], recordsets: [[]] });
    const res = await postJson("/run/change-mode", { payment_sno: 34, mode: "rtgs", reason: "  above 2 lakh  " });
    expect(res.data).toMatchObject({ mode: "RTGS", old_mode: "NEFT" });
    expect(sentTo("sp_nt_ChangeFailedPaymentMode")).toEqual({ payment_sno: 34, mode: "RTGS", reason: "above 2 lakh", changed_by: "TEST001", hierarchy });
    expect(broadcast.mock.calls[0][2]).toMatchObject({ payment_sno: 34, mode: "RTGS" });
    expect((await postJson("/run/change-mode", { payment_sno: 34, mode: "UPI" })).error).toMatch(/Choose NEFT, RTGS/);
    expect((await postJson("/run/change-mode", { mode: "NEFT" })).error).toMatch(/payment_sno is required/);
  });

  it("the Payment Run list carries the bank's reason on a payment it did not pay", async () => {
    execute.mockImplementation(async (proc) => {
      if (proc === "sp_nt_GetPaymentEntries") {
        return { recordset: [], recordsets: [[{ payment_sno: 34, status: "Approved", batch_sno: null }, { payment_sno: 40, status: "Approved", batch_sno: null }], [], []] };
      }
      if (proc === "sp_nt_GetPaymentBankFailures") return { recordset: [{ payment_sno: 34, bank_status: "REJECTED", bank_reason: "Invalid account", batch_no: "PB-2026-000021" }], recordsets: [[]] };
      return { recordset: [], recordsets: [[]] };
    });
    const res = await getJson("/entries?view=run");
    // (sentTo pairs calls by position, and this route also runs a procedure without parameters - so look for the payload itself)
    expect(input.mock.calls.map((c) => JSON.parse(c[2]))).toContainEqual({ payment_snos: [34, 40] });
    expect(execute.mock.calls.map(([p]) => p)).toContain("sp_nt_GetPaymentBankFailures");
    expect(res.data.entries[0].bank_failure).toMatchObject({ bank_status: "REJECTED", bank_reason: "Invalid account" });
    expect(res.data.entries[1].bank_failure).toBeUndefined();
  });
});
