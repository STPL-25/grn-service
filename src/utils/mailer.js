/**
 * Minimal SMTP mailer for supplier-portal invites. No email-sending
 * capability exists anywhere else in this codebase, so this is new.
 *
 * Mirrors this codebase's dev-bypass convention: without SMTP_HOST/USER/PASS
 * configured, sendMail() logs the message to the console instead of
 * throwing, so the invite flow is testable before real credentials exist.
 */
import nodemailer from "nodemailer";
import { configDotenv } from "dotenv";
configDotenv();

const SMTP_HOST = process.env.SMTP_HOST;
const SMTP_PORT = parseInt(process.env.SMTP_PORT || "587");
const SMTP_USER = process.env.SMTP_USER;
const SMTP_PASS = process.env.SMTP_PASS;
const SMTP_FROM = process.env.SMTP_FROM || SMTP_USER;

const isConfigured = Boolean(SMTP_HOST && SMTP_USER && SMTP_PASS);

const transporter = isConfigured
  ? nodemailer.createTransport({
      host: SMTP_HOST,
      port: SMTP_PORT,
      secure: SMTP_PORT === 465,
      auth: { user: SMTP_USER, pass: SMTP_PASS },
    })
  : null;

/** @param {{ to: string, subject: string, text: string, html?: string }} message */
async function sendMail(message) {
  if (!isConfigured) {
    console.log(`[mailer] SMTP not configured — logging message instead of sending:\n`, message);
    return { sent: false, reason: "SMTP not configured" };
  }

  await transporter.sendMail({ from: SMTP_FROM, ...message });
  return { sent: true };
}

function buildSupplierInviteEmail({ to, companyName, suppCode, tempPassword, portalUrl }) {
  return {
    to,
    subject: "Your supplier portal access",
    text:
      `Hello ${companyName},\n\n` +
      `You've been granted access to the supplier portal.\n\n` +
      `Login URL: ${portalUrl}\n` +
      `Login ID (Supplier Code): ${suppCode}\n` +
      `Temporary password: ${tempPassword}\n\n` +
      `You'll be asked to set a new password on first login.`,
  };
}

export { sendMail, buildSupplierInviteEmail, isConfigured as isMailerConfigured };
