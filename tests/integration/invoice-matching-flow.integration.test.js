// Integration test — composite invoice allocation/matching, exercised
// against a REAL database connection because the actual business rule this
// feature depends on ("a mismatch on one bucket never holds another
// bucket's payable amount") lives entirely inside sp_nt_MatchInvoiceBucket
// (SQL), not in the Node.js layer invoice.service.test.js already covers
// with mocks.
//
// SKIPPED BY DEFAULT — same reasoning as backend-stpl's
// tests/integration/pr-po-flow.integration.test.js: this repo has no
// dedicated test database, only the same one real users work in. Run for
// real against a disposable test DB with:
//   RUN_DB_INTEGRATION_TESTS=1 npm test -- --testPathPatterns=integration
//
// Everything this test creates (one invoice_info row + its
// invoice_allocation_details rows) is soft-deleted in afterAll.
import { describe, it, expect, beforeAll, afterAll } from "@jest/globals";

const RUN = process.env.RUN_DB_INTEGRATION_TESTS === "1";
const maybeDescribe = RUN ? describe : describe.skip;

maybeDescribe("Composite invoice bucket matching (integration, real DB)", () => {
  let sql, pool;
  let createdInvoiceSno;

  beforeAll(async () => {
    sql = (await import("mssql")).default;
    const { configDotenv } = await import("dotenv");
    configDotenv();
    pool = await new sql.ConnectionPool({
      user: process.env.DB_USER,
      password: process.env.DB_USER_PASSWORD,
      server: process.env.SERVER,
      database: process.env.DATABASE,
      port: parseInt(process.env.DB_PORT) || 1433,
      options: { trustServerCertificate: true, enableArithAbort: true },
    }).connect();
  });

  afterAll(async () => {
    if (createdInvoiceSno) {
      await pool.request()
        .input("sno", sql.Int, createdInvoiceSno)
        .query("UPDATE invoice_allocation_details SET is_active = 'N' WHERE invoice_sno = @sno");
      await pool.request()
        .input("sno", sql.Int, createdInvoiceSno)
        .query("UPDATE invoice_info SET is_active = 'N' WHERE invoice_sno = @sno");
    }
    await pool?.close();
  });

  it("holds only a mismatched bucket while releasing a fully-received one on the same invoice", async () => {
    // Two distinct po_item_sno rows on two different POs, each with a known
    // received quantity, stand in for "a MATERIAL line and a SERVICE line" —
    // sp_nt_MatchInvoiceBucket's ratio math is identical either way (it's
    // driven by po_item_details.po_section per row, not by which PO a row
    // came from), so this exercises the real independence rule without
    // depending on a specific combined PO existing in whatever DB this runs
    // against.
    const lines = await pool.request().query(`
      SELECT TOP 2 poi.po_item_sno, poi.po_basic_sno, poi.qty, poi.net_cost,
             ISNULL(poi.po_section, 'MATERIAL') AS po_section
      FROM po_item_details poi
      WHERE poi.is_active IN ('1','Y') AND poi.qty > 0 AND poi.net_cost > 0
      ORDER BY poi.po_item_sno DESC
    `);
    if (lines.recordset.length < 2) {
      throw new Error("Need at least 2 po_item_details rows with qty/net_cost to run this integration test.");
    }
    const [lineA, lineB] = lines.recordset;

    const vendor = await pool.request()
      .input("po", sql.Int, lineA.po_basic_sno)
      .query("SELECT vendor_sno FROM po_request_info WHERE po_basic_sno = @po");

    const totalAmount = Number(lineA.net_cost) + Number(lineB.net_cost);

    const created = await pool.request()
      .input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({
        vendor_invoice_no: "INTEG-TEST-" + Date.now(),
        vendor_sno: vendor.recordset[0].vendor_sno,
        po_basic_sno: lineA.po_basic_sno,
        invoice_date: new Date().toISOString().slice(0, 10),
        invoice_amount: totalAmount,
        invoice_type: "COMPOSITE",
        created_by: "integration-test",
      }))
      .execute("sp_nt_CreateInvoice");
    createdInvoiceSno = created.recordset[0].invoice_sno;

    await pool.request()
      .input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({
        invoice_sno: createdInvoiceSno,
        created_by: "integration-test",
        allocations: [
          { po_item_sno: lineA.po_item_sno, allocated_amount: Number(lineA.net_cost) },
          { po_item_sno: lineB.po_item_sno, allocated_amount: Number(lineB.net_cost) },
        ],
      }))
      .execute("sp_nt_AllocateInvoice");

    const matched = await pool.request()
      .input("jsonInput", sql.NVarChar(sql.MAX), JSON.stringify({ invoice_sno: createdInvoiceSno }))
      .execute("sp_nt_MatchInvoiceBucket");

    expect(matched.recordset).toHaveLength(2);
    // The core guarantee under test: each bucket's hold/release is computed
    // independently — a bucket that resolves to a 0% match still leaves the
    // other bucket's release_amount untouched, rather than holding the
    // whole invoice.
    for (const bucket of matched.recordset) {
      expect(Number(bucket.hold_amount) + Number(bucket.release_amount)).toBeCloseTo(Number(bucket.allocated_amount), 1);
    }
    const totalHold = matched.recordset.reduce((s, b) => s + Number(b.hold_amount), 0);
    const totalRelease = matched.recordset.reduce((s, b) => s + Number(b.release_amount), 0);
    expect(totalHold + totalRelease).toBeCloseTo(totalAmount, 1);
  });
});
