// paymentFile.js - the bank payment file of a Payment Run (sql/68): the file the company uploads to its bank to pay suppliers by NEFT / RTGS.
//
// File type BANK_UPLOAD - the layout the bank takes: one line per transfer, 28 positions separated by commas, no header, no quotes, LF
// between lines (none after the last). Positions that are not used stay empty:
//
//    1  transfer type   N = NEFT, R = RTGS (from the payment's mode)
//    3  receiver's account number         }
//    4  amount (2 decimals)               }  receiver: the supplier KYC, copied onto the run's lines when the run was made
//    5  receiver's name (first 20 letters)}
//   14  reference  <supplier id>-<payment no without - or spaces>, at most 20 characters
//   23  payment date dd/mm/yyyy (the run's payment date)
//   25  receiver's IFSC  26  receiver's bank  27  receiver's branch      (supplier KYC)
//   28  e-mail - the sender's alert e-mail from the Payment Bank master
//
// The file NAME (<prefix>_<client code>_<client code><DDMM>.<seq>) is made by sp_nt_CreatePaymentBatch under the run's lock and
// arrives here as batch.file_name; the sender's alert e-mail as batch.sender_alert_email.
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

const cell = (v) => String(v ?? "").replace(/[\r\n\t,]+/g, " ").replace(/ {2,}/g, " ").trim();
const alnum = (v) => String(v ?? "").replace(/[^A-Za-z0-9]/g, "");

/** <supplier id>-<payment no>, cut to REFERENCE_MAX from the supplier side so the payment number always stays whole. */
export function referenceOf(item) {
  const pay = alnum(item.payment_no);
  const who = alnum(item.vendor_sno);
  if (!who) return pay.slice(0, REFERENCE_MAX);
  const room = REFERENCE_MAX - 1 - pay.length;
  return room > 0 ? `${who.slice(0, room)}-${pay}` : pay.slice(0, REFERENCE_MAX);
}

const SKIP_REASON = {
  MANUAL: "Cheque / cash / DD - not a bank transfer",
  PORTAL: "Supplier is paid on their portal",
  ADJUSTMENT: "Nothing to pay out - advances / notes settle it",
};

/** The 28 positions of one transfer. */
function lineOf(item, batch) {
  const f = new Array(POSITION_COUNT).fill("");
  f[0] = TRANSFER_TYPE[String(item.mode ?? "").toUpperCase()];
  f[2] = cell(item.account_no);
  f[3] = money(item.amount);
  f[4] = cell(item.beneficiary_name || item.vendor_name).slice(0, NAME_MAX).trimEnd();
  f[13] = referenceOf(item);
  f[22] = ddmmyyyy(batch.batch_date);
  f[24] = cell(item.ifsc).toUpperCase();
  f[25] = cell(item.bank_name);
  f[26] = cell(item.branch_name);
  f[27] = cell(batch.sender_alert_email);
  return f.join(",");
}

/**
 * @param batch  { batch_no, batch_date, file_name, file_type, sender_alert_email } - the run
 * @param items  payment_batch_item rows in file order ({ channel, payment_no, vendor_sno, mode, amount, beneficiary_name, account_no, ifsc, bank_name, branch_name, ... })
 * @returns { fileName, mimeType, content, lineCount, totalAmount, skipped: [{ payment_no, vendor_name, amount, channel, reason }] }
 *          A run with nothing to upload (no bank line, so no sender and no file type) gives an empty file: fileName '', lineCount 0.
 */
export function buildPaymentFile(batch, items) {
  const inFile = (i) => i.channel === "BANK" && Object.hasOwn(TRANSFER_TYPE, String(i.mode ?? "").toUpperCase());
  const lines = items.filter(inFile);
  const skipped = items.filter((i) => !inFile(i)).map((i) => ({
    payment_no: i.payment_no, vendor_name: i.vendor_name, amount: Number(i.amount), channel: i.channel,
    reason: i.channel === "BANK" ? `${i.mode} is not paid through the bank file - pay it another way` : (SKIP_REASON[i.channel] ?? "Not a bank transfer"),
  }));
  const base = { mimeType: "text/plain;charset=utf-8", skipped };

  if (lines.length === 0) return { ...base, fileName: "", content: "", lineCount: 0, totalAmount: 0 };
  if (batch.file_type !== FILE_TYPES.BANK_UPLOAD) throw new Error(`Cannot write a payment file of type ${batch.file_type ?? "(none)"}.`);
  if (!batch.file_name) throw new Error(`Payment run ${batch.batch_no} has no file name - was a bank account chosen for it?`);

  return {
    ...base,
    fileName: batch.file_name,
    content: lines.map((i) => lineOf(i, batch)).join("\n"),
    lineCount: lines.length,
    totalAmount: Math.round(lines.reduce((s, i) => s + Number(i.amount), 0) * 100) / 100,
  };
}
