# SECURITY.md — Security Model, Findings, and Gap Registry

## Model overview

Two layered gates protect data: RLS policies (row-level) AND column guard triggers
(column-level). They compose — a trigger ALLOW never bypasses RLS, and passing RLS
never bypasses a trigger; both must pass for a write to land.

## Function security split (locked)

- `private.is_admin()`, `private.is_active_worker()` — `SECURITY DEFINER`, `STABLE`,
  `SET search_path = ''`, schema-qualified relations, EXECUTE revoked from PUBLIC
  (granted to `authenticated`, `service_role`). DEFINER is required so the helpers can
  reliably read `public.users` regardless of the caller's RLS visibility; the empty
  search_path plus schema qualification defend against search_path hijacking.
- `public.guard_users_protected_columns()` and
  `public.guard_worker_profiles_protected_columns()` — `SECURITY INVOKER`. Under
  DEFINER, `current_user` would report the function owner (`postgres`), silently
  satisfying Tier 1 for every caller and disabling the guard.
- Guard trigger functions need no client-callable EXECUTE surface: EXECUTE is checked
  only when the trigger is created (by the owner), never when it fires. The Piece E
  guard therefore carries no EXECUTE grant for `PUBLIC`, `anon`, `authenticated`, or
  `service_role` (live `proacl = {postgres=X/postgres}`). The Piece D guard predates
  this convention — see GAP-004.

## Guard trigger behavior

`trg_guard_users_protected_columns` — `BEFORE INSERT OR UPDATE ON public.users FOR
EACH ROW`. Protected columns: `users.role`, `users.is_active`.

- Tier 1 — `current_user IN ('postgres', 'service_role')`: unrestricted (trusted
  database execution paths).
- Tier 2 — authenticated caller with `private.is_admin()` true (entered via an explicit
  `auth.uid() IS NOT NULL` check, so `anon` never touches schema `private`):
  unrestricted on the rows RLS already permits.
- Tier 3 — everyone else:
  - INSERT: `role = 'administrator'` rejected; role must be `'worker'` or `'client'`;
    `is_active` is forced `true` (server-owned; a client-supplied value is overridden
    rather than rejected).
  - UPDATE: any change to `role` or `is_active` (`IS DISTINCT FROM`) rejected.
  - All rejections raise `ERRCODE '42501'`.

`trg_guard_worker_profiles_protected_columns` — `BEFORE INSERT OR UPDATE ON
public.worker_profiles FOR EACH ROW` (Piece E). Protected columns (5):
`is_verified`, `verified_by`, `rating_avg`, `strike_count`, `badge_level`. Same
three-tier shape as the users guard (Tier 1 and Tier 2 identical, including the
nested `auth.uid() IS NOT NULL` check).

