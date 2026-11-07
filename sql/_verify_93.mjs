/**
 * Verifies sql/93_supplier_kyc_change_approval.sql WITHOUT applying it: every case runs in its own transaction that is always
 * rolled back (a procedure error with XACT_ABORT ends the transaction, so each expected error gets a fresh one).
 * sql/92 must already be on the database (it is: the change request builds on its tables and snapshot function).
 *
 *   cd grn-service && node sql/_verify_93.mjs [kyc_basic_info_sno]      (default 122)
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

const script = await fs.readFile(path.join(here, "93_supplier_kyc_change_approval.sql"), "utf8");
const batches = script.split(/^\s*GO\s*$/gim).map((b) => b.trim())
  .filter((b) => b && !b.split("\n").every((l) => !l.trim() || l.trim().startsWith("--")));

// changes this supplier already has on the database (a real one may exist): every version / count below is relative to them
const hasStatus = (await pool.request().query(`SELECT COL_LENGTH('dbo.kyc_modified_data', 'status') c`)).recordset[0].c !== null;
const [{ BASE_V, BASE_N, BASE_A, BASE_P }] = (await pool.request().query(hasStatus
  ? `SELECT ISNULL(MAX(version_no), 0) BASE_V, COUNT(*) BASE_N, SUM(CASE WHEN status = 'A' THEN 1 ELSE 0 END) BASE_A, SUM(CASE WHEN status = 'P' THEN 1 ELSE 0 END) BASE_P FROM dbo.kyc_modified_data WHERE kyc_basic_info_sno = ${K}`
  : `SELECT ISNULL(MAX(version_no), 0) BASE_V, COUNT(*) BASE_N, COUNT(*) BASE_A, 0 BASE_P FROM dbo.kyc_modified_data WHERE kyc_basic_info_sno = ${K}`)).recordset;
console.log(`Existing changes for supplier ${K}: ${BASE_N} (latest version ${BASE_V}); ${BASE_P} of them waiting for approval - set aside inside each rolled-back transaction`);

// what is on the database before the run, to prove the run leaves it exactly so (sql/93 may already be applied for real)
const shape = async () => (await pool.request().query(`SELECT
  (SELECT COUNT(*) FROM sys.objects WHERE name IN ('kyc_modified_approval','sp_nt_ApplyKycChange','sp_nt_WithdrawKycChange','sp_nt_GetKycChangeApprovals','sp_nt_KycChangeAct')) objs,
  (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('dbo.kyc_modified_data') AND name IN ('status','payload','stages_json','current_seq')) cols,
  (SELECT COUNT(*) FROM dbo.kyc_modified_data) rows_,
  (SELECT ISNULL(SUM(CASE WHEN COL_LENGTH('dbo.kyc_modified_data','status') IS NULL THEN 0 ELSE 1 END), 0)) hasStatus,
  (SELECT COUNT(*) FROM dbo.nt_user_permissions_json) users_,
  (SELECT MAX(modify_date) FROM sys.objects WHERE name = 'sp_nt_SupplierModifyKyc') proc_modified`)).recordset[0];
const shapeBefore = await shape();

// the first approver of the supplier-change workflow, as it is configured on this database
const [{ stages, wf }] = (await pool.request().query(`
  SELECT (SELECT JSON_VALUE(s.value, '$.stage_order_json') FROM dbo.vw_workflow_stages ws CROSS APPLY OPENJSON(ws.stages_json) s
          WHERE ws.workflow_types_id = dbo.fn_scopeless_workflow_types('KYC') AND s.[key] = '0') AS stages,
         dbo.fn_scopeless_workflow_types('KYC') AS wf`)).recordset;
const stageList = JSON.parse(stages);
const APPROVER = stageList[0].approver_ecno;
const STAGE = stageList[0].stage;
console.log(`KYC workflow ${wf}: ${stageList.length} stage(s), first approver ${APPROVER} (${STAGE})\n`);

let failures = 0;
const check = (ok, label, extra = "") => { console.log(`${ok ? "PASS" : "FAIL"}  ${label}${extra ? `  ${extra}` : ""}`); if (!ok) failures += 1; };

const AUTH = { file_kind: "AUTHORIZATION", file_name: "authorization.pdf", file_path: "http://localhost:8081/dwl/NON_TRADE_DATAS/KYC_MODIFICATIONS/authorization_test.pdf", file_size: 1234 };

/** Runs fn inside a fresh transaction with sql/93 applied, then rolls back. */
async function inTx(label, fn, { apply = true } = {}) {
  const tx = new sql.Transaction(pool);
  await tx.begin();
  const q = async (text) => (await new sql.Request(tx).query(text)).recordset;
  const run = async (proc, input) => (await new sql.Request(tx).input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify(input)).execute(proc)).recordsets;
  const full = async (id) => (await new sql.Request(tx).input("source", sql.VarChar(12), "KYC").input("record_id", sql.Int, id).execute("sp_nt_GetSupplierFullDetails")).recordsets;
  try {
    const before = await full(K);
    if (apply) for (const b of batches) await new sql.Request(tx).batch(b);
    // a real request may be waiting on this database: set it aside (inside this transaction only) so a new one can be made
    if (apply) await q(`UPDATE dbo.kyc_modified_data SET status = 'C', decision_note = N'set aside by the verification run' WHERE kyc_basic_info_sno = ${K} AND status = 'P'`);
    await fn({ q, run, full, before, tx });
  } finally {
    try { await tx.rollback(); } catch { /* an error inside the procedure already ended it */ }
  }
  console.log(`      (${label}: rolled back)\n`);
}

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

