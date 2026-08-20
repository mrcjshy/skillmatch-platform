# Task archive — Piece D: users protected-column guard

Historical record. Agents reference this file; do not edit it.

## Objective

Close the privilege-escalation path allowing authenticated users to self-assign
`users.role` / `users.is_active` (F-001).

## What was implemented

- Migration: `supabase/migrations/20260820042554_phase0_piece_d_users_guard.sql`
- Commit: `6451d91` — `security: guard protected users columns` (single-file commit;
  integrated into `main`; pushed to GitHub; no hosted Supabase deployment).
- `public.guard_users_protected_columns()` — plpgsql, SECURITY INVOKER (verified live:
  `prosecdef = f`), `SET search_path = ''`, schema-qualified. Fired by
  `trg_guard_users_protected_columns`, `BEFORE INSERT OR UPDATE ON public.users FOR
  EACH ROW`. Three-tier model per docs/SECURITY.md.

## Key inspection findings

- Pre-existing `users` RLS constrained which ROW a caller may touch, never which
  COLUMN VALUES that row may carry — F-001.
- `allow_update_own_profile` is self-row only — GAP-001 (explicitly out of scope;
  UPDATE policy left unchanged).
- SECURITY INVOKER is load-bearing: a DEFINER guard would collapse every caller into
  Tier 1. Tier 2 is entered via a nested `IF auth.uid() IS NOT NULL`, not a
  short-circuited AND, so `anon` never hits a `private`-schema permission error.

## Verification — 13/13 PASS

Harness: `docker exec ... psql` against the local container; all fixtures and mutations
inside `BEGIN ... ROLLBACK` with per-test `SAVEPOINT`/`ROLLBACK TO`; post-rollback
cleanliness verified (0 rows). Case 12 is split into 12a/12b (11 + 2 = 13 cases).

| #   | Tier             | Scenario                              | Expected                 | Result |
|-----|------------------|---------------------------------------|--------------------------|--------|
| 1   | 1 (service_role) | UPDATE ordinary column (city)         | ALLOW                    | PASS |
| 2   | 1                | UPDATE role to administrator          | ALLOW                    | PASS (UPDATE 1) |
| 3   | 1                | UPDATE is_active to false             | ALLOW                    | PASS (UPDATE 1) |
| 4   | 1                | INSERT administrator account          | ALLOW                    | PASS (is_active forcing did not fire) |
| 5   | 2 (admin)        | UPDATE own ordinary column            | ALLOW                    | PASS (UPDATE 1) |
| 6   | 2                | UPDATE own role                       | ALLOW                    | PASS (role='worker') |
| 7   | 2                | UPDATE own is_active                  | ALLOW                    | PASS (is_active=f) |
| 8   | 2                | UPDATE another user's row             | Blocked by self-only RLS | PASS (UPDATE 0, row unchanged) |
| 9   | 3 (user)         | UPDATE own ordinary column            | ALLOW                    | PASS (city='REG-CITY') |
| 10  | 3                | UPDATE own role                       | REJECT                   | PASS — "Changing your own role is not permitted." (42501) |
| 11  | 3                | UPDATE own is_active                  | REJECT                   | PASS — "Changing your own active status is not permitted." (42501) |
| 12a | 3                | INSERT role='administrator'           | REJECT                   | PASS — "Self-registration as administrator is not permitted." (42501); 0 rows |
| 12b | 3                | INSERT role='worker', is_active=false | is_active forced true    | PASS (worker, is_active=t) |

Observed-value detail for cases 1, 4, and 5 was truncated in the archived source
report; scenarios and PASS verdicts are preserved. Error strings for cases 10, 11, and
12a are the exact `RAISE EXCEPTION` literals in the migration.

Test 8 documents pre-existing GAP-001 behavior (RLS filters the row before the trigger
fires — `UPDATE 0`, no error), not a Piece D failure.

Supplementary (not in the 13): `anon` with no JWT attempting a registration INSERT is
denied by RLS with no `private`-schema permission error leaked — confirming the nested
`IF` design note and that the BEFORE trigger runs ahead of WITH CHECK evaluation.

## Findings / gaps produced

- F-001 — CLOSED (docs/SECURITY.md, Findings log).
- GAP-001 — OPEN / DEFERRED BY DECISION, D-008 (docs/SECURITY.md, Known gaps registry).

## Notes / follow-ups (recorded, NOT performed)

- `src/pages/Register.jsx` inserts role; the guard's rejection surfaces a raw Postgres
  message through `profileError.message`. Map ERRCODE 42501 to a friendly string in a
  later piece.
- Transient `LegacyDbConnectError` on the first `db reset --local` ("Recreating
  database..."); the container self-recovered and the immediate retry succeeded fully.
  May recur on this Windows host; a retry clears it.
- Tier 2 ordering: the guard runs BEFORE UPDATE and `private.is_admin()` sees the
  pre-update row, so an admin deactivating themselves is still authorized at check time.

## Evidence source

APPENDIX A (Piece D final agent report), condensed. Post-report repository state
verified against Git: commit `6451d91d400cdb4f87f0a6cea3a8b211bc352296` contains
exactly the one migration file and is an ancestor of `main`.
