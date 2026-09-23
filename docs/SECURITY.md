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
  `confirmed` only (R3B amendment; N11 originally also released `completed`)
- suppressed states (`completed`, `cancelled`, `pending`, `no_show`) expose no
  counterpart contact or profile data; the Client-facing Worker profile block is
  gated as one unit
- exact `job_address` is projected only while `confirmed`; `job_barangay` and
  `job_city` remain on history rows
- counterpart UUIDs remain projected in every status
- **email and `verified_by` are excluded** from both projections
- rating aggregates are computed from `public.ratings`, not from the unmaintained
  `worker_profiles.rating_avg`; an unrated Worker yields count `0` and average `NULL`,
  never an actual `0` and never the neutral `3.0` matching constant
- **`public.job_postings` SELECT is not redesigned.** Authenticated-wide job read
  remains an acknowledged residual. R3B does not claim absolute database-level secrecy
  of job address.

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
carry-forwards.

**Status: DEPLOYED AND HOSTED-VERIFIED -- BL-01A is CLOSED.** The lifecycle migration
`20260905160000_bl01a_db_01_booking_completion_cancellation.sql` is live on hosted and its
hosted lifecycle behaviour is verified. No dedicated real-Expo native closure is claimed
for BL-01A in this document. The BL-01D, BL-01B and BL-01C subsections below each carry
their own status and are not covered by this line.

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

The remaining gaps recorded here were closed by BL-01B; see the section below.

### BL-01D COD trusted payment boundary — 2026-09-06

Adds the cash half of the payment lifecycle. Uses only values the baseline schema already
permits, so no table, column, constraint, index, trigger or enum is created and the public
policy count is unchanged at **24** — this migration creates and drops no policy.

**`public.bookings` grants narrowed.** Before BL-01D the table still carried the
unnarrowed Supabase defaults (`anon` and `authenticated` both `arwdDxtm`) — the last table
in the schema still doing so. Those grants were inert, because `bookings` has exactly one
policy (participant SELECT) and RLS refuses every write with no matching policy, but
BL-01D makes `payment_status = 'paid'` a real financial assertion, so the blast radius of
one mistaken permissive UPDATE policy is materially larger than before. After this
migration **`anon` holds no privilege at all** and **`authenticated` holds SELECT only**;
`service_role` and the `postgres` owner entry are unchanged, and the participant SELECT
policy is untouched. Verified: `authenticated` INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/
TRIGGER/MAINTAIN all false.

**Two trusted RPCs, one Booking row each.** Both are postgres-owned, `SECURITY DEFINER`,
`SET search_path = ''`, every object schema-qualified, EXECUTE revoked from PUBLIC/`anon`/
`service_role` and granted to `authenticated` only. Both take **a Booking id and nothing
else** — there is no payment method, status, amount or reference parameter, so a caller
cannot express "mark this paid" or name a provider.

- **`select_my_booking_cod(uuid)` — Client only.** Active Client account required
  (`42501`); then the Booking must exist, be the caller's, and be `completed` — all three
  collapsed into one `SM409` so the function is not a Booking-existence oracle. The only
  write it can perform is `payment_method = 'cod'` on a `(NULL, 'pending')` tuple.
- **`confirm_my_cod_payment_received(uuid)` — assigned Worker only.** Active Worker
  account required (`42501`); then the Booking must exist, name the caller as `worker_id`,
  be `completed`, and already be `payment_method = 'cod'` — all four collapsed into one
  `SM409`. That COD requirement is also the **PayMongo forward guard**: this function can
  never settle a `gcash` or `maya` Booking. An already-paid Booking raises **`SM403`**
  after participation is proven (mirroring the BL-01A paid guard), before any write and
  before any notification.

**Payment identities are derived, never supplied.** The Client is `auth.uid()`; the Worker
and the notification recipient are read from the locked Booking row.

**Confirmation and notification are atomic.** The Booking row is locked `FOR UPDATE`
before any decision; `payment_status` is then set to `'paid'` and exactly one
`payment_received` notification is emitted to the **Client** in the same transaction.
`private.emit_notification` carries no exception handler, so a failed notification
propagates and rolls the settlement back. Proven locally with a temporary diagnostic that
forced the notification insert to fail: the RPC failed, `payment_status` stayed
`'pending'`, and no notification row was created.

**Invariants held by both functions.** Neither writes `bookings.status`, `completed_at`,
`paymongo_ref`, or any `job_postings` column; neither creates a Rating or a Message nor
changes `worker_profiles.rating_avg`. `paymongo_ref` remains NULL for COD.

Local verification (15 migrations, clean reset): a full canonical lifecycle driven through
the real trusted path — N9 acceptance producing `(NULL,'pending',NULL)`, BL-01A completion
preserving it, Client selection producing `(cod,'pending')`, Worker confirmation producing
`(cod,'paid')` with exactly one Client `payment_received` notification and no rating,
message or Job change. Client matrix 13/13: allowed for the active owning Client on a
completed Booking; `42501` for a Worker caller and for `anon`; `SM409` for a different
Client, `confirmed`, `cancelled`, `no_show`, a nonexistent id, `cod+paid`, `gcash`, `maya`
and `refunded`. Worker matrix 13/13: allowed for the assigned Worker on a completed COD
Booking; `42501` for a Client caller and `anon`; `SM409` for a different Worker, a
completed Booking with no method, `confirmed`, `cancelled`, `no_show`, a nonexistent id,
`gcash`, `maya` and `refunded`; **`SM403`** for an already-paid own Booking. Repeat
selection proven a true no-op by an unchanged row `xmin`. A forced parallel confirmation
race produced one success and one `SM403`, with `payment_status = 'paid'` and **exactly
one** notification. Direct writes as `authenticated` refused for `payment_method`,
`payment_status`, `paymongo_ref`, INSERT and DELETE; `anon` refused entirely; an unrelated
participant's Booking returns 0 rows.

**Status: DEPLOYED AND CLOSED - 2026-09-06.** Hosted received
`20260906093000_bl01d_db_01_cod_trusted_path.sql` via one
`npx supabase db push --linked --skip-vault` preceded by a `--dry-run` scope gate, and now
runs **15 migrations** at an unchanged 11 tables / 74 columns / 24 policies. Hosted
behavioural and real native runtime evidence were both taken the same day. In the current
Expo source under Expo Go, the owning Client selected COD in the app and the authoritative
state became `(cod,'pending')`; the assigned Worker then confirmed cash receipt in the app
and it became `(cod,'paid')`, with **exactly one** `payment_received` notification reaching
the Client and the paid state surviving an authoritative refresh. On hosted, a repeat Client
selection was again a true no-op by unchanged row `xmin`; a repeat Worker confirmation
returned `SM403` with no second write and no second notification; and a proven participant's
direct `UPDATE` of a payment column was refused `42501` at the table-privilege layer, before
RLS -- the narrowing this migration introduced. The temporary Job, `job_skill`, Booking and
four notifications were removed afterwards, restoring every lifecycle table to 0 rows with
the protected `job_postings` fingerprint unchanged.

**Still deferred:** refunds, payment reversal or edit, PayMongo/online settlement, and any
payout logic.

### BL-01B Ratings trusted write boundary — 2026-09-05

Supersedes the Ratings carry-forward and the duplicate-prevention correction above, both of
which described the pre-BL-01B state: an INSERT policy whose only test was
`rated_by = auth.uid()`, over a table still holding the unnarrowed Supabase default ACL,
with `SELECT USING (true)` for every authenticated caller.

**What was exploitable before.** The old policy prevented exactly one thing — forging the
*rater*. It did not check Booking participation, `completed` status, direction, or that
`rated_user` was the Booking's Worker. Any authenticated account could therefore rate any
Booking in any status, naming any user as the rated party, including themselves.

Implemented reality after BL-01B
(`20260905220000_bl01b_db_01_ratings_trusted_path.sql`):

- **Direct authenticated INSERT is DENIED.** The policy is dropped and not replaced, and
  INSERT is revoked at the GRANT layer, so a direct write fails before RLS is consulted.
- **Direct authenticated UPDATE and DELETE are DENIED** — no policy and no grant. Ratings
  are append-only and immutable, which is what makes transactional aggregate maintenance
  sound.
- **SELECT is narrowed** from `USING (true)` to `rated_by = auth.uid() OR rated_user =
  auth.uid()`, `TO authenticated`. Free-text comments and rater/rated pairs are no longer
  readable by every signed-in account. N11's Booking-list RPCs are SECURITY DEFINER and
  bypass RLS, so the released aggregates are unaffected.
- **`anon` holds no privilege at all** on `public.ratings`; its ACL entry is gone.
  `authenticated` holds **SELECT only**. `service_role` and the `postgres` owner entry are
  unchanged. `REVOKE ALL` was used rather than an enumerated list so PostgreSQL 17's
  MAINTAIN could not be left behind.
