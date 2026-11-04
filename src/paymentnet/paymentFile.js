// paymentFile.js - the bank payment file of a Payment Run (sql/68, sql/70): the file the company uploads to its bank to pay suppliers by NEFT / RTGS.
//
// The LAYOUT of the file is not here: it is the Bank File Format of the payment bank account the run is paid from (Masters > Finance >
// Bank File Format + Bank File Format Columns, backend-stpl sql/149), rendered by bankFileFormat.js. This file works out the VALUES a
// column can pick from (valuesOf) and decides which payments go in. A run whose account has no format is refused - there is no
// built-in layout to fall back on.
//
// What DETAIL_1-3 carry: 1 the supplier's invoice number(s), 2 FULL, or PART / FINAL with this payment's share of the invoice, 3 what was
// taken off - TDS, advance, debit / credit note (at most 30 characters each). The checker approves the file in the BANK's application,
// not here, so these tell one transfer from the next and show that a part payment is a part payment. buildVerificationSheet() gives
// the same facts as a sheet to check against.
//
// The file NAME (<prefix>_<client code>_<client code><DDMM>.<seq>) is made by sp_nt_CreatePaymentBatch under the run's lock and
// arrives here as batch.file_name.
//
// Only real bank transfers go in: channel BANK with a mode that has a transfer type (NEFT / RTGS). Cheque / cash / DD (MANUAL),
// suppliers paid on their portal (PORTAL), payments the advances and notes settle entirely (ADJUSTMENT) and other bank modes
// such as UPI stay out - the bank would reject them in an upload - and are returned in `skipped` so the screen can list them.
//
// A value that holds the separator or a line break would shift every field after it, so those are turned into spaces (bankFileFormat.js).

import { renderFile } from "./bankFileFormat.js";

export const FILE_TYPES = { BANK_UPLOAD: "BANK_UPLOAD" };
export const POSITION_COUNT = 28;
export const TRANSFER_TYPE = { NEFT: "N", RTGS: "R" };
export const NAME_MAX = 20;
export const REFERENCE_MAX = 20;
export const DETAIL_MAX = 30;
/** zero-based indexes of the three payment-details positions (15, 16, 17) */
export const DETAIL_POSITIONS = [14, 15, 16];

const isoDate = (d) => {
  if (!d) return "";
  const s = d instanceof Date ? d.toISOString() : String(d);
  return s.slice(0, 10);
};
const ddmmyyyy = (d) => {
  const s = isoDate(d);
  return s ? `${s.slice(8, 10)}/${s.slice(5, 7)}/${s.slice(0, 4)}` : "";
};
const money = (n) => Number(n ?? 0).toFixed(2);
/** whole rupees without .00 (short, for the 30-character payment details) */
const short = (n) => (Number.isInteger(Number(n)) ? String(Number(n)) : money(n));

const cell = (v) => String(v ?? "").replace(/[\r\n\t,]+/g, " ").replace(/ {2,}/g, " ").trim();
const alnum = (v) => String(v ?? "").replace(/[^A-Za-z0-9]/g, "");
const cut = (v, n) => cell(v).slice(0, n).trimEnd();

/** Join whole items up to n characters; when not all fit the rest is counted ("A/B+3") instead of cutting an item in half. */
function fitList(list, sep, n) {
  if (list.join(sep).length <= n) return list.join(sep);
  let kept = 0;
  for (let k = 1; k <= list.length; k++) {
    const text = list.slice(0, k).join(sep) + (k < list.length ? `+${list.length - k}` : "");
    if (text.length > n) break;
    kept = k;
  }
  return kept === 0 ? cut(list[0], n) : list.slice(0, kept).join(sep) + (kept < list.length ? `+${list.length - kept}` : "");
}

/** <supplier id>-<payment no>, cut to REFERENCE_MAX from the supplier side so the payment number always stays whole. */
export function referenceOf(item) {
  const pay = alnum(item.payment_no);
  const who = alnum(item.vendor_sno);
  if (!who) return pay.slice(0, REFERENCE_MAX);
  const room = REFERENCE_MAX - 1 - pay.length;
  return room > 0 ? `${who.slice(0, room)}-${pay}` : pay.slice(0, REFERENCE_MAX);
}

