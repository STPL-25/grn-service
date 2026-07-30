import StockRequestRepository from "./stockrequest.repository.js";

class StockRequestService {
  static repo = new StockRequestRepository();

  static async getRequests(filters) {
    return this.repo.getRequests(filters);
  }

  static async getRequestItems(request_sno) {
    if (!request_sno) throw new Error("request_sno is required");
    return this.repo.getRequestItems(request_sno);
  }

  static async createRequest(requestData) {
    const { requested_by, items } = requestData;
    if (!requested_by) throw new Error("requested_by is required");
    if (!Array.isArray(items) || items.length === 0) {
      throw new Error("At least one item is required");
    }
    for (const line of items) {
      if (!line.item_sno) throw new Error("Every item needs an item_sno");
      if (line.quantity == null || Number(line.quantity) <= 0) {
        throw new Error("Every item needs a quantity greater than zero");
      }
    }
    return this.repo.createRequest(requestData);
  }

  static async issueRequest(issueData) {
    const { request_sno, issued_by, items } = issueData;
    if (!request_sno) throw new Error("request_sno is required");
    if (!issued_by) throw new Error("issued_by is required");
    const toIssue = (Array.isArray(items) ? items : []).filter(
      (l) => l.sr_item_sno && Number(l.issue_qty) > 0
    );
    if (toIssue.length === 0) throw new Error("No issue quantities supplied");

    const [header, movements] = await this.repo.issueRequest({
      request_sno,
      issued_by,
      items: toIssue,
    });
    return { header: header?.[0], movements: movements ?? [] };
  }

  static async rejectRequest(request_sno, reason, updated_by) {
    if (!request_sno) throw new Error("request_sno is required");
    return this.repo.updateStatus({ request_sno, status: "Rejected", reason, updated_by });
  }

  static async cancelRequest(request_sno, reason, updated_by) {
    if (!request_sno) throw new Error("request_sno is required");
    return this.repo.updateStatus({ request_sno, status: "Cancelled", reason, updated_by });
  }
}

export default StockRequestService;
