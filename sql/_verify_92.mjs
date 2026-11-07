/**
 * Verifies sql/92_supplier_kyc_modification.sql WITHOUT applying it: every case runs in its own transaction that is always
 * rolled back (a procedure error with XACT_ABORT ends the transaction, so each expected error gets a fresh one).
 *
 *   cd grn-service && node sql/_verify_92.mjs [kyc_basic_info_sno]      (default 122)
 */
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sql from "mssql";
import { configDotenv } from "dotenv";

configDotenv({ quiet: true });
const here = path.dirname(fileURLToPath(import.meta.url));

if (!/dev/i.test(process.env.DATABASE ?? "")) {
  console.error(`Refusing to run: DATABASE is "${process.env.DATABASE}", expected a Dev database.`);
  process.exit(2);
}
const K = Number(process.argv[2] || 122);

const pool = await new sql.ConnectionPool({
  user: process.env.DB_USER, password: process.env.DB_USER_PASSWORD, server: process.env.SERVER,
  database: process.env.DATABASE, port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true }, requestTimeout: 120000,
}).connect();
console.log(`Database: ${process.env.DATABASE} (every change is rolled back), supplier ${K}\n`);

const script = await fs.readFile(path.join(here, "92_supplier_kyc_modification.sql"), "utf8");
const batches = script.split(/^\s*GO\s*$/gim).map((b) => b.trim())
  .filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));

