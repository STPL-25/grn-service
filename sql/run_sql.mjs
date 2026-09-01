/**
 * Applies a .sql file to the database this service is configured against.
 *
 *   cd grn-service && node sql/run_sql.mjs sql/17_invoice_po_items_for_allocation.sql
 *
 * Copied from backend-stpl/sql/run_sql.mjs (same DB, same batch-splitting
 * convention: standalone GO lines separate batches, execution stops at the
 * first failing batch, scripts here should be written to be re-runnable).
 * Run it from the grn-service directory — dotenv resolves .env relative to
 * the working directory.
 */
import fs from "node:fs/promises";
import path from "node:path";
import sql from "mssql";
import { configDotenv } from "dotenv";

configDotenv();

const target = process.argv[2];
if (!target) {
  console.error("Usage: node sql/run_sql.mjs <path-to.sql>   (run from the grn-service directory)");
  process.exit(1);
}

if (!process.env.SERVER || !process.env.DATABASE) {
  console.error(
    "SERVER/DATABASE are not set — .env was not picked up.\n" +
    "Run this from the grn-service directory: cd grn-service && node sql/run_sql.mjs <file>"
  );
  process.exit(1);
}

const config = {
  user: process.env.DB_USER,
  password: process.env.DB_USER_PASSWORD,
  server: process.env.SERVER,
  database: process.env.DATABASE,
  port: parseInt(process.env.DB_PORT) || 1433,
  options: { trustServerCertificate: true, enableArithAbort: true },
  connectionTimeout: 15000,
  requestTimeout: 60000,
  pool: { max: 2, min: 0, idleTimeoutMillis: 5000 },
};

const sqlPath = path.resolve(target);
const script = await fs.readFile(sqlPath, "utf8");

/** True once every line-comment and blank line is stripped, i.e. nothing to run. */
const isCommentOnly = (batch) =>
  batch
    .split("\n")
    .every((line) => {
      const trimmed = line.trim();
      return trimmed === "" || trimmed.startsWith("--");
    });

/** Split on standalone GO lines, dropping comment-only fragments. */
const batches = script
  .split(/^\s*GO\s*$/gim)
  .map((batch) => batch.trim())
  .filter((batch) => batch.length > 0 && !isCommentOnly(batch));

/** One-line summary of a batch, for the progress log. */
const describe = (batch) => {
  const proc = batch.match(/CREATE\s+PROCEDURE\s+(?:dbo\.)?(\w+)/i);
  if (proc) return `procedure ${proc[1]}`;
  const drop = batch.match(/DROP\s+PROCEDURE\s+(?:dbo\.)?(\w+)/i);
  if (drop) return `drop ${drop[1]}`;
  const table = batch.match(/CREATE\s+TABLE\s+(?:dbo\.)?(\w+)/i);
  if (table) return `table ${table[1]}`;
  return batch.split("\n").find((l) => l.trim() && !l.trim().startsWith("--"))?.slice(0, 60) ?? "batch";
};

const pool = await new sql.ConnectionPool(config).connect();
console.log(`Database : ${config.database} @ ${config.server}`);
console.log(`Script   : ${path.basename(sqlPath)} (${batches.length} batches)\n`);

let failed = false;
for (const [i, batch] of batches.entries()) {
  const label = describe(batch);
  try {
    await pool.request().batch(batch);
    console.log(`  [${i + 1}/${batches.length}] ok   ${label}`);
  } catch (error) {
    console.error(`  [${i + 1}/${batches.length}] FAIL ${label}`);
    console.error(`        ${error.message}`);
    console.error("\nStopped. Batches after this one were not applied.");
    failed = true;
    break;
  }
}

if (!failed) console.log(`\nAll ${batches.length} batches applied.`);

await pool.close();
process.exit(failed ? 1 : 0);
