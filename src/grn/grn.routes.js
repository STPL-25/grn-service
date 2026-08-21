import express from "express";
import GRNController from "./grn.controller.js";
import { cacheMiddleware } from "../middleware/redisCache.js";

const GRNRouter = express.Router();

// DB operations
// GRNRouter.get("/grnhealth123",  GRNController.getGRN);
GRNRouter.get("/getPendingPOs",             GRNController.getPendingPOs);
GRNRouter.get("/getPendingGateEntries",     GRNController.getPendingGateEntries);
GRNRouter.get("/getGRNsByPO/:po_basic_sno",  GRNController.getGRNsByPO);
GRNRouter.post("/createGRN",                GRNController.createGRN);
GRNRouter.get("/getAllGRNs",               GRNController.getAllGRNs);
GRNRouter.get("/getWarehouseLocations",     GRNController.getWarehouseLocationsForGRN);

// Draft operations (Redis-backed, per-user)
// GRNRouter.post("/saveGRNDraft",              GRNController.saveGRNDraft);
// GRNRouter.get("/getGRNDrafts",               GRNController.getGRNDrafts);
// GRNRouter.get("/getGRNDraft/:draftId",       GRNController.getGRNDraft);
// GRNRouter.put("/updateGRNDraft/:draftId",    GRNController.updateGRNDraft);
// GRNRouter.delete("/deleteGRNDraft/:draftId", GRNController.deleteGRNDraft);
// GRNRouter.post("/submitGRNDraft/:draftId",   GRNController.submitGRNDraft);

export default GRNRouter;
