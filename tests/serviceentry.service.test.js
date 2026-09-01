// serviceentry.service.js — routing tests for Service Entry / Delivered
// confirmation, including the variance-exceeded escalation path
// (sp_nt_CreateServiceEntry, grn-service/sql/12_service_entry.sql). The
// variance % computation and the "exceeds tolerance -> route to
// entity_type='ServiceEntry' workflow, else auto-approve" branch live in
// SQL — covered by the integration test.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import ServiceEntryService from "../src/serviceentry/serviceentry.service.js";

describe("ServiceEntryService — variance-based escalation routing", () => {
  beforeEach(() => {
    jest.restoreAllMocks();
  });

  it("createServiceEntry forwards a within-tolerance confirmation and reports auto-approval", async () => {
    const payload = {
      po_basic_sno: 1, vendor_sno: 1, period_from: "2026-08-01", period_to: "2026-08-31",
      confirmed_amount: 51000, created_by: "KTM1148",
      items: [{ po_item_sno: 1, service_sno: 10, billed_qty: 1, confirmed_amount: 51000 }],
    };
    const spy = jest
      .spyOn(ServiceEntryService.repo, "createServiceEntry")
      .mockResolvedValue([{ service_entry_sno: 1, variance_status: "WITHIN_TOLERANCE", status: "Approved" }]);

    const result = await ServiceEntryService.createServiceEntry(payload);

    expect(spy).toHaveBeenCalledWith(payload);
    expect(result[0].status).toBe("Approved");
  });

  it("createServiceEntry forwards an over-ceiling confirmation and reports the escalated (Pending) state", async () => {
    const payload = {
      po_basic_sno: 2, vendor_sno: 1, period_from: "2026-08-01", period_to: "2026-08-31",
      confirmed_amount: 90000, created_by: "KTM1148",
      items: [{ po_item_sno: 2, service_sno: 10, billed_qty: 1, confirmed_amount: 90000 }],
    };
    const spy = jest
      .spyOn(ServiceEntryService.repo, "createServiceEntry")
      .mockResolvedValue([{ service_entry_sno: 2, variance_status: "EXCEEDED", status: "Pending" }]);

    const result = await ServiceEntryService.createServiceEntry(payload);

    expect(spy).toHaveBeenCalledWith(payload);
    // Escalated entries stay Pending — they need explicit approval through
    // the entity_type='ServiceEntry' workflow rather than auto-approving.
    expect(result[0].status).toBe("Pending");
    expect(result[0].variance_status).toBe("EXCEEDED");
  });
});
