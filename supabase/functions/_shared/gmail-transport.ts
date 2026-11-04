// Deno-only Gmail SMTP transport (smtp.gmail.com:465, implicit TLS). See gmail-mailer.ts.
import nodemailer from "npm:nodemailer@6.9.16";

import { formatFrom, type GmailConfig, isSafeEmail, type SendEmail } from "./gmail-mailer.ts";

export function createGmailSender(config: GmailConfig): SendEmail {
  const transport = nodemailer.createTransport({
    host: "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: { user: config.user, pass: config.appPassword },
    connectionTimeout: 10_000,
    greetingTimeout: 10_000,
    socketTimeout: 15_000,
  });
  return async (email) => {
    if (!isSafeEmail(email.to)) return { ok: false, error: "invalid_recipient" };
    try {
      const info = await transport.sendMail({
        from: formatFrom(config),
        to: email.to,
        subject: email.subject,
        text: email.text,
        ...(email.html ? { html: email.html } : {}),
      });
      const ref = typeof info?.messageId === "string" ? info.messageId.slice(0, 200) : null;
      return { ok: true, ref };
    } catch (error) {
      // Only the SMTP response code class is kept; never the message (it can echo addresses).
      const code = typeof (error as { responseCode?: unknown })?.responseCode === "number"
        ? `smtp_${(error as { responseCode: number }).responseCode}`
        : "smtp_unreachable";
      return { ok: false, error: code };
    }
  };
}
