/**
 * Shared PR-tracking helpers for grn-service's post-PO modules (dispatch,
 * gate entry, GRN) — each of those only carries po_basic_sno, so this
 * resolves which pr_no's tracking room to push a live update into, via the
 * new read-only sp_nt_GetPrNoByPoBasicSno (backend-stpl/sql/29_pr_tracking.sql).
 *
 * Both helpers swallow their own errors — a tracking-side failure must never
 * surface as a failure of the dispatch/gate-entry/GRN action that triggered it.
 */
import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";
import { broadcast } from "./socketBroadcast.js";

export async function getPrNoByPoBasicSno(po_basic_sno) {
  try {
    const pool = await initializeDatabase();
    const request = pool.request();
    request.input("po_basic_sno", mssql.Int, po_basic_sno);
    const result = await request.execute("sp_nt_GetPrNoByPoBasicSno");
    return result.recordset[0]?.pr_no ?? null;
  } catch (error) {
    console.error("[grn-service] getPrNoByPoBasicSno failed:", error.message);
    return null;
  }
}

export async function broadcastPrTrack(po_basic_sno, stage, status, payload) {
  try {
    const pr_no = await getPrNoByPoBasicSno(po_basic_sno);
    if (!pr_no) return;
    broadcast(`pr:track:${pr_no}`, "pr:track:updated", { pr_no, stage, status, payload });
  } catch (error) {
    console.error("[grn-service] broadcastPrTrack failed:", error.message);
  }
}
