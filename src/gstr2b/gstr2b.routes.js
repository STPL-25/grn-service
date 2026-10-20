import crypto from "node:crypto";
import express from "express";
import multer from "multer";
import Gstr2bRepository from "./gstr2b.repository.js";
import { parseGstr2bWorkbook } from "./gstr2b.parser.js";

const repo = new Gstr2bRepository();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 20 * 1024 * 1024 } });
const Gstr2bRouter = express.Router();

const userOf = (req) => (Array.isArray(req.user) ? req.user[0] : req.user);
const wrap = (fn, status = 400) => async (req, res) => {
  try {
    res.json({ success: true, data: await fn(req) });
  } catch (error) {
    res.status(status).json({ success: false, error: error.message });
  }
};

// POST multipart: file (xlsx), return_period (MMYYYY), com_sno?
Gstr2bRouter.post("/upload", upload.single("file"), wrap(async (req) => {
  if (!req.file) throw new Error("Choose the GSTR-2B Excel file.");
  const period = String(req.body.return_period ?? "").trim();
  if (!/^(0[1-9]|1[0-2])\d{4}$/.test(period)) throw new Error("Return period must be MMYYYY, e.g. 102026.");
  const { rows, sheets } = await parseGstr2bWorkbook(req.file.buffer);
  if (rows.length === 0) throw new Error("The file has no invoice rows.");
  const file_hash = crypto.createHash("sha256").update(req.file.buffer).digest("hex");
  const [summary] = await repo.import({
    com_sno: req.body.com_sno ? Number(req.body.com_sno) : null,
    return_period: period,
    file_name: req.file.originalname,
    file_hash,
    uploaded_by: userOf(req)?.ecno,
    rows,
  });
  return { summary, sheets };
}));

Gstr2bRouter.get("/uploads", wrap(() => repo.listUploads(), 500));
Gstr2bRouter.get("/uploads/:id", wrap(async (req) => {
  const upload_sno = Number(req.params.id);
  const [summary] = await repo.summary(upload_sno);
  const rows = await repo.rows({ upload_sno, match_status: req.query.status || undefined });
  return { summary, rows };
}));
Gstr2bRouter.get("/rows/:rowSno/candidates", wrap((req) => repo.candidates(Number(req.params.rowSno))));
Gstr2bRouter.post("/rows/:rowSno/confirm", wrap(async (req) => {
  const [r] = await repo.confirmSupplier({
    row_sno: Number(req.params.rowSno), vendor_sno: Number(req.body.vendor_sno), confirmed_by: userOf(req)?.ecno,
  });
  return r;
}));
Gstr2bRouter.post("/rows/:rowSno/skip", wrap(async (req) => {
  const [r] = await repo.skipRow({ row_sno: Number(req.params.rowSno), skipped_by: userOf(req)?.ecno });
  return r;
}));
Gstr2bRouter.get("/missing", wrap(() => repo.missingIn2B(), 500));
Gstr2bRouter.post("/invoices/:id/hold-override", wrap(async (req) => {
  const [r] = await repo.setHoldOverride({
    invoice_sno: Number(req.params.id), override: req.body.override, reason: req.body.reason, by: userOf(req)?.ecno,
  });
  return r;
}));

export default Gstr2bRouter;
