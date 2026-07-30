import StockRequestService from "./stockrequest.service.js";
import { invalidateCache } from "../middleware/redisCache.js";
import { broadcast } from "../utils/socketBroadcast.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class StockRequestController {
  static async getRequests(req, res) {
    try {
      const data = await StockRequestService.getRequests(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getRequestItems(req, res) {
    try {
      const { request_sno } = req.params;
      const data = await StockRequestService.getRequestItems(Number(request_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createRequest(req, res) {
    try {
      const user = getAuthUser(req);
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Request data is required" });

      const data = await StockRequestService.createRequest({
        ...req.body,
        requested_by: user?.ecno,
        requested_name: req.body.requested_name ?? user?.name,
      });
      broadcast(req.redisClient, "inventory:live", "stockrequest:updated", {
        request: data?.[0],
        action: "created",
      });
      res.json({ success: true, data, message: "Stock request submitted" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async issueRequest(req, res) {
    try {
      const user = getAuthUser(req);
      if (!req.body || Object.keys(req.body).length === 0)
        return res.status(400).json({ success: false, error: "Issue data is required" });

      const data = await StockRequestService.issueRequest({
        ...req.body,
        issued_by: user?.ecno,
      });

      // Issuing reduces stock — drop the cached item list and each touched
      // item's movement cache, then push the movements to the inventory room
      // so open Inventory pages update live.
      const movementKeys = (data.movements ?? []).map((m) => `inv:movements:${m.item_sno}`);
      await invalidateCache(req.redisClient, "inv:items", ...movementKeys);
      for (const movement of data.movements ?? []) {
        broadcast(req.redisClient, "inventory:live", "inventory:updated", {
          movement,
          action: "adjusted",
        });
      }
      broadcast(req.redisClient, "inventory:live", "stockrequest:updated", {
        request: data.header,
        action: "issued",
      });

      res.json({ success: true, data, message: "Stock issued" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async rejectRequest(req, res) {
    try {
      const user = getAuthUser(req);
      const { request_sno } = req.params;
      const data = await StockRequestService.rejectRequest(
        Number(request_sno),
        req.body?.reason,
        user?.ecno
      );
      broadcast(req.redisClient, "inventory:live", "stockrequest:updated", {
        request: data?.[0],
        action: "rejected",
      });
      res.json({ success: true, data, message: "Stock request rejected" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async cancelRequest(req, res) {
    try {
      const user = getAuthUser(req);
      const { request_sno } = req.params;
      const data = await StockRequestService.cancelRequest(
        Number(request_sno),
        req.body?.reason,
        user?.ecno
      );
      broadcast(req.redisClient, "inventory:live", "stockrequest:updated", {
        request: data?.[0],
        action: "cancelled",
      });
      res.json({ success: true, data, message: "Stock request cancelled" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default StockRequestController;