/** A change across every section. */
function bigChange(head, snap) {
  const primary = snap.addresses.find((a) => a.is_primary === "Y") ?? snap.addresses[0];
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
  return { form, primary };
}

const submit = async (run, form) => (await run("sp_nt_SupplierModifyKyc", form))[0][0];
const act = async (run, input) => (await run("sp_nt_KycChangeAct", input))[0][0];
const liveSnapshot = async (q) => (await q(`SELECT dbo.fn_nt_KycSnapshot(${K}) s`))[0].s;

try {
  // ------------------------------------------------------------ A: submit -> pending, live KYC untouched
  await inTx("A submit", async ({ q, run, full, before }) => {
    check(true, `applied ${batches.length} batches`);
    const { head, snap } = await load(run);
    check(head.pending_sno === null && head.pending_stage_total === 0, "no request waiting before the submit");
    check((await q(`SELECT COUNT(*) n FROM dbo.kyc_modified_data WHERE kyc_basic_info_sno = ${K} AND status = 'A'`))[0].n === BASE_A, "changes made before sql/93 are marked applied (A)");
    const liveBefore = await liveSnapshot(q);
    const [{ addrs, banks, conts, docs }] = await q(`SELECT
      (SELECT COUNT(*) FROM dbo.kyc_address_info WHERE kyc_basic_info_sno = ${K}) addrs, (SELECT COUNT(*) FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = ${K}) banks,
      (SELECT COUNT(*) FROM dbo.kyc_contact_info WHERE kyc_basic_info_sno = ${K}) conts, (SELECT COUNT(*) FROM dbo.kyc_document_info WHERE kyc_basic_info_sno = ${K}) docs`);

    const { form } = bigChange(head, snap);
    const r = await submit(run, form);
    check(r.status === "P" && r.version_no === BASE_V + 1 && r.stage_no === 1 && r.stage_total === stageList.length, "submit -> pending request with the next version number, stage 1", JSON.stringify(r));
    check(r.current_approver_ecno === APPROVER && r.stage_name === STAGE, "first approver and stage name come from the workflow", `${r.current_approver_ecno} / ${r.stage_name}`);
    check(r.changed_sections === "BASIC,ADDRESS,BANK,CONTACT,DOCUMENT", "changed sections", r.changed_sections);

    check((await liveSnapshot(q)) === liveBefore, "the LIVE KYC is exactly as before (the trial apply was rolled back)");
    const [after] = await q(`SELECT
      (SELECT COUNT(*) FROM dbo.kyc_address_info WHERE kyc_basic_info_sno = ${K}) addrs, (SELECT COUNT(*) FROM dbo.kyc_bank_info WHERE kyc_basic_info_sno = ${K}) banks,
      (SELECT COUNT(*) FROM dbo.kyc_contact_info WHERE kyc_basic_info_sno = ${K}) conts, (SELECT COUNT(*) FROM dbo.kyc_document_info WHERE kyc_basic_info_sno = ${K}) docs`);
    check(after.addrs === addrs && after.banks === banks && after.conts === conts && after.docs === docs, "no row was added to the live KYC tables", JSON.stringify(after));

    const [m] = await q(`SELECT * FROM dbo.kyc_modified_data WHERE kyc_modified_sno = ${r.kyc_modified_sno}`);
    check(m.old_data === liveBefore, "old_data = the KYC as it is now");
    const proposed = JSON.parse(m.new_data);
    check(m.new_data !== m.old_data && proposed.basic.contact_person === "Verify Person" && proposed.addresses.length === 2 && proposed.banks.some((x) => x.ac_number === "123456789012" && x.ifsc === "HDFC0000001"),
      "new_data = the KYC as it WOULD be (proposed values, IFSC upper-cased)");
    check(m.status === "P" && m.workflow_types_id === wf && m.current_seq === 1 && m.base_hash?.length === 64 && JSON.parse(m.payload).reason === "Verification run" && JSON.parse(m.stages_json).length === stageList.length,
      "request keeps status, workflow, stage, base hash, payload and a copy of the stages");
    const files = await q(`SELECT file_kind FROM dbo.kyc_modified_data_file WHERE kyc_modified_sno = ${r.kyc_modified_sno} ORDER BY kyc_modified_file_sno`);
    check(files.map((f) => f.file_kind).join(",") === "AUTHORIZATION,gst_file", "authorization letter + new document stored with the request");

    const mine = await load(run);
    check(mine.head.pending_sno === r.kyc_modified_sno && mine.head.pending_version === BASE_V + 1 && mine.head.pending_stage_no === 1 && mine.head.pending_stage_name === STAGE && mine.head.pending_since,
      "own KYC shows the waiting request and its stage", `${mine.head.pending_stage_name} ${mine.head.pending_stage_no}/${mine.head.pending_stage_total}`);
    check(mine.head.snapshot_hash === head.snapshot_hash && mine.snap.basic.contact_person === snap.basic.contact_person, "own KYC still shows the OLD values and the same hash");
    check(mine.history.length === BASE_N + 1 && mine.history[0].status === "P" && JSON.parse(mine.history[0].approvals ?? "[]").length === 0 && JSON.parse(mine.history[0].files).length === 2, "history lists it as P with no approvals yet");

    const fd = await full(K);
    check(fd.length === 7 && fd[6].length === BASE_N + 1 && fd[6][0].status === "P" && fd[6][0].current_approver_ecno === APPROVER && fd[6][0].stage_total === stageList.length, "staff full details RS7 carries status / approver / stage");
    const cols = (rs) => Object.keys(rs.columns ?? {}).join(",");
    check(before.slice(0, 6).every((rs, i) => cols(rs) === cols(fd[i])), "RS1-RS6 have the same columns as before sql/93");

    // a second request while one waits is refused (ends this transaction)
    const next = await load(run);
    await expectError(run("sp_nt_SupplierModifyKyc", { ...formFrom(next.head, next.snap, { reason: "again" }), basic: { ...formFrom(next.head, next.snap).basic, contact_person: "Another" } }), 58614, "a second request while one is waiting is refused");
  });

  // ------------------------------------------------------------ B: single-stage approval applies the change
  await inTx("B approve", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const liveBefore = await liveSnapshot(q);
    const { form, primary } = bigChange(head, snap);
    const secondary = snap.addresses.find((a) => a !== primary);
    const r = await submit(run, form);
    const lowerAndTrimmed = ` ${APPROVER.toLowerCase()} `;

    if (stageList.length > 1) {
      console.log("      (workflow has several stages: the one-stage shortcut is covered in case C)");
      return;
    }
    const done = await act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: lowerAndTrimmed, action: "approve", note: "Looks right" });
    check(done.status === "A" && done.next_approver_ecno === null && done.supp_code === head.supp_code, "approve at the only stage -> applied", JSON.stringify(done));

    const [m] = await q(`SELECT * FROM dbo.kyc_modified_data WHERE kyc_modified_sno = ${r.kyc_modified_sno}`);
    check(m.old_data === liveBefore, "old_data is still the KYC from before the change");
    check(m.new_data === await liveSnapshot(q), "new_data = the live KYC now (real ids)");
    check(m.status === "A" && m.decided_by?.toLowerCase() === APPROVER.toLowerCase() && m.decided_date && m.decision_note === "Looks right", "decision stored", `${m.decided_by}`);

    const now = JSON.parse(await liveSnapshot(q));
    check(now.basic.contact_person === "Verify Person", "contact person updated");
    check(now.addresses.length === 2 && now.addresses.some((a) => a.kyc_address_sno === primary.kyc_address_sno && a.city === `${primary.city} City`), "primary address updated in place (same sno)");
    if (secondary) check((await q(`SELECT is_active FROM dbo.kyc_address_info WHERE kyc_address_sno = ${secondary.kyc_address_sno}`))[0].is_active === "N", "address left out is deactivated, not deleted");
    check(now.banks.some((x) => x.ac_number === "123456789012") && now.banks.length === snap.banks.length + 1, "new bank account added");
    check(now.documents.filter((d) => d.document_type === "gst_file").length === 1 && now.documents.find((d) => d.document_type === "gst_file").document_path.endsWith("gst_new.pdf"), "new GST certificate replaced the old one");
    const [kb] = await q(`SELECT modified_by, DATEDIFF(SECOND, modified_date, GETDATE()) age, pan_no, supp_code, status FROM dbo.kyc_basic_info WHERE kyc_basic_info_sno = ${K}`);
    check(kb.modified_by.toLowerCase() === APPROVER.toLowerCase().slice(0, 20) && kb.age < 60 && kb.pan_no === snap.basic.pan_no && kb.supp_code === head.supp_code && kb.status === head.status, "kyc_basic_info: modified by the approver; PAN, code, status untouched", JSON.stringify(kb));

    const trail = await q(`SELECT seq_no, stage_name, approver_ecno, action, note FROM dbo.kyc_modified_approval WHERE kyc_modified_sno = ${r.kyc_modified_sno}`);
    check(trail.length === 1 && trail[0].action === "A" && trail[0].seq_no === 1 && trail[0].note === "Looks right", "approval trail has the action", JSON.stringify(trail));

    const mine = await load(run);
    check(mine.head.pending_sno === null && mine.history[0].status === "A" && JSON.parse(mine.history[0].approvals).length === 1, "supplier: nothing waiting any more; history shows A with its trail");
    check(mine.snap.basic.contact_person === "Verify Person" && mine.head.snapshot_hash !== head.snapshot_hash, "supplier now sees the NEW values (and a new hash)");

    // the supplier can make another change now
    const f2 = formFrom(mine.head, mine.snap);
    f2.basic.contact_person = "Second Round";
    const r2 = await submit(run, f2);
    check(r2.version_no === BASE_V + 2 && r2.status === "P", "a new request is possible once the last one is decided (next version)");
  });

  // ------------------------------------------------------------ C: several stages
  await inTx("C two stages", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    const second = APPROVER === "KTM1148" ? "KTM1006" : "KTM1148";
    const twoStages = JSON.stringify([{ approver_ecno: APPROVER, stage: "Stage one" }, { approver_ecno: second, stage: "Stage two" }]);
    await q(`UPDATE dbo.kyc_modified_data SET stages_json = N'${twoStages.replace(/'/g, "''")}' WHERE kyc_modified_sno = ${r.kyc_modified_sno}`);
    const liveBefore = await liveSnapshot(q);

    const s1 = await act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "approve", note: "ok 1" });
    check(s1.status === "P" && s1.stage_no === 2 && s1.stage_total === 2 && s1.next_approver_ecno === second && s1.next_stage_name === "Stage two", "approve stage 1 -> waits at stage 2 for the next approver", JSON.stringify(s1));
    check((await liveSnapshot(q)) === liveBefore, "the live KYC is still unchanged after stage 1");
    const mid = await load(run);
    check(mid.head.pending_stage_no === 2 && mid.head.pending_stage_name === "Stage two" && JSON.parse(mid.history[0].approvals).length === 1, "supplier sees stage 2 of 2 and one approval so far");

    const inbox1 = await run("sp_nt_GetKycChangeApprovals", { ecno: APPROVER });
    const inbox2 = await run("sp_nt_GetKycChangeApprovals", { ecno: second.toLowerCase() });
    check(inbox1[0].length === 0 && inbox1[1].length === 1 && inbox1[1][0].status === "P", "stage 1 approver: nothing waiting, one in 'I have acted' (still in progress)");
    check(inbox2[0].length === 1 && inbox2[0][0].is_mine === true && inbox2[0][0].stage_name === "Stage two", "stage 2 approver (any case) has it waiting");

    const s2 = await act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: second.toLowerCase(), action: "approve" });
    check(s2.status === "A", "approve the last stage -> applied", JSON.stringify(s2));
    check(JSON.parse(await liveSnapshot(q)).basic.contact_person === "Verify Person", "the change is live now");
    const trail = await q(`SELECT seq_no, action FROM dbo.kyc_modified_approval WHERE kyc_modified_sno = ${r.kyc_modified_sno} ORDER BY kyc_modified_approval_sno`);
    check(trail.map((t) => `${t.seq_no}${t.action}`).join(",") === "1A,2A", "trail has both approvals in order", JSON.stringify(trail));
    const done = await run("sp_nt_GetKycChangeApprovals", { ecno: second });
    check(done[0].length === 0 && done[1].length === 1 && done[1][0].status === "A" && JSON.parse(done[1][0].approvals).length === 2, "last approver's history lists it as applied, with the full trail");
  });

  // wrong person (own tx: the error ends it)
  await inTx("C2 wrong approver", async ({ run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    await expectError(act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: "ZZ999", action: "approve" }), 58618, "someone who is not the current approver is refused");
  });
  await inTx("C3 not waiting for the same person twice", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    const second = APPROVER === "KTM1148" ? "KTM1006" : "KTM1148";
    await q(`UPDATE dbo.kyc_modified_data SET stages_json = N'${JSON.stringify([{ approver_ecno: APPROVER, stage: "One" }, { approver_ecno: second, stage: "Two" }])}' WHERE kyc_modified_sno = ${r.kyc_modified_sno}`);
    await act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "approve" });
    await expectError(act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "approve" }), 58618, "the stage-1 approver cannot approve again at stage 2");
  });
  await inTx("C4 stage without an approver", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    await q(`UPDATE dbo.kyc_modified_data SET stages_json = N'${JSON.stringify([{ approver_ecno: APPROVER, stage: "One" }, { approver_ecno: "", stage: "Two" }])}' WHERE kyc_modified_sno = ${r.kyc_modified_sno}`);
    await expectError(act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "approve" }), 58620, "an empty next stage is refused with a clear message");
  });

  // ------------------------------------------------------------ D: reject, then send again
  await inTx("D reject", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const liveBefore = await liveSnapshot(q);
    const r = await submit(run, bigChange(head, snap).form);
    const rej = await act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "reject", note: "Letter is not signed" });
    check(rej.status === "R" && rej.decision_note === "Letter is not signed", "reject -> R with the note", JSON.stringify(rej));
    check((await liveSnapshot(q)) === liveBefore, "the live KYC is unchanged after a reject");
    const mine = await load(run);
    check(mine.head.pending_sno === null && mine.history[0].status === "R" && mine.history[0].decision_note === "Letter is not signed" && JSON.parse(mine.history[0].approvals)[0].action === "R", "supplier sees the rejection, the reason and the trail");
    const again = await submit(run, { ...bigChange(mine.head, mine.snap).form, reason: "Signed letter attached" });
    check(again.version_no === BASE_V + 2 && again.status === "P", "the supplier can send it again after a reject (next version)");
    await expectError(act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "approve" }), 58617, "a rejected request cannot be approved afterwards");
  });
  await inTx("D2 reject needs a note", async ({ run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    await expectError(act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "reject", note: "  " }), 58619, "a reject without a note is refused");
  });

  // ------------------------------------------------------------ E: withdraw
  await inTx("E withdraw", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    const w = (await run("sp_nt_WithdrawKycChange", { kyc_basic_info_sno: K, kyc_modified_sno: r.kyc_modified_sno, by: "verify@example.com" }))[0][0];
    check(w.status === "C" && w.current_approver_ecno === APPROVER && w.company_name, "withdraw -> C (and who was waiting, for the alert)", JSON.stringify(w));
    const mine = await load(run);
    check(mine.head.pending_sno === null && mine.history[0].status === "C" && mine.history[0].decision_note === "Withdrawn by the supplier", "history shows it withdrawn");
    const inbox = await run("sp_nt_GetKycChangeApprovals", { ecno: APPROVER });
    check(inbox[0].length === 0, "it left the approver's waiting list");
    const again = await submit(run, bigChange(mine.head, mine.snap).form);
    check(again.version_no === BASE_V + 2, "a new request can be made after a withdraw");
    await expectError(act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "approve" }), 58617, "a withdrawn request cannot be approved");
  });
  await inTx("E2 withdraw someone else's / twice", async ({ run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    await expectError(run("sp_nt_WithdrawKycChange", { kyc_basic_info_sno: 99, kyc_modified_sno: r.kyc_modified_sno, by: "other" }), 58615, "another supplier cannot withdraw it");
  });
  await inTx("E3 withdraw twice", async ({ run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    await run("sp_nt_WithdrawKycChange", { kyc_basic_info_sno: K, kyc_modified_sno: r.kyc_modified_sno, by: "v" });
    await expectError(run("sp_nt_WithdrawKycChange", { kyc_basic_info_sno: K, kyc_modified_sno: r.kyc_modified_sno, by: "v" }), 58615, "a request that is no longer waiting cannot be withdrawn");
  });

  // ------------------------------------------------------------ F: the KYC moved on while the request waited
  await inTx("F stale at the last stage", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    await q(`UPDATE dbo.kyc_basic_info SET trade_name = N'Changed elsewhere' WHERE kyc_basic_info_sno = ${K}`);
    await expectError(act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "approve" }), 58621, "final approval is refused when the live KYC changed after the request");
  });
  await inTx("F2 stale request can still be rejected", async ({ q, run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    await q(`UPDATE dbo.kyc_basic_info SET trade_name = N'Changed elsewhere' WHERE kyc_basic_info_sno = ${K}`);
    const rej = await act(run, { kyc_modified_sno: r.kyc_modified_sno, ecno: APPROVER, action: "reject", note: "KYC changed - send again" });
    check(rej.status === "R", "reject works on a stale request");
  });

  // ------------------------------------------------------------ G: no workflow
  await inTx("G no workflow", async ({ q, run }) => {
    const { head, snap } = await load(run);
    await q(`UPDATE dbo.workflow_types SET is_active = 'N' WHERE workflow_types_id = ${wf}`);
    await expectError(run("sp_nt_SupplierModifyKyc", bigChange(head, snap).form), 58613, "no active KYC workflow -> refused with a clear message");
  });
  await inTx("G2 first stage without an approver", async ({ q, run }) => {
    const { head, snap } = await load(run);
    await q(`UPDATE dbo.workflow_stage SET stage_order_json = REPLACE(stage_order_json, '"approver_ecno":"${APPROVER}"', '"approver_ecno":""') WHERE workflow_types_id = ${wf}`);
    await expectError(run("sp_nt_SupplierModifyKyc", bigChange(head, snap).form), 58613, "first stage without an approver -> refused");
  });
  await inTx("G3 routed to its own workflow", async ({ q, run }) => {
    const [route] = await q(`SELECT entity_code FROM dbo.approval_entity_route WHERE module_code = 'KYC' AND variant_code = 'SUPPLIER_CHANGE'`);
    check(route?.entity_code === "KYC", "seed: KYC > SUPPLIER_CHANGE is routed to the KYC workflow by default");
    check((await q(`SELECT dbo.fn_resolve_approval_entity('KYC', 'SUPPLIER_CHANGE') e`))[0].e === "KYC", "fn_resolve_approval_entity resolves it");
    // point it at an entity that has no usable workflow -> the supplier is told, nothing is half-saved
    const [bare] = await q(`SELECT TOP 1 e.entity_code FROM dbo.entity_master e
      WHERE e.is_active = 'Y' AND e.entity_code <> 'KYC' AND dbo.fn_scopeless_workflow_types(e.entity_code) IS NULL ORDER BY e.entity_sno`);
    if (!bare) { console.log("      (every entity has a workflow here: re-route check skipped)"); return; }
    await q(`UPDATE dbo.approval_entity_route SET entity_code = '${bare.entity_code}' WHERE module_code = 'KYC' AND variant_code = 'SUPPLIER_CHANGE'`);
    const { head, snap } = await load(run);
    await expectError(run("sp_nt_SupplierModifyKyc", bigChange(head, snap).form), 58613, `re-routed to ${bare.entity_code} (no workflow) -> refused`);
  });

  // ------------------------------------------------------------ H: other submit errors
  const submitError = async (label, num, mutate) => inTx(label, async ({ run }) => {
    const { head, snap } = await load(run);
    const form = formFrom(head, snap);
    form.basic.contact_person = "Changed";
    await expectError(run("sp_nt_SupplierModifyKyc", mutate(form, snap, head) ?? form), num, label);
  });
  await submitError("no authorization letter", 58605, (f) => { f.files = [{ ...AUTH, file_kind: "gst_file" }]; });
  await submitError("no reason", 58602, (f) => { f.reason = "   "; });
  await submitError("nothing changed", 58612, (f, snap) => { f.basic.contact_person = snap.basic.contact_person; });
  await submitError("two primary addresses", 58606, (f) => { f.addresses = f.addresses.map((a) => ({ ...a, is_primary: "Y" })); if (f.addresses.length < 2) f.addresses.push({ ...f.addresses[0], kyc_address_sno: null }); });
  await submitError("someone else's bank account", 58609, (f) => {
    f.basic.pay_via_portal = "N";
    f.banks = [{ kyc_bank_sno: 97, ac_holder_name: "X", ac_number: "1234567", ac_type: "2", ifsc: "KKBK0000961", bank_name: "B", bank_branch_name: "BR", bank_address: "A", is_primary: "Y" }];
  });
  await submitError("no primary contact", 58608, (f) => { f.contacts = f.contacts.map((c) => ({ ...c, is_primary: "N" })); });
  await submitError("unknown document type", 58610, (f) => { f.documents = [{ document_type: "aadhaar", document_name: "x", document_path: "http://x/y.pdf" }]; });
  await submitError("portal without a URL", 58604, (f) => { f.basic.pay_via_portal = "Y"; f.basic.payment_portal_name = "Our portal"; f.basic.payment_portal_url = ""; });
  await submitError("wrong hash", 58611, (f) => { f.snapshot_hash = "0".repeat(64); });
  await inTx("unknown supplier", async ({ run }) => {
    await expectError(run("sp_nt_GetSupplierOwnKyc", { kyc_basic_info_sno: 99999999 }), 58601, "own KYC of an unknown supplier");
  });

  // ------------------------------------------------------------ I: inbox + misc
  await inTx("I inbox", async ({ run }) => {
    const { head, snap } = await load(run);
    const r = await submit(run, bigChange(head, snap).form);
    const mine = await run("sp_nt_GetKycChangeApprovals", { ecno: APPROVER });
    check(mine[0].length === 1 && mine[0][0].kyc_modified_sno === r.kyc_modified_sno && mine[0][0].company_name && mine[0][0].supp_code === head.supp_code, "the approver's inbox lists the request with the supplier");
    const row = mine[0][0];
    check(JSON.parse(row.files).length === 2 && JSON.parse(row.old_data).basic.company_name && JSON.parse(row.new_data).basic.contact_person === "Verify Person" && row.stage_total === stageList.length, "request carries files, old data, new data and the stage count");
    const other = await run("sp_nt_GetKycChangeApprovals", { ecno: "ZZ999" });
    check(other[0].length === 0 && other[1].length === 0, "someone else sees nothing");
    await expectError(run("sp_nt_GetKycChangeApprovals", { ecno: "" }), 58622, "an inbox call without an approver is refused");
  });
  await inTx("J database guards + re-run", async ({ q, run, tx }) => {
    // sql/93 can be run again without error (re-runnable)
    for (const b of batches) await new sql.Request(tx).batch(b);
    check(true, "sql/93 ran a second time without error");
    // a row inserted the sql/92 way (no status) is an applied change
    await q(`INSERT dbo.kyc_modified_data (kyc_basic_info_sno, version_no, reason, changed_sections, old_data, new_data, modified_by) VALUES (${K}, 90, N'old style', 'BASIC', N'{}', N'{}', N'x')`);
    check((await q(`SELECT status FROM dbo.kyc_modified_data WHERE version_no = 90`))[0].status === "A", "a row inserted the sql/92 way defaults to status A (applied)");
    // the unique index: two waiting requests for one supplier cannot exist
    await q(`INSERT dbo.kyc_modified_data (kyc_basic_info_sno, version_no, reason, changed_sections, old_data, new_data, modified_by, status) VALUES (${K}, 91, N'p1', 'BASIC', N'{}', N'{}', N'x', 'P')`);
    await expectError(q(`INSERT dbo.kyc_modified_data (kyc_basic_info_sno, version_no, reason, changed_sections, old_data, new_data, modified_by, status) VALUES (${K}, 92, N'p2', 'BASIC', N'{}', N'{}', N'x', 'P')`), 2601, "the database itself refuses a second waiting request");
  });

  const shapeAfter = await shape();
  check(JSON.stringify(shapeAfter) === JSON.stringify(shapeBefore), "the run left the database exactly as it found it (objects, columns, rows, procedure versions)", JSON.stringify(shapeAfter));
} catch (e) {
  failures += 1;
  console.error("UNEXPECTED", e.number ?? "", e.message);
} finally {
  await pool.close();
}
console.log(failures ? `\n${failures} check(s) FAILED` : "\nAll checks passed");
process.exit(failures ? 1 : 0);
