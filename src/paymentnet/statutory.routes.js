import express from "express";
import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";
import { attachHierarchyScope } from "../middleware/hierarchyScope.js";
import { buildStatutoryFile } from "./paymentFile.js";
import { loadBankFileLayout } from "./bankFileLayout.js";

// Statutory payments (sql/73): TDS payable, GST payable and other amounts owed to the government / others, paid in their own
// run with their own bank upload file - apart from the supplier Payment Run. Mounted at /api/payment_net/statutory.
//   GET  /payables?kind=&status=   the register (TDS fills itself from paid supplier payments) + GST held on supplier bills until 2B
//   POST /payables                 key in a GST / other amount            POST /payables/cancel   withdraw an open one keyed in by hand
//   GET  /payees  POST /payees     who is paid: a bank account (account, IFSC, mode) or, from sql/82, a website / portal (name, URL, instructions)
//   POST /run                      pays the ticked amounts of ONE kind from one of the company's bank accounts -> run + the bank file
//   POST /online-payment           (sql/82) the ticked amounts of ONE online payee were paid on its portal: record how, the challan no and date
//   GET  /runs  GET /runs/:id/file the earlier runs (bank files and online payments), and a bank run's file again
const StatutoryRouter = express.Router();

const userOf = (req) => (Array.isArray(req.user) ? req.user[0] : req.user);
const callerOf = (req) => req.user_ecno ?? userOf(req)?.ecno ?? userOf(req)?.login_id ?? null;
const httpError = (status, message) => Object.assign(new Error(message), { status });
const positiveInt = (v) => (Number.isInteger(Number(v)) && Number(v) > 0 ? Number(v) : null);
const KINDS = ["TDS", "GST", "OTHER"];

async function exec(proc, params, allRecordsets = false) {
  try {
    const pool = await initializeDatabase();
    const request = pool.request();
    if (params !== undefined) request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(params));
    const result = await request.execute(proc);
    return allRecordsets ? result.recordsets : result.recordset;
  } catch (error) {
    throw new Error(error.message);   // SP THROW text is user-facing validation
  }
}
const wrap = (fn, status = 400) => async (req, res) => {
  try {
    res.json({ success: true, data: await fn(req) });
  } catch (error) {
    res.status(error.status ?? status).json({ success: false, error: error.message });
  }
};
const kindOf = (v, required = false) => {
  const k = String(v ?? "").toUpperCase();
  if (KINDS.includes(k)) return k;
  if (required) throw httpError(400, "Choose TDS, GST or other");
  return undefined;
};

// The register needs sql/73. Say so plainly instead of a raw "could not find stored procedure".
let schemaReady = false;
async function requireSchema() {
  if (schemaReady) return;
  const pool = await initializeDatabase();
  const r = await pool.request().query("SELECT OBJECT_ID('dbo.sp_nt_CreateStatutoryBatch') AS p, OBJECT_ID('dbo.statutory_payable') AS t");
  if (r.recordset[0]?.p == null || r.recordset[0]?.t == null) throw httpError(503, "Statutory payments are not set up in the database yet - run grn-service sql/73, then try again.");
  schemaReady = true;
}
// Online payees and their payments need sql/82 on top.
let onlineReady = false;
async function requireOnlineSchema() {
  await requireSchema();
  if (onlineReady) return;
  const pool = await initializeDatabase();
  const r = await pool.request().query("SELECT OBJECT_ID('dbo.sp_nt_RecordStatutoryOnlinePayment') AS p");
  if (r.recordset[0]?.p == null) throw httpError(503, "Online payees are not set up in the database yet - run grn-service sql/82, then try again.");
  onlineReady = true;
}

// The ways an online statutory payment can have been made (sql/82 checks the same list).
export const ONLINE_MODES = ["Net Banking", "UPI", "Debit Card", "Credit Card", "NEFT/RTGS", "Other"];
const isYes = (v) => v === true || v === "Y" || v === "true" || v === 1 || v === "1";

