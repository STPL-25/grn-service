// paymentFile.js - the bank payment file of a Payment Run (sql/68, sql/70): the file the company uploads to its bank to pay suppliers by NEFT / RTGS.
//
// File type BANK_UPLOAD - the layout the bank takes: one line per transfer, 28 positions separated by commas, no header, no quotes, LF
// between lines (none after the last). Positions that are not used stay empty:
//
//    1  transfer type   N = NEFT, R = RTGS (from the payment's mode)
//    3  receiver's account number         }
//    4  amount (2 decimals) = what the bank sends, i.e. after TDS / advance / notes }  receiver: the supplier KYC, copied onto the run's lines when the run was made
//    5  receiver's name (first 20 letters)}
//   14  reference  <supplier id>-<payment no without - or spaces>, at most 20 characters
//   15  payment details 1: the supplier's invoice number(s)                              }  free-text "payment details" the bank keeps with the
//   16  payment details 2: FULL, or PART / FINAL with this payment's share of the invoice }  transfer and shows to the checker (auditor / payment
//   17  payment details 3: what was taken off - TDS, advance, debit / credit note        }  inputter) on its own screen, at most 30 characters each
//   23  payment date dd/mm/yyyy (the run's payment date)
//   25  receiver's IFSC  26  receiver's bank  27  receiver's branch      (supplier KYC)
//
// Position 28 (the receiver's e-mail in the bank layout) is left empty: the sender's alert e-mail used to go there and does not any more.
// The checker approves the file in the BANK's application, not here, so positions 15-17 carry what they need to tell one transfer from
// the next and to see that a part payment is a part payment. buildVerificationSheet() gives the same facts as a sheet to check against.
//
// The file NAME (<prefix>_<client code>_<client code><DDMM>.<seq>) is made by sp_nt_CreatePaymentBatch under the run's lock and
// arrives here as batch.file_name.
//
// Only real bank transfers go in: channel BANK with a mode that has a transfer type (NEFT / RTGS). Cheque / cash / DD (MANUAL),
// suppliers paid on their portal (PORTAL), payments the advances and notes settle entirely (ADJUSTMENT) and other bank modes
// such as UPI stay out - the bank would reject them in an upload - and are returned in `skipped` so the screen can list them.
//
// A value that holds a comma or a line break would shift every position after it, so those are turned into spaces.

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

/** The 28 positions of one transfer. */
function lineOf(item, batch, lines) {
  const mine = linesOf(item, lines);
  const f = new Array(POSITION_COUNT).fill("");
  f[0] = TRANSFER_TYPE[String(item.mode ?? "").toUpperCase()];
  f[2] = cell(item.account_no);
  f[3] = money(item.amount);
  f[4] = cell(item.beneficiary_name || item.vendor_name).slice(0, NAME_MAX).trimEnd();
  f[13] = referenceOf(item);
  [f[14], f[15], f[16]] = [invoiceText(item, mine), kindText(mine), deductionText(item)];
  f[22] = ddmmyyyy(batch.batch_date);
  f[24] = cell(item.ifsc).toUpperCase();
  f[25] = cell(item.bank_name);
  f[26] = cell(item.branch_name);
  return f.join(",");
}

const inFile = (i) => i.channel === "BANK" && Object.hasOwn(TRANSFER_TYPE, String(i.mode ?? "").toUpperCase());

/**
 * @param batch  { batch_no, batch_date, file_name, file_type } - the run
 * @param items  payment_batch_item rows in file order ({ channel, payment_no, vendor_sno, mode, amount, beneficiary_name, account_no, ifsc, bank_name, branch_name, tds_amount, advance_amount, note_amount, ... })
 * @param lines  payment_batch_item_invoice rows of the run (what each payment paid on each invoice); optional - runs before sql/70 have none
 * @returns { fileName, mimeType, content, lineCount, totalAmount, skipped: [{ payment_no, vendor_name, amount, channel, reason }] }
 *          A run with nothing to upload (no bank line, so no sender and no file type) gives an empty file: fileName '', lineCount 0.
 */
export function buildPaymentFile(batch, items, lines = []) {
  const inLines = items.filter(inFile);
  const skipped = items.filter((i) => !inFile(i)).map((i) => ({
    payment_no: i.payment_no, vendor_name: i.vendor_name, amount: Number(i.amount), channel: i.channel,
    reason: i.channel === "BANK" ? `${i.mode} is not paid through the bank file - pay it another way` : (SKIP_REASON[i.channel] ?? "Not a bank transfer"),
  }));
  const base = { mimeType: "text/plain;charset=utf-8", skipped };

  if (inLines.length === 0) return { ...base, fileName: "", content: "", lineCount: 0, totalAmount: 0 };
  if (batch.file_type !== FILE_TYPES.BANK_UPLOAD) throw new Error(`Cannot write a payment file of type ${batch.file_type ?? "(none)"}.`);
  if (!batch.file_name) throw new Error(`Payment run ${batch.batch_no} has no file name - was a bank account chosen for it?`);

  return {
    ...base,
    fileName: batch.file_name,
    content: inLines.map((i) => lineOf(i, batch, lines)).join("\n"),
    lineCount: inLines.length,
    totalAmount: Math.round(inLines.reduce((s, i) => s + Number(i.amount), 0) * 100) / 100,
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
