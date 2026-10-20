import mssql from "mssql";
import { randomUUID } from "node:crypto";
import { initializeDatabase } from "../config/db.js";

const GRN_DRAFT_TTL = 30 * 24 * 60 * 60; // 30 days

class GRNRepository {
  async executeStoredProcedure(procedureName, parameters = {}, { allRecordsets = false } = {}) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      if (Object.keys(parameters).length > 0) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return allRecordsets ? result.recordsets : result.recordset;
    } catch (error) {
      throw new Error(`Database error: ${error.message}`);
    }
  }

  // ── DB Operations ─────────────────────────────────────────────────────────

  async getPendingPOs(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetPendingPOsForGRN", filters);
  }

  async getPendingGateEntries(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetPendingGateEntriesForGRN", filters);
  }

  async getGRNsByPO(po_basic_sno, hierarchyJson) {
    return this.executeStoredProcedure("sp_nt_GetGRNsByPO", { po_basic_sno, hierarchy: hierarchyJson ?? [] });
  }

  async createGRN(grnData) {
    console.log("Creating GRN with data:", grnData);
    return this.executeStoredProcedure("sp_nt_CreateGRN", grnData);
  }

  // ── GRN approval gate (see sql/40_grn_approval_workflow.sql) ──

  async submitForApproval(payload) {
    return this.executeStoredProcedure("sp_nt_SubmitGRNForApproval", payload);
  }

  async approveGRN(payload) {
    return this.executeStoredProcedure("sp_nt_ApproveGRN", payload);
  }

  // First recordset = GRN rows, second = approval history (only when grn_basic_sno given).
  async getGRNApprovals(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetGRNApprovals", filters, { allRecordsets: true });
  }

  // ── Asset tags (see sql/58_grn_asset_tags.sql) ──

  async getGRNsForAssetTags() {
    return this.executeStoredProcedure("sp_nt_GetGRNsForAssetTags", {});
  }

  async generateAssetTags(payload) {
    return this.executeStoredProcedure("sp_nt_GenerateGRNAssetTags", payload);
  }

  async getAssetTags(grn_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetGRNAssetTags", { grn_basic_sno });
  }

  async markAssetTagsPrinted(tag_codes) {
    return this.executeStoredProcedure("sp_nt_ClaimAssetTagsForPrint", { tag_codes });
  }

  // ── Accounting journal (see sql/41_accounting_journal.sql) ──

  async postGRNJournal(payload) {
    return this.executeStoredProcedure("sp_nt_PostGRNJournal", payload);
  }

  async getJournals(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetJournals", filters);
  }

  async getAccountHeads() {
    return this.executeStoredProcedure("sp_nt_GetAccountHeads", {});
  }

  async getSubcategoryAccountMap() {
    return this.executeStoredProcedure("sp_nt_GetSubcategoryAccountMap", {});
  }

  async setSubcategoryAccountHead(payload) {
    return this.executeStoredProcedure("sp_nt_SetSubcategoryAccountHead", payload);
  }

  // ── Invoice qty / excess-over-PO approval (see sql/39_grn_invoice_qty_excess_shortage.sql) ──

  async getUomList() {
    return this.executeStoredProcedure("sp_nt_GetGRNUomList");
  }

  async getExcessRequests(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetGRNExcessRequests", filters);
  }

  async decideExcess(payload) {
    return this.executeStoredProcedure("sp_nt_DecideGRNExcess", payload);
  }

  async getCreditNotesByGRN(grn_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetCreditNotesByGRN", { grn_basic_sno });
  }

  async getAllGRNs(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetAllGRNs", filters);
  }

  async getWarehouseLocationsForGRN(scope = {}) {
    return this.executeStoredProcedure("sp_nt_GetWarehouseLocationsForGRN", scope);
  }

  // ── Inventory sync tracking (see sql/24_grn_inventory_sync_tracking.sql) ──

  async getItemsForInventorySync(grn_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetGRNItemsForInventorySync", { grn_basic_sno });
  }

  async getItemForInventorySync(grn_item_sno) {
    return this.executeStoredProcedure("sp_nt_GetGRNItemForInventorySync", { grn_item_sno });
  }

  async getUnsyncedInventoryItems() {
    return this.executeStoredProcedure("sp_nt_GetUnsyncedGRNInventoryItems", {});
  }

  async markInventorySync(grn_item_sno, status, error_message = null) {
    return this.executeStoredProcedure("sp_nt_MarkGRNItemInventorySync", {
      grn_item_sno,
      status,
      error_message,
    });
  }

  // ── Draft Operations (Redis) ──────────────────────────────────────────────
  // Key layout matches the monolith (grn:draft:{ecno}:{draftId} +
  // grn:drafts:{ecno} index set) so drafts survive the migration.

  async saveGRNDraft(redisClient, ecno, draftData) {
    if (!redisClient) return null;
    const draftId = randomUUID();
    const key = `grn:draft:${ecno}:${draftId}`;
    const indexKey = `grn:drafts:${ecno}`;

    const payload = {
      ...draftData,
      draftId,
      ecno,
      status: "Draft",
      savedAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };

    await redisClient.setEx(key, GRN_DRAFT_TTL, JSON.stringify(payload));
    await redisClient.sAdd(indexKey, draftId);
    await redisClient.expire(indexKey, GRN_DRAFT_TTL);
    return { draftId, savedAt: payload.savedAt };
  }

  async getGRNDrafts(redisClient, ecno) {
    if (!redisClient) return [];
    const indexKey = `grn:drafts:${ecno}`;
    const draftIds = await redisClient.sMembers(indexKey);
    if (!draftIds || draftIds.length === 0) return [];

    const drafts = await Promise.all(
      draftIds.map(async (draftId) => {
        const key = `grn:draft:${ecno}:${draftId}`;
        const raw = await redisClient.get(key);
        if (!raw) {
          await redisClient.sRem(indexKey, draftId);
          return null;
        }
        return JSON.parse(raw);
      })
    );

    return drafts
      .filter(Boolean)
      .sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt));
  }

  async getGRNDraft(redisClient, ecno, draftId) {
    if (!redisClient) return null;
    const key = `grn:draft:${ecno}:${draftId}`;
    const raw = await redisClient.get(key);
    if (!raw) return null;
    return JSON.parse(raw);
  }

  async updateGRNDraft(redisClient, ecno, draftId, draftData) {
    if (!redisClient) return null;
    const key = `grn:draft:${ecno}:${draftId}`;
    const existing = await redisClient.get(key);
    if (!existing) return null;

    const prev = JSON.parse(existing);
    const updated = {
      ...prev,
      ...draftData,
      draftId,
      ecno,
      savedAt: prev.savedAt,
      updatedAt: new Date().toISOString(),
    };

    await redisClient.setEx(key, GRN_DRAFT_TTL, JSON.stringify(updated));
    return { draftId, updatedAt: updated.updatedAt };
  }

  async deleteGRNDraft(redisClient, ecno, draftId) {
    if (!redisClient) return false;
    const key = `grn:draft:${ecno}:${draftId}`;
    const indexKey = `grn:drafts:${ecno}`;
    const deleted = await redisClient.del(key);
    await redisClient.sRem(indexKey, draftId);
    return deleted > 0;
  }
}

export default GRNRepository;