StatutoryRouter.get("/payables", attachHierarchyScope, wrap(async (req) => {
  await requireSchema();
  const [payables = [], gstHeld = []] = await exec("sp_nt_GetStatutoryPayables", {
    kind: kindOf(req.query.kind), status: ["Open", "Paid"].includes(req.query.status) ? req.query.status : undefined, hierarchy: req.hierarchyJson,
  }, true);
  return { payables, gstHeld };
}, 500));

StatutoryRouter.post("/payables", attachHierarchyScope, wrap(async (req) => {
  await requireSchema();
  const b = req.body ?? {};
  const [row] = await exec("sp_nt_AddStatutoryPayable", {
    kind: kindOf(b.kind, true), head_name: b.head_name, ref_no: b.ref_no, period_label: b.period_label, amount: b.amount,
    due_date: /^\d{4}-\d{2}-\d{2}$/.test(String(b.due_date ?? "")) ? b.due_date : undefined, narration: b.narration,
    payee_sno: positiveInt(b.payee_sno) ?? undefined, com_sno: positiveInt(b.com_sno) ?? undefined, div_sno: positiveInt(b.div_sno) ?? undefined, brn_sno: positiveInt(b.brn_sno) ?? undefined,
    created_by: callerOf(req), hierarchy: req.hierarchyJson,
  });
  return row;
}));

StatutoryRouter.post("/payables/cancel", attachHierarchyScope, wrap(async (req) => {
  await requireSchema();
  if (!positiveInt(req.body?.stat_sno)) throw httpError(400, "stat_sno is required");
  const [row] = await exec("sp_nt_CancelStatutoryPayable", { stat_sno: Number(req.body.stat_sno), reason: req.body.reason, hierarchy: req.hierarchyJson });
  return row;
}));

// The account number comes back whole to the screen that edits the payee (the same people who run the payments); lists elsewhere show the last 4.
StatutoryRouter.get("/payees", wrap(async (req) => { await requireSchema(); return exec("sp_nt_GetStatutoryPayees", { kind: kindOf(req.query.kind) }); }, 500));
StatutoryRouter.post("/payees", wrap(async (req) => {
  const b = req.body ?? {};
  const online = isYes(b.pay_via_portal);
  // before sql/82 the database would quietly save an online payee as a bank one with no account - say what is missing instead
  await (online ? requireOnlineSchema() : requireSchema());
  const [row] = await exec("sp_nt_UpsertStatutoryPayee", {
    payee_sno: positiveInt(b.payee_sno) ?? undefined, kind: kindOf(b.kind, true), payee_name: b.payee_name, reference_no: b.reference_no,
    com_sno: positiveInt(b.com_sno) ?? undefined, is_default: b.is_default ? "Y" : "N", is_active: b.is_active === false ? "N" : "Y", modified_by: callerOf(req),
    pay_via_portal: online ? "Y" : "N",
    ...(online
      ? { payment_portal_name: b.payment_portal_name, payment_portal_url: b.payment_portal_url, payment_instructions: b.payment_instructions }
      : { ac_number: b.ac_number, ifsc: b.ifsc, bank_name: b.bank_name, branch_name: b.branch_name, pay_mode: b.pay_mode }),
  });
  return row;
}));

const publicBatch = ({ sender_account_no, file_content: _omit, ...batch }) => ({ ...batch, sender_ac_last4: sender_account_no ? String(sender_account_no).slice(-4) : null });

