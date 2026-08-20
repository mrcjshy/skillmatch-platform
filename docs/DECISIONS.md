# DECISIONS.md — Locked Decisions (ADR-lite)

Append-only. Entries are numbered D-001…; each entry = date, decision, STATUS
(LOCKED / DEFERRED / PENDING-PANEL), and a 1–3 line rationale. Agents may not
contradict LOCKED entries; any change requires Josh. Entries D-001–D-009 were seeded
2026-08-20 from a Josh-approved documentation task specification (intent source), not
derived from code.

### D-001 — 11-table ERD locked (2026-08-20) — LOCKED
No new tables or columns without explicit approval. The capstone schema is fixed at
the 11 tables in the live baseline migration.

### D-002 — Two-stage matching (2026-08-20) — LOCKED
Stage 1 eligibility filter: matching required skill, worker availability, account
active / not suspended. Stage 2 weighted ranking: 40 skill / 30 location /
20 verification / 10 rating; ratio-based skill scoring; cold-start neutral 3.0 is
computation-only ("New — no ratings yet" in UI); tiebreak: fewer completed bookings,
then earlier registration. Location matching is address-based: worker location derives
from existing `users.barangay` and `users.city`; job location derives from existing
`job_postings.address`, `barangay`, and `city`. No live GPS/tracking; no
exact-distance claims unsupported by the stored data.

### D-003 — Worker-choice booking (2026-08-20) — LOCKED
System determines and ranks eligible workers and notifies them; workers choose whether
to accept; the first valid acceptance wins via an atomic PostgreSQL claim; the client
never manually selects from a ranked list. Worker details/contact information become
available to the client only after confirmation; messaging is booking-scoped.

### D-004 — AI feature boundaries (2026-08-20) — LOCKED
Skill gap: canonical result is a rule-based set difference — AI does not determine the
gap; AI may convert the computed result into simple Taglish guidance, on-demand; no
new table. Resume builder: source data = existing worker profile + skills + portfolio;
AI may assist descriptive English only; identifiers/personal data are merged
client-side and are not sent to external AI; fixed HTML/CSS printable PDF; no new
table. FAQ chatbot: fixed developer-created knowledge base, simple Taglish; no
account, booking, payment, or private user-data lookup. No new tables for AI features.

### D-005 — Security function split + INVOKER guard (2026-08-20) — LOCKED
Helper functions are SECURITY DEFINER; the users column guard is SECURITY INVOKER.
See docs/SECURITY.md ("Function security split", "Standing RPC caveat").

### D-006 — Administrator provisioning (2026-08-20) — LOCKED
Administrator provisioning is restricted to trusted backend/database paths such as
service_role or database administration; no normal authenticated registration path may
create administrators.

### D-007 — Local-first Supabase (2026-08-20) — LOCKED
Hosted Supabase changes only with Josh's explicit written authorization; all default
work targets the local stack.

### D-008 — GAP-001 resolution deferred (2026-08-20) — DEFERRED
Cross-user admin management (GAP-001) is deferred to a dedicated, security-reviewed
admin-management task; it must not be absorbed into another piece.

### D-009 — Native/web product direction (2026-08-20) — PENDING-PANEL
Panel question pending (Objective 1): native-primary Worker/Client direction versus
the retained responsive web fallback. Established implementation direction: Expo +
React Native, Android primary; one native application with role routing (not separate
Worker and Client apps); shared Supabase backend with the web application; no
duplicated business logic; WebView is not the final mobile solution. Web retains full
Admin, public landing/information pages, and a responsive Worker/Client fallback.
