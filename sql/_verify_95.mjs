/**
 * Verifies sql/95_kyc_change_in_kyc_approval_screen.sql and its rollback WITHOUT applying them: everything runs in one transaction that is
 * always rolled back.
 *
 *   cd grn-service && node sql/_verify_95.mjs
 */
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sql from "mssql";
import { configDotenv } from "dotenv";

configDotenv({ quiet: true });
const here = path.dirname(fileURLToPath(import.meta.url));
if (!/dev/i.test(process.env.DATABASE ?? "")) { console.error("Refusing to run: not a Dev database."); process.exit(2); }

const batchesOf = async (file) => (await fs.readFile(path.join(here, file), "utf8")).split(/^\s*GO\s*$/gim).map((b) => b.trim())
  .filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));
const b95 = await batchesOf("95_kyc_change_in_kyc_approval_screen.sql");
const bRb = await batchesOf("backups/kyc_change_in_kyc_approval_screen_2026-11-08_ROLLBACK.sql");

const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER,
  database: process.env.DATABASE, port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true }, requestTimeout: 120000,
}).connect();
console.log(`Database: ${process.env.DATABASE} (everything is rolled back)\n`);

let failures = 0;
const check = (ok, label, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`); if (!ok) failures += 1; };

const tx = new sql.Transaction(pool);
await tx.begin();
const q = async (t) => (await new sql.Request(tx).query(t)).recordset;
try {
  const users = () => q(`SELECT user_perm_json_sno id, ecno, login_id, screens_json FROM dbo.nt_user_permissions_json WHERE is_active = 'Y'`);
  const screenId = async (comp) => (await q(`SELECT screen_id id FROM dbo.screens WHERE comp = '${comp}'`))[0]?.id ?? null;
  const ids = (u) => JSON.parse(u.screens_json || "[]").map((s) => Number(s.screen_id));

  const before = await users();
  const oldScreen = await screenId("KycChangeApprovalScreen");
  const kycScreen = await screenId("KYCApprovalScreen");
  const [{ active: oldActive }] = oldScreen ? await q(`SELECT is_active active FROM dbo.screens WHERE screen_id = ${oldScreen}`) : [{ active: null }];
  const holders = before.filter((u) => oldScreen && ids(u).includes(oldScreen));
  console.log(`separate screen ${oldScreen ?? "(none)"} held by ${holders.length} user(s); KYC Approval Screen is ${kycScreen}\n`);

  const approvers = [];
  for (const entity of ["SUPPLIER", "SUPPLIER_CHANGE"]) {
    const [{ stages }] = await q(`SELECT (SELECT JSON_VALUE(s.value, '$.stage_order_json') FROM dbo.vw_workflow_stages ws CROSS APPLY OPENJSON(ws.stages_json) s
        WHERE ws.workflow_types_id = dbo.fn_scopeless_workflow_types(dbo.fn_resolve_approval_entity('KYC','${entity}')) AND s.[key] = '0') stages`);
    approvers.push(...JSON.parse(stages ?? "[]").map((s) => String(s.approver_ecno).toUpperCase()));
  }
  const approverUsers = before.filter((u) => approvers.includes(String(u.ecno ?? "").toUpperCase()) || approvers.includes(String(u.login_id ?? "").toUpperCase()));
  const needGrant = approverUsers.filter((u) => !ids(u).includes(kycScreen));
  console.log(`approvers ${[...new Set(approvers)].join(",")} -> ${approverUsers.length} user(s), ${needGrant.length} without the KYC Approval Screen\n`);

  for (const b of b95) await new sql.Request(tx).batch(b);
  const after = await users();

  check(after.every((u) => !oldScreen || !ids(u).includes(oldScreen)), "the separate screen is out of every user's screens_json");
  if (oldScreen) check((await q(`SELECT is_active a FROM dbo.screens WHERE screen_id = ${oldScreen}`))[0].a === "N", "the separate screen is switched off (row kept)");
  check(needGrant.every((u) => { const a = after.find((x) => x.id === u.id); const e = JSON.parse(a.screens_json).find((s) => Number(s.screen_id) === kycScreen); return e && e.permissions.join(",") === "2,4,7,8"; }),
    "approvers who lacked the KYC Approval Screen now have it with View / Edit / Approve / Reject", needGrant.map((u) => u.login_id ?? u.ecno).join(","));
  check(after.every((u) => ids(u).filter((i) => i === kycScreen).length <= 1), "nobody has the KYC Approval Screen twice");
  check(after.every((u) => {
    const b = before.find((x) => x.id === u.id);
    const keep = JSON.parse(b.screens_json || "[]").filter((s) => !oldScreen || Number(s.screen_id) !== oldScreen);
    const now = JSON.parse(u.screens_json || "[]");
    return JSON.stringify(keep) === JSON.stringify(now.slice(0, keep.length)) && now.length - keep.length === (needGrant.some((n) => n.id === u.id) ? 1 : 0);
  }), "every other screen is untouched and in the same order (only the grant is appended)");
  check(before.filter((u) => !holders.includes(u) && !needGrant.includes(u)).every((u) => after.find((x) => x.id === u.id).screens_json === u.screens_json), "users it has no reason to touch are byte-for-byte unchanged");

  const [{ n: backed }] = await q(`SELECT COUNT(*) n FROM dbo.bk_sql95_screens WHERE kind = 'USER'`);
  const touched = new Set([...holders, ...needGrant].map((u) => u.id));
  check(backed === touched.size, "every changed user was backed up first", `${backed} backed up, ${touched.size} changed`);

  // the sidebar of an approver: KYC Approval Screen yes, the separate screen no
  const approver = needGrant[0] ?? approverUsers[0];
  if (approver) {
    const key = approver.login_id ?? approver.ecno;
    const rs = (await new sql.Request(tx).input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({ ecno: key })).execute("sp_nt_GetUserScreensAndPermissionsJson")).recordsets;
    const text = JSON.stringify(rs);
    check(text.includes("KYCApprovalScreen") && !text.includes("KycChangeApprovalScreen"), `${key}'s sidebar lists the KYC Approval Screen and not the separate screen`);
  }

  // a second run changes nothing and keeps the ORIGINAL backup
  await new sql.Request(tx).batch(b95[0]);
  const again = await users();
  for (const b of b95) await new sql.Request(tx).batch(b);
  const twice = await users();
  check(JSON.stringify(twice) === JSON.stringify(after), "running it again changes nothing");
  check((await q(`SELECT COUNT(*) n FROM dbo.bk_sql95_screens WHERE kind = 'USER'`))[0].n === backed, "a second run keeps the original backup (no new rows)");
  void again;

  // the rollback restores everything
  for (const b of bRb) await new sql.Request(tx).batch(b);
  const restored = await users();
  check(restored.every((u) => u.screens_json === before.find((x) => x.id === u.id).screens_json), "after the rollback every screens_json is exactly what it was before");
  if (oldScreen) check((await q(`SELECT is_active a FROM dbo.screens WHERE screen_id = ${oldScreen}`))[0].a === oldActive, "after the rollback the separate screen is as before", String(oldActive));
  check((await q(`SELECT OBJECT_ID('dbo.bk_sql95_screens') id`))[0].id === null, "the backup table is removed by the rollback");
} catch (e) {
  failures += 1;
  console.error("UNEXPECTED", e.number ?? "", e.message);
} finally {
  try { await tx.rollback(); } catch { /* ended */ }
  await pool.close();
}
console.log(failures ? `\n${failures} check(s) FAILED` : "\nAll checks passed");
process.exit(failures ? 1 : 0);
