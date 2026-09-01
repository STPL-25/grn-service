import express from "express";
import DebitNoteController from "./debitnote.controller.js";

const DebitNoteRouter = express.Router();

DebitNoteRouter.get("/discrepancyItems/:grn_basic_sno", DebitNoteController.getGRNDiscrepancyItems);
DebitNoteRouter.post("/createDebitNote", DebitNoteController.createDebitNote);
DebitNoteRouter.get("/getAllDebitNotes", DebitNoteController.getAllDebitNotes);
DebitNoteRouter.get("/getDebitNotesByGRN/:grn_basic_sno", DebitNoteController.getDebitNotesByGRN);

export default DebitNoteRouter;
