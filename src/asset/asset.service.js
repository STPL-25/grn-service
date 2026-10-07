import AssetRepository from "./asset.repository.js";

const ACTIONS = new Set([
  "APPROVE", "REJECT", "CANCEL", "RAISE_RETURN_ORDER", "GATE_OUT", "GATE_IN",
  "START_SERVICE", "COMPLETE_SERVICE", "RAISE_DEBIT_NOTE", "RESERVICE",
]);

class AssetService {
  static repo = new AssetRepository();

  static getRegister(filters) { return this.repo.getRegister(filters); }
  static getRequests(filters) { return this.repo.getRequests(filters); }
  static getSuppliers() { return this.repo.getSuppliers(); }

  static async getRequestDetail(asset_req_sno) {
    if (!asset_req_sno) throw new Error("asset_req_sno is required");
    const [header, approvals, history] = await this.repo.getRequestDetail(asset_req_sno);
    if (!header?.[0]) throw new Error("Asset request not found");
    return { request: header[0], approvals: approvals ?? [], history: history ?? [] };
  }

  static async isStoreIncharge(ecno) {
    const rows = await this.repo.isStoreIncharge(ecno);
    return !!rows?.[0]?.is_store_incharge;
  }

  static async createRequest(data) {
    if (!data.raised_by) throw new Error("raised_by is required");
    const rows = await this.repo.createRequest(data);
    return rows?.[0];
  }

  static async act(data) {
    if (!ACTIONS.has(String(data.action || "").toUpperCase())) throw new Error("Unknown action");
    const rows = await this.repo.act(data);
    return rows?.[0];
  }
}

export default AssetService;