- **`public.rate_my_completed_worker(uuid, integer, text)` is the sole writer** —
  postgres-owned, `SECURITY DEFINER`, `SET search_path = ''`, every object schema-qualified,
  EXECUTE revoked from PUBLIC/`anon`/`service_role` and granted to `authenticated` only.
- **Server-derived identities.** `rated_by` is `auth.uid()`; `rated_user` is the Booking's
  `worker_id`. Neither is a parameter, so substitution is unrepresentable.
- **Ownership boundary.** Active Client account required (`42501`); then Booking exists,
  is the caller's, is `completed`, and has a Worker — all four, plus a duplicate, collapsed
  into one `SM409` so the RPC is not a Booking-existence oracle. Invalid score or an
  over-length comment raise `22023`, a caller-input class that discloses nothing about any
  Booking.
- **Transactional aggregate maintenance.** The target `worker_profiles` row is locked
  `FOR UPDATE` **before** the insert; the average is then recomputed in full from all
  rating rows and written in the same transaction. Recomputation is used rather than
  incremental arithmetic so the value is exact and self-healing. A forced aggregate-side
  failure was shown locally to roll the rating back entirely.
- **The protected-column guard is unchanged.** `rating_avg` is written through the guard's
  existing Tier 1 (`current_user IN ('postgres','service_role')`), the same mechanism N10's
  `verify_worker()` uses. An ordinary role changing `rating_avg` directly still hits Tier 3
  and is refused — verified after BL-01B.

The public policy count moves **25 → 24**: the Rating INSERT policy is removed and not
replaced, while the Rating SELECT policy is replaced one-for-one. No table, column, index,
constraint, trigger or publication is created, so D-001 is untouched.

Local verification (14 migrations, clean reset): allowed ratings at scores 1–5; denied for a
Worker caller (42501), a different Client, `confirmed`, `cancelled`, `no_show`, a
nonexistent Booking, and a duplicate (all the same SM409); `22023` for NULL/0/6 scores and a
1001-character comment; comment normalisation (NULL, empty, whitespace-only → NULL; padded →
trimmed; 1000 accepted); `anon` refused EXECUTE; direct INSERT/UPDATE/DELETE refused at the
GRANT layer; read visibility 1/1/2/0 for rater A, rater B, the rated Worker and an unrelated
account. Aggregate: first rating exact, second exact mean, N11 live average agreeing within
1e-6, and a forced two-Client lock-contention race producing no lost update. N8 regression:
a rated Worker scored `13.33/20` from the maintained `rating_avg` while an unrated Worker
scored the cold-start `12/20`.

**Status: DEPLOYED AND CLOSED.** `20260905220000_bl01b_db_01_ratings_trusted_path.sql` is
live on hosted. Hosted behavioural verification passed, and real Expo Client runtime was
proven: the Client submitted a rating from the app, the authoritative state refreshed to
show it, and the Worker aggregate updated accordingly, while direct Rating writes stayed
refused at the GRANT layer. The temporary fixtures were removed afterwards, restoring
`ratings` to 0 rows and the Worker `rating_avg` to its entry baseline.

**Still deferred:** rating-received notification, Worker→Client rating, rating edit/delete,
and any rating management surface.

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

**SELECT — participant-only, status-independent (BL-01C).** A caller sees a message only if they are
exactly that Booking's `worker_id` or `client_id`. BL-01C carried **no** Booking-status
predicate, deliberately: history stayed readable in `confirmed`, `completed`, `cancelled`
and `no_show`. A non-participant receives zero rows rather than an error. **R3B amends
the live SELECT rule** to confirmed-only; see “R3B terminal privacy and report-scoped
evidence — 2026-09-11”.

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
non-participant reads 0 rows; `anon` is refused at the GRANT layer.

**Status: DEPLOYED AND CLOSED.**
`20260905180000_bl01c_db_01_messaging_status_boundary.sql` is live on hosted. Hosted
behavioural verification passed, and real Expo Worker and Client runtime was proven: both
participants exchanged messages from the app on a `confirmed` Booking, and history stayed
readable read-only after the Booking reached a terminal state. That was the BL-01C live
rule at closure. R3B later amends ordinary SELECT to confirmed-only; the BL-01C hosted
proof above is provenance, not the current contract. Sending remains permitted only
while `Booking.status = 'confirmed'`. The temporary fixtures were removed afterwards,
restoring `messages` to 0 rows at that closure. Present-day hosted state at BL-01C
closure recording is **15 migrations** and **24** public policies; the **25** recorded
above was correct when BL-01C landed and was reduced to 24 by the later BL-01B Ratings
migration, which replaced two Ratings policies with one.

### R3B terminal privacy and report-scoped evidence — 2026-09-11

**Status: R3B — CLOSED + HOSTED PROVEN + NATIVE RUNTIME PROVEN.** The 2026-09-11
source-only wording below is historical provenance for the contract, not current proof
status. Hosted apply and the original hosted/native matrices closed this lane in
previous dispatches. R3B-N1 (2026-09-15) is supplemental reconfirmation only and does
not create new Phase 1 debt. `public.get_report_booking_messages(uuid)` is not open
proof-debt: the historical hosted R3B matrix already covers its report-scoped
authorization contract.

The contract lives in
`supabase/migrations/20260911100000_r3b_db_01_terminal_privacy.sql` and the 2026-09-11
clarifications in `docs/DECISIONS.md`.

**N11 projection amendment.** Both participant list RPCs keep their signatures and
return every owned Booking. Counterpart contact/profile fields and exact `job_address`
are released only while `confirmed`. `completed` / `cancelled` history remains listable
with those fields NULL. `job_barangay` / `job_city` and counterpart UUIDs remain.
Confirmed behavior is unchanged.

**Ordinary message SELECT.** The participant SELECT policy now also requires
`bookings.status = 'confirmed'`. `completed`, `cancelled`, `pending`, and `no_show`
return zero rows to ordinary callers. INSERT is unchanged. There is still no UPDATE or
DELETE policy and no message-deletion trigger. Historical rows remain stored.

**No Admin table SELECT.** R3B does not add a `public.messages` SELECT policy for
Administrators.

**Report-scoped evidence RPC.** `public.get_report_booking_messages(p_report_id uuid)`
is `SECURITY DEFINER` with `SET search_path = ''`. `private.is_admin()` or 42501. NULL
id is 22023. Missing report, app issue, and any `booking_id` NULL context share one
SM409. Scope is `reports.booking_id` only. Result columns are `message_id`,
`sender_role` (`worker` / `client`), `content`, and `created_at`, ordered
`created_at ASC, id ASC`. No sender UUID, name, phone, email, address, or `is_read`.
EXECUTE is revoked from PUBLIC / `anon` / `service_role` and granted to
`authenticated` only.

**job_postings residual.** This piece does not change
`Anyone authenticated can read open jobs` (`USING (true)`). Suppressing `job_address`
in the participant Booking RPCs is the authoritative list/detail projection hardening.
It is not absolute database-level secrecy of job address.

**R3 unchanged.** Submit, list, get, and review RPCs, the reports table, report
lifecycle, notifications, and punishment behavior are not modified. `no_show` remains
producerless.

**D-001 / ERD.** No table, column, index, constraint, or trigger is added. Structural
ERD impact is none.

**Original hosted / native closure (do not rerun as a new Phase 1 gate).** Backend
commit `7b8d5fa87207152e8e465f618877b14530ee5993` (`feat: harden terminal privacy and
report evidence`). Mobile commit `8fea092fee4750d68301f1f32a7b73ed161d785f`
(`feat: enforce terminal privacy in native app`). Hosted TDD matrix **36/36**. Native
runtime matrix **22/22**. Proven: terminal participant contact suppression; exact
`job_address` suppression with barangay/city remaining; confirmed-only ordinary
participant message access; report-scoped Admin evidence RPC
`public.get_report_booking_messages(uuid)`. Disposable fixtures were cleaned. Do not
create another report fixture merely to repeat that historical Admin-evidence proof.

**R3B-N1 supplemental reconfirmation — 2026-09-15.**
`PASS — participant terminal privacy reconfirmed on retained completed Booking`.
`SUPPLEMENTAL RECONFIRMATION — no new Phase 1 debt created`. Booking
`227adbac-4d6a-4825-986e-2dbec2bfc174` (Job `Defense Rehearsal - Sep 9`). Worker
historical summary: no Client name, phone, profile/contact control, exact street
address, chat, or portfolio access. Client historical summary: no Worker name, phone,
profile/contact/skills/verification block, exact street address, chat, or portfolio
access. Direct chat deep links `skillmatchmobile://worker/chat?bookingId=` and
`skillmatchmobile://client/chat?bookingId=` failed closed with
`Chat is only available while this booking is confirmed.` No messages, composer, Send
control, or message history. No data, Git, Storage, session, matching, or application
mutation. Hosted counts unchanged: 4 completed bookings; reports 0; messages 3;
notifications 14; ratings 2; portfolio items/images/objects 0. Matching fingerprints
unchanged: `private.compute_job_matches(job_id uuid)`
`9433844085e4e0c45c6f68f996238b3c`; `public.match_workers_for_job(p_job_id uuid)`
`a5d50042d3bee78833c765db6b37bd7e`.

