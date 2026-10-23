import express from "express";
import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";
import { broadcast } from "../utils/socketBroadcast.js";
import { createInAppNotification } from "../utils/notifyClient.js";
import { attachHierarchyScope, orgRoomTargets } from "../middleware/hierarchyScope.js";
import { buildPaymentFile } from "./paymentFile.js";

// Payment backend: payable bills with GRN / 2B / TDS context, the adjustments available for the bills being paid
// (advances, debit/credit notes, TDS sections), and the payment life cycle (sql/44, sql/48, sql/64, sql/65):
//   POST /release  saves a payment (sp_nt_ReleasePaymentNet) -> 'Pending Approval', or 'Approved' when no workflow is configured
//   POST /approve  an approver passes / rejects / forwards / sends it back (stages and value conditions: sql/66)
//                                                            -> 'Approved' | 'Rejected' | stays 'Pending Approval' with the next approver
//   POST /cancel   withdraws a payment that is not paid yet   -> 'Cancelled'
//   GET  /entries  the approval screen and the Payment Run list (approved payments waiting for money, MSME / due dates)
//   GET  /run/senders  the company's bank accounts a run can be paid from (Payment Bank master, sql/138)
//   POST /run/proceed  pays the ticked payments against today's fund plan from one of them: batch, journals, and the bank payment file (sql/68)
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

PaymentNetRouter.get("/bills", wrap((req) => exec("sp_nt_GetPayableBillsNet", { vendor_sno: req.query.vendor_sno ? Number(req.query.vendor_sno) : undefined }), 500));

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
  const [advances = [], debitNotes = [], creditNotes = []] =
    await exec("sp_nt_GetPaymentAdjustments", { vendor_sno: Number(req.query.vendor_sno), invoice_snos }, true);
  const tdsSections = await exec("sp_nt_GetTdsSections", {});   // carries applies_to (Service / Product / Both), sql/62
  return { advances, debitNotes, creditNotes, tdsSections };
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

// Save. The payment is created 'Pending Approval' (first approver notified) or 'Approved' when the department has no Payment workflow.
PaymentNetRouter.post("/release", wrap(async (req) => {
  const [row] = await exec("sp_nt_ReleasePaymentNet", releaseBody(req, false));
  broadcastPaymentReleased(req.body, row);
  broadcastPaymentUpdated(row);
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
  const [entries = [], lines = [], settings = []] = await exec("sp_nt_GetPaymentEntries", {
    view,
    ecno: callerOf(req),
    hierarchy: req.hierarchyJson,
    vendor_sno: positiveInt(req.query.vendor_sno) ?? undefined,
    com_sno: positiveInt(req.query.com_sno) ?? undefined,
    status: req.query.status ? String(req.query.status) : undefined,
    with_lines: req.query.with_lines,
  }, true);
  return { entries, lines, settings: Object.fromEntries(settings.map((s) => [s.setting_key, s.setting_value])) };
}, 500));

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
  return {
    entry: entries[0], lines, history, adjustments, stages,
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
  } else if (row.result === "REJECTED") {
    notify(row.created_by, "warning", "Payment rejected",
      `${row.payment_no} was rejected${comments ? `: ${comments}` : ""}. Its invoices are free to be paid again.`, { payment_sno: row.payment_sno });
  }
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
// The bank accounts a run of one company can be paid from - the Payment Bank master (backend-stpl sql/138). Only the last 4 digits go out.
PaymentNetRouter.get("/run/senders", attachHierarchyScope, wrap(
  (req) => exec("sp_nt_GetPaymentSenders", { com_sno: positiveInt(req.query.com_sno) ?? undefined, hierarchy: req.hierarchyJson }), 500));

// The bank file needs sql/68 (sender columns + procedures). Refuse BEFORE any payment is paid when this code runs against a database
// that does not have it yet - otherwise the run would be paid and its file could not be written. Remembered once true.
let bankFileSchemaReady = false;
async function requireBankFileSchema() {
  if (bankFileSchemaReady) return;
  const pool = await initializeDatabase();
  const r = await pool.request().query("SELECT COL_LENGTH('dbo.payment_batch', 'file_type') AS c, OBJECT_ID('dbo.sp_nt_GetPaymentSenders') AS p");
  if (r.recordset[0]?.c == null || r.recordset[0]?.p == null) throw httpError(503, "The payment bank file is not set up in the database yet - run grn-service sql/68 (after backend-stpl sql/138), then try again.");
  bankFileSchemaReady = true;
}

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
  const [batchRows = [], itemRows = []] = await exec("sp_nt_CreatePaymentBatch", {
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
    file = buildPaymentFile(batch, itemRows);
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
  return {
    batch: publicBatch(batch), items: itemRows, skipped: file.skipped,
    file: { file_name: file.fileName, mime_type: file.mimeType, content: file.content, line_count: file.lineCount, total_amount: file.totalAmount },
  };
}));

PaymentNetRouter.get("/run/batches", attachHierarchyScope, wrap(async (req) => {
  const [batches = []] = await exec("sp_nt_GetPaymentBatches", { hierarchy: req.hierarchyJson, limit: 30 }, true);
  return batches;
}, 500));
// (sp_nt_GetPaymentBatches already cuts the sender's account to sender_ac_last4 and the file content only comes with with_file)

async function loadBatch(req, withFile) {
  const id = positiveInt(req.params.id);
  if (!id) throw httpError(400, "Invalid batch id");
  const [batches = [], items = []] = await exec("sp_nt_GetPaymentBatches", { batch_sno: id, hierarchy: req.hierarchyJson, with_file: withFile }, true);
  if (!batches[0]) throw httpError(404, "Payment run not found, or it is outside your access");
  return { batch: batches[0], items };
}

PaymentNetRouter.get("/run/batches/:id", attachHierarchyScope, wrap(async (req) => {
  const { batch, items } = await loadBatch(req, false);
  const { file_content: _omit, ...rest } = batch;
  return { batch: rest, items };
}, 500));

// The file again (Download on a past run). A run from before sql/68 (no file_type) has its CSV stored; a bank file that was never
// stored is written again from the batch lines and the sender the run remembers, so it comes out the same.
PaymentNetRouter.get("/run/batches/:id/file", attachHierarchyScope, wrap(async (req) => {
  const { batch, items } = await loadBatch(req, true);
  if (batch.file_content) {
    return { file_name: batch.file_name, mime_type: batch.file_type ? "text/plain;charset=utf-8" : "text/csv;charset=utf-8", content: batch.file_content };
  }
  if (!batch.file_type) throw httpError(404, "No file was stored for this run");
  const file = buildPaymentFile(batch, items);
  if (file.lineCount === 0) throw httpError(404, "This run has no bank transfer, so there is no file");
  await exec("sp_nt_SetPaymentBatchFile", { batch_sno: batch.batch_sno, file_name: file.fileName, file_content: file.content });
  return { file_name: file.fileName, mime_type: file.mimeType, content: file.content };
}, 500));

export default PaymentNetRouter;
