// reverseFile.js - reading the bank's reverse file by its header and matching it to a run's transfers (sql/83).
import { describe, it, expect } from "@jest/globals";
import { actionOf, fileItemsOf, matchReverseFile, parseAmount, parseBankDate, parseReverseFile, statusOf } from "../src/paymentnet/reverseFile.js";

const batch = { batch_no: "PB-2026-000021", file_name: "SPACETEX_SPA311_SPA3110311.100" };
const item = (o) => ({ channel: "BANK", mode: "NEFT", bank_status: null, utr_no: null, payment_status: "Processed", paid_again_batch_no: null, ...o });
const items = [
  item({ batch_item_sno: 1, line_no: 1, payment_no: "PAY-2026-000031", vendor_sno: 122, vendor_name: "Aravali", amount: 48300, account_no: "1205012345" }),
  item({ batch_item_sno: 2, line_no: 2, payment_no: "PAY-2026-000032", vendor_sno: 135, vendor_name: "Coastal", amount: 250000, mode: "RTGS", account_no: "912020045678901" }),
  item({ batch_item_sno: 3, line_no: 3, payment_no: "PAY-2026-000033", vendor_sno: 141, vendor_name: "Silver Oak", amount: 9450, account_no: "38291045566" }),
  item({ batch_item_sno: 4, line_no: 4, payment_no: "PAY-2026-000034", vendor_sno: 150, vendor_name: "Bluepeak", amount: 61500, account_no: "50100223344556" }),
  item({ batch_item_sno: 5, line_no: 5, payment_no: "PAY-2026-000035", vendor_sno: 160, vendor_name: "Cheque Co", amount: 700, mode: "Cheque", channel: "MANUAL" }),
];

// the sample reverse file in docs/payment_reverse_file (20 columns, header line)
const HEAD = "File Name,Line No,Transaction Type,Beneficiary Account No,Amount,Beneficiary Name,Customer Reference No,Payment Details 1,Payment Details 2,Payment Details 3,Payment Date,Beneficiary IFSC,Status,UTR No,Bank Reference No,Debit Date,Credit / Return Date Time,Reason Code,Reason,Debit Account No";
const SAMPLE = [
  HEAD,
  "SPACETEX_SPA311_SPA3110311.100,1,N,001205012345,48300.00,Aravali Electricals,122-PAY2026000031,AE/1182,FULL,TDS 700,03/11/2026,ICIC0000012,PAID,HDFCN26307004512,BLK0311000101,03/11/2026,03/11/2026 11:42:10,,Credited to beneficiary,50200012345678",
  "SPACETEX_SPA311_SPA3110311.100,2,R,912020045678901,250000.00,Coastal Line Logisti,135-PAY2026000032,CLL-2210,PART 250000.00/400000.00,,03/11/2026,UTIB0000456,PAID,HDFCR52026110300087321,BLK0311000102,03/11/2026,03/11/2026 11:05:37,,Credited to beneficiary,50200012345678",
  "SPACETEX_SPA311_SPA3110311.100,3,N,38291045566,9450.00,Silver Oak Stationer,141-PAY2026000033,SOS-77,FULL,ADV 500 DN 50,03/11/2026,SBIN0001234,RETURNED,HDFCN26307004513,BLK0311000103,03/11/2026,04/11/2026 10:15:02,AC04,Beneficiary account closed - amount credited back,50200012345678",
  "SPACETEX_SPA311_SPA3110311.100,4,N,50100223344556,61500.00,Bluepeak IT Solution,150-PAY2026000034,BP-901/BP-915,FULL,TDS 1500,03/11/2026,KKBK0008765,REJECTED,,BLK0311000104,,,AC01,Invalid beneficiary account number - not debited,50200012345678",
].join("\r\n");

