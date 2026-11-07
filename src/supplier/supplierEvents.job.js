/**
 * Supplier-portal bell for debit notes, credit notes and payments (sql/88_supplier_portal_bell.sql).
 *
 * A note or payment can appear through several different stored procedures / routes, so instead of hooking each one this job asks
 * sp_nt_GetPendingSupplierEvents "what is new?" once a minute and posts one bell notification per event through
 * notification-service. The procedure owns de-duplication (nt_supplier_event_log) and a claim lease, so a second grn-service
 * instance, a restart, or a notification-service outage can neither double-announce nor lose an event (a failed send is retried).
 *
 * RFQ and PO notifications are NOT here: those are single, explicit moments (the RFQ mail / the PO mail) and are sent right
 * there from backend-stpl.
 */
import mssql from "mssql";
import { initializeDatabase } from "../config/db.js";
import { notifySupplier } from "../utils/notifyClient.js";

const SWEEP_INTERVAL_MS = 60_000;
const FIRST_SWEEP_DELAY_MS = 15_000;

const rupees = (n) =>
  `₹${Number(n ?? 0).toLocaleString("en-IN", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

const clip = (text, max = 160) => {
  const t = String(text ?? "").trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
};

/**
 * The notification for one row of sp_nt_GetPendingSupplierEvents, or null when there is nothing to say
 * (the note / payment went inactive after it was registered). Pure - no I/O.
 */
export function buildSupplierNotification(e) {
  if (!e?.ref_no) return null;
  const po = e.po_no ? ` against PO ${e.po_no}` : "";
  const why = e.remarks ? ` Reason: ${clip(e.remarks)}.` : "";

  switch (e.event_kind) {
    case "DEBIT_NOTE":
      return {
        type: "warning",
        title: "Debit note raised",
        message: `Debit note ${e.ref_no} for ${rupees(e.amount)} was raised${po}.${why} It is adjusted against what you are paid - review it under Debit / Credit Notes.`,
        data: { kind: "debit_note", view: "debit-notes", ref_no: e.ref_no },
      };
    case "CREDIT_NOTE":
      return {
        type: "success",
        title: "Credit note raised",
        message: `Credit note ${e.ref_no} for ${rupees(e.amount)} was raised${po}.${why} It adds to what you are paid - review it under Debit / Credit Notes.`,
        data: { kind: "credit_note", view: "debit-notes", ref_no: e.ref_no },
      };
    case "PAY_SCHEDULED": {
      const advance = e.payment_type === "ADVANCE";
      const when = advance && e.planned_for ? ` for ${e.planned_for}` : "";
      return {
        type: "info",
        title: advance ? "Advance payment scheduled" : "Payment scheduled",
        message: `${advance ? "Advance payment" : "Payment"} ${e.ref_no} of ${rupees(e.amount)} is scheduled${when}.`,
        data: { kind: "payment", view: "payments", ref_no: e.ref_no },
      };
    }
    case "PAY_PAID":
      return {
        type: "success",
        title: e.payment_type === "ADVANCE" ? "Advance payment made" : "Payment made",
        message: `Payment ${e.ref_no}: ${rupees(e.amount)} has been paid${e.mode ? ` by ${e.mode}` : ""}${e.paid_on ? ` on ${e.paid_on}` : ""}.`,
        data: { kind: "payment", view: "payments", ref_no: e.ref_no },
      };
    default:
      return null;
  }
}

/**
 * One pass. Returns { found, sent, skipped, failed }. Throws only if the database call itself fails.
 * `getPool` / `notify` are injectable so the claim -> send -> mark-delivered contract can be tested without a database.
 */
export async function sweepSupplierEvents({ getPool = initializeDatabase, notify = notifySupplier } = {}) {
  const pool = await getPool();
  const { recordset: events = [] } = await pool.request().execute("sp_nt_GetPendingSupplierEvents");

  const delivered = [];
  const result = { found: events.length, sent: 0, skipped: 0, failed: 0 };

  for (const e of events) {
    const note = buildSupplierNotification(e);
    if (!note) {
      delivered.push(e.event_sno); // nothing to announce - close it so it is not retried
      result.skipped += 1;
      continue;
    }
    const out = await notify({ supplier_sno: e.vendor_sno, ...note });
    if (out.sent) {
      delivered.push(e.event_sno);
      result.sent += 1;
    } else {
      result.failed += 1; // stays claimed; retried once the 5-minute lease lapses
      console.error(`[grn-service] supplier bell: ${e.event_kind} ${e.ref_no} -> supplier ${e.vendor_sno} failed: ${out.reason}`);
    }
  }

  if (delivered.length) {
    await pool
      .request()
      .input("jsonInput", mssql.NVarChar(mssql.MAX), JSON.stringify({ event_snos: delivered }))
      .execute("sp_nt_MarkSupplierEventsDelivered");
  }
  return result;
}

let timer = null;
let lastError = null;
let running = false;

async function tick() {
  if (running) return; // a slow pass must not overlap the next one
  running = true;
  try {
    const r = await sweepSupplierEvents();
    lastError = null;
    if (r.sent || r.failed) {
      console.log(`[grn-service] supplier bell sweep: ${r.sent} sent, ${r.failed} failed, ${r.skipped} skipped`);
    }
  } catch (err) {
    // Typically "Could not find stored procedure" before sql/88 is applied - say so once, not every minute.
    if (err.message !== lastError) {
      lastError = err.message;
      console.error(`[grn-service] supplier bell sweep failed (is sql/88_supplier_portal_bell.sql applied?): ${err.message}`);
    }
  } finally {
    running = false;
  }
}

export function startSupplierEventsJob() {
  if (timer) return;
  setTimeout(tick, FIRST_SWEEP_DELAY_MS).unref();
  timer = setInterval(tick, SWEEP_INTERVAL_MS);
  timer.unref();
}

export function stopSupplierEventsJob() {
  if (timer) clearInterval(timer);
  timer = null;
}
