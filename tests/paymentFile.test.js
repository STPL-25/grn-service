// paymentFile.js - the bank payment file of a Payment Run: 28 comma separated positions per NEFT / RTGS transfer, no header,
// only real bank transfers, and nothing in a value that could shift a position.
import { describe, it, expect } from "@jest/globals";
import { buildPaymentFile, referenceOf, POSITION_COUNT, FILE_TYPES } from "../src/paymentnet/paymentFile.js";

const batch = (over = {}) => ({
  batch_no: "PB-2026-000007", batch_date: new Date("2026-10-22T00:00:00.000Z"), file_type: FILE_TYPES.BANK_UPLOAD,
  file_name: "SPACETEX_SPA311_SPA3112210.100", sender_alert_email: "payment.ktm@scmts.net", ...over,
});
const item = (over = {}) => ({
  payment_no: "PAY-2026-000011", vendor_sno: 122, mode: "NEFT", amount: 124277.76, channel: "BANK",
  beneficiary_name: "NEO DIAMONDS", account_no: "7312577145", ifsc: "kkbk0000961", bank_name: "KOTAK MAHINDRA BANK LIMITED", branch_name: "KALBADEVI",
  vendor_name: "NEO DIAMONDS", ...over,
});
const lines = (f) => (f.content === "" ? [] : f.content.split("\n"));
const fields = (line) => line.split(",");

