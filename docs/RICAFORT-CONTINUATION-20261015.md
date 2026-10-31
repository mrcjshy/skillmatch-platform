# Ricafort continuation checkpoint — 2026-10-15

Follow-up: `RICAFORT-STOP-HARDENING-20261015.md` records the subsequently completed app-root pending Stop fix, final 2,546-test evidence and supplemental recovery checkpoint. The earlier unmount limitation below is historical; process termination still clears memory-only cleanup.

This records implementation from the inherited working trees, not a replacement plan. Source is uncommitted. No hosted changes, provider calls, native builds, staging, commits, pushes, merges, or destructive recovery occurred.

## Ownership and preserved entry

Coordinator ownership: the owner explicitly confirmed the former coordinator's `COORDINATOR RELEASED — NO FURTHER WRITES`, then authorized Mobile RC/backend continuation. Mobile branch remains `ft03/ride-hailing-location-picker`, HEAD `bc424a7251ed5837aa904ebe9549970264c73874`; Web remains `main`, HEAD `c0a2f5ef07a2082c8d8beb2e1e80b288a38c63a4`.

Admin-web ownership: **NOT RELEASED to this coordinator**. `admin-web/**` was not modified or independently verified. The inherited report remains 41/41 unit tests, 11/11 mocked-browser tests, successful build; these are implementer-reported results, not this checkpoint's independent evidence. Root ESLint integration and full Admin-web integration remain BLOCKED pending explicit release and report review.

Preserved checkpoints: `C:/Users/JOSH/Documents/skillmatch-web-backup/20261014-231056-pre-ricafort` and `C:/Users/JOSH/Documents/skillmatch-rc-backup/20261014-154023-picker-fix-validated`. The entry's eight expected Mobile changes were preserved. Expected-change manifests and baseline hashes remain under `C:/Users/JOSH/Documents/SkillMatch-releases/20261021-ricafort-candidate/`.

## Completed source continuation

All Mobile paths below are relative to `skillmatch-mobile-rc`.

- Location: new `src/hooks/use-location-sharing.ts`, `src/hooks/use-booking-pins.ts`, and `src/components/booking-location-map.tsx`; Booking Details opt-in integration. Actual loaded map, navigation focus and AppState gate collection. Map displays own/counterpart/destination pins, freshness, overlapping marker selection, separate Stop and Stop-all, permission explanations and retry state. Existing `src/lib/location-sharing.ts` now rejects obsolete watchers, clears background/expired/denied reads, conservatively measures leases from request time, invalidates all concurrent reads on denial, and retains failed Stop operations while mounted. Existing pin helpers retained; style-only lint corrections applied.
- Video: new `src/lib/video-call.ts`, `src/lib/native-video-call.ts`, `src/components/booking-video-call.tsx`, `src/components/incoming-call-host.tsx`, and Worker/Client `video.tsx` routes. Booking Details entry, root incoming host, identifier-only push capture and reauthorized routing integrated in `_layout.tsx`, `index.tsx`, `push-notifications.ts`, and `push-notification-inbox-intent.tsx`. Native SDK loads lazily; media tracks are owned before publication and stopped on background/navigation. Join is explicit after return. Terminal identities cannot resurrect; authoritative replacement retires old media. End retries adapt to a simultaneous acceptance. Successful connection clears server away state, with compensation for background races.
- Backend: `supabase/functions/booking-call/handler.ts` no longer returns a caller token on ringing/start. Tokens remain in authorized accepted accept/rejoin paths. Matching handler regression updated. Inherited migrations, RF03 revocation and provider/reconciler/webhook implementation preserved.
- Responsive U1–U5: Worker profile and Client skill modal search anchored outside scrolling results; Worker selected chips moved after catalog; keyboard avoidance and drag dismissal; optional catalog `hideSearch`; identity picker synchronous duplicate guard, pending/error UI and late-result mount guard; registration Next focus order and Done-to-consent without automatic acceptance/submission; portfolio interactive scale chips minimum 48dp. Existing shared chip/consent targets and font scaling preserved.
- Tests: new real-hook location integration, location API/controller integration, video client/lifecycle, native media-boundary, and push component integration. Existing location, registration, Client posting and identity foreground tests extended. Booking Details and root composition harnesses updated to isolate unrelated new native hosts.

## Executed local evidence

