// supplier.routes.js - "My KYC" of the supplier portal (sql/92). What the procedures decide (the form is not stale, every row named is
// the supplier's own, one primary row each ...) was checked against the database (sql/_verify_92.mjs); here: that the supplier id
// comes from the LOGIN, that the form is checked and the files are sorted BEFORE anything is sent to the FTP server, what reaches the
// procedure, and that the procedure's messages for the supplier come back untouched.
import { describe, it, expect, jest, beforeAll, afterAll, beforeEach } from "@jest/globals";
import express from "express";
import multer from "multer";

const input = jest.fn();
const execute = jest.fn();
const request = { input, execute };
input.mockReturnValue(request);
const uploadFileIfExists = jest.fn();
const createInAppNotification = jest.fn(async () => ({ sent: true }));

jest.unstable_mockModule("../src/config/db.js", () => ({
  initializeDatabase: async () => ({ request: () => request }),
}));
jest.unstable_mockModule("../src/utils/ftpUpload.js", () => ({
  upload: multer({ storage: multer.memoryStorage(), limits: { fileSize: 10 * 1024 * 1024 } }),
  ftpUploader: { uploadFileIfExists },
}));
jest.unstable_mockModule("../src/middleware/auth.js", () => ({ default: (_req, _res, next) => next() }));
jest.unstable_mockModule("../src/middleware/supplierAuth.js", () => ({
  verifySupplierAuth: (req, _res, next) => { req.supplier = { kyc_basic_info_sno: 55, supp_code: "SUP55", email: "s55@example.com" }; next(); },
  signSupplierToken: () => "token",
}));
jest.unstable_mockModule("../src/utils/notifyClient.js", () => ({
  createInAppNotification,
  sendSupplierInviteEmail: async () => ({ sent: true }),
}));
jest.unstable_mockModule("../src/utils/prTracking.js", () => ({ broadcastPrTrack: async () => {} }));

const { default: SupplierRouter } = await import("../src/supplier/supplier.routes.js");
const { parseKycChange, sortKycFiles, describeSections, webAddress } = await import("../src/supplier/supplierKyc.validation.js");

let server;
let base;
beforeAll(async () => {
  const app = express();
  app.use(express.json());
  app.use("/api/supplier", SupplierRouter);
  server = app.listen(0);
  base = `http://127.0.0.1:${server.address().port}/api/supplier`;
});
afterAll(() => new Promise((r) => server.close(r)));
beforeEach(() => {
  input.mockClear();
  execute.mockReset();
  uploadFileIfExists.mockReset();
  createInAppNotification.mockClear();
});

const HASH = "A".repeat(64);
const snapshot = {
  basic: { company_name: "ACME", legal_name: null, trade_name: null, contact_person: "Ravi", email: "r@acme.com", mobile_number: "9000000000",
    business_type: "2", is_gst_avail: "Y", gst_no: "33ABCDE1234F1Z5", is_msme_avail: "N", msme_no: null, msme_type: null, pan_no: "ABCDE1234F" },
  payment: { pay_via_portal: "N", payment_portal_name: null, payment_portal_url: null, payment_instructions: null },
  addresses: [{ kyc_address_sno: 7, address_type: "PRIMARY", door_no: "1", street: "S", area: "A", city: "Coimbatore", taluk: null, state: "Tamil Nadu", state_code: 33, pincode: "641001", location_link: null, is_primary: "Y" }],
  banks: [{ kyc_bank_sno: 3, ac_holder_name: "ACME", ac_number: "123456789012", ac_type: "2", ac_type_name: "Current", ifsc: "HDFC0000001", bank_name: "HDFC", bank_branch_name: "RS Puram", bank_address: "Cbe", is_primary: "Y" }],
  contacts: [{ kyc_contact_sno: 4, contact_type: "PRIMARY", contact_name: "Ravi", contact_position: "Owner", contact_mobile: "9000000000", contact_email: "r@acme.com" }],
  documents: [],
};
const head = { kyc_basic_info_sno: 55, supp_code: "SUP55", status: "A", pan_no: "ABCDE1234F", supplier_category: "Packaging", category: "Supplier", snapshot: JSON.stringify(snapshot), snapshot_hash: HASH };
const ownKycResult = () => ({
  recordsets: [[head], [], [{ value: "1", label: "Sole Proprietorship" }, { value: "2", label: "Partnership" }], [{ value: "1", label: "Savings" }, { value: "2", label: "Current" }]],
});