### R4 Job posting-time payment intent — 2026-09-11

**Status: R4 — CLOSED + HOSTED PROVEN + NATIVE RUNTIME PROVEN.** R4-DB hosted
verification remains recorded below. R4 native/mobile later closed on hosted Android
runtime and must not be scheduled as a new Phase 1 proof gate. R4B remains
separate and not implemented. The contract lives in
`supabase/migrations/20260911120000_r4_db_01_job_payment_intent.sql` and the
2026-09-11 R4 clarifications in `docs/DECISIONS.md`.

**Source / Git.** R4-DB is committed and synchronized on
`ea2b33764c14955bab3e946d1d5b0b40d76907f4` (`feat: add job payment intent`).

**Local behavioral verification.** Local Supabase/Postgres runtime verification
passed 28/28 required behavioral cases, plus required budget-edge and
compatibility cases. That local matrix proved new `cod` / `qrph` Job intent,
the QR Ph minimum payable budget, payment-method immutability, Worker
opportunity projection, acceptance retaining `(NULL, pending, NULL)`, Cash/QR
intent enforcement, legacy NULL compatibility, unchanged matching/scoring, and
provider isolation. The 28-case matrix was executed **locally**, not hosted.

**Hosted verification.** Migration
`20260911120000_r4_db_01_job_payment_intent.sql` is deployed on hosted project
`uzbntxxwayqfkusyhodl`. Hosted evidence is non-destructive: migration apply
plus catalog, function-definition, ACL, and retained-data/census inspection.
It proved the R4 version present; application table count remains 12;
`job_postings.payment_method` exists, is nullable, and has no default; both
the `cod|qrph` CHECK and the QR Ph budget CHECK are present and validated; the
immutability trigger/function is present; `list_my_job_opportunities()` has
the 12-column R4 shape with the intended RPC ACL; Cash/QR trusted-function
definitions contain Job-intent enforcement; `accept_job_opportunity()` and
the matching functions remain unchanged; all 7 retained pre-R4 Jobs remain
`payment_method IS NULL`; and the retained business census and Booking
payment tuples are unchanged. No hosted business-data mutation outside the
migration, no Auth mutation, and no Edge deployment. The 28-case matrix remains
a **local** proof; native hosted runtime is the later R4-native record below,
not a hosted 28/28 rerun.

**R4 native hosted runtime — CLOSED.** Mobile commit
`ad2de30a7e7c6465983079614d2811c6ac0cdd63` (`feat: add job payment intent to native
flows`). Proven: Cash/QR Ph selection during Job posting; Worker pre-acceptance
visibility of the method; pre-acceptance exact-address/contact privacy; no PayMongo
provider invocation during posting; acceptance Booking stayed unsettled
`(payment_method NULL, payment_status pending, paymongo_ref NULL)`; Cash completion
reached the recorded paid state; QR remained control-only (Start QR Ph Payment was
not pressed); exact disposable-Job cleanup. Do not schedule a new R4 native proof
gate.

**Column.** `public.job_postings.payment_method` is `varchar(20)`, **NULLABLE, no
DEFAULT**. Allowed values `cod` | `qrph`. NULL is legacy compatibility only and is not
backfilled. Table count stays **12**. Booking payment columns are unchanged.

**New INSERT.** Policy `"Active clients can insert their own jobs"` still requires
`private.is_active_client()` and `client_id = auth.uid()`, and additionally requires
`payment_method IN ('cod','qrph')`. A NULL method on a new authenticated INSERT is
denied. Invalid methods are denied by that WITH CHECK and by
`job_postings_payment_method_check`.

**QR Ph budget.** `job_postings_qrph_budget_check` requires
`(payment_method IS DISTINCT FROM 'qrph') OR (budget IS NOT NULL AND budget >= 1.00)`.
The `IS DISTINCT FROM` / `IS NOT NULL` form is load-bearing: a CHECK of
`payment_method <> 'qrph' OR budget >= 1` would accept a `qrph` + NULL-budget row
because CHECK treats UNKNOWN as pass. Cash Jobs keep existing optional `budget >= 0`
semantics.

**Immutability.** `public.guard_job_postings_payment_method()` is `SECURITY INVOKER`,
`SET search_path = ''`, BEFORE UPDATE FOR EACH ROW. Any `payment_method IS DISTINCT
FROM` change raises `42501`, including legacy NULL → `cod`/`qrph`. Trusted lifecycle
RPCs UPDATE `status` only and are not blocked. EXECUTE is revoked from PUBLIC / `anon`
/ `authenticated` / `service_role`.

**Opportunity RPC.** `public.list_my_job_opportunities()` was DROP/CREATE (no CASCADE)
to add `payment_method`. Preserved: owner `postgres`, `STABLE`, `SECURITY DEFINER`,
empty `search_path`, authenticated-only EXECUTE (PUBLIC / `anon` / `service_role`
revoked). Still withholds exact address and Client identity/contact. Scorer unchanged.

**Acceptance.** `public.accept_job_opportunity` is not modified. The Booking still
begins as `(payment_method NULL, payment_status 'pending', paymongo_ref NULL)`.

**Payment enforcement.** `select_my_booking_cod` SM409s when the Job method is `qrph`.
`prepare_booking_qrph` and `claim_and_bind_booking_qrph` SM409 when the Job method is
`cod`. Legacy NULL Jobs keep the previous dual choice. FRESH QR Ph remains
`(NULL, pending, NULL)`; claim/bind still writes method and `paymongo_ref` in one
statement. Edge Function request contracts are unchanged. Job posting performs zero
provider calls.

**R4B.** Post-Booking payment-method switching / agreement is not implemented.

### R5 private Broadcast freshness transport — 2026-09-12

**Status: R5 — CLOSED / IMPLEMENTED.** The 2026-09-12 source-only wording is
historical provenance for the contract. Backend commit
`409f7b4b30859210ca4fc76cfea9d097513adebc` (`feat: add R5 private Broadcast
backend`). Native commit `505c36f4c16017e5a24d7ea7055e5044e36af1a0`
(`feat: add R5 private Broadcast freshness`). Hosted later received this
migration with the rest of the 24-migration catalog. Notification-inbox Broadcast
freshness is runtime proven during R5B. Exact two-device live-chat
`message_inserted` and `booking_status_changed` delivery was not recovered as a
standalone historical runtime closure; those two narrow behaviors are carried to
R6 final regression only. Do not reopen the R5 implementation lane and do not
create a new Phase 1 fixture campaign.

The BL-01C / N12 / PM-01 historical statements that Realtime was deferred remain
true for that time; R5 is the later narrow exception locked in
`docs/DECISIONS.md`.

The contract lives in
`supabase/migrations/20260912110000_r5_db_01_private_broadcast.sql` and the
2026-09-12 R5 lock in `docs/DECISIONS.md`.

**Architecture.** Private Supabase Broadcast is freshness / invalidation
transport only. Authoritative state remains `public.messages`,
`public.notifications`, `public.bookings`, existing RPCs, existing RLS, and
the N12 trusted notification writers. Clients re-read those surfaces. Broadcast
payloads are not a second business-data authority.

**Receive-only clients.** Two `FOR SELECT TO authenticated` policies exist on
`realtime.messages`. No authenticated `realtime.messages` INSERT policy is
added. Chat send remains `public.messages` INSERT. Notification creation
remains `private.emit_notification` and its existing DEFINER callers.

**Topics.** `booking:<booking_uuid>:messages` authorizes only a confirmed
Booking Worker or Client, using
`realtime.topic() = 'booking:' || b.id::text || ':messages'` (no topic-text
UUID cast). `user:<auth_uid>:notifications` requires
`realtime.topic() = 'user:' || auth.uid()::text || ':notifications'`.
Both require `extension = 'broadcast'`.

**Database-triggered events.** `AFTER INSERT` on `public.messages` emits
`message_inserted` `{booking_id, message_id}`. `AFTER INSERT` on
`public.notifications` emits `notification_inserted` `{notification_id}`.
`AFTER UPDATE OF status` on `public.bookings` when status leaves `confirmed`
emits `booking_status_changed` `{booking_id}` on the same booking topic.
`realtime.send(..., true)` runs in the same transaction as the business write.
No message body, contact, address, profile, provider reference, QR, or payment
secret is included. `realtime.broadcast_changes` is not used.