/** The invoice lines (sql/70 payment_batch_item_invoice) of one payment, in invoice order. */
const linesOf = (item, lines) => (lines ?? []).filter((l) => (item.payment_sno != null && l.payment_sno === item.payment_sno) || (item.batch_item_sno != null && l.batch_item_sno === item.batch_item_sno));

/** Supplier invoice number(s) of the payment: "INV-77/INV-78". Falls back to what the item stored when the run has no invoice lines (runs before sql/70). */
export function invoiceText(item, itemLines) {
  const fromLines = itemLines.map((l) => cell(l.supplier_invoice_no) || cell(l.invoice_no)).filter(Boolean);
  const list = fromLines.length > 0 ? fromLines : String(item.supplier_invoice_nos || item.invoice_nos || "").split(",").map(cell).filter(Boolean);
  return fitList([...new Set(list)], "/", DETAIL_MAX);
}

/**
 * Whether the transfer is the whole invoice or a part of it, so the checker does not take a part payment for a short payment.
 *   one invoice, paid whole      FULL
 *   one invoice, part            PART 5000.00/10000.00   (this payment / what the invoice may be paid in all)
 *   the last part                FINAL 5000.00/10000.00
 *   several invoices             FULL, or "3 INV 2 PART" when some of them are part payments
 * Empty when the run has no invoice lines (runs before sql/70).
 */
export function kindText(itemLines) {
  if (itemLines.length === 0) return "";
  const parts = itemLines.filter((l) => l.kind !== "FULL");
  if (itemLines.length === 1) {
    const l = itemLines[0];
    return l.kind === "FULL" ? "FULL" : cut(`${l.kind} ${money(l.this_gross)}/${money(l.payable_total)}`, DETAIL_MAX);
  }
  return parts.length === 0 ? "FULL" : cut(`${itemLines.length} INV ${parts.length} PART`, DETAIL_MAX);
}

/** What was taken off the invoices on the way to the amount the bank sends: "TDS 100 ADV 50.50 DN 10" (whole rupees without .00). Empty when nothing was. */
export function deductionText(item) {
  const parts = [];
  if (Number(item.tds_amount) > 0) parts.push(`TDS ${short(item.tds_amount)}`);
  if (Number(item.advance_amount) > 0) parts.push(`ADV ${short(item.advance_amount)}`);
  const note = Number(item.note_amount);
  if (note > 0) parts.push(`DN ${short(note)}`);
  if (note < 0) parts.push(`CN ${short(-note)}`);
  return fitList(parts, " ", DETAIL_MAX);
}

const SKIP_REASON = {
  MANUAL: "Cheque / cash / DD - not a bank transfer",
  PORTAL: "Supplier is paid on their portal",
  ADJUSTMENT: "Nothing to pay out - advances / notes settle it",
};

// ── OLD built-in layout (commented out: the file is now written from the Bank File Format master, see renderFile) ──────────────
// Kept for reference. It wrote 28 comma separated positions:
//   1 transfer type (N/R)  3 account no  4 amount  5 name (first 20)  14 reference  15-17 payment details 1-3
//   23 payment date dd/mm/yyyy  25 IFSC  26 bank  27 branch  (28 left empty)
//
// /** The 28 positions of one transfer. */
// function lineOf(item, batch, lines) {
//   const mine = linesOf(item, lines);
//   const f = new Array(POSITION_COUNT).fill("");
//   f[0] = TRANSFER_TYPE[String(item.mode ?? "").toUpperCase()];
//   f[2] = cell(item.account_no);
//   f[3] = money(item.amount);
//   f[4] = cell(item.beneficiary_name || item.vendor_name).slice(0, NAME_MAX).trimEnd();
//   f[13] = referenceOf(item);
//   [f[14], f[15], f[16]] = [invoiceText(item, mine), kindText(mine), deductionText(item)];
//   f[22] = ddmmyyyy(batch.batch_date);
//   f[24] = cell(item.ifsc).toUpperCase();
//   f[25] = cell(item.bank_name);
//   f[26] = cell(item.branch_name);
//   return f.join(",");
// }
//
// and in buildPaymentFile:
//   content: inLines.map((i) => lineOf(i, batch, lines)).join("\n"),

/**
 * What the Bank File Format masters can pick from for one transfer (bankFileFormat.js SOURCE_FIELDS), same values the built-in
 * layout puts in its positions. `layoutDef.sender` = the payment bank account's { ac_holder_name, ifsc }.
 */
