import {
  buildIdempotencyKey,
  buildOutcomeEmails,
  deriveOutcomeEvent,
  parseRequestPayload,
} from "./index.ts";

const reportId = "11111111-1111-4111-8111-111111111111";
const reviewedAt = "2026-09-29T00:00:00Z";

Deno.test("request accepts report_id only and rejects caller-selected authority", () => {
  const accepted = parseRequestPayload({ report_id: reportId });
  if (accepted?.reportId !== reportId) throw new Error("report_id request was rejected");
  if (parseRequestPayload({ report_id: reportId, event: "resolved" }) !== null) {
    throw new Error("caller-selected event was accepted");
  }
  if (parseRequestPayload({ report_id: reportId, recipient: "reported" }) !== null) {
    throw new Error("caller-selected recipient was accepted");
  }
});

Deno.test("terminal event is derived only from durable report state", () => {
  if (deriveOutcomeEvent("dismissed", null) !== "dismissed") throw new Error("dismissed derivation failed");
  if (deriveOutcomeEvent("resolved", null) !== "resolved") throw new Error("resolved derivation failed");
  if (deriveOutcomeEvent("resolved", "no_show_strike") !== "no_show_strike") throw new Error("strike derivation failed");
  if (deriveOutcomeEvent("resolved", "account_suspended") !== "account_suspended") throw new Error("suspension derivation failed");
  if (deriveOutcomeEvent("submitted", null) !== null) throw new Error("nonterminal report was accepted");
  if (deriveOutcomeEvent("dismissed", "no_show_strike") !== null) throw new Error("invalid disciplinary state was accepted");
});

Deno.test("reported party email excludes reporter identity and free-form content", () => {
  const messages = buildOutcomeEmails({
    reportId,
    reviewedAt,
    event: "resolved",
    reporterEmail: "reporter@example.test",
    reportedEmail: "reported@example.test",
    adminResponse: "Administrative response",
    bookingReference: "22222222-2222-4222-8222-222222222222",
    strikeCount: null,
  });
  const reported = messages[1].text;
  const forbidden = [
    "reporter@example.test",
    "Reporter Name",
    "+639171234567",
    reportId,
    "Administrative response",
    "22222222",
    "free-form report description",
  ];
  if (forbidden.some((value) => reported.includes(value))) {
    throw new Error("reported-party privacy boundary failed");
  }
});

Deno.test("strike email carries only the server-read strike count", () => {
  const messages = buildOutcomeEmails({
    reportId,
    reviewedAt,
    event: "no_show_strike",
    reporterEmail: "reporter@example.test",
    reportedEmail: "worker@example.test",
    adminResponse: null,
    bookingReference: null,
    strikeCount: 2,
  });
  if (!messages[1].text.includes("2 of 3")) throw new Error("strike count missing");
});

Deno.test("app issue terminal outcome sends only the reporter email", () => {
  const messages = buildOutcomeEmails({
    reportId,
    reviewedAt,
    event: "dismissed",
    reporterEmail: "reporter@example.test",
    reportedEmail: null,
    adminResponse: "The issue was reviewed.",
    bookingReference: null,
    strikeCount: null,
  });
  if (messages.length !== 1 || messages[0].recipient !== "reporter") {
    throw new Error("app issue email recipient boundary failed");
  }
});

Deno.test("retry idempotency keys are stable and recipient-scoped", () => {
  const reporter = buildIdempotencyKey(reportId, reviewedAt, "reporter");
  const retry = buildIdempotencyKey(reportId, reviewedAt, "reporter");
  const reported = buildIdempotencyKey(reportId, reviewedAt, "reported");
  if (reporter !== `skillmatch-report:${reportId}:${reviewedAt}:reporter`) {
    throw new Error("reporter idempotency key is not deterministic");
  }
  if (retry !== reporter || reported === reporter) throw new Error("retry key contract failed");
});
