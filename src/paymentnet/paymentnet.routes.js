import express from "express";
import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

// Payment page backend: payable bills with GRN / 2B / TDS context, the adjustments available for a supplier
// (advances, debit/credit notes, TDS sections), and release-with-adjustments (sql/44, sql/48).
// sp_nt_ReleasePaymentNet with preview=true returns the figures without saving.
const PaymentNetRouter = express.Router();

const userOf = (req) => (Array.isArray(req.user) ? req.user[0] : req.user);

async function exec(proc, params, allRecordsets = false) {
  try {
    const pool = await initializeDatabase();
    const request = pool.request();
    if (params !== undefined) request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(params));
    const result = await request.execute(proc);
    return allRecordsets ? result.recordsets : result.recordset;
  } catch (error) {
    throw new Error(error.message); // SP THROW text is user-facing validation
  }
}
const wrap = (fn, status = 400) => async (req, res) => {
  try {
    res.json({ success: true, data: await fn(req) });
  } catch (error) {
    res.status(status).json({ success: false, error: error.message });
  }
};

PaymentNetRouter.get("/bills", wrap((req) => exec("sp_nt_GetPayableBillsNet", { vendor_sno: req.query.vendor_sno ? Number(req.query.vendor_sno) : undefined }), 500));

// Goods received (GRN approved) but no supplier invoice yet - listed on the Payment page as "pending payment" (sql/53).
PaymentNetRouter.get("/grn-pending", wrap((req) => exec("sp_nt_GetGrnPendingPayments", { vendor_sno: req.query.vendor_sno ? Number(req.query.vendor_sno) : undefined, include_billed: req.query.include_billed === "1" }), 500));

// Invoice-wise ledger per PO: every invoice (paid / part paid / unpaid / not allocated, with duplicate flag) and the invoice data each GRN captured (sql/63).
PaymentNetRouter.get("/invoice-ledger", wrap(async (req) => {
  const [invoices = [], grns = []] = await exec("sp_nt_GetPoInvoiceLedger", { vendor_sno: req.query.vendor_sno ? Number(req.query.vendor_sno) : undefined }, true);
  return { invoices, grns };
}, 500));

PaymentNetRouter.get("/adjustments", wrap(async (req) => {
  const [advances = [], debitNotes = [], creditNotes = []] =
    await exec("sp_nt_GetPaymentAdjustments", { vendor_sno: Number(req.query.vendor_sno) }, true);
  const tdsSections = await exec("sp_nt_GetTdsSections", {});   // carries applies_to (Service / Product / Both), sql/62
  return { advances, debitNotes, creditNotes, tdsSections };
}));

// TDS Section master (Masters screen): list every section, add / edit one (sql/60)
PaymentNetRouter.get("/tds-sections", wrap(() => exec("sp_nt_GetTdsSections", {}), 500));
PaymentNetRouter.post("/tds-sections", wrap(async (req) => {
  const [row] = await exec("sp_nt_UpsertTdsSection", { ...req.body, modified_by: userOf(req)?.ecno });
  return row;
}));

const releaseBody = (req, preview) => ({ ...req.body, created_by: userOf(req)?.ecno, preview });

PaymentNetRouter.post("/preview", wrap(async (req) => {
  const [summary = [], invoices = []] = await exec("sp_nt_ReleasePaymentNet", releaseBody(req, true), true);
  return { summary: summary[0] ?? null, invoices };
}));

PaymentNetRouter.post("/release", wrap(async (req) => {
  const [row] = await exec("sp_nt_ReleasePaymentNet", releaseBody(req, false));
  return row;
}));

export default PaymentNetRouter;
