import PaymentService from "./payment.service.js";
import { invalidateCache } from "../middleware/redisCache.js";
import { broadcast } from "../utils/socketBroadcast.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class PaymentController {
  static async getPayableBills(req, res) {
    try {
      const data = await PaymentService.getPayableBills();
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createPayment(req, res) {
    try {
      const user = getAuthUser(req);
      const { vendor_sno, payment_date, amount, mode, bank_account, reference_no, remarks, allocations } = req.body;

      if (!vendor_sno || !amount || !mode || !Array.isArray(allocations) || allocations.length === 0) {
        return res.status(400).json({ success: false, error: "vendor_sno, amount, mode and at least one allocation are required" });
      }

      const data = await PaymentService.releasePayment({
        vendor_sno, payment_date, amount, mode, bank_account, reference_no, remarks,
        allocations,
        created_by: user?.ecno,
      });

      await invalidateCache(req.redisClient, "payment:payable_bills", "payment:history");
      broadcast("payment:live", "payment:released", data?.[0]);

      res.json({ success: true, data, message: "Payment released" });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getPaymentHistory(req, res) {
    try {
      const { bill_sno } = req.query;
      const data = await PaymentService.getPaymentHistory({ bill_sno });
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default PaymentController;
