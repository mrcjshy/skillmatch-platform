# Location Stop lifecycle hardening — 2026-10-15

This supersedes the map-unmount Stop-retry limitation in the accepted October 15 continuation checkpoint. It does not replace that checkpoint's implementation record or approval holds.

## Completed behavior

- Pending Stop operations now belong to an app-root, process-memory queue, independent of map/navigation lifetime. Entries contain account, booking and exact share identifiers (or the separately requested Stop-all scope), attempt/deadline/status metadata only. No coordinates, stored credentials, persisted sessions or storage writes are added. The queue has no GPS/watch/start capability.
- Explicit Stop and map disposal remove the watcher immediately and enqueue cleanup. Pending/late Start responses after disposal also enqueue their exact share ID. Reopening a map exposes unconfirmed cleanup and never resumes collection automatically.
- At most four requests per operation, with 1s/5s/15s retry delays and a ten-minute total window. Each request has a ten-second timeout and abort signal. The root ticks while running, but dispatch requires foreground and a current owning-account session lifetime. Manual Retry consumes the same bounded attempt budget. Timers do not collect location.
- Sign-out, account change and background pause dispatch. The queue survives these transitions in memory. A new authenticated session for the same account can finish pending cleanup. Each dispatched RPC explicitly pins its Authorization header to that account's captured token; later global-auth changes cannot retarget the request. Tokens are not queue-entry data. Wrong-account callers cannot consume another account's queue entries.
- Only valid success responses clear an entry (`stopped`/`not_current` for exact-session Stop; a nonnegative integer for Stop-all). Network failure, denial, timeout, malformed response and exhausted retries remain visibly unconfirmed. Retry-window expiry is **not** server-Stop confirmation or proof of physical deletion.
- Unconfirmed Stop-all blocks local replacement sharing even after its deadline; the map explains how to explicitly reissue Stop-all. Reissue after expiry receives a new bounded window. An expired exact-session Stop cannot target a subsequent share and does not block a new explicit opt-in. Stop-all retains its intentionally broader all-device scope; its bounded retries may affect a session started on another device during that window.
- A root notice remains visible for the authenticated owning account after leaving the map. Map-level controls reflect pending, retryable, expired and replacement-blocking state.

Memory-only limitation remains deliberate: terminating/restarting the app process loses pending cleanup and its notice. No sharing is restored on restart. The server's existing authorization/last-pin expiry remains the fallback; this change does not claim remote deletion without a confirmed response. Native timeout/abort timing and actual server TTL behavior remain unverified.

## Exact source changes from accepted checkpoint

Relative to `skillmatch-mobile-rc`:

- Added `src/lib/location-stop-queue.ts`, `src/lib/location-stop-transport.ts`, `src/components/location-stop-host.tsx`.
- Updated `src/lib/location-sharing.ts`, `src/hooks/use-location-sharing.ts`, `src/components/booking-location-map.tsx`, `src/app/_layout.tsx`.
- Added `src/lib/location-stop-queue.test.ts`, `src/lib/location-stop-transport.test.ts`, `src/components/location-stop-host.integration.test.ts`.
- Updated existing hook integration and root-composition isolation: `src/hooks/location-hooks.integration.test.ts`, `src/components/worker-onboarding-ui.test.ts`, `src/lib/role-navigation-ui.test.ts`, `src/lib/client-refresh-continuity.test.ts`.

Web changes are this record and appended security/inventory/checkpoint documentation only. No backend SQL, Edge handler, landing source, root configuration or `admin-web/**` implementation changed during this hardening pass.

## Executed verification

| Feature | Scenario | Test layer | Exact artifact | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| Pending cleanup | Unsubscribe/unmount, retry recovery, bounded attempts, expiry, account changes, same-account session replacement, late Start, exact-share safety, Stop-all replacement block | Controllers with mocked RPC/clock | `src/lib/location-stop-queue.test.ts` | 7/7 | PASS |
| Cleanup transport | Pinned auth, exact IDs, denial/malformed results, ten-second abort | Mocked transport | `src/lib/location-stop-transport.test.ts` | 3/3 | PASS |
| Root/map lifecycle | Real React hook + root host; navigation removes watcher; unconfirmed notice survives; wrong-account pause; replacement-session cleanup; no watcher restart | Executed integration, mocked native/Supabase | `src/components/location-stop-host.integration.test.ts` | 1/1 | PASS |
| Mobile regression | Full available suite | Local Vitest | Release `baseline/stop-hardening-vitest-final.json` and `.log` | 2,546/2,546, 133 files, 0 failed/skipped | PASS |
| Static checks | TypeScript; full source ESLint, followed by targeted lint on final delta; diff whitespace | Local source | `tsc --noEmit`, `eslint src --no-fix`, final targeted ESLint, `git diff --check` | Exit 0; no diagnostics | PASS |
| Independent review | Queue, transport, root host, controller/hook/map integration and final Stop-all guard | Read-only source review | `stop_hardening_review` final report | No material findings; review ownership released; reviewer did not run tests | PASS |

Initial regression failures were reproduced before fixes. The first whole-suite hardening report (2,545 tests) is preserved; `stop-hardening-vitest-final.json` adds the final Stop-all regression and is authoritative for current source. The case-level inventory is `baseline/stop-hardening-test-inventory.csv`.

Backend 48/48 mocked Deno tests and four type-checked Edge entrypoints, plus landing build/lint, are accepted carried-forward evidence from the prior checkpoint; they were not rerun because those sources did not change. SQL remains BLOCKED without Docker. Native/device, provider and full E2E behavior remain NOT RUN/HELD.

## Integration, recovery and next consequential actions

Entry inspection matched all 648 hashes from the accepted paired checkpoint; no subordinate writer was active. Admin-web ownership was not released and its files remain excluded from editing, verification and the coordinator's recovery capture. Its inherited 41/41 unit, 11/11 mocked-browser and build report is not independent evidence. Root Admin integration remains BLOCKED.

New paired source checkpoint: `C:/Users/JOSH/Documents/SkillMatch-releases/20261021-ricafort-candidate/recovery-20261015-stop-hardening/`. Separate Mobile/Web SHA256 manifests and copied test evidence identify exact bytes. It supplements, never overwrites, the prior recovery directory. No restore, staging, commits, pushes, reset, deployment, provider or hosted action occurred.

The consequential-action package remains the one in `RICAFORT-CONTINUATION-20261015.md`: explicit Admin implementer release before independent package/build/root integration; owner-provided local Docker or separately authorized machine setup before SQL execution; one explicitly authorized EAS development compatibility build before native claims; separately authorized hosted migrations/functions/settings/schedulers/provider provisioning; authorized accounts and two physical phones before E2E; and separately authorized standalone APK generation/verification. No routine continuation approval is requested.

Rollback APK **5333ce4d remains preserved**. Its installation alone cannot undo backend changes. Pre-change schema/history/grants/functions/policies, Edge/config/scheduler recovery, provider room/token cleanup, authorized backup access and local recovery rehearsal must accompany any later hosted approval. This source checkpoint is not a database backup.
