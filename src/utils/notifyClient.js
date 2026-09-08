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

/**
 * Creates an in-app "bell" notification for a staff ecno — POST /api/notifications,
 * authenticated the same way as the email routes (x-internal-secret) since this
 * is a service-to-service call with no user JWT (see notification-service's
 * internalOrJwtAuth middleware). notification-service persists it and pushes it
 * live over Socket.IO to the recipient's `user:<ecno>` room — no direct
 * Socket.IO usage needed here.
 */
export async function createInAppNotification({ ecno, type = "info", title, message, data }) {
  try {
    const resp = await fetch(`${NOTIFICATION_SERVICE_URL}/api/notifications`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-internal-secret": INTERNAL_BROADCAST_SECRET },
      body: JSON.stringify({ ecno, type, title, message, data }),
      signal: AbortSignal.timeout(5000),
    });
    const body = await resp.json().catch(() => ({}));
    if (!resp.ok) return { sent: false, reason: body.message || `notification-service HTTP ${resp.status}` };
    return { sent: true, notif: body.data };
  } catch (err) {
    return { sent: false, reason: err.message };
  }
}
