import mssql from "mssql";
import { randomUUID } from "node:crypto";
import { initializeDatabase } from "../config/db.js";

const GRN_DRAFT_TTL = 30 * 24 * 60 * 60; // 30 days

class GRNRepository {
  async executeStoredProcedure(procedureName, parameters = {}) {
    try {
      const pool = await initializeDatabase();
      const request = pool.request();
      if (Object.keys(parameters).length > 0) {
        request.input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify(parameters));
      }
      const result = await request.execute(procedureName);
      return result.recordset;
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

  async getGRNsByPO(po_basic_sno) {
    return this.executeStoredProcedure("sp_nt_GetGRNsByPO", { po_basic_sno });
  }

  async createGRN(grnData) {
    console.log("Creating GRN with data:", grnData);
    return this.executeStoredProcedure("sp_nt_CreateGRN", grnData);
  }

  async getAllGRNs(filters = {}) {
    return this.executeStoredProcedure("sp_nt_GetAllGRNs", filters);
  }

  async getWarehouseLocationsForGRN(scope = {}) {
    return this.executeStoredProcedure("sp_nt_GetWarehouseLocationsForGRN", scope);
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
