# AGENTS.md — Canonical Agent Instructions (SkillMatch)

## Purpose

SkillMatch is a livelihood matching and skills platform (BSIT capstone) connecting local
workers with clients: a Supabase backend (Postgres, RLS, Auth), this React/Vite web
frontend, and a planned Expo mobile app in a sibling repository (`skillmatch-mobile`).
This file is the canonical instruction set for all coding agents
working in this repository; read it at the start of every task.

## Precedence / source of truth

```
1. Repository reality (migrations, code, local DB behavior) — what IS
2. docs/DECISIONS.md — locked intent; agents may not contradict
3. docs/SECURITY.md — security invariants
4. AGENTS.md — workflow rules
5. The current task spec — narrows scope; may never override 1–4

Any conflict → STOP and report. Never improvise.
```

## Environment facts

- Windows host; the main repository path contains a space (`CAPSTONE 1`) — always quote paths.
- Git Bash (MINGW64) is the primary shell; prefix `winpty` when interactive Docker
  commands fail with TTY errors; CMD is the fallback shell.
- Supabase CLI is invoked as `npx supabase <cmd>`.
- Local stack: `npx supabase start`; apply migrations with `npx supabase db reset --local`.

## Supabase targeting rule

LOCAL ONLY by default. `db push`, `link`, hosted SQL, or any hosted-project operation
requires Josh's explicit written authorization in the task spec. `git push` (GitHub
integration/backup) is distinct from Supabase hosted deployment — but commit,
integration/merge, and Git push still follow the workflow loop's review and
authorization gates below, and must not be performed merely because they are not
hosted Supabase operations.

## Workflow loop

inspect → report actual state → authorization to implement → implement minimal scoped
change → local behavioral tests / evidence → agent report → Josh diff/content review →
explicit authorization before commit → commit → integration verification → authorized
Git push / save point.

Security-sensitive database work is SEQUENTIAL — one agent on that surface at a time.
Genuinely independent work (separate repo/files) may run in parallel worktrees.

## Agent boundaries

Agents may make low-level implementation decisions. Agents may NOT change: research
objectives, approved scope, the 11-table ERD, the matching model, the worker-choice
booking model, AI feature boundaries, the security model, or the native/web role
architecture. If a locked decision appears impossible to implement, STOP and report.

## Documentation update policy

When a task changes security behavior, architecture, or a locked-adjacent decision, the
same commit must update the affected doc (docs/SECURITY.md, docs/DECISIONS.md, or the
STATUS block below). Doc-only edits to docs/DECISIONS.md require Josh's approval:
agents propose, Josh decides.

## STATUS

Snapshot date: 2026-08-21. Updated only at phase boundaries.

- Phase 0 pieces A–G complete.
  - Piece D (`users` guard) verified 13/13; closed F-001.
  - Piece E (`worker_profiles` guard) verified 18/18 plus supplementary checks; Piece D
    regression remained 13/13; closed F-002.
  - Piece F (hosted leaked-password protection) evaluated and closed as plan-gated /
    unavailable on the current Free plan; feature NOT enabled.
  - Piece G final regression verification passed (clean local reset, all four
    migrations, D 13/13, E 18/18 + 6 supplementary, D re-run 13/13).
- Phase 0 closure outcome: READY TO CLOSE WITH DEFERRED HARDENING.
- GAP-001 through GAP-004 remain open/deferred as recorded in docs/SECURITY.md.
- Hosted Supabase has NOT received the Phase 0 A–E migration deployment. Phase 0
  repository implementation and verification are complete through Piece G; hosted
  deployment remains a separate, explicitly authorized future action.
- Next: Phase 0 implementation/verification is complete. Module 1 has not started;
  next application-development work may proceed only after normal task scoping.
  Hosted Phase 0 deployment remains separately gated.
