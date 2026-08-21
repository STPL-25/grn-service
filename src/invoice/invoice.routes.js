import express from "express";
import InvoiceController from "./invoice.controller.js";
import { upload } from "../utils/ftpUpload.js";

const InvoiceRouter = express.Router();

InvoiceRouter.post("/createInvoice", upload.single("invoice_file"), InvoiceController.createInvoice);
InvoiceRouter.post("/linkInvoiceToPO", InvoiceController.linkInvoiceToPO);
InvoiceRouter.post("/allocateInvoice", InvoiceController.allocateInvoice);
InvoiceRouter.post("/matchInvoice", InvoiceController.matchInvoice);
InvoiceRouter.get("/getInvoicesByPO/:po_basic_sno", InvoiceController.getInvoicesByPO);
InvoiceRouter.get("/getAllInvoices", InvoiceController.getAllInvoices);
InvoiceRouter.get("/getPendingMatches", InvoiceController.getPendingMatches);

export default InvoiceRouter;