/** the change form, as the portal sends it for the KYC above */
const goodForm = (over = {}) => ({
  snapshot_hash: HASH, reason: "New registered office",
  basic: { ...snapshot.basic, ...snapshot.payment, contact_person: "Ravi Kumar" },
  addresses: snapshot.addresses, banks: snapshot.banks,
  contacts: snapshot.contacts.map((c) => ({ ...c, is_primary: "Y" })),
  ...over,
});

const sent = () => JSON.parse(input.mock.calls.at(-1)[2]);
const pdf = (name, body = "x") => ({ blob: new Blob([body]), name });
const submit = (form, files = {}) => {
  const fd = new FormData();
  fd.append("payload", JSON.stringify(form));
  for (const [field, list] of Object.entries(files)) for (const f of [].concat(list)) fd.append(field, f.blob, f.name);
  return fetch(`${base}/kyc/modify`, { method: "POST", body: fd }).then(async (r) => ({ status: r.status, json: await r.json() }));
};

describe("GET /kyc", () => {
  it("returns the logged-in supplier's KYC (the id comes from the login), parsed, with the form choices", async () => {
    execute.mockResolvedValue({
      recordsets: [
        [{ ...head, pending_sno: 7, pending_version: 2, pending_stage_no: 1, pending_stage_total: 2, pending_stage_name: "STORE INCHARGE" }],
        [{ kyc_modified_sno: 1, version_no: 1, reason: "r", changed_sections: "BANK", old_data: JSON.stringify(snapshot), new_data: JSON.stringify(snapshot), modified_by: "x", modified_date: "2026-11-06", status: "A", files: JSON.stringify([{ file_kind: "AUTHORIZATION", file_name: "a.pdf", file_path: "http://x/a.pdf" }]), approvals: JSON.stringify([{ seq_no: 1, stage_name: "STORE INCHARGE", action: "A", note: null }]) }],
        [{ value: "2", label: "Partnership" }], [{ value: "2", label: "Current" }],
      ],
    });
    const res = await fetch(`${base}/kyc`);
    const json = await res.json();
    expect(res.status).toBe(200);
    expect(execute).toHaveBeenCalledWith("sp_nt_GetSupplierOwnKyc");
    expect(sent()).toEqual({ kyc_basic_info_sno: 55 });
    expect(json.data.kyc.snapshot_hash).toBe(HASH);
    expect(json.data.kyc.basic.company_name).toBe("ACME");
    expect(json.data.kyc.banks[0].ac_number).toBe("123456789012");
    expect(json.data.kyc.snapshot).toBeUndefined();
    expect(json.data.history[0].old_data.basic.company_name).toBe("ACME");
    expect(json.data.history[0].files[0].file_kind).toBe("AUTHORIZATION");
    expect(json.data.history[0].status).toBe("A");
    expect(json.data.history[0].approvals).toEqual([{ seq_no: 1, stage_name: "STORE INCHARGE", action: "A", note: null }]);
    expect(json.data.kyc).toMatchObject({ pending_sno: 7, pending_stage_no: 1, pending_stage_total: 2, pending_stage_name: "STORE INCHARGE" });
    expect(json.data.business_types).toEqual([{ value: "2", label: "Partnership" }]);
  });

  it("404 with the procedure's own message when the KYC is gone", async () => {
    execute.mockRejectedValue(Object.assign(new Error("Your KYC record was not found. Please contact the purchase team."), { number: 58601 }));
    const res = await fetch(`${base}/kyc`);
    expect(res.status).toBe(404);
    expect((await res.json()).error).toBe("Your KYC record was not found. Please contact the purchase team.");
  });
});

