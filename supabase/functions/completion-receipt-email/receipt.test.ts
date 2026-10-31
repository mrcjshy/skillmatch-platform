// Runs under `node --test` (Node 22.6+ type stripping) and `deno test`.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  bookingReference,
  buildReceiptDedupKey,
  buildReceiptEmail,
  DISCLAIMER,
  formatManilaDateTime,
  formatPeso,
  parseReceiptRequest,
  paymentStatusLabel,
  QRPH_TEST_NOTICE,
  validateContext,
} from "./receipt.ts";
import type { ReceiptContext } from "./receipt.ts";

const BID = "abcdef12-1111-4111-8111-111111111111";

function ctx(over: Partial<ReceiptContext> = {}): ReceiptContext {
  return {
    booking_id: BID,
    booking_status: "completed",
    completed_at: "2026-10-14T03:05:12.345678+00:00",
    payment_method: "cod",
    payment_status: "paid",
    job_title: "Fix kitchen sink",
    job_barangay: "Santa Ana",
    job_city: "Manila",
    job_budget: 1500,
    client_full_name: "Juan Dela Cruz",
    client_email: "client@example.test",
    ...over,
  };
}

test("request accepts booking_id only; caller cannot pick recipient or amount", () => {
  assert.deepEqual(parseReceiptRequest({ booking_id: BID }), { bookingId: BID });
  assert.deepEqual(parseReceiptRequest({ booking_id: BID.toUpperCase() }), { bookingId: BID });
  assert.equal(parseReceiptRequest({ booking_id: BID, to: "attacker@example.test" }), null);
  assert.equal(parseReceiptRequest({ booking_id: BID, amount: 1 }), null);
  assert.equal(parseReceiptRequest({ booking_id: "nope" }), null);
  assert.equal(parseReceiptRequest([BID]), null);
});

test("server context must be completed, match the booking and carry one clean email", () => {
  assert.ok(validateContext(ctx(), BID));
  assert.equal(validateContext(null, BID), null);
  assert.equal(validateContext({ ...ctx(), booking_status: "confirmed" }, BID), null);
  assert.equal(validateContext({ ...ctx(), booking_id: "99999999-1111-4111-8111-111111111111" }, BID), null);
  assert.equal(validateContext({ ...ctx(), completed_at: null }, BID), null);
  for (const bad of ["", "a@b", "a@b.c\r\nBcc: x@y.z", "a@b.c, d@e.f", "<a@b.c>", "a b@c.d"]) {
    assert.equal(validateContext({ ...ctx(), client_email: bad }, BID), null, bad);
  }
});

test("dedup key is one per booking", () => {
  assert.equal(buildReceiptDedupKey(BID), `completion-receipt:${BID}`);
  assert.equal(buildReceiptDedupKey(BID.toUpperCase()), buildReceiptDedupKey(BID));
});

test("completion time is rendered in Asia/Manila across the UTC date boundary", () => {
  assert.equal(formatManilaDateTime("2026-10-14T03:05:12.345678+00:00"), "14 Oct 2026, 11:05 AM (Asia/Manila)");
  assert.equal(formatManilaDateTime("2026-12-31T16:30:00Z"), "1 Jan 2027, 12:30 AM (Asia/Manila)");
  assert.equal(formatManilaDateTime("2026-10-14T04:00:00Z"), "14 Oct 2026, 12:00 PM (Asia/Manila)");
});

test("peso formatting is exact", () => {
  assert.equal(formatPeso(1500), "PHP 1,500.00");
  assert.equal(formatPeso("1234567.5"), "PHP 1,234,567.50");
  assert.equal(formatPeso("0.10"), "PHP 0.10");
  assert.equal(formatPeso(99999999.99), "PHP 99,999,999.99");
  assert.equal(formatPeso(null), "Not recorded");
  assert.equal(formatPeso("-5"), "Not recorded");
});

test("payment status is the recorded state; completion never implies paid", () => {
  assert.equal(paymentStatusLabel("paid"), "Paid (as recorded in SkillMatch)");
  assert.equal(paymentStatusLabel("pending"), "Not recorded as paid");
  assert.equal(paymentStatusLabel(null), "Not recorded");
  const email = buildReceiptEmail(ctx({ payment_status: "pending" }));
  assert.match(email.text, /Payment status: Not recorded as paid/);
  assert.doesNotMatch(email.text, /Paid \(/);
});

test("QR Ph receipts are labelled as PayMongo test-mode simulations", () => {
  const qr = buildReceiptEmail(ctx({ payment_method: "qrph" }));
  assert.match(qr.text, /QR Ph via PayMongo \(TEST MODE\)/);
  assert.ok(qr.text.includes(QRPH_TEST_NOTICE));
  assert.ok(qr.html.includes("no real money moved"));
  const cod = buildReceiptEmail(ctx());
  assert.ok(!cod.text.includes(QRPH_TEST_NOTICE));
});

test("every receipt says it is not a tax invoice or proof of transfer", () => {
  for (const method of ["cod", "qrph", null]) {
    const email = buildReceiptEmail(ctx({ payment_method: method }));
    assert.ok(email.text.includes(DISCLAIMER));
    assert.ok(email.html.includes("not an official receipt or tax invoice"));
  }
});

test("content: reference, service, Manila time, amount; no Worker identity or exact address", () => {
  const email = buildReceiptEmail(ctx());
  assert.equal(email.to, "client@example.test");
  assert.equal(email.subject, `SkillMatch booking ${bookingReference(BID)} completed - summary`);
  assert.equal(bookingReference(BID), "SM-ABCDEF12");
  assert.match(email.text, /Booking reference: SM-ABCDEF12 \(abcdef12-1111-4111-8111-111111111111\)/);
  assert.match(email.text, /Service: Fix kitchen sink/);
  assert.match(email.text, /Area: Santa Ana, Manila/);
  assert.match(email.text, /Completed: 14 Oct 2026, 11:05 AM \(Asia\/Manila\)/);
  assert.match(email.text, /Amount \(job budget\): PHP 1,500.00/);
  assert.match(email.text, /Payment method: Cash on delivery \(COD\)/);
  assert.match(email.text, /Worker: Your SkillMatch Worker/);
  assert.match(email.text, /^Hi Juan Dela Cruz,/);
});

test("untrusted text is escaped in HTML and flattened in text", () => {
  const email = buildReceiptEmail(ctx({
    job_title: "<script>alert(1)</script>\r\nBcc: x",
    client_full_name: "A & \"B\"",
  }));
  assert.ok(!email.html.includes("<script>"));
  assert.ok(email.html.includes("&lt;script&gt;"));
  assert.ok(email.html.includes("A &amp; &quot;B&quot;"));
  assert.match(email.text, /Service: <script>alert\(1\)<\/script> Bcc: x/);
  assert.ok(!email.subject.includes("script"));
});
