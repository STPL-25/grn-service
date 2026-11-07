/**
 * Verifies sql/88_supplier_portal_bell.sql WITHOUT applying it: everything runs inside one transaction that is always rolled
 * back (DDL included), then the script confirms nothing was left behind.
 *
 *   cd grn-service && node sql/_verify_88.mjs
 *
 * Checks: seeding is silent and complete; a quiet DB announces nothing; a "new" note / payment is announced once with the right
 * details; a claimed event is not handed out twice but is retried after the lease; delivered events stay delivered; a payment
 * first seen already paid is announced as paid only; an event whose source went inactive comes back with a NULL ref_no.
 */
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sql from "mssql";
import { configDotenv } from "dotenv";

configDotenv();
const here = path.dirname(fileURLToPath(import.meta.url));

// Even though everything is rolled back, never point a verification at production (Non_Trade).
if (!/dev/i.test(process.env.DATABASE ?? "")) {
  console.error(`Refusing to run: DATABASE is "${process.env.DATABASE}", expected a Dev database (e.g. Non_trade_Dev).`);
  process.exit(2);
}

const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER,
  password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER,
  database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true },
  requestTimeout: 60000,
}).connect();
console.log(`Database: ${process.env.DATABASE} (changes are rolled back)\n`);

const script = await fs.readFile(path.join(here, "88_supplier_portal_bell.sql"), "utf8");
const batches = script.split(/^\s*GO\s*$/gim).map((b) => b.trim()).filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));