describe("POST /kyc/modify", () => {
  it("needs the authorization letter - nothing is uploaded, nothing is saved", async () => {
    execute.mockResolvedValue(ownKycResult());
    const r = await submit(goodForm());
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("Upload the authorization letter for this change.");
    expect(uploadFileIfExists).not.toHaveBeenCalled();
    expect(execute).toHaveBeenCalledTimes(1); // only the read of the current KYC
  });

  it("checks the form before uploading anything", async () => {
    execute.mockResolvedValue(ownKycResult());
    const r = await submit(goodForm({ addresses: [{ ...snapshot.addresses[0], pincode: "12" }] }), { authorization_file: pdf("a.pdf") });
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("Address 1: the pincode is not valid (6 digits).");
    expect(uploadFileIfExists).not.toHaveBeenCalled();
  });

  it("refuses a file type that is not a PDF or an image, before anything is uploaded", async () => {
    execute.mockResolvedValue(ownKycResult());
    const r = await submit(goodForm(), { authorization_file: pdf("letter.docx") });
    expect(r.status).toBe(400);
    expect(r.json.error).toMatch(/"letter.docx" is not a PDF or an image/);
    expect(uploadFileIfExists).not.toHaveBeenCalled();
  });

  it("refuses a file that belongs to no known document", async () => {
    execute.mockResolvedValue(ownKycResult());
    const r = await submit(goodForm(), { authorization_file: pdf("a.pdf"), doc_aadhaar: pdf("x.pdf") });
    expect(r.status).toBe(400);
    expect(r.json.error).toMatch(/not for a known document/);
    expect(uploadFileIfExists).not.toHaveBeenCalled();
  });

  const pendingRow = (over = {}) => ({
    kyc_modified_sno: 5, version_no: 2, changed_sections: "BASIC,DOCUMENT", status: "P", current_approver_ecno: "ED001",
    stage_name: "STORE INCHARGE", stage_no: 1, stage_total: 2, company_name: "ACME", supp_code: "SUP55", ...over,
  });

  it("saves a REQUEST: files go to the FTP server, the supplier is the logged-in one, and the procedure gets hash + files", async () => {
    execute.mockResolvedValueOnce(ownKycResult());
    execute.mockResolvedValueOnce({ recordset: [pendingRow()] });
    uploadFileIfExists.mockImplementation(async (file, folder) => `http://be/dwl/${folder}/${file.originalname}`);
    const r = await submit(
      goodForm({ kyc_basic_info_sno: 999 }),
      { authorization_file: [pdf("auth1.pdf"), pdf("auth2.png")], doc_gst_file: pdf("gst.pdf") },
    );
    expect(r.status).toBe(200);
    expect(r.json.message).toMatch(/sent for approval/);
    expect(r.json.data).toEqual({
      kyc_modified_sno: 5, version_no: 2, changed_sections: "BASIC,DOCUMENT", status: "P", stage_no: 1, stage_total: 2, stage_name: "STORE INCHARGE",
    });
    expect(uploadFileIfExists.mock.calls.map((c) => c[1])).toEqual([
      "NON_TRADE_DATAS/KYC_MODIFICATIONS", "NON_TRADE_DATAS/KYC_MODIFICATIONS", "NON_TRADE_DATAS/KYC_DATAS",
    ]);
    expect(execute).toHaveBeenLastCalledWith("sp_nt_SupplierModifyKyc");
    const p = sent();
    expect(p.kyc_basic_info_sno).toBe(55);
    expect(p.snapshot_hash).toBe(HASH);
    expect(p.modified_by).toBe("s55@example.com");
    expect(p.reason).toBe("New registered office");
    expect(p.basic.contact_person).toBe("Ravi Kumar");
    expect(p.banks[0]).toMatchObject({ kyc_bank_sno: 3, ac_number: "123456789012", ifsc: "HDFC0000001" });
    expect(p.documents).toEqual([{ document_type: "gst_file", document_name: "gst.pdf", document_path: "http://be/dwl/NON_TRADE_DATAS/KYC_DATAS/gst.pdf", file_size: 1 }]);
    expect(p.files.map((f) => f.file_kind)).toEqual(["AUTHORIZATION", "AUTHORIZATION", "gst_file"]);
  });

  it("tells the FIRST approver on the staff bell, opening the KYC Approval screen", async () => {
    execute.mockResolvedValueOnce(ownKycResult());
    execute.mockResolvedValueOnce({ recordset: [pendingRow({ changed_sections: "BANK", current_approver_ecno: " ED001 " })] });
    uploadFileIfExists.mockResolvedValue("http://be/dwl/a.pdf");
    const r = await submit(goodForm(), { authorization_file: pdf("a.pdf") });
    expect(r.status).toBe(200);
    await new Promise((resolve) => setImmediate(resolve));
    expect(createInAppNotification).toHaveBeenCalledTimes(1);
    const n = createInAppNotification.mock.calls[0][0];
    expect(n.ecno).toBe("ED001");
    expect(n.message).toMatch(/asked to change their bank accounts/);
    expect(n.message).toMatch(/Open KYC Approval/);
    expect(n.data).toMatchObject({ kind: "supplier_kyc_change_pending", screen: "KYCApprovalScreen", kyc_modified_sno: 5 });
  });

  it("sends no bell when the procedure names no approver", async () => {
    execute.mockResolvedValueOnce(ownKycResult());
    execute.mockResolvedValueOnce({ recordset: [pendingRow({ current_approver_ecno: null })] });
    uploadFileIfExists.mockResolvedValue("http://be/dwl/a.pdf");
    const r = await submit(goodForm(), { authorization_file: pdf("a.pdf") });
    expect(r.status).toBe(200);
    await new Promise((resolve) => setImmediate(resolve));
    expect(createInAppNotification).not.toHaveBeenCalled();
  });

  it("502-style failure: a file the FTP server did not take stops the save", async () => {
    execute.mockResolvedValue(ownKycResult());
    uploadFileIfExists.mockResolvedValue("");
    const r = await submit(goodForm(), { authorization_file: pdf("a.pdf") });
    expect(r.status).toBe(400);
    expect(r.json.error).toBe('"a.pdf" could not be uploaded. Please try again.');
    expect(execute).toHaveBeenCalledTimes(1);
  });

  it("the procedure's message for the supplier comes back as written (not wrapped as a database error)", async () => {
    execute.mockResolvedValueOnce(ownKycResult());
    execute.mockRejectedValueOnce(Object.assign(new Error("Your KYC was changed after you opened this form. Reload the page and make your change again."), { number: 58611 }));
    uploadFileIfExists.mockResolvedValue("http://be/dwl/a.pdf");
    const r = await submit(goodForm(), { authorization_file: pdf("a.pdf") });
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("Your KYC was changed after you opened this form. Reload the page and make your change again.");
    expect(createInAppNotification).not.toHaveBeenCalled();
  });

  it("any other database failure is wrapped, not shown raw", async () => {
    execute.mockResolvedValueOnce(ownKycResult());
    execute.mockRejectedValueOnce(Object.assign(new Error("Deadlock victim"), { number: 1205 }));
    uploadFileIfExists.mockResolvedValue("http://be/dwl/a.pdf");
    const r = await submit(goodForm(), { authorization_file: pdf("a.pdf") });
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("Database error: Deadlock victim");
  });

  it("400 when the payload is not JSON", async () => {
    const fd = new FormData();
    fd.append("payload", "{nope");
    const res = await fetch(`${base}/kyc/modify`, { method: "POST", body: fd });
    expect(res.status).toBe(400);
    expect((await res.json()).error).toBe("The KYC form is not valid JSON.");
  });
});

