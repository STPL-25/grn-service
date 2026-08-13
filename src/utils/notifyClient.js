/**
 * Thin client for notification-service's email API — replaces this
 * service's old local mailer (utils/mailer.js, deleted) now that SMTP
 * setup and templates live in one place instead of being copy-pasted per
 * service. Same return contract as the old sendMail() so call sites barely
 * change: { sent: boolean, reason?: string }.
 */
const NOTIFICATION_SERVICE_URL = process.env.NOTIFICATION_SERVICE_URL || "http://localhost:8086";
const INTERNAL_BROADCAST_SECRET = process.env.INTERNAL_BROADCAST_SECRET;

async function callEmailApi(path, body) {
  try {
    const resp = await fetch(`${NOTIFICATION_SERVICE_URL}/api/notify/email/${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-internal-secret": INTERNAL_BROADCAST_SECRET },
      body: JSON.stringify(body),
      // Emails involve an outbound SMTP round-trip on the other side —
      // longer than the ~3s used for the fire-and-forget socket broadcast.
      signal: AbortSignal.timeout(15000),
    });
    const data = await resp.json().catch(() => ({}));
    if (!resp.ok) return { sent: false, reason: data.message || `notification-service HTTP ${resp.status}` };
    return { sent: Boolean(data.sent), reason: data.reason };
  } catch (err) {
    return { sent: false, reason: err.message };
  }
}

export function sendSupplierInviteEmail({ to, companyName, suppCode, tempPassword, portalUrl }) {
  return callEmailApi("supplier-invite", { to, companyName, suppCode, tempPassword, portalUrl });
}
