/**
 * Verifies sql/90_gstr2b_company_scope.sql WITHOUT applying it: one transaction, always rolled back.
 *
 *   cd grn-service && node sql/_verify_90.mjs
 *
 * Old vs new output of the GSTR-2B list procedures, the company / hierarchy filters, sp_nt_Gstr2bScopeOf,
 * and what real users' hierarchies would see.
 */
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sql from "mssql";
import { configDotenv } from "dotenv";

configDotenv();
const here = path.dirname(fileURLToPath(import.meta.url));

if (!/dev/i.test(process.env.DATABASE ?? "")) {
  console.error(`Refusing to run: DATABASE is "${process.env.DATABASE}", expected a Dev database.`);
  process.exit(2);
}

const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER,
  database: process.env.DATABASE, port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true }, requestTimeout: 120000,
}).connect();
console.log(`Database: ${process.env.DATABASE} (changes are rolled back)\n`);

const script = await fs.readFile(path.join(here, "90_gstr2b_company_scope.sql"), "utf8");
const batches = script.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));

let failures = 0;
const check = (ok, label, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`); if (!ok) failures += 1; };

const tx = new sql.Transaction(pool);
await tx.begin();
const q = async (text) => (await new sql.Request(tx).query(text)).recordset;
const exec = async (proc, input) => {
  const r = new sql.Request(tx);
  if (input !== undefined) r.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(input));
  return (await r.execute(proc)).recordset ?? [];
};
const ids = (list, key) => list.map((x) => x[key]).sort((a, b) => a - b).join(",");

try {
  const oldUploads = await exec("sp_nt_Gstr2bListUploads");
  const oldMissing = await exec("sp_nt_Gstr2bMissingIn2B");
  const uploadRows = await q("SELECT upload_sno, com_sno FROM dbo.gstr2b_upload");
  // independent expectation for Missing in 2B: each invoice's company / division / branch (invoice first, else its PO)
  const invOrg = new Map((await q(`SELECT i.invoice_sno, COALESCE(i.com_sno, po.com_sno) com_sno, COALESCE(i.div_sno, po.div_sno) div_sno, COALESCE(i.brn_sno, po.brn_sno) brn_sno
      FROM dbo.invoice_info i LEFT JOIN dbo.po_request_info po ON po.po_basic_sno = i.po_basic_sno`)).map((r) => [r.invoice_sno, r]));
  const covers = (hier, o) => hier.some((h) => h.com_sno === o.com_sno && (h.div_sno == null || h.div_sno === o.div_sno) && (h.brn_sno == null || h.brn_sno === o.brn_sno));

  for (const b of batches) await new sql.Request(tx).batch(b);
  check(true, `applied ${batches.length} batches inside the transaction`);

  // ---- no parameter = old behaviour
  const newUploads = await exec("sp_nt_Gstr2bListUploads");
  check(ids(newUploads, "upload_sno") === ids(oldUploads, "upload_sno"), "ListUploads without input lists the same uploads as before", `(${newUploads.length})`);
  const sameCounts = newUploads.every((n) => { const o = oldUploads.find((x) => x.upload_sno === n.upload_sno);
    return o && ["matched", "mismatch", "unmatched", "added", "row_count"].every((k) => o[k] === n[k]); });
  check(sameCounts, "ListUploads counts unchanged");
  check(newUploads.every((u) => "com_sno" in u && "com_name" in u), "ListUploads returns com_sno + com_name",
    newUploads.map((u) => `${u.upload_sno}:${u.com_sno}:${u.com_name}`).join(" "));
  const newMissing = await exec("sp_nt_Gstr2bMissingIn2B");
  check(ids(newMissing, "invoice_sno") === ids(oldMissing, "invoice_sno"), "MissingIn2B without input lists the same invoices as before", `(${newMissing.length})`);

  // ---- hierarchy filter on uploads
  check((await exec("sp_nt_Gstr2bListUploads", { hierarchy: [] })).length === 0, "ListUploads with an empty hierarchy shows nothing");
  const coms = [...new Set(uploadRows.map((u) => u.com_sno).filter((c) => c != null))];
  for (const c of coms) {
    const mine = await exec("sp_nt_Gstr2bListUploads", { hierarchy: [{ com_sno: c, div_sno: 99, brn_sno: 99 }] });
    check(ids(mine, "upload_sno") === ids(uploadRows.filter((u) => u.com_sno === c), "upload_sno"),
      `company ${c}: a branch-level grant still sees the company's 2B files`, `(${mine.length})`);
    const other = await exec("sp_nt_Gstr2bListUploads", { hierarchy: [{ com_sno: 999999 }] });
    check(other.length === 0, `another company's user does not see company ${c}'s files`);
    const pick = await exec("sp_nt_Gstr2bListUploads", { com_sno: c, hierarchy: [{ com_sno: c }, { com_sno: 999999 }] });
    check(pick.every((u) => u.com_sno === c) && pick.length === uploadRows.filter((u) => u.com_sno === c).length, `com_sno=${c} returns only that company's files`);
    const notMine = await exec("sp_nt_Gstr2bListUploads", { com_sno: c, hierarchy: [{ com_sno: 999999 }] });
    check(notMine.length === 0, `com_sno=${c} asked by a user without that company returns nothing`);
  }

  // ---- summary carries the company
  for (const u of uploadRows) {
    const s = (await new sql.Request(tx).input("upload_sno", sql.Int, u.upload_sno).execute("sp_nt_Gstr2bSummary")).recordset[0];
    check(s && s.com_sno === u.com_sno && "com_name" in s, `Summary ${u.upload_sno} returns its company`, `${s?.com_sno} ${s?.com_name}`);
  }

  // ---- Missing in 2B by company / hierarchy
  check((await exec("sp_nt_Gstr2bMissingIn2B", { hierarchy: [] })).length === 0, "MissingIn2B with an empty hierarchy shows nothing");
  const missingComs = [...new Set(oldMissing.map((m) => invOrg.get(m.invoice_sno)?.com_sno))];
  for (const c of missingComs.filter((x) => x != null)) {
    const hier = [{ com_sno: c, div_sno: null, brn_sno: null }];
    const got = await exec("sp_nt_Gstr2bMissingIn2B", { com_sno: c, hierarchy: hier });
    const want = oldMissing.filter((m) => covers(hier, invOrg.get(m.invoice_sno)));
    check(ids(got, "invoice_sno") === ids(want, "invoice_sno"), `MissingIn2B company ${c}`, `(${got.length} of ${oldMissing.length})`);
    check(got.every((m) => m.com_sno === c), `MissingIn2B company ${c} rows all carry com_sno ${c}`);
  }
  const noCom = oldMissing.filter((m) => invOrg.get(m.invoice_sno)?.com_sno == null).length;
  console.log(`      (${noCom} missing-in-2B invoices have no company on the invoice or its PO: hidden from every company view)`);
  // a narrower grant (one division / branch) gets a subset, matching the JS rule
  const sample = oldMissing.map((m) => invOrg.get(m.invoice_sno)).find((o) => o?.com_sno != null && o.div_sno != null && o.brn_sno != null);
  if (sample) {
    const hier = [{ com_sno: sample.com_sno, div_sno: sample.div_sno, brn_sno: sample.brn_sno }];
    const got = await exec("sp_nt_Gstr2bMissingIn2B", { hierarchy: hier });
    const want = oldMissing.filter((m) => covers(hier, invOrg.get(m.invoice_sno)));
    check(ids(got, "invoice_sno") === ids(want, "invoice_sno"), `MissingIn2B branch grant ${sample.com_sno}/${sample.div_sno}/${sample.brn_sno}`, `(${got.length})`);
  }

  // ---- real users: what would they see
  const users = await q(`SELECT TOP 8 ecno FROM dbo.nt_user_permissions_json WHERE is_active = 'Y' AND ecno IS NOT NULL
      AND ecno IN (SELECT uploaded_by FROM dbo.gstr2b_upload UNION SELECT 'KTM1006' UNION SELECT 'KTM1148' UNION SELECT 'NSU00002') ORDER BY ecno`);
  for (const { ecno } of users) {
    const hier = (await new sql.Request(tx).input("Ecno", sql.VarChar(50), ecno).execute("sp_nt_GetUserHierarchy")).recordset;
    const ups = await exec("sp_nt_Gstr2bListUploads", { hierarchy: hier });
    const mis = await exec("sp_nt_Gstr2bMissingIn2B", { hierarchy: hier });
    console.log(`      ${ecno}: companies [${[...new Set(hier.map((h) => h.com_sno))].join(",")}] -> ${ups.length} 2B files, ${mis.length} missing-in-2B invoices`);
  }

  // ---- scope lookups
  for (const u of uploadRows) {
    const [s] = await exec("sp_nt_Gstr2bScopeOf", { upload_sno: u.upload_sno });
    check(s?.com_sno === u.com_sno, `ScopeOf upload ${u.upload_sno} = company ${u.com_sno}`);
    const [r] = await q(`SELECT TOP 1 row_sno FROM dbo.gstr2b_row WHERE upload_sno = ${u.upload_sno}`);
    if (r) { const [rs] = await exec("sp_nt_Gstr2bScopeOf", { row_sno: r.row_sno }); check(rs?.com_sno === u.com_sno, `ScopeOf row ${r.row_sno} = company ${u.com_sno}`); }
  }
  for (const m of oldMissing.slice(0, 5)) {
    const [s] = await exec("sp_nt_Gstr2bScopeOf", { invoice_sno: m.invoice_sno });
    const o = invOrg.get(m.invoice_sno);
    check(s && s.com_sno === o.com_sno && s.div_sno === o.div_sno && s.brn_sno === o.brn_sno, `ScopeOf invoice ${m.invoice_sno}`, `${s?.com_sno}/${s?.div_sno}/${s?.brn_sno}`);
  }
  check((await exec("sp_nt_Gstr2bScopeOf", { row_sno: 2147483000 })).length === 0, "ScopeOf an unknown row returns no row");
  // last: the procedure's THROW for no key (kept last so an aborted transaction cannot hide other results)
  let threw = "";
  try { await exec("sp_nt_Gstr2bScopeOf", {}); } catch (e) { threw = e.message; }
  check(/required/.test(threw), "ScopeOf with no key throws", threw);
} catch (e) {
  failures += 1;
  console.error("ERROR", e.message);
} finally {
  await tx.rollback().catch(() => {});
  const still = await pool.request().query("SELECT OBJECT_ID('dbo.sp_nt_Gstr2bScopeOf') id");
  console.log(`\nRolled back (sp_nt_Gstr2bScopeOf exists afterwards: ${still.recordset[0].id != null}). ${failures ? `${failures} FAILED` : "all passed"}`);
  await pool.close();
}
process.exit(failures ? 1 : 0);
