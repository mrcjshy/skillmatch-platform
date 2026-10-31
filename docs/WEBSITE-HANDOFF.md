# SkillMatch website — first visual pass

Implemented locally for owner review. No staging, commit, push, deployment, hosted configuration, database access, or native app changes.

## Preview

Development preview: http://127.0.0.1:5173/

Production-build preview: http://127.0.0.1:4173/

Both servers were started and browser-accessed during this task. Restart if needed from the website workspace:

```sh
npm run dev -- --host 127.0.0.1 --port 5173 --strictPort
```

For the built version:

```sh
npm run build
npm run preview -- --host 127.0.0.1 --port 4173 --strictPort
```

## Visual direction and implementation

Warm ivory, terracotta, and deep green; self-hosted Manrope headings and DM Sans body copy. Paired illustrative phone spaces introduce the two audiences. Open editorial layouts alternate with a green matching section, an interactive role showcase, a four-step journey, support tools, Santa Ana context, FAQs, and a terracotta download section.

The mobile navigation closes on link selection, Escape, outside pointer interaction, and desktop resize. Worker/Client tabs support arrow keys, Home, and End. The gallery has previous/next controls and announces its current screen. FAQ answers use keyboard-operable buttons and explicit expanded states. Anchors use native browser scrolling and honor reduced motion.

GSAP owns one coordinated hero sequence. Framer Motion owns gallery transitions and FAQ icon rotation. Effects clean up when unmounted. Lenis, WebGL, OGL, Swiper, and additional icon libraries were unnecessary for this draft and are not installed. Primary content stays visible without decorative motion.

Vercel Analytics is a lazy integration, disabled in configuration and restricted to production when later enabled. The hook removes URL path/query/hash details beyond the public root. No custom events or personal-data payloads were added. Hosted analytics has not been enabled or verified.

## Files

- `src/pages/Landing.jsx`: full page composition.
- `src/components/website/`: Header, Sections (Hero/Matching/HowItWorks/About/Download/Footer), Experience, SupportTools, FAQ, AssetPreview, SiteAnalytics.
- `src/content/website.js`: narrative content, role explanations, FAQ answers, asset registry, APK configuration, optional footer links, analytics toggle.
- `src/effects/useLandingMotion.js`: isolated GSAP lifecycle.
- `src/index.css`: Tailwind theme tokens, responsive layouts, states, and reduced-motion rules.
- `index.html`, `public/website-icon.svg`: public metadata and replaceable temporary favicon. `public/website-font-licenses.txt` preserves both self-hosted fonts' SIL Open Font License notices.
- `package.json`, `package-lock.json`: scoped additions and `test:website` command.
- `scripts/website-check.mjs`: repeatable Chrome interaction/accessibility/layout checks and screenshots.
- `PRODUCT.md`, `DESIGN.md`, `.impeccable/design.json`, `docs/website-visual-brief.md`: website product context and design handoff; canonical decisions/security docs remain authoritative.
- `.impeccable/review/`: local screenshot and validation evidence.

Existing starter assets remain on disk but are unused. Existing router and landing-only fallback are preserved. Existing unrelated dirty files and agent configuration were not edited.

## Dependencies

Added runtime dependencies: `gsap@3.15.0`, `framer-motion@13.4.6`, `lucide-react@1.49.0`, `@vercel/analytics@2.0.1`, `@fontsource-variable/manrope@5.3.0`, and `@fontsource-variable/dm-sans@5.3.0`.

Added development dependencies: `@playwright/test@1.63.0` and `@axe-core/playwright@4.13.0`. Tests use installed Google Chrome; no browser binary installation was performed. Prettier 3.6.2 was run as a one-off formatter, without adding it to the manifest.

All existing locked package versions were retained, confirmed against the original Git lockfile. Only one Motion package variant is installed; its internal `motion-dom`/`motion-utils` dependencies are transitive.

## Replaceable assets and release details

Set the appropriate `assets` entry's `src` in `src/content/website.js`, preferably to a file under `public/website/`. Null or failed image URLs render labeled fallbacks. Actual screenshots use `object-fit: contain`; do not substitute synthetic personal records or a redesigned mobile interface.

