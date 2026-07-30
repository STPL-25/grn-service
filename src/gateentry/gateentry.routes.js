import express from "express";
import GateEntryController from "./gateentry.controller.js";
import { cacheMiddleware } from "../middleware/redisCache.js";
import { upload } from "../utils/ftpUpload.js";

const GateEntryRouter = express.Router();

// Approved POs (pending receipt) — the list a security gate registers arrivals against
GateEntryRouter.get("/getApprovedPOs", GateEntryController.getApprovedPOs);

// Gate entry register
// GateEntryRouter.get("/getAllGateEntries",                    GateEntryController.getAllGateEntries);
GateEntryRouter.get("/getGateEntriesByPO/:po_basic_sno",     GateEntryController.getGateEntriesByPO);
// QR scan-to-fill: dispatch delivery by LR no (or DSD-<delivery_sno> for Direct slips)
GateEntryRouter.get("/dispatchByLr/:lr_code",                GateEntryController.getDispatchByLr);
// Sidebar "Pending Inward" — dispatched POs not yet GRN-complete
GateEntryRouter.get("/pendingInward",                        GateEntryController.getPendingInward);
// upload.any() parses multipart/form-data (photo + text fields) into req.files/req.body;
// it's a no-op for a plain JSON request (no photo), which still hits express.json() upstream.
GateEntryRouter.post("/createGateEntry",                     upload.any(), GateEntryController.createGateEntry);
GateEntryRouter.put("/updateGateEntryStatus/:gate_entry_sno", GateEntryController.updateGateEntryStatus);

export default GateEntryRouter;
