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

  static async getVendorDrivenBillableChildPOs(vendor_sno) {
    return this.repo.getVendorDrivenBillableChildPOs(vendor_sno);
  }

  // Consolidates several Vendor-Driven child POs (spanning multiple delivery
  // days) into one bill each, in one user action — one real invoice per PO
  // (invoice_info.po_basic_sno is a single FK, so "one bill" per PO is the
  // real unit), created+allocated+matched immediately so it shows up in
  // Payable Bills right away with the correct received-qty-based release
  // amount. Re-fetches the billable rows server-side (by vendor_sno) rather
  // than trusting client-supplied amounts, then filters to the requested
  // po_basic_snos — same reasoning as every other "never trust the client
  // for money" precedent in this codebase. One PO's failure doesn't abort
  // the rest — each result is reported independently.
  static async consolidateVendorDrivenBills({ vendor_sno, po_basic_snos, created_by }) {
    if (!vendor_sno) throw new Error("vendor_sno is required");
    if (!Array.isArray(po_basic_snos) || po_basic_snos.length === 0) {
      throw new Error("At least one po_basic_sno is required");
    }
    if (!created_by) throw new Error("created_by is required");

    const billable = await this.repo.getVendorDrivenBillableChildPOs(vendor_sno);
    const wanted = new Set(po_basic_snos.map(Number));
    const targets = billable.filter((po) => wanted.has(po.po_basic_sno));

    const results = [];
    for (const po of targets) {
      try {
        const items = JSON.parse(po.items || "[]");
        if (items.length === 0) {
          results.push({ po_basic_sno: po.po_basic_sno, result: "ERROR", error: "No billable items on this PO" });
          continue;
        }
        const invoice_amount = items.reduce((sum, it) => sum + (Number(it.line_value) || 0), 0);
        const invoice_date = po.vendor_invoice_date ? String(po.vendor_invoice_date).slice(0, 10) : new Date().toISOString().slice(0, 10);
        const dueDate = new Date(invoice_date);
        dueDate.setDate(dueDate.getDate() + (Number(po.payment_cycle_days) || 15));

        const invResult = await this.repo.createInvoice({
          vendor_invoice_no: po.vendor_invoice_no,
          vendor_sno: po.vendor_sno,
          po_basic_sno: po.po_basic_sno,
          com_sno: po.com_sno,
          div_sno: po.div_sno,
          brn_sno: po.brn_sno,
          dept_sno: po.dept_sno,
          invoice_date,
          due_date: dueDate.toISOString().slice(0, 10),
          invoice_amount,
          invoice_type: "MATERIAL",
          source_type: "STANDARD",
          remarks: `Vendor-driven consolidated bill for ${po.po_df_no}`,
          created_by,
        });
        const invoice_sno = invResult[0]?.invoice_sno;

        await this.repo.allocateInvoice({
          invoice_sno,
          allocations: items.map((it) => ({ po_item_sno: it.po_item_sno, allocated_amount: Number(it.line_value) })),
          created_by,
        });

        await this.repo.matchInvoiceBucket({ invoice_sno });

        results.push({ po_basic_sno: po.po_basic_sno, po_no: po.po_df_no, invoice_sno, invoice_no: invResult[0]?.invoice_no, invoice_amount, result: "SUCCESS" });
      } catch (error) {
        results.push({ po_basic_sno: po.po_basic_sno, po_no: po.po_df_no, result: "ERROR", error: error.message });
      }
    }

    const requestedNotFound = po_basic_snos
      .map(Number)
      .filter((sno) => !targets.some((t) => t.po_basic_sno === sno));
    for (const sno of requestedNotFound) {
      results.push({ po_basic_sno: sno, result: "ERROR", error: "Not currently billable (already invoiced, no GRN yet, or not found for this vendor)" });
    }

    return results;
  }
}

export default InvoiceService;
