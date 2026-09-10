# DECISIONS.md — Locked Decisions (ADR-lite)

Append-only. Entries are numbered D-001…; each entry = date, decision, STATUS
(LOCKED / DEFERRED / PENDING-PANEL), and a 1–3 line rationale. Agents may not
contradict LOCKED entries; any change requires Josh. Entries D-001–D-009 were seeded
2026-08-20 from a Josh-approved documentation task specification (intent source), not
derived from code.

### D-001 — 11-table ERD locked (2026-08-20) — LOCKED
No new tables or columns without explicit approval. The capstone schema is fixed at
the 11 tables in the live baseline migration.

#### Amendment — `public.reports` as 12th application table (2026-09-10) — LOCKED

Josh-approved R3 contract. `public.reports` is now an approved 12th application table.

Reason: user reporting and Administrator review is approved pre-defense scope.

This amendment does not automatically classify ERD / DFD / manuscript content as
requiring immediate revision. Diagram and manuscript consistency is evaluated
separately after implementation freeze.

No automatic punishment, suspension, or strike behavior is introduced.

Locked R3 contract:

- Counterpart reports are Booking-bound. A Worker may report only the Client, and a
  Client only the Worker, from a Booking they actually participate in.
  `reported_user_id` is always server-derived from that Booking. Counterpart reports
  are allowed only when authoritative Booking status is `confirmed`, `completed`, or
  `cancelled`; `pending` and `no_show` are denied. The report category `no-show` does
  not require Booking status `no_show`. There is no reporting time limit.
- App issues are general: no Booking, no reported user, category fixed to `app_issue`.
- Reporting eligibility is role-based (`users.role` is `worker` or `client`). Inactive
  Worker and Client accounts (`users.is_active = false`) may still submit legitimate
  reports. Submission is not gated through `private.is_active_worker()` or
  `private.is_active_client()`.
- Report statuses are `submitted` (default), `under_review`, `resolved`, `dismissed`.
- Duplicate active counterpart reports are database-enforced: unique
  `(reporter_id, booking_id)` where `booking_id IS NOT NULL` and status is
  `submitted` or `under_review`. After `resolved` or `dismissed`, a new report for
  that Booking may be submitted. App issues remain repeatable.
- The reported party cannot read the report. Direct SELECT is reporter-only.
- Administrators use narrow RPCs (`list_reports`, `get_report`, `review_report`). There
  is no Admin table-wide SELECT policy on `public.reports`.
- R3 creates no notification types and emits no report notifications.
- Admin response is mandatory and nonblank (1..2000) on `resolved` / `dismissed`;
  optional on `under_review`.
- Report-scoped Admin message evidence is deferred to R3B. R3 does not grant Admin
  general message access.

This belongs as the D-001 amendment / R3 dated contract note. It is not a new
decision id.

Effective status of D-001 from this amendment onward: LOCKED as amended. The original
11-table line above is retained for append-only provenance but is superseded by this
amendment for application-table count.

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

#### Clarification — Ratings Pre-Defense Contract (2026-09-05) — LOCKED, IMPLEMENTED (BL-01B)
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

**This is now implemented as BL-01B.** The pre-BL-01B `ratings` INSERT policy checked only
`rated_by = auth.uid()`; it enforced no Booking participation, no completed status, no
direction, and no link between `rated_user` and the Booking. That policy is **removed and
not replaced**, and the direct INSERT grant is revoked with it.

Implemented reality:

- **`public.rate_my_completed_worker(p_booking_id, p_score, p_comment)` is the sole
  writer.** postgres-owned, SECURITY DEFINER, `search_path = ''`, EXECUTE granted to
  `authenticated` only.
- **Identities are server-derived, not parameters.** `rated_by` is `auth.uid()` and
  `rated_user` is the Booking's `worker_id`, so identity substitution is unrepresentable
  rather than merely rejected.
- **Eligibility:** active Client account (`42501` otherwise), then a Booking that exists,
  belongs to the caller, is `completed`, and has an assigned Worker — all four collapsed
  into one `SM409`, as is a duplicate, so the RPC is not a Booking-existence oracle.
- **Score `1..5`**, validated in the RPC for a clear message with the existing schema CHECK
  kept as defence in depth. **Comment optional**, trimmed, empty/whitespace-only stored as
  NULL, **maximum 1000 characters**; both input faults raise `22023`, which reveals nothing
  about any Booking. Over-length is rejected, never truncated.