**Trigger functions.** `private.r5_broadcast_message_inserted()`,
`private.r5_broadcast_notification_inserted()`, and
`private.r5_broadcast_booking_status_changed()` are postgres-owned
`SECURITY DEFINER` `SET search_path = ''` trigger-only functions. EXECUTE is
revoked from PUBLIC / `anon` / `authenticated` / `service_role`. No public RPC
is added.

**Publication and schema.** `public.messages`, `public.notifications`, and
`public.bookings` are not added to `supabase_realtime`. No Postgres Changes.
Application table count remains **12**. No new application table, column, or
public RLS policy.

**Realtime dashboard setting.** This piece does not change hosted or retained
local "Allow public access". That setting remains separately gated. Unknown
hosted dashboard state is not treated as confirmed here.

**R5B.** Android OS push / `expo-notifications` / FCM is a separate closed lane.
See “R5B Android OS push — 2026-09-13” below. R5-DB did not start R5B.

**Local verification.** A clean local `db reset` applied 20 migrations with
`20260912110000` last. A 39-case local matrix proved catalog shape, confirmed
Worker/Client booking-topic allow, unrelated/wrong-booking/terminal/malformed/
anonymous deny, own-user notification allow, cross-user and anonymous
notification deny, no client Broadcast INSERT, intended emit payloads,
no event on confirmed-preserving Booking UPDATE, rollback of business write
plus Broadcast row, and unchanged message/notification/completion contracts.
That matrix is **LOCAL only** for the original R5-DB source gate. Later hosted apply
and native implementation closed the implementation lane as recorded in the Status
line above.

### R6 Worker opportunity invalidation — 2026-09-22

The R6 responsiveness extension adds private topic `worker:opportunities` and
event `job_opportunities_changed`. Its deployed contract is
`supabase/migrations/20260922071511_r6_worker_opportunity_invalidation.sql`.
The earlier R5 two-policy inventory above is historical: R6 adds one receive
policy without replacing either existing notification or confirmed-Booking policy.

**Authorization and payload.** `FOR SELECT TO authenticated` on
`realtime.messages` requires `extension = 'broadcast'`, exact
`realtime.topic() = 'worker:opportunities'`, and `private.is_active_worker()`.
Authenticated subscribers are RECEIVE-ONLY; no authenticated realtime INSERT
path or client-originated Broadcast is added. The mobile channel is private.
The trigger supplies only `{}`: no Job id, description, Client identity, address,
skill ids, coordinates, or ranking. A transport-generated id is not business data.
Broadcast is not authoritative business state or evidence of Job eligibility.

**Emission.** PostgreSQL-owned, private, trigger-only
`private.r6_broadcast_job_opportunities_changed()` is SECURITY DEFINER with an
empty search path and EXECUTE revoked from PUBLIC, anon, authenticated, and
service_role. It calls `realtime.send` with the exact event/topic and private=true.
AFTER STATEMENT INSERT/UPDATE/DELETE triggers on both `public.job_postings` and
`public.job_skills` invalidate opportunity freshness in the write transaction.
These triggers do not mutate business rows, create Bookings or notifications,
or replace matching, acceptance, payment, lifecycle, or business-table RLS.

**Native read boundary.** An eligible mounted Worker Home subscribes and always
re-reads `list_my_job_opportunities()` through its existing authoritative loader
on invalidation and SUBSCRIBED/reconnect. Focus also revalidates. Payload contents
never select, append, remove, or rank a Job. Duplicate/replayed events cause only
extra reads, not business changes. Mobile coalesces reads to one in flight with
one pending follow-up, suppresses obsolete results, and cleans up subscriptions.
There is no polling or automatic opportunity selection/navigation: the Worker
chooses a card. Matching, ranking, and eligibility remain server-authoritative
and unchanged; receive authorization does not imply opportunity eligibility.

F5B deployed the migration once. F5C proved the new matching F5 card present on
an already-mounted Worker Home within 40 seconds, with only a later reveal-only
scroll; exact arrival latency was not instrumented. No Worker reload, refresh,
focus change, or navigation was used to cause the reread. The rollback-based
local SQL suite covers the new receive/write boundary and both tables' actions.

### R5B Android OS push — 2026-09-13

**Status: R5B — CLOSED + DEVELOPMENT-APK RUNTIME PROVEN.** Do not schedule another
R5B proof lane. Fresh R7 EAS proof remains final-build validation, not reopened R5B
work.

Backend commit `ff82394011ef90b9c7d5f93d51250cbde60f5b11` (`feat: add R5B push
backend`). Final mobile commit `7580c57246d35d62b6390b292546eb37fe0e2cc2`
(`feat: add Android OS push notifications`). EAS development build
`ffb5c1ef-7919-4b55-b47e-49f3f86377ce` installed on Worker and Client AVDs. Proven:
real Expo push tokens; foreground Android notification; background Android push;
notification-inbox freshness; background tap routing; no duplicate persistent
notification row; sign-out token deactivation; cold-start routing/session restoration
correction; exact fixture cleanup. Expo Go is not valid OS-push proof.

### R3 user reports security boundary — 2026-09-10

**Status: R3 — CLOSED + HOSTED PROVEN + NATIVE RUNTIME PROVEN.** The 2026-09-10
source-only wording is historical provenance for the contract. Backend commit
`b90e9284346d985839046218dfedf1a367b4c182` (`feat: add user reports and admin review`).
Mobile commit `03e87bab8332d16ee00cdde2624e283c3b832997`
(`feat: add native reporting workflows`). Hosted core database matrix **36/36**.
Supplemental ACL matrix **5/5**. Native runtime matrix **22/22**. Proven: Worker/Client
report submission; Admin review/status workflow (`under_review`, `resolved`,
`dismissed`); disposable cleanup. Do not schedule a new R3 runtime gate.

The contract lives in
`supabase/migrations/20260910183000_r3_db_01_user_reports.sql` and the D-001 amendment
in `docs/DECISIONS.md`.

**Table and direct access.** `public.reports` has RLS enabled. `PUBLIC` and `anon` are
revoked entirely. `authenticated` holds **SELECT only** — no INSERT, UPDATE, or DELETE
grant. There is no user UPDATE or DELETE policy. Direct user writes therefore fail at
the GRANT layer before RLS is consulted.

**Reporter-only SELECT.** The single policy is `reporter_id = auth.uid()`,
`TO authenticated`. The reported party receives **zero rows**. Unrelated callers
receive zero rows. There is no Admin table-wide SELECT policy; Administrators do not
read this table through PostgREST.

**Server-derived counterpart identity.** `public.submit_my_booking_report` accepts
Booking, category, and description only. `reporter_id` is `auth.uid()`.
`reported_user_id` is the opposite Booking participant. Callers cannot supply
`reporter_id`, `reported_user_id`, `status`, or Admin fields.

**Submission writers.** Both submit RPCs are postgres-owned, `SECURITY DEFINER`,
`SET search_path = ''`, EXECUTE revoked from PUBLIC / `anon` / `service_role` and
granted to `authenticated` only. Authorization is **role-based**: an authoritative
`public.users` row for `auth.uid()` whose `role` is `worker` or `client`. Inactive
accounts retain reporting access — the RPCs do not call `private.is_active_worker()` or
`private.is_active_client()`, and they do not read `users.is_active`. Administrators
using a user submit RPC receive `42501`.

**Narrow Admin RPC boundary.** `list_reports`, `get_report`, and `review_report` require
`private.is_admin()` internally (`42501` otherwise). List/detail project names, ids,
category, status, description (detail only), optional job title, and Admin lifecycle
fields. They do not project phone, email, exact address, or message history.

**No Admin-wide message access.** R3 adds no messages SELECT policy, no
message dump inside `get_report()`, no evidence column, and no attachment logic.
Historical report-scoped Admin message evidence was deferred to R3B and is now
the separate function `public.get_report_booking_messages(uuid)`.

**No automatic punishment.** `review_report` updates only `reports.status`,
`admin_response`, `reviewed_by`, and `reviewed_at`. It does not mutate
`public.users.is_active`, `worker_profiles.strike_count`, `bookings.status`,
`job_postings.status`, ratings, or payments. Submit RPCs insert a `reports` row and
nothing else.

**Notifications unchanged.** R3 does not modify `notifications_type_check` and does not
emit report notification types.

### R5D-IMG-B1 portfolio image metadata — 2026-09-14

Source-only at this record until a later hosted-apply gate. The contract lives in
`supabase/migrations/20260914120000_r5d_img_b1_portfolio_item_images.sql` and the
D-001 amendment in `docs/DECISIONS.md`. This section does not claim hosted apply.

