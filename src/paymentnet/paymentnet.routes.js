import express from "express";
import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";
import { broadcast } from "../utils/socketBroadcast.js";
import { createInAppNotification } from "../utils/notifyClient.js";
import { attachHierarchyScope, orgRoomTargets } from "../middleware/hierarchyScope.js";
import { buildPaymentFile, buildVerificationSheet, referenceOf } from "./paymentFile.js";
import { loadBankFileLayout } from "./bankFileLayout.js";
import { fileItemsOf, matchReverseFile, parseReverseFile } from "./reverseFile.js";
import StatutoryRouter from "./statutory.routes.js";

// Payment backend: payable bills with GRN / 2B / TDS context, the adjustments available for the bills being paid
// (advances, debit/credit notes, TDS sections), and the payment life cycle (sql/44, sql/48, sql/64, sql/65):
//   POST /release  saves a payment (sp_nt_ReleasePaymentNet) -> 'Pending Approval', or 'Approved' when no workflow is configured
//   POST /approve  an approver passes / rejects / forwards / sends it back (stages and value conditions: sql/66)
//                                                            -> 'Approved' | 'Rejected' | stays 'Pending Approval' with the next approver
//   POST /cancel   withdraws a payment that is not paid yet   -> 'Cancelled'
//   GET  /entries  the approval screen and the Payment Run list (approved payments waiting for money, MSME / due dates)
//   GET  /tds-rate-log  who typed which TDS rate on which invoice (sql/84)
//   GET  /run/senders  the company/division/branch bank accounts a run can be paid from (Payment Bank master, sql/138)
//   POST /run/proceed  pays the ticked payments against today's fund plan from one of them: batch, journals, and the bank payment file (sql/68)
//   POST /run/portal-details  adds / fixes a portal supplier's portal name, address and instructions from a waiting payment (sql/91, logged)
//   POST /run/batches/:id/reverse-file[/preview]  the bank's answer to that file (sql/83): UTRs on what it paid; what it rejected /
//                      returned goes back to Payment Run (journal reversed) - POST /run/change-mode then changes how it is paid
// sp_nt_ReleasePaymentNet with preview=true returns the figures without saving.
const PaymentNetRouter = express.Router();

const userOf = (req) => (Array.isArray(req.user) ? req.user[0] : req.user);
// staff ecno, or the login id of a non-staff user (same identity the approval workflow stores as approver_ecno)
const callerOf = (req) => req.user_ecno ?? userOf(req)?.ecno ?? userOf(req)?.login_id ?? null;
const httpError = (status, message) => Object.assign(new Error(message), { status });

async function exec(proc, params, allRecordsets = false) {
  try {
    const pool = await initializeDatabase();
    const request = pool.request();
    if (params !== undefined) request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(params));
    const result = await request.execute(proc);
    return allRecordsets ? result.recordsets : result.recordset;
  } catch (error) {
    throw new Error(error.message); // SP THROW text is user-facing validation
  }
}
const wrap = (fn, status = 400) => async (req, res) => {
  try {
    res.json({ success: true, data: await fn(req) });
  } catch (error) {
    res.status(error.status ?? status).json({ success: false, error: error.message });
  }
};

