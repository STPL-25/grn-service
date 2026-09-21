import PaymentRepository from "./payment.repository.js";

class PaymentService {
  static repo = new PaymentRepository();

  static async getPayableBills(filters) {
    return this.repo.getPayableBills(filters);
  }

  static async releasePayment(payload) {
    return this.repo.releasePayment(payload);
  }

  static async getPaymentHistory(filters) {
    return this.repo.getPaymentHistory(filters);
  }
}

export default PaymentService;
