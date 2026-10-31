// ============================================================
// Lane C: completion receipt content (pure, no I/O)
// ============================================================
//
// Everything printed here comes from the server-read receipt context
// (public.get_completion_receipt_context, service_role only). Nothing
// is caller-supplied. R3B terminal privacy: after completion the Client
// may not see the Worker's name/contact or the exact job address, so the
// receipt names neither.

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
// Deliberately strict: one address, no whitespace/CR/LF/commas/angle brackets.
const EMAIL_RE = /^[^\s@,<>;"]+@[^\s@,<>;"]+\.[^\s@,<>;"]+$/;
const MANILA_OFFSET_MS = 8 * 60 * 60_000;
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

export type ReceiptContext = {
  booking_id: string;
  booking_status: string;
  completed_at: string;
  payment_method: string | null;
  payment_status: string | null;
  job_title: string | null;
  job_barangay: string | null;
  job_city: string | null;
  job_budget: number | string | null;
  client_full_name: string | null;
  client_email: string;
};

export function parseReceiptRequest(payload: unknown): { bookingId: string } | null {
  if (payload === null || typeof payload !== "object" || Array.isArray(payload)) return null;
  const keys = Object.keys(payload);
  if (keys.length !== 1 || keys[0] !== "booking_id") return null;
  const id = (payload as { booking_id: unknown }).booking_id;
  return typeof id === "string" && UUID_RE.test(id) ? { bookingId: id.toLowerCase() } : null;
}

/** Validates the server row; anything off means "do not send". */
export function validateContext(row: unknown, bookingId: string): ReceiptContext | null {
  if (row === null || typeof row !== "object") return null;
  const r = row as Record<string, unknown>;
  if (typeof r.booking_id !== "string" || r.booking_id.toLowerCase() !== bookingId) return null;
  if (r.booking_status !== "completed") return null;
  if (typeof r.completed_at !== "string" || !Number.isFinite(Date.parse(r.completed_at))) return null;
  if (typeof r.client_email !== "string" || r.client_email.length > 254 || !EMAIL_RE.test(r.client_email)) {
    return null;
  }
  const str = (v: unknown) => (typeof v === "string" ? v : null);
  const budget = typeof r.job_budget === "number" || typeof r.job_budget === "string" ? r.job_budget : null;
  return {
    booking_id: r.booking_id,
    booking_status: "completed",
    completed_at: r.completed_at,
    payment_method: str(r.payment_method),
    payment_status: str(r.payment_status),
    job_title: str(r.job_title),
    job_barangay: str(r.job_barangay),
    job_city: str(r.job_city),
    job_budget: budget,
    client_full_name: str(r.client_full_name),
    client_email: r.client_email,
  };
}

/** One logical receipt per Booking: completion is terminal. */
export function buildReceiptDedupKey(bookingId: string): string {
  return `completion-receipt:${bookingId.toLowerCase()}`;
}

export function bookingReference(bookingId: string): string {
  return `SM-${bookingId.replace(/-/g, "").slice(0, 8).toUpperCase()}`;
}

/** "14 Oct 2026, 11:05 AM (Asia/Manila)". Deterministic, no host ICU. */
export function formatManilaDateTime(iso: string): string {
  const d = new Date(Date.parse(iso) + MANILA_OFFSET_MS);
  const h = d.getUTCHours();
  const h12 = h % 12 === 0 ? 12 : h % 12;
  const mm = String(d.getUTCMinutes()).padStart(2, "0");
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()}, ${h12}:${mm} ${h < 12 ? "AM" : "PM"} (Asia/Manila)`;
}

/** Exact decimal formatting from numeric(10,2); no float arithmetic. */
export function formatPeso(value: number | string | null): string {
  if (value === null) return "Not recorded";
  const raw = typeof value === "number" ? value.toFixed(2) : value.trim();
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(raw);
  if (!m) return "Not recorded";
  const whole = m[1].replace(/^0+(?=\d)/, "").replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const cents = (m[2] ?? "").padEnd(2, "0");
  return `PHP ${whole}.${cents}`;
}

export function paymentMethodLabel(method: string | null): string {
  switch (method) {
    case "cod":
      return "Cash on delivery (COD)";
    case "qrph":
      return "QR Ph via PayMongo (TEST MODE)";
    case "gcash":
      return "GCash";
    case "maya":
      return "Maya";
    default:
      return "Not selected";
  }
}

/** The recorded state only. Completion never implies payment. */
export function paymentStatusLabel(status: string | null): string {
  switch (status) {
    case "paid":
      return "Paid (as recorded in SkillMatch)";
    case "refunded":
      return "Refunded (as recorded in SkillMatch)";
    case "pending":
      return "Not recorded as paid";
    default:
      return "Not recorded";
  }
}

export const QRPH_TEST_NOTICE =
  "QR Ph payments in SkillMatch use PayMongo TEST MODE. This was a simulation: no real money moved.";
export const DISCLAIMER =
  "This is a SkillMatch booking summary. It is not an official receipt or tax invoice, and it is not proof that money was transferred.";

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function oneLine(s: string | null, max: number): string | null {
  if (s === null) return null;
  const t = s.replace(/[\r\n\t]+/g, " ").replace(/\s+/g, " ").trim();
  if (t === "") return null;
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

export type ReceiptEmail = { to: string; subject: string; text: string; html: string };

export function buildReceiptEmail(ctx: ReceiptContext): ReceiptEmail {
  const ref = bookingReference(ctx.booking_id);
  const service = oneLine(ctx.job_title, 150) ?? "SkillMatch service";
  const area = [oneLine(ctx.job_barangay, 100), oneLine(ctx.job_city, 100)].filter(Boolean).join(", ");
  const name = oneLine(ctx.client_full_name, 100);
  const rows: Array<[string, string]> = [
    ["Booking reference", `${ref} (${ctx.booking_id})`],
    ["Service", service],
    ...(area ? [["Area", area] as [string, string]] : []),
    ["Completed", formatManilaDateTime(ctx.completed_at)],
    ["Worker", "Your SkillMatch Worker"],
    ["Amount (job budget)", formatPeso(ctx.job_budget)],
    ["Payment method", paymentMethodLabel(ctx.payment_method)],
    ["Payment status", paymentStatusLabel(ctx.payment_status)],
  ];
  const notices = [
    ...(ctx.payment_method === "qrph" ? [QRPH_TEST_NOTICE] : []),
    DISCLAIMER,
  ];
  const greeting = name ? `Hi ${name},` : "Hi,";
  const intro = "Your SkillMatch booking was marked completed. Here is a summary for your records.";
  const footer = "You received this because a booking on your SkillMatch Client account was completed.";

  const text = [
    greeting,
    "",
    intro,
    "",
    ...rows.map(([k, v]) => `${k}: ${v}`),
    "",
    ...notices,
    "",
    footer,
    "SkillMatch",
  ].join("\n");

  // SkillMatch brand tokens from DESIGN.md (page, ink, ink-muted, accent, line,
  // light). Email clients rarely load web fonts, so the documented families
  // are listed first with system fallbacks.
  const body = "'DM Sans Variable','DM Sans',Arial,Helvetica,sans-serif";
  const heading = "'Manrope Variable',Manrope,Arial,Helvetica,sans-serif";
  const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#faf8f3;font-family:${body};color:#233d35">
<table role="presentation" width="100%" style="max-width:560px;margin:0 auto;background:#ffffff;border-radius:16px;border:1px solid #dddcd2">
<tr><td style="padding:20px 24px;border-bottom:3px solid #af452e"><strong style="font-family:${heading};font-size:20px;color:#233d35">SkillMatch</strong><div style="font-size:13px;color:#59665e">Booking completion summary</div></td></tr>
<tr><td style="padding:20px 24px;font-size:15px;line-height:1.5">
<p style="margin:0 0 12px">${escapeHtml(greeting)}</p>
<p style="margin:0 0 16px">${escapeHtml(intro)}</p>
<table role="presentation" width="100%" style="border-collapse:collapse;font-size:14px">
${rows.map(([k, v]) => `<tr><td style="padding:6px 8px 6px 0;color:#59665e;vertical-align:top;white-space:nowrap">${escapeHtml(k)}</td><td style="padding:6px 0;vertical-align:top">${escapeHtml(v)}</td></tr>`).join("\n")}
</table>
${notices.map((n) => `<p style="margin:16px 0 0;padding:10px 12px;background:#fff8ed;border:1px solid #ecd9bd;border-radius:8px;font-size:13px">${escapeHtml(n)}</p>`).join("\n")}
</td></tr>
<tr><td style="padding:16px 24px;font-size:12px;color:#59665e;border-top:1px solid #dddcd2">${escapeHtml(footer)}</td></tr>
</table></body></html>`;

  return {
    to: ctx.client_email,
    subject: `SkillMatch booking ${ref} completed - summary`,
    text,
    html,
  };
}