function valuesOf(item, batch, lines, serial, layoutDef) {
  const mine = linesOf(item, lines);
  const sender = layoutDef?.sender ?? {};
  return {
    TRANSFER_TYPE: TRANSFER_TYPE[String(item.mode ?? "").toUpperCase()] ?? "",
    MODE: String(item.mode ?? "").toUpperCase(),
    ACCOUNT_NO: cell(item.account_no),
    AMOUNT: money(item.amount),
    BENEFICIARY_NAME: cell(item.beneficiary_name || item.vendor_name),
    REFERENCE: referenceOf(item),
    PAYMENT_NO: cell(item.payment_no),
    SUPPLIER_CODE: cell(item.vendor_sno),
    DETAIL_1: invoiceText(item, mine), DETAIL_2: kindText(mine), DETAIL_3: deductionText(item),
    IFSC: cell(item.ifsc).toUpperCase(), BANK_NAME: cell(item.bank_name), BRANCH_NAME: cell(item.branch_name),
    SERIAL_NO: String(serial),
    SENDER_ACCOUNT_NO: cell(batch.sender_account_no), SENDER_NAME: cell(sender.ac_holder_name), SENDER_IFSC: cell(sender.ifsc).toUpperCase(),
    SENDER_BANK_NAME: cell(batch.sender_bank_name), SENDER_CLIENT_CODE: cell(batch.sender_client_code), SENDER_EMAIL: cell(batch.sender_alert_email),
  };
}

/** The file is written only from a Bank File Format master (the payment bank account's), never from a layout in code. */
function requireLayout(layoutDef, batch) {
  if (!layoutDef?.format) throw new Error(`Run ${batch.batch_no} has no Bank File Format - choose one on the Payment Bank account (Masters > Finance) and try again.`);
}

const inFile = (i) => i.channel === "BANK" && Object.hasOwn(TRANSFER_TYPE, String(i.mode ?? "").toUpperCase());

/**
 * @param batch  { batch_no, batch_date, file_name, file_type } - the run
 * @param items  payment_batch_item rows in file order ({ channel, payment_no, vendor_sno, mode, amount, beneficiary_name, account_no, ifsc, bank_name, branch_name, tds_amount, advance_amount, note_amount, ... })
 * @param lines  payment_batch_item_invoice rows of the run (what each payment paid on each invoice); optional - runs before sql/70 have none
 * @returns { fileName, mimeType, content, lineCount, totalAmount, skipped: [{ payment_no, vendor_name, amount, channel, reason }] }
 *          A run with nothing to upload (no bank line, so no sender and no file type) gives an empty file: fileName '', lineCount 0.
 */
export function buildPaymentFile(batch, items, lines = [], layoutDef) {
  const inLines = items.filter(inFile);
  const skipped = items.filter((i) => !inFile(i)).map((i) => ({
    payment_no: i.payment_no, vendor_name: i.vendor_name, amount: Number(i.amount), channel: i.channel,
    reason: i.channel === "BANK" ? `${i.mode} is not paid through the bank file - pay it another way` : (SKIP_REASON[i.channel] ?? "Not a bank transfer"),
  }));
  const base = { mimeType: "text/plain;charset=utf-8", skipped };

  if (inLines.length === 0) return { ...base, fileName: "", content: "", lineCount: 0, totalAmount: 0 };
  if (batch.file_type !== FILE_TYPES.BANK_UPLOAD) throw new Error(`Cannot write a payment file of type ${batch.file_type ?? "(none)"}.`);
  if (!batch.file_name) throw new Error(`Payment run ${batch.batch_no} has no file name - was a bank account chosen for it?`);

  requireLayout(layoutDef, batch);
  const content = renderFile(layoutDef.format, layoutDef.columns, inLines.map((i, k) => ({ values: valuesOf(i, batch, lines, k + 1, layoutDef), paymentDate: batch.batch_date })));
  return {
    ...base,
    fileName: batch.file_name,
    content,
    lineCount: inLines.length,
    totalAmount: Math.round(inLines.reduce((s, i) => s + Number(i.amount), 0) * 100) / 100,
  };
}