describe("POST /kyc/withdraw", () => {
  const withdraw = (body) => fetch(`${base}/kyc/withdraw`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })
    .then(async (r) => ({ status: r.status, json: await r.json() }));

  it("withdraws the logged-in supplier's own request, whatever supplier the body names, and tells the approver", async () => {
    execute.mockResolvedValue({ recordset: [{ kyc_modified_sno: 7, version_no: 2, status: "C", current_approver_ecno: "ED001", company_name: "ACME", supp_code: "SUP55" }] });
    const r = await withdraw({ kyc_modified_sno: 7, kyc_basic_info_sno: 999 });
    expect(r.status).toBe(200);
    expect(r.json.data).toEqual({ kyc_modified_sno: 7, status: "C" });
    expect(execute).toHaveBeenCalledWith("sp_nt_WithdrawKycChange");
    expect(sent()).toEqual({ kyc_basic_info_sno: 55, kyc_modified_sno: 7, by: "s55@example.com" });
    await new Promise((resolve) => setImmediate(resolve));
    expect(createInAppNotification).toHaveBeenCalledTimes(1);
    expect(createInAppNotification.mock.calls[0][0]).toMatchObject({ ecno: "ED001", title: "Supplier KYC change withdrawn", data: { kind: "supplier_kyc_change_withdrawn", screen: "KYCApprovalScreen" } });
  });

  it("refuses a request id that is not a number, before the database is called", async () => {
    const r = await withdraw({ kyc_modified_sno: "abc" });
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("That request was not found.");
    expect(execute).not.toHaveBeenCalled();
  });

  it("the procedure's message comes back as written, and nobody is told", async () => {
    execute.mockRejectedValue(Object.assign(new Error("Only a request that is still waiting for approval can be withdrawn."), { number: 58615 }));
    const r = await withdraw({ kyc_modified_sno: 7 });
    expect(r.status).toBe(400);
    expect(r.json.error).toBe("Only a request that is still waiting for approval can be withdrawn.");
    expect(createInAppNotification).not.toHaveBeenCalled();
  });
});

