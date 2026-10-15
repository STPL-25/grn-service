import express from "express";
import GRNController from "./grn.controller.js";
import { cacheMiddleware } from "../middleware/redisCache.js";
import { attachHierarchyScope } from "../middleware/hierarchyScope.js";

const GRNRouter = express.Router();

// DB operations
// GRNRouter.get("/grnhealth123",  GRNController.getGRN);
GRNRouter.get("/getPendingPOs",             GRNController.getPendingPOs);
GRNRouter.get("/getPendingGateEntries",     GRNController.getPendingGateEntries);
GRNRouter.get("/getGRNsByPO/:po_basic_sno", attachHierarchyScope, GRNController.getGRNsByPO);
GRNRouter.post("/createGRN",                GRNController.createGRN);
GRNRouter.get("/getUoms",                  GRNController.getUomList);
GRNRouter.get("/excessRequests",           GRNController.getExcessRequests);
GRNRouter.post("/decideExcess",            GRNController.decideExcess);
GRNRouter.get("/grnApprovals",            GRNController.getGRNApprovals);
GRNRouter.post("/decideGRN",               GRNController.decideGRN);
GRNRouter.get("/creditNotesByGRN/:grn_basic_sno", GRNController.getCreditNotesByGRN);
GRNRouter.get("/getAllGRNs",               attachHierarchyScope, GRNController.getAllGRNs);
GRNRouter.get("/getWarehouseLocations",     GRNController.getWarehouseLocationsForGRN);
GRNRouter.get("/getUnsyncedInventoryItems", GRNController.getUnsyncedInventoryItems);
GRNRouter.post("/resyncInventoryItem",      GRNController.resyncInventoryItem);

// Draft operations (Redis-backed, per-user)
// GRNRouter.post("/saveGRNDraft",              GRNController.saveGRNDraft);
// GRNRouter.get("/getGRNDrafts",               GRNController.getGRNDrafts);
// GRNRouter.get("/getGRNDraft/:draftId",       GRNController.getGRNDraft);
// GRNRouter.put("/updateGRNDraft/:draftId",    GRNController.updateGRNDraft);
// GRNRouter.delete("/deleteGRNDraft/:draftId", GRNController.deleteGRNDraft);
// GRNRouter.post("/submitGRNDraft/:draftId",   GRNController.submitGRNDraft);

export default GRNRouter;
