import express from "express";
import PaymentController from "./payment.controller.js";

const PaymentRouter = express.Router();

PaymentRouter.get("/getPayableBills", PaymentController.getPayableBills);
PaymentRouter.post("/createPayment", PaymentController.createPayment);
PaymentRouter.get("/getPaymentHistory", PaymentController.getPaymentHistory);

export default PaymentRouter;