**Table and direct access.** `public.portfolio_item_images` has RLS enabled. `PUBLIC`
and `anon` are revoked entirely. `authenticated` holds **SELECT, INSERT, and DELETE**
only. There is no UPDATE grant and no UPDATE policy. Client image SELECT is not
granted. There is no Admin table-wide write path.

**Worker-owned policies.** SELECT / INSERT / DELETE are `TO authenticated` and resolve
ownership as `auth.uid()` → `worker_profiles.user_id` → `worker_profiles.id` →
`portfolio_items.worker_id`. INSERT uses `WITH CHECK`. Policies do not compare
`portfolio_items.worker_id` to `auth.uid()` and do not authorize from `storage_path`.

**Max 5.** `CHECK (position BETWEEN 1 AND 5)` plus `UNIQUE (portfolio_item_id, position)`
make a sixth metadata row impossible. No count trigger is added.

**Parent row.** This migration does not alter `public.portfolio_items`, including
`image_url`. Parent delete cascades image metadata rows. Storage objects are not
created or authorized here.

### R5D-IMG-B2 private portfolio Storage — 2026-09-14

Hosted apply of this migration is recorded. The contract lives in
`supabase/migrations/20260914130000_r5d_img_b2_portfolio_storage.sql`. Hosted Storage
after apply is the private `portfolio` bucket and **0 objects**. This section does
not claim Storage API binary upload, download, signed URLs, mobile image
picker/runtime, or Client image viewing.

**Bucket.** `storage.buckets` row `id = name = 'portfolio'` is private
(`public = false`). `file_size_limit = 5242880` (5 MiB). `allowed_mime_types` is
exactly `image/jpeg`, `image/png`, `image/webp`. No GIF, HEIC/HEIF, video, or
document types.

**Object policies.** `storage.objects` policies are `TO authenticated` only and
require `bucket_id = 'portfolio'`. Worker SELECT / INSERT / DELETE resolve
ownership as `auth.uid()` → `worker_profiles.user_id` → `worker_profiles.id` →
`portfolio_items.worker_id`, compared as text to the first two folders of
`storage.foldername(name)`. Exact folder depth is two
(`worker_profile_id / portfolio_item_id / filename`). Path segments are never
cast to uuid. `users.id` is never the first folder. There is no UPDATE policy.
Client object SELECT is not granted. There is no Admin special write. `anon` and
`PUBLIC` have no portfolio object policy.

**B1 metadata table.** This migration does not alter `public.portfolio_item_images`
or `public.portfolio_items`.

### R5D-CLIENT-B1 confirmed-booking Client portfolio read — 2026-09-14

Source-only at this record until a later hosted-apply gate. The contract lives in
`supabase/migrations/20260914200000_r5d_client_portfolio_read.sql` and the
D-001 amendment in `docs/DECISIONS.md`. This section does not claim hosted apply,
Storage HTTP signed-URL runtime, or mobile Client UI. Current R5D-CLIENT proof
classification is the 2026-09-15 R5D-CLIENT-M1 record below.

**Worker.** Own-row portfolio read/write is unchanged: `Workers can manage their own
portfolio` on `public.portfolio_items`; Worker SELECT / INSERT / DELETE on
`public.portfolio_item_images`; Worker SELECT / INSERT / DELETE on `storage.objects`
for canonical two-folder portfolio paths. Workers cannot read another Worker's
portfolio text after the residual authenticated-wide SELECT was removed.

**Client.** Read-only. An active authenticated Client (`private.is_active_client()`)
may SELECT portfolio content for the assigned Worker only while a Booking exists
such that `bookings.client_id = auth.uid()`, `bookings.worker_id =
worker_profiles.user_id`, `bookings.status = 'confirmed'`, and
`portfolio_items.worker_id = worker_profiles.id`. The same predicate authorizes
`portfolio_item_images` through the parent item. No Client INSERT / UPDATE / DELETE.
No portfolio access from `pending`, `completed`, `cancelled`, or `no_show`.

**Residual removed.** Policy `Anyone authenticated can read portfolio items`
(`FOR SELECT TO authenticated USING (true)`) is dropped. There is no remaining
authenticated-wide SELECT path on `public.portfolio_items`.

**Storage.** The `portfolio` bucket remains private (`public = false`),
`file_size_limit = 5242880`, MIME `image/jpeg` / `image/png` / `image/webp`. Client
object SELECT requires `bucket_id = 'portfolio'` and
`storage.objects.name = portfolio_item_images.storage_path` for a metadata row whose
parent item belongs to the confirmed counterpart Worker. Folder-only / prefix Client
reads are not authorized. Path segments are not cast to uuid. Signed URLs remain
transient client-side artifacts of object SELECT; they are not stored in Postgres.
`getPublicUrl` is not part of this contract. No bucket update is made here.

**Not added.** No public RPC, no new helper, no grant widening, no Admin portfolio
write policy, no matching/ranking/eligibility change.

### R5D-CLIENT-M1 confirmed-Client portfolio Android runtime proof — 2026-09-15

**Status: R5D-CLIENT-M1 — CLOSED.** Backend authorization is hosted/runtime
exercised. Mobile Client UI is implemented, committed, pushed, and
Android-runtime proven. This record does not close R7 or final System Checking.

**Source / Git.** Backend source SHA
`9978238bad8efb7de630a56db176a364e89dcbfd`. Mobile implementation SHA
`f4366ac01f266873f765ad513bb64d8b8bcea736` (`feat: add confirmed-client portfolio view`).

**Runtime.** A disposable hosted Android fixture chain — one Job, one confirmed
Booking, one portfolio item, and one private image — was created through the real
Client and Worker flows, then removed exactly.

Confirmed Client access used `/client/portfolio?bookingId=<confirmed-booking-uuid>`.
Route authority used `bookingId`; no Worker ID was trusted in route parameters.
The Client screen rendered the assigned Worker name, portfolio title, description,
scale, and private image. The image used a private signed URL; no public URL path.
The Client had no portfolio write controls.

A retained completed Booking did not show View Portfolio. A stale completed-Booking
deep link returned `This portfolio is unavailable.` Exact Client portfolio access
was therefore proven while confirmed and denied after terminal state.

**Non-regression / cleanup.** Matching fingerprints and retained business data were
unchanged. The disposable Job, Booking, portfolio item, image metadata, Storage
object, and two notifications were removed exactly. Final counts returned to the
pre-fixture baseline.

**Static.** Tests 220/220 PASS. TypeScript clean. Lint: only the three documented
pre-existing warnings.

**Not claimed.** The reused development APK was sufficient for this feature gate but
is not a fresh R7 EAS-build proof. This record does not claim live-payment,
matching-change, or broader portfolio-visibility beyond the confirmed-booking
counterpart contract. **R5D-CLIENT remains FULLY CLOSED.** Do not change this M1
classification.

### Phase 1 closure correction — 2026-09-15

**Status: Phase 1 functional/security implementation — CLOSED — implemented and proven
to its recorded boundaries in previous dispatches.** Small final regression checks do
not reopen Phase 1.

**PROOF-RECON-01 — CLOSED WITH CORRECTIONS.** Its initial 2026-09-15 output
incorrectly reopened completed gates because earlier runtime and hosted closure
records were not fully recovered. PROOF-RECON-01 is not the current active gate.

**MATCH-DECISION-01 — CLOSED.** Authoritative new-Worker cold-start rating
component: `12/20`.

D-002 amendment dated 2026-08-31, canonical decision commit
`9947e16ec9e20b45f6a4fde041a8e4f519a57ca9`, locked ranking Skill 50 / Location 30 /
Rating 20. A Worker with no rating row receives computation-only neutral `3.0`;
`3.0 / 5 × 20 = 12/20`; `is_new_worker = true`; do not display `3.0` as an actual
received rating. Rating-row existence determines newness. A real `rating_avg = 0`
is not converted into the cold-start value. BL-01B later reaffirmed `12/20`.
Source implementation, recorded regression evidence, and recorded hosted function
fingerprints remain consistent. No later locked decision changed the value. No
matching mutation is required.

`10/20` is **STALE HANDOFF/RECON TRANSCRIPTION — never an approved cold-start
value**. The old `10` belonged to the superseded four-factor model's Rating weight
(`40 Skill / 30 Location / 20 Verification / 10 Rating`). It was not a current
`10/20` cold-start score. Original D-002 wording remains append-only historical
provenance in `docs/DECISIONS.md` and was not edited by this gate.

Hosted consistency is supported by the previously recorded 2026-09-15 function
fingerprints and the verified absence of any later CREATE OR REPLACE migration for
the matching functions. MATCH-DECISION-01 performed no fresh hosted catalog query
because Supabase MCP required authentication. Previously recorded fingerprints:
`private.compute_job_matches(uuid)` `9433844085e4e0c45c6f68f996238b3c`;
`public.match_workers_for_job(uuid)` `a5d50042d3bee78833c765db6b37bd7e`.