describe("buildPaymentFile - the bank upload file", () => {
  it("writes one line per transfer: 28 positions, no header, LF between lines and none after the last", () => {
    const f = buildPaymentFile(batch(), [item(), item({ payment_no: "PAY-2026-000012", amount: 15000, mode: "RTGS" })]);
    expect(lines(f)).toHaveLength(2);
    expect(lines(f).every((l) => fields(l).length === POSITION_COUNT)).toBe(true);
    expect(f.content.endsWith("\n")).toBe(false);
    expect(f.content).not.toMatch(/\r/);
    expect(f.lineCount).toBe(2);
    expect(f.totalAmount).toBe(139277.76);
  });

  it("puts each value in its position: type, account, amount, name, reference, date, IFSC, bank, branch, e-mail - the rest stay empty", () => {
    const [line] = lines(buildPaymentFile(batch(), [item()]));
    const f = fields(line);
    expect(f[0]).toBe("N");                          // 1  transfer type
    expect(f[1]).toBe("");                           // 2
    expect(f[2]).toBe("7312577145");                 // 3  receiver's account
    expect(f[3]).toBe("124277.76");                  // 4  amount
    expect(f[4]).toBe("NEO DIAMONDS");               // 5  receiver's name
    expect(f[13]).toBe("122-PAY2026000011");         // 14 reference
    expect(f[22]).toBe("22/10/2026");                // 23 date
    expect(f[24]).toBe("KKBK0000961");               // 25 IFSC (upper case)
    expect(f[25]).toBe("KOTAK MAHINDRA BANK LIMITED"); // 26 bank
    expect(f[26]).toBe("KALBADEVI");                 // 27 branch
    expect(f[27]).toBe("payment.ktm@scmts.net");     // 28 e-mail
    const used = new Set([0, 2, 3, 4, 13, 22, 24, 25, 26, 27]);
    expect(f.every((v, i) => used.has(i) || v === "")).toBe(true);
  });

  it("uses N for NEFT and R for RTGS, whatever the case of the mode", () => {
    const f = buildPaymentFile(batch(), [item({ mode: "neft" }), item({ mode: "Rtgs", payment_no: "P2" })]);
    expect(lines(f).map((l) => fields(l)[0])).toEqual(["N", "R"]);
  });

  it("writes the amount with two decimals and no separators", () => {
    expect(fields(lines(buildPaymentFile(batch(), [item({ amount: 1000 })]))[0])[3]).toBe("1000.00");
    expect(fields(lines(buildPaymentFile(batch(), [item({ amount: "86400.5" })]))[0])[3]).toBe("86400.50");
  });

  it("cuts the receiver's name to its first 20 letters, and falls back to the supplier name when KYC has no account holder", () => {
    expect(fields(lines(buildPaymentFile(batch(), [item({ beneficiary_name: "THE VERY LONG ACCOUNT HOLDER NAME PRIVATE LIMITED" })]))[0])[4]).toBe("THE VERY LONG ACCOUN");
    expect(fields(lines(buildPaymentFile(batch(), [item({ beneficiary_name: "ABCDEFGHIJKLMNOPQRS TUV" })]))[0])[4]).toBe("ABCDEFGHIJKLMNOPQRS");   // no trailing space left by the cut
    expect(fields(lines(buildPaymentFile(batch(), [item({ beneficiary_name: null, vendor_name: "Sunrise Electricians" })]))[0])[4]).toBe("Sunrise Electricians");
  });

  it("names the file as the run decided and sends it as plain text", () => {
    const f = buildPaymentFile(batch(), [item()]);
    expect(f.fileName).toBe("SPACETEX_SPA311_SPA3112210.100");
    expect(f.mimeType).toBe("text/plain;charset=utf-8");
  });

  it("turns a comma, tab or line break inside a value into a space so no position shifts", () => {
    const [line] = lines(buildPaymentFile(batch(), [item({ bank_name: "HDFC, Ring Road\nBranch", branch_name: "Main,\tTown", beneficiary_name: "A,B" })]));
    expect(fields(line)).toHaveLength(POSITION_COUNT);
    expect(fields(line)[25]).toBe("HDFC Ring Road Branch");
    expect(fields(line)[26]).toBe("Main Town");
    expect(fields(line)[4]).toBe("A B");
  });

  it("leaves the e-mail position empty when the sender has no alert e-mail", () => {
    expect(fields(lines(buildPaymentFile(batch({ sender_alert_email: null }), [item()]))[0])[27]).toBe("");
  });

  it("keeps cheque / cash / DD, portal, fully-adjusted and UPI payments out of the file and says why", () => {
    const f = buildPaymentFile(batch(), [
      item({ payment_no: "P1" }),
      item({ payment_no: "P2", channel: "MANUAL", mode: "Cheque", vendor_name: "A" }),
      item({ payment_no: "P3", channel: "PORTAL", vendor_name: "B" }),
      item({ payment_no: "P4", channel: "ADJUSTMENT", amount: 0, vendor_name: "C" }),
      item({ payment_no: "P5", mode: "UPI", vendor_name: "D" }),
    ]);
    expect(lines(f)).toHaveLength(1);
    expect(f.content).not.toMatch(/P2|P3|P4|P5/);
    expect(f.skipped.map((s) => [s.payment_no, s.channel])).toEqual([["P2", "MANUAL"], ["P3", "PORTAL"], ["P4", "ADJUSTMENT"], ["P5", "BANK"]]);
    expect(f.skipped.every((s) => s.reason)).toBe(true);
    expect(f.skipped.find((s) => s.payment_no === "P5").reason).toMatch(/UPI is not paid through the bank file/);
    expect(f.lineCount).toBe(1);
  });

  it("keeps the order of the lines as given", () => {
    const f = buildPaymentFile(batch(), [item({ payment_no: "B" }), item({ payment_no: "A" })]);
    expect(lines(f).map((l) => fields(l)[13])).toEqual(["122-B", "122-A"]);
  });

  it("a run with nothing to upload gives an empty file - no name, no lines - and still lists what was left out", () => {
    const f = buildPaymentFile(batch({ file_type: null, file_name: null, sender_alert_email: null }), [item({ channel: "MANUAL", mode: "Cash" })]);
    expect(f.fileName).toBe("");
    expect(f.content).toBe("");
    expect(f.lineCount).toBe(0);
    expect(f.totalAmount).toBe(0);
    expect(f.skipped).toHaveLength(1);
  });

  it("refuses to write a line for a file type it does not know, or a run that has no file name", () => {
    expect(() => buildPaymentFile(batch({ file_type: "SOMETHING" }), [item()])).toThrow(/type SOMETHING/);
    expect(() => buildPaymentFile(batch({ file_type: null }), [item()])).toThrow(/type \(none\)/);
    expect(() => buildPaymentFile(batch({ file_name: null }), [item()])).toThrow(/no file name/);
  });
});

describe("referenceOf - supplier id and payment number, at most 20 characters", () => {
  it("is <supplier id>-<payment number without dashes>", () => {
    expect(referenceOf({ vendor_sno: 7, payment_no: "PAY-2026-000009" })).toBe("7-PAY2026000009");
  });

  it("keeps the payment number whole and shortens the supplier id when the two would not fit", () => {
    const r = referenceOf({ vendor_sno: 1234567890, payment_no: "PAY-2026-000009" });
    expect(r.length).toBeLessThanOrEqual(20);
    expect(r.endsWith("-PAY2026000009")).toBe(true);
    expect(r).toBe("123456-PAY2026000009");
  });

  it("is the payment number alone when there is no supplier id, and never longer than 20", () => {
    expect(referenceOf({ vendor_sno: null, payment_no: "PAY-2026-000009" })).toBe("PAY2026000009");
    expect(referenceOf({ vendor_sno: 5, payment_no: "P".repeat(30) })).toHaveLength(20);
  });
});
