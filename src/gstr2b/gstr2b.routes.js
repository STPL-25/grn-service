import crypto from "node:crypto";
import express from "express";
import multer from "multer";
import Gstr2bRepository from "./gstr2b.repository.js";
import { parseGstr2bWorkbook } from "./gstr2b.parser.js";
import { releaseUnpaidGst } from "../paymentnet/paymentnet.routes.js";
import { attachHierarchyScope } from "../middleware/hierarchyScope.js";

const repo = new Gstr2bRepository();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 20 * 1024 * 1024 } });
const Gstr2bRouter = express.Router();

const userOf = (req) => (Array.isArray(req.user) ? req.user[0] : req.user);
const wrap = (fn, status = 400) => async (req, res) => {
  try {
    res.json({ success: true, data: await fn(req) });
  } catch (error) {
    res.status(error.status ?? status).json({ success: false, error: error.message });
  }
};
const httpError = (status, message) => Object.assign(new Error(message), { status });
const positiveInt = (v) => { const n = Number(v); return Number.isInteger(n) && n > 0 ? n : null; };

// Company scope (sql/90). req.hierarchyJson = the caller's { com_sno, div_sno, brn_sno } rows, [] when none (sees nothing).
// A 2B file is company-wide (one GSTIN), so any row for its company grants it; a books invoice also needs its division / branch.
const hasCompany = (hier, com) => com != null && (hier ?? []).some((h) => Number(h.com_sno) === Number(com));
const coversInvoice = (hier, s) => (hier ?? []).some((h) => Number(h.com_sno) === Number(s.com_sno)
  && (h.div_sno == null || Number(h.div_sno) === Number(s.div_sno))
  && (h.brn_sno == null || Number(h.brn_sno) === Number(s.brn_sno)));
// Refuse a 2B row / books invoice of a company the caller cannot see (404, so other companies' records stay invisible).
async function assertAccess(req, ref) {
  const [scope] = await repo.scopeOf(ref);
  const ok = scope && (ref.invoice_sno ? coversInvoice(req.hierarchyJson, scope) : hasCompany(req.hierarchyJson, scope.com_sno));
  if (!ok) throw httpError(404, ref.invoice_sno ? "Invoice not found." : "GSTR-2B row not found.");
}

// POST multipart: file (xlsx), return_period (MMYYYY), com_sno (required, one of the caller's companies)
Gstr2bRouter.post("/upload", attachHierarchyScope, upload.single("file"), wrap(async (req) => {
  const com_sno = positiveInt(req.body.com_sno);
  if (!com_sno) throw new Error("Choose the company this GSTR-2B belongs to.");
  if (!hasCompany(req.hierarchyJson, com_sno)) throw httpError(403, "You do not have access to this company.");
  if (!req.file) throw new Error("Choose the GSTR-2B Excel file.");
  const period = String(req.body.return_period ?? "").trim();
  if (!/^(0[1-9]|1[0-2])\d{4}$/.test(period)) throw new Error("Return period must be MMYYYY, e.g. 102026.");
  const { rows, sheets } = await parseGstr2bWorkbook(req.file.buffer);
  if (rows.length === 0) throw new Error("The file has no invoice rows.");
  const file_hash = crypto.createHash("sha256").update(req.file.buffer).digest("hex");
  const [summary] = await repo.import({
    com_sno,
    return_period: period,
    file_name: req.file.originalname,
    file_hash,
    uploaded_by: userOf(req)?.ecno,
    rows,
  });
  // GST that was left unpaid because an invoice was not in 2B yet moves to Payment Run now that 2B may have it (sql/75)
  const released_gst = await releaseUnpaidGst({ by: userOf(req)?.ecno });
  return { summary, sheets, released_gst };
}));

// ?com_sno= one company's files; only companies in the caller's hierarchy are ever returned
Gstr2bRouter.get("/uploads", attachHierarchyScope, wrap((req) =>
  repo.listUploads({ com_sno: positiveInt(req.query.com_sno) ?? undefined, hierarchy: req.hierarchyJson }), 500));
Gstr2bRouter.get("/uploads/:id", attachHierarchyScope, wrap(async (req) => {
  const upload_sno = positiveInt(req.params.id);
  const [summary] = upload_sno ? await repo.summary(upload_sno) : [];
  if (!summary || !hasCompany(req.hierarchyJson, summary.com_sno)) throw httpError(404, "GSTR-2B upload not found.");
  const rows = await repo.rows({ upload_sno, match_status: req.query.status || undefined });
  return { summary, rows };
}));
Gstr2bRouter.get("/rows/:rowSno/candidates", attachHierarchyScope, wrap(async (req) => {
  await assertAccess(req, { row_sno: Number(req.params.rowSno) });
  return repo.candidates(Number(req.params.rowSno));
}));
Gstr2bRouter.post("/rows/:rowSno/confirm", attachHierarchyScope, wrap(async (req) => {
  await assertAccess(req, { row_sno: Number(req.params.rowSno) });
  const [r] = await repo.confirmSupplier({
    row_sno: Number(req.params.rowSno), vendor_sno: Number(req.body.vendor_sno), confirmed_by: userOf(req)?.ecno,
  });
  const released_gst = await releaseUnpaidGst({ by: userOf(req)?.ecno });
  return released_gst.length ? { ...r, released_gst } : r;
}));
// fix a typo in a 2B row that did not match and re-run the match for it
Gstr2bRouter.put("/rows/:rowSno", attachHierarchyScope, wrap(async (req) => {
  await assertAccess(req, { row_sno: Number(req.params.rowSno) });
  const [r] = await repo.editRow({ ...req.body, row_sno: Number(req.params.rowSno), by: userOf(req)?.ecno });
  const released_gst = await releaseUnpaidGst({ by: userOf(req)?.ecno });
  return released_gst.length ? { ...r, released_gst } : r;
}));
Gstr2bRouter.post("/rows/:rowSno/skip", attachHierarchyScope, wrap(async (req) => {
  await assertAccess(req, { row_sno: Number(req.params.rowSno) });
  const [r] = await repo.skipRow({ row_sno: Number(req.params.rowSno), skipped_by: userOf(req)?.ecno });
  return r;
}));
// ?com_sno= one company's invoices; always limited to the caller's companies / divisions / branches
Gstr2bRouter.get("/missing", attachHierarchyScope, wrap((req) =>
  repo.missingIn2B({ com_sno: positiveInt(req.query.com_sno) ?? undefined, hierarchy: req.hierarchyJson }), 500));
Gstr2bRouter.post("/invoices/:id/hold-override", attachHierarchyScope, wrap(async (req) => {
  await assertAccess(req, { invoice_sno: Number(req.params.id) });
  const [r] = await repo.setHoldOverride({
    invoice_sno: Number(req.params.id), override: req.body.override, reason: req.body.reason, by: userOf(req)?.ecno,
  });
  const released_gst = await releaseUnpaidGst({ by: userOf(req)?.ecno });
  return released_gst.length ? { ...r, released_gst } : r;
}));

export default Gstr2bRouter;
