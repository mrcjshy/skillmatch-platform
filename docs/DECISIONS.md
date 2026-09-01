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

#### Amendment — Verification Gate and Three-Factor Ranking (2026-08-31) — LOCKED
Verification moves from Stage 2 weighted ranking into Stage 1 eligibility.

A Worker is eligible for matching only when all of the following are true:

- `users.role = 'worker'`
- `users.is_active = true`
  - this represents active / not suspended status
  - suspension, including the three-strike suspension rule when implemented,
    sets this false and removes the Worker from the candidate set
- `worker_profiles.availability_status = 'available'`
- `worker_profiles.is_verified = true`
- the Worker shares at least one required skill with the job

Verification is therefore a **safety precondition**, not a ranking preference.

Only eligible Workers proceed to Stage 2.

**Stage 2 weighted ranking**

Skill      50
Location   30
Rating     20
Total     100

**Skill**

matched required skills / total required skills × 50

Worker proficiency may be displayed for explainability/profile context
but does not affect the matching score.

**Location**

same barangay + same city = 30
same city only            = 10
otherwise                 = 0

Location remains address-based using existing stored location fields.

No GPS.
No exact-distance claim.
No zone scoring at this stage.

**Rating**

For a Worker with received ratings:

rating_avg / 5 × 20

For a Worker with no received ratings:

- neutral `3.0` is used for computation only
- rating component = `12/20`
- expose `is_new_worker = true`
- UI later displays `New — no ratings yet`
- neutral 3.0 must not be represented as an actual Worker rating

**Ranking order**

1. weighted total descending
2. fewer completed bookings
3. earlier registration

**Rationale**

Moving verification into eligibility ensures that only administrator-vetted
Workers can receive livelihood opportunities.

Verification is a safety requirement rather than a ranking preference.

Rebasing the ranking to:

50 Skill / 30 Location / 20 Rating

preserves:

Skill > Location > Rating

while retaining Location /30 for possible future refinement.

Effective status of D-002 from this amendment onward: LOCKED as amended.
The original Stage 2 line (40 skill / 30 location / 20 verification / 10 rating)
is retained above for append-only provenance but is superseded by this amendment.

#### Clarification — N8 Secure Computation Boundary (2026-08-31) — LOCKED
N8 matching will use:

private.compute_job_matches(job_id)
public.match_workers_for_job(p_job_id)

Security requirements:

- private computation function is not directly callable by client roles
- revoke EXECUTE from `PUBLIC`
- revoke EXECUTE from `authenticated`
- grant no client-facing EXECUTE permission to the private function
- authenticated public wrapper performs caller/job authorization before invoking private computation
- public wrapper uses a restricted `SECURITY DEFINER` boundary
- wrapper uses `search_path = ''`
- only the minimum projection required for matching/explainability is returned
- Worker phone, email, residential address, and unnecessary private data are not exposed

Downstream consequences:

- demo Worker must be administrator-verified before hosted N8 matching tests
- N9 acceptance must re-check `is_active = true` and `is_verified = true`
  at acceptance time
- Admin Worker verification becomes operationally required for real participant matching
- manuscript consistency work later describes verification as an eligibility
  precondition and ranking as the three-factor Skill / Location / Rating mechanism
- parked zone refinement remains out of scope and requires a future explicit
  D-001 + D-002 amendment before schema changes

#### Clarification — N8 Worker Opportunity Read Boundary (2026-09-01) — LOCKED
N8 adds a Worker-facing read boundary through:

`public.list_my_job_opportunities()`

The function accepts no Worker identifier parameter. The current Worker is derived
only from `auth.uid()`.

Caller authorization and matching eligibility are intentionally separated.

An unauthenticated caller, Client, Administrator, inactive Worker, or other caller
that fails the active-Worker authorization gate receives an authorization failure
(`42501`).

An authenticated active Worker who is currently unverified, busy, offline, has no
required-skill overlap, or otherwise does not satisfy the authoritative Stage 1
matching eligibility rules receives a successful response with zero opportunity rows
rather than an authorization error.

The Worker-facing wrapper does not reproduce Stage 1 eligibility or the
Skill 50 / Location 30 / Rating 20 scoring mechanism. Both remain authoritative
inside `private.compute_job_matches(job_id)`. For each open job, the Worker wrapper
reuses that scorer and retains only the row whose `worker_id` equals the
authenticated caller.

The Worker-facing projection is limited to:

- `job_id`
- `title`
- `description`
- `barangay`
- `city`
- `budget`
- `scheduled_at`
- `skill_points`
- `location_points`
- `rating_points`
- `total_points`

The Worker opportunity surface does not expose Client identity or contact
information, other Worker identities, competitor scores, candidate counts, or the
Worker's rank against other candidates.

Returned opportunities use the following deterministic presentation order:

1. `total_points DESC`
2. `scheduled_at ASC NULLS LAST`
3. `job_id ASC`

This ordering is presentation-only. It is not an additional D-002 scoring factor,
does not alter the within-job Worker ranking rules, and is not persisted.

The existing `public.match_workers_for_job(job_id)` function remains the
owning-Client diagnostic and explainability surface for the current implementation.
It is not a Client Worker-selection mechanism and does not change D-003: the Client
does not manually choose a Worker. The longer-term product disposition of this
diagnostic Client surface may be revisited after the defense without changing the
current worker-choice booking model.

