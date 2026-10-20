import ExcelJS from "exceljs";

// Reads the GSTR-2B Excel downloaded from the GST portal.
//   B2B       -> invoices      (doc_type 'INV')
//   B2B-CDNR  -> credit/debit notes (doc_type 'CDN')
// The portal puts a few title rows and a two-line header above the data, so the header row is
// found by looking for its column captions instead of assuming a position.

const cellText = (c) => {
  const v = c?.value;
  if (v == null) return "";
  if (typeof v === "object") {
    if (v.richText) return v.richText.map((t) => t.text).join("");
    if (v.result != null) return String(v.result);
    if (v.text != null) return String(v.text);
    if (v instanceof Date) return v.toISOString();
  }
  return String(v);
};

const num = (v) => {
  if (v == null || v === "") return 0;
  if (typeof v === "number") return v;
  if (typeof v === "object" && v.result != null) return num(v.result);
  const n = Number(String(v).replace(/[₹,\s]/g, ""));
  return Number.isFinite(n) ? n : 0;
};

// Excel date cell, or text like 21-09-2026 / 21/09/2026 / 2026-09-21 / 21-Sep-2026 -> 'YYYY-MM-DD'
const isoDate = (v) => {
  if (v == null || v === "") return null;
  const pad = (n) => String(n).padStart(2, "0");
  if (v instanceof Date) return `${v.getUTCFullYear()}-${pad(v.getUTCMonth() + 1)}-${pad(v.getUTCDate())}`;
  const s = String(v).trim();
  let m = s.match(/^(\d{4})-(\d{1,2})-(\d{1,2})/);
  if (m) return `${m[1]}-${pad(m[2])}-${pad(m[3])}`;
  m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})/);
  if (m) return `${m[3]}-${pad(m[2])}-${pad(m[1])}`;
  m = s.match(/^(\d{1,2})[-/ ]([A-Za-z]{3})[a-z]*[-/ ](\d{4})/);
  if (m) {
    const mon = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].indexOf(m[2].toLowerCase());
    if (mon >= 0) return `${m[3]}-${pad(mon + 1)}-${pad(m[1])}`;
  }
  return null;
};

// caption regex -> field, per sheet kind. First match wins, so order matters.
const COLUMNS = {
  INV: [
    ["supplier_gstin", /gstin of supplier|supplier gstin/i],
    ["trade_name", /trade\/?legal name|trade name|legal name/i],
    ["invoice_no", /^invoice (number|no)/i],
    ["invoice_date", /^invoice date/i],
    ["invoice_value", /^invoice value/i],
    ["place_of_supply", /place of supply/i],
    ["reverse_charge", /reverse charge/i],
    ["taxable_value", /^taxable value/i],
    ["igst", /integrated tax/i],
    ["cgst", /central tax/i],
    ["sgst", /state\/?ut tax|state tax/i],
    ["cess", /^cess/i],
    ["filing_period", /gstr-?1.*period|return period/i],
    ["itc_available", /itc availab/i],
    ["itc_reason", /^reason/i],
    ["irn", /^irn$/i],
  ],
  CDN: [
    ["supplier_gstin", /gstin of supplier|supplier gstin/i],
    ["trade_name", /trade\/?legal name|trade name|legal name/i],
    ["invoice_no", /^note (number|no)/i],
    ["note_type", /^note type/i],
    ["invoice_date", /^note date/i],
    ["invoice_value", /^note value/i],
    ["place_of_supply", /place of supply/i],
    ["reverse_charge", /reverse charge/i],
    ["taxable_value", /^taxable value/i],
    ["igst", /integrated tax/i],
    ["cgst", /central tax/i],
    ["sgst", /state\/?ut tax|state tax/i],
    ["cess", /^cess/i],
    ["filing_period", /gstr-?1.*period|return period/i],
    ["itc_available", /itc availab/i],
    ["itc_reason", /^reason/i],
    ["irn", /^irn$/i],
  ],
};