describe("parseKycChange", () => {
  const ctx = { pan_no: "ABCDE1234F", current_business_type: "2", business_types: ["1", "2"], account_types: ["1", "2"] };
  const run = (over) => parseKycChange(goodForm(over), ctx);
  const fails = (over, message) => expect(() => run(over)).toThrow(message);

  it("accepts the KYC as it is and cleans the values", () => {
    const out = parseKycChange(goodForm({
      basic: { ...snapshot.basic, ...snapshot.payment, gst_no: " 33abcde1234f1z5 ", mobile_number: "+91 90000-00000" },
      banks: [{ ...snapshot.banks[0], ifsc: "hdfc0000001", ac_number: " 1234 5678 9012 " }],
    }), ctx);
    expect(out.basic.gst_no).toBe("33ABCDE1234F1Z5");
    expect(out.basic.mobile_number).toBe("+919000000000");
    expect(out.banks[0]).toMatchObject({ ifsc: "HDFC0000001", ac_number: "123456789012" });
    expect(out.addresses[0].state_code).toBe(33);
  });

  it("clears what does not apply: no GST number when not GST registered, no bank when paid through the portal", () => {
    const out = run({ basic: { ...snapshot.basic, is_gst_avail: "N", gst_no: "33ABCDE1234F1Z5", pay_via_portal: "Y", payment_portal_name: "Pay here", payment_portal_url: "https://pay.example.com/x" }, banks: [] });
    expect(out.basic.gst_no).toBeNull();
    expect(out.banks).toEqual([]);
    expect(out.basic.payment_portal_url).toBe("https://pay.example.com/x");
  });

  it("is strict about what could misdirect money or break the KYC", () => {
    fails({ reason: "  " }, "Enter the reason for the change.");
    fails({ snapshot_hash: "abc" }, /Reload the page/);
    fails({ basic: { ...snapshot.basic, gst_no: "33ABCDE1234G1Z5" } }, /must contain your PAN \(ABCDE1234F\)/);
    fails({ basic: { ...snapshot.basic, gst_no: "NOPE" } }, /GST number is not valid/);
    fails({ basic: { ...snapshot.basic, email: "not-an-email" } }, /email is not valid/);
    fails({ basic: { ...snapshot.basic, business_type: "99" } }, "Company details: choose a business type from the list.");
    fails({ banks: [{ ...snapshot.banks[0], ifsc: "BAD" }] }, /Bank account 1: the IFSC is not valid/);
    fails({ banks: [{ ...snapshot.banks[0], ac_number: "0123456789" }] }, /starting with 0/);
    fails({ banks: [{ ...snapshot.banks[0], ac_type: "9" }] }, /choose the account type/i);
    fails({ banks: [] }, "Add your bank account, or choose to be paid through your portal.");
    fails({ banks: [{ ...snapshot.banks[0], is_primary: "N" }] }, "Mark exactly one bank account as primary.");
    fails({ addresses: [] }, "Add at least one address.");
    fails({ addresses: [{ ...snapshot.addresses[0], kyc_address_sno: "abc" }] }, /Reload the page/);
    fails({ contacts: [{ ...snapshot.contacts[0], is_primary: "N" }] }, "Mark exactly one contact as primary.");
    fails({ basic: { ...snapshot.basic, pay_via_portal: "Y", payment_portal_name: "P", payment_portal_url: "https://good.com@bad.com" }, banks: [] }, /full web address/);
  });

  it("a business type / account type already on file stays valid even if the master retired it", () => {
    const out = parseKycChange(goodForm({ basic: { ...snapshot.basic, business_type: "Electrical Contractor" } }), { ...ctx, current_business_type: "Electrical Contractor" });
    expect(out.basic.business_type).toBe("Electrical Contractor");
  });

  it("webAddress rejects look-alike addresses", () => {
    expect(webAddress("", "address", "https://pay.example.com/a?b=1", { required: true })).toBe("https://pay.example.com/a?b=1");
    expect(webAddress("", "address", "")).toBeNull();
    for (const bad of ["pay.example.com", "ftp://pay.example.com", "https://localhost", "https://a b.com", "javascript:alert(1)"]) {
      expect(() => webAddress("", "address", bad, { required: true })).toThrow(/full web address/);
    }
  });
});

describe("sortKycFiles / describeSections", () => {
  const f = (fieldname, originalname) => ({ fieldname, originalname });
  const ext = (n) => n.slice(n.lastIndexOf("."));

  it("sorts the letter from the documents", () => {
    const { authorization, documents } = sortKycFiles([f("authorization_file", "a.pdf"), f("doc_pan_file", "p.jpg")], ext);
    expect(authorization).toHaveLength(1);
    expect(documents.map((d) => d.type)).toEqual(["pan_file"]);
  });

  it("limits how many files", () => {
    const four = ["1", "2", "3", "4"].map((n) => f("authorization_file", `${n}.pdf`));
    expect(() => sortKycFiles(four, ext)).toThrow(/at most 3 files/);
    expect(() => sortKycFiles([f("authorization_file", "a.pdf"), f("doc_pan_file", "1.pdf"), f("doc_pan_file", "2.pdf")], ext)).toThrow(/one PAN card at a time/);
  });

  it("describes the changed sections for the staff bell", () => {
    expect(describeSections("BANK")).toBe("bank accounts");
    expect(describeSections("BASIC,BANK,DOCUMENT")).toBe("company details, bank accounts and documents");
    expect(describeSections("")).toBe("details");
  });
});