let failures = 0;
const check = (ok, label, extra = "") => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`);
  if (!ok) failures += 1;
};

const tx = new sql.Transaction(pool);
await tx.begin();
const q = async (text) => (await new sql.Request(tx).query(text)).recordset;
const exec = async (proc, input) => {
  const r = new sql.Request(tx);
  if (input !== undefined) r.input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(input));
  return (await r.execute(proc)).recordset ?? [];
};

try {
  // Source counts BEFORE applying, to compare with the seed.
  const [src] = await q(`SELECT
      (SELECT COUNT(*) FROM dbo.debit_note_basic_info  WHERE is_active='Y' AND vendor_sno IS NOT NULL) AS dn,
      (SELECT COUNT(*) FROM dbo.credit_note_basic_info WHERE is_active='Y' AND vendor_sno IS NOT NULL) AS cn,
      (SELECT COUNT(*) FROM dbo.payment_info WHERE is_active='Y' AND vendor_sno IS NOT NULL AND status IN ('Approved','Processed')) AS sched,
      (SELECT COUNT(*) FROM dbo.payment_info WHERE is_active='Y' AND vendor_sno IS NOT NULL AND status = 'Processed') AS paid,
      (SELECT COUNT(*) FROM dbo.payment_info WHERE is_active='Y' AND vendor_sno IS NOT NULL AND status = 'Approved') AS approved`);
  console.log("Source rows:", JSON.stringify(src), "\n");

  for (const b of batches) await new sql.Request(tx).batch(b);
  check(true, `applied ${batches.length} batches inside the transaction`);

  // 1) seeding
  const seeded = Object.fromEntries((await q(`SELECT event_kind, COUNT(*) n, SUM(CAST(silent AS INT)) silent_n, SUM(CASE WHEN delivered_at IS NOT NULL THEN 1 ELSE 0 END) delivered_n FROM dbo.nt_supplier_event_log GROUP BY event_kind`)).map((r) => [r.event_kind, r]));
  check((seeded.DEBIT_NOTE?.n ?? 0) === src.dn, "seed: every active debit note is logged", `${seeded.DEBIT_NOTE?.n ?? 0}/${src.dn}`);
  check((seeded.CREDIT_NOTE?.n ?? 0) === src.cn, "seed: every active credit note is logged", `${seeded.CREDIT_NOTE?.n ?? 0}/${src.cn}`);
  check((seeded.PAY_SCHEDULED?.n ?? 0) === src.sched, "seed: every approved/processed payment has a PAY_SCHEDULED row", `${seeded.PAY_SCHEDULED?.n ?? 0}/${src.sched}`);
  check((seeded.PAY_PAID?.n ?? 0) === src.paid, "seed: every processed payment has a PAY_PAID row", `${seeded.PAY_PAID?.n ?? 0}/${src.paid}`);
  const allSilent = Object.values(seeded).every((r) => r.n === r.silent_n && r.n === r.delivered_n);
  check(allSilent, "seed: all rows are silent AND already delivered (no flood on first run)");

  // 2) a quiet system announces nothing
  let pending = await exec("sp_nt_GetPendingSupplierEvents");
  check(pending.length === 0, "quiet DB: sweep returns nothing", `got ${pending.length}`);

  // 3) simulate brand-new events by forgetting a few seeded rows
  const [dn] = await q(`SELECT TOP 1 n.debit_note_sno, n.debit_note_no, n.vendor_sno, n.total_amount FROM dbo.debit_note_basic_info n WHERE n.is_active='Y' AND n.vendor_sno IS NOT NULL ORDER BY n.debit_note_sno DESC`);
  const [cn] = await q(`SELECT TOP 1 n.credit_note_sno, n.credit_note_no, n.vendor_sno, n.total_amount FROM dbo.credit_note_basic_info n WHERE n.is_active='Y' AND n.vendor_sno IS NOT NULL ORDER BY n.credit_note_sno DESC`);
  const [paidPay] = await q(`SELECT TOP 1 payment_sno, payment_no, vendor_sno FROM dbo.payment_info WHERE is_active='Y' AND vendor_sno IS NOT NULL AND status='Processed' ORDER BY payment_sno DESC`);
  let [apprPay] = await q(`SELECT TOP 1 payment_sno, payment_no, vendor_sno FROM dbo.payment_info WHERE is_active='Y' AND vendor_sno IS NOT NULL AND status='Approved' ORDER BY payment_sno DESC`);
  if (!apprPay && paidPay) {
    // No payment is waiting in Dev right now: flip a copy's status inside the transaction (rolled back with everything else).
    const [other] = await q(`SELECT TOP 1 payment_sno, payment_no, vendor_sno FROM dbo.payment_info WHERE is_active='Y' AND vendor_sno IS NOT NULL AND status='Processed' AND payment_sno <> ${paidPay.payment_sno} ORDER BY payment_sno`);
    if (other) {
      await q(`UPDATE dbo.payment_info SET status='Approved' WHERE payment_sno=${other.payment_sno}`);
      await q(`DELETE FROM dbo.nt_supplier_event_log WHERE ref_sno=${other.payment_sno} AND event_kind IN ('PAY_SCHEDULED','PAY_PAID')`);
      apprPay = other;
      console.log(`(no Approved payment in Dev - temporarily treating ${other.payment_no} as Approved inside the transaction)\n`);
    }
  }
  console.log("Sample rows:", JSON.stringify({ dn, cn, paidPay, apprPay }), "\n");

  const forget = async (kind, sno) => q(`DELETE FROM dbo.nt_supplier_event_log WHERE event_kind='${kind}' AND ref_sno=${sno}`);
  if (dn) await forget("DEBIT_NOTE", dn.debit_note_sno);
  if (cn) await forget("CREDIT_NOTE", cn.credit_note_sno);
  if (paidPay) { await forget("PAY_PAID", paidPay.payment_sno); await forget("PAY_SCHEDULED", paidPay.payment_sno); }
  if (apprPay) await forget("PAY_SCHEDULED", apprPay.payment_sno);
  // Orphan: logged, but its note does not exist (went inactive / was removed) -> NULL ref_no.
  await q(`INSERT INTO dbo.nt_supplier_event_log (event_kind, ref_sno, vendor_sno) VALUES ('DEBIT_NOTE', 2147000000, 1)`);

  pending = await exec("sp_nt_GetPendingSupplierEvents");
  const by = (kind, sno) => pending.find((e) => e.event_kind === kind && e.ref_sno === sno);
  console.log("Pending after simulation:\n", pending.map((e) => `  ${e.event_kind} ${e.ref_no ?? "(orphan)"} v${e.vendor_sno} amount=${e.amount} po=${e.po_no ?? "-"}`).join("\n"), "\n");

  if (dn) {
    const e = by("DEBIT_NOTE", dn.debit_note_sno);
    check(!!e && e.ref_no === dn.debit_note_no && e.vendor_sno === dn.vendor_sno, "new debit note is announced to its supplier with its number", e ? `${e.ref_no} -> v${e.vendor_sno}` : "missing");
    check(!!e && Number(e.amount) === Number(dn.total_amount), "…with the right amount");
  } else console.log("SKIP  no debit notes in Dev");
  if (cn) {
    const e = by("CREDIT_NOTE", cn.credit_note_sno);
    check(!!e && e.ref_no === cn.credit_note_no && e.vendor_sno === cn.vendor_sno, "new credit note is announced to its supplier", e ? `${e.ref_no} -> v${e.vendor_sno}` : "missing");
  } else console.log("SKIP  no credit notes in Dev");
  if (paidPay) {
    const paid = by("PAY_PAID", paidPay.payment_sno);
    check(!!paid && paid.ref_no === paidPay.payment_no && paid.vendor_sno === paidPay.vendor_sno, "payment first seen paid is announced as PAID", paid ? paid.ref_no : "missing");
    check(!by("PAY_SCHEDULED", paidPay.payment_sno), "…and NOT also as scheduled (silent row instead)");
    const [silentSched] = await q(`SELECT silent, delivered_at FROM dbo.nt_supplier_event_log WHERE event_kind='PAY_SCHEDULED' AND ref_sno=${paidPay.payment_sno}`);
    check(silentSched?.silent === true && silentSched.delivered_at !== null, "…its PAY_SCHEDULED row exists, silent + delivered");
  } else console.log("SKIP  no processed payments in Dev");
  if (apprPay) {
    // seeded state for apprPay depends on whether we flipped it; announce only if its SCHEDULED row was forgotten
    const sched = by("PAY_SCHEDULED", apprPay.payment_sno);
    check(!!sched && sched.vendor_sno === apprPay.vendor_sno, "approved payment is announced as SCHEDULED", sched ? sched.ref_no : "missing");
    check(!by("PAY_PAID", apprPay.payment_sno), "…and not as paid");
  } else console.log("SKIP  no approved payments in Dev");
  const orphan = by("DEBIT_NOTE", 2147000000);
  check(!!orphan && orphan.ref_no === null, "event whose note is gone comes back with NULL ref_no (the job closes it unsent)");

  // 4) claimed events are not handed out twice
  const again = await exec("sp_nt_GetPendingSupplierEvents");
  check(again.length === 0, "claimed events are not handed out again within the lease", `got ${again.length}`);

  // 5) …but a failed send is retried once the lease lapses
  await q(`UPDATE dbo.nt_supplier_event_log SET claimed_at = DATEADD(MINUTE, -10, claimed_at) WHERE delivered_at IS NULL`);
  const retried = await exec("sp_nt_GetPendingSupplierEvents");
  check(retried.length === pending.length, "after the lease lapses, undelivered events are handed out again", `${retried.length}/${pending.length}`);

  // 6) delivered stays delivered
  const marked = await exec("sp_nt_MarkSupplierEventsDelivered", { event_snos: retried.map((e) => e.event_sno) });
  check(marked[0]?.marked === retried.length, "mark delivered updates exactly those rows", `${marked[0]?.marked}/${retried.length}`);
  await q(`UPDATE dbo.nt_supplier_event_log SET claimed_at = DATEADD(MINUTE, -10, claimed_at)`);
  const done = await exec("sp_nt_GetPendingSupplierEvents");
  check(done.length === 0, "delivered events are never announced again, even after the lease", `got ${done.length}`);

  // 7) idempotent registration + junk input
  const [dupes] = await q(`SELECT COUNT(*) n FROM (SELECT event_kind, ref_sno FROM dbo.nt_supplier_event_log GROUP BY event_kind, ref_sno HAVING COUNT(*) > 1) d`);
  check(dupes.n === 0, "no duplicate (kind, ref) rows after repeated sweeps");
  const junk = await exec("sp_nt_MarkSupplierEventsDelivered", { event_snos: ["x", null, 999999999] });
  check(junk[0]?.marked === 0, "junk ids in the mark call are ignored", `marked ${junk[0]?.marked}`);

  // 8) the Node job's wording, from real rows
  const { buildSupplierNotification } = await import("../src/supplier/supplierEvents.job.js");
  console.log("\nWording from real rows:");
  for (const e of pending.filter((p) => p.ref_no)) {
    const n = buildSupplierNotification(e);
    console.log(`  [${n.type}] ${n.title} - ${n.message}   -> ${n.data.view}`);
  }
} catch (err) {
  failures += 1;
  console.error("ERROR", err.message);
} finally {
  await tx.rollback();
  const [left] = (await pool.request().query(`SELECT OBJECT_ID('dbo.nt_supplier_event_log') t, OBJECT_ID('dbo.sp_nt_GetPendingSupplierEvents') p1, OBJECT_ID('dbo.sp_nt_MarkSupplierEventsDelivered') p2`)).recordset;
  check(left.t === null && left.p1 === null && left.p2 === null, "rolled back: the table and both procedures do not exist afterwards");
  await pool.close();
}
console.log(failures === 0 ? "\nALL CHECKS PASSED" : `\n${failures} CHECK(S) FAILED`);
process.exit(failures === 0 ? 0 : 1);