let failures = 0;
const check = (ok, label, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`); if (!ok) failures += 1; };

const AUTH = { file_kind: "AUTHORIZATION", file_name: "authorization.pdf", file_path: "http://localhost:8081/dwl/NON_TRADE_DATAS/KYC_MODIFICATIONS/authorization_test.pdf", file_size: 1234 };

/** Runs fn inside a fresh transaction with sql/92 applied, then rolls back. */
async function inTx(label, fn) {
  const tx = new sql.Transaction(pool);
  await tx.begin();
  const q = async (text) => (await new sql.Request(tx).query(text)).recordset;
  const run = async (proc, input) => (await new sql.Request(tx).input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(input)).execute(proc)).recordsets;
  const full = async (id) => (await new sql.Request(tx).input("source", sql.VarChar(12), "KYC").input("record_id", sql.Int, id).execute("sp_nt_GetSupplierFullDetails")).recordsets;
  try {
    const before = await full(K);
    for (const b of batches) await new sql.Request(tx).batch(b);
    await fn({ q, run, full, before });
  } finally {
    try { await tx.rollback(); } catch { /* an error inside the procedure already ended it */ }
  }
  console.log(`      (${label}: rolled back)\n`);
}

/** Expects `promise` to fail with error number `num`. */
async function expectError(promise, num, label) {
  try {
    await promise;
    check(false, label, "no error raised");
  } catch (e) {
    check(e.number === num, label, `-> ${e.number}: ${e.message}`);
  }
}

async function load(run) {
  const [[head], history, businessTypes, accountTypes] = await run("sp_nt_GetSupplierOwnKyc", { kyc_basic_info_sno: K });
  return { head, snap: JSON.parse(head.snapshot), history, businessTypes, accountTypes };
}

/** The change form, filled with the KYC exactly as it is. */
function formFrom(head, snap, extra = {}) {
  const b = snap.basic, p = snap.payment;
  return {
    kyc_basic_info_sno: K, snapshot_hash: head.snapshot_hash, reason: "Verification run", modified_by: "verify@example.com",
    modified_by_code: head.supp_code,
    basic: {
      company_name: b.company_name, legal_name: b.legal_name, trade_name: b.trade_name, contact_person: b.contact_person,
      email: b.email, mobile_number: b.mobile_number, business_type: b.business_type,
      is_gst_avail: b.is_gst_avail, gst_no: b.gst_no, is_msme_avail: b.is_msme_avail, msme_no: b.msme_no, msme_type: b.msme_type,
      pay_via_portal: p.pay_via_portal, payment_portal_name: p.payment_portal_name, payment_portal_url: p.payment_portal_url,
      payment_instructions: p.payment_instructions,
    },
    addresses: snap.addresses.map((a) => ({ ...a })),
    banks: snap.banks.map((x) => ({ ...x })),
    contacts: snap.contacts.map((c) => ({ ...c, is_primary: c.contact_type === "PRIMARY" ? "Y" : "N" })),
    documents: [],
    files: [AUTH],
    ...extra,
  };
}

const otherCounts = async (q) => (await q(`SELECT
    (SELECT COUNT(*) FROM dbo.kyc_address_info WHERE kyc_basic_info_sno <> ${K} AND ISNULL(is_active,'Y') <> 'N') a,
    (SELECT COUNT(*) FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno <> ${K} AND ISNULL(is_active,'Y') <> 'N') b,
    (SELECT COUNT(*) FROM dbo.kyc_contact_info WHERE kyc_basic_info_sno <> ${K} AND ISNULL(is_active,'Y') <> 'N') c,
    (SELECT COUNT(*) FROM dbo.kyc_document_info WHERE kyc_basic_info_sno <> ${K} AND ISNULL(is_active,'Y') <> 'N') d,
    (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno <> ${K}) k`))[0];

try {
  // ---------------------------------------------------------------- A: a change across every section, then a second one
  await inTx("A happy path", async ({ q, run, full, before }) => {
    check(true, `applied ${batches.length} batches`);
    const { head, snap, history, businessTypes, accountTypes } = await load(run);
    check(!!head && head.snapshot_hash?.length === 64, "own KYC loads with a 64-char hash", `${snap.addresses.length} addr, ${snap.banks.length} bank, ${snap.contacts.length} contact, ${snap.documents.length} doc`);
    check(history.length === 0, "no change history yet");
    check(businessTypes.length > 0 && accountTypes.length > 0, "form choices load", `${businessTypes.length} business types, ${accountTypes.length} account types`);
    const again = await load(run);
    check(again.head.snapshot === head.snapshot && again.head.snapshot_hash === head.snapshot_hash, "snapshot is stable between two reads");

    const others0 = await otherCounts(q);
    const primary = snap.addresses.find((a) => a.is_primary === "Y") ?? snap.addresses[0];
    const secondary = snap.addresses.find((a) => a !== primary);
    const form = formFrom(head, snap);
    form.basic.contact_person = "Verify Person";
    form.addresses = [
      { ...primary, is_primary: "Y", city: `${primary.city} City` },
      { door_no: "12", street: "New Street", area: "New Area", city: "Coimbatore", taluk: "", state: "Tamil Nadu", state_code: 33, pincode: "641001", location_link: "", is_primary: "N" },
    ];
    form.banks = [
      ...snap.banks.map((x, i) => (i === 0 ? { ...x, ac_holder_name: "VERIFY HOLDER" } : x)),
      { ac_holder_name: "NEW ACCOUNT", ac_number: "123456789012", ac_type: "2", ifsc: "hdfc0000001", bank_name: "HDFC BANK", bank_branch_name: "RS PURAM", bank_address: "Coimbatore", is_primary: snap.banks.length ? "N" : "Y" },
    ];
    form.contacts = [...form.contacts, { contact_name: "Second Contact", contact_position: "Accounts", contact_mobile: "9000000001", contact_email: "acc@example.com", is_primary: "N" }];
    form.documents = [{ document_type: "gst_file", document_name: "GST certificate.pdf", document_path: "http://localhost:8081/dwl/NON_TRADE_DATAS/KYC_DATAS/gst_new.pdf", file_size: 99 }];
    form.files = [AUTH, { file_kind: "gst_file", file_name: "GST certificate.pdf", file_path: form.documents[0].document_path, file_size: 99 }];

    const [[res]] = await run("sp_nt_SupplierModifyKyc", form);
    check(res?.version_no === 1, "change saved as version 1", JSON.stringify(res));
    check(res?.changed_sections === "BASIC,ADDRESS,BANK,CONTACT,DOCUMENT", "changed sections", res?.changed_sections);

    const [m] = await q(`SELECT * FROM dbo.kyc_modified_data WHERE kyc_modified_sno = ${res.kyc_modified_sno}`);
    check(m.old_data === head.snapshot, "old_data is exactly the KYC before the change");
    const [{ now }] = await q(`SELECT dbo.fn_nt_KycSnapshot(${K}) now`);
    check(m.new_data === now, "new_data is exactly the KYC after the change");
    check(m.reason === "Verification run" && m.modified_by === "verify@example.com" && m.source === "SUPPLIER_PORTAL", "reason / who / source stored");
    const files = await q(`SELECT file_kind FROM dbo.kyc_modified_data_file WHERE kyc_modified_sno = ${res.kyc_modified_sno} ORDER BY kyc_modified_file_sno`);
    check(files.map((f) => f.file_kind).join(",") === "AUTHORIZATION,gst_file", "both uploaded files stored", files.map((f) => f.file_kind).join(","));

    const nowSnap = JSON.parse(now);
    check(nowSnap.basic.contact_person === "Verify Person", "contact person updated");
    check(nowSnap.addresses.length === 2 && nowSnap.addresses.some((a) => a.kyc_address_sno === primary.kyc_address_sno && a.city === `${primary.city} City`), "primary address updated in place (same sno)");
    if (secondary) {
      const [s] = await q(`SELECT is_active FROM dbo.kyc_address_info WHERE kyc_address_sno = ${secondary.kyc_address_sno}`);
      check(s.is_active === "N", "address left out of the form is deactivated, not deleted");
    }
    const added = nowSnap.addresses.find((a) => a.kyc_address_sno !== primary.kyc_address_sno);
    check(added?.address_type === "SECONDARY" && added?.is_primary === "N" && added?.state_code === 33, "new address added as SECONDARY", JSON.stringify(added));
    check(nowSnap.banks.length === snap.banks.length + 1 && nowSnap.banks.some((x) => x.ac_number === "123456789012" && x.ifsc === "HDFC0000001"), "new bank added (IFSC upper-cased, account as text)");
    if (snap.banks.length) check(nowSnap.banks.find((x) => x.kyc_bank_sno === snap.banks[0].kyc_bank_sno)?.ac_holder_name === "VERIFY HOLDER", "existing bank updated in place");
    check(nowSnap.contacts.length === snap.contacts.length + 1 && nowSnap.contacts.some((c) => c.contact_type === "SECONDARY"), "second contact added");
    const gst = nowSnap.documents.filter((d) => d.document_type === "gst_file");
    check(gst.length === 1 && gst[0].document_path.endsWith("gst_new.pdf"), "new GST certificate replaced the old one");
    const [kb] = await q(`SELECT modified_by, DATEDIFF(SECOND, modified_date, GETDATE()) age, pan_no, supp_code, status FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = ${K}`);
    check(kb.modified_by === head.supp_code.slice(0, 20) && kb.age < 60, "kyc_basic_info.modified_by / modified_date set", JSON.stringify(kb));
    check(kb.pan_no === snap.basic.pan_no && kb.supp_code === head.supp_code && kb.status === head.status, "PAN, supplier code, status untouched");
    const others1 = await otherCounts(q);
    check(JSON.stringify(others0) === JSON.stringify(others1), "no other supplier's rows changed");

    // staff view: RS1-RS6 unchanged in shape, RS7 = the change
    const after = await full(K);
    check(after.length === 7 && before.length === 6, "full details: 6 result sets before, 7 after");
    const cols = (rs) => Object.keys(rs.columns ?? {}).join(",");
    check(before.every((rs, i) => cols(rs) === cols(after[i])), "RS1-RS6 have the same columns as before");
    check(after[6].length === 1 && after[6][0].version_no === 1 && JSON.parse(after[6][0].files).length === 2, "RS7 lists the change with its files");
    const [fullOther] = await full(99);
    check(fullOther.length === 1, "full details still works for a supplier with no changes");
    const mine = await load(run);
    check(mine.history.length === 1 && mine.head.snapshot === now, "own KYC shows the new values and one change");

    // second change: GST number, and a case-only edit counts as a change
    const f2 = formFrom(mine.head, mine.snap);
    const pan = (mine.snap.basic.pan_no || "AAAAA0000A").slice(0, 10);
    f2.basic.is_gst_avail = "Y";
    f2.basic.gst_no = `33${pan}1Z5`.toLowerCase();
    f2.addresses = f2.addresses.map((a) => (a.is_primary === "Y" ? { ...a, city: a.city.toUpperCase() } : a));
    const [[r2]] = await run("sp_nt_SupplierModifyKyc", f2);
    check(r2.version_no === 2 && r2.changed_sections === "BASIC,ADDRESS", "second change = version 2, BASIC,ADDRESS (case-only city edit counted)", r2.changed_sections);
    const [g] = await q(`SELECT gst_no, gst_status, gst_blk_status, txp_type, date_of_reg FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = ${K}`);
    check(g.gst_no === `33${pan}1Z5`.toUpperCase() && g.gst_status === null && g.gst_blk_status === null && g.txp_type === null && g.date_of_reg === null,
      "new GST number saved upper-case; old GSTIN lookup values cleared", JSON.stringify(g));
    const hist = await load(run);
    check(hist.history.map((h) => h.version_no).join(",") === "2,1", "history newest first");

    // the first form again (stale hash) - must be refused, not overwrite (ends this transaction)
    await expectError(run("sp_nt_SupplierModifyKyc", { ...form, reason: "stale" }), 58611, "form opened before the last change is refused");
  });

  // ---------------------------------------------------------------- errors, one transaction each
  const errorCase = async (label, num, mutate) => inTx(label, async ({ run }) => {
    const { head, snap } = await load(run);
    const form = formFrom(head, snap);
    form.basic.contact_person = "Changed";
    await expectError(run("sp_nt_SupplierModifyKyc", mutate(form, snap, head) ?? form), num, label);
  });

  await errorCase("no authorization letter", 58605, (f) => { f.files = [{ ...AUTH, file_kind: "gst_file" }]; });
  await errorCase("no reason", 58602, (f) => { f.reason = "   "; });
  await errorCase("nothing changed", 58612, (f, snap) => { f.basic.contact_person = snap.basic.contact_person; });
  await errorCase("two primary addresses", 58606, (f) => { f.addresses = f.addresses.map((a) => ({ ...a, is_primary: "Y" })); if (f.addresses.length < 2) f.addresses.push({ ...f.addresses[0], kyc_address_sno: null }); });
  await errorCase("someone else's bank account", 58609, (f) => {
    f.basic.pay_via_portal = "N";
    f.banks = [{ kyc_bank_sno: 97, ac_holder_name: "X", ac_number: "1234567", ac_type: "2", ifsc: "KKBK0000961", bank_name: "B", bank_branch_name: "BR", bank_address: "A", is_primary: "Y" }];
  });
  await errorCase("same address twice", 58609, (f) => { f.addresses = [...f.addresses, { ...f.addresses[0], is_primary: "N" }]; });
  await errorCase("no primary contact", 58608, (f) => { f.contacts = f.contacts.map((c) => ({ ...c, is_primary: "N" })); });
  await errorCase("unknown document type", 58610, (f) => { f.documents = [{ document_type: "aadhaar", document_name: "x", document_path: "http://x/y.pdf" }]; });
  await errorCase("portal without a URL", 58604, (f) => { f.basic.pay_via_portal = "Y"; f.basic.payment_portal_name = "Our portal"; f.basic.payment_portal_url = ""; });
  await errorCase("wrong hash", 58611, (f) => { f.snapshot_hash = "0".repeat(64); });
  await inTx("unknown supplier", async ({ run }) => {
    await expectError(run("sp_nt_GetSupplierOwnKyc", { kyc_basic_info_sno: 99999999 }), 58601, "own KYC of an unknown supplier");
  });

  // ---------------------------------------------------------------- switching to portal payment deactivates the bank accounts
  await inTx("switch to portal", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const form = formFrom(head, snap);
    form.basic.pay_via_portal = "Y";
    form.basic.payment_portal_name = "Supplier portal";
    form.basic.payment_portal_url = "https://pay.example.com";
    const [[r]] = await run("sp_nt_SupplierModifyKyc", form);
    const [{ n }] = await q(`SELECT COUNT(*) n FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = ${K} AND ISNULL(is_active,'Y') <> 'N'`);
    check(r.changed_sections === (snap.banks.length ? "PAYMENT,BANK" : "PAYMENT") && n === 0, "portal chosen: PAYMENT (+BANK) changed, no active bank account left", `${r.changed_sections}, active banks ${n}`);
    const [k] = await q(`SELECT pay_via_portal, payment_portal_url FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = ${K}`);
    check(k.pay_via_portal === "Y" && k.payment_portal_url === "https://pay.example.com", "portal details saved");
  });

  const [{ leftover }] = (await pool.request().query(`SELECT COUNT(*) leftover FROM sys.objects WHERE name IN ('kyc_modified_data','kyc_modified_data_file','fn_nt_KycSnapshot','sp_nt_GetSupplierOwnKyc','sp_nt_SupplierModifyKyc')`)).recordset;
  check(leftover === 0, "nothing from sql/92 is left on the database");
} catch (e) {
  failures += 1;
  console.error("UNEXPECTED", e.number ?? "", e.message);
} finally {
  await pool.close();
}
console.log(failures ? `\n${failures} check(s) FAILED` : "\nAll checks passed");
process.exit(failures ? 1 : 0);
