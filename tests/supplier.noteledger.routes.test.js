// supplier.routes.js - the ledger upload edge of the supplier portal's Debit / Credit Notes screen (sql/87).
// Whether a note / invoice belongs to the supplier is decided in SQL (sp_nt_AddSupplierNoteLedger) and was checked against the
// database; here: which request reaches the FTP server and the procedure, that the supplier id comes from the LOGIN (never the
// body), and that the procedure's supplier-facing messages come back untouched.
import { describe, it, expect, jest, beforeAll, afterAll, beforeEach } from "@jest/globals";
import express from "express";
import multer from "multer";

const input = jest.fn();
const execute = jest.fn();
const request = { input, execute };
input.mockReturnValue(request);
const uploadFileIfExists = jest.fn();

jest.unstable_mockModule("../src/config/db.js", () => ({
  initializeDatabase: async () => ({ request: () => request }),
}));
jest.unstable_mockModule("../src/utils/ftpUpload.js", () => ({
  upload: multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } }),
  ftpUploader: { uploadFileIfExists },
}));
jest.unstable_mockModule("../src/middleware/auth.js", () => ({ default: (_req, _res, next) => next() }));
jest.unstable_mockModule("../src/middleware/supplierAuth.js", () => ({
  verifySupplierAuth: (req, _res, next) => { req.supplier = { kyc_basic_info_sno: 55, supp_code: "SUP55", email: "s55@example.com" }; next(); },
  signSupplierToken: () => "token",
}));
jest.unstable_mockModule("../src/utils/notifyClient.js", () => ({
  createInAppNotification: async () => ({ sent: true }),
  sendSupplierInviteEmail: async () => ({ sent: true }),
}));
jest.unstable_mockModule("../src/utils/prTracking.js", () => ({ broadcastPrTrack: async () => {} }));

const { default: SupplierRouter } = await import("../src/supplier/supplier.routes.js");

let server;
let base;
beforeAll(async () => {
  const app = express();
  app.use(express.json());
  app.use("/api/supplier", SupplierRouter);
  server = app.listen(0);
  base = `http://127.0.0.1:${server.address().port}/api/supplier`;
});
afterAll(() => new Promise((r) => server.close(r)));
beforeEach(() => {
  input.mockClear();
  execute.mockReset();
  uploadFileIfExists.mockReset();
});

/** the JSON the procedure was called with */
const sent = () => JSON.parse(input.mock.calls.at(-1)[2]);
const form = (fields, file) => {
  const fd = new FormData();
  for (const [k, v] of Object.entries(fields)) fd.append(k, v);
  if (file) fd.append("ledger_file", new Blob([file.body ?? "x"]), file.name);
  return fd;
};
const post = (fd) => fetch(`${base}/note-ledgers`, { method: "POST", body: fd }).then(async (r) => ({ status: r.status, json: await r.json() }));
const row = { ledger_sno: 9, scope: "NOTE", note_kind: "CREDIT", note_sno: 4, invoice_no: null, file_url: "http://be/dwl/NON_TRADE_DATAS/NOTE_LEDGERS/l.pdf" };

