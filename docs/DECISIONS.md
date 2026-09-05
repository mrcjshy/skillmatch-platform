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

#### Clarification — N10 Administrator Verification Operationalized (2026-09-05) — LOCKED
The D-002 amendment made `worker_profiles.is_verified = true` a Stage 1 eligibility
precondition. It did not provide a controlled path for an Administrator to set that
column, so verification was a locked requirement with no operational mechanism. N10
supplies the mechanism. This clarification records the implemented reality; it does not
change the amendment.

Verification remains a Stage 1 eligibility precondition and is **not** a Stage 2 ranking
factor. The ranking remains Skill 50 / Location 30 / Rating 20.

Administrator verification is operational through two reviewed RPCs:

`public.list_unverified_workers()`
`public.verify_worker(p_worker_user_id uuid)`

`public.verify_worker(uuid)` is the authoritative controlled write path for this
operation. It writes only the two fields the operation requires:

- `worker_profiles.is_verified`
- `worker_profiles.verified_by`

It preserves the role/authorization checks and the unavailable boundary: a caller who is
not an active administrator receives `42501`; an already-verified Worker, a non-worker
target, and a nonexistent target all receive the same `SM409`, so the function is not an
account-existence oracle and a second verification cannot overwrite the original
`verified_by` attribution. The target profile row is locked `FOR UPDATE` before the
decision proceeds.

N12 later added trusted `worker_verified` notification emission inside the same
authoritative verification transaction. That addition changes neither the D-002 matching
weights nor the verification-gate semantics.

**GAP-003 precision.** N10 solves the Worker-verification use-case operationally. It does
**not** close the broader `worker_profiles` administrative-policy gap. Administrators do
**not** now hold general cross-user UPDATE access: `worker_profiles` UPDATE RLS remains
self-row only, and `verify_worker` reaches the row as a postgres-owned SECURITY DEFINER
function, not through a widened policy. Controlled administration of `strike_count`,
`badge_level`, and protected profile fields generally remains outside N10 and unresolved.
GAP-003 remains OPEN / DEFERRED. See docs/SECURITY.md.

#### Clarification — Ratings Pre-Defense Contract (2026-09-05) — LOCKED, NOT YET IMPLEMENTED
D-002 scores a Rating component out of 20 but nothing has ever written the column it
reads. This entry locks the rules a later Ratings piece must implement. **It changes no
part of the Stage 2 model: Skill 50 / Location 30 / Rating 20 is untouched.**

- **Direction:** Client → Worker only.
- **Eligibility:** the Booking must be `completed`.
- **Rater:** that Booking's Client. **`rated_user`:** that Booking's Worker.
- **Duplicate prevention:** the existing `UNIQUE (booking_id, rated_by)` constraint
  already prevents the same rater rating the same Booking twice. No new constraint is
  required for that case.
- **Immutability:** ratings carry no UPDATE and no DELETE path.
- **Aggregate strategy pre-defense:** the later trusted rating RPC maintains
  `worker_profiles.rating_avg` transactionally, so the N8 scorer continues to read the
  column exactly as it does today and is not modified.

Immutability is load-bearing for that last point: transactional maintenance of
`rating_avg` is only sound while ratings cannot be edited or removed outside the trusted
recomputation path.

**None of this is implemented.** Today the `ratings` INSERT policy checks only
`rated_by = auth.uid()` — it does not enforce Booking participation, completed status,
direction, or that `rated_user` is the counterparty. Those remain open security gaps
recorded in docs/SECURITY.md. The alternative strategy of computing a live average from
`public.ratings` and changing what the scorer reads is **not** current behaviour and is
not adopted here.

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

#### Clarification — N9 Status Closure and N12 Emission (2026-09-05) — LOCKED
The two statements above — "Notifications are not created by N9 and remain a separate
module" and the "Verification boundary as of this entry" list — describe the N9 boundary
**at the date they were written (2026-09-01)** and are retained as dated provenance. Both
were true then. Later verified work has superseded them operationally, as recorded here.
Neither is rewritten.