### R5E-D1 — Job pin / static map product and security contract — 2026-09-15

**Status: R5E-D1 — CLOSED as documentation lock.** Canonical product, privacy, schema
authorization, matching non-impact, Expo direction, TDD seams, and review workflow are
recorded here and in `docs/DECISIONS.md`. This gate implemented no application source,
migrations, packages, Expo configuration, or hosted mutation. This final decision
supersedes the earlier temporary selection that included live Worker tracking.

**R5E-PREFLIGHT-01 — CLOSED.** Read-only discovery identified existing text
address/barangay/city behavior and the absence of pins, coordinates, maps, navigation
handoff, device-location permissions, and active Worker location. Existing address
fields are not R5E.

**Current gate: R5E-M1.** Client pin picker after R5E-DB1. R5E-DB1 is CLOSED.

**Next:** R5E-M2 Worker approximate/exact static map + `Open in Maps` → R5E-N1
hosted/native privacy proof → remaining V2 UX → R6 → R7 → System Checking.

**Locked Client flow.** Interactive map centered on the approved Santa Ana, Pateros
service area. `Use Current Location` requests **foreground** device-location permission
only after the Client invokes that action. Granted: center and place the editable Job
pin at the current device position; the Client may still drag/tap a different pin.
Denied or unavailable: manual pin placement remains; posting must not crash; do not
repeatedly force the prompt. Manual address/house/street/landmark remains required.
Fixed `barangay = Santa Ana` and `city = Pateros` remain. Save only the final selected
Job pin. Do not retain the Client current-location reading separately. Owner may edit
address and pin only while the Job is open/unaccepted. After acceptance/confirmation
the address and pin are immutable. Legacy Jobs without coordinates keep the text-only
fallback.

**Locked Worker before acceptance.** Approximate non-interactive area map plus
barangay, city, and existing authorized opportunity fields. No exact latitude/longitude,
exact pin, house/street address, residence-identifying landmark, Client contact, or
`Open in Maps`. The approximate marker is **not** a jitter or rounding of the exact pin.
Use only the approved general area associated with barangay/city (current deployment:
general Santa Ana, Pateros). Do not invent an official barangay polygon or centroid
without verified source data. Copy: `Approximate Job area. Exact location becomes
available after acceptance.` Exact Santa Ana display center/bounds are an R5E-M1
preflight verification item.

**Locked Worker after acceptance.** Assigned Worker on a `confirmed` Booking only:
exact saved Job pin; non-interactive in-app map; manual house/street/landmark;
barangay; city; `Open in Maps` to the installed navigation app with the **fixed Job
destination**. SkillMatch does not publish or collect the Worker’s location.

**Locked terminal / Client visibility.** `completed`, `cancelled`, and any other
terminal status: no exact coordinates, no exact map, no `Open in Maps`, R3B exact
address/landmark suppression, barangay/city history only. Direct deep links fail
closed. Owning Client may view the exact pin while editing an open/unaccepted Job and
while the Booking is confirmed. Terminal Client surfaces must not re-expose the pin.

**NOT AUTHORIZED / REMOVED FROM R5E:** live Worker location; active Worker tracking;
foreground or background Worker tracking; continuous Client tracking; movement
history; Worker-location Realtime/Broadcast; Worker-location tables or RPCs; location
update timers; foreground tracking services; background-location permission; Client
watching Worker movement; Admin live-location map. `R5E-ACTIVE-*` is removed from the
active roadmap. No Worker device-location permission is required.

**Expo direction (do not install during R5E-D1).** `react-native-maps` for the
interactive Client picker and for Worker “static map” as the same native map with
interaction disabled. Client `expo-location` foreground-only for `Use Current Location`.
Existing `expo-linking` for `Open in Maps`. Do not use Google Static Maps HTTP URLs
containing precise coordinates. Do not use `expo-maps` (alpha; unavailable in Expo Go
under inspected SDK 57 docs). Authenticate remote Expo MCP and re-check SDK 57
install/config requirements before the first mobile mutation. Maps native
configuration requires a fresh development APK; the reused R5D APK cannot prove R5E.
Restrict Google Maps Android credentials to the SkillMatch Android package and
authorized SHA-1. Do not commit an unrestricted API key. Do not enable
`isAndroidBackgroundLocationEnabled`, `ACCESS_BACKGROUND_LOCATION`, or background
location tasks. Expo tooling is advisory and cannot override this contract.

**D-001 / D-002.** Precise coordinates live in authorized `private.job_locations`, not
on `public.job_postings`. Public application-table count remains 13. Matching stays
Skill 50 / Location 30 / Rating 20 on existing barangay/city rules only.

**Mandatory R5E-DB1 security dependency.** The existing authenticated-wide
`job_postings` SELECT must not expose `job_postings.address` or any precise coordinate
data to unassigned Workers. Inventory every direct `job_postings` reader and replace
or narrow unsafe reads before precise coordinates are deployed. Not solved in R5E-D1.

**Authorized TDD seams (no tests in this gate).** Backend: atomic Job + skills +
coordinates creation; owning Client open-Job read/update; unassigned Worker
exact-coordinate denial; opportunity RPC contains no exact coordinates/address;
confirmed assigned Worker allow; confirmed owning Client allow; nonparticipant denial;
completed/cancelled denial; malformed/out-of-range/nonfinite coordinate rejection;
matching-function fingerprints unchanged; legacy coordinate-null Job compatibility.
Mobile pure functions: coordinate validation; permission-result mapping;
approximate-versus-exact lifecycle projection; general-area map-region mapping;
external navigation URL construction; text-location fallback; map-unavailable
fail-closed state. Mock only system boundaries (`expo-location`, map component
boundary, `Linking.openURL`). Do not mock internal business logic.

**Code review.** After substantive implementation and before staging:

```
preflight and confirmed seam
→ Matt Pocock TDD
→ tests/static checks
→ Matt Pocock Standards review
→ Matt Pocock Spec review
→ runtime/privacy proof
→ stage/commit
→ push
```

R5E-DB1 security/RLS review is sequential. Mobile-only Standards and Spec may run in
parallel only when the diff has no SQL/security surface.

### R5E-DB1 — private Job coordinate contract — 2026-09-15

**Status: R5E-DB1 — CLOSED + HOSTED PROVEN (local 56/56, hosted 56/56).** Backend/security
foundation only. No mobile UI, Expo packages, maps, or `Open in Maps`.

**Migration.** `supabase/migrations/20260915120000_r5e_db_01_private_job_locations.sql`
applied locally by `db reset` and hosted by one `npx supabase db push --linked --skip-vault`
after a dry-run that listed exactly that file.

**Schema.** `private.job_locations` is a private one-to-one Job pin (`job_id` PK/FK to
`public.job_postings(id) ON DELETE CASCADE`; finite latitude −90..90; finite longitude
−180..180; `created_at` / `updated_at`). RLS enabled with no policies. `anon`,
`authenticated`, `PUBLIC`, and `service_role` hold no table privileges. Public
application-table count remains **13**. No latitude/longitude columns on
`public.job_postings`. No Worker-location table.

**Atomic create.** `public.create_my_job_with_location(...)` is postgres-owned
`SECURITY DEFINER` with `SET search_path = ''`. Caller is `auth.uid()` via
`private.is_active_client()` (42501 otherwise). Server writes `barangay = Santa Ana` and
`city = Pateros`. Job, required skills, and private pin are inserted in one function
transaction. Invalid coordinates, blank address, or unknown skills raise `22023` and
leave no orphan row.

**Owner update.** `public.update_my_open_job_location(uuid, text, float8, float8)`
replaces address and pin only while the Job is `open` and owned by the caller. Accepted
Jobs share `SM409`.

**Pre-accept approximate area.** `public.get_job_approximate_area(uuid)` returns
`job_id`, `barangay`, `city`, and `approximate_area_key` (`santa_ana_pateros` when those
fields match the locked deployment). It does not return address or coordinates. Eligible
open-Job Workers (via `private.compute_job_matches`) or the owning Client of an open Job.
Otherwise `SM409`. `list_my_job_opportunities()` is unchanged (fingerprint
`a135ec4ddac213df3f3ef147f93e0fc9`) and still has no address/latitude/longitude result
columns.

**Exact location.** `public.get_authorized_job_location(uuid)` returns address and pin
only for the owning active Client of an `open` Job, or a `confirmed` Booking participant.
Identity is `auth.uid()`. `completed`, `cancelled`, `no_show`, nonparticipants, and
unknown ids share `SM409`. Legacy Jobs without a pin return the stored address and NULL
coordinates.

