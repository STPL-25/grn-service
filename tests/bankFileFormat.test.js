// bankFileFormat.js - the payment file written from a Bank File Format master (backend-stpl sql/149), not from a layout fixed in code.
import { describe, it, expect } from "@jest/globals";
import * as real from "../src/paymentnet/paymentFile.js";
const { FILE_TYPES } = real;
const buildPaymentFile = (b, i, l, layout) => real.buildPaymentFile(b, i, l, layout);
const buildStatutoryFile = (b, i, layout) => real.buildStatutoryFile(b, i, layout);
import { renderFile, formatDate } from "../src/paymentnet/bankFileFormat.js";

import { STD_FORMAT, STD_COLUMNS } from "./fixtures/standardLayout.js";

const batch = (over = {}) => ({
  batch_no: "PB-2026-000007", batch_date: new Date("2026-10-22T00:00:00.000Z"), file_type: FILE_TYPES.BANK_UPLOAD, file_name: "ACME_C1_C12210.100",
  sender_account_no: "50100123456789", sender_bank_name: "HDFC Bank", sender_client_code: "SPA311", sender_alert_email: "ap@acme.test", ...over,
});
const item = (over = {}) => ({
  payment_no: "PAY-2026-000011", vendor_sno: 122, mode: "NEFT", amount: 124277.76, channel: "BANK", beneficiary_name: "NEO DIAMONDS INTERNATIONAL PVT",
  account_no: "7312577145", ifsc: "kkbk0000961", bank_name: "KOTAK MAHINDRA BANK LIMITED", branch_name: "KALBADEVI",
  supplier_invoice_nos: "INV-77", tds_amount: 100, advance_amount: 0, note_amount: 0, ...over,
});
const rtgs = item({ payment_no: "PAY-2026-000012", vendor_sno: 9, mode: "RTGS", amount: 500000, account_no: "1234567", ifsc: "hdfc0000123", beneficiary_name: "A, B\nC" });

describe("the standard 28-position format", () => {
  const std = { format: STD_FORMAT, columns: STD_COLUMNS, sender: {} };
  it("writes the 28 positions of the layout the bank has always taken", () => {
    const { content } = buildPaymentFile(batch(), [item(), rtgs], [], std);
    const [l1, l2] = content.split("\n");
    expect(l1).toBe("N,,7312577145,124277.76,NEO DIAMONDS INTERNA,,,,,,,,,122-PAY2026000011,INV-77,,TDS 100,,,,,,22/10/2026,,KKBK0000961,KOTAK MAHINDRA BANK LIMITED,KALBADEVI,");
    expect(l1.split(",")).toHaveLength(28);
    expect(l2.split(",")[0]).toBe("R");
    expect(l2.split(",")).toHaveLength(28);
  });

  it("writes the statutory file the same way", () => {
    const sb = { batch_no: "SB2026000001", batch_date: "2026-10-22", kind: "TDS", file_type: FILE_TYPES.BANK_UPLOAD, file_name: "ACME_C1_C12210.101" };
    const rows = [{ line_no: 1, amount: 1500.5, mode: "NEFT", payee_name: "Income Tax Dept", account_no: "0123456789", ifsc: "sbin0000001", bank_name: "SBI", branch_name: "Main",
      reference_no: "TAN123", head_name: "TDS u/s 194C", period_label: "Sep 2026" }];
    expect(buildStatutoryFile(sb, rows, std).content).toBe("N,,0123456789,1500.50,Income Tax Dept,,,,,,,,,TDS2026000001-1,TDS u/s 194C,Sep 2026,TAN123,,,,,,22/10/2026,,SBIN0000001,SBI,Main,");
  });

  it("is refused when the run's bank account has no format - there is no built-in layout", () => {
    expect(() => buildPaymentFile(batch(), [item()], [], null)).toThrow(/no Bank File Format/);
    expect(() => buildStatutoryFile({ batch_no: "SB1", batch_date: "2026-10-22", kind: "TDS", file_type: FILE_TYPES.BANK_UPLOAD, file_name: "F.1" }, [], null)).toThrow(/no Bank File Format/);
  });

  it("writes the alert e-mail in position 28 when the format says so (the Federal Bank line)", () => {
    const federal = STD_COLUMNS.map((c) => (c.position === 28 ? { position: 28, source_field: "SENDER_EMAIL" } : c));
    const { content } = buildPaymentFile(batch(), [item()], [], { format: STD_FORMAT, columns: federal, sender: {} });
    expect(content.endsWith(",ap@acme.test")).toBe(true);
    expect(content.split(",")).toHaveLength(28);
  });
});