Current verification status:

- N9 hosted authenticated acceptance: **VERIFIED**
- N9 hosted concurrency / first-valid-acceptance behavior: **VERIFIED**
- N9 native UI: **VERIFIED**
- Full continuous booking E2E in one uninterrupted rehearsal: **NOT YET VERIFIED —
  rehearsal still needed.** The original "Full booking E2E: NOT YET TESTED" line above
  therefore remains current, not merely historical.

These statuses are previously closed evidence synchronized here on 2026-09-05. No test
was performed by this documentation task.

Notification emission. N12 replaced `public.accept_job_opportunity(p_job_id uuid)` via
`CREATE OR REPLACE`, preserving the N9 acceptance, authorization and concurrency contract
— every argument, return column, error code and message, the `FOR UPDATE` Job lock, the
authoritative eligibility re-check, the security properties, `search_path` and ACL — and
adding atomic trusted notification emission after the authoritative writes.

On a successful acceptance N12 emits exactly:

- one `booking_confirmed` notification to the Worker
- one `booking_confirmed` notification to the Client

Emission is inside the acceptance transaction, so a failed acceptance emits nothing. This
does not change the Worker-choice booking model: the Client still does not select,
assign, or substitute a Worker, and the first valid Worker acceptance still wins.

#### Clarification — N11 Participant Booking Visibility (2026-09-05) — LOCKED
D-003 states that Worker details and contact information become available to the Client
only after confirmation. N11 implements that contact-release principle as a read boundary
through two RPCs:

`public.list_my_worker_bookings()`
`public.list_my_client_bookings()`

Contract:

- caller identity derives exclusively from `auth.uid()`
- neither function takes a participant-id or Booking-id parameter, so one participant
  cannot enumerate another's list
- an owned Booking is listed **regardless of Booking status**, so history never
  disappears
- Booking status controls only whether counterparty information is released

Ownership and status are therefore separate axes. Release states are `confirmed` and
`completed`; `pending`, `cancelled` and `no_show` suppress.

Privacy boundaries:

- Worker-facing list: Client `full_name` and `phone` released in released states only.
  Client email is never projected.
- Client-facing list: the approved Worker profile block released in released states only,
  gated as one unit so no field can leak while a sibling is suppressed. Worker email is
  never projected, and neither is `verified_by`.
- Worker skill projection: NULL when suppressed; an empty array when released for a
  Worker with no skills; otherwise a deterministic de-duplicated alphabetical projection.
  The empty-array case is distinguishable from suppression.
- Ratings shown by N11 are aggregated from `public.ratings`, **not** from
  `worker_profiles.rating_avg`, which nothing maintains. A Worker with no received
  ratings yields count `0` and average `NULL` — never an actual `0` and never the
  computation-only neutral `3.0` of D-002. Individual scores, comments and `rated_by`
  are never projected.

This implements the post-confirmation contact-release principle **without widening the
`public.users` self-row-only SELECT policy**. Widening that policy would have exposed
every account's contact details to every authenticated user, far beyond Bookings; these
two functions are the only new cross-participant identity surface.

#### Clarification — BL-01A Booking Lifecycle Contract (2026-09-05) — LOCKED
N9 removed the direct authenticated Booking INSERT and UPDATE policies without
replacing them, which closed the Client-assigns-Worker side door but also left every
confirmed Booking permanent and its Job permanently `matched`. BL-01A adds the two
lifecycle exits, and only those two. Everything below marked IMPLEMENTED is live in
`bl01a_db_01_booking_completion_cancellation`; everything marked LOCKED — NOT YET
IMPLEMENTED or DEFERRED is not.

**Completion — IMPLEMENTED.** Actor: **the owning Client only**.

- Booking `confirmed` → `completed`
- Job `matched` → `completed`
- `bookings.completed_at` is set from trusted database time, never from the caller

