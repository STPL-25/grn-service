// bankFileFormat.js - writes the bank payment file from a layout kept in the Bank File Format masters (backend-stpl sql/149), so each
// bank's file is whatever its master says and nothing about one bank's layout lives in code.
//
//   format   { format_name, delimiter: COMMA|PIPE|TAB|SEMICOLON|NONE, has_header: Y|N, line_ending: LF|CRLF, quote_text: Y|N }
//   columns  [{ position, header_text, source_field, fixed_value, max_len, pad_side: L|R, pad_char, date_format }]
//
// Each column says where its value comes from (SOURCE_FIELDS), how long it may be (max_len, cut from the right), whether it is padded
// out to that length (pad_side + pad_char) and, for the payment date, how the date is written. Positions with no column stay empty,
// so a layout can leave gaps. NONE as separator is a fixed-width file: every column then needs max_len + padding or the fields
// would run into each other, and that is refused instead of written wrong.
//
// A value that holds the separator or a line break would shift every field after it, so those become spaces (inside quotes only
// the line breaks do, and a double quote is doubled).
//
// paymentFile.js supplies the per-payment values (invoice text, part payment text ...); this file only lays them out.

export const SOURCE_FIELDS = {
  TRANSFER_TYPE: "Transfer type code (N = NEFT, R = RTGS)",
  MODE: "Payment mode (NEFT / RTGS)",
  ACCOUNT_NO: "Receiver's account number",
  AMOUNT: "Amount the bank sends (2 decimals)",
  BENEFICIARY_NAME: "Receiver's name",
  REFERENCE: "Reference (supplier id-payment no, at most 20)",
  PAYMENT_NO: "Payment number",
  SUPPLIER_CODE: "Supplier id",
  DETAIL_1: "Payment details 1 (invoice no(s) / tax head)",
  DETAIL_2: "Payment details 2 (FULL / PART / period)",
  DETAIL_3: "Payment details 3 (TDS, advance, notes / registration no)",
  PAYMENT_DATE: "Payment date",
  IFSC: "Receiver's IFSC",
  BANK_NAME: "Receiver's bank",
  BRANCH_NAME: "Receiver's branch",
  SERIAL_NO: "Line number in the file",
  SENDER_ACCOUNT_NO: "Our account number",
  SENDER_NAME: "Our account holder name",
  SENDER_IFSC: "Our IFSC",
  SENDER_BANK_NAME: "Our bank",
  SENDER_CLIENT_CODE: "Our client code with the bank",
  SENDER_EMAIL: "Our alert e-mail",
  FIXED: "Fixed text (typed in the column)",
  BLANK: "Empty",
};

export const DATE_FORMATS = ["DD/MM/YYYY", "DD-MM-YYYY", "YYYY-MM-DD", "DDMMYYYY", "YYYYMMDD"];
const SEPARATOR = { COMMA: ",", PIPE: "|", TAB: "\t", SEMICOLON: ";", NONE: "" };
const LINE_END = { LF: "\n", CRLF: "\r\n" };

/** @param iso 'YYYY-MM-DD...' (or a Date) @param style one of DATE_FORMATS */
export function formatDate(d, style = "DD/MM/YYYY") {
  const s = d instanceof Date ? d.toISOString() : String(d ?? "");
  const [y, m, day] = [s.slice(0, 4), s.slice(5, 7), s.slice(8, 10)];
  if (!/^\d{4}$/.test(y) || !/^\d{2}$/.test(m) || !/^\d{2}$/.test(day)) return "";
  return style.replace("YYYY", y).replace("MM", m).replace("DD", day);
}

const flat = (v) => String(v ?? "").replace(/[\r\n\t]+/g, " ").replace(/ {2,}/g, " ").trim();

/**
 * One value of one column.
 * @param ctx  { values: { <SOURCE_FIELD>: text }, paymentDate }  - values the caller worked out for this line (a field it has no value
 *             for is empty); PAYMENT_DATE is written here from ctx.paymentDate in the column's date format
 */
function valueOf(col, ctx) {
  const src = String(col.source_field ?? "").toUpperCase();
  if (src === "BLANK") return "";
  if (src === "FIXED") return col.fixed_value ?? "";
  if (src === "PAYMENT_DATE") return formatDate(ctx.paymentDate, col.date_format || "DD/MM/YYYY");
  if (!Object.hasOwn(SOURCE_FIELDS, src)) throw new Error(`Column ${col.position}: unknown source field ${col.source_field}.`);
  return ctx.values[src] ?? "";
}

/** Text of a column on one line: cleaned, cut to max_len, padded. */
function columnText(col, ctx, format) {
  const sep = SEPARATOR[format.delimiter];
  const quote = format.quote_text === "Y";
  let t = flat(valueOf(col, ctx));
  if (sep && !quote) t = t.split(sep).join(" ").replace(/ {2,}/g, " ").trim();
  if (col.max_len) t = t.slice(0, Number(col.max_len)).trimEnd();
  if (col.pad_side && col.max_len) {
    const ch = String(col.pad_char ?? " ").slice(0, 1) || " ";
    t = col.pad_side === "L" ? t.padStart(Number(col.max_len), ch) : t.padEnd(Number(col.max_len), ch);
  }
  return quote ? `"${t.replace(/"/g, '""')}"` : t;
}

/** The columns by position with empty cells for any gap; fixed width files are checked here. */
function layout(format, columns) {
  if (!Object.hasOwn(SEPARATOR, format.delimiter)) throw new Error(`Bank file format "${format.format_name}": unknown separator ${format.delimiter}.`);
  if (!Object.hasOwn(LINE_END, format.line_ending)) throw new Error(`Bank file format "${format.format_name}": unknown line ending ${format.line_ending}.`);
  const cols = [...columns].sort((a, b) => a.position - b.position);
  if (cols.length === 0) throw new Error(`Bank file format "${format.format_name}" has no columns - add them in the Bank File Format Column master.`);
  if (format.delimiter === "NONE") {
    const loose = cols.find((c) => !c.max_len || !c.pad_side);
    if (loose) throw new Error(`Bank file format "${format.format_name}" has no separator, so position ${loose.position} needs a maximum length and padding.`);
  }
  const width = cols[cols.length - 1].position;
  const byPos = new Map(cols.map((c) => [c.position, c]));
  const slots = Array.from({ length: width }, (_, k) => byPos.get(k + 1) ?? null);
  if (format.delimiter === "NONE" && slots.includes(null)) {
    throw new Error(`Bank file format "${format.format_name}" has no separator, so it cannot skip position ${slots.indexOf(null) + 1} - add a BLANK column there.`);
  }
  return slots;
}

/**
 * @param format   the bank_file_format row
 * @param columns  its bank_file_format_column rows
 * @param lines    [{ values: {...}, paymentDate }] one per transfer, in file order
 * @returns the file text ('' when there are no lines)
 */
export function renderFile(format, columns, lines) {
  if (lines.length === 0) return "";
  const slots = layout(format, columns);
  const sep = SEPARATOR[format.delimiter];
  const quote = format.quote_text === "Y";
  const out = [];
  if (format.has_header === "Y") {
    const head = (c) => {
      const h = flat(c?.header_text);
      return quote ? `"${h.replace(/"/g, '""')}"` : (sep ? h.split(sep).join(" ") : h);
    };
    out.push(slots.map(head).join(sep));
  }
  for (const ctx of lines) out.push(slots.map((c) => (c ? columnText(c, ctx, format) : "")).join(sep));
  return out.join(LINE_END[format.line_ending]);
}