| Check | Result | Artifact / scope |
| --- | --- | --- |
| Full Mobile Vitest | PASS — 2,535/2,535, 130 files, 0 failed, 0 skipped | Release `baseline/continuation-vitest-verified.json` and `.log`; actual code with mocked native/network boundaries |
| Mobile TypeScript | PASS | `./node_modules/.bin/tsc.cmd --noEmit` |
| Mobile ESLint | PASS — no errors or warnings | `./node_modules/.bin/eslint.cmd src --no-fix` |
| Edge Deno | PASS — 48/48 | `npx --offline --no-install deno test --allow-env` on `_shared`, `booking-call`, `booking-call-reconcile`, `livekit-webhook`, `report-outcome-email`; mocked providers |
| Public landing build | PASS | Vite build to release `baseline/landing-build-20261015`, without cleaning existing outputs |
| Landing source lint | PASS | Web `eslint src --no-fix`; excludes owned Admin application |
| Landing bundle isolation markers | PASS, limited static evidence | Generated JS has no `supabase.co`, `supabase-js`, `admin-web/`, `booking-call`, or `createClient` markers; not a formal whole-program proof |
| Mobile diff whitespace | PASS | `git diff --check` |
| Web diff whitespace | FAIL — inherited | Existing blank EOF lines: `supabase/migrations/20260928235945_ft05_admin_reviewed_no_show_strikes.sql:199`, `supabase/tests/ft05_18_payment_before_completion.sql:187`; unrelated files preserved |
| Drift / Git | PASS within checked source scope | Entry hashes plus explicit expected changes; heads unchanged; indexes empty. Admin-web excluded from coordinator ownership assertion |

Earlier failed continuation runs remain in release `baseline/continuation-vitest.json` and `continuation-vitest-final.json`; the **verified** artifact supersedes them. Historical baseline 2,471/2,471 is not represented as current verification. Regression failures were reproduced before fixes; the final full run contains their passing tests.

## Independent review

Read-only reviewer `ricafort_review` found five call defects and two additional lifecycle races. All seven were fixed: cancellation/acceptance retry, missing back acknowledgement, unpublished track ownership, cold-start route race, fresh identity after terminal, outstanding pin read after denial, and missed terminal identity replacement. Final source spot-check reported no further material findings and explicitly released ownership. Reviewer did not rerun tests. This is a focused source review, **not full independent integrated approval**, which still needs Admin-web, executable SQL and native/provider evidence.

Remaining limitation: location Stop retries are in-memory and disappear on unmount; failed remote Stop can leave the last pin visible until the disclosed expiry. Collection stops locally immediately. Native capture-stop timing, SDK compatibility, map rendering/keyboard behavior, provider cleanup and real two-device races are unverified. Failed call/provider cleanup is not described as confirmed success. ID authenticity remains NOT STARTED; MFA remains an unresolved owner decision.

## Feature evidence inventory and campaign

`RICAFORT-FEATURE-INVENTORY-20261015.md` covers the cross-feature campaign. The release `baseline/continuation-test-inventory.csv` enumerates every executed Mobile test as Feature → Scenario → Test Layer → Exact Artifact → Evidence → Status. Mock/source tests do not establish end-to-end success.

## Recovery and held consequential-action package

Integrated source checkpoint: `C:/Users/JOSH/Documents/SkillMatch-releases/20261021-ricafort-candidate/recovery-20261015-continuation/`, with paired `mobile-rc/`, `web/`, SHA256 manifests and verification evidence. Admin-web is excluded because ownership is unreleased; its inherited backup/report must be paired after release. This is a source recovery checkpoint, not a database snapshot or verified APK. No restore was performed.

Rollback APK **5333ce4d is preserved**. Installing it alone cannot reverse backend changes. Before any hosted migration approval, prepare and review a paired recovery record: pre-change schema/migration history and relevant grants/functions/policies, authorized backup/restore access, old Edge Function/config versions, scheduler disable/restore procedure, LiveKit room/token cleanup verification, and data retention/recovery treatment for the new private tables. Rehearse forward and recovery SQL locally when Docker is available. Never delete migration history or drop tables as an improvised rollback. A database restore or provider purge needs its own authorization.

The following remain held; this document is a concrete approval package, not permission to execute:

1. **Early compatibility build:** one EAS `development` build of the exact source/package checkpoint, Expo 57 / RN 0.86 / LiveKit RN 3.0.0. No SDK upgrade. Record build ID/logs and inspect permissions/capture shutdown before any compatibility claim. EAS quota use requires explicit approval; no `expo run:android` workaround.
2. **Local SQL:** Docker installation/machine changes only if separately authorized, or an owner-provided existing local engine. Execute RF01/RF02/RF03 and two-session termination/concurrency tests plus regressions and paired rollback rehearsal. Currently BLOCKED.
3. **Hosted backend:** explicit approval for exact RF migrations, function releases, settings/Vault/secrets, scheduler and Admin origin configuration, only after SQL/security review and paired recovery approval. No service-role browser credential. Review revocation effects and existing caller compatibility.
4. **Provider:** explicit LiveKit account/project/spend, secrets/webhook and real cleanup test authorization. Provider responses must independently confirm cleanup; mocks do not suffice. No ID/selfie transfer and no ID-authenticity implementation in this package.
5. **Admin-web:** obtain explicit implementer release, collect exact report/checkpoint, then independently check reproducible package build, protected roles/42501, local/global logout, signed ID access, existing RPCs, and landing isolation; finish root ESLint integration. Deployment is separate.
6. **Device/E2E and final APK:** explicit account/physical-phone permission; two Worker/Client devices; full inventory campaign including payments in TEST mode. Then separately authorize standalone APK build/install, verify checksum/package/native permissions and full launch flow, preserve APK 5333ce4d plus paired backend recovery. Target demonstration remains October 21; no readiness claim until these gates pass.
