// paymentnet.routes.js - the HTTP edge of the Payment screens: which bills the notes lookup is asked about, the live
// payment:released / payment:updated broadcasts, the approval and cancel calls, the Payment Run list and the payment file.
// Which bill may redeem which debit / credit note, and the approval / MSME / fund rules, are decided in SQL (sql/64, sql/65)
// and are exercised against the database, not here.
import { describe, it, expect, jest, beforeAll, afterAll, beforeEach } from "@jest/globals";
import express from "express";

const input = jest.fn();
const execute = jest.fn();
const schema = { c: 1, p: 1 };                       // what the database says about the sql/68 objects
const query = jest.fn(async () => ({ recordset: [schema] }));
const request = { input, execute, query };
input.mockReturnValue(request);
const broadcast = jest.fn();
const createInAppNotification = jest.fn(async () => ({ sent: true }));

jest.unstable_mockModule("../src/config/db.js", () => ({
  initializeDatabase: async () => ({ request: () => request }),
}));
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
    expect(line).toBe("N,,123,1000.00,NEO,,,,,,,,,122-PAY55,,,,,,,,,22/10/2026,,KKBK0000961,KOTAK,SURAT,payment.ktm@scmts.net");
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
    expect(rebuilt.content).toBe("N,,123,1000.00,NEO,,,,,,,,,122-PAY55,,,,,,,,,22/10/2026,,KKBK0000961,KOTAK,SURAT,payment.ktm@scmts.net");
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

  it("a run outside the caller's scope is 404", async () => {
    execute.mockResolvedValue({ recordsets: [[], []], recordset: [] });
    expect((await fetch(`${base}/run/batches/9`)).status).toBe(404);
    expect((await fetch(`${base}/run/batches/9/file`)).status).toBe(404);
  });
});

describe("GET /run/senders", () => {
  it("asks for the company's bank accounts under the caller's org scope and returns them as the database gave them", async () => {
    const senders = [{ payment_bank_sno: 3, com_sno: 1, profile_name: "HDFC Current A/c", ac_last4: "5678", is_default: "Y" }];
    execute.mockResolvedValue({ recordset: senders, recordsets: [senders] });
    const res = await getJson("/run/senders?com_sno=1");
    expect(sentTo("sp_nt_GetPaymentSenders")).toEqual({ com_sno: 1, hierarchy });
    expect(res.data).toEqual(senders);
  });

  it("without a usable company it asks for every company the caller may see", async () => {
    execute.mockResolvedValue({ recordset: [], recordsets: [[]] });
    await getJson("/run/senders?com_sno=abc");
    expect(sentTo("sp_nt_GetPaymentSenders")).toEqual({ hierarchy });
  });
});