- **One immutable rating per (Booking, rater)** via the existing
  `UNIQUE (booking_id, rated_by)`. No update path, no delete path, no rating RPC for either.
- **`worker_profiles.rating_avg` is maintained transactionally.** The target profile row is
  locked `FOR UPDATE` **before** the rating is inserted, then the average is **recomputed in
  full** from all rating rows — never incrementally — and written in the same transaction.
  The lock is load-bearing: without it two Clients rating the same Worker concurrently can
  lose an update.
- **Direct participant writes denied.** `authenticated` holds only SELECT on
  `public.ratings`; `anon` holds nothing.
- **Rating reads narrowed** from `USING (true)` to `rated_by = auth.uid() OR rated_user =
  auth.uid()`, so free-text comments and rater/rated pairs are no longer readable by every
  signed-in account.
- **No rating notification.** Deferred.

**N8 is unchanged** and still reads `worker_profiles.rating_avg`; cold start remains
`12/20` decided by the existence of rating rows. **N11 is unchanged** and still computes its
aggregates live from `public.ratings`; the two now agree because the column is maintained.
The alternative strategy of changing what the scorer reads is **not** adopted.

As of this entry BL-01B is implemented and **locally verified only**; the hosted project has
not received it, and hosted deployment is separately gated.

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
triggers no refund flow.

#### Clarification — Cash on Delivery (2026-09-06) — LOCKED, IMPLEMENTED (BL-01D)

**COD is implemented; PayMongo is still not.** BL-01D adds the cash half of the payment
lifecycle using **only values the baseline schema already permits**, so it creates no
table, column, constraint, index, trigger or enum and leaves D-001 untouched.

- **Payment happens only after completion.** Both COD operations require
  `bookings.status = 'completed'`; a `confirmed` Booking is not yet payable and
  `cancelled` / `no_show` never become payable.
- **The Client chooses; the assigned Worker attests.**
  `public.select_my_booking_cod(p_booking_id)` is Client-only and
  `public.confirm_my_cod_payment_received(p_booking_id)` is Worker-only. Each refuses
  the other role at its account gate, so a Client can never mark their own Booking paid
  and a Worker can never choose the Client's payment method.
- **The state machine, in existing values only:**

  ```
  after N9 acceptance        (method NULL,  status 'pending')
  after BL-01A completion    (method NULL,  status 'pending')   -- unchanged
  Client selects COD         (method 'cod', status 'pending')
  Worker confirms cash       (method 'cod', status 'paid')
  ```

- **Neither RPC accepts a payment value.** Each takes a Booking id and nothing else;
  `rated`-style identity substitution is unrepresentable. `paymongo_ref` stays **NULL**
  for COD, so a later PayMongo piece can carry a real reference beside this without
  collision. That later piece was assumed here to be `gcash`/`maya`; for the defense
  implementation that assumption is **superseded by the PM-01 QR Ph amendment below**,
  which implements `qrph` instead. The `gcash` and `maya` schema values are retained.
- **Repeat behaviour is deliberately asymmetric.** Re-selecting COD on a Booking already
  `(cod, pending)` is a **no-op**: it writes nothing and returns the current state,
  because it is a restatement of the same choice rather than a second event. A repeated
  Worker confirmation is **rejected with SM403** before any write or notification, so it
  can neither pay twice nor notify twice. Every other repeat — already paid, another
  method, refunded — conflicts with SM409.
- **Exactly one `payment_received` notification** goes to the **Client** when cash is
  confirmed, emitted inside the same transaction as the payment write, so a failed
  notification rolls the settlement back. `payment_received` was already an allowed
  notification type; nothing was added. **No notification is emitted when the Client
  merely selects COD.**
- **Direct participant Booking writes are denied at both layers.** BL-01D also narrows
  `public.bookings` grants to `authenticated: SELECT only` / `anon: none`, closing the
  last table still carrying the broad Supabase defaults.
- **Refunds remain deferred** and `'refunded'` remains a value no code path produces.

As of this entry BL-01D is implemented and **locally verified only**; the hosted project
has not received it, and hosted deployment is separately gated.

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

#### PM-01 — PayMongo QR Ph Amendment (2026-09-07) — LOCKED