The Worker does not complete the Booking: completion is the Client's attestation that
the work was delivered, and under the payment sequencing below it is the event a later
payment piece depends on. There is **no intermediate worker-finished state**, and the
legacy Booking `pending` value is **not** repurposed to create one.

**Cancellation — IMPLEMENTED.** Actors: **the assigned Worker or the owning Client**.

- Booking `confirmed` → `cancelled`
- Job `matched` → `cancelled`

Cancellation is **terminal**: no automatic reopen, no automatic rematching, and no
replacement Booking is generated. If the Client still requires the service they create a
new Job. This is a deliberate pre-defense product and security decision, not a schema
limitation — it keeps N9's first-valid-acceptance concurrency model exactly as it is. The
cancelled Booking is retained as history and is never deleted.

**Payment sequencing — LOCKED.** Service completion occurs **before** payment.
Completion itself does not mark anything paid, and BL-01A writes no payment column:
`payment_method`, `payment_status` and `paymongo_ref` are preserved unchanged by both
functions. Ordinary pre-defense cancellation happens before payment settlement, so it
triggers no refund flow. Neither PayMongo nor COD is implemented.

**No-show and strikes — DEFERRED PRE-DEFENSE.** The three-strike concept in the D-002
amendment is unchanged and is not withdrawn. What is deferred is the *operational* path:
no-show reporting, `strike_count` mutation, and automatic third-strike enforcement are
not part of BL-01A and remain deferred until their abuse and adjudication rules can be
defined safely. `status = 'no_show'` remains a schema value that no code path produces.

**RPC shape — LOCKED.** Lifecycle writes use **narrow action-specific RPCs**, not a
generic action-string transition function. The two actions have different actors —
completion is Client-only, cancellation is either participant — and a single entry point
would multiplex two authorization models behind one EXECUTE grant. This also matches the
convention every existing public RPC in this project already follows.

**Lock ordering — IMPLEMENTED.** Lifecycle mutators that touch both records lock in the
fixed order **Booking row → Job row**, never inverted. A consistent lock order across
lifecycle mutators avoids lock-order inversions and keeps concurrent terminal
transitions deterministic. Every authorization and state decision is made from the
locked row values, never from a pre-lock read.

**Repeat-safe terminal handling — IMPLEMENTED.** A repeated completion or cancellation
request against a Booking that is no longer valid for the requested transition returns
the conflict class, performs no second state mutation, and emits no duplicate
notification. This is deliberately described as repeat-safe terminal handling rather
than idempotency: the repeated call does not succeed quietly, it conflicts.

**Notification matrix — IMPLEMENTED.** Emitted inside the same transaction as the
authoritative write:

- Client completion → the **Worker** receives `booking_completed`
- Client cancellation → the **Worker** receives `booking_cancelled`
- Worker cancellation → the **Client** receives `booking_cancelled`

In short: completed notifies the Worker; cancelled notifies the counterparty. The actor
is never notified of their own action. A rating-received notification remains deferred.

#### Clarification — Messaging Send Boundary (2026-09-05) — LOCKED, IMPLEMENTED (BL-01C)
D-003 already locks that messaging is Booking-scoped. This fixes the remaining question
of *when* a participant may send:

- messages may be **sent only while the Booking status is `confirmed`**
- message **history remains readable** after a terminal status (`completed`, `cancelled`,
  `no_show`)

This supersedes the earlier working suggestion that sends should also be allowed while
`completed`; that suggestion is retained nowhere as authoritative and is superseded by
this entry.

**This rule is now enforced.** BL-01C recreated both `messages` policies `TO authenticated`
and added the missing conjuncts to INSERT: the caller must be exactly this Booking's
`worker_id` or `client_id`, the Booking must be `confirmed`, `auth.uid()` must equal
`sender_id`, and the content must be non-blank and at most **2000 characters**. SELECT
deliberately carries no status predicate, which is what keeps history readable after a
terminal status. Membership and status are decided from one lookup of the Booking row.

