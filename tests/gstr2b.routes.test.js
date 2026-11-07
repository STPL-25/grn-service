// gstr2b.routes.js - company scope of the GSTR-2B screen (sql/90): a user only lists, opens, uploads to and acts on
// 2B files / rows / invoices of companies in their own hierarchy. The SQL filters are exercised against the database
// (sql/_verify_90.mjs); this checks what the HTTP edge sends and refuses.
import { describe, it, expect, jest, beforeAll, afterAll, beforeEach } from "@jest/globals";
import express from "express";

// the caller may see company 1 (one branch of it) only
const hierarchy = [{ com_sno: 1, div_sno: 3, brn_sno: 4 }];
// what the database holds: upload 3 / row 25 belong to company 1, upload 9 / row 90 to company 2
const scope = {
  upload: { 3: { com_sno: 1 }, 9: { com_sno: 2 } },
  row: { 25: { com_sno: 1 }, 90: { com_sno: 2 } },
  invoice: { 6: { com_sno: 1, div_sno: 3, brn_sno: 4 }, 7: { com_sno: 1, div_sno: 1, brn_sno: 1 }, 8: { com_sno: 2, div_sno: 3, brn_sno: 4 } },
};

const calls = [];
const makeRequest = () => {
  const inputs = {};
  const req = {
    input: (name, _type, value) => { inputs[name] = value; return req; },
    execute: async (proc) => {
      const body = inputs.jsonInput ? JSON.parse(inputs.jsonInput) : undefined;
      calls.push({ proc, body, inputs: { ...inputs } });
      switch (proc) {
        case "sp_nt_Gstr2bScopeOf": {
          const hit = body.upload_sno != null ? scope.upload[body.upload_sno] : body.row_sno != null ? scope.row[body.row_sno] : scope.invoice[body.invoice_sno];
          return { recordset: hit ? [hit] : [] };
        }
        case "sp_nt_Gstr2bSummary": {
          const u = scope.upload[inputs.upload_sno];
          return { recordset: u ? [{ upload_sno: inputs.upload_sno, com_sno: u.com_sno }] : [] };
        }
        case "sp_nt_Gstr2bGetRows": return { recordset: [{ row_sno: 25 }] };
        case "sp_nt_Gstr2bEditRow": return { recordset: [{ row_sno: body.row_sno, match_status: "Matched" }] };
        case "sp_nt_Gstr2bSkipRow": return { recordset: [{ row_sno: body.row_sno, match_status: "Skipped" }] };
        case "sp_nt_Gstr2bCandidates": return { recordset: [] };
        case "sp_nt_Gstr2bConfirmSupplier": return { recordset: [{ row_sno: body.row_sno, match_status: "Added" }] };
        case "sp_nt_SetInvoiceHoldOverride": return { recordset: [{ invoice_sno: body.invoice_sno, payment_hold_override: body.override }] };
        default: return { recordset: [] };
      }
    },
  };
  return req;
};

jest.unstable_mockModule("../src/config/db.js", () => ({ initializeDatabase: async () => ({ request: makeRequest }) }));
jest.unstable_mockModule("../src/middleware/hierarchyScope.js", () => ({
  attachHierarchyScope: (req, _res, next) => { req.hierarchyJson = hierarchy; next(); },
}));
const releaseUnpaidGst = jest.fn(async () => []);
jest.unstable_mockModule("../src/paymentnet/paymentnet.routes.js", () => ({ releaseUnpaidGst }));
const parseGstr2bWorkbook = jest.fn(async () => ({ rows: [{ supplier_gstin: "33AAAAA0000A1Z5", invoice_no: "1" }], sheets: ["B2B"] }));
jest.unstable_mockModule("../src/gstr2b/gstr2b.parser.js", () => ({ parseGstr2bWorkbook }));

const { default: Gstr2bRouter } = await import("../src/gstr2b/gstr2b.routes.js");

let server;
let base;
beforeAll(async () => {
  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => { req.user = { ecno: "TEST001" }; next(); });
  app.use("/api/gstr2b", Gstr2bRouter);
  server = app.listen(0);
  base = `http://127.0.0.1:${server.address().port}/api/gstr2b`;
});
afterAll(() => new Promise((resolve) => server.close(resolve)));
beforeEach(() => { calls.length = 0; parseGstr2bWorkbook.mockClear(); });

