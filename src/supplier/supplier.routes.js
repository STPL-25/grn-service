import express from "express";
import SupplierController from "./supplier.controller.js";
import verifyStaffJWT from "../middleware/auth.js";
import { verifySupplierAuth } from "../middleware/supplierAuth.js";
import { upload } from "../utils/ftpUpload.js";

const SupplierRouter = express.Router();

// Staff-only — triggers/resets a supplier's portal invite (called from KYCDataView)
SupplierRouter.post("/invite", verifyStaffJWT, SupplierController.invite);

// Public — supplier login
SupplierRouter.post("/login", SupplierController.login);

// Supplier-authenticated
SupplierRouter.post("/reset-password", verifySupplierAuth, SupplierController.resetPassword);
SupplierRouter.get("/pos", verifySupplierAuth, SupplierController.getPOs);
SupplierRouter.get("/pos/:po_basic_sno", verifySupplierAuth, SupplierController.getPODetail);
SupplierRouter.post("/pos/:po_basic_sno/accept", verifySupplierAuth, SupplierController.acceptPO);
// Active transporters from the transporter master — populates the dispatch form's dropdown
SupplierRouter.get("/transporters", verifySupplierAuth, SupplierController.getTransporters);
// upload.any() parses multipart/form-data (per-delivery invoice copies + a JSON
// `deliveries` field); it's a no-op for a plain JSON request (no files).
SupplierRouter.post("/pos/:po_basic_sno/dispatch", verifySupplierAuth, upload.any(), SupplierController.createDispatch);
SupplierRouter.get("/dispatch/:dispatch_slip_sno", verifySupplierAuth, SupplierController.getDispatchSlip);
SupplierRouter.get("/dispatch/delivery/:delivery_sno", verifySupplierAuth, SupplierController.getDispatchDelivery);
SupplierRouter.get("/debit-notes", verifySupplierAuth, SupplierController.getDebitNotes);
// The supplier's own payments (advance + bill payments, scheduled / paid) and the advances held for them (sql/69)
SupplierRouter.get("/payments", verifySupplierAuth, SupplierController.getPayments);
SupplierRouter.get("/debit-notes/:debit_note_sno", verifySupplierAuth, SupplierController.getDebitNoteDetail);
// Request For Quotation (sql/86): the RFQs sent to this supplier, the Quotation Entry screen and its submissions.
// Submit takes multipart/form-data (`payload` JSON + optional `quotation_file`); each submit is stored as a new version.
SupplierRouter.get("/rfqs", verifySupplierAuth, SupplierController.getRfqs);
SupplierRouter.get("/rfqs/:rfq_supplier_sno", verifySupplierAuth, SupplierController.getRfqDetail);
SupplierRouter.post("/rfqs/:rfq_supplier_sno/respond", verifySupplierAuth, upload.any(), SupplierController.submitRfqResponse);
SupplierRouter.post("/rfqs/:rfq_supplier_sno/decline", verifySupplierAuth, SupplierController.declineRfq);
// Credit notes (sql/71) - shown next to the debit notes on the portal
SupplierRouter.get("/credit-notes", verifySupplierAuth, SupplierController.getCreditNotes);
SupplierRouter.get("/credit-notes/:credit_note_sno", verifySupplierAuth, SupplierController.getCreditNoteDetail);

// Ledger uploads against a debit / credit note, or against an invoice (covers every note on it) - sql/87.
// A too-big / unreadable upload becomes a JSON error instead of express's default HTML 500.
const ledgerUpload = (req, res, next) =>
  upload.single("ledger_file")(req, res, (err) => {
    if (!err) return next();
    const error = err.code === "LIMIT_FILE_SIZE" ? "The ledger file must be under 10 MB." : err.message;
    res.status(400).json({ success: false, error });
  });
SupplierRouter.get("/note-ledgers", verifySupplierAuth, SupplierController.getNoteLedgers);
SupplierRouter.post("/note-ledgers", verifySupplierAuth, ledgerUpload, SupplierController.uploadNoteLedger);
SupplierRouter.delete("/note-ledgers/:ledger_sno", verifySupplierAuth, SupplierController.removeNoteLedger);

// My KYC (sql/92): the supplier's own KYC, and a change to it. A change is multipart/form-data: `payload` JSON +
// `authorization_file` (the signed authorization letter, required) + optional `doc_<document type>` files.
// A too-big / unreadable upload becomes a JSON error instead of express's default HTML 500.
const kycUpload = (req, res, next) =>
  upload.any()(req, res, (err) => {
    if (!err) return next();
    const error = err.code === "LIMIT_FILE_SIZE" ? "Each file must be under 10 MB." : err.message;
    res.status(400).json({ success: false, error });
  });
SupplierRouter.get("/kyc", verifySupplierAuth, SupplierController.getKyc);
SupplierRouter.post("/kyc/modify", verifySupplierAuth, kycUpload, SupplierController.modifyKyc);
// Takes back a request that is still waiting for approval (JSON body: { kyc_modified_sno })
SupplierRouter.post("/kyc/withdraw", verifySupplierAuth, SupplierController.withdrawKyc);

export default SupplierRouter;
