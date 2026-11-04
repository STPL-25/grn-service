import { initializeDatabase } from "../config/db.js";

/**
 * The Bank File Format (backend-stpl sql/149) of a payment bank account, for paymentFile.js.
 * @returns { format, columns, sender: { ac_holder_name, ifsc } } - or null when the account has no format (it then gets the built-in
 *          28-position layout), when there is no account, or when sql/149 is not applied yet.
 */
export async function loadBankFileLayout(payment_bank_sno) {
  const id = Number(payment_bank_sno);
  if (!Number.isInteger(id) || id <= 0) return null;
  const pool = await initializeDatabase();
  const has = await pool.request().query("SELECT COL_LENGTH('dbo.payment_bank_master', 'file_format_sno') AS c");
  if (has.recordset[0]?.c == null) return null;
  // id is a checked positive integer, so it can be written into the statement
  const head = await pool.request().query(
    `SELECT f.format_sno, f.format_name, f.delimiter, f.has_header, f.line_ending, f.quote_text, m.ac_holder_name, m.ifsc
     FROM dbo.payment_bank_master m
     JOIN dbo.bank_file_format f ON f.format_sno = m.file_format_sno AND f.is_active = 'Y'
     WHERE m.payment_bank_sno = ${id}`);
  const row = head.recordset[0];
  if (row?.format_sno == null) return null;
  const cols = await pool.request().query(
    `SELECT position, header_text, source_field, fixed_value, max_len, pad_side, pad_char, date_format
     FROM dbo.bank_file_format_column WHERE format_sno = ${Number(row.format_sno)} AND is_active = 'Y' ORDER BY position`);
  const { ac_holder_name, ifsc, ...format } = row;
  return { format, columns: cols.recordset, sender: { ac_holder_name, ifsc } };
}