describe("a bank's own layout", () => {
  const cols = [
    { position: 1, header_text: "Ben A/c", source_field: "ACCOUNT_NO" },
    { position: 2, header_text: "Amt", source_field: "AMOUNT" },
    { position: 3, header_text: "IFSC", source_field: "IFSC" },
    { position: 4, header_text: "Mode", source_field: "MODE" },
    { position: 5, header_text: "Date", source_field: "PAYMENT_DATE", date_format: "YYYY-MM-DD" },
    { position: 6, header_text: "Dr A/c", source_field: "SENDER_ACCOUNT_NO" },
    { position: 7, header_text: "Type", source_field: "FIXED", fixed_value: "PAY" },
  ];
  const fmt = { format_name: "Pipe bank", delimiter: "PIPE", has_header: "Y", line_ending: "CRLF", quote_text: "N" };

  it("uses the separator, header line, line ending, date format, fixed text and sender fields the master says", () => {
    const { content } = buildPaymentFile(batch(), [item(), rtgs], [], { format: fmt, columns: cols, sender: {} });
    expect(content).toBe(["Ben A/c|Amt|IFSC|Mode|Date|Dr A/c|Type",
      "7312577145|124277.76|KKBK0000961|NEFT|2026-10-22|50100123456789|PAY",
      "1234567|500000.00|HDFC0000123|RTGS|2026-10-22|50100123456789|PAY"].join("\r\n"));
  });

  it("takes the sender's holder name and IFSC from the payment bank account", () => {
    const c = [{ position: 1, source_field: "SENDER_NAME" }, { position: 2, source_field: "SENDER_IFSC" }];
    const { content } = buildPaymentFile(batch(), [item()], [], { format: { ...fmt, has_header: "N" }, columns: c, sender: { ac_holder_name: "ACME LTD", ifsc: "hdfc0000001" } });
    expect(content).toBe("ACME LTD|HDFC0000001");
  });

  it("cuts to the maximum length and pads (left zeros, right spaces)", () => {
    const c = [
      { position: 1, source_field: "AMOUNT", max_len: 12, pad_side: "L", pad_char: "0" },
      { position: 2, source_field: "BENEFICIARY_NAME", max_len: 8, pad_side: "R", pad_char: " " },
      { position: 3, source_field: "SERIAL_NO", max_len: 3, pad_side: "L", pad_char: "0" },
    ];
    const { content } = buildPaymentFile(batch(), [item(), rtgs], [], { format: { ...fmt, delimiter: "NONE", has_header: "N", line_ending: "LF" }, columns: c, sender: {} });
    expect(content).toBe("000124277.76NEO DIAM001\n000500000.00A B C   002");
  });

  it("keeps a separator or line break inside a value from shifting the fields", () => {
    const { content } = buildPaymentFile(batch(), [rtgs], [], { format: { ...fmt, delimiter: "COMMA", has_header: "N" }, columns: [{ position: 1, source_field: "BENEFICIARY_NAME" }, { position: 2, source_field: "AMOUNT" }], sender: {} });
    expect(content).toBe("A B C,500000.00");
  });

  it("quotes every value when asked, doubling a quote inside (commas are already taken out of a name)", () => {
    const { content } = buildPaymentFile(batch(), [item({ beneficiary_name: 'A "B", C' })], [], { format: { ...fmt, delimiter: "COMMA", has_header: "Y", quote_text: "Y" }, columns: cols.slice(0, 2).concat([{ position: 3, source_field: "BENEFICIARY_NAME" }]), sender: {} });
    expect(content.split("\r\n")).toEqual(['"Ben A/c","Amt",""', '"7312577145","124277.76","A ""B"" C"']);
  });

  it("leaves empty cells for positions with no column", () => {
    const { content } = buildPaymentFile(batch(), [item()], [], { format: { ...fmt, has_header: "N", delimiter: "COMMA" }, columns: [{ position: 1, source_field: "MODE" }, { position: 4, source_field: "AMOUNT" }], sender: {} });
    expect(content).toBe("NEFT,,,124277.76");
  });

  it("refuses a fixed-width layout that would run its fields together, and a format with no columns", () => {
    const fixedWidth = { ...fmt, delimiter: "NONE", has_header: "N" };
    expect(() => renderFile(fixedWidth, [{ position: 1, source_field: "AMOUNT" }], [{ values: { AMOUNT: "1.00" } }])).toThrow(/needs a maximum length and padding/);
    expect(() => renderFile(fixedWidth, [{ position: 2, source_field: "AMOUNT", max_len: 5, pad_side: "L", pad_char: "0" }], [{ values: {} }])).toThrow(/cannot skip position 1/);
    expect(() => renderFile(fmt, [], [{ values: {} }])).toThrow(/has no columns/);
  });

  it("refuses an unknown source field instead of writing an empty column", () => {
    expect(() => renderFile(fmt, [{ position: 1, source_field: "NOPE" }], [{ values: {} }])).toThrow(/unknown source field/);
  });

  it("still leaves out what is not a bank transfer, and writes nothing when there is none", () => {
    const manual = item({ channel: "MANUAL", mode: "CHEQUE" });
    const r = buildPaymentFile(batch(), [manual], [], { format: fmt, columns: cols, sender: {} });
    expect(r.lineCount).toBe(0);
    expect(r.skipped).toHaveLength(1);
  });
});

describe("formatDate", () => {
  it.each([["DD/MM/YYYY", "22/10/2026"], ["DD-MM-YYYY", "22-10-2026"], ["YYYY-MM-DD", "2026-10-22"], ["DDMMYYYY", "22102026"], ["YYYYMMDD", "20261022"]])("%s", (style, expected) => {
    expect(formatDate(new Date("2026-10-22T00:00:00.000Z"), style)).toBe(expected);
  });
  it("is empty for no date", () => expect(formatDate(null)).toBe(""));
});