**Nothing here is implemented.** This entry records the approved architecture for the
online half of the payment lifecycle *before* any of it is built. No migration, Edge
Function, provider credential or provider call exists yet, and every piece below carries
its own separate authorization gate. The COD clarification above is unchanged and BL-01D
remains closed on its own terms.

**Implementation target — QR Ph.** The PayMongo account capability currently available
to the project is **QR Ph**, so QR Ph is the online method implemented for the defense.
`gcash` and `maya` are **not implemented for the defense**. They are not broken, not
withdrawn, and not permanently unsupported — they are simply not built now, and they
remain valid schema values for historical and forward compatibility. The distinction to
carry forward is:

```
schema compatibility    gcash | maya | qrph | cod
defense implementation                qrph | cod
```

COD remains independently closed and unchanged by this amendment.

**QR-01 — Flow.** PayMongo **Dynamic QR Ph**: create a Payment Intent, create a QR Ph
Payment Method, attach the Payment Method to that Intent, receive the QR action, and let
the provider decide the outcome, which the server then verifies. Hosted Checkout is
**not** the selected PM-01 architecture.

**QR-02 — `paymongo_ref` invariant.** `bookings.paymongo_ref` always stores the PayMongo
**Payment Intent ID** and never a Payment ID, Payment Method ID, QR image, `test_url`,
`client_key`, webhook event ID or raw provider JSON. The Intent is the only identifier
that already exists at initiation, survives QR expiry, and is the resource that both the
attach call and reconciliation address. No fixed provider ID length is claimed: the
returned Intent ID must be non-empty and must fit the existing `varchar(100)`, and the
server **fails closed** if it does not. No column expansion is approved.

**QR-03 — `payment_method` CHECK.** The future amendment is
`payment_method IN ('gcash','maya','qrph','cod')` — adding only `qrph` and preserving
`gcash`, `maya` and `cod`. Classification, stated precisely because the two are easy to
conflate: **D-001 structural change not required** (no table added, no column added, no
ERD relationship changed; the model stays 11 tables / 74 columns), **but a hosted schema
CHECK amendment IS required** and needs its own separate mutation authorization. This is
not a no-schema-change piece.

**Locked online-payment lifecycle.** Using existing column values only:

```
after BL-01A completion      (NULL,   pending, NULL)
Client initiates QR Ph       ('qrph', pending, <Payment Intent ID>)
provider-confirmed success   ('qrph', paid,    <same Payment Intent ID>)
```

Throughout, `Booking.status` stays `completed`, `Job.status` stays `completed`, and
`completed_at` is untouched. **Neither the Client nor the Worker may mark a QR Ph Booking
paid.** Only trusted provider-verified server code performs `pending` — `paid`. This is
the structural difference from COD, where the Worker attests physical cash.

**QR-04 — Initiation boundary.** A **Supabase Edge Function**, conceptually
`POST paymongo-qrph-initiate` taking **`booking_id` and nothing else**. The server derives
caller identity, Client role, active status, Booking ownership, Booking lifecycle, the
Job, the budget, the amount, the currency, the payment method and the payment state. The
client may not supply `client_id`, `worker_id`, `amount`, `currency`, budget,
`payment_status`, `paymongo_ref` or any PayMongo key. **All PayMongo calls remain
server-side**, including the ones the provider would accept a public key for: the
`client_key` is an Intent-scoped credential, and shipping it to the device would let a
modified client drive the Intent outside our boundary while buying nothing — the device
only needs the finished QR image.

**Secret boundary — LOCKED.** The PayMongo API secret, the PayMongo webhook signing
secret and any Supabase privileged secret are **server-side only**. None may ever appear
in an `EXPO_PUBLIC_*` variable, the React Native bundle, the Vite bundle, AsyncStorage,
Git, Git history, screenshots, reports, chat or client logs. Future secret names, recorded
by name only: `PAYMONGO_SECRET_KEY`, `PAYMONGO_PUBLIC_KEY`, `PAYMONGO_WEBHOOK_SECRET`.
Values are entered by Josh directly into the approved server-side secret store and are
never transmitted to an agent.

**QR-05 / QR-06 — Webhook boundary and signature.** A **separate** Edge Function with
`verify_jwt = false`, because PayMongo holds no Supabase user JWT — the PayMongo
signature *is* the provider authentication. Required order, non-negotiable: read the raw
request body, read the signature, verify it, reject on mismatch, and only then parse or
process. The signature contract as currently documented: header `Paymongo-Signature` with
parts `t`, `te` and `li`; signed material `timestamp + "." + rawBody`; algorithm
**HMAC-SHA256** keyed with the per-endpoint webhook signing secret; compare `te` in test
mode and `li` in live mode, using a timing-safe comparison. The signing secret is never
exposed and is distinct from the API secret key. The implementation must not silently
adopt a differently named header: real test-mode webhook evidence must confirm the actual
provider behaviour before PM-01 closure.