const call = async (method, path, body) => {
  const res = await fetch(base + path, {
    method, headers: body && !(body instanceof FormData) ? { "Content-Type": "application/json" } : undefined,
    body: body instanceof FormData ? body : body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, json: await res.json() };
};
const ran = (proc) => calls.some((c) => c.proc === proc);
const sentTo = (proc) => calls.find((c) => c.proc === proc)?.body;
const xlsx = () => {
  const fd = new FormData();
  fd.append("file", new Blob([new Uint8Array([1, 2, 3])]), "2b.xlsx");
  fd.append("return_period", "102026");
  return fd;
};

describe("lists", () => {
  it("lists one company's uploads, always with the caller's hierarchy", async () => {
    const { status } = await call("GET", "/uploads?com_sno=1");
    expect(status).toBe(200);
    expect(sentTo("sp_nt_Gstr2bListUploads")).toEqual({ com_sno: 1, hierarchy });
  });
  it("still sends the hierarchy when no company is given (never an unfiltered list)", async () => {
    await call("GET", "/uploads");
    expect(sentTo("sp_nt_Gstr2bListUploads")).toEqual({ hierarchy });
  });
  it("missing-in-2B is per company and hierarchy-scoped", async () => {
    await call("GET", "/missing?com_sno=1");
    expect(sentTo("sp_nt_Gstr2bMissingIn2B")).toEqual({ com_sno: 1, hierarchy });
  });
});

describe("opening an upload", () => {
  it("opens an upload of the caller's company (a branch-level grant covers the company's 2B)", async () => {
    const { status, json } = await call("GET", "/uploads/3");
    expect(status).toBe(200);
    expect(json.data.summary.com_sno).toBe(1);
    expect(ran("sp_nt_Gstr2bGetRows")).toBe(true);
  });
  it("another company's upload is not found and its rows are not read", async () => {
    const { status, json } = await call("GET", "/uploads/9");
    expect(status).toBe(404);
    expect(json.success).toBe(false);
    expect(ran("sp_nt_Gstr2bGetRows")).toBe(false);
  });
  it("an unknown upload is not found", async () => {
    expect((await call("GET", "/uploads/12345")).status).toBe(404);
    expect((await call("GET", "/uploads/abc")).status).toBe(404);
  });
});

describe("uploading", () => {
  it("needs a company", async () => {
    const { status, json } = await call("POST", "/upload", xlsx());
    expect(status).toBe(400);
    expect(json.error).toMatch(/company/i);
    expect(parseGstr2bWorkbook).not.toHaveBeenCalled();
  });
  it("refuses a company outside the caller's hierarchy before reading the file", async () => {
    const fd = xlsx();
    fd.append("com_sno", "2");
    const { status } = await call("POST", "/upload", fd);
    expect(status).toBe(403);
    expect(parseGstr2bWorkbook).not.toHaveBeenCalled();
    expect(ran("sp_nt_Gstr2bImport")).toBe(false);
  });
  it("saves the file under the chosen company", async () => {
    const fd = xlsx();
    fd.append("com_sno", "1");
    await call("POST", "/upload", fd);
    expect(sentTo("sp_nt_Gstr2bImport")).toMatchObject({ com_sno: 1, return_period: "102026", uploaded_by: "TEST001" });
  });
});

describe("row and invoice actions", () => {
  it("acts on a row of the caller's company", async () => {
    expect((await call("PUT", "/rows/25", { invoice_no: "X1" })).status).toBe(200);
    expect(ran("sp_nt_Gstr2bEditRow")).toBe(true);
  });
  it.each([
    ["PUT", "/rows/90", { invoice_no: "X1" }, "sp_nt_Gstr2bEditRow"],
    ["POST", "/rows/90/skip", {}, "sp_nt_Gstr2bSkipRow"],
    ["POST", "/rows/90/confirm", { vendor_sno: 5 }, "sp_nt_Gstr2bConfirmSupplier"],
    ["GET", "/rows/90/candidates", undefined, "sp_nt_Gstr2bCandidates"],
  ])("%s %s on another company's row is refused", async (method, path, body, proc) => {
    const { status } = await call(method, path, body);
    expect(status).toBe(404);
    expect(ran(proc)).toBe(false);
  });
  it("releases the hold on an invoice in the caller's branch", async () => {
    expect((await call("POST", "/invoices/6/hold-override", { override: "Y", reason: "ok" })).status).toBe(200);
    expect(ran("sp_nt_SetInvoiceHoldOverride")).toBe(true);
  });
  it.each([[7, "another branch of the same company"], [8, "another company"], [404, "unknown"]])(
    "refuses the hold on invoice %s (%s)", async (id) => {
      const { status } = await call("POST", `/invoices/${id}/hold-override`, { override: "Y", reason: "ok" });
      expect(status).toBe(404);
      expect(ran("sp_nt_SetInvoiceHoldOverride")).toBe(false);
    });
});
