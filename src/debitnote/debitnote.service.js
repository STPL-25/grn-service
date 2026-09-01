import DebitNoteRepository from "./debitnote.repository.js";

const REASON_TYPES = new Set(["Damage", "Shortage", "Return"]);

class DebitNoteService {
  static repo = new DebitNoteRepository();

  static async getGRNDiscrepancyItems(grn_basic_sno) {
    return this.repo.getGRNDiscrepancyItems(grn_basic_sno);
  }

  static async createDebitNote(debitNoteData) {
    const { grn_basic_sno, items = [] } = debitNoteData;
    if (!grn_basic_sno) throw new Error("grn_basic_sno is required.");
    if (!Array.isArray(items) || items.length === 0) {
      throw new Error("At least one item is required.");
    }
    for (const item of items) {
      if (!item.qty || Number(item.qty) <= 0) {
        throw new Error("Every item requires a quantity greater than 0.");
      }
      if (!REASON_TYPES.has(item.reason_type)) {
        throw new Error("reason_type must be Damage, Shortage or Return.");
      }
    }
    const [debitNote] = await this.repo.createDebitNote(debitNoteData);
    return debitNote;
  }

  static async getAllDebitNotes(filters) {
    return this.repo.getAllDebitNotes(filters);
  }

  static async getDebitNotesByGRN(grn_basic_sno) {
    return this.repo.getDebitNotesByGRN(grn_basic_sno);
  }
}

export default DebitNoteService;