describe("parseReverseFile", () => {
  it("reads the sample by its header, whatever the column order", () => {
    const p = parseReverseFile(SAMPLE);
    expect(p.separator).toBe(",");
    expect(p.rows).toHaveLength(4);
    expect(p.rows[0].raw).toMatchObject({ REFERENCE: "122-PAY2026000031", STATUS: "PAID", UTR: "HDFCN26307004512", AMOUNT: "48300.00", ACCOUNT_NO: "001205012345", FILE_NAME: batch.file_name });
    expect(p.rows[2].raw).toMatchObject({ STATUS: "RETURNED", REASON_CODE: "AC04", CREDIT_AT: "04/11/2026 10:15:02" });
    expect(p.fields).toEqual(expect.arrayContaining(["REFERENCE", "STATUS", "UTR", "BANK_REF", "DEBIT_DATE", "CREDIT_AT", "REASON_CODE", "REASON"]));
  });

  it("takes other banks' names, pipes, quotes, a BOM and blank lines", () => {
    const p = parseReverseFile("﻿Cust Ref No|Txn Status|UTR|Reject Reason\n\n\"150-PAY2026000034\"|Failed|\"\"|\"Name, mismatch\"\n");
    expect(p.separator).toBe("|");
    expect(p.rows).toEqual([{ row_no: 3, raw: { REFERENCE: "150-PAY2026000034", STATUS: "Failed", UTR: "", REASON: "Name, mismatch" } }]);
  });

  it("refuses a file without the reference or the status column", () => {
    expect(() => parseReverseFile("Amount,UTR\n100,X")).toThrow(/reference column/);
    expect(() => parseReverseFile("")).toThrow(/empty/);
    expect(() => parseReverseFile(HEAD)).toThrow(/no lines/);
  });
});

describe("values", () => {
  it("knows the usual status words", () => {
    expect(["Success", "EXECUTED", "e", "Credited"].map(statusOf)).toEqual(["PAID", "PAID", "PAID", "PAID"]);
    expect(["In Process", "pending", "P"].map(statusOf)).toEqual(["PENDING", "PENDING", "PENDING"]);
    expect(["Rejected", "FAILED", "r"].map(statusOf)).toEqual(["REJECTED", "REJECTED", "REJECTED"]);
    expect(["Returned", "RETURN", "Reversed"].map(statusOf)).toEqual(["RETURNED", "RETURNED", "RETURNED"]);
    expect(statusOf("maybe")).toBeNull();
  });

  it("reads Indian bank dates day first, with or without a time", () => {
    expect(parseBankDate("03/11/2026")).toEqual({ date: "2026-11-03", at: null });
    expect(parseBankDate("03-11-2026 11:42:10")).toEqual({ date: "2026-11-03", at: "2026-11-03 11:42:10" });
    expect(parseBankDate("2026-11-03T09:05")).toEqual({ date: "2026-11-03", at: "2026-11-03 09:05:00" });
    expect(parseBankDate("03-Nov-2026 02:15 PM")).toEqual({ date: "2026-11-03", at: "2026-11-03 14:15:00" });
    expect(parseBankDate("03112026")).toEqual({ date: "2026-11-03", at: null });
    expect(parseBankDate("20261103")).toEqual({ date: "2026-11-03", at: null });
    expect(parseBankDate("31/02/2026")).toBeNull();
    expect(parseBankDate("")).toBeNull();
  });

  it("reads amounts with rupee signs and Indian grouping", () => {
    expect(parseAmount("₹ 2,50,000.00")).toBe(250000);
    expect(parseAmount("Rs.9450")).toBe(9450);
    expect(parseAmount("48300.00 CR")).toBe(48300);
    expect(parseAmount("abc")).toBeNull();
  });
});