**QR-07 — Atomic claim-and-bind ordering.** The Payment Intent is created **before** any
Booking payment state is committed, and a single trusted DB operation performs the claim
and the binding together. There is therefore **no intermediate committed
`(qrph, pending, NULL)` state**: a Booking is either untouched or already bound to its
authoritative Intent. The earlier claim-then-bind sequence is superseded, because a
committed claim carrying no reference could strand a Booking with no durable recovery
field available under the locked 11-table / 74-column model.

```
1. the Edge Function authenticates the Client and validates the request
2. read/prepare the Booking and derive the authoritative amount and currency
3. create the PayMongo Payment Intent
4. one trusted DB operation atomically locks the Booking and changes
      (NULL, pending, NULL)  →  ('qrph', pending, <Payment Intent ID>)
5. COMMIT that authoritative binding
6. only after the DB binding succeeds, create the QR Ph Payment Method
7. attach that Payment Method to the authoritative stored Payment Intent
8. return the QR and test-mode information transiently
```

**Invariants.**

- No payable QR may be generated before the authoritative DB binding succeeds.
- `paymongo_ref` remains the single authoritative Payment Intent ID.
- An existing non-NULL `paymongo_ref` is **never** replaced.
- A retry against an already-bound `qrph/pending` Booking **reuses the stored Intent**.
- A concurrent losing request may leave an orphan Payment Intent.
- A losing or orphan Intent must never be attached or exposed as the Booking's QR.
- Orphan provider resources are accepted as the cross-system race and failure tradeoff.
- **No cross-system atomicity is claimed** between PayMongo and Postgres.
- PayMongo `Idempotency-Key` remains *secondary* protection only, never the correctness
  mechanism, and only after its behaviour is confirmed against the current PayMongo API.

**Concurrency, stated truthfully.** Two simultaneous taps may each reach step 3, so
request A creates `pi_A` and request B creates `pi_B`. Both then contend for the same
Booking row at step 4. A wins and the Booking becomes `qrph / pending / pi_A`; B acquires
the lock afterwards, finds the method already set and `paymongo_ref` already non-NULL, and
is refused — it must never replace `pi_A`. `pi_B` is left unattached and becomes an
orphan. It is therefore **not** claimed that only one provider Intent can ever be created
under a race. The guarantee is narrower and exact: **only one Intent can become the
Booking's authoritative `paymongo_ref`, and no losing Intent ever becomes payable**,
because attachment happens only at step 7 and only against the stored authoritative
Intent.

**Retry and crash recovery.** If the server dies after the binding commits but before the
QR is attached, the Booking rests at `qrph / pending / pi_A`, which is a fully recoverable
state rather than a stranded one. A later retry reads the stored `pi_A`, reuses it, creates
a fresh QR Ph Payment Method if needed, and attaches it to `pi_A`. It must **not** create a
replacement authoritative Payment Intent. This is the same rule QR-09 applies to ordinary
QR expiry: the Payment Intent is stable, and only the QR is regenerated.

**QR-08 — Duplicate webhook delivery.** Settlement takes a row lock and permits only
`qrph/pending` — `qrph/paid`. The first valid provider success transitions once; a
repeated valid delivery finds the Booking already paid, acknowledges, and performs no
second write and no duplicate side effect. **No webhook-events table pre-defense.** A
durable provider-event ledger would require a separate D-001 structural decision and is
deferred.

**QR-09 — Expiry and QR regeneration.** QR expiry does **not** create a replacement
Payment Intent. The Booking keeps the same `paymongo_ref`, the same Payment Intent and the
same `qrph/pending` state. Recovery is to create a **new QR Ph Payment Method and attach
it to the same Payment Intent**, yielding a fresh QR. There is no new `payment_status`, no
new `paymongo_ref`, no replacement Intent and no method switch. This preserves the
one-Booking / one-Intent invariant, which is also what keeps a late webhook for a
superseded resource from ever being possible.