| Asset key | Needed from owner |
| --- | --- |
| BRAND_LOGO | Approved SkillMatch brand artwork; replaces temporary text/linked-shape treatment |
| APP_ICON | Approved Android app icon |
| MOCKUP_WORKER_HOME | Approved Worker home capture |
| MOCKUP_CLIENT_HOME | Approved Client home capture |
| MOCKUP_OPPORTUNITY_DETAILS | Approved opportunity details capture |
| MOCKUP_BOOKING_DETAILS | Approved booking details capture |
| MOCKUP_RESUME_PREVIEW | Approved resume capture |
| MOCKUP_SKILL_GAP | Approved skill-gap capture |
| DOWNLOAD_QR | QR image pointing to the approved Android download; never a payment QR |

Also supply an approved HTTPS APK URL via `download.apkUrl`. The current disabled “Download coming soon” state is intentional. QR display is gated by an available APK URL, and no fake scannable code is generated. No version, file size, store listing, or release date is invented.

Optional `footerLinks.contact`, `.privacy`, and `.terms` accept `{ label, href }` only when destinations/content are approved. None was supplied, so none is displayed. The temporary favicon can be replaced independently in `public/website-icon.svg`. Optional videos are omitted.

## Actual validation

- `npm run lint`: passed on final source.
- `npm run build`: passed; main JS approximately 457.49 kB / 151.36 kB gzip, CSS approximately 39 kB / 12 kB gzip. Fonts are self-hosted.
- `npm run test:website`: 27/27 checks passed against the final production build at port 4173, using `WEBSITE_URL=http://127.0.0.1:4173` (PowerShell: `$env:WEBSITE_URL = 'http://127.0.0.1:4173'`).
- Chrome viewport widths: 320, 390, 768, and 1440 pixels. Checked all sections, anchor destinations, horizontal overflow, broken images, caption separation, tab/gallery behavior, FAQ keyboard toggling, mobile navigation/Escape, and the disabled download state.
- Axe WCAG 2 A/AA and 2.1 AA scans: zero reported violations at all four widths. This is automated evidence, not a complete accessibility certification or screen-reader audit.
- Reduced-motion checks passed at all four widths; normal-motion hero settling was checked separately. Unknown `/worker` routes redirect to the landing page.
- Zero console errors or failed asset requests in the four-viewport run. A page reload made no third-party/backend/analytics runtime requests.
- Website-scoped `git diff --check`: passed. Repository-wide `git diff --check` reports existing blank lines at EOF in `supabase/migrations/20260928235945_ft05_admin_reviewed_no_show_strikes.sql:199` and `supabase/tests/ft05_18_payment_before_completion.sql:187`; these are outside this change and were left alone.
- `npm audit --json`: nonzero exit; 12 findings (9 high, 2 moderate, 1 low) in retained dependencies. No automatic fix or blanket upgrade was applied.
- Impeccable: installed context loader and direction seed executed; craft-floor guidance read; mechanical detector returned `[]`. Independent finish review identified the mobile Client-caption overlap; corrected captures received a **ship** verdict for the listed fix and local visual draft. Design tokens are documented separately.

Early checks found and resolved invalid Fontsource import paths, a lowercase Motion JSX lint binding, an axe browser-context setup problem, an invalid label on the temporary icon, a cramped FAQ-assistance row, and hero-caption overlap. The final results above supersede those failed runs.

No Firefox, Safari, physical mobile device, native app, hosted infrastructure, release-download, or live-analytics test was performed. Approved replacement assets have not yet been supplied or visually verified. Gigwire could not be retrieved by the web tool and timed out in Chrome, so direct visual comparison was unavailable; the written app-focused brief supplied the structural direction.

## Captures

All captures show the final production build with animation settled or reduced motion enabled.

- [Desktop full page](../.impeccable/review/desktop.png)
- [Mobile full page](../.impeccable/review/mobile.png)
- [Desktop first viewport](../.impeccable/review/desktop-hero.png)
- [Mobile first viewport](../.impeccable/review/mobile-hero.png)
- [Narrow 320px](../.impeccable/review/user-320.png)
- [Tablet 768px](../.impeccable/review/user-768.png)
- [Normal-motion settled hero](../.impeccable/review/desktop-motion.png)
- [Machine-readable checks](../.impeccable/review/validation.json)
