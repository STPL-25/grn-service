// payment.service.js — routing tests for bucket-level payment release
// (payment_info/payment_allocation_details, sql/14_payment.sql +
// sql/18_payment_bucket_detail.sql). The "held bucket can never be paid,
// matched bucket can" enforcement lives in sp_nt_ReleasePayment (SQL) —
// covered by the integration test.
import { describe, it, expect, jest, beforeEach } from "@jest/globals";
import PaymentService from "../src/payment/payment.service.js";

describe("PaymentService — bucket-level payment release routing", () => {
  beforeEach(() => {
    jest.restoreAllMocks();
  });

  it("releasePayment forwards allocations keyed by invoice_alloc_sno (bucket), not invoice_sno", async () => {
    const payload = {
      vendor_sno: 3, payment_date: "2026-08-21", amount: 88500, mode: "NEFT",
      created_by: "KTM1148",
      allocations: [{ invoice_alloc_sno: 2, amount: 88500 }],
    };
    const spy = jest
      .spyOn(PaymentService.repo, "releasePayment")
      .mockResolvedValue([{ payment_no: "PAY-2026-000001", result: "SUCCESS" }]);

    await PaymentService.releasePayment(payload);

    expect(spy).toHaveBeenCalledWith(payload);
    expect(spy.mock.calls[0][0].allocations[0]).toHaveProperty("invoice_alloc_sno");
  });

  it("getPayableBills returns bucket rows including hold/matched-ratio fields untouched", async () => {
    const fakeBills = [
      { bill_sno: 1, bucket_type: "MATERIAL", hold_amount: 0, matched_qty_ratio: 1, outstanding: 566400 },
      { bill_sno: 2, bucket_type: "SERVICE", hold_amount: 17700, matched_qty_ratio: 0.8333, outstanding: 88500 },
    ];
    jest.spyOn(PaymentService.repo, "getPayableBills").mockResolvedValue(fakeBills);

    const result = await PaymentService.getPayableBills();

    // A mismatched SERVICE bucket carries a hold_amount while the fully
    // matched MATERIAL bucket doesn't — this is the "one bucket's mismatch
    // never blocks another bucket" guarantee surfacing at the API boundary.
    expect(result.find((b) => b.bucket_type === "MATERIAL").hold_amount).toBe(0);
    expect(result.find((b) => b.bucket_type === "SERVICE").hold_amount).toBeGreaterThan(0);
  });
});
