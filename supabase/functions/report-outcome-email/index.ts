import { createClient } from "npm:@supabase/supabase-js@2";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const DISCIPLINARY_OUTCOMES = ["no_show_strike", "account_suspended"] as const;
type DisciplinaryOutcome = typeof DISCIPLINARY_OUTCOMES[number];
type Event = "resolved" | "dismissed" | DisciplinaryOutcome;
type Recipient = "reporter" | "reported";

export type OutcomeContext = {
  reportId: string;
  reviewedAt: string;
  event: Event;
  reporterEmail: string;
  reportedEmail: string | null;
  adminResponse: string | null;
  bookingReference: string | null;
  strikeCount: number | null;
};

export function parseRequestPayload(payload: unknown): { reportId: string } | null {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) return null;
  const record = payload as Record<string, unknown>;
  const keys = Object.keys(record);
  if (keys.length !== 1 || keys[0] !== "report_id") return null;
  return typeof record.report_id === "string" && UUID_RE.test(record.report_id)
    ? { reportId: record.report_id }
    : null;
}

export function deriveOutcomeEvent(
  status: unknown,
  disciplinaryOutcome: unknown,
): Event | null {
  const discipline = typeof disciplinaryOutcome === "string" &&
      DISCIPLINARY_OUTCOMES.includes(disciplinaryOutcome as DisciplinaryOutcome)
    ? disciplinaryOutcome as DisciplinaryOutcome
    : null;
  if (status === "dismissed") return discipline === null ? "dismissed" : null;
  if (status === "resolved") return discipline ?? "resolved";
  return null;
}

export function buildIdempotencyKey(
  reportId: string,
  reviewedAt: string,
  recipient: Recipient,
): string {
  return `skillmatch-report:${reportId}:${reviewedAt}:${recipient}`;
}

export function buildOutcomeEmails(context: OutcomeContext) {
  const status = context.event === "dismissed" ? "dismissed" : "resolved";
  const reporterText = [
    `Your SkillMatch report was ${status}.`,
    context.bookingReference ? `Booking reference: ${context.bookingReference}.` : null,
    context.adminResponse ? `Admin response: ${context.adminResponse}` : null,
  ].filter(Boolean).join("\n\n");
  const reportedText = context.event === "account_suspended"
    ? "Your SkillMatch account was suspended after a reviewed no-show outcome."
    : context.event === "no_show_strike"
      ? `A reviewed no-show strike was applied to your SkillMatch account. Current strike count: ${context.strikeCount ?? 0} of 3.`
      : `A report involving one of your SkillMatch bookings was ${status}.`;
  const messages: Array<{
    to: string;
    subject: string;
    text: string;
    recipient: Recipient;
  }> = [
    {
      to: context.reporterEmail,
      subject: `SkillMatch report ${status}`,
      text: reporterText,
      recipient: "reporter",
    },
  ];
  if (context.reportedEmail) {
    messages.push({
      to: context.reportedEmail,
      subject: "SkillMatch account review update",
      text: reportedText,
      recipient: "reported",
    });
  }
  return messages;
}

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "POST required" });
  const authorization = req.headers.get("authorization");
  if (!authorization?.startsWith("Bearer ")) return json(401, { error: "unauthorized" });

  let rawPayload: unknown;
  try {
    rawPayload = await req.json();
  } catch {
    return json(400, { error: "invalid request" });
  }
  const payload = parseRequestPayload(rawPayload);
  if (payload === null) return json(400, { error: "invalid request" });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const resendKey = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("REPORT_OUTCOME_EMAIL_FROM");
  if (!url || !serviceKey || !resendKey || !from) return json(503, { delivered: false });

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const token = authorization.slice(7);
  const { data: authData } = await admin.auth.getUser(token);
  const callerId = authData.user?.id;
  if (!callerId) return json(401, { error: "unauthorized" });
  const { data: caller } = await admin
    .from("users")
    .select("role,is_active")
    .eq("id", callerId)
    .maybeSingle();
  if (caller?.role !== "administrator" || caller.is_active !== true) {
    return json(403, { error: "forbidden" });
  }

  const { data: report } = await admin
    .from("reports")
    .select(
      "id,reporter_id,reported_user_id,booking_id,category,status,admin_response,reviewed_at,disciplinary_outcome",
    )
    .eq("id", payload.reportId)
    .maybeSingle();
  if (!report?.reviewed_at) return json(409, { delivered: false });
  const event = deriveOutcomeEvent(report.status, report.disciplinary_outcome);
  if (event === null) return json(409, { delivered: false });

  const recipientIds = [report.reporter_id, report.reported_user_id].filter(
    (id): id is string => typeof id === "string",
  );
  const { data: recipients } = await admin
    .from("users")
    .select("id,email,role,is_active")
    .in("id", recipientIds);
  const reporter = recipients?.find((row) => row.id === report.reporter_id);
  const reported = recipients?.find((row) => row.id === report.reported_user_id);
  if (!reporter?.email || (report.reported_user_id && !reported?.email)) {
    return json(503, { delivered: false });
  }

  let strikeCount: number | null = null;
  if (event === "no_show_strike" || event === "account_suspended") {
    if (!report.reported_user_id || report.category !== "no-show" || reported?.role !== "worker") {
      return json(409, { delivered: false });
    }
    const { data: profile } = await admin
      .from("worker_profiles")
      .select("strike_count")
      .eq("user_id", report.reported_user_id)
      .maybeSingle();
    strikeCount = typeof profile?.strike_count === "number" ? profile.strike_count : null;
    const stateMatchesEvent = event === "account_suspended"
      ? reported.is_active === false && strikeCount === 3
      : strikeCount !== null && strikeCount >= 1 && strikeCount <= 3;
    if (!stateMatchesEvent) return json(409, { delivered: false });
  }

  const context: OutcomeContext = {
    reportId: report.id,
    reviewedAt: report.reviewed_at,
    event,
    reporterEmail: reporter.email,
    reportedEmail: reported?.email ?? null,
    adminResponse: report.admin_response,
    bookingReference: report.booking_id,
    strikeCount,
  };
  const messages = buildOutcomeEmails(context);
  for (const message of messages) {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        authorization: `Bearer ${resendKey}`,
        "content-type": "application/json",
        "idempotency-key": buildIdempotencyKey(
          report.id,
          report.reviewed_at,
          message.recipient,
        ),
      },
      body: JSON.stringify({
        from,
        to: [message.to],
        subject: message.subject,
        text: message.text,
      }),
    });
    if (!response.ok) return json(200, { delivered: false });
  }
  return json(200, { delivered: true });
}

if (import.meta.main) Deno.serve(handleRequest);
