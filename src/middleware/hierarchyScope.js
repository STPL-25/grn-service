/**
 * Company/Division/Branch access scoping — grn-service's copy of
 * backend-stpl/src/Middleware/hierarchyScope.js (duplicated rather than
 * shared, matching how JwtAuth.js is already duplicated across the two
 * services — they're separate deployables with separate repos).
 *
 * Resolves the requesting employee's allowed org scope from
 * nt_user_permissions_json.hierarchy_json (via sp_nt_GetUserHierarchy, in
 * the shared Non_trade_Dev database) and attaches it as req.hierarchyJson —
 * an array of {com_sno, div_sno, brn_sno} rows to fold into any SP call's
 * `hierarchy` field.
 *
 * Fail-closed default: an ecno with no active permissions row (or any
 * lookup error) gets [] — an empty array, never null/undefined — so a GET
 * handler that forwards it straight through sees zero rows rather than an
 * unfiltered table. Passing an actual NULL/omitted field means "no filter",
 * which must never happen implicitly from this path.
 */
import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";

const CACHE_TTL_SECONDS = 60;

export async function getHierarchyJson(ecno) {
  if (!ecno) return [];
  try {
    const pool = await initializeDatabase();
    const request = pool.request();
    request.input("Ecno", mssql.VarChar(50), ecno);
    const result = await request.execute("sp_nt_GetUserHierarchy");
    return result.recordset ?? [];
  } catch (error) {
    console.error(`[hierarchyScope] failed to resolve hierarchy for ${ecno}:`, error.message);
    return [];
  }
}

async function getHierarchyJsonCached(req, ecno) {
  const redisClient = req.redisClient;
  if (!ecno || !redisClient) return getHierarchyJson(ecno);

  const cacheKey = `hier:${ecno}`;
  try {
    const cached = await redisClient.get(cacheKey);
    if (cached) return JSON.parse(cached);
  } catch {
    // fall through to a live lookup
  }

  const hierarchy = await getHierarchyJson(ecno);
  redisClient.setEx(cacheKey, CACHE_TTL_SECONDS, JSON.stringify(hierarchy)).catch(() => {});
  return hierarchy;
}

// Mount on individual GET routes, after verifyJWT (needs req.user_ecno).
export async function attachHierarchyScope(req, res, next) {
  req.hierarchyJson = await getHierarchyJsonCached(req, req.user_ecno);
  next();
}

/**
 * Socket.IO room scheme for org-scoped real-time broadcasts — mirrors
 * backend-stpl/src/Middleware/hierarchyScope.js exactly (that copy is what
 * a connecting socket joins; this one is what grn-service's
 * socketBroadcast.js targets when it emits an event for a specific
 * com/div/brn). Keep the two in lockstep if this scheme ever changes.
 */
export function orgRoomTargets(domain, { com_sno, div_sno, brn_sno, dept_sno } = {}) {
  if (com_sno == null) return [`${domain}:live`];
  const rooms = [`${domain}:live:com:${com_sno}`];
  if (div_sno != null) {
    rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}`);
    if (brn_sno != null) {
      rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}:brn:${brn_sno}`);
      if (dept_sno != null) rooms.push(`${domain}:live:com:${com_sno}:div:${div_sno}:brn:${brn_sno}:dept:${dept_sno}`);
    }
  }
  return rooms;
}
