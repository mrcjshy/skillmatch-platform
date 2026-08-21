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

Future gap template:

```
GAP-NNN — <description>. Discovered-by: <task>. Status: OPEN | CLOSED (+ qualifier). Resolution path: <dedicated task>.
```
