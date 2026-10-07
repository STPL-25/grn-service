import AssetService from "./asset.service.js";
import { broadcast } from "../utils/socketBroadcast.js";
import { createInAppNotification } from "../utils/notifyClient.js";
import { orgRoomTargets } from "../middleware/hierarchyScope.js";

function getAuthUser(req) {
  return Array.isArray(req.user) ? req.user[0] : req.user;
}

// Fire-and-forget: a notification failure must never fail the request itself.
async function notify(ecno, title, message, row) {
  if (!ecno) return;
  try {
    await createInAppNotification({
      ecno, type: "info", title, message,
      data: { asset_req_sno: row?.asset_req_sno, request_no: row?.request_no, screen: "AssetManagementPage" },
    });
  } catch { /* ignore */ }
}

const label = (r) => `${r.request_no} · ${r.item_name} × ${r.qty}`;

function afterChange(row, action, prevStatus, actor) {
  broadcast(orgRoomTargets("inventory", row), "asset:updated", { request: row, action });
  // next approver is waiting
  if (row.current_approver_ecno && row.current_approver_ecno !== actor) {
    notify(row.current_approver_ecno, "Asset request awaiting your approval", label(row), row);
  }
  // raiser hears about the outcome of an approval decision
  if (row.status === "Rejected" && row.raised_by !== actor) {
    notify(row.raised_by, "Asset request rejected", `${label(row)} — ${row.reject_reason ?? ""}`, row);
  } else if (row.status === "Approved" && prevStatus !== "Approved" && row.raised_by !== actor) {
    notify(row.raised_by, "Asset request approved", label(row), row);
  }
}

const fail = (res, error) => res.status(400).json({ success: false, error: error.message });

class AssetController {
  static async getRegister(req, res) {
    try {
      const filters = { ...req.query, hierarchy: req.hierarchyJson };
      res.json({ success: true, data: await AssetService.getRegister(filters) });
    } catch (e) { res.status(500).json({ success: false, error: e.message }); }
  }

  static async getRequests(req, res) {
    try {
      const user = getAuthUser(req);
      const filters = { ...req.query, hierarchy: req.hierarchyJson };
      // "waiting on me" is always the session's own ecno, never a client-supplied one
      delete filters.approver_ecno;
      if (filters.mine_approvals) { filters.approver_ecno = user?.ecno; }
      delete filters.mine_approvals;
      res.json({ success: true, data: await AssetService.getRequests(filters) });
    } catch (e) { res.status(500).json({ success: false, error: e.message }); }
  }

  static async getRequestDetail(req, res) {
    try {
      res.json({ success: true, data: await AssetService.getRequestDetail(Number(req.params.id)) });
    } catch (e) { fail(res, e); }
  }

  static async getSuppliers(_req, res) {
    try { res.json({ success: true, data: await AssetService.getSuppliers() }); }
    catch (e) { res.status(500).json({ success: false, error: e.message }); }
  }

  static async getMe(req, res) {
    try {
      const user = getAuthUser(req);
      res.json({
        success: true,
        data: { ecno: user?.ecno, name: user?.name, is_store_incharge: await AssetService.isStoreIncharge(user?.ecno) },
      });
    } catch (e) { res.status(500).json({ success: false, error: e.message }); }
  }

  static async createRequest(req, res) {
    try {
      const user = getAuthUser(req);
      // raised_by / role are derived server-side — never trusted from the body
      const row = await AssetService.createRequest({ ...req.body, raised_by: user?.ecno, raised_by_name: user?.name });
      afterChange(row, "created", null, user?.ecno);
      res.json({ success: true, data: row, message: `${row.request_no} raised` });
    } catch (e) { fail(res, e); }
  }

  static async act(req, res) {
    try {
      const user = getAuthUser(req);
      const before = await AssetService.getRequestDetail(Number(req.params.id)).catch(() => null);
      const row = await AssetService.act({ ...req.body, asset_req_sno: Number(req.params.id), by: user?.ecno });
      afterChange(row, String(req.body.action).toLowerCase(), before?.request?.status, user?.ecno);
      res.json({ success: true, data: row });
    } catch (e) { fail(res, e); }
  }
}

export default AssetController;
