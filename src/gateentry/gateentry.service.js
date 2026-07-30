import GateEntryRepository from "./gateentry.repository.js";

const GATE_STATUSES = ["In", "Verified", "GRN Done", "Out"];

class GateEntryService {
  static repo = new GateEntryRepository();

  static async getApprovedPOs(filters) {
    return this.repo.getApprovedPOs(filters);
  }

  static async getAllGateEntries(filters) {
    return this.repo.getAllGateEntries(filters);
  }

  static async getGateEntriesByPO(po_basic_sno) {
    return this.repo.getGateEntriesByPO(po_basic_sno);
  }

  static async createGateEntry(entryData) {
    if (!entryData.received_date) {
      entryData.received_date = new Date().toISOString().slice(0, 10);
    }
    return this.repo.createGateEntry(entryData);
  }

  static async updateGateEntryStatus(gate_entry_sno, status, updated_by) {
    if (!GATE_STATUSES.includes(status)) {
      throw new Error(`Invalid status '${status}'. Allowed: ${GATE_STATUSES.join(", ")}`);
    }
    return this.repo.updateGateEntryStatus(gate_entry_sno, status, updated_by);
  }

  static async getDispatchByLr(lr_code) {
    if (!lr_code || !String(lr_code).trim()) {
      throw new Error("lr_code is required.");
    }
    return this.repo.getDispatchDeliveryByLr(String(lr_code).trim());
  }

  static async getPendingInwardPOs() {
    return this.repo.getPendingInwardPOs();
  }
}

export default GateEntryService;
