# Feature → scenario → evidence inventory

Latest evidence: Stop lifecycle hardening passes 2,546/2,546 Mobile tests in 133 files, including seven queue, three transport and one real React root-host integration tests. See `RICAFORT-STOP-HARDENING-20261015.md` for the added Feature → Scenario → Test Layer → Exact Artifact → Evidence → Status rows and `baseline/stop-hardening-test-inventory.csv` for all current cases. The 2,535-test snapshot below remains historical. All device/SQL/provider/Admin ownership gates below remain unchanged.

Checkpoint: 2026-10-15. Mobile artifacts are relative to `skillmatch-mobile-rc`; SQL/Edge artifacts to `skillmatch-web`. Full executed case-level inventory is `C:/Users/JOSH/Documents/SkillMatch-releases/20261021-ricafort-candidate/baseline/continuation-test-inventory.csv`. Evidence `V` below means the final full Vitest report `baseline/continuation-vitest-verified.json` (2,535 tests, 130 files); `D` means the coordinator's 48-test Deno execution recorded in the continuation ledger. PASS is limited to the named test layer.

| Feature | Scenario | Test layer | Exact artifact | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| Location opt-in | Map loaded/focused/foreground; background watcher removal; resume same share; explicit Stop never restarts | Real React hooks, mocked native/RPC | `src/hooks/location-hooks.integration.test.ts` | V, 1 test | PASS |
| Location authorization | Lease expiration; slow responses; denial invalidates every outstanding read; per-session Stop, Stop-all, retry, late start/watcher/publish | Unit lifecycle | `src/lib/location-sharing.test.ts` | V, 28 tests | PASS |
| Location map helpers | Parsing, freshness/approximation, overlap, publish limits | Unit | `src/lib/location-pins.test.ts` | V, 16 tests | PASS |
| Location integration | RPC denial stops current sharing session | API + controllers, mocked boundary | `src/lib/location-map.integration.test.ts` | V, 1 test | PASS |
| Location database | Participant restrictions, read lease, Stop scope, termination/concurrency | Local SQL | `supabase/tests/rf01_location_pins.sql`, `supabase/tests/rf_termination_concurrency.sql` | Docker unavailable; not executed | BLOCKED |
| Calls | Accepted-only token, End/accept race, away/back, terminal identity, missed terminal update | Client + lifecycle unit/integration | `src/lib/video-call.test.ts` | V, 9 tests | PASS |
| Native call media | Stop acquired/unpublished tracks; late acquisition after leave | Mocked SDK boundary | `src/lib/native-video-call.test.ts` | V, 2 tests; no native compatibility proof | PASS |
| Call push | Cold start, reauthorization, terminal fallback, account/route cleanup, identifier-only hints | Executed component with mocked routing/service | `src/components/video-push.integration.test.ts` | V, 4 tests | PASS |
| Call backend | Auth/validation, start without token, invite once, provisioning ambiguity, accepted token, cleanup | Mocked Edge handler/provider | `supabase/functions/booking-call/handler.test.ts` | D, 13 tests | PASS |
| Call provider/reconciliation | Scoped tokens, signed webhook, cleanup confirmation, retry | Mocked Edge/provider | `_shared/call-ops.test.ts`, `_shared/livekit.test.ts`, `booking-call-reconcile/handler.test.ts`, `livekit-webhook/handler.test.ts` under `supabase/functions/` | D, 27 tests | PASS |
| Call database | Active identity, participant eligibility, acceptance, termination and concurrency | Local SQL | `supabase/tests/rf02_booking_calls.sql`, `supabase/tests/rf_termination_concurrency.sql` | Docker unavailable | BLOCKED |
| Worker verification | Direct verify privilege revoked; existing Admin path | Local SQL | `supabase/tests/rf03_verify_worker_revoke.sql`, `supabase/tests/v3_db_03_worker_id_review.sql` | Docker unavailable | BLOCKED |
| Responsive U1/U2 | Pinned search, expandable catalog, keyboard-safe selection/forms | Component/source harness | `src/components/client-post-job-screen.test.ts`, `src/components/skill-catalog-picker.test.ts`, `src/components/worker-profile-ui.test.ts` | V; Client posting 31 tests | PASS |
| Responsive U3 | Pending picker/denied permission; preserved ID type/photo across foreground refresh | Real React providers/form, mocked picker/RPC | `src/components/worker-identity-foreground-refresh.test.ts` | V, 13 tests | PASS |
| Responsive U4 | Next focus order; Done exposes unchecked consent without signup | Component harness | `src/components/registration-refinement.test.ts` | V, 10 tests | PASS |
| Responsive U5 | Interactive chip/consent targets; portfolio controls | Source/component checks | `src/components/worker-portfolio.test.ts`, `src/components/wave1-shared-ui.test.ts`; portfolio source minimum48 | V plus source inspection; not physical size measurement | PASS |
| Admin web | Build; existing Admin login, Worker verification/reports/directories; RPC/42501; signed IDs; local/global logout | Implementer-reported unit/mock-browser | Inherited Admin-web report | 41/41 unit, 11/11 mocked browser, successful build; not independently rerun | PASS |
| Admin web integration | Ownership release, independent build/security review, root ESLint | Independent integrated checks | Continuation ledger Admin ownership gate | Explicit release absent | BLOCKED |
| Report email CORS | Only listed Admin origins; server-derived recipient/outcome | Mocked Edge | `supabase/functions/report-outcome-email/index.test.ts` | D, 8 tests | PASS |
| Public site | Separate landing bundle and lint | Local production build/static inspection | Release `baseline/landing-build-20261015` | Successful build; limited isolation marker scan | PASS |
| Onboarding/auth | Role choice, validation, consent, recovery, gates | Unit/component | `src/components/auth-screens.test.ts`, `src/components/registration-refinement.test.ts`, `src/lib/user-consent.test.ts`, `src/lib/worker-onboarding.test.ts` | V | PASS |
| Profiles/skills/portfolio | Worker/Client editing, images, persistence/refresh | Unit/component | `src/lib/worker-profile.test.ts`, `src/providers/worker-profile-provider.test.ts`, `src/lib/client-profile.test.ts`, `src/lib/portfolio.test.ts`, `src/lib/portfolio-images.test.ts` | V | PASS |
| Posting/matching | Location-first flow, canonical address, deterministic eligibility, skill choice, stale submission prevention | Unit/component | `src/components/client-post-job-screen.test.ts`, `src/lib/ai-deterministic-campaign.test.ts`, `src/lib/client-post-job-submission.test.ts` | V | PASS |
| Booking lifecycle | Acceptance, confirmation, refresh/focus, cancellation, completion/payment gates | Unit/component | `src/lib/bookings.test.ts`, `src/lib/booking-lifecycle.test.ts`, `src/lib/booking-cancellation-details.test.ts`, `src/components/booking-details.test.ts` | V | PASS |
| Notifications/chat | Push routing, inbox/bell, message scrolling/refresh | Unit/component | `src/lib/push-notifications.test.ts`, `src/components/notification-list.test.ts`, `src/components/notification-bell.test.ts`, `src/lib/chat-scroll.test.ts` | V | PASS |
| Payments | Amount/method and status logic | Mock/unit | `src/lib/payments.test.ts`, `src/lib/job-payment.test.ts` | V; no payment provider transaction | PASS |
| Mobile Admin | Analytics, directories, user details, routing | Unit/component | `src/lib/admin-analytics.test.ts`, `src/lib/admin-directories.test.ts`, `src/lib/admin-user-detail.test.ts`, `src/components/wave4-admin-ui.test.ts` | V; historical hosted evidence remains separate | PASS |
| FAQ / skill gap | Deterministic helpers and failure cases | Unit | `src/lib/faq.test.ts`, `src/lib/ai-deterministic-campaign.test.ts` | V; actual provider behavior not established | PASS |
| ID authenticity | Adviser-dependent checker | No implementation | Continuation ledger scope hold | Separate decisions pending | NOT RUN |

