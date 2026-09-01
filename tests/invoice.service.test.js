// invoice.service.js — routing tests for the composite invoice allocation
// flow (invoice_info/invoice_allocation_details, sql/13_invoice.sql) and the
// new Vendor-Bill-Driven verification/allocation-picker endpoints
// (sql/17_invoice_po_items_for_allocation.sql, sql/19_invoice_delivery_verification.sql).
// The actual bucket-independence and matching arithmetic live in
// sp_nt_MatchInvoiceBucket (SQL) — covered by the integration test, not here.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import InvoiceService from "../src/invoice/invoice.service.js";

describe("InvoiceService — composite invoice allocation routing", () => {
  beforeEach(() => {
    jest.restoreAllMocks();
  });

  it("allocateInvoice forwards a split across MATERIAL and SERVICE buckets untouched", async () => {
    const payload = {
      invoice_sno: 501,
      allocations: [
        { po_item_sno: 42, allocated_amount: 566400 }, // MATERIAL
        { po_item_sno: 45, allocated_amount: 88500 },   // SERVICE
      ],
      created_by: "KTM1148",
    };
    const spy = jest
      .spyOn(InvoiceService.repo, "allocateInvoice")
      .mockResolvedValue([{ invoice_alloc_sno: 1, bucket_type: "MATERIAL" }, { invoice_alloc_sno: 2, bucket_type: "SERVICE" }]);

    await InvoiceService.allocateInvoice(payload);

    expect(spy).toHaveBeenCalledWith(payload);
    expect(spy.mock.calls[0][0].allocations).toHaveLength(2);
  });

  it("matchInvoiceBucket is called with just the invoice_sno — matching runs per-bucket server-side", async () => {
    const spy = jest
      .spyOn(InvoiceService.repo, "matchInvoiceBucket")
      .mockResolvedValue([]);

    await InvoiceService.matchInvoiceBucket({ invoice_sno: 501 });

    expect(spy).toHaveBeenCalledWith({ invoice_sno: 501 });
  });

  it("getPoItemsForAllocation forwards po_basic_sno for the bucket-split picker", async () => {
    const spy = jest
      .spyOn(InvoiceService.repo, "getPoItemsForAllocation")
      .mockResolvedValue([{ po_item_sno: 45, po_section: "MATERIAL", line_value: 3600 }]);

    const result = await InvoiceService.getPoItemsForAllocation(40);

    expect(spy).toHaveBeenCalledWith(40);
    expect(result[0].po_section).toBe("MATERIAL");
  });

  it("verifyInvoiceDelivery forwards the retrospective-invoice verification payload", async () => {
    const payload = { invoice_sno: 601, verified_by: "KTM1148", remarks: "Matches delivery log" };
    const spy = jest
      .spyOn(InvoiceService.repo, "verifyInvoiceDelivery")
      .mockResolvedValue([{ invoice_sno: 601, verification_status: "Verified" }]);

    await InvoiceService.verifyInvoiceDelivery(payload);

    expect(spy).toHaveBeenCalledWith(payload);
  });
});