**Maximum message length: 2000 characters** — enforced in the INSERT `WITH CHECK` as
`length(content) <= 2000`, measured in characters rather than bytes, and deliberately
**not** added as a CHECK constraint: it is an application-authorization rule, not a data
integrity invariant, and a constraint would be a schema change on a locked table. An
over-length message is rejected, never truncated.

BL-01C is implemented through direct INSERT under RLS rather than a send RPC. Membership
and sender identity were already enforced correctly by the pre-existing policies; only the
status conjunct was missing, so completing the predicate where it already lived was the
narrower change than adding a SECURITY DEFINER surface and an EXECUTE grant to re-derive
membership RLS already derives.

**Deferred by BL-01C and NOT implemented:** `messages.is_read` maintenance (the column
keeps its `false` default and has no UPDATE policy and no grant behind it, so it cannot be
written at all), read receipts, message notification fan-out, and Realtime. There is no
UPDATE and no DELETE policy, so messages are append-only — no edit, delete or recall path
exists.

As of this entry BL-01C is applied to the **local** database only; the hosted project has
not received it, and hosted deployment is separately gated.

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

#### Clarification — N12 Trusted Notification Write Boundary (2026-09-05) — LOCKED
N12 applies the D-005 function security split to `public.notifications`. The implemented
trusted-write model:

- the direct authenticated INSERT policy was **removed** and not replaced
- the broad recipient UPDATE policy was **removed** and not replaced
- recipient SELECT remains own-row only (`user_id = auth.uid()`) and is unchanged
- `public.mark_my_notification_read(uuid)` is the narrow recipient mutation — it can
  change exactly one flag on exactly one own row
- `private.emit_notification(uuid, text, text)` is internal-only and not client-callable;
  no client role holds EXECUTE on it
- the authoritative trusted writers are the reviewed server-side mutation paths: N9
  acceptance and N10 verification emit notifications atomically with their authoritative
  writes, inside the same transaction

Consistent with D-005, the internal writer is `SECURITY INVOKER` while the recipient RPC
is `SECURITY DEFINER`. The writer does not need definer rights — called from a
postgres-owned DEFINER function it already reaches the table as owner — and leaving it
invoker keeps a mistaken future GRANT fail-safe rather than making it an escalation.

Deliberately not done: no notification trigger; no Worker-opportunity fan-out (matching
is computed-on-read, so materialising a row per eligible Worker would mean recomputing
eligibility at write time and leaving stale rows after every first-wins acceptance); no
Realtime; no new notification table, column, or index. D-001 remains untouched.

`is_read` remains nullable and NULL is treated as unread — readers must use
`IS DISTINCT FROM true`, never `= false`.

Privacy: notification messages carry the Job title and fixed operational text only. No
contact information, participant name, email, phone, `verified_by`, or other
status-gated N11 data is written into notification text. This matters beyond tidiness: a
notification is immutable frozen text, while N11 releases counterparty contact under a
**live** status rule, so embedded contact would keep displaying after a Booking later
became cancelled, silently defeating that contract.

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

#### Implementation alignment (2026-09-05) — evidence, not a new decision
D-009 as resolved above is unchanged. This note records only that the repository caught
up to it.

Until 2026-09-05 the React/Vite application still contradicted the locked architecture at
runtime: `src/App.jsx` routed `/` to a Login page, `/register` to a Register page, and
`/worker` `/client` `/admin` to role dashboards, and `src/main.jsx` wrapped the tree in an
`AuthProvider`. None of it was dead code.

Commit `d7e5ef11b9a91ac5cd51bb983339d284baae95aa` — `refactor: make web landing-only` —
removed that legacy surface. A Landing page was created; the routing surface became `/`
plus a catch-all redirect to `/`; the `AuthProvider` wrapper was removed; and twelve
files were deleted, including the web Supabase client, so the site establishes no auth
session and makes no Supabase call. The repository now implements the locked
landing/information-only runtime.

This is implementation evidence for the existing locked decision. It creates no new
architecture decision and no new decision id.
