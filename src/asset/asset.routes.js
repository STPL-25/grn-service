import express from "express";
import AssetController from "./asset.controller.js";
import { attachHierarchyScope } from "../middleware/hierarchyScope.js";

const AssetRouter = express.Router();

AssetRouter.get("/me",                   AssetController.getMe);
AssetRouter.get("/register",             attachHierarchyScope, AssetController.getRegister);
AssetRouter.get("/suppliers",            AssetController.getSuppliers);
AssetRouter.get("/requests",             attachHierarchyScope, AssetController.getRequests);
AssetRouter.get("/requests/:id",         AssetController.getRequestDetail);
AssetRouter.post("/requests",            AssetController.createRequest);
AssetRouter.post("/requests/:id/action", AssetController.act);

export default AssetRouter;
