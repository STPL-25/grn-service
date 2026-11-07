/**
 * Verifies sql/89_supplier_po_page_amounts.sql WITHOUT applying it: one transaction, always rolled back.
 *
 *   cd grn-service && node sql/_verify_89.mjs
 *
 * Compares the OLD and NEW supplier PO procedures over every PO line on the database: amounts (re-derived independently in JS),
 * names, the list contents, and the status gate on list / detail / accept.
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

const script = await fs.readFile(path.join(here, "89_supplier_po_page_amounts.sql"), "utf8");
const batches = script.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));

let failures = 0;
const check = (ok, label, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`); if (!ok) failures += 1; };
const round2 = (n) => Math.round((n + Number.EPSILON) * 100) / 100;

const tx = new sql.Transaction(pool);
await tx.begin();
const q = async (text) => (await new sql.Request(tx).query(text)).recordset;
const exec = async (proc, input) => (await new sql.Request(tx).input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(input)).execute(proc)).recordset ?? [];
const items = (row) => (row?.items ? JSON.parse(row.items) : []);

try {
  // Every approved PO that has a supplier, with the raw line columns for an independent expectation.
  const pos = await q(`SELECT po_basic_sno, vendor_sno FROM dbo.po_request_info WHERE vendor_sno IS NOT NULL AND status='A' AND is_active IN ('Y','1') ORDER BY po_basic_sno`);
  const raw = new Map((await q(`SELECT i.po_item_sno, i.qty, i.agreed_unit_price price, ISNULL(i.discount_pct,0) disc, ISNULL(i.tax_pct,0) tax, i.total_cost, i.net_cost, i.prod_sno, i.service_sno
      FROM dbo.po_item_details i WHERE i.is_active IN ('Y','1')`)).map((r) => [r.po_item_sno, r]));
  const oldListCount = new Map();
  const oldDetail = new Map();
  for (const p of pos) {
    const [d] = await exec("sp_nt_GetPODetailForSupplier", { kyc_basic_info_sno: p.vendor_sno, po_basic_sno: p.po_basic_sno });
    oldDetail.set(p.po_basic_sno, items(d));
  }
  for (const v of new Set(pos.map((p) => p.vendor_sno))) oldListCount.set(v, (await exec("sp_nt_GetPOsForSupplier", { kyc_basic_info_sno: v })).length);
  const [pendingPo] = await q(`SELECT po_basic_sno FROM dbo.po_request_info WHERE status <> 'A' AND is_active IN ('Y','1')`);

  for (const b of batches) await new sql.Request(tx).batch(b);
  check(true, `applied ${batches.length} batches inside the transaction; ${pos.length} approved POs with a supplier to compare`);

  // ---- amounts / names, line by line
  let lines = 0, amountWrongBefore = 0, amountWrongAfter = 0, notAStoredIssuerValue = 0, taxedWrong = 0, blankNameBefore = 0, blankNameAfter = 0, blankUnitAfter = 0, missingKeys = 0;
  const examples = [];
  for (const p of pos) {
    const [d] = await exec("sp_nt_GetPODetailForSupplier", { kyc_basic_info_sno: p.vendor_sno, po_basic_sno: p.po_basic_sno });
    check_po: for (const it of items(d)) {
      const r = raw.get(it.po_item_sno);
      lines += 1;
      const taxable = round2(Number(r.qty) * Number(r.price) * (1 - Number(r.disc) / 100));
      const tax = round2(taxable * Number(r.tax) / 100);
      const expected = round2(taxable + tax);
      if (Math.abs(Number(it.total_amount) - expected) > 0.02) amountWrongAfter += 1;
      if (Math.abs(Number(it.taxable_amount) - taxable) > 0.02 || Math.abs(Number(it.tax_amount) - tax) > 0.02) taxedWrong += 1;
      // the incl-GST figure the issuer saw is stored in total_cost or net_cost (depending on how the PO was created)
      if (Math.abs(Number(it.total_amount) - Number(r.total_cost)) > 0.05 && Math.abs(Number(it.total_amount) - Number(r.net_cost)) > 0.05) notAStoredIssuerValue += 1;
      for (const k of ["discount_pct", "tax_pct", "taxable_amount", "tax_amount", "total_amount", "ordered_qty", "unit_price", "po_item_sno", "prod_name", "unit_name"]) if (!(k in it) && !["prod_name", "unit_name"].includes(k)) missingKeys += 1;
      if (!it.prod_name || !String(it.prod_name).trim()) blankNameAfter += 1;
      if (!it.unit_name || !String(it.unit_name).trim()) blankUnitAfter += 1;
    }
    for (const it of oldDetail.get(p.po_basic_sno)) {
      const r = raw.get(it.po_item_sno);
      const expected = round2(Number(r.qty) * Number(r.price) * (1 - Number(r.disc) / 100) * (1 + Number(r.tax) / 100));
      if (Math.abs(Number(it.total_amount) - expected) > 0.05) { amountWrongBefore += 1; if (examples.length < 3) examples.push({ qty: r.qty, price: r.price, tax: r.tax, oldShown: it.total_amount, newShown: expected }); }
      if (!it.prod_name || !String(it.prod_name).trim()) blankNameBefore += 1;
    }
  }
  console.log("\nExamples of lines the OLD procedure got wrong:", JSON.stringify(examples));
  console.log(`Lines compared: ${lines}\n`);
  check(amountWrongBefore > 0, "baseline: the OLD procedure really did show wrong amounts", `${amountWrongBefore} lines`);
  check(amountWrongAfter === 0, "NEW: every line's total_amount = qty x price x (1-disc%) x (1+GST%), re-derived independently in JS", `${amountWrongAfter} wrong`);
  check(taxedWrong === 0, "NEW: taxable_amount and tax_amount are right on every line", `${taxedWrong} wrong`);
  check(notAStoredIssuerValue === 0, "NEW: every line total equals the incl-GST value stored on the line (total_cost or net_cost) - i.e. what the issuer saw", `${notAStoredIssuerValue} differ`);
  check(missingKeys === 0, "NEW: all keys the page reads are still present, plus discount_pct / tax_pct / taxable_amount / tax_amount");
  check(blankNameBefore > 0, "baseline: the OLD procedure returned blank item names", `${blankNameBefore} lines`);
  check(blankNameAfter === 0, "NEW: no blank item names", `${blankNameAfter} blank`);
  check(blankUnitAfter === 0, "NEW: no blank units", `${blankUnitAfter} blank`);

  // ---- list contents unchanged for approved POs
  let sameList = true;
  for (const [v, n] of oldListCount) { const now = (await exec("sp_nt_GetPOsForSupplier", { kyc_basic_info_sno: v })).length; if (now !== n) { sameList = false; console.log(`   vendor ${v}: ${n} -> ${now}`); } }
  check(sameList, "list: every supplier still sees all their approved POs");

  // ---- status gate (simulate: give the pending PO a supplier, inside the transaction)
  if (pendingPo) {
    await q(`UPDATE dbo.po_request_info SET vendor_sno = 122 WHERE po_basic_sno = ${pendingPo.po_basic_sno}`);
    const list = await exec("sp_nt_GetPOsForSupplier", { kyc_basic_info_sno: 122 });
    check(!list.some((r) => r.po_basic_sno === pendingPo.po_basic_sno), "list: a PO still pending approval (status P) is NOT shown to the supplier");
    const detail = await exec("sp_nt_GetPODetailForSupplier", { kyc_basic_info_sno: 122, po_basic_sno: pendingPo.po_basic_sno });
    check(detail.length === 0, "detail: a pending PO cannot be opened by id");
    let accepted = true;
    try { await exec("sp_nt_AcceptPO", { kyc_basic_info_sno: 122, po_basic_sno: pendingPo.po_basic_sno }); } catch (e) { accepted = false; check(/not found/i.test(e.message), "accept: a pending PO cannot be accepted", e.message); }
    if (accepted) check(false, "accept: a pending PO cannot be accepted", "it was accepted!");
    await q(`UPDATE dbo.po_request_info SET status = 'A' WHERE po_basic_sno = ${pendingPo.po_basic_sno}`);
    const after = await exec("sp_nt_GetPOsForSupplier", { kyc_basic_info_sno: 122 });
    check(after.some((r) => r.po_basic_sno === pendingPo.po_basic_sno), "list: the same PO appears as soon as it is approved");
  } else console.log("SKIP  no pending PO on this database");

  // ---- accept still works for an approved, unaccepted PO
  const [todo] = await q(`SELECT TOP 1 po_basic_sno, vendor_sno FROM dbo.po_request_info WHERE vendor_sno IS NOT NULL AND status='A' AND is_active IN ('Y','1') AND supplier_ack_status IS NULL`);
  if (todo) {
    const [acc] = await exec("sp_nt_AcceptPO", { kyc_basic_info_sno: todo.vendor_sno, po_basic_sno: todo.po_basic_sno });
    check(acc?.supplier_ack_status === "Accepted", "accept: an approved PO of the supplier is accepted as before");
    let crossed = false;
    try { await exec("sp_nt_AcceptPO", { kyc_basic_info_sno: todo.vendor_sno + 999999, po_basic_sno: todo.po_basic_sno }); crossed = true; } catch { /* expected */ }
    check(!crossed, "accept: another supplier cannot accept it");
  }

  // ---- sample for the eye
  const sample = pos.find((p) => p.vendor_sno === 122) ?? pos[0];
  const [s] = await exec("sp_nt_GetPODetailForSupplier", { kyc_basic_info_sno: sample.vendor_sno, po_basic_sno: sample.po_basic_sno });
  console.log("\nSample (new):", JSON.stringify(items(s).slice(0, 2)));
} catch (err) {
  failures += 1;
  console.error("ERROR", err.message);
} finally {
  await tx.rollback();
  const [def] = (await pool.request().query(`SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.sp_nt_GetPODetailForSupplier')) d`)).recordset;
  check(def.d.includes("i.net_cost       AS total_amount") && !def.d.includes("taxable_amount"), "rolled back: the live detail procedure is the old one again");
  await pool.close();
}
console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
