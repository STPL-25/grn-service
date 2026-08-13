import InventoryService from "./inventory.service.js";
import { invalidateCache } from "../middleware/redisCache.js";
import { broadcast } from "../utils/socketBroadcast.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class InventoryController {
  static async getItems(req, res) {
    try {
      const data = await InventoryService.getItems(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createItem(req, res) {
    try {
      const user = getAuthUser(req);
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Item data is required" });

      const data = await InventoryService.createItem({ ...req.body, created_by: user?.ecno });
      await invalidateCache(req.redisClient, "inv:items");
      broadcast("inventory:live", "inventory:updated", { item: data?.[0], action: "created" });
      res.json({ success: true, data, message: "Inventory item created" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async updateItem(req, res) {
    try {
      const user = getAuthUser(req);
      const { item_sno } = req.params;
      const data = await InventoryService.updateItem(Number(item_sno), {
        ...req.body,
        updated_by: user?.ecno,
      });
      await invalidateCache(req.redisClient, "inv:items");
      broadcast("inventory:live", "inventory:updated", { item: data?.[0], action: "updated" });
      res.json({ success: true, data, message: "Inventory item updated" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async deleteItem(req, res) {
    try {
      const user = getAuthUser(req);
      const { item_sno } = req.params;
      const data = await InventoryService.deleteItem(Number(item_sno), user?.ecno);
      await invalidateCache(req.redisClient, "inv:items");
      broadcast("inventory:live", "inventory:updated", { item: data?.[0], action: "deleted" });
      res.json({ success: true, data, message: "Inventory item discontinued" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getMovements(req, res) {
    try {
      const { item_sno } = req.params;
      const data = await InventoryService.getMovements(Number(item_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getStockSummary(req, res) {
    try {
      const data = await InventoryService.getStockSummary(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async adjustStock(req, res) {
    try {
      const user = getAuthUser(req);
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Adjustment data is required" });

      const data = await InventoryService.adjustStock({ ...req.body, created_by: user?.ecno });
      await invalidateCache(
        req.redisClient,
        "inv:items",
        `inv:movements:${req.body.item_sno}`
      );
      broadcast("inventory:live", "inventory:updated", { movement: data?.[0], action: "adjusted" });
      res.json({ success: true, data, message: "Stock adjusted" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default InventoryController;