describe("POST /note-ledgers", () => {
  it("needs a file", async () => {
    const r = await post(form({ scope: "NOTE", note_kind: "DEBIT", note_sno: "1" }));
    expect(r.status).toBe(400);
    expect(r.json.error).toMatch(/Choose the ledger file/);
    expect(execute).not.toHaveBeenCalled();
  });

  it("refuses a file type that is not a ledger, before anything is uploaded", async () => {
    const r = await post(form({ scope: "NOTE", note_kind: "DEBIT", note_sno: "1" }, { name: "page.html" }));
    expect(r.status).toBe(400);
    expect(r.json.error).toMatch(/PDF/);
    expect(uploadFileIfExists).not.toHaveBeenCalled();
    expect(execute).not.toHaveBeenCalled();
  });

  it("refuses an unknown scope before anything is uploaded", async () => {
    const r = await post(form({ scope: "ALL" }, { name: "l.pdf" }));
    expect(r.status).toBe(400);
    expect(r.json.error).toMatch(/single note or against an invoice/);
    expect(uploadFileIfExists).not.toHaveBeenCalled();
  });

  it("refuses a note upload that names no real note, before anything is uploaded", async () => {
    uploadFileIfExists.mockResolvedValue("http://be/dwl/x.pdf");
    const r = await post(form({ scope: "NOTE", note_kind: "SIDEWAYS", note_sno: "abc" }, { name: "l.pdf" }));
    expect(r.status).toBe(400);
    expect(r.json.error).toMatch(/Choose the debit or credit note/);
    expect(uploadFileIfExists).not.toHaveBeenCalled();
    expect(execute).not.toHaveBeenCalled();
  });

  it("stores a ledger for ONE note; the supplier is the logged-in one, whatever the body says", async () => {
    uploadFileIfExists.mockResolvedValue(row.file_url);
    execute.mockResolvedValue({ recordset: [row] });
    const r = await post(form({ scope: "note", note_kind: "credit", note_sno: "4", kyc_basic_info_sno: "999", remarks: "Oct ledger" }, { name: "Oct ledger.pdf" }));
    expect(r.status).toBe(200);
    expect(r.json.data).toEqual(row);
    expect(uploadFileIfExists.mock.calls[0][1]).toBe("NON_TRADE_DATAS/NOTE_LEDGERS");
    expect(execute).toHaveBeenCalledWith("sp_nt_AddSupplierNoteLedger");
    expect(sent()).toEqual({
      kyc_basic_info_sno: 55, scope: "NOTE", note_kind: "CREDIT", note_sno: 4,
      file_url: row.file_url, file_name: "Oct ledger.pdf", remarks: "Oct ledger", uploaded_by: "s55@example.com",
    });
  });

  it("stores a ledger for an INVOICE (no note id goes to the procedure)", async () => {
    uploadFileIfExists.mockResolvedValue(row.file_url);
    execute.mockResolvedValue({ recordset: [{ ...row, scope: "INVOICE", invoice_no: "INV-1" }] });
    const r = await post(form({ scope: "INVOICE", invoice_no: " INV-1 ", note_kind: "DEBIT", note_sno: "3" }, { name: "stmt.xlsx" }));
    expect(r.status).toBe(200);
    expect(sent()).toEqual({
      kyc_basic_info_sno: 55, scope: "INVOICE", invoice_no: "INV-1",
      file_url: row.file_url, file_name: "stmt.xlsx", uploaded_by: "s55@example.com",
    });
  });

  it("an invoice upload needs the invoice number, before anything is uploaded", async () => {
    uploadFileIfExists.mockResolvedValue(row.file_url);
    const r = await post(form({ scope: "INVOICE", invoice_no: "  " }, { name: "stmt.csv" }));
    expect(r.status).toBe(400);
    expect(r.json.error).toMatch(/Choose the invoice/);
    expect(uploadFileIfExists).not.toHaveBeenCalled();
    expect(execute).not.toHaveBeenCalled();
  });

  it("502 when the FTP server does not take the file, and nothing is recorded", async () => {
    uploadFileIfExists.mockResolvedValue("");
    const r = await post(form({ scope: "NOTE", note_kind: "DEBIT", note_sno: "1" }, { name: "l.pdf" }));
    expect(r.status).toBe(502);
    expect(r.json.error).toMatch(/could not be uploaded/);
    expect(execute).not.toHaveBeenCalled();
  });

  it("the procedure's message for the supplier comes back as written (not wrapped as a database error)", async () => {
    uploadFileIfExists.mockResolvedValue(row.file_url);
    execute.mockRejectedValue(Object.assign(new Error("None of your debit / credit notes is on that invoice."), { number: 58105 }));
    const r = await post(form({ scope: "INVOICE", invoice_no: "NOPE" }, { name: "l.pdf" }));
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("None of your debit / credit notes is on that invoice.");
  });

  it("any other database failure is reported as one", async () => {
    uploadFileIfExists.mockResolvedValue(row.file_url);
    execute.mockRejectedValue(Object.assign(new Error("Timeout"), { number: 1222 }));
    const r = await post(form({ scope: "NOTE", note_kind: "DEBIT", note_sno: "1" }, { name: "l.pdf" }));
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("Database error: Timeout");
  });

  it("a file over 10 MB is a JSON 400, not an HTML error page", async () => {
    const r = await post(form({ scope: "NOTE", note_kind: "DEBIT", note_sno: "1" }, { name: "big.pdf", body: new Uint8Array(10 * 1024 * 1024 + 10) }));
    expect(r.status).toBe(400);
    expect(r.json.error).toMatch(/under 10 MB/);
    expect(uploadFileIfExists).not.toHaveBeenCalled();
  });
});

describe("GET /note-ledgers", () => {
  it("lists the logged-in supplier's ledgers", async () => {
    execute.mockResolvedValue({ recordset: [row] });
    const res = await fetch(`${base}/note-ledgers`);
    expect(res.status).toBe(200);
    expect((await res.json()).data).toEqual([row]);
    expect(execute).toHaveBeenCalledWith("sp_nt_GetSupplierNoteLedgers");
    expect(sent()).toEqual({ kyc_basic_info_sno: 55 });
  });
});

describe("DELETE /note-ledgers/:ledger_sno", () => {
  it("removes one of the supplier's own ledgers", async () => {
    execute.mockResolvedValue({ recordset: [{ ledger_sno: 9 }] });
    const res = await fetch(`${base}/note-ledgers/9`, { method: "DELETE" });
    expect(res.status).toBe(200);
    expect(execute).toHaveBeenCalledWith("sp_nt_RemoveSupplierNoteLedger");
    expect(sent()).toEqual({ kyc_basic_info_sno: 55, ledger_sno: 9 });
  });

  it("a ledger id that is not a number never reaches the database", async () => {
    const res = await fetch(`${base}/note-ledgers/abc`, { method: "DELETE" });
    expect(res.status).toBe(400);
    expect(execute).not.toHaveBeenCalled();
  });

  it("someone else's / already removed ledger: the procedure's message", async () => {
    execute.mockRejectedValue(Object.assign(new Error("That ledger was not found (it may already be removed)."), { number: 58107 }));
    const res = await fetch(`${base}/note-ledgers/9`, { method: "DELETE" });
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/not found/);
  });
});
