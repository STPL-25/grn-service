import DebitNoteService from "./debitnote.service.js";
import { broadcast } from "../utils/socketBroadcast.js";

function getAuthUser(req) {
  const user = Array.isArray(req.user) ? req.user[0] : req.user;
  return user;
}

class DebitNoteController {
  static async getGRNDiscrepancyItems(req, res) {
    try {
      const { grn_basic_sno } = req.params;
      const data = await DebitNoteService.getGRNDiscrepancyItems(Number(grn_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async createDebitNote(req, res) {
    try {
      const user = getAuthUser(req);
      const debitNote = await DebitNoteService.createDebitNote({ ...req.body, created_by: user?.ecno });
      broadcast("grn:live", "debit_note:created", debitNote);
      res.json({ success: true, data: debitNote, message: "Debit note raised" });
    } catch (error) {
      res.status(400).json({ success: false, error: error.message });
    }
  }

  static async getAllDebitNotes(req, res) {
    try {
      const data = await DebitNoteService.getAllDebitNotes(req.query);
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }

  static async getDebitNotesByGRN(req, res) {
    try {
      const { grn_basic_sno } = req.params;
      const data = await DebitNoteService.getDebitNotesByGRN(Number(grn_basic_sno));
      res.json({ success: true, data });
    } catch (error) {
      res.status(500).json({ success: false, error: error.message });
    }
  }
}

export default DebitNoteController;