## Full end-to-end campaign still required

Each row below requires actual observed evidence, timestamp, app/backend versions, role/device identities represented by non-sensitive labels, exact artifact/log reference, and PASS/FAIL. Existing mocks and historical results cannot close these rows. Physical accounts/phones and consequential operations remain separately authorized.

| Feature | Scenario | Test layer | Exact artifact | Evidence | Status |
| --- | --- | --- | --- | --- | --- |
| Onboarding/Gmail OTP | Worker/Client registration, Gmail delivery, invalid/expired OTP, resend, recovery, consent and Worker ID gating | Two-phone + hosted auth | Campaign evidence not yet created | Account/device permission pending | NOT RUN |
| Roles/session | Worker/Client/Admin navigation, deep links, inactive account, logout/account switch, local/global logout | Device/hosted | Campaign evidence not yet created | No current run | NOT RUN |
| Profiles/skills/portfolio | Edit/save/reload, search/expand/remove, image cancellation/error, device return | Physical phone | Campaign evidence not yet created | No current run | NOT RUN |
| Posting/matching | Client posts → deterministic eligible Worker sees/accepts → confirmed booking; unauthorized/ineligible denial | Two-phone/hosted DB | Campaign evidence not yet created | Hosted changes held | NOT RUN |
| Booking/notifications/chat | Lists/details, push cold/warm/foreground, ordering/read state, reconnect, two-person chat | Two-phone | Campaign evidence not yet created | No current run | NOT RUN |
| Cancellation/completion | Both roles, reason display, races, terminal route denial, notifications | Two-phone/hosted | Campaign evidence not yet created | No current run | NOT RUN |
| Payments TEST | Valid/failed/cancelled TEST payment, webhook/retry, completion gate, no real-money spend | Provider TEST + devices | Campaign evidence not yet created | Provider actions held | NOT RUN |
| Admin mobile/web | Login/role denial, analytics, directories/details, verification/report actions, signed ID expiry, 42501, local/global logout | Independent browser/device/hosted | Campaign evidence not yet created | Admin ownership and hosted actions held | BLOCKED |
| FAQ/skill gap | Empty/success/error states, deterministic boundary, declared AI behavior, no authority changes | Device + authorized provider if needed | Campaign evidence not yet created | No current run | NOT RUN |
| Live pins | Explicit opt-in, You/counterpart/destination, accuracy/overlap, denied permissions, foreground/focus, stale/lease, session Stop vs Stop-all, account/booking termination, offline/late responses | Two-phone + executable SQL | Campaign evidence not yet created | SQL/native/hosted gates | BLOCKED |
| Video | Start/invite/accept/reject/missed, duplicate start, no preaccept token, permissions, background media stop, explicit rejoin, End/navigation, remote end, disconnect, cleanup retry/confirmed provider absence | Two-phone + real LiveKit + SQL | Campaign evidence not yet created | Build/provider/SQL/hosted approval pending | BLOCKED |
| Responsive U1–U5 | Small screen, keyboard open, large font scale, skill expansion/search anchoring, identity busy/error, Next/consent, measured48dp interactive chips | Physical phone | Campaign evidence not yet created | Physical reproduction permission pending | NOT RUN |
| Standalone APK | Install/launch, old→new upgrade, offline boot, native permissions/LiveKit, hash/package verification | Authorized release APK/two-phone | Rollback APK 5333ce4d preserved; no new build | Build held | BLOCKED |
| Recovery | Source restore + paired backend/function/config/provider recovery rehearsal | Local DB then explicitly authorized recovery exercise | Continuation ledger recovery package | No restore executed | BLOCKED |

No end-to-end demonstration or native-compatibility completion is claimed by this inventory.
