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
SupplierRouter.get("/debit-notes/:debit_note_sno", verifySupplierAuth, SupplierController.getDebitNoteDetail);

export default SupplierRouter;