- Tier 3 — everyone else:
  - INSERT: all five columns are forced to the trusted initial state
    `is_verified = false`, `verified_by = NULL`, `rating_avg = 0`,
    `strike_count = 0`, `badge_level = 'none'` (server-owned; client-supplied values
    are overwritten, never rejected). `'none'` is trigger-enforced initial state
    only: the column keeps NO default and remains nullable, and pre-existing
    `NULL` rows are not backfilled (no schema/ERD change, D-001).
  - UPDATE: any change (`IS DISTINCT FROM`, so NULL-safe) to any of the five columns is
    rejected with `ERRCODE '42501'` and a column-specific message
    ("Changing your own verification status / verifier / rating average / strike
    count / badge level is not permitted."). Identical re-sends pass. Non-protected
    columns (`bio`, `availability_status`, …) are unaffected, subject to existing RLS.
- The guard is a column-value guard, not a row-authorization mechanism. Tier 2 is
  bounded by the unchanged self-row RLS: an administrator's cross-user UPDATE yields
  `UPDATE 0` before the trigger fires (GAP-003), and the role/status-agnostic INSERT
  policy is not made worker-only or is_active-aware (GAP-002). Trigger authorization
  must never be read as fixing either gap.
- Verified locally 18/18 behavioral cases plus supplementary and catalog checks,
  all inside rolled-back transactions; Piece D 13/13 re-run unchanged.

## Standing RPC caveat (locked)

Any postgres-owned SECURITY DEFINER function that UPDATEs `public.users` executes the
guard with `current_user = postgres`, which satisfies Tier 1 and therefore bypasses the
column guard entirely. Consequently, no client-callable SECURITY DEFINER RPC may modify
protected user columns without restricted EXECUTE, input validation, and security
review. This applies to all future RPCs, including the future atomic booking RPC if it
ever touches protected `public.users` columns.

The same caveat applies verbatim to `public.worker_profiles` and its five protected
columns (Piece E). Future system paths that compute `rating_avg`, `strike_count`, or
`badge_level` (ratings, no-show handling, portfolio scale) must be trusted Tier 1
paths or restricted, reviewed RPCs — a postgres-owned DEFINER function writing
`worker_profiles` bypasses the guard via Tier 1.

## Hosted Auth control — leaked-password protection (Piece F)

Date: 2026-08-21 (historical evidence snapshot — plan, settings, and advisor state as
observed on this date, not an evergreen claim).

**Status: CLOSED — evaluated; unavailable on current plan. Feature NOT enabled. No
hosted changes made.** Manual dashboard evaluation with a read-only Supabase MCP
cross-check; no SQL, migration, billing change, or Auth setting change was performed.

- Objective: evaluate whether Supabase Auth leaked-password protection (the
  HaveIBeenPwned Pwned Passwords check used by Supabase Auth to reject known leaked
  passwords) is available on the project's current plan, and enable it if supported.
  The objective was evaluate-then-enable-if-supported, not simply "enable".
- Threat model: leaked-password protection reduces credential-stuffing /
  account-takeover risk from passwords that are already compromised (present in public
  breach corpora). It is a hosted Auth-layer control. RLS and the Piece D / Piece E
  column guards are separate authorization / data-integrity controls and are NOT
  compensating controls for it — they constrain what an authenticated session may
  write, not whether an attacker holding a user's compromised password can obtain that
  session.
- Plan evidence (captured during Piece F):
  - organization plan observed as Free in the dashboard;
  - dashboard setting present, OFF, labeled Pro+ only;
  - read-only Supabase MCP independently returned organization plan `free`;
  - project status `ACTIVE_HEALTHY`;
  - Security Advisor returned `auth_leaked_password_protection` — "Leaked Password
    Protection Disabled" — level WARN.
- Advisor warning: while the project remains on Free and the feature remains
  unavailable/disabled, this warning is expected to remain unresolved. Piece G should
  classify it as known / plan-gated rather than treat it as a regression.
- Advisor discrepancy (unexplained): the dashboard Security Advisor showed 2 warnings;
  a later read-only MCP advisor call returned exactly 1 security lint (the one above).
  The second dashboard warning is unidentified. No explanation is asserted here.
  Carried into Piece G for fresh capture of both surfaces.
- Related observations (recorded as future-hardening observations only — NOT registry
  gaps; no GAP entry created): minimum password length = 6; character requirements
  unset; secure password change OFF; require current password when updating OFF.
  Current Supabase documentation recommends a minimum password length of at least 8.
  Client-side validation currently enforces the same 6-character minimum; any future
  hosted minimum-length change must move in lockstep with frontend validation.
- Upgrade path: enabling the hosted control later (Pro+ plan) requires no DB schema or
  migration change — it is a dashboard Auth setting — but Auth/client flows
  (registration, sign-in, password reset/update) should be regression-tested for
  compromised-password error handling before and after enabling, since a rejected
  leaked password surfaces as a new Auth error path.
- External reference (Pro+ restriction and password-strength guidance):
  https://supabase.com/docs/guides/auth/password-security
- No decision record (no D-010) and no gap entry (no GAP-005) were created for Piece F.

## Phase 0 final verification — regression and closure (Piece G)

Date: 2026-08-21 (evidence snapshot as observed on this date).

**Outcome (reviewer-approved): READY TO CLOSE WITH DEFERRED HARDENING.** Piece G was
verification and documentation only: no migration, SQL, RLS, function/trigger, ACL,
frontend, hosted Supabase, or billing change was made.

Local regression evidence (Piece G Pass 1):

- Clean `npx supabase db reset --local` succeeded from scratch; all four migrations
  applied with zero errors.
- Expected security functions, triggers, and catalog properties matched this document
  (function security split, guard triggers, EXECUTE surfaces as recorded, including
  the GAP-004 `anon` grant on the Piece D guard).
- Piece D regression: 13/13 PASS.
- Piece E regression: 18/18 PASS plus 6 supplementary PASS.
- Piece D re-run after Piece E: 13/13 PASS.
- All checks ran inside rolled-back transactions; zero local test residue after
  rollback.

Hosted state (read-only observation; no hosted mutation performed):

- Hosted project remained `ACTIVE_HEALTHY`; organization remained Free.
- Fresh Security Advisor capture returned exactly one WARN:
  `auth_leaked_password_protection`. This matches the earlier programmatic Piece F
  capture and the fresh ChatGPT MCP capture. Classified as known / plan-gated per
  Piece F, not a regression.
- Leaked-password protection remained NOT enabled.
- Hosted Auth-config read remained MCP-UNAVAILABLE for fresh verification. The Piece F
  Auth values (minimum password length, character requirements, secure password
  change, require-current-password) are therefore HISTORICAL evidence only — not
  freshly verified in Piece G.
- Frontend registration still enforces a minimum password length of 6 (see the Piece
  F related observations above; not duplicated here).
- Dashboard-vs-MCP advisor warning-count discrepancy (dashboard showed 2, MCP
  returned 1 in Piece F): classified **UNRESOLVED historical evidence**. No evidence
  exists for a current second advisor lint; no explanation for the earlier dashboard
  count is asserted.

GAP reverification (statuses preserved exactly; none closed, renumbered, or added):

- GAP-001 — CONFIRMED; remains OPEN / DEFERRED BY DECISION (D-008).
- GAP-002 — CONFIRMED; remains OPEN / DEFERRED.
- GAP-003 — CONFIRMED; remains OPEN / DEFERRED.
- GAP-004 — CONFIRMED; remains OPEN / DEFERRED (hardening).

Future-hardening observation (NOT a registry gap; no GAP entry created):

- Baseline Supabase/default privileges give `anon` and `authenticated` broad table
  privileges on `public.users` and `public.worker_profiles`. Current application row
  access remains RLS-governed, and no Phase 0 exploit or regression was demonstrated
  from these grants. A future least-privilege review may evaluate the table grants.

No decision record (no D-010), no finding (no F-003), and no gap entry (no GAP-005)
were created for Piece G.

## Hosted Phase 0 deployment record — 2026-08-22

Date: 2026-08-22 (evidence snapshot as observed on this date).

**Status: DEPLOYED.** The hosted project now runs the Phase 0 security model recorded
above. Hosted operation: one `npx supabase db push` to project `uzbntxxwayqfkusyhodl`
(livelihood-matching-platform, Free plan, ap-northeast-1, PG 17.6), preceded by a
`npx supabase db push --dry-run` gate. No other hosted mutation was performed.

Deployment evidence:

- Dry-run listed exactly three pending migrations; the applied set was byte-identical
  to the dry-run list:
  - `20260811025903_phase0_backend_security_v3`
  - `20260820042554_phase0_piece_d_users_guard`
  - `20260820190630_phase0_piece_e_worker_profiles_guard`
- Baseline `20260810153826_remote_schema` was NOT re-applied.
- Hosted migration history: exactly 4 rows (`20260810153826`, `20260811025903`,
  `20260820042554`, `20260820190630`).
- Repository state at deployment: local `main` = `origin/main` =
  `1448b751aaa71a2ef054a22686f80185ad5a4186`. Hosted state is expressed as the
  recorded migration versions and the catalog-verified objects below, not as a commit.

Post-deployment verification (2026-08-22, read-only):

- All Phase 0 objects present on hosted (schema `private`, `private.is_admin()`,
  `private.is_active_worker()`, both guard functions, both guard triggers).
  SECURITY DEFINER / INVOKER properties and effective privileges MATCH the security
  model recorded in this document; both guard triggers enabled.
- RLS flags on `public.users` and `public.worker_profiles` and all 6 policies
  byte-identical to the preflight capture.
- Advisor unchanged: single plan-gated `auth_leaked_password_protection` WARN
  (expected on Free plan).
- Project status `ACTIVE_HEALTHY`.
- Independent live re-verification confirmed the hosted migration history, project
  health, function security/privilege state, and guard-trigger presence after
  deployment. The deployment evidence was reviewed and accepted before this record
  was finalized.

C4 — exposed-schemas verification (`private` must not be API-exposed):

- Pre-deploy (before `private` existed): Dashboard listed `graphql_public`, `public`;
  no `pgrst.db_schemas` override on `authenticator`, making the Dashboard list
  authoritative.
- Post-deploy DB-side check (2026-08-22, read-only catalog query over
  `pg_db_role_setting` via Supabase MCP): zero `pgrst.*` entries on any role or
  database scope — `pgrst.db_schemas` absent, `pgrst.db_extra_search_path` absent;
  `authenticator` carries only platform defaults
  (`session_preload_libraries=safeupdate`, `statement_timeout=8s`,
  `lock_timeout=8s`). Premise re-verified post-deploy.
- The available MCP/tooling exposed no readable platform-level Data API configuration
  surface, so the Dashboard was used as the closing direct observation surface.
- Post-deploy Dashboard observation (2026-08-22, lead developer): Exposed schemas
  selector shows 2 of 3 — `graphql_public` SELECTED, `public` SELECTED, `private`
  PRESENT IN SELECTOR but NOT SELECTED. Extra search path: `public`, `extensions`
  only; `private` absent.
- Ruling: **C4 CLOSED** — `private` confirmed unexposed after hosted Phase 0
  deployment.

GAP-004 on hosted:

- Reproduced on hosted exactly as preflight predicted (`anon` EXECUTE on the users
  guard trigger function via public-schema `pg_default_acl`). Status unchanged:
  **OPEN / DEFERRED**. No action taken.

C2 — backup acceptance:

- One-time acceptance on a three-fact basis: (i) 0 rows in all hosted tables;
  (ii) non-destructive SQL (additive DDL; `DROP TRIGGER IF EXISTS` → `CREATE` is
  idempotent re-creation, not data-destructive); (iii) a written rollback plan
  existed. This acceptance applies only to this deployment and does not waive backup
  review for future hosted changes. Future deployments must make an explicit
  backup/restore decision from the then-current data, plan capabilities, and
  deployment risk.

C3 — hosted behavioral verification:

- No hosted behavioral smoke tests were performed at deployment. The guard objects
  that close F-001 and F-002 in repository/local verification are now present and
  catalog-verified on hosted. Hosted behavioral verification was intentionally
  deferred by ruling to Module 1's first real application flows.

Non-TTY process deviation:

- During `db push`, command wrapping made stdin non-TTY and the CLI skipped the
  interactive `[Y/n]` confirmation entirely. Compensated by: the dry-run gate,
  unchanged pre-push migration history, and exact post-verification. Classification:
  PROCESS DEVIATION, not a security finding. Ruled ACCEPTED. (The derived operating
  rule is queued for AGENTS.md under a separate tooling task; this record documents
  the deviation only.)

Carried adjacent observation (NOT a registry gap; no GAP / F number assigned):

- Dashboard shows "Automatically expose new tables" = ON. Unchanged in this task;
  queued for a separate future least-privilege hardening review.

## Findings log

**F-001** — Pre-Piece-D, the `public.users` INSERT policy (`allow_insert_own_profile`)
checked row ownership only (`auth.uid() = id`), so an authenticated registrant could
self-insert `role = 'administrator'` and mint admin authority via `private.is_admin()`.
Verified locally in a rolled-back transaction. **CLOSED** by the Piece D guard trigger,
verified 13/13 behavioral cases (see docs/tasks/piece-d-users-guard.md). Administrator
provisioning is restricted to trusted backend/database paths such as service_role or
database administration; no normal authenticated registration path may create
administrators.

**F-002** — Pre-Piece-E, the `public.worker_profiles` INSERT and UPDATE policies
checked row ownership only (`user_id = auth.uid()`), so an authenticated worker could
self-assign protected profile metadata: `is_verified = true`, `verified_by = <any
administrator id>` (forged verification attribution), `rating_avg = 5`,
`strike_count = 0` (resetting a 3-strike suspension) and `badge_level = 'large'`, on
both INSERT and UPDATE. No administrator authority derives from these columns, but they
feed the locked matching model (D-002 verification and rating weights), the 3-strike
rule and the badge system. Verified locally in a rolled-back transaction. **CLOSED** by
the Piece E guard trigger (`20260820190630_phase0_piece_e_worker_profiles_guard.sql`),
verified 18/18 behavioral cases plus supplementary and catalog checks; Piece D 13/13
regression unchanged. Piece E closes the unauthorized WRITE PATH going forward; it
does not audit, normalize, or remediate protected values that may already exist in
pre-Piece-E rows (existing rows remain untouched; no backfill, no schema change).
Row-level gaps discovered alongside it remain open as GAP-002 and GAP-003.

## Known gaps registry

**GAP-001** — `public.users` UPDATE RLS (`allow_update_own_profile`) is self-row only,
so authenticated administrators cannot UPDATE another user's row via PostgREST.
Discovered-by: Piece D (migration header + Piece D report). Status: **OPEN / DEFERRED
BY DECISION** (D-008) — must be resolved as a dedicated, security-reviewed
admin-management task, never absorbed silently into another piece.

**GAP-002** — `public.worker_profiles` INSERT RLS ("Workers can insert their own
profile") is role/status agnostic: it checks only `user_id = auth.uid()` and does not
enforce that the caller is an active worker. An authenticated non-worker role —
confirmed for both client and administrator — can create its own `worker_profiles`
row, and an inactive/suspended worker can also create one. Discovered-by: Piece E
inspection (verified locally, rolled back; Piece E cases T7, S2, S3 — the guard forces
the trusted initial state on such rows but does not prevent them). Status: **OPEN /
DEFERRED** — row authorization / RLS; not fixed by Piece E. Resolution path:
dedicated, security-reviewed worker-module RLS task (restrictive write policies using
`private.is_active_worker()`).

**GAP-003** — `public.worker_profiles` UPDATE RLS ("Workers can update their own
profile") is self-row only, so an authenticated administrator cannot UPDATE another
worker's `worker_profiles` row (verify, strike, badge) through normal PostgREST;
only Tier 1 paths can. Analogue of GAP-001. Discovered-by: Piece E inspection
(verified locally; Piece E case T6/S4 — `UPDATE 0`, RLS bound, not trigger
rejection). Status: **OPEN / DEFERRED** — row authorization; the Piece E guard's
Tier 2 is bounded by this policy. Resolution path: the dedicated, security-reviewed
admin-management task (alongside GAP-001 / D-008), never absorbed into another piece.

**GAP-004** — `public.guard_users_protected_columns()` (Piece D) retains an explicit
`anon` EXECUTE grant (live `proacl` includes `anon=X/postgres`): the project's
`ALTER DEFAULT PRIVILEGES … IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon` granted
`anon` explicitly at CREATE time, and the migration's `REVOKE … FROM PUBLIC` does not
remove an explicit grantee. No exploit path (trigger functions are not
permission-checked at fire time and a `RETURNS trigger` function cannot be called
directly), but the privilege surface is not as stated in the Piece D migration
comment. Discovered-by: Piece E inspection. Status: **OPEN / DEFERRED (hardening)** —
deliberately not modified in Piece E (no edits to the applied Piece D migration).
Resolution path: a dedicated hardening migration issuing `REVOKE EXECUTE … FROM
anon, authenticated, service_role` to match the Piece E convention.

Clarification (2026-09-01, N8 / N8-W) — N8 and N8-W reconfirmed the GAP-004 behavior
rather than discovering a new issue. In this project, schema `public` carries default
function EXECUTE grants to the named roles `anon`, `authenticated`, and
`service_role`, so `REVOKE … FROM PUBLIC` alone does not remove EXECUTE already
granted directly to those roles. A new public RPC migration must therefore explicitly
revoke each unintended named role and then grant only the intended caller role.
`public.match_workers_for_job(uuid)` (N8) and `public.list_my_job_opportunities()`
(N8-W) both follow this explicit role-by-role revoke pattern, and their live `proacl`
values were verified to contain only the intended grantees. This clarification records
the required pattern for future public RPCs; it does not create a new GAP and does not
change the status of GAP-004.

**N9 implementation note — atomic Worker acceptance (2026-09-01)**

*Legacy Booking INSERT path closed.* Before N9, the policy `"System can insert
bookings"` carried only `WITH CHECK (client_id = auth.uid())`, so an authenticated
Client could directly create a Booking while supplying any Worker identifier — a
direct contradiction of the Worker-choice model. N9 removes that policy with no direct
INSERT replacement. **Client direct Worker assignment through bookings INSERT: CLOSED.**
The normal application creation path is now the controlled
`public.accept_job_opportunity(p_job_id uuid)` RPC.

*Legacy Booking UPDATE path closed.* The policy `"Workers and clients can update their
own bookings"` allowed participants broad direct Booking mutation (it carried no
`WITH CHECK`, so the resulting row was unconstrained). N9 removes that direct UPDATE
policy with no replacement. Ordinary participants can no longer directly rewrite
`job_id`, `worker_id`, `client_id`, `status`, the payment fields, or completion state.
Future lifecycle and payment writes require dedicated controlled RPCs. The participant
SELECT policy is preserved unchanged.

*Job matched→open side door closed.* The Client Job UPDATE policy is now open-only in
both `USING` and `WITH CHECK`, so ordinary Client direct updates are restricted to
their own currently-open Jobs and must leave them open. This prevents ordinary Client
`open → matched`, `open → cancelled`, `open → completed`, and `matched → open`
transitions through direct DML.

*Matched-Job DELETE / cascade side door closed.* The Client Job DELETE policy is now
open-only. The foreign key is unchanged and remains
`bookings.job_id → job_postings.id ON DELETE CASCADE`. **N9 did NOT change the FK.**
Protection is authorization-based: ordinary Client DML cannot directly delete a matched
Job, so the cascade cannot be reached through that path after a successful acceptance.

*N9 RPC ACL.* `public.accept_job_opportunity(p_job_id uuid)` is `SECURITY DEFINER`,
`VOLATILE`, `SET search_path = ''`, with EXECUTE granted to `authenticated` and no
EXECUTE for `PUBLIC`, `anon`, or `service_role`. The migration follows the
already-documented GAP-004 role-by-role revoke pattern above. This is not a new GAP.

*Hosted catalog result.* Post-N9 hosted state verified as 11 public base tables, 74
public columns, 27 public RLS policies, 0 zone columns. Catalog and security deployment
are verified; **hosted authenticated acceptance and hosted concurrency remain separate
pending tests** and are not claimed here.

*Carry-forwards (recorded, not acted on).* The existing notifications INSERT policy
permits authenticated insertion broadly (`WITH CHECK (true)`) and remains a security
carry-forward for the Notifications module; no new GAP number is assigned here.
`bookings.worker_id → users.id` and `bookings.client_id → users.id` are both
`ON DELETE CASCADE`; ordinary user account DELETE is not currently reachable through
the application and no delete-account feature exists, but account-deletion/lifecycle
design must explicitly decide how historical Bookings are preserved or removed. No
unique constraint or index on `bookings.job_id` was added; that remains intentionally
deferred until cancellation/rematching semantics are locked.

## Post-N12 security end state — 2026-09-05

Date: 2026-09-05. This section is a **dated evidence snapshot**, not an evergreen
invariant, and it is a documentation synchronization of previously closed evidence. No
test, migration, hosted operation, or RPC invocation was performed to produce it. Every
earlier dated record in this document is retained unchanged; where an earlier record has
been superseded, the supersession is stated here rather than by editing the original.

### Current hosted catalog snapshot

Hosted project `uzbntxxwayqfkusyhodl`, as observed 2026-09-05:

- migrations: **11**
- public base tables: **11**
- public columns: **74**
- public RLS policies: **25**

Application-data counts at the closed verification point:

- `users` 13 · `auth.users` 13
- `worker_profiles` 3 · `worker_skills` 10 · `skills` 4
- `job_postings` 3 · `job_skills` 4
- `portfolio_items` 0
- `bookings` 0 · `notifications` 0 · `ratings` 0 · `messages` 0

Zero fixture residue. Migration tail: `n10_db_01_admin_worker_verification` →
`n11_db_01_participant_booking_lists` → `n12_db_01_trusted_notifications`.

The policy count moved 27 → 25. The delta is exactly the two intentional N12 drops
recorded below. The **27-policy figure in the post-N9 hosted catalog record above remains
correct as a historical snapshot for its own date** and is deliberately not edited.

### N10 — Administrator verification security boundary

`public.list_unverified_workers()` — `SECURITY DEFINER`, `STABLE`, `SET search_path = ''`.
Client EXECUTE surface is `authenticated` only, following the role-by-role revoke pattern
recorded under GAP-004; the Administrator check is performed server-side inside the
function. DEFINER is required because `public.users` SELECT is self-row only.

`public.verify_worker(p_worker_user_id uuid)` — `SECURITY DEFINER`, `VOLATILE`,
`SET search_path = ''`, EXECUTE granted to `authenticated` only, with Administrator
authorization (`private.is_admin()`) enforced inside the function; every other caller
receives `42501`. The target profile row is locked `FOR UPDATE` before the decision
proceeds, so concurrent verification cannot record two `verified_by` attributions. The
write is confined to the verification-operation fields **`is_verified` and `verified_by`
only**. An already-verified Worker, a non-worker target, and a nonexistent target all
return the same `SM409`, so the function is not an account-existence oracle. The N12
version additionally emits a `worker_verified` notification atomically within the same
transaction.

This is the Standing RPC caveat applied deliberately: a postgres-owned DEFINER function
reaches `worker_profiles` as Tier 1, which is why the EXECUTE surface is restricted, the
input validated, and the write column-confined. **`worker_profiles` UPDATE RLS was not
widened.**

### GAP-003 — precise current status

**GAP-003 remains OPEN / DEFERRED. It is NOT closed.**

Clarification (2026-09-05): N10 operationally solves the specific Worker-verification
use-case through `public.verify_worker(uuid)`, a reviewed, column-confined,
authorization-checked RPC. It does not resolve the underlying gap:

- cross-user `public.worker_profiles` UPDATE RLS remains **self-row only**; an
  authenticated administrator still cannot UPDATE another Worker's profile row through
  ordinary PostgREST
- broader controlled administration of `strike_count`, `badge_level`, and protected
  profile fields generally remains **unresolved / deferred**
- the resolution path is unchanged: the dedicated, security-reviewed admin-management
  task alongside GAP-001 / D-008, never absorbed into another piece

Solving a use-case through a reviewed RPC is not the same as closing a row-authorization
gap. No new GAP number is assigned.

### N11 — participant Booking read / privacy boundary

`public.list_my_worker_bookings()` and `public.list_my_client_bookings()` — both
`SECURITY DEFINER`, `STABLE`, `SET search_path = ''`, EXECUTE granted to `authenticated`
only.

Their narrow security purpose: a Booking list must name the counterparty, but
`public.users` SELECT is self-row only. These RPCs are the minimum surface that satisfies
that need. Explicitly:

- **N11 avoids widening `users` SELECT RLS.** The alternative would have exposed every
  account's contact details to every authenticated user, far beyond Bookings. The users
  policy and every other policy are unchanged.
- the caller is derived from `auth.uid()`; neither function takes a participant-id or
  Booking-id parameter
- only owned Bookings are returned, in every status
- counterparty contact/profile release is **live status-gated**: released while
  `confirmed` or `completed`, suppressed for `pending`, `cancelled` and `no_show`
- suppressed states expose no counterparty contact or profile data; the Client-facing
  Worker profile block is gated as one unit
- **email and `verified_by` are excluded** from both projections
- rating aggregates are computed from `public.ratings`, not from the unmaintained
  `worker_profiles.rating_avg`; an unrated Worker yields count `0` and average `NULL`,
  never an actual `0` and never the neutral `3.0` matching constant

### N12 — notification spoofing carry-forward: CLOSED

The carry-forward recorded in the N9 implementation note above — that the notifications
INSERT policy permits authenticated insertion broadly (`WITH CHECK (true)`) and remains a
security carry-forward for the Notifications module — is retained as historical
observation and was accurate when written. **It is CLOSED BY N12.**

The pre-N12 policy was, despite its name, not system-only: `WITH CHECK (true)` let any
authenticated account insert a notification for any `user_id` with arbitrary message
text. It was reachable in practice rather than only in theory, because the N11 Booking
list RPCs project the counterparty's user id, so a participant already held the id needed
to write a forged `booking_confirmed` or `account_suspended` into that person's inbox,
indistinguishable from a genuine system message. The UPDATE policy, named "mark as read",
was column-unrestricted, so a recipient could rewrite the `type` and `message` of their
own rows.

Closure state after N12:

- the authenticated INSERT policy is **dropped**, with no replacement direct INSERT
  policy
- the broad recipient UPDATE policy is **dropped**, with no replacement direct UPDATE
  policy
- `authenticated` direct table privilege is narrowed to **SELECT only**
- `anon` direct notification access is **removed** (it previously held GRANT ALL and was
  blocked only by having no policy)
- `service_role` behavior was not broadened by N12
- the only remaining notification RLS policy is the recipient SELECT
  (`user_id = auth.uid()`), left byte-for-byte unchanged and not widened
- `private.emit_notification(uuid, text, text)` is internal and not client-callable; no
  client role holds EXECUTE
- `public.mark_my_notification_read(uuid)` is the narrow recipient mutation
- forged cross-user or system-looking notification creation is no longer available to an
  ordinary authenticated client through the previous direct table path
- a recipient can no longer rewrite immutable `message` or `type` through the former
  broad UPDATE path

Because privileges were narrowed at the GRANT layer, direct attempts fail with `42501`
before RLS is consulted. No GAP number is assigned to this closure.

### N9 — current test status

Previously closed evidence, synchronized here on 2026-09-05:

- N9 hosted authenticated acceptance: **VERIFIED**
- N9 hosted concurrency: **VERIFIED**
- N9 native acceptance UI: **VERIFIED**

The lines in the post-N9 hosted catalog record above stating that hosted authenticated
acceptance and hosted concurrency "remain separate pending tests" are retained as
historical evidence for their own date and are superseded by the three statuses here.

**Full continuous booking E2E remains rehearsal-needed** — it has never been run unbroken
in a single session, and no such claim is made. iPhone locale/date verification has not
been performed; emulator evidence is not iPhone evidence. No test was newly performed by
this documentation-synchronization task.

### Ratings carry-forward — still OPEN / HELD

Evidence only. No design resolution is made here.

- **INSERT** — the authenticated policy checks `rated_by = auth.uid()` and does **not**
  verify Booking participation or eligibility. Any authenticated user can insert a rating
  for any rated user against any `booking_id`.
- **SELECT** — authenticated-wide `USING (true)`. Scores, comments and `rated_by` are
  readable by any signed-in account.
- **UPDATE / DELETE** — no participant policy exists.
- `worker_profiles.rating_avg` — no implemented maintenance path (N8-OBS-05). Nothing
  computes or updates it.
- N8 matching currently consumes `worker_profiles.rating_avg`, applying the existing
  cold-start computation semantics of D-002. This is inert at zero ratings but is a real
  coupling once Ratings ships.

**Ratings remains NOT STARTED / HELD**, pending its dedicated read-only preflight and
explicit design authorization. Whether `rating_avg` will be maintained, or whether
matching will aggregate `public.ratings` directly, is **not decided here** — that
decision belongs to the Ratings task. N11 already reads aggregates from `public.ratings`
rather than `rating_avg`, which is an implementation fact, not a resolution of this
question.

### Vercel / public-web deployment observation

Dated operational observation, 2026-09-05. Not a security gap and not a decision.

- Connected Vercel inspection found **no project linked** to the SkillMatch/capstone Git
  repository.
- The landing-only Git push (`d7e5ef1`) was therefore not expected to auto-deploy through
  that observed account, and no deployment side effect was observed.
- An earlier connector call returned an empty team list. That result conflicted with the
  later direct project observation and is **not treated as authoritative evidence**. The
  discrepancy is recorded, not investigated.
- No Vercel project was created or linked by the landing-only task.
- Creating or linking the future public landing / APK-distribution project is a separate,
  separately authorized future operation.
- Once such a Git-linked Vercel project exists, pushes to its production branch may
  intentionally acquire deployment side effects and must be governed accordingly — a push
  would stop being a purely local-consequence operation.

**No hosted SkillMatch landing URL is claimed to exist as of this date.**

### GAP registry status at this snapshot

Statuses preserved exactly; none closed, renumbered, or added:

- **GAP-001** — OPEN / DEFERRED BY DECISION (D-008)
- **GAP-002** — OPEN / DEFERRED
- **GAP-003** — OPEN / DEFERRED, with the N10 operational-verification clarification above
- **GAP-004** — OPEN / DEFERRED (hardening)

No GAP-005 is created by N10, N11, N12, the web landing-only correction, or this
synchronization. No decision record (no D-010) is created either.

## BL-01A Booking lifecycle security boundary — 2026-09-05

Date: 2026-09-05. Records the security boundary of the two lifecycle RPCs added by
`bl01a_db_01_booking_completion_cancellation`, plus two factual corrections to earlier
carry-forwards. Local verification only; no hosted deployment is claimed.

### Booking write surface

Current authoritative reality:

- authenticated direct Booking **INSERT: denied**
- authenticated direct Booking **UPDATE: denied**

`public.bookings` carries **only** its participant SELECT policy. Neither BL-01A function
creates, drops or alters any policy, and **participants hold no broad table UPDATE
permission**. The writes succeed because a postgres-owned SECURITY DEFINER function is the
table owner and `relforcerowsecurity` is false — the same mechanism recorded for N10 on
`worker_profiles` and N12 on `notifications`.

The trusted Booking writers are now exactly three:

```
public.accept_job_opportunity        (N9, creates the Booking)
public.complete_my_client_booking    (BL-01A)
public.cancel_my_booking             (BL-01A)
```

Verified from the catalog rather than from source: a scan of every function body in
`public` and `private` returns exactly these three as writers of `public.bookings`, and
the same three as writers of `public.job_postings`.

### Completion boundary — `public.complete_my_client_booking(uuid)`

`SECURITY DEFINER`, `VOLATILE`, `SET search_path = ''`, postgres-owned, EXECUTE revoked
from `PUBLIC`, `anon`, `authenticated` and `service_role` and then granted to
`authenticated` only (live `proacl` = `postgres=X/postgres,authenticated=X/postgres`).

- Client identity derived from `auth.uid()`; no actor identifier is accepted from the
  caller
- active-Client authorization via `private.is_active_client()`; every other caller,
  including the assigned Worker, receives `42501` before any Booking is read
- the Client must own the Booking
- the Booking must be `confirmed` and its Job `matched`
- Booking row then Job row locked `FOR UPDATE`, in that fixed order
- all validation performed after the locks, from the locked values, including that
  `booking.client_id = job.client_id`
- atomic Booking + Job transition to `completed` with a database-time `completed_at`
- atomic trusted notification emission in the same transaction
- payment fields untouched

### Cancellation boundary — `public.cancel_my_booking(uuid)`

Same security properties, ACL and lock order.

- caller identity derived from `auth.uid()`
- active Worker **or** active Client required, else `42501`
- the caller must be the exact Booking participant — that Booking's `worker_id` or
  `client_id`
- the Booking must be `confirmed` and its Job `matched`
- post-lock validation of the Booking/Job pair
- terminal cancellation: the Job is set `cancelled` and is **never reopened**; no
  rematching and no replacement Booking
- atomic counterparty notification in the same transaction
- payment fields untouched

Implemented forward guard: **cancellation of an already-paid Booking fails closed**
(`SM403`, raised only after participation is proven). No path can currently set
`payment_status = 'paid'`, so this is defensive. **No refund system exists.**

### Error and anti-oracle behaviour

The established convention is extended, not replaced:

```
42501  caller role/account authorization failure
SM403  legitimate caller blocked by an action-eligibility rule, where used
SM409  unavailable / current-state conflict
```

Unavailable Booking cases are intentionally **collapsed** where practical — nonexistent
Booking, Booking belonging to another participant, Booking already terminal, Booking not
`confirmed`, and inconsistent Booking/Job linkage all produce the same conflict result —
so an authenticated caller cannot use these functions to probe which Booking ids exist or
what state another participant's Booking is in. `SM403` is used only after participation
has been proven, where the error reveals nothing the caller does not already know.

### Notification atomicity

Lifecycle notifications are emitted through the existing N12 helper **inside the same
database transaction** as the authoritative write. A failed notification insert must roll
back the lifecycle write. Verified locally: under a temporary failure seam on
`public.notifications`, both completion and cancellation aborted with the Booking still
`confirmed`, the Job still `matched`, `completed_at` NULL and zero notifications; with the
seam removed the same call succeeded and emitted exactly one notification.

Notification text carries the Job title and fixed operational wording only. No contact
information is written into notifications, which remain immutable while contact release
is governed by live Booking status.

### N11 privacy regression

Re-verified after both transitions:

- **completed** Booking — remains listed, and the existing N11 contact-release behaviour
  is unchanged
- **cancelled** Booking — remains listed as history, and the counterparty
  contact/profile projection becomes **suppressed**

The live status rule therefore survives the new transitions in both directions.

### Correction — Ratings duplicate prevention

The Ratings carry-forward recorded above is corrected on one point of fact: the baseline
schema already carries

```
ratings_booking_id_rated_by_key  UNIQUE (booking_id, rated_by)
```

so **duplicate rating by the same rater for the same Booking is already
schema-prevented**. No new constraint is needed for that case.

The remaining gaps are unchanged and still open. The current direct INSERT policy checks
only `rated_by = auth.uid()` and does not enforce:

- Booking participation
- `completed` Booking status
- rating direction
- that `rated_user` is the Booking counterparty

SELECT remains authenticated-wide, and there is no UPDATE or DELETE policy. **Ratings is
neither secure nor implemented.**

### BL-01C Messaging security boundary — 2026-09-05

Supersedes the earlier "Messaging has no status gating" correction, which recorded the
pre-BL-01C state: participant-scoped and spoof-proof policies carrying **no** Booking-status
predicate, both targeting role `public` rather than `authenticated`, over a table that still
held the unnarrowed Supabase default ACL. Sends were possible in every status, including
after a Booking was `cancelled` or recorded `no_show`.

Implemented reality after BL-01C (`20260905180000_bl01c_db_01_messaging_status_boundary.sql`):

**Direct table privileges — narrowed.** `anon` holds **no privilege at all** on
`public.messages`; its ACL entry is gone, so an anonymous read or write now fails at the
GRANT layer rather than relying on `auth.uid()` being NULL. `authenticated` holds exactly
**SELECT and INSERT**; UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER and MAINTAIN are all
revoked. `REVOKE ALL` was used rather than an enumerated list so the end state does not
depend on which privilege letters the server version supports — PostgreSQL 17's MAINTAIN
was present in the pre-BL-01C ACL. `service_role` and the `postgres` owner entry are
deliberately unchanged. This is the same GAP-004 discipline N12 applied to
`public.notifications`: an unnecessary privilege is removed at the GRANT layer, not merely
left unreachable behind the absence of a policy.

**Both policies now target `TO authenticated`**, bringing `messages` in line with the rest
of the schema. The policy inventory is exactly **one SELECT and one INSERT** — there is no
UPDATE and no DELETE policy, so messages are **append-only**: no edit, delete or recall
path exists for any caller.

**SELECT — participant-only, status-independent.** A caller sees a message only if they are
exactly that Booking's `worker_id` or `client_id`. It carries **no** Booking-status
predicate, deliberately: history stays readable in `confirmed`, `completed`, `cancelled`
and `no_show`, per the locked boundary in docs/DECISIONS.md. A non-participant receives
zero rows rather than an error.

**INSERT — the send boundary.** All five conjuncts are enforced server-side:

- `auth.uid() = sender_id` — **sender spoofing is prevented**; combined with `sender_id`
  being NOT NULL this also makes an anonymous send impossible
- the caller is exactly this Booking's `worker_id` or `client_id`
- the Booking status is **`confirmed`** — the conjunct BL-01C exists to add
- `btrim(content) <> ''` — no empty or whitespace-only message
- `length(content) <= 2000` — the locked maximum, in characters, rejected rather than
  truncated

Membership and status are read from **one** lookup of the Booking row, so the status can
never be evaluated against a different row than the one membership was proven against.
A rejected send is a single undifferentiated 42501: a non-`confirmed` Booking, a
non-participant, a spoofed `sender_id` and over-length content are indistinguishable to the
caller — the same anti-oracle discipline BL-01A applied by collapsing its cases into one
SM409.

The migration creates no table, column, index, constraint or trigger, so D-001 is
untouched. Two Messaging policies replaced two Messaging policies, so the public policy
count is unchanged at **25**.

**Still a deferred gap: `messages.is_read`.** The column exists with its `false` default and
has **no maintenance path** — no UPDATE policy and, after BL-01C, no UPDATE grant either, so
it cannot be written by any client. Read receipts, message notification fan-out and Realtime
all remain deferred and unimplemented.

Local verification (13 migrations, clean reset): three allowed sends (Worker/`confirmed`,
Client/`confirmed`, exactly 2000 characters) and fourteen denied cases — non-participant,
`completed` (both participants), `cancelled`, `no_show`, `pending`, `sender_id` spoof, empty
content, whitespace-only content, 2001 characters, `anon` send, and authenticated UPDATE /
DELETE / `is_read` UPDATE. Both participants read history in all five statuses; a
non-participant reads 0 rows; `anon` is refused at the GRANT layer. **Local only — the
hosted project has not received this migration and remains at 12.**

### Still deferred after BL-01A

No-show operational path, `strike_count` mutation, automatic third-strike suspension,
refunds, automatic cancellation rematching, and the rating-received notification all
remain deferred. No GAP number is created by BL-01A, and GAP-001 through GAP-004 are
unchanged.

Future gap template:

```
GAP-NNN — <description>. Discovered-by: <task>. Status: OPEN | CLOSED (+ qualifier). Resolution path: <dedicated task>.
```
