// reverseFile.js - reads the bank's reverse file (its answer to a payment run's upload file, sql/83) and matches each of its lines
// to a transfer of the run.
//
// The bank's exact layout is not known yet, so the file is read by its HEADER line, not by column positions: each field is found
// under any of the names banks commonly use (HEADERS below). Comma, pipe, tab or semicolon separated; quoted values allowed.
// The only columns it must have are the reference and the status; amount, account, UTR, dates and reason are read when present.
//
// A line is matched on the reference the upload file carried in its reference column (paymentFile.js referenceOf:
// <supplier id>-<payment no>). It is then checked against what the run sent - the file name (when the reverse file names one),
// the amount, the beneficiary account - and anything that does not agree is shown as a problem and NOT applied.
//
// What each matched line will do is worked out here for the preview (actionOf); sp_nt_ApplyPaymentReverseFile decides it again
// inside its transaction.

import { referenceOf, TRANSFER_TYPE } from "./paymentFile.js";

export const BANK_STATUSES = ["PAID", "PENDING", "REJECTED", "RETURNED"];

const norm = (s) => String(s ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

/** Field -> header names it may come under (compared after norm(): lower case, punctuation as spaces). */
export const HEADERS = {
  FILE_NAME: ["file name", "filename", "input file name", "upload file name", "file"],
  LINE_NO: ["line no", "line", "line number", "serial no", "sr no", "s no", "sl no", "record no"],
  REFERENCE: ["customer reference no", "customer reference number", "customer reference", "customer ref no", "customer ref", "cust ref no",
    "client reference", "reference no", "reference number", "reference", "ref no", "payment reference", "instruction reference number"],
  AMOUNT: ["amount", "instrument amount", "txn amount", "transaction amount", "payment amount", "amount inr"],
  ACCOUNT_NO: ["beneficiary account no", "beneficiary account number", "bene account no", "bene account number", "beneficiary a c no",
    "account no", "account number", "credit account no", "credit account number"],
  STATUS: ["status", "transaction status", "txn status", "payment status", "record status"],
  UTR: ["utr no", "utr", "utr number", "utr rrn", "bank utr", "utr ref no"],
  BANK_REF: ["bank reference no", "bank reference number", "bank reference", "bank ref no", "bank ref", "transaction reference no", "txn ref no"],
  DEBIT_DATE: ["debit date", "value date", "transaction date", "txn date", "payment date processed"],
  CREDIT_AT: ["credit return date time", "credit date time", "credit datetime", "credit date", "return date time", "return date", "processed at", "processed date time"],
  REASON_CODE: ["reason code", "reject code", "rejection code", "return code", "error code", "status code"],
  REASON: ["reason", "reject reason", "rejection reason", "return reason", "failure reason", "remarks", "error description", "status description"],
};
const ALIAS = new Map(Object.entries(HEADERS).flatMap(([field, names]) => names.map((n) => [norm(n), field])));

/** The bank's status word -> ours. Unknown words are a problem on that line. */
const STATUS_WORDS = {
  PAID: ["paid", "success", "successful", "succeeded", "executed", "e", "s", "processed", "credited", "completed", "settled", "done"],
  PENDING: ["pending", "p", "in process", "inprocess", "processing", "in progress", "awaited", "awaiting", "sent", "queued", "on hold", "hold"],
  REJECTED: ["rejected", "reject", "r", "failed", "failure", "fail", "f", "error", "declined", "cancelled", "canceled"],
  RETURNED: ["returned", "return", "ret", "rt", "reversed", "reversal", "bounced", "refunded"],
};
const STATUS_OF = new Map(Object.entries(STATUS_WORDS).flatMap(([st, words]) => words.map((w) => [norm(w), st])));
export const statusOf = (raw) => STATUS_OF.get(norm(raw)) ?? null;

const SEPARATORS = [",", "|", "\t", ";"];

/** One line into fields: the separator splits outside double quotes; "" inside quotes is a quote. */
function splitLine(line, sep) {
  const out = [];
  let cur = "";
  let quoted = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; } else if (ch === '"') quoted = false; else cur += ch;
    } else if (ch === '"' && cur.trim() === "") { cur = ""; quoted = true; } else if (ch === sep) { out.push(cur.trim()); cur = ""; } else cur += ch;
  }
  out.push(cur.trim());
  return out;
}

