// ============================================================
// SkillMatch outbound email: Gmail SMTP (owner decision 2026-11-05)
// ============================================================
//
// No email provider was configured on hosted, and the owner chose a free Gmail account over a
// paid provider or a domain. Edge Functions block outbound ports 25 and 587, so this uses
// smtp.gmail.com:465 (implicit TLS) with a Google App Password.
//
// Secrets (Edge env): GMAIL_SMTP_USER (the Gmail address), GMAIL_SMTP_APP_PASSWORD (16 letters,
// spaces allowed), optional EMAIL_FROM_NAME (default "SkillMatch"). Nothing here logs the password,
// the recipient or the content. This file is pure; the Deno-only transport is gmail-transport.ts.

export type OutboundEmail = { to: string; subject: string; text: string; html?: string };
export type SendResult = { ok: true; ref: string | null } | { ok: false; error: string };
/** Sends one email. Never throws: failures come back as { ok: false }. */
export type SendEmail = (email: OutboundEmail) => Promise<SendResult>;

export type GmailConfig = { user: string; appPassword: string; fromName: string };

// One address, no whitespace/CR/LF/commas/angle brackets (header-injection safe).
const EMAIL_RE = /^[^\s@,<>;"]+@[^\s@,<>;"]+\.[^\s@,<>;"]+$/;

export const isSafeEmail = (value: unknown): value is string =>
  typeof value === "string" && value.length <= 254 && EMAIL_RE.test(value);

/** Reads the Gmail settings; null when anything is missing or malformed (callers then do not send). */
export function gmailConfig(get: (name: string) => string | undefined): GmailConfig | null {
  const user = get("GMAIL_SMTP_USER")?.trim();
  const appPassword = get("GMAIL_SMTP_APP_PASSWORD")?.replace(/\s+/g, "");
  const fromName = (get("EMAIL_FROM_NAME")?.trim() || "SkillMatch").replace(/["\r\n<>]/g, "").slice(0, 60) || "SkillMatch";
  if (!isSafeEmail(user) || !appPassword || !/^[A-Za-z0-9]{16}$/.test(appPassword)) return null;
  return { user, appPassword, fromName };
}

/** `"SkillMatch" <address>`: the display name is sanitised in gmailConfig. */
export const formatFrom = (config: GmailConfig) => `"${config.fromName}" <${config.user}>`;