function readSheet(ws, kind) {
  const anchor = kind === "INV" ? /^invoice (number|no)/i : /^note (number|no)/i;
  let headerRow = null;
  ws.eachRow({ includeEmpty: false }, (row, rowNumber) => {
    if (headerRow || rowNumber > 25) return;
    let hit = false;
    row.eachCell((c) => { if (anchor.test(cellText(c).trim())) hit = true; });
    if (hit) headerRow = rowNumber;
  });
  if (!headerRow) return [];

  // The portal header is two lines: group captions above (GSTIN, name, taxable value, ITC...) and the detail
  // captions below (invoice number, tax heads...). Match a column on the lower caption first, then the upper one.
  const colMap = {};
  const lower = ws.getRow(headerRow);
  const upper = headerRow > 1 ? ws.getRow(headerRow - 1) : null;
  const width = Math.max(lower.cellCount, upper ? upper.cellCount : 0);
  for (let colNumber = 1; colNumber <= width; colNumber++) {
    const captions = [cellText(lower.getCell(colNumber)), upper ? cellText(upper.getCell(colNumber)) : ""]
      .map((t) => t.replace(/\s+/g, " ").trim()).filter(Boolean);
    outer: for (const t of captions) {
      for (const [field, re] of COLUMNS[kind]) {
        if (colMap[field] == null && re.test(t)) { colMap[field] = colNumber; break outer; }
      }
    }
  }
  if (!colMap.supplier_gstin || !colMap.invoice_no) {
    throw new Error(`Sheet "${ws.name}": could not find the supplier GSTIN / ${kind === "INV" ? "invoice" : "note"} number columns.`);
  }

  const txt = (row, f) => (colMap[f] ? cellText(row.getCell(colMap[f])).trim() : "");
  const get = (row, f) => (colMap[f] ? row.getCell(colMap[f]).value : null);
  const rows = [];
  ws.eachRow({ includeEmpty: false }, (row, rowNumber) => {
    if (rowNumber <= headerRow) return;
    const gstin = txt(row, "supplier_gstin").toUpperCase();
    const no = txt(row, "invoice_no");
    if (!gstin || !no || gstin.length < 15) return;          // blank / total / footnote rows
    rows.push({
      doc_type: kind,
      supplier_gstin: gstin,
      trade_name: txt(row, "trade_name") || null,
      invoice_no: no,
      invoice_date: isoDate(get(row, "invoice_date")),
      invoice_value: num(get(row, "invoice_value")),
      taxable_value: num(get(row, "taxable_value")),
      igst: num(get(row, "igst")),
      cgst: num(get(row, "cgst")),
      sgst: num(get(row, "sgst")),
      cess: num(get(row, "cess")),
      place_of_supply: txt(row, "place_of_supply") || null,
      reverse_charge: txt(row, "reverse_charge") || null,
      itc_available: txt(row, "itc_available") || null,
      itc_reason: txt(row, "itc_reason") || null,
      filing_period: txt(row, "filing_period") || null,
      irn: txt(row, "irn") || null,
    });
  });
  return rows;
}

/** @param {Buffer} buffer an .xlsx file. Returns { rows, sheets } (rows ready for sp_nt_Gstr2bImport). */
export async function parseGstr2bWorkbook(buffer) {
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(buffer);

  const rows = [];
  const sheets = [];
  for (const ws of wb.worksheets) {
    const name = ws.name.trim();
    let kind = null;
    if (/^b2b-?cdnr?a?$/i.test(name.replace(/\s/g, "")) && !/cdnra/i.test(name)) kind = "CDN";
    else if (/^b2b$/i.test(name)) kind = "INV";
    if (!kind) continue;
    const found = readSheet(ws, kind);
    sheets.push({ sheet: name, kind, rows: found.length });
    rows.push(...found);
  }
  if (sheets.length === 0) throw new Error('No "B2B" sheet found - upload the GSTR-2B Excel file downloaded from the GST portal.');
  return { rows, sheets };
}