**QR-10 — First payment method selection locks the method.** From `NULL/pending` the
Client may choose either `cod/pending` or `qrph/pending`. After either selection, COD
— QR Ph switching is **not permitted pre-defense**, and after `paid` a method change is
impossible. No fallback switching semantics are added. The deployed COD path already
behaves this way, since `select_my_booking_cod` requires a NULL method and conflicts
otherwise.

**QR-11 — No QR Ph payment notification pre-defense.** The locked `payment_received`
semantics were defined for COD, where the **Worker** attests that cash was received and
the **Client** is the party learning something new. QR Ph is provider-confirmed and the
Client is the payer, so reusing that notification would be misleading without a separate
product decision. Therefore: **no new notification type, and no existing notification type
reused for QR Ph.** Success is communicated through the authoritative Booking payment
state that both roles already read. COD notification behaviour is unchanged.

**QR-12 — Test-mode defense procedure.** **PayMongo test mode only.** PayMongo's own
testing guidance warns that test-mode QR Ph generates authentic QR codes and that scanning
and paying one processes a real transaction. Hard rule for development and defense:
**do not scan the generated QR** with GCash, Maya, a banking app or any real payment
application, and **do not send real money**. Outcomes are simulated using the PayMongo
`test_url` returned with the QR. The exact response path holding `test_url` is an
implementation-time fact to read from a real test-mode response and is deliberately not
invented here. The resulting demonstration is classified as a **genuine PayMongo
test-mode integration — not a mock, and not a real-money transaction**.

**QR-13 — Amount binding.** The payable amount is **derived server-side only**, from
`Booking` — `job_id` — the authoritative `Job.budget` — PHP centavos. `job_postings.budget`
is `numeric(10,2)` and nullable with `CHECK (budget >= 0)`, so the conversion must use
exact numeric arithmetic, convert to integer/bigint centavos, and reject NULL, reject
anything below the PHP 1.00 provider minimum, and reject an out-of-range or
provider-invalid amount. Floating-point conversion is forbidden. The client never supplies
the amount, and settlement or reconciliation recomputes it and compares it against the
provider amount rather than trusting the event.

**Provider-to-Booking binding.** A valid PayMongo signature proves only that PayMongo sent
the event — never that a particular Booking may be marked paid. Settlement must
independently establish that the Booking exists, `Booking.status = 'completed'`,
`payment_method = 'qrph'`, the payment state is `pending` (or already `paid`, for
repeat handling), the stored `paymongo_ref` matches the authoritative provider resource,
the currency is PHP, the provider amount equals the server-derived Job amount, and the
provider state is a genuine successful QR Ph payment. Provider metadata or reference
fields may serve as **correlation only, never as authorization**.

**QR-14 — Server-side reconciliation.** A **Refresh Payment Status** control is backed by
a trusted server endpoint that reads the stored Payment Intent ID, retrieves the
authoritative Intent from PayMongo, verifies the amount, currency and resource binding,
and — only if the provider reports success — invokes the same guarded settlement path;
otherwise the Booking stays `pending`. The Client may request a refresh but may never
assert payment. The webhook remains the normal provider-driven path; reconciliation is the
recovery and defense path, and both converge on one settlement routine.

**QR-15 — D-001 determination.** **D-001 structural change not required.** The model
remains **11 tables / 74 columns**. No payment table, payment-attempt table,
webhook-events table, new Booking column or new Job column is approved. The only approved
DB-definition amendment for PM-01 is adding `qrph` to `bookings_payment_method_check`, and
even that requires its own separate authorization.

**D-009 preserved.** Operational payment logic lives entirely in the Expo application and
the Supabase trusted server boundary. The React/Vite application remains public
landing/information only and gains no payment or authentication logic. Dynamic QR Ph needs
no redirect return page, so none is introduced.

**Deferred — PM-01 reopens none of these:** GCash implementation, Maya implementation,
refund processing, payment reversal, payment-method switching after selection, a
webhook-event ledger, live payments, real-money testing, online payment notifications, EAS
Update, Socket.IO, Realtime chat, no-show automation and automatic rematching.

**Intended implementation sequence (planning only, nothing authorized by this entry):**
`PM-01A` DB trusted boundary and the `qrph` CHECK amendment — `PM-01B` QR Ph initiation
Edge Function — `PM-01C` webhook and reconciliation boundary — `PM-01D` native QR Ph UI
— `PM-01E` hosted and native PayMongo test-mode closure.

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