StatutoryRouter.post("/run", attachHierarchyScope, wrap(async (req) => {
  await requireSchema();
  const { stat_snos, payment_date, payment_bank_sno } = req.body ?? {};
  if (!Array.isArray(stat_snos) || stat_snos.length === 0 || !stat_snos.every(positiveInt)) throw httpError(400, "Select at least one amount");
  const hasBank = payment_bank_sno !== undefined && payment_bank_sno !== null && payment_bank_sno !== "";
  if (hasBank && !positiveInt(payment_bank_sno)) throw httpError(400, "Choose the bank account to pay from");
  const [batchRows = [], itemRows = []] = await exec("sp_nt_CreateStatutoryBatch", {
    stat_snos: stat_snos.map(Number),
    payment_date: /^\d{4}-\d{2}-\d{2}$/.test(String(payment_date ?? "")) ? payment_date : undefined,
    payment_bank_sno: hasBank ? Number(payment_bank_sno) : undefined,
    created_by: callerOf(req), hierarchy: req.hierarchyJson,
  }, true);
  const batch = batchRows[0];
  let file;
  try {
    file = buildStatutoryFile(batch, itemRows, await loadBankFileLayout(batch.payment_bank_sno));
    await exec("sp_nt_SetStatutoryBatchFile", { batch_sno: batch.batch_sno, file_name: file.fileName, file_content: file.content });
  } catch (error) {
    // the amounts are already marked paid - say so instead of letting the run look like it failed
    throw new Error(`Statutory run ${batch.batch_no} was created, but its file could not be written: ${error.message} Use "File" in Previous runs to get it.`);
  }
  return {
    batch: publicBatch(batch), items: itemRows,
    file: { file_name: file.fileName, mime_type: file.mimeType, content: file.content, line_count: file.lineCount, total_amount: file.totalAmount },
  };
}));

// Paid on the payee's portal: no bank file. Records how it was paid, the challan / transaction no and the date (sql/82).
StatutoryRouter.post("/online-payment", attachHierarchyScope, wrap(async (req) => {
  await requireOnlineSchema();
  const { stat_snos, txn_mode, txn_id, txn_date, remarks } = req.body ?? {};
  if (!Array.isArray(stat_snos) || stat_snos.length === 0 || !stat_snos.every(positiveInt)) throw httpError(400, "Select at least one amount");
  const mode = ONLINE_MODES.find((m) => m.toLowerCase() === String(txn_mode ?? "").trim().toLowerCase());
  if (!mode) throw httpError(400, `Choose how it was paid: ${ONLINE_MODES.join(", ")}`);
  const txn = String(txn_id ?? "").trim();
  if (!txn) throw httpError(400, "Enter the challan / transaction number");
  const [batchRows = [], itemRows = []] = await exec("sp_nt_RecordStatutoryOnlinePayment", {
    stat_snos: stat_snos.map(Number), txn_mode: mode, txn_id: txn,
    txn_date: /^\d{4}-\d{2}-\d{2}$/.test(String(txn_date ?? "")) ? txn_date : undefined,
    remarks: typeof remarks === "string" && remarks.trim() ? remarks.trim() : undefined,
    recorded_by: callerOf(req), hierarchy: req.hierarchyJson,
  }, true);
  return { batch: publicBatch(batchRows[0]), items: itemRows };
}));

StatutoryRouter.get("/runs", attachHierarchyScope, wrap(async (req) => {
  await requireSchema();
  const [batches = []] = await exec("sp_nt_GetStatutoryBatches", { hierarchy: req.hierarchyJson, kind: kindOf(req.query.kind), limit: 30 }, true);
  return batches.map(publicBatch);
}, 500));

// The file again. Stored with the run; written again from the run's lines when it was never stored, so it comes out the same.
StatutoryRouter.get("/runs/:id/file", attachHierarchyScope, wrap(async (req) => {
  await requireSchema();
  const id = positiveInt(req.params.id);
  if (!id) throw httpError(400, "Invalid run id");
  const [batches = [], items = []] = await exec("sp_nt_GetStatutoryBatches", { batch_sno: id, hierarchy: req.hierarchyJson, with_file: true }, true);
  const batch = batches[0];
  if (!batch) throw httpError(404, "Statutory run not found, or it is outside your access");
  if (batch.pay_channel === "ONLINE") {
    const how = [batch.txn_mode, batch.txn_id].filter(Boolean).join(" ");
    throw httpError(400, `${batch.batch_no} was paid online${how ? ` (${how})` : ""} - there is no bank file for it.`);
  }
  if (batch.file_content) return { file_name: batch.file_name, mime_type: "text/plain;charset=utf-8", content: batch.file_content };
  const file = buildStatutoryFile(batch, items, await loadBankFileLayout(batch.payment_bank_sno));
  await exec("sp_nt_SetStatutoryBatchFile", { batch_sno: batch.batch_sno, file_name: file.fileName, file_content: file.content });
  return { file_name: file.fileName, mime_type: file.mimeType, content: file.content };
}, 500));

export default StatutoryRouter;
