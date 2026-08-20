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
- `public.guard_users_protected_columns()` — `SECURITY INVOKER`. Under DEFINER,
  `current_user` would report the function owner (`postgres`), silently satisfying
  Tier 1 for every caller and disabling the guard.

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

## Standing RPC caveat (locked)

Any postgres-owned SECURITY DEFINER function that UPDATEs `public.users` executes the
guard with `current_user = postgres`, which satisfies Tier 1 and therefore bypasses the
column guard entirely. Consequently, no client-callable SECURITY DEFINER RPC may modify
protected user columns without restricted EXECUTE, input validation, and security
review. This applies to all future RPCs, including the future atomic booking RPC if it
ever touches protected `public.users` columns.

## Findings log

**F-001** — Pre-Piece-D, the `public.users` INSERT policy (`allow_insert_own_profile`)
checked row ownership only (`auth.uid() = id`), so an authenticated registrant could
self-insert `role = 'administrator'` and mint admin authority via `private.is_admin()`.
Verified locally in a rolled-back transaction. **CLOSED** by the Piece D guard trigger,
verified 13/13 behavioral cases (see docs/tasks/piece-d-users-guard.md). Administrator
provisioning is restricted to trusted backend/database paths such as service_role or
database administration; no normal authenticated registration path may create
administrators.

## Known gaps registry

**GAP-001** — `public.users` UPDATE RLS (`allow_update_own_profile`) is self-row only,
so authenticated administrators cannot UPDATE another user's row via PostgREST.
Discovered-by: Piece D (migration header + Piece D report). Status: **OPEN / DEFERRED
BY DECISION** (D-008) — must be resolved as a dedicated, security-reviewed
admin-management task, never absorbed silently into another piece.

Future gap template:

```
GAP-NNN — <description>. Discovered-by: <task>. Status: OPEN | CLOSED (+ qualifier). Resolution path: <dedicated task>.
```