// ── statutory file (sql/73) ─────────────────────────────────────────────────
// Same 28-position bank upload layout as above, but the receiver is a statutory payee (Income Tax Dept, GST dept, PF ...) and the
// three payment-details positions say what is being paid: 15 the head ("TDS u/s 194C"), 16 the period ("Sep 2026"), 17 the payee's
// registration (TAN / GSTIN / return). Reference (14) is <KIND><batch no digits>-<line>, e.g. TDS2026000001-1. One file = one kind.

/** TDS2026000001-1 : kind + the run number without dashes + the line; at most REFERENCE_MAX characters. */
export function statutoryReference(batch, item) {
  const ref = `${alnum(batch.kind)}${alnum(String(batch.batch_no ?? "").replace(/^SB/i, ""))}-${item.line_no}`;
  return ref.slice(0, REFERENCE_MAX);
}

/**
 * @param batch  { batch_no, batch_date, kind, file_name, file_type } - the statutory run
 * @param items  statutory_batch_item rows in file order ({ line_no, amount, mode, payee_name, account_no, ifsc, bank_name, branch_name, reference_no, head_name, period_label })
 * @returns { fileName, mimeType, content, lineCount, totalAmount }
 */
export function buildStatutoryFile(batch, items, layoutDef) {
  if (batch.file_type !== FILE_TYPES.BANK_UPLOAD) throw new Error(`Cannot write a payment file of type ${batch.file_type ?? "(none)"}.`);
  if (!batch.file_name) throw new Error(`Statutory run ${batch.batch_no} has no file name - was a bank account chosen for it?`);
  const rows = [...items].sort((a, b) => a.line_no - b.line_no);
  // OLD built-in statutory layout (commented out - the Bank File Format master is used instead):
  // const content = rows.map((i) => {
  //   const f = new Array(POSITION_COUNT).fill("");
  //   f[0] = TRANSFER_TYPE[String(i.mode ?? "").toUpperCase()];
  //   if (!f[0]) throw new Error(`${i.head_name}: ${i.mode} is not a mode the bank file carries.`);
  //   f[2] = cell(i.account_no);
  //   f[3] = money(i.amount);
  //   f[4] = cell(i.payee_name).slice(0, NAME_MAX).trimEnd();
  //   f[13] = statutoryReference(batch, i);
  //   [f[14], f[15], f[16]] = [cut(i.head_name, DETAIL_MAX), cut(i.period_label, DETAIL_MAX), cut(i.reference_no, DETAIL_MAX)];
  //   f[22] = ddmmyyyy(batch.batch_date);
  //   f[24] = cell(i.ifsc).toUpperCase();
  //   f[25] = cell(i.bank_name);
  //   f[26] = cell(i.branch_name);
  //   return f.join(",");
  // }).join("\n");
  requireLayout(layoutDef, batch);
  const sender = layoutDef.sender ?? {};
  const lines = rows.map((i, k) => {
    if (!TRANSFER_TYPE[String(i.mode ?? "").toUpperCase()]) throw new Error(`${i.head_name}: ${i.mode} is not a mode the bank file carries.`);
    return {
      paymentDate: batch.batch_date,
      values: {
        TRANSFER_TYPE: TRANSFER_TYPE[String(i.mode).toUpperCase()], MODE: String(i.mode).toUpperCase(), ACCOUNT_NO: cell(i.account_no), AMOUNT: money(i.amount),
        BENEFICIARY_NAME: cell(i.payee_name), REFERENCE: statutoryReference(batch, i), PAYMENT_NO: cell(batch.batch_no), SUPPLIER_CODE: "",
        DETAIL_1: cut(i.head_name, DETAIL_MAX), DETAIL_2: cut(i.period_label, DETAIL_MAX), DETAIL_3: cut(i.reference_no, DETAIL_MAX),
        IFSC: cell(i.ifsc).toUpperCase(), BANK_NAME: cell(i.bank_name), BRANCH_NAME: cell(i.branch_name), SERIAL_NO: String(k + 1),
        SENDER_ACCOUNT_NO: cell(batch.sender_account_no), SENDER_NAME: cell(sender.ac_holder_name), SENDER_IFSC: cell(sender.ifsc).toUpperCase(),
        SENDER_BANK_NAME: cell(batch.sender_bank_name), SENDER_CLIENT_CODE: cell(batch.sender_client_code), SENDER_EMAIL: cell(batch.sender_alert_email),
      },
    };
  });
  return {
    fileName: batch.file_name, mimeType: "text/plain;charset=utf-8", content: renderFile(layoutDef.format, layoutDef.columns, lines), lineCount: rows.length,
    totalAmount: Math.round(rows.reduce((s, i) => s + Number(i.amount), 0) * 100) / 100,
  };
}

