import InvoiceRepository from "./invoice.repository.js";

class InvoiceService {
  static repo = new InvoiceRepository();

  static async createInvoice(payload) {
    return this.repo.createInvoice(payload);
  }

  static async linkInvoiceToPO(payload) {
    return this.repo.linkInvoiceToPO(payload);
  }

  static async allocateInvoice(payload) {
    return this.repo.allocateInvoice(payload);
  }

  static async matchInvoiceBucket(payload) {
    return this.repo.matchInvoiceBucket(payload);
  }

  static async getInvoicesByPO(po_basic_sno) {
    return this.repo.getInvoicesByPO(po_basic_sno);
  }

  static async getPoItemsForAllocation(po_basic_sno) {
    return this.repo.getPoItemsForAllocation(po_basic_sno);
  }

  static async verifyInvoiceDelivery(payload) {
    return this.repo.verifyInvoiceDelivery(payload);
  }

  static async getAllInvoices(filters) {
    return this.repo.getAllInvoices(filters);
  }

  static async getPendingInvoiceMatches() {
    return this.repo.getPendingInvoiceMatches();
  }
}

export default InvoiceService;