const rupees = (n) => `₹${Number(n ?? 0).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const notify = (ecno, type, title, message, data) => {
  if (ecno) createInAppNotification({ ecno, type, title, message, data: { kind: "payment", ...data } }).catch(() => {});
};
const positiveInt = (v) => (Number.isInteger(Number(v)) && Number(v) > 0 ? Number(v) : null);

// Each bill also carries the company/division/branch it will be paid under - the invoice's own, else its PO's (the same rule
// sp_nt_ReleasePaymentNet uses to file the payment). A payment belongs to ONE company, so the screen saves one payment per
// supplier and company when the ticked bills span several.
PaymentNetRouter.get("/bills", wrap(async (req) => {
  const bills = await exec("sp_nt_GetPayableBillsNet", { vendor_sno: req.query.vendor_sno ? Number(req.query.vendor_sno) : undefined });
  if (!Array.isArray(bills) || bills.length === 0) return bills;
  const pool = await initializeDatabase();
  const orgs = await pool.request().query(`
    SELECT iad.invoice_alloc_sno AS bill_sno,
           IIF(i.com_sno IS NULL, p.com_sno, i.com_sno) AS com_sno, IIF(i.com_sno IS NULL, p.div_sno, i.div_sno) AS div_sno,
           IIF(i.com_sno IS NULL, p.brn_sno, i.brn_sno) AS brn_sno, c.com_name
    FROM dbo.invoice_allocation_details iad
    JOIN dbo.invoice_info i ON i.invoice_sno = iad.invoice_sno
    LEFT JOIN dbo.po_request_info p ON p.po_basic_sno = i.po_basic_sno
    LEFT JOIN dbo.company_master c ON c.com_sno = IIF(i.com_sno IS NULL, p.com_sno, i.com_sno)
    WHERE iad.is_active = 'Y'`);
  const byBill = new Map(orgs.recordset.map((o) => [o.bill_sno, o]));
  return bills.map((b) => {
    const o = byBill.get(b.bill_sno);
    return { ...b, com_sno: o?.com_sno ?? null, div_sno: o?.div_sno ?? null, brn_sno: o?.brn_sno ?? null, com_name: o?.com_name ?? null };
  });
}, 500));

// Goods received (GRN approved) but no supplier invoice yet - listed on the Payment page as "pending payment" (sql/53).
PaymentNetRouter.get("/grn-pending", wrap((req) => exec("sp_nt_GetGrnPendingPayments", { vendor_sno: req.query.vendor_sno ? Number(req.query.vendor_sno) : undefined, include_billed: req.query.include_billed === "1" }), 500));

// Invoice-wise ledger per PO: every invoice (paid / part paid / unpaid / not allocated, with duplicate flag) and the invoice data each GRN captured (sql/63).
PaymentNetRouter.get("/invoice-ledger", wrap(async (req) => {
  const [invoices = [], grns = []] = await exec("sp_nt_GetPoInvoiceLedger", { vendor_sno: req.query.vendor_sno ? Number(req.query.vendor_sno) : undefined }, true);
  return { invoices, grns };
}, 500));

// Notes are only ever offered against specific bills (sql/64): ?vendor_sno=7&invoice_snos=12,14 - the invoices being paid.
// A note raised against a bill that is already paid in full is offered on every bill of the supplier; one raised against
// a bill still open is offered only with that bill. Without invoice_snos no note comes back.
PaymentNetRouter.get("/adjustments", wrap(async (req) => {
  const invoice_snos = [...new Set(String(req.query.invoice_snos ?? "").split(",").map((s) => Number(s.trim())).filter((n) => Number.isInteger(n) && n > 0))];
  // 5th recordset (sql/69): advances approved for the supplier but still waiting in Payment Run - not nettable until they are paid
  const [advances = [], debitNotes = [], creditNotes = [], , pendingAdvances = []] =
    await exec("sp_nt_GetPaymentAdjustments", { vendor_sno: Number(req.query.vendor_sno), invoice_snos }, true);
  const tdsSections = await exec("sp_nt_GetTdsSections", {});   // carries applies_to (Service / Product / Both), sql/62
  return { advances, debitNotes, creditNotes, tdsSections, pendingAdvances };
}));

// TDS Section master (Masters screen): list every section, add / edit one (sql/60)
PaymentNetRouter.get("/tds-sections", wrap(() => exec("sp_nt_GetTdsSections", {}), 500));
PaymentNetRouter.post("/tds-sections", wrap(async (req) => {
  const [row] = await exec("sp_nt_UpsertTdsSection", { ...req.body, modified_by: callerOf(req) });
  return row;
}));

const releaseBody = (req, preview) => ({ ...req.body, created_by: callerOf(req), preview });

PaymentNetRouter.post("/preview", wrap(async (req) => {
  const [summary = [], invoices = []] = await exec("sp_nt_ReleasePaymentNet", releaseBody(req, true), true);
  return { summary: summary[0] ?? null, invoices };
}));

// Tells every open Payment page what this save used up. A note redeemed here has to vanish from the other payments
// of the supplier at once, otherwise someone else ticks it and their save fails. Fired only after the commit.
function broadcastPaymentReleased(body, row) {
  if (!row?.payment_sno) return;
  const { com_sno, div_sno, brn_sno, dept_sno } = row;
  broadcast(orgRoomTargets("payment", { com_sno, div_sno, brn_sno, dept_sno }), "payment:released", {
    payment_sno: row.payment_sno,
    payment_no: row.payment_no,
    vendor_sno: Number(body.vendor_sno),
    bill_snos: (body.allocations ?? []).map((a) => Number(a.invoice_alloc_sno)),
    notes: (body.notes ?? []).map((n) => ({ type: String(n.type).toUpperCase(), note_sno: Number(n.note_sno) })),
  });
}

// A payment changed state (saved, approved, rejected, cancelled): the approval screen and the Payment Run refresh.
function broadcastPaymentUpdated(row, extra = {}) {
  if (!row?.payment_sno) return;
  const { com_sno, div_sno, brn_sno, dept_sno } = row;
  broadcast(orgRoomTargets("payment", { com_sno, div_sno, brn_sno, dept_sno }), "payment:updated", {
    payment_sno: row.payment_sno, payment_no: row.payment_no, status: row.status, ...extra,
  });
}

// GSTR-2B check at Payment Run (sql/79): the Payment screen and the approval ignore 2B; an APPROVED payment that has not gone into a run yet is
// cut to the taxable value of every invoice that is still not in 2B, and that GST is listed on Unpaid GST. Safe to repeat; never throws.
export async function applyGst2bCheck({ by, vendor_sno, payment_sno } = {}) {
  try {
    const cut = await exec("sp_nt_ApplyGst2bCheck", { by: by ? String(by).slice(0, 20) : undefined, vendor_sno: vendor_sno ?? undefined, payment_sno: payment_sno ?? undefined });
    for (const p of cut ?? []) broadcastPaymentUpdated({ ...p, status: p.cancelled ? "Cancelled" : "Approved" }, { gst_deferred: p.deferred });
    return cut ?? [];
  } catch {
    return [];   // before sql/79 is applied there is no such check
  }
}

// Unpaid GST (sql/75): an invoice that was not in GSTR-2B was paid without its GST. Once a 2B upload has the invoice, that GST is moved
// to Payment Run as an already approved payment. Run after a payment's final approval, after every 2B upload / confirm / hold release,
// and from the Unpaid GST screen. Never throws when `quiet` (a failure here must not undo the approval or the upload that called it).
export async function releaseUnpaidGst({ by, vendor_sno, quiet = true } = {}) {
  try {
    await applyGst2bCheck({ by, vendor_sno });
    const released = await exec("sp_nt_ReleaseGstAfter2b", { by: by ? String(by).slice(0, 20) : undefined, vendor_sno: vendor_sno ?? undefined });
    for (const p of released ?? []) broadcastPaymentUpdated({ ...p, status: "Approved" }, { gst_released: true });
    return released ?? [];
  } catch (error) {
    if (!quiet) throw error;
    return [];
  }
}

// Save. The payment is created 'Pending Approval' (first approver notified) or 'Approved' when the department has no Payment workflow.
PaymentNetRouter.post("/release", wrap(async (req) => {
  const [row] = await exec("sp_nt_ReleasePaymentNet", releaseBody(req, false));
  broadcastPaymentReleased(req.body, row);
  broadcastPaymentUpdated(row);
  if (row?.status === "Approved") await releaseUnpaidGst({ by: callerOf(req), vendor_sno: Number(req.body?.vendor_sno) || undefined });
  if (row?.status === "Pending Approval") {
    notify(row.current_approver_id, "info", "Payment awaiting your approval",
      `${row.payment_no} (${rupees(row.net_paid)}) needs your approval. Open Payment Approval.`, { payment_sno: row.payment_sno });
  }
  return row;
}));

// ── approval (sql/65) ───────────────────────────────────────────────────────
// view=run (default) | mine | all; ?payment_sno= for one; ?vendor_sno= ?com_sno= ?status= filters. Org-scoped like the other lists.
PaymentNetRouter.get("/entries", attachHierarchyScope, wrap(async (req) => {
  const view = ["run", "mine", "all"].includes(req.query.view) ? req.query.view : "run";
  if (view === "run") await applyGst2bCheck({ by: callerOf(req) });
  const [entries = [], lines = [], settings = []] = await exec("sp_nt_GetPaymentEntries", {
    view,
    ecno: callerOf(req),
    hierarchy: req.hierarchyJson,
    vendor_sno: positiveInt(req.query.vendor_sno) ?? undefined,
    com_sno: positiveInt(req.query.com_sno) ?? undefined,
    status: req.query.status ? String(req.query.status) : undefined,
    with_lines: req.query.with_lines,
  }, true);
  const held = await gstHeldByInvoice(lines);
  const linesOut = lines.map((l) => ({ ...l, gst_held: held.get(l.invoice_sno) ?? 0 }));
  const heldBy = new Map();
  for (const l of linesOut) heldBy.set(l.payment_sno, (heldBy.get(l.payment_sno) ?? 0) + l.gst_held);
  const entriesOut = await withPortalDetails(await withBankFailures((await withGroups(entries)).map((e) => ({ ...e, gst_held: heldBy.get(e.payment_sno) ?? 0 }))));
  return { entries: entriesOut, lines: linesOut, settings: Object.fromEntries(settings.map((s) => [s.setting_key, s.setting_value])) };
}, 500));

// A supplier paid on their own portal (KYC "pay via portal", backend sql/109) also carries the payment instructions it gave in KYC,
// so "Pay on supplier portals" can show what to do there next to the portal link, and - once the payments team has changed its
// portal details on Payment Run (sql/91) - who did that last and when (portal_edited_by / portal_edited_at). Read-only; never
// throws - without it the list still shows, just without instructions. Before sql/91 there is no log, so no "edited by".
async function withPortalDetails(entries) {
  const vendors = [...new Set(entries.filter((e) => e.pay_via_portal && e.vendor_sno != null).map((e) => Number(e.vendor_sno)))];
  if (vendors.length === 0) return entries;
  try {
    const pool = await initializeDatabase();
    const r = await pool.request()
      .input("vendors", mssql.NVarChar(mssql.MAX), JSON.stringify(vendors))
      .query(`DECLARE @v TABLE (vendor_sno INT PRIMARY KEY);
              INSERT INTO @v SELECT DISTINCT TRY_CAST(value AS INT) FROM OPENJSON(@vendors) WHERE TRY_CAST(value AS INT) IS NOT NULL;
              SELECT k.kyc_basic_info_sno AS vendor_sno, NULLIF(LTRIM(RTRIM(k.payment_instructions)), '') AS payment_instructions
              FROM dbo.kyc_basic_info k JOIN @v v ON v.vendor_sno = k.kyc_basic_info_sno;
              IF OBJECT_ID('dbo.kyc_portal_detail_log', 'U') IS NOT NULL
                  SELECT x.vendor_sno, x.changed_by AS portal_edited_by, x.changed_at AS portal_edited_at
                  FROM (SELECT l.kyc_basic_info_sno AS vendor_sno, l.changed_by, l.changed_at,
                               ROW_NUMBER() OVER (PARTITION BY l.kyc_basic_info_sno ORDER BY l.log_sno DESC) AS rn
                        FROM dbo.kyc_portal_detail_log l JOIN @v v ON v.vendor_sno = l.kyc_basic_info_sno) x
                  WHERE x.rn = 1;`);
    const [details = r.recordset ?? [], edits = []] = r.recordsets ?? [];
    const by = new Map(details.map((x) => [Number(x.vendor_sno), x.payment_instructions ?? null]));
    const edited = new Map(edits.map((x) => [Number(x.vendor_sno), x]));
    return entries.map((e) => {
      if (!e.pay_via_portal) return e;
      const last = edited.get(Number(e.vendor_sno));
      return { ...e, payment_instructions: by.get(Number(e.vendor_sno)) ?? null,
        ...(last ? { portal_edited_by: last.portal_edited_by, portal_edited_at: last.portal_edited_at } : {}) };
    });
  } catch {
    return entries;
  }
}

// A payment waiting in Payment Run because the bank rejected / returned it in an earlier run (sql/83) carries `bank_failure`: the
// run, the bank's reason and whether the supplier's KYC account changed since. Never throws - before sql/83 nothing has failed.
async function withBankFailures(entries) {
  const waiting = entries.filter((e) => e.status === "Approved" && e.batch_sno == null).map((e) => e.payment_sno);
  if (waiting.length === 0) return entries;
  let rows = [];
  try { rows = await exec("sp_nt_GetPaymentBankFailures", { payment_snos: waiting }); } catch { return entries; }
  const by = new Map((rows ?? []).map((r) => [r.payment_sno, r]));
  return entries.map((e) => (by.has(e.payment_sno) ? { ...e, bank_failure: by.get(e.payment_sno) } : e));
}

// GST kept back on an invoice until it shows in GSTR-2B (payment_gst_pending, sql/75): shown in red in the breakup of a payment.
// Never throws - before sql/75 there is no such table and nothing is held.
async function gstHeldByInvoice(lines) {
  const out = new Map();
  if (!lines.length) return out;
  try {
    const pool = await initializeDatabase();
    const r = await pool.request().query("SELECT invoice_sno, SUM(gst_amount) AS gst_held FROM dbo.payment_gst_pending WHERE status = 'Awaiting 2B' GROUP BY invoice_sno");
    for (const x of r.recordset) out.set(x.invoice_sno, Number(x.gst_held) || 0);
  } catch {
    // no held GST to show
  }
  return out;
}

// Payment groups (sql/74): payments saved together for several suppliers of one company/division/branch. The entries carry
// group_sno / group_no / group_size so the screens can badge them and act on the whole group. Before sql/74 is applied
// there are simply no groups.
async function withGroups(entries) {
  let map = [];
  try { map = await exec("sp_nt_GetPaymentGroupMap"); } catch { return entries; }
  const byPayment = new Map(map.map((g) => [g.payment_sno, g]));
  return entries.map((e) => {
    const g = byPayment.get(e.payment_sno);
    return g ? { ...e, group_sno: g.group_sno, group_no: g.group_no, group_size: g.payment_count } : e;
  });
}

// Ties payments that were just saved together into one group. Called by the Payment screen after a multi-supplier save, once
// per company/division/branch that got two or more payments.
PaymentNetRouter.post("/group", wrap(async (req) => {
  const snos = Array.isArray(req.body?.payment_snos) ? req.body.payment_snos : [];
  if (snos.length < 2 || !snos.every(positiveInt)) throw httpError(400, "Choose at least two payments to group");
  const [row] = await exec("sp_nt_CreatePaymentGroup", { payment_snos: snos.map(Number), created_by: callerOf(req) });
  return row;
}));

// One payment with its invoice lines, approval trail, adjustments and approver chain. `stages` is the chain this payment follows
// (which stage applies to its amount, who acted, who is current); `approval` is what the caller may do now - approve / reject /
// forward / send back, with the stages each of those can go to (sql/66).
PaymentNetRouter.get("/entries/:id", attachHierarchyScope, wrap(async (req) => {
  const id = positiveInt(req.params.id);
  if (!id) throw httpError(400, "Invalid payment id");
  const ecno = callerOf(req);
  const [entries = [], lines = []] = await exec("sp_nt_GetPaymentEntries", { view: "all", payment_sno: id, ecno, hierarchy: req.hierarchyJson }, true);
  if (!entries[0]) throw httpError(404, "Payment not found, or it is outside your access");
  const [history = [], adjustments = [], stages = [], summary = [], forwardTargets = [], sendBackTargets = [], log = [], fields = []] =
    await exec("sp_nt_GetPaymentActivity", { payment_sno: id, ecno }, true);
  // per invoice: what it may be paid in all, what other payments hold, what this one pays, what is left, GST waiting for 2B (sql/70) -
  // what an approver needs to decide whether to pay less now. A database without sql/70 simply has no such figures.
  const invoices = await exec("sp_nt_GetPaymentInvoiceFigures", { payment_sno: id }).catch(() => []);
  return {
    entry: entries[0], lines, invoices, history, adjustments, stages,
    approval: { summary: summary[0] ?? null, forward_targets: forwardTargets, send_back_targets: sendBackTargets, log, condition_fields: fields },
  };
}, 500));

// action: approve | reject | forward | send_back. forward / send_back need target_seq (a later / an earlier stage); reject and send_back need remarks.
PaymentNetRouter.post("/approve", wrap(async (req) => {
  const { payment_sno, action, comments, target_seq } = req.body ?? {};
  if (!positiveInt(payment_sno)) throw httpError(400, "payment_sno is required");
  const target = target_seq === undefined || target_seq === null || target_seq === "" ? undefined : Number(target_seq);
  if (target !== undefined && !(Number.isInteger(target) && target >= 0)) throw httpError(400, "target_seq must be a stage number");
  const by = callerOf(req);
  const [row] = await exec("sp_nt_ApprovePayment", { payment_sno: Number(payment_sno), action, comments, target_seq: target, approved_by: by });
  broadcastPaymentUpdated(row);
  if (row.result === "APPROVED_NEXT") {
    notify(row.next_approver, "info", "Payment awaiting your approval",
      `${row.payment_no} (${rupees(row.net_paid)}) was approved by the previous approver and now needs yours.`, { payment_sno: row.payment_sno });
  } else if (row.result === "FORWARDED") {
    notify(row.next_approver, "info", "Payment forwarded to you",
      `${row.payment_no} (${rupees(row.net_paid)}) was forwarded to you by ${by}${comments ? `: ${comments}` : ""}. Open Payment Approval.`, { payment_sno: row.payment_sno });
  } else if (row.result === "SENT_BACK") {
    notify(row.next_approver, "warning", "Payment sent back to you",
      `${row.payment_no} (${rupees(row.net_paid)}) was sent back to you by ${by}: ${comments}. Open Payment Approval.`, { payment_sno: row.payment_sno });
  } else if (row.result === "FINAL") {
    notify(row.created_by, "success", "Payment approved",
      `${row.payment_no} (${rupees(row.net_paid)}) was approved - it is now waiting in Payment Run.`, { payment_sno: row.payment_sno });
    // final approval checks GSTR-2B: GST left unpaid is noted, and moved to Payment Run at once when 2B already has the invoice (sql/75)
    await releaseUnpaidGst({ by: by, vendor_sno: row.vendor_sno });
  } else if (row.result === "REJECTED") {
    notify(row.created_by, "warning", "Payment rejected",
      `${row.payment_no} was rejected${comments ? `: ${comments}` : ""}. Its invoices are free to be paid again.`, { payment_sno: row.payment_sno });
  }
  return row;
}));

// The approver pays less now (sql/70): { payment_sno, reason, allocations: [{ invoice_sno, amount }] } - each invoice is cut down to `amount`
// (0 leaves it out of this payment; never more than was saved). What is not paid stays on the invoice for another payment.
// Only the approver the payment is with can do it; it stays Pending Approval, at the same stage, and the approver then approves it as usual.
PaymentNetRouter.post("/revise", wrap(async (req) => {
  const { payment_sno, reason, allocations } = req.body ?? {};
  if (!positiveInt(payment_sno)) throw httpError(400, "payment_sno is required");
  if (!String(reason ?? "").trim()) throw httpError(400, "Give the reason for paying less now");
  if (!Array.isArray(allocations) || allocations.length === 0
    || !allocations.every((a) => positiveInt(a?.invoice_sno) && Number.isFinite(Number(a?.amount)) && Number(a.amount) >= 0)) {
    throw httpError(400, "Give the amount to pay now for each invoice");
  }
  const by = callerOf(req);
  const [row] = await exec("sp_nt_RevisePayment", {
    payment_sno: Number(payment_sno), revised_by: by, reason: String(reason).trim(),
    allocations: allocations.map((a) => ({ invoice_sno: Number(a.invoice_sno), amount: Number(a.amount) })),
  });
  broadcastPaymentUpdated(row);
  notify(row.created_by ?? null, "info", "Payment reduced", `${row.payment_no} was reduced to ${rupees(row.net_paid)} by ${by}: ${String(reason).trim()}. The rest of the invoice stays open.`, { payment_sno: row.payment_sno });
  return row;
}));

PaymentNetRouter.post("/cancel", wrap(async (req) => {
  const { payment_sno, reason } = req.body ?? {};
  if (!positiveInt(payment_sno)) throw httpError(400, "payment_sno is required");
  const by = callerOf(req);
  const [row] = await exec("sp_nt_CancelPayment", { payment_sno: Number(payment_sno), cancelled_by: by, reason });
  broadcastPaymentUpdated(row);
  const note = `${row.payment_no} (${rupees(row.net_paid)}) was cancelled by ${by}: ${reason}`;
  if (row.created_by && row.created_by !== by) notify(row.created_by, "warning", "Payment cancelled", note, { payment_sno: row.payment_sno });
  if (row.was_status === "Pending Approval" && row.was_waiting_on && row.was_waiting_on !== by) notify(row.was_waiting_on, "info", "Payment cancelled", note, { payment_sno: row.payment_sno });
  return row;
}));

// ── payment run (sql/65, sql/68) ────────────────────────────────────────────
// The bank accounts for the run's company/division/branch - the Payment Bank master (backend-stpl sql/138). Only the last 4 digits go out.
PaymentNetRouter.get("/run/senders", attachHierarchyScope, wrap(
  (req) => exec("sp_nt_GetPaymentSenders", {
    com_sno: positiveInt(req.query.com_sno) ?? undefined,
    div_sno: positiveInt(req.query.div_sno) ?? undefined,
    brn_sno: positiveInt(req.query.brn_sno) ?? undefined,
    hierarchy: req.hierarchyJson,
  }), 500));

// The bank file needs sql/68 (sender columns + procedures). Refuse BEFORE any payment is paid when this code runs against a database
// that does not have it yet - otherwise the run would be paid and its file could not be written. Remembered once true.
let bankFileSchemaReady = false;
async function requireBankFileSchema() {
  if (bankFileSchemaReady) return;
  const pool = await initializeDatabase();
  const r = await pool.request().query("SELECT COL_LENGTH('dbo.payment_batch', 'file_no') AS c, OBJECT_ID('dbo.sp_nt_GetPaymentSenders') AS p, OBJECT_ID('dbo.payment_file_creation_no') AS n");
  if (r.recordset[0]?.c == null || r.recordset[0]?.p == null || r.recordset[0]?.n == null) throw httpError(503, "The scoped payment bank file sequence is not set up yet - run the latest grn-service sql/68 (after backend-stpl sql/138), then try again.");
  bankFileSchemaReady = true;
}

// ── suppliers paid on their portal (sql/69) ─────────────────────────────────
// No run, no file: the payment is paid on the portal and the transaction is recorded here afterwards.
PaymentNetRouter.post("/run/portal-payment", attachHierarchyScope, wrap(async (req) => {
  const b = req.body ?? {};
  if (!positiveInt(b.payment_sno)) throw httpError(400, "payment_sno is required");
  const [row] = await exec("sp_nt_RecordPortalPayment", {
    payment_sno: Number(b.payment_sno), txn_mode: b.txn_mode, txn_id: b.txn_id,
    txn_date: /^\d{4}-\d{2}-\d{2}$/.test(String(b.txn_date ?? "")) ? b.txn_date : undefined,
    amount_paid: b.amount_paid, discount_amount: b.discount_amount === "" ? undefined : b.discount_amount, remarks: b.remarks,
    recorded_by: callerOf(req), hierarchy: req.hierarchyJson,
  });
  const { com_sno, div_sno, brn_sno, dept_sno } = row;
  broadcastPaymentUpdated({ payment_sno: row.payment_sno, payment_no: row.payment_no, status: "Processed", com_sno, div_sno, brn_sno, dept_sno }, { portal: true });
  return row;
}));
// A portal supplier's portal details (name, address, instructions - sql/91), added or fixed by the payments team from a payment
// waiting in Payment Run: the same access as recording that payment. Only portal suppliers; every change is logged with the old
// values and the caller's login (never a login from the body). Other open Payment Run screens reload on the broadcast.
let portalEditReady = false;
PaymentNetRouter.post("/run/portal-details", attachHierarchyScope, wrap(async (req) => {
  const b = req.body ?? {};
  if (!positiveInt(b.payment_sno)) throw httpError(400, "payment_sno is required");
  if (!portalEditReady) {
    const pool = await initializeDatabase();
    const r = await pool.request().query("SELECT OBJECT_ID('dbo.sp_nt_UpdateSupplierPortalDetails') AS p");
    if (r.recordset[0]?.p == null) throw httpError(503, "Editing portal details is not set up in the database yet - run grn-service sql/91, then try again.");
    portalEditReady = true;
  }
  const text = (v) => (typeof v === "string" ? v : undefined);
  const [row] = await exec("sp_nt_UpdateSupplierPortalDetails", {
    payment_sno: Number(b.payment_sno), payment_portal_name: text(b.payment_portal_name), payment_portal_url: text(b.payment_portal_url),
    payment_instructions: text(b.payment_instructions), changed_by: callerOf(req), hierarchy: req.hierarchyJson,
  });
  broadcastPaymentUpdated({ ...row, status: "Approved" }, { portal_details: true });
  return row;
}));
// ?limit= (default 50, at most 1000): Payment history lists the portal payments next to the bank runs
PaymentNetRouter.get("/run/portal-payments", attachHierarchyScope, wrap((req) => exec("sp_nt_GetPortalPayments", {
  hierarchy: req.hierarchyJson, limit: Math.min(positiveInt(req.query.limit) ?? 50, 1000),
}), 500));
// TDS taken on each invoice: invoice, supplier (deductee), company + TAN (deductor), section, rate, base, amount
PaymentNetRouter.get("/tds-records", attachHierarchyScope, wrap(
  (req) => exec("sp_nt_GetTdsRecords", { hierarchy: req.hierarchyJson, vendor_sno: positiveInt(req.query.vendor_sno) ?? undefined }), 500));
// Who (which login) typed which TDS rate on which invoice, newest first (sql/84). ?invoice_sno= for one invoice (Payment page "history");
// without it the newest entries under the caller's org scope. The login stored is the server-side caller, never a value from the body.
PaymentNetRouter.get("/tds-rate-log", attachHierarchyScope, wrap(
  (req) => exec("sp_nt_GetTdsRateLog", {
    hierarchy: req.hierarchyJson, invoice_sno: positiveInt(req.query.invoice_sno) ?? undefined, vendor_sno: positiveInt(req.query.vendor_sno) ?? undefined,
    limit: Math.min(positiveInt(req.query.limit) ?? 200, 1000),
  }), 500));

// A batch as the screen gets it: the sender's account number is cut to its last 4 digits.
const publicBatch = ({ sender_account_no, ...batch }) => ({ ...batch, sender_ac_last4: sender_account_no ? String(sender_account_no).slice(-4) : null });

// Pays the ticked payments against today's fund plan from one of the company's bank accounts (payment_bank_sno; left out = the
// company's default / only account). The bank file is built here and kept with the batch; the browser saves it to the user's
// Downloads folder (a server folder can be added later - `file.content` is all that is needed).
PaymentNetRouter.post("/run/proceed", attachHierarchyScope, wrap(async (req) => {
  const { payment_snos, fund_plan_amount, payment_date, payment_bank_sno } = req.body ?? {};
  if (!Array.isArray(payment_snos) || payment_snos.length === 0 || !payment_snos.every(positiveInt)) throw httpError(400, "Select at least one payment");
  const fund = Number(fund_plan_amount);
  if (!(fund > 0)) throw httpError(400, "Enter today's fund plan before proceeding");
  const hasBank = payment_bank_sno !== undefined && payment_bank_sno !== null && payment_bank_sno !== "";
  if (hasBank && !positiveInt(payment_bank_sno)) throw httpError(400, "Choose the bank account to pay from");
  await requireBankFileSchema();
  await applyGst2bCheck({ by: callerOf(req) });   // 2B may have changed since the list was opened; the batch pays what is left after the cut
  const [batchRows = [], itemRows = [], lineRows = []] = await exec("sp_nt_CreatePaymentBatch", {
    payment_snos: payment_snos.map(Number),
    fund_plan_amount: fund,
    payment_date: /^\d{4}-\d{2}-\d{2}$/.test(String(payment_date ?? "")) ? payment_date : undefined,
    payment_bank_sno: hasBank ? Number(payment_bank_sno) : undefined,
    created_by: callerOf(req),
    hierarchy: req.hierarchyJson,
  }, true);
  const batch = batchRows[0];
  let file;
  try {
    file = buildPaymentFile(batch, itemRows, lineRows, await loadBankFileLayout(batch.payment_bank_sno));
    if (file.lineCount > 0) await exec("sp_nt_SetPaymentBatchFile", { batch_sno: batch.batch_sno, file_name: file.fileName, file_content: file.content });
  } catch (error) {
    // the payments are already paid and journalled - say so instead of letting the run look like it failed
    throw new Error(`Payment run ${batch.batch_no} was created, but its file could not be written: ${error.message} Use "File" in Previous payment runs to get it.`);
  }

  const orgs = new Map(itemRows.map((i) => [`${i.com_sno}|${i.div_sno}|${i.brn_sno}|${i.dept_sno}`, i]));
  for (const o of orgs.values()) {
    broadcastPaymentUpdated({ payment_sno: o.payment_sno, payment_no: o.payment_no, status: "Processed", com_sno: o.com_sno, div_sno: o.div_sno, brn_sno: o.brn_sno, dept_sno: o.dept_sno },
      { batch_no: batch.batch_no, payment_snos: itemRows.map((i) => i.payment_sno) });
  }
  const sheet = file.lineCount > 0 ? buildVerificationSheet(batch, itemRows, lineRows) : null;
  return {
    batch: publicBatch(batch), items: itemRows, lines: lineRows, skipped: file.skipped,
    file: { file_name: file.fileName, mime_type: file.mimeType, content: file.content, line_count: file.lineCount, total_amount: file.totalAmount },
    // what the auditor / payment inputter checks the bank's screen against (invoice-wise, part payments, TDS) - saved by the browser next to the file
    verification: sheet && { file_name: sheet.fileName, mime_type: sheet.mimeType, content: sheet.content },
  };
}));

// Payment history: the newest runs first (?limit=, default 30, at most 1000), each with the suppliers and payments it paid so the
// screen can find "when did we pay X" without opening every run.
PaymentNetRouter.get("/run/batches", attachHierarchyScope, wrap(async (req) => {
  const limit = Math.min(positiveInt(req.query.limit) ?? 30, 1000);
  const [batches = []] = await exec("sp_nt_GetPaymentBatches", { hierarchy: req.hierarchyJson, limit }, true);
  return withRunPayees(batches);
}, 500));

// Never throws: without the per-run lines a run is still listed, just without its supplier names.
async function withRunPayees(batches) {
  if (!batches.length) return batches;
  const by = new Map();
  try {
    const pool = await initializeDatabase();
    const r = await pool.request()
      .input("ids", mssql.NVarChar(mssql.MAX), JSON.stringify(batches.map((b) => b.batch_sno)))
      .query(`SELECT i.batch_sno,
                     STRING_AGG(CAST(ISNULL(i.vendor_name, N'') AS NVARCHAR(MAX)), NCHAR(31)) WITHIN GROUP (ORDER BY i.line_no) AS vendor_names,
                     STRING_AGG(CAST(ISNULL(i.supp_code, N'') AS NVARCHAR(MAX)), NCHAR(31)) WITHIN GROUP (ORDER BY i.line_no) AS supp_codes,
                     STRING_AGG(CAST(p.payment_no AS NVARCHAR(MAX)), NCHAR(31)) WITHIN GROUP (ORDER BY i.line_no) AS payment_nos
              FROM dbo.payment_batch_item i JOIN dbo.payment_info p ON p.payment_sno = i.payment_sno
              WHERE i.batch_sno IN (SELECT TRY_CAST([value] AS INT) FROM OPENJSON(@ids))
              GROUP BY i.batch_sno`);
    const list = (s) => [...new Set(String(s ?? "").split("\u001f").map((x) => x.trim()).filter(Boolean))];
    for (const x of r.recordset ?? []) {
      if (x.batch_sno == null) continue;
      by.set(x.batch_sno, { vendor_names: list(x.vendor_names), supp_codes: list(x.supp_codes), payment_nos: list(x.payment_nos) });
    }
  } catch {
    // listed without supplier names
  }
  return batches.map((b) => ({ ...b, ...(by.get(b.batch_sno) ?? { vendor_names: [], supp_codes: [], payment_nos: [] }) }));
}
// (sp_nt_GetPaymentBatches already cuts the sender's account to sender_ac_last4 and the file content only comes with with_file)

async function loadBatch(req, withFile) {
  const id = positiveInt(req.params.id);
  if (!id) throw httpError(400, "Invalid batch id");
  const [batches = [], items = [], lines = [], reverseFiles = []] = await exec("sp_nt_GetPaymentBatches", { batch_sno: id, hierarchy: req.hierarchyJson, with_file: withFile }, true);
  if (!batches[0]) throw httpError(404, "Payment run not found, or it is outside your access");
  return { batch: batches[0], items, lines, reverseFiles };
}

// Each transfer of the bank file also carries the reference the file gave it (what the bank's reverse file quotes back), and the run
// the reverse files uploaded for it (sql/83).
PaymentNetRouter.get("/run/batches/:id", attachHierarchyScope, wrap(async (req) => {
  const { batch, items, lines, reverseFiles } = await loadBatch(req, false);
  const { file_content: _omit, ...rest } = batch;
  const inFile = new Set(fileItemsOf(items).map((i) => i.batch_item_sno));
  return { batch: rest, items: items.map((i) => ({ ...i, reference: inFile.has(i.batch_item_sno) ? referenceOf(i) : null })), lines, reverse_files: reverseFiles };
}, 500));

// ── the bank's answer to a run's file: the reverse file (sql/83) ────────────
// The browser sends the file's text; it is read by its header line and matched to the run's transfers on their reference
// (reverseFile.js). /preview only says what each line would do; the plain POST applies the lines that matched without a problem.
let reverseSchemaReady = false;
async function requireReverseSchema() {
  if (reverseSchemaReady) return;
  const pool = await initializeDatabase();
  const r = await pool.request().query("SELECT COL_LENGTH('dbo.payment_batch_item', 'returned_to_run') AS c, OBJECT_ID('dbo.sp_nt_ApplyPaymentReverseFile') AS p");
  if (r.recordset[0]?.c == null || r.recordset[0]?.p == null) throw httpError(503, "Reverse files are not set up in the database yet - run grn-service sql/83, then try again.");
  reverseSchemaReady = true;
}
export const REVERSE_FILE_MAX = 2_000_000;   // characters; a reverse file is one line per transfer

async function matchUpload(req) {
  const { file_name, content } = req.body ?? {};
  if (typeof content !== "string" || !content.trim()) throw httpError(400, "Choose the reverse file the bank sent");
  if (content.length > REVERSE_FILE_MAX) throw httpError(400, "The reverse file is too large (at most 2 MB of text)");
  await requireReverseSchema();
  const { batch, items } = await loadBatch(req, false);
  if (fileItemsOf(items).length === 0) throw httpError(400, "This run has no NEFT / RTGS transfer, so the bank sends no reverse file for it");
  let parsed;
  try { parsed = parseReverseFile(content); } catch (error) { throw httpError(400, error.message); }
  const fileName = String(file_name ?? "").trim().slice(0, 260) || "reverse file";
  return { fileName, content, batch, match: matchReverseFile(batch, items, parsed) };
}

PaymentNetRouter.post("/run/batches/:id/reverse-file/preview", attachHierarchyScope, wrap(async (req) => {
  const { fileName, batch, match } = await matchUpload(req);
  return { file_name: fileName, batch_no: batch.batch_no, run_file_name: batch.file_name, lines: match.lines, missing: match.missing, summary: match.summary };
}));

PaymentNetRouter.post("/run/batches/:id/reverse-file", attachHierarchyScope, wrap(async (req) => {
  const { fileName, content, batch, match } = await matchUpload(req);
  if (match.apply.length === 0) throw httpError(400, "No line of the reverse file could be matched to this run - nothing was changed");
  const by = callerOf(req);
  const [fileRows = [], results = []] = await exec("sp_nt_ApplyPaymentReverseFile", {
    batch_sno: batch.batch_sno, uploaded_by: by, file_name: fileName, file_content: content, hierarchy: req.hierarchyJson,
    unmatched_count: match.summary.problems, lines: match.apply,
  }, true);
  for (const r of results) {
    if (!["PAID", "UPDATED", "PENDING", "FAILED"].includes(r.result)) continue;
    broadcastPaymentUpdated({ ...r, status: r.payment_status }, { batch_no: batch.batch_no, bank_status: r.new_status });
    if (r.result === "FAILED" && r.created_by && r.created_by !== by) {
      notify(r.created_by, "warning", "Payment not paid by the bank",
        `${r.payment_no} (${rupees(r.amount)}) to ${r.vendor_name ?? "the supplier"} was ${String(r.new_status).toLowerCase()} by the bank${r.bank_reason ? `: ${r.bank_reason}` : ""}. It is back in Payment Run to be paid again.`,
        { payment_sno: r.payment_sno });
    }
  }
  return { file: fileRows[0] ?? null, results, problems: match.lines.filter((l) => l.problem), missing: match.missing };
}));

// A payment the bank did not pay is paid another way next time: NEFT <-> RTGS, or cheque / DD / cash (then it is not in the bank file).
export const RETRY_MODES = ["NEFT", "RTGS", "CHEQUE", "DD", "CASH"];
PaymentNetRouter.post("/run/change-mode", attachHierarchyScope, wrap(async (req) => {
  const { payment_sno, mode, reason } = req.body ?? {};
  if (!positiveInt(payment_sno)) throw httpError(400, "payment_sno is required");
  const m = String(mode ?? "").trim().toUpperCase();
  if (!RETRY_MODES.includes(m)) throw httpError(400, "Choose NEFT, RTGS, cheque, DD or cash");
  await requireReverseSchema();
  const [row] = await exec("sp_nt_ChangeFailedPaymentMode", {
    payment_sno: Number(payment_sno), mode: m, reason: reason == null ? undefined : String(reason).trim().slice(0, 300), changed_by: callerOf(req), hierarchy: req.hierarchyJson,
  });
  broadcastPaymentUpdated(row, { mode: row.mode });
  return row;
}));

// The sheet to check the bank file against: one row per payment x invoice, part payments marked, TDS and what is left (sql/70).
PaymentNetRouter.get("/run/batches/:id/verification", attachHierarchyScope, wrap(async (req) => {
  const { batch, items, lines } = await loadBatch(req, false);
  const sheet = buildVerificationSheet(batch, items, lines);
  if (sheet.lineCount === 0) throw httpError(404, "This run has no bank transfer, so there is nothing to verify");
  return { file_name: sheet.fileName, mime_type: sheet.mimeType, content: sheet.content, line_count: sheet.lineCount, total_amount: sheet.totalAmount };
}, 500));

// The file again (Download on a past run). A run from before sql/68 (no file_type) has its CSV stored; a bank file that was never
// stored is written again from the batch lines and the sender the run remembers, so it comes out the same.
PaymentNetRouter.get("/run/batches/:id/file", attachHierarchyScope, wrap(async (req) => {
  const { batch, items, lines } = await loadBatch(req, true);
  if (batch.file_content) {
    return { file_name: batch.file_name, mime_type: batch.file_type ? "text/plain;charset=utf-8" : "text/csv;charset=utf-8", content: batch.file_content };
  }
  if (!batch.file_type) throw httpError(404, "No file was stored for this run");
  const file = buildPaymentFile(batch, items, lines, await loadBankFileLayout(batch.payment_bank_sno));
  if (file.lineCount === 0) throw httpError(404, "This run has no bank transfer, so there is no file");
  await exec("sp_nt_SetPaymentBatchFile", { batch_sno: batch.batch_sno, file_name: file.fileName, file_content: file.content });
  return { file_name: file.fileName, mime_type: file.mimeType, content: file.content };
}, 500));

// ── unpaid GST (sql/75) ─────────────────────────────────────────────────────
// GET /unpaid-gst?status=&vendor_sno=   invoices paid without their GST (not in GSTR-2B yet) and the ones released since
// POST /unpaid-gst/check                looks at GSTR-2B again now and moves what 2B has to Payment Run -> { released: [payments] }
const needsSql75 = (error) => (/Could not find stored procedure|Invalid object name/i.test(error.message)
  ? httpError(503, "Unpaid GST is not set up in the database yet - run grn-service sql/75, then try again.") : error);
PaymentNetRouter.get("/unpaid-gst", attachHierarchyScope, wrap(async (req) => {
  try {
    return await exec("sp_nt_GetUnpaidGst", {
      status: ["Awaiting 2B", "Released", "Closed"].includes(req.query.status) ? req.query.status : undefined,
      vendor_sno: positiveInt(req.query.vendor_sno) ?? undefined, hierarchy: req.hierarchyJson,
    });
  } catch (error) { throw needsSql75(error); }
}, 500));
PaymentNetRouter.post("/unpaid-gst/check", wrap(async (req) => {
  try {
    return { released: await releaseUnpaidGst({ by: callerOf(req), vendor_sno: positiveInt(req.body?.vendor_sno) ?? undefined, quiet: false }) };
  } catch (error) { throw needsSql75(error); }
}));

// TDS / GST / other statutory amounts: their own register, run and bank file (sql/73), apart from the supplier run above.
PaymentNetRouter.use("/statutory", StatutoryRouter);

export default PaymentNetRouter;
