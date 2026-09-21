import express from "express";
import InventoryController from "./inventory.controller.js";
import { cacheMiddleware } from "../middleware/redisCache.js";
import { attachHierarchyScope } from "../middleware/hierarchyScope.js";

const InventoryRouter = express.Router();

// Item master (paths match the monolith's frontend Api.tsx inventory endpoints
// so a gateway can proxy /api/inventory/* here transparently)
InventoryRouter.get("/getItems",               attachHierarchyScope, InventoryController.getItems);
InventoryRouter.post("/createItem",           InventoryController.createItem);
InventoryRouter.put("/updateItem/:item_sno",  InventoryController.updateItem);
InventoryRouter.delete("/deleteItem/:item_sno", InventoryController.deleteItem);

// Stock movements
InventoryRouter.get("/getMovements/:item_sno",  InventoryController.getMovements);
InventoryRouter.get("/getBatches/:item_sno",    InventoryController.getBatches);
InventoryRouter.get("/getStockSummary",         attachHierarchyScope, InventoryController.getStockSummary);
InventoryRouter.post("/adjustStock",           InventoryController.adjustStock);

export default InventoryRouter;