// ── verification sheet ──────────────────────────────────────────────────────
// The checker (internal auditor / payment inputter) approves the upload on the bank's screen, which shows the file's lines and its
// total. This sheet is what they compare it with: one row per payment x invoice - what the invoice is, what was paid before, what is
// paid now, TDS, what is left - and, on the first row of each payment, what the bank is told to send. Only the lines that are in the
// file are listed, so the count and the total match the bank screen.

const csv = (v) => {
  const s = String(v ?? "");
  return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};
const num = (n) => (n === null || n === undefined || n === "" ? "" : money(n));
const KIND_LABEL = { FULL: "Full payment", PART: "Part payment", FINAL: "Last part" };
const HEADER = [
  "File line", "Payment no", "Supplier", "Account (last 4)", "IFSC", "Supplier invoice no", "Our invoice no", "Invoice date", "Invoice amount",
  "Payable on invoice", "Paid earlier", "Paid in this payment", "TDS", "Still to pay on invoice", "Full / part", "Part no", "GST waiting for GSTR-2B",
  "Advance adjusted", "Debit (-) / credit (+) notes", "Sent to bank (this payment)",
];

/** @returns { fileName, mimeType, content, lineCount, totalAmount } - CSV, one row per payment x invoice, then a total row. */
export function buildVerificationSheet(batch, items, lines = []) {
  const inLines = items.filter(inFile);
  const stamp = isoDate(batch.batch_date);
  const rows = [
    ["Payment run", batch.batch_no], ["Bank file", batch.file_name || ""], ["Run date", stamp],
    ["Transfers in the file", inLines.length], ["Total sent to bank", num(inLines.reduce((s, i) => s + Number(i.amount), 0))], [],
    HEADER,
  ];
  let fileLine = 0;
  for (const item of inLines) {
    fileLine += 1;
    const mine = linesOf(item, lines);
    const common = [fileLine, item.payment_no, item.vendor_name, item.account_no ? String(item.account_no).slice(-4) : "", cell(item.ifsc).toUpperCase()];
    const deductions = [num(item.advance_amount), item.note_amount == null ? "" : num(-Number(item.note_amount))];
    if (mine.length === 0) {   // a run from before sql/70: only what the item itself kept
      rows.push([...common, item.supplier_invoice_nos ?? "", item.invoice_nos ?? "", "", "", "", "", "", num(item.tds_amount), "", "", "", "", ...deductions, num(item.amount)]);
      continue;
    }
    mine.forEach((l, k) => {
      rows.push([
        ...common, l.supplier_invoice_no ?? "", l.invoice_no ?? "", isoDate(l.invoice_date), num(l.invoice_amount), num(l.payable_total), num(l.paid_before),
        num(l.this_gross), num(l.tds_amount), num(l.balance_after), KIND_LABEL[l.kind] ?? l.kind, l.part_no, l.awaiting_2b ? num(l.balance_after) : "",
        ...(k === 0 ? [...deductions, num(item.amount)] : ["", "", ""]),
      ]);
    });
  }
  rows.push([]);
  const shown = inLines.flatMap((i) => linesOf(i, lines));
  const sum = (arr, pick) => arr.reduce((s, x) => s + Number(pick(x) || 0), 0);
  rows.push(["TOTAL", "", "", "", "", "", "", "", "", "", "", shown.length ? num(sum(shown, (l) => l.this_gross)) : "",
    num(sum(inLines, (i) => i.tds_amount)), "", "", "", "", num(sum(inLines, (i) => i.advance_amount)), num(-sum(inLines, (i) => i.note_amount)), num(sum(inLines, (i) => i.amount))]);
  const stem = (batch.file_name || batch.batch_no || "payment-run").replace(/\.[^.]*$/, "");
  return {
    fileName: `${stem}_verification.csv`, mimeType: "text/csv;charset=utf-8",
    content: rows.map((r) => r.map(csv).join(",")).join("\r\n"),
    lineCount: inLines.length, totalAmount: Math.round(inLines.reduce((s, i) => s + Number(i.amount), 0) * 100) / 100,
  };
}
