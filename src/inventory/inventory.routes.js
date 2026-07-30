import express from "express";
import InventoryController from "./inventory.controller.js";
import { cacheMiddleware } from "../middleware/redisCache.js";

const InventoryRouter = express.Router();

// Item master (paths match the monolith's frontend Api.tsx inventory endpoints
// so a gateway can proxy /api/inventory/* here transparently)
InventoryRouter.get("/getItems",               InventoryController.getItems);
InventoryRouter.post("/createItem",           InventoryController.createItem);
InventoryRouter.put("/updateItem/:item_sno",  InventoryController.updateItem);
InventoryRouter.delete("/deleteItem/:item_sno", InventoryController.deleteItem);

// Stock movements
InventoryRouter.get("/getMovements/:item_sno",  InventoryController.getMovements);
InventoryRouter.get("/getStockSummary",         InventoryController.getStockSummary);
InventoryRouter.post("/adjustStock",           InventoryController.adjustStock);

export default InventoryRouter;