Implementation observation: `public.list_my_job_opportunities()` evaluates open jobs
through the authoritative scorer using a LATERAL/equivalent scorer call per open job.
Its computational cost therefore scales with the number of open jobs. This is
accepted for the current capstone-scale workload. A future optimization must not
duplicate, bypass, or create a second authoritative copy of the matching rules
without an approved implementation decision.

### D-003 — Worker-choice booking (2026-08-20) — LOCKED
System determines and ranks eligible workers and notifies them; workers choose whether
to accept; the first valid acceptance wins via an atomic PostgreSQL claim; the client
never manually selects from a ranked list. Worker details/contact information become
available to the client only after confirmation; messaging is booking-scoped.

#### Clarification — N9 Atomic Worker Acceptance Boundary (2026-09-01) — LOCKED
N9 implements Worker acceptance through:

`public.accept_job_opportunity(p_job_id uuid)`

The function accepts exactly one Job identifier and no Worker identifier. The
accepting Worker is derived exclusively from `auth.uid()`.

The acceptance flow preserves the Worker-choice booking model:

Client posts a Job → the system determines eligible/ranked Workers → an eligible
Worker sees the opportunity → the Worker accepts → the first valid Worker
acceptance wins → the Booking is created.

The Client does not manually select, assign, or substitute a Worker.

Acceptance is atomic. The target `job_postings` row is locked with
`SELECT ... FOR UPDATE` before the acceptance decision proceeds. If two eligible
Workers attempt to accept the same open Job concurrently, only the transaction
holding the Job row lock can proceed first. After the winning transaction creates
the Booking and changes the Job to `matched`, the losing transaction re-reads the
committed non-open state and receives the unavailable result.

Acceptance-time match eligibility is revalidated through the authoritative
`private.compute_job_matches(p_job_id)` scorer for the authenticated Worker. N9
does not reproduce the matching rules locally. The re-check therefore covers the
current Worker role/account state, active status, verification status,
availability, and required-skill overlap using the same authoritative matching
boundary established by D-002/N8.

A successful acceptance creates exactly one Booking for the winning transaction
with:

- `job_id` from the locked Job
- `worker_id` from `auth.uid()`
- `client_id` from the locked Job owner
- `status = 'confirmed'`

The same transaction changes the Job from `open` to `matched`.

The Booking begins as `confirmed` because the Worker acceptance itself is the
confirmation event under the Worker-choice model. The legacy `pending` Booking
default is not used as the acceptance state. Payment processing is not performed
by N9; the existing payment fields remain at their existing unset/default values
until the separate payment lifecycle is implemented.

The successful RPC result is limited to:

- `booking_id`
- `job_id`
- `booking_status`
- `job_status`

It does not expose Client identity/contact information, competitor information,
candidate rank, or matching details that are not required for the acceptance
result.

The implemented acceptance error boundary is:

- authorization failure → SQLSTATE `42501`
- authenticated Worker is no longer match-eligible → SQLSTATE `SM403`
- Job is nonexistent or no longer available/open → SQLSTATE `SM409`

Nonexistent and non-open Jobs intentionally use the same unavailable response so
the Worker-facing surface does not disclose whether an arbitrary Job identifier
exists.

Direct application Booking creation and modification are not part of the N9 flow.
The legacy direct authenticated Booking INSERT and UPDATE policies were removed.
Booking cancellation, completion, no-show handling, and payment-state changes
therefore require future controlled lifecycle RPCs rather than ordinary
participant table writes.

Client direct Job UPDATE and DELETE are restricted to Jobs that are currently
`open`. A direct Client UPDATE must also leave the Job `open`. As a result, an
ordinary Client cannot directly transition a Job to `matched`, reopen a matched
Job, or directly delete a matched Job after a Worker has won.

The `bookings.job_id → job_postings.id` foreign key remains `ON DELETE CASCADE`;
N9 does not change that foreign key. The winning confirmed Booking is protected
from ordinary Client-triggered cascade deletion by the open-only Job DELETE
authorization boundary.

A database uniqueness rule on `bookings.job_id` remains deferred.
Cancellation/rematching semantics must be decided before introducing a uniqueness
constraint or partial unique index. N9 first-wins correctness currently comes from
the Job row lock, atomic Job state transition, removal of direct Booking writes,
and open-only Client Job lifecycle access.

Notifications are not created by N9 and remain a separate module.

Verification boundary as of this entry:

- N9 local implementation and concurrency: VERIFIED
- N9 hosted migration: DEPLOYED
- N9 hosted catalog/security boundary: VERIFIED
- N9 hosted authenticated acceptance: NOT YET TESTED
- N9 hosted concurrency: NOT YET TESTED
- N9 native UI: NOT YET TESTED
- Full booking E2E: NOT YET TESTED

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

#### Resolution (2026-08-24) — LOCKED

Panel-approved architecture: SkillMatch's operational Worker, Client, and
Administrator interfaces are delivered through one Expo + React Native
application with role-based routing, Android as the primary target, and a
shared Supabase backend. The React/Vite web application is limited to the
public landing/information site. It is not an operational role interface or
responsive fallback. WebView is not the final mobile implementation.

Effective status of D-009 from this resolution onward: LOCKED.

Resolution recorded 2026-08-24: Josh confirmed panel approval. The original
PENDING-PANEL text above is retained for append-only provenance but is
superseded by this resolution, including its former web Admin and responsive
Worker/Client fallback architecture.