**Address SELECT hardening.** Table-level `SELECT` on `public.job_postings` is revoked
from `anon` and `authenticated`. Column `SELECT` is re-granted for every Job column
except `address`. Direct authenticated `SELECT address` is `42501`, including the
owning Client. Inventoried readers: N7 Client INSERT still writes `address` and
returns `id` only; Client dashboard and `fetchJobPaymentMethod` select non-address
columns; `list_my_job_opportunities()` has no address/coordinate result columns;
R3B `list_my_*_bookings()` remain SECURITY DEFINER status-gated address projection;
matching reads barangay/city only. No public address view exists.

**Matching.** Untouched. Hosted and local fingerprints after apply:
`private.compute_job_matches(uuid)` `b9b686e6b0b9a87ee8618b5600b1ed62`;
`public.match_workers_for_job(uuid)` `9239550ea9da726a3002bb3503d12f73`;
`private.location_points(text,text,text,text)` `3da08e1ce3b7b7089ff51285a7c33dae`.
These match the R5D-CLIENT hosted record. The earlier MATCH-DECISION-01 pair
(`9433844085e4e0c45c6f68f996238b3c` / `a5d50042d3bee78833c765db6b37bd7e`) remains
append-only recon transcription and is not the live catalog identity.
Behavioral score for a same-barangay Santa Ana Worker with one matching skill and no
rating rows remains Skill 50 / Location 30 / Rating 12.

**Local verification.** Clean `db reset --local` applied 25 migrations. R5E-DB1 SQL
matrix **56/56**. Existing suites: R5D-CLIENT-B1 **46/46**, R5D-IMG-B1 **17/17**,
R5D-IMG-B2 **22/22**.

**Hosted proof — 2026-09-15.** Migration history contains `20260915120000`. Catalog:
`private.job_locations` present; public tables 13; authenticated cannot SELECT
`job_postings.address` or `private.job_locations`. The same 50-case script ran through
`npx supabase db query --linked` inside `BEGIN`/`ABORT` and returned **56/56**. Census
before and after: `job_postings` 7, `bookings` 4, `private.job_locations` 0, zero
`r5e-db1-%` users. No disposable hosted rows were retained. Protected Jobs were not
modified.

**Current gate: R5E-M1.** Client pin picker. Do not start it from this record.

**R1-C session persistence — CLOSED at the recorded Expo Go/AVD proof boundary.**
Prior proof included JavaScript reload, background/foreground, Expo Go process
restart, AVD reboot, session restoration without credentials, and correct
Worker/Client role restoration. A generic standalone-APK persistence recheck may
remain inside R7 final regression. It must not reopen R1-C.

**R2 Forgot Password — CLOSED + PUSHED + RUNTIME PROVEN.** Mobile commit
`f1dae1a98e804be7a05e9588d461c114d7c2ef33` (`feat: add native password recovery`).
Proven: recovery link / deep link `skillmatchmobile://update-password`; Update
Password form; password update; new-password login; fail-closed invalid/expired
recovery handling (`This recovery link is invalid or expired.`); generic
account-existence copy; fixture cleanup; EAS preview APK proof. Do not schedule a
new R2 fixture gate.

**Carried to R6/R7, not reopened Phase 1 lanes:** exact R5 two-device live-chat /
`booking_status_changed` Broadcast coverage; standalone installed-APK session
persistence; AI-02 installed-APK PDF share sheet; AI-SVC-01 authorized nonzero-gap
provider call; Worker portfolio max-five / multi-image gallery behavior.

R5F OTP Authentication remains not active / not authorized. R5G Booking Confirmation
Email remains flagged out. R5H Budget Negotiation remains not active / not
authorized. R5I core Reports remain implemented; only integrated regression / UX
polish remains.

### Still deferred after BL-01A

No-show operational path, `strike_count` mutation, automatic third-strike suspension,
refunds, automatic cancellation rematching, and the rating-received notification all
remain deferred. No GAP number is created by BL-01A, and GAP-001 through GAP-004 are
unchanged.

### V3-1 — consent, worker identity, Santa Ana geofence — 2026-09-18

**Status: HOSTED VERIFIED.** Project ref `uzbntxxwayqfkusyhodl`.
DB1 consent = deployed. DB2 valid ID = deployed. DB3 review = deployed.
DB4 geofence/title/description = deployed. This record is not native or
emulator runtime proof. DB5 and BE-5 were still local-only at this gate;
they are hosted in V3-5 below.

Public application-table count remains **13**. New objects live in `private` plus
reviewed `SECURITY DEFINER` RPCs. Matching fingerprints are unchanged:
`private.compute_job_matches(uuid)` `b9b686e6b0b9a87ee8618b5600b1ed62`;
`public.match_workers_for_job(uuid)` `9239550ea9da726a3002bb3503d12f73`;
`private.location_points(text,text,text,text)` `3da08e1ce3b7b7089ff51285a7c33dae`;
`public.list_my_job_opportunities()` `a135ec4ddac213df3f3ef147f93e0fc9`. GPS is not a
matching input. `verify_worker()` remains the sole writer of `is_verified` /
`verified_by`. Worker-choice `accept_job_opportunity()` is untouched.

**Consent.** `private.user_consents` (`user_id` PK/FK to `public.users`). RLS on;
`anon` / `authenticated` / `service_role` / `PUBLIC` hold no table privileges.
Locked versions `2026-09-v1` / `2026-09-v1` via
`private.current_legal_terms_version()` and
`private.current_legal_privacy_version()`. RPCs:
`public.record_my_consent(text,text)` and `public.get_my_consent()`. Own-user only.
Unsigned or missing `public.users` row is `42501` for both `record_my_consent` and
`get_my_consent`. Wrong version is `22023`.
Same-version repeats keep original timestamps. Consent is not stored in Auth
metadata. Corrective migration
`20260918160000_v3_db_05_get_my_consent_users_row.sql` aligns `get_my_consent` to
that unsigned-or-missing-`public.users`-row `42501` behavior. It was local-only
at V3-1 and is hosted as of V3-5.

**Worker valid ID.** `private.worker_id_documents` plus private Storage bucket
`worker-identity` (`public=false`, 5 MiB, jpeg/png/webp). Path
`{worker_profiles.id}/{uuid}.jpg|jpeg|png|webp`. Allowed `id_type`:
`national_id`, `drivers_license`, `passport`, `umid`, `postal_id`. RPCs:
`public.submit_my_valid_id(text,text)` and `public.get_my_identity_submission()`.
Upload does not set `is_verified`. Approved submissions cannot be replaced
(`SM409`). Storage SELECT/INSERT is own-worker folder only. No public URL.
Already-verified pre-V3 Workers without identity documents remain grandfathered.
They are not unverified.

**ID review.** `public.list_workers_pending_id_review()`,
`public.get_worker_identity_for_review(uuid)`,
`public.approve_worker_identity(uuid)`, `public.reject_worker_identity(uuid,text)`.
Non-admin `42501`. Missing/non-pending targets `SM409`. Approve calls
`verify_worker()` then marks the document approved. `reject_worker_identity`
does not modify `is_verified` or `verified_by`. Administrator Storage SELECT
is limited to the exact pending object path
via `private.admin_may_read_identity_object(text)`.

**Geofence.** `private.assert_job_pin_in_service_area(float8,float8)` enforces the
NAMRIA/PSA COD-AB v03 Santa Ana, Pateros polygon (HDX `cod-ab-phl`,
`phl_admin4.shp`, `adm4_pcode` `PH1307606007`, current PSGC `1381701007`,
EPSG:4326, 153 vertices including close). Applied to
`create_my_job_with_location` and `update_my_open_job_location`. Vertices/edges
count as inside. The shapefile display centroid is not the geofence.
`authenticated` and `anon` `INSERT` on `public.job_postings` is revoked so a
Client cannot bypass the pin check. Description is required. `job_postings.title`
is retained and derived from the primary required skill name.

**Local suites added.** `supabase/tests/v3_db_01_user_consent.sql`,
`v3_db_02_worker_valid_id.sql`, `v3_db_03_worker_id_review.sql`,
`v3_db_04_service_area_geofence.sql`. Existing R5E fixture pins were moved inside
the official polygon so create/update still exercise location privacy, not a
geofence miss.

**Hosted — 2026-09-18 (V3-1).** Project `uzbntxxwayqfkusyhodl`. DB1 consent, DB2 valid ID,
DB3 review, and DB4 geofence/title/description are deployed. HOSTED VERIFIED.
This is not native or emulator runtime proof. Matching fingerprints remain:
`private.compute_job_matches(uuid)` `b9b686e6b0b9a87ee8618b5600b1ed62`;
`public.match_workers_for_job(uuid)` `9239550ea9da726a3002bb3503d12f73`;
`private.location_points(text,text,text,text)` `3da08e1ce3b7b7089ff51285a7c33dae`;
`public.list_my_job_opportunities()` `a135ec4ddac213df3f3ef147f93e0fc9`.
Public application-table count remains **13**. At this gate DB5 and BE-5 were
not yet hosted.