describe("matchReverseFile", () => {
  it("matches the sample to the run: two paid, one returned, one rejected; the cheque is not a file line", () => {
    const m = matchReverseFile(batch, items, parseReverseFile(SAMPLE));
    expect(fileItemsOf(items).map((i) => i.batch_item_sno)).toEqual([1, 2, 3, 4]);
    expect(m.summary).toEqual({ lines: 4, matched: 4, problems: 0, paid: 2, pending: 0, failed: 2, no_change: 0 });
    expect(m.missing).toEqual([]);
    expect(m.apply).toEqual([
      { batch_item_sno: 1, line_no: 1, status: "PAID", amount: 48300, utr_no: "HDFCN26307004512", bank_ref_no: "BLK0311000101", debit_date: "2026-11-03", credit_at: "2026-11-03 11:42:10", reason_code: null, reason: "Credited to beneficiary" },
      expect.objectContaining({ batch_item_sno: 2, status: "PAID", utr_no: "HDFCR52026110300087321" }),
      expect.objectContaining({ batch_item_sno: 3, status: "RETURNED", reason_code: "AC04", credit_at: "2026-11-04 10:15:02" }),
      expect.objectContaining({ batch_item_sno: 4, status: "REJECTED", utr_no: null, debit_date: null, reason_code: "AC01" }),
    ]);
    expect(m.lines.map((l) => l.action)).toEqual(["MARK_PAID", "MARK_PAID", "RETURN_TO_RUN", "RETURN_TO_RUN"]);
  });

  it("does not apply a line that disagrees with the run, and lists what the file left out", () => {
    const file = [
      "Customer Reference No,Status,Amount,Beneficiary Account No,UTR No,File Name",
      "122-PAY2026000031,Paid,48300.01,1205012345,U1,",                         // amount differs by a paisa
      "135-PAY2026000032,Paid,250000,999,U2,",                                   // another account
      "141-PAY2026000033,Paid,9450,38291045566,,",                               // paid without a UTR
      "141-PAY2026000033,Rejected,9450,38291045566,,",                           // twice (the first, a problem, still counts as the line)
      "999-PAY2026000099,Paid,1,1,U9,",                                          // not in this run
      "150-PAY2026000034,Maybe,61500,50100223344556,,",                          // unknown status
      "150-PAY2026000034,Paid,61500,50100223344556,U4,OTHER_FILE.101",           // another upload file
    ].join("\n");
    const m = matchReverseFile(batch, items, parseReverseFile(file));
    expect(m.apply).toEqual([]);
    expect(m.lines.map((l) => l.problem)).toEqual([
      expect.stringMatching(/Amount 48300.01 is not what the run sent \(48300.00\)/),
      expect.stringMatching(/Account 999 is not the account/),
      expect.stringMatching(/no UTR/),
      expect.stringMatching(/more than once/),
      expect.stringMatching(/No transfer of PB-2026-000021 has the reference 999-PAY2026000099/),
      expect.stringMatching(/Status "Maybe"/),
      expect.stringMatching(/another upload file \(OTHER_FILE.101\)/),
    ]);
    expect(m.missing.map((x) => x.reference)).toEqual([]);   // every transfer was named, even if wrongly
    const partial = matchReverseFile(batch, items, parseReverseFile("Reference,Status,UTR\n122-PAY2026000031,S,U1"));
    expect(partial.missing.map((x) => x.reference)).toEqual(["135-PAY2026000032", "141-PAY2026000033", "150-PAY2026000034"]);
  });

  it("compares account numbers without leading zeros (the KYC keeps them as a number)", () => {
    const m = matchReverseFile(batch, items, parseReverseFile("Customer Reference No,Status,Beneficiary Account No,UTR No\n122-PAY2026000031,PAID,0001205012345,U1"));
    expect(m.lines[0].problem).toBeNull();
  });
});

describe("actionOf - what a line does to what the run line is now", () => {
  it("follows the bank's latest answer and never moves a payment that left the run", () => {
    expect(actionOf("PAID", item({}), "U1").action).toBe("MARK_PAID");
    expect(actionOf("PAID", item({ bank_status: "PENDING" }), "U1").action).toBe("MARK_PAID");
    expect(actionOf("PAID", item({ bank_status: "PAID", utr_no: "U1" }), "U1").action).toBe("NO_CHANGE");
    expect(actionOf("PAID", item({ bank_status: "PAID", utr_no: "U1" }), "U2").action).toBe("UPDATE_UTR");
    expect(actionOf("PAID", item({ bank_status: "RETURNED" }), "U1").action).toBe("IGNORED");
    expect(actionOf("PENDING", item({}), null).action).toBe("MARK_PENDING");
    expect(actionOf("PENDING", item({ bank_status: "PAID" }), null).action).toBe("IGNORED");
    expect(actionOf("RETURNED", item({ bank_status: "PAID" }), "U1")).toMatchObject({ action: "RETURN_TO_RUN", text: expect.stringMatching(/marked paid before/) });
    expect(actionOf("REJECTED", item({ bank_status: "REJECTED" }), null).action).toBe("NO_CHANGE");
    expect(actionOf("REJECTED", item({ payment_status: "Approved" }), null).action).toBe("IGNORED");
    expect(actionOf("REJECTED", item({ paid_again_batch_no: "PB-2026-000030" }), null).action).toBe("IGNORED");
  });
});
