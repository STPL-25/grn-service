// The "Standard 28-position (NEFT / RTGS)" Bank File Format exactly as backend-stpl sql/149 seeds it: comma separated, no header, LF.
// The payment file is written only from a format, so tests that look at the file hand it this one.
export const STD_FORMAT = { format_name: "Standard 28-position (NEFT / RTGS)", delimiter: "COMMA", has_header: "N", line_ending: "LF", quote_text: "N" };
const blanks = (from, to) => Array.from({ length: to - from + 1 }, (_, k) => ({ position: from + k, source_field: "BLANK" }));
export const STD_COLUMNS = [
  { position: 1, source_field: "TRANSFER_TYPE" }, { position: 2, source_field: "BLANK" }, { position: 3, source_field: "ACCOUNT_NO" },
  { position: 4, source_field: "AMOUNT" }, { position: 5, source_field: "BENEFICIARY_NAME", max_len: 20 }, ...blanks(6, 13),
  { position: 14, source_field: "REFERENCE" }, { position: 15, source_field: "DETAIL_1" }, { position: 16, source_field: "DETAIL_2" }, { position: 17, source_field: "DETAIL_3" },
  ...blanks(18, 22), { position: 23, source_field: "PAYMENT_DATE", date_format: "DD/MM/YYYY" }, { position: 24, source_field: "BLANK" },
  { position: 25, source_field: "IFSC" }, { position: 26, source_field: "BANK_NAME" }, { position: 27, source_field: "BRANCH_NAME" }, { position: 28, source_field: "BLANK" },
];
export const STD_LAYOUT = { format: STD_FORMAT, columns: STD_COLUMNS, sender: {} };