**BE-5 design lock (hosted census, read-only, 2026-09-18).** Total Worker
profiles = 3; available = 2; busy = 1; offline = 0. That census authorized
narrowing `availability_status` CHECK to `available | busy` with no data rewrite.
Deployed in V3-5.

### V3-5 — DB5 consent correction + BE-5 two-state availability — 2026-09-18

**Status: HOSTED VERIFIED.** Project ref `uzbntxxwayqfkusyhodl`
(`livelihood-matching-platform`). Deployed by `npx supabase db push --linked
--skip-vault` after a dry-run that listed exactly:

- `20260918160000_v3_db_05_get_my_consent_users_row.sql`
- `20260918170000_v3_db_06_worker_availability_two_state.sql`

No analytics, email, Phosphor, seed, or role files were deployed. Local and
remote migration history now match through `20260918170000`. This record is not
new native/emulator runtime proof. V3-4 already proved the Worker ID + Admin
approval path; this gate is schema/hosting only. The disposable Worker fixture
was left intact for a later cleanup gate.

**DB5.** Hosted `public.get_my_consent()` now requires an authoritative
`public.users` row. Signed-out or missing `public.users` is `42501`. A
`public.users` row with no consent still returns empty. EXECUTE remains
authenticated-only: `authenticated` granted; `anon`, `PUBLIC`, and
`service_role` revoked, matching the locked DB1 contract. Missing-user `42501`
was proven locally; hosted users rows were not deleted to re-test that branch.

**BE-5.** Hosted `worker_profiles_availability_status_check` accepts only
`available | busy`. `offline` is no longer a valid stored value. Column
`DEFAULT 'available'` is unchanged. No Worker row was rewritten: pre-deploy
census was total 4, available 3, busy 1, offline 0, unexpected 0 (the fourth
profile is the V3-4E disposable Worker). Post-deploy census is the same.
Matching fingerprints are unchanged:
`private.compute_job_matches(uuid)` `b9b686e6b0b9a87ee8618b5600b1ed62`;
`public.match_workers_for_job(uuid)` `9239550ea9da726a3002bb3503d12f73`;
`private.location_points(text,text,text,text)` `3da08e1ce3b7b7089ff51285a7c33dae`;
`public.list_my_job_opportunities()` `a135ec4ddac213df3f3ef147f93e0fc9`.
`verify_worker()` remains the sole writer of `is_verified` / `verified_by`.

**Local suites added.** `supabase/tests/v3_db_05_get_my_consent_users_row.sql`,
`v3_db_06_worker_availability_two_state.sql`.

### AA-01B — Administrator aggregate read boundary — 2026-09-23

**Status: LOCAL IMPLEMENTATION / LOCAL TEST EVIDENCE ONLY.** The forward-only
`20260923012025_aa01_admin_aggregate_summary.sql` migration adds exactly
`public.get_admin_analytics_summary()`; the focused rollback test is
`supabase/tests/aa01_admin_aggregate_summary.sql`. No application table,
column, index, trigger, RLS policy, or business writer is added. Hosted
deployment is **PENDING**. The native Admin dashboard is **NOT IMPLEMENTED** by
this gate. No hosted or native runtime proof is claimed.

The zero-argument, one-row RPC returns `as_of timestamptz`, `bigint` totals for
Workers, verified Workers, pending Worker verifications, Clients, completed
Bookings, and Reports needing attention, plus fixed-key `jsonb` breakdowns of
Job status, Booking status, Booking payment method/status, and Report status.
The snapshot counts all retained `public.users` application accounts, including
inactive accounts and synthetic fixtures; Auth-only records are excluded.
Pending verification counts distinct Worker accounts with a pending submission
in the current `list_workers_pending_id_review()` queue, not every unverified
profile. Payment counts use `public.bookings` state, not Job posting-time
intent, and include explicit zeroes and `unset` buckets for nullable legacy
fields. Completed Bookings do not imply payment; `submitted` plus
`under_review` Reports are workload, not strikes or unread notifications.
Each base entity is counted independently so child rows cannot multiply it.

The function is postgres-owned, `STABLE SECURITY DEFINER`, with empty
`search_path` and schema-qualified relations. It derives caller identity from
`auth.uid()` and requires the existing `private.is_admin()` active-Admin gate;
all denied callers receive `42501`. EXECUTE is revoked from `PUBLIC`, `anon`,
`authenticated`, and `service_role`, then granted only to `authenticated`.
It returns aggregates only, grants no broad Admin table access, and performs
no business writes.

**Local evidence.** The focused migration plus test ran in one local database
transaction and ended with `ROLLBACK`: **22/22 PASS**. It covered active Admin,
signed-out/Worker/Client/missing-account/inactive-Admin denial, direct
`service_role` denial, ACL/function properties, empty zero buckets, all current
status/payment categories and legacy NULLs, pending-ID versus unverified
profile membership, child-row inflation, exact response keys, private-field
absence, and unchanged business rows. The 12 pre-existing local SQL test files
also passed (316 cases); the locally absent R6 migration was supplied only
inside that test's rollback transaction. No migration was persistently applied.
`supabase db lint --local --schema public,private --level warning --fail-on error`
exited 0 with four warnings in pre-existing functions; the new function was
not present in the standing local schema for that separate lint command.
The new function separately passed transactional PL/pgSQL validation with
`check_function_bodies = on` and `plpgsql.extra_warnings = 'all'` (no warnings),
and behavioral execution in the rollback test.

**Hosted AA-01C verification — 2026-09-23.** Implementation commit
`b90a052c0d85726314c17f462f4e061a9ed5ba72` was pushed to `origin/main`
before deployment. A linked-project dry run for `uzbntxxwayqfkusyhodl`
listed only `20260923012025_aa01_admin_aggregate_summary.sql`, with no seeds
or roles. `npx.cmd --no-install supabase db push --linked --skip-vault` then
applied exactly that file; its SHA-256 is
`F0D74FCB2540DA255C7ADCB73A207EE6178E61E29628E4DFCF3E251FA47399C1`.
Hosted migration history contains version `20260923012025` exactly once.

The installed `public.get_admin_analytics_summary()` has zero arguments and
the approved eleven-column return shape (`as_of timestamptz`; six `bigint`
totals; four `jsonb` breakdowns). Catalog inspection and the installed
definition match the migration: `postgres` owner, `STABLE SECURITY DEFINER`,
empty `search_path`, schema-qualified reads, and the active-Admin check through
`auth.uid()` and `private.is_admin()`. Only `authenticated` has EXECUTE among
application roles; `PUBLIC`, `anon`, and `service_role` do not. The migration
adds no Admin business-table policy or write grant.

An existing active Admin was checked through a caller-scoped SQL claims harness
inside a read-only, repeatable-read transaction. This is **SQL authorization
proof, not native Admin UI proof**. The RPC returned exactly one row with a
server-generated `as_of`, the approved typed fields and fixed JSON keys, zero
buckets, and no identity, contact, location, message, or ID-document fields.
Independent counts in the same snapshot reconciled every metric: Workers 7
(verified 2; pending ID review 0), Clients 5; Jobs 15 (`open` 5, `matched` 1,
`completed` 8, `cancelled` 1, `unset` 0); Bookings 10 (`confirmed` 1,
`completed` 8, `cancelled` 1, `pending` 0, `no_show` 0); payments `cod/paid` 3,
`qrph/paid` 2, `qrph/pending` 2, `unset/pending` 3, with every other fixed cell
zero; Reports 2 (`submitted` 1, `dismissed` 1, other statuses 0), needing
attention 1. The breakdowns sum to their base counts. All retained
application rows were counted without account-activity or fixture filters;
there were no inactive Worker/Client rows in this snapshot. Child-row totals
(Worker skills 11, Job skills 17, messages 9, ID documents 1) did not inflate
base counts. Existing Worker and Client callers and the unauthenticated role
were denied with `42501` in read-only SQL claims checks. Fixture-dependent
denials remain covered by the local 22-case suite; no hosted fixtures were made.

The pre/post hosted business census was identical: users 14 (Workers 7,
Clients 5, active Admins 2), Worker profiles 4, Jobs 15, Bookings 10,
Reports 2, ID documents 1, messages 9, and retained-test-marker user/Job
counts 0/0. No business-row change was observed. The earlier separate local
schema lint did **not** inspect the rolled-back AA-01 function; its own
in-transaction compilation and hosted execution are the applicable function
evidence. The native Admin dashboard and native runtime proof remain pending.
The local-only status above records the earlier AA-01B gate.

Future gap template:

```
GAP-NNN — <description>. Discovered-by: <task>. Status: OPEN | CLOSED (+ qualifier). Resolution path: <dedicated task>.
```