const pad2 = (n) => String(n).padStart(2, "0");
const MONTHS = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };
const validDay = (y, m, d) => {
  const t = new Date(Date.UTC(y, m - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === m - 1 && t.getUTCDate() === d;
};

/**
 * A bank date (and time) -> { date: 'yyyy-mm-dd', at: 'yyyy-mm-dd hh:mm:ss' } or null.
 * DD/MM/YYYY, DD-MM-YYYY, DD.MM.YYYY, YYYY-MM-DD, DD-MMM-YYYY, DDMMYYYY, YYYYMMDD; then an optional time hh:mm[:ss] [AM|PM].
 * Indian banks write the day first, so 03/11/2026 is 3 November.
 */
const TIME = "(?:[T\\s,]+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?(?:\\.\\d+)?\\s*([AaPp][Mm])?)?";
const SPLIT_DATE = new RegExp(`^(\\d{1,4})[/.\\-\\s]([A-Za-z]{3}|\\d{1,2})[/.\\-\\s](\\d{2,4})${TIME}$`);
const COMPACT_DATE = new RegExp(`^(\\d{8})${TIME}$`);

export function parseBankDate(raw) {
  const s = String(raw ?? "").trim();
  if (!s) return null;
  let y; let mo; let d; let t;
  const split = s.match(SPLIT_DATE);
  const compact = split ? null : s.match(COMPACT_DATE);
  if (split) {
    const [, a, b, c] = split;
    mo = /^[A-Za-z]{3}$/.test(b) ? MONTHS[b.toLowerCase()] : Number(b);
    if (a.length === 4) { y = Number(a); d = Number(c); } else { d = Number(a); y = Number(c.length === 2 ? `20${c}` : c); }
    t = split.slice(4);
  } else if (compact) {
    // DDMMYYYY unless it only reads as YYYYMMDD
    const n = compact[1];
    const dm = [Number(n.slice(0, 2)), Number(n.slice(2, 4)), Number(n.slice(4))];
    const ym = [Number(n.slice(6)), Number(n.slice(4, 6)), Number(n.slice(0, 4))];
    [d, mo, y] = validDay(dm[2], dm[1], dm[0]) ? dm : ym;
    t = compact.slice(2);
  } else return null;
  if (!mo || !validDay(y, mo, d)) return null;
  const date = `${y}-${pad2(mo)}-${pad2(d)}`;
  if (t[0] == null) return { date, at: null };
  let h = Number(t[0]);
  const ap = t[3]?.toUpperCase();
  if (ap === "PM" && h < 12) h += 12;
  if (ap === "AM" && h === 12) h = 0;
  const mi = Number(t[1]); const se = Number(t[2] ?? 0);
  if (h > 23 || mi > 59 || se > 59) return { date, at: null };
  return { date, at: `${date} ${pad2(h)}:${pad2(mi)}:${pad2(se)}` };
}

/** "₹ 1,23,456.70" / "Rs.500" / "500.00 CR" -> number, or null. */
export function parseAmount(raw) {
  const s = String(raw ?? "").replace(/₹|rs\.?|inr|cr|dr/gi, "").replace(/[,\s]/g, "");
  if (!/^-?\d+(\.\d+)?$/.test(s)) return null;
  return Math.round(Number(s) * 100) / 100;
}

const refKey = (v) => String(v ?? "").toUpperCase().replace(/[^A-Z0-9-]/g, "");
/** Account numbers compared on their digits without leading zeros (the KYC keeps them as a number - leading zeros are already gone). */
const accountKey = (v) => String(v ?? "").replace(/\D/g, "").replace(/^0+/, "");

/**
 * The reverse file -> { rows: [{ row_no, raw: {field: text}, ... }], fields: [found fields], separator }.
 * Throws an Error with a user-facing message when the file cannot be read at all.
 */
export function parseReverseFile(content) {
  const text = String(content ?? "").replace(/^﻿/, "");
  const lines = text.split(/\r\n|\n|\r/);
  const first = lines.findIndex((l) => l.trim() !== "");
  if (first < 0) throw new Error("The reverse file is empty.");
  const headerLine = lines[first];
  const sep = SEPARATORS.map((s) => [s, splitLine(headerLine, s).length]).sort((a, b) => b[1] - a[1])[0][0];
  const header = splitLine(headerLine, sep);
  const fieldAt = header.map((h) => ALIAS.get(norm(h)) ?? null);
  const seen = new Set();
  fieldAt.forEach((f, i) => { if (f && seen.has(f)) fieldAt[i] = null; else if (f) seen.add(f); });   // first column of a name wins
  if (!seen.has("REFERENCE") || !seen.has("STATUS")) {
    throw new Error("The reverse file needs a header line with at least a reference column (e.g. \"Customer Reference No\") and a \"Status\" column.");
  }
  const rows = [];
  for (let i = first + 1; i < lines.length; i++) {
    if (lines[i].trim() === "") continue;
    const cells = splitLine(lines[i], sep);
    const raw = {};
    fieldAt.forEach((f, k) => { if (f) raw[f] = cells[k] ?? ""; });
    if (Object.values(raw).every((v) => String(v).trim() === "")) continue;
    rows.push({ row_no: i + 1, raw });
  }
  if (rows.length === 0) throw new Error("The reverse file has a header but no lines.");
  return { rows, fields: [...seen], separator: sep };
}

/** The transfers of a run that went in its bank file (paymentFile.js puts exactly these in). */
export const fileItemsOf = (items) => (items ?? []).filter((i) => i.channel === "BANK" && Object.hasOwn(TRANSFER_TYPE, String(i.mode ?? "").toUpperCase()));

/**
 * What applying a line will do, given what the run line is now (mirrors sp_nt_ApplyPaymentReverseFile).
 * @returns { action, text }  action: MARK_PAID | UPDATE_UTR | MARK_PENDING | RETURN_TO_RUN | NO_CHANGE | IGNORED
 */
export function actionOf(status, item, utr) {
  const cur = item.bank_status ?? null;
  if (status === "PAID") {
    if (cur === null || cur === "PENDING") return { action: "MARK_PAID", text: "Mark paid and save the UTR" };
    if (cur === "PAID") return utr && utr !== (item.utr_no ?? "") ? { action: "UPDATE_UTR", text: `Already paid - UTR changes to ${utr}` } : { action: "NO_CHANGE", text: "Already marked paid" };
    return { action: "IGNORED", text: `The bank already ${cur.toLowerCase()} it - this older answer is not used` };
  }
  if (status === "PENDING") {
    if (cur === null) return { action: "MARK_PENDING", text: "Mark pending at the bank" };
    if (cur === "PENDING") return { action: "NO_CHANGE", text: "Still pending" };
    return { action: "IGNORED", text: `The bank already answered ${cur} - this older answer is not used` };
  }
  if (cur === "REJECTED" || cur === "RETURNED") return { action: "NO_CHANGE", text: "Already back in Payment Run" };
  if (item.payment_status && (item.payment_status !== "Processed" || item.paid_again_batch_no)) {
    return { action: "IGNORED", text: `The payment is no longer paid in this run (now ${item.payment_status})` };
  }
  return { action: "RETURN_TO_RUN", text: `Not paid - reverse its journal and send it back to Payment Run${cur === "PAID" ? " (it was marked paid before)" : ""}` };
}

const clip = (v, n) => (String(v ?? "").trim().slice(0, n) || null);

/**
 * Match a parsed reverse file to a run.
 * @param batch  { batch_no, file_name }
 * @param items  the run's lines (sp_nt_GetPaymentBatches recordset 2: batch_item_sno, payment_no, vendor_sno, amount, account_no, mode,
 *               channel, bank_status, utr_no, payment_status, paid_again_batch_no ...)
 * @returns {
 *   lines:   one per row of the file: { row_no, reference, status, utr_no, bank_ref_no, debit_date, credit_at, reason_code, reason,
 *            amount, batch_item_sno?, payment_no?, vendor_name?, line_no?, run_amount?, current_status?, action?, action_text?, problem? }
 *   apply:   the lines without a problem, as sp_nt_ApplyPaymentReverseFile takes them
 *   missing: transfers of the run the file says nothing about
 *   summary: { lines, matched, problems, paid, pending, failed, no_change }
 * }
 */
export function matchReverseFile(batch, items, parsed) {
  const fileItems = fileItemsOf(items);
  const byRef = new Map(fileItems.map((i) => [refKey(referenceOf(i)), i]));
  const used = new Set();
  const runFile = String(batch?.file_name ?? "").trim().toLowerCase();
  const lines = parsed.rows.map(({ row_no, raw }) => {
    const reference = clip(raw.REFERENCE, 60) ?? "";
    const statusRaw = String(raw.STATUS ?? "").trim();
    const status = statusOf(statusRaw);
    const debit = parseBankDate(raw.DEBIT_DATE);
    const credit = parseBankDate(raw.CREDIT_AT);
    const line = {
      row_no, reference, status, status_text: statusRaw,
      utr_no: clip(raw.UTR, 40), bank_ref_no: clip(raw.BANK_REF, 40),
      debit_date: debit?.date ?? null, credit_at: credit?.at ?? (credit?.date ? `${credit.date} 00:00:00` : null),
      reason_code: clip(raw.REASON_CODE, 20), reason: clip(raw.REASON, 300),
      amount: raw.AMOUNT === undefined ? null : parseAmount(raw.AMOUNT),
    };
    const fileName = String(raw.FILE_NAME ?? "").trim();
    const item = byRef.get(refKey(reference));
    const problem = (text) => ({ ...line, ...(item ? { batch_item_sno: item.batch_item_sno, payment_no: item.payment_no, vendor_name: item.vendor_name, line_no: item.line_no, run_amount: Number(item.amount) } : {}), problem: text });

    if (fileName && runFile && fileName.toLowerCase() !== runFile) return problem(`Belongs to another upload file (${fileName}), not ${batch.file_name}`);
    if (!reference) return problem("No reference on this line");
    if (!item) return problem(`No transfer of ${batch?.batch_no ?? "this run"} has the reference ${reference}`);
    if (used.has(item.batch_item_sno)) return problem(`${reference} is in the file more than once - only its first line is used`);
    used.add(item.batch_item_sno);
    if (!status) return problem(`Status "${statusRaw || "(empty)"}" is not one this screen knows (paid / pending / rejected / returned)`);
    if (raw.AMOUNT !== undefined && (line.amount === null || Math.abs(line.amount - Number(item.amount)) > 0.004)) {
      return problem(`Amount ${raw.AMOUNT || "(empty)"} is not what the run sent (${Number(item.amount).toFixed(2)})`);
    }
    if (raw.ACCOUNT_NO !== undefined && String(raw.ACCOUNT_NO).trim() && accountKey(raw.ACCOUNT_NO) !== accountKey(item.account_no)) {
      return problem(`Account ${raw.ACCOUNT_NO} is not the account the run paid (••••${String(item.account_no ?? "").slice(-4)})`);
    }
    if (status === "PAID" && !line.utr_no && !line.bank_ref_no) return problem("Paid, but the line has no UTR or bank reference");
    const { action, text } = actionOf(status, item, line.utr_no);
    return {
      ...line, batch_item_sno: item.batch_item_sno, payment_no: item.payment_no, vendor_name: item.vendor_name, line_no: item.line_no,
      run_amount: Number(item.amount), current_status: item.bank_status ?? null, action, action_text: text, problem: null,
    };
  });

  const ok = lines.filter((l) => !l.problem);
  const apply = ok.map((l) => ({
    batch_item_sno: l.batch_item_sno, line_no: l.line_no, status: l.status, amount: l.run_amount, utr_no: l.utr_no, bank_ref_no: l.bank_ref_no,
    debit_date: l.debit_date, credit_at: l.credit_at, reason_code: l.reason_code, reason: l.reason,
  }));
  const missing = fileItems.filter((i) => !used.has(i.batch_item_sno)).map((i) => ({
    batch_item_sno: i.batch_item_sno, payment_no: i.payment_no, vendor_name: i.vendor_name, line_no: i.line_no, amount: Number(i.amount),
    reference: referenceOf(i), current_status: i.bank_status ?? null,
  }));
  const count = (a) => ok.filter((l) => l.action === a).length;
  return {
    lines, apply, missing,
    summary: {
      lines: lines.length, matched: ok.length, problems: lines.length - ok.length,
      paid: count("MARK_PAID") + count("UPDATE_UTR"), pending: count("MARK_PENDING"), failed: count("RETURN_TO_RUN"),
      no_change: count("NO_CHANGE") + count("IGNORED"),
    },
  };
}
