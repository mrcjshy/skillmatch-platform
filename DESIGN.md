---
name: SkillMatch public website
description: Warm editorial presentation for a local livelihood app.
colors:
  page: "#faf8f3"
  ink: "#233d35"
  ink-muted: "#59665e"
  accent: "#af452e"
  accent-hover: "#943720"
  peach: "#f1d7c6"
  sage: "#e1e8db"
  line: "#dddcd2"
  button-text: "#fffaf3"
  light: "#fff8ed"
  light-hover: "#ffe5d5"
  dark-focus: "#fff4d9"
  client-surface: "#f1dece"
  steps-surface: "#f0eee6"
  tools-surface: "#e5e9dd"
typography:
  display:
    fontFamily: "Manrope Variable, sans-serif"
    fontSize: "clamp(48px, 4.7vw, 68px)"
    fontWeight: 650
    lineHeight: 1.09
    letterSpacing: "-0.04em"
  headline:
    fontFamily: "Manrope Variable, sans-serif"
    fontSize: "clamp(32px, 3.65vw, 52px)"
    fontWeight: 650
    lineHeight: 1.16
    letterSpacing: "-0.035em"
  title:
    fontFamily: "Manrope Variable, sans-serif"
    fontSize: "clamp(28px, 2.8vw, 38px)"
    fontWeight: 650
    lineHeight: 1.25
    letterSpacing: "-0.025em"
  body:
    fontFamily: "DM Sans Variable, sans-serif"
    fontSize: "16px"
    lineHeight: 1.65
  lead:
    fontFamily: "DM Sans Variable, sans-serif"
    fontSize: "17px"
    lineHeight: 1.75
  label:
    fontFamily: "DM Sans Variable, sans-serif"
    fontSize: "14px"
    fontWeight: 600
rounded:
  tab: "5px"
  control: "8px"
  app-icon: "14px"
  surface: "16px"
  screen: "24px"
  phone: "31px"
  circle: "50%"
spacing:
  section-space: "clamp(64px, 7.5vw, 112px)"
  card-padding: "32px"
  content-gap: "24px"
components:
  button-primary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.button-text}"
    rounded: "{rounded.control}"
    padding: "14px 24px"
  button-primary-hover:
    backgroundColor: "{colors.accent-hover}"
  button-small:
    typography: "{typography.label}"
    padding: "11px 18px"
  button-light:
    backgroundColor: "{colors.light}"
    textColor: "{colors.accent}"
    rounded: "{rounded.control}"
    padding: "14px 24px"
  button-light-hover:
    backgroundColor: "{colors.light-hover}"
  text-link:
    textColor: "{colors.ink}"
  role-tab-selected:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.page}"
    rounded: "{rounded.tab}"
    padding: "10px 28px"
    typography: "{typography.label}"
  tool-card:
    backgroundColor: "{colors.client-surface}"
    rounded: "{rounded.surface}"
    padding: "{spacing.card-padding}"
  navigation:
    backgroundColor: "{colors.page}"
    textColor: "{colors.ink}"
  gallery-control:
    rounded: "{rounded.circle}"
    width: "44px"
    height: "44px"
---

# Design System: SkillMatch public website

## Overview

**Creative North Star: "Useful skills belong close to home."**

The implemented website pairs warm ivory, terracotta, and ink green with generous editorial spacing. Large Manrope headings establish the hierarchy; DM Sans carries the explanations and controls. Flat color fields organize the page, while paired phone illustrations introduce the Worker and Client perspectives.

This is a source-based record of the first public website visual pass, not a design specification for the native app. The direction comes from `docs/website-visual-brief.md`; implemented values come from `src/index.css`, `src/components/website/`, and `src/effects/useLandingMotion.js`. Copy and replaceable assets live in `src/content/website.js`. `PRODUCT.md` provides the product and accessibility constraints. Source remains authoritative when this document needs refreshing.

**Key Characteristics:**
- Warm neutral canvas with terracotta actions and green text.
- Broad compositions, thin dividing rules, and flat tonal surfaces.
- Rounded phone previews with explicit placeholder disclosures.
- A role switch that updates both explanation and preview.
- Native scrolling with restrained, reduced-motion-aware animation.

## Colors

The frontmatter records the shared palette and recurring surface colors; incidental illustration colors remain local to the source.

### Primary

- **Terracotta (`accent`)** identifies primary actions, headline emphasis, small icons, focus outlines, and the download section. `accent-hover` darkens filled actions on hover.
- **Button cream (`button-text`)** supplies contrast on primary buttons; **light cream (`light`)** is the download section's text and reverse-button surface, with `light-hover` also used for supporting copy there.

### Secondary

- **Ink green (`ink`)** is the main text color, matching-section field, and selected role-tab fill. The matching section reverses text to the page color.
- **Peach (`peach`)** grounds the hero's circular composition and text selection. **Sage (`sage`)** is the Worker preview stage and eligible-match result surface.
- **Client peach (`client-surface`)** connects the Client preview stage with the resume card. `tools-surface` supplies the skill-gap card's pale green field.

### Neutral

- **Warm ivory (`page`)** covers the body and sticky header.
- **Muted green (`ink-muted`)** supports descriptions, captions, and secondary information.
- **Warm rule (`line`)** divides navigation, FAQs, footer, and section boundaries.
- **Steps ivory (`steps-surface`)** distinguishes the four-step explanation.
- **Pale focus (`dark-focus`)** replaces the standard outline on matching and download backgrounds.

No tonal ramp is defined in the implementation. The sidecar does not invent one.

## Typography

**Display font:** Manrope Variable, sans-serif. **Body font:** DM Sans Variable, sans-serif. Both are self-hosted through Fontsource package imports in the main stylesheet. Lucide provides the line icons; there is no icon font or separate monospace family.

The frontmatter captures the desktop role values. Display is the hero heading; headline is the standard section heading; title is the role-explanation heading. These are contextual sizes rather than a generated modular scale. Headings use balanced wrapping and slightly negative tracking. Intended multiline copy preserves line breaks.

Body paragraphs are capped at 70ch. The hero lead is narrower (455px). Detail copy commonly uses 14px; navigation and role tabs use 14px; preview captions use 12px. Placeholder-only miniature labels use smaller local sizes and must not become a general body-text scale. The temporary wordmark uses Manrope at 28px, weight 800, with tight tracking.

The hero heading changes to 45px at widths up to 899px, then `clamp(42px, 10.6vw, 62px)` up to 639px, and 39px up to 359px. The small-screen role heading is 31px. The download heading has its own desktop clamp (`clamp(36px, 4vw, 55px)`) and becomes 36px up to 639px.

## Layout

The desktop container is `min(1200px, calc(100% - 96px))`; widths up to 1150px use 32px side margins, up to 639px use 20px, and up to 359px use 16px. The body minimum width is 320px. Section padding uses the fluid `section-space` token. The layout uses contextual gaps rather than a uniform spacing scale.

The hero has a two-column 1.03:1 grid, a 690px minimum height, and a right-hand circular phone composition. Matching uses 1.05:1 columns; experience and about use equal columns. The journey has four columns; support tools use 1.1:1 columns; FAQ uses 0.85:1.25; download uses 1.4:1. Major desktop gaps range from 64px to 90px. The full-width color fields retain the shared inner container.

| Media boundary | Implemented change |
| --- | --- |
| Up to 1150px | Narrower gutters, smaller phone previews, and 45px gaps in matching, experience, and about. |
| Up to 899px | Mobile menu replaces desktop links; header is 76px tall; matching and tools become single-column; journey becomes two columns; hero, experience, about, FAQ, and download still retain two columns. |
| From 900px | Mobile navigation is hidden and an open menu closes when the viewport enters this range. |
| Up to 639px | Header is 72px tall; hero, experience, about, FAQ, and download stack; skills strip becomes two columns; tool cards stack their text and preview. Journey remains two columns. |
| Up to 359px | Header CTA hides while the menu retains the download link; hero heading and previews shrink to fit the 320px minimum. |

The desktop header is 88px tall and sticky. Anchor navigation uses native smooth scrolling with a 98px top offset. Reduced motion changes scrolling to immediate. No custom scroll engine, scroll pinning, Lenis, or WebGL is implemented.

## Elevation & Depth

Large surfaces are flat and separated by color or thin borders. Phone shells supply the recurring shadow (`0 20px 35px -16px #28372f4a`). Their slight opposing rotations and the hero's peach disc and fine orbit add depth without elevating ordinary cards. The header is opaque and separated by a rule; it has no blur or shadow. Primary-button feedback changes background color rather than position.

## Shapes

Controls use the `control` radius; tabs sit inside a bordered rounded group and use the smaller `tab` radius. Content stages, tool cards, the community panel, and QR placeholder use the `surface` radius. Phones use the `phone` shell radius and `screen` inner radius, with smaller local variants for compact cards and responsive hero previews. Phone shells have a 0.5 aspect ratio. Circular gallery arrows, hero fields, and decorative orbits repeat the circle geometry.

The temporary brand symbol is two overlapping outlined rounded shapes, rotated 32 degrees, alongside a lowercase wordmark. The app-icon substitute places that symbol in a cream rounded square. Both are replaceable through the content asset map.

## Components

### Buttons and text links

Primary buttons are terracotta with cream text, 54px minimum height, a 22px icon gap, and the frontmatter padding. The small header variant has a 44px minimum height and an 18px icon gap. Background transitions last 0.2 seconds. The light variant reverses the colors for the download section; its disabled state has a stable cream fill and muted terracotta text.

Text links use weight 600, a 44px minimum height, a 12px icon gap, and an underline on hover. All keyboard-focusable controls inherit a 3px outline offset by 5px; the two dark/colored sections use the pale focus color. Focus is not communicated through motion alone.

### Navigation

The sticky header pairs the temporary wordmark with four section anchors and a download CTA. Desktop links change to terracotta on hover. The compact menu uses a labeled button with `aria-expanded` and `aria-controls`. It closes after selecting a link, clicking outside, pressing Escape, or entering the desktop width. Escape returns focus to the toggle. A skip link becomes visible on keyboard focus.

### Role switch and preview gallery

The two-role control is a tablist with roving focus. Left/Right arrows switch roles; Home selects Worker; End selects Client. Selecting a role resets its three-preview gallery to the first slot and updates the panel's accessible label, stage color, and explanatory copy. The active tab uses ink green and ivory.

Previous/next gallery buttons are circular 44px controls, bordered and transparent at rest, with an ivory hover fill. They wrap through the available previews. A polite live counter announces the slide number and preview label. Framer Motion brings the new preview from 12px right over 0.3 seconds with `easeOut`; reduced motion suppresses the initial offset. There is no autoplay.

### Phone previews and cards

Six replaceable screenshot slots share a phone shell, role-specific pale fill, Lucide illustration, headline, and explicit screenshot-coming-soon disclosure. These illustrate asset positions, not native interfaces. The source asset keys cover Worker home, Client home, opportunity details, booking details, resume preview, and skill gap. Missing or failed images render the fallback; supplied screenshots use `object-fit: contain`.

The experience stage centers one preview and its controls. The resume and skill-gap cards use flat peach/green fills, 32px desktop padding, and a text-plus-phone composition. The four journey steps use numbers and thin rules rather than independent raised cards. Matching-factor rows are explanatory labels, not clickable filters. There are no input or form-field primitives in this website.

### FAQ

Questions form a ruled accordion. The first answer starts open; selecting a different question opens that answer, and selecting the current question closes it. Answer regions use `hidden` and linked accessible labels. The plus icon rotates 45 degrees when open over 0.2 seconds, or immediately for reduced motion. Answer height is not animated.

### Hero motion

One GSAP entrance timeline owns the hero composition only. Its defaults are 1.05 seconds and `expo.out`: the disc begins at scale 0.92, Worker phone at y 22/rotation -3, Client phone at y 32/rotation 3, and connection note at y 12. Start offsets are 0, 0.08, 0.2, and 0.32 seconds. Text stays visible. The entire sequence runs only with no reduced-motion preference and is reverted on cleanup.

### Download and replacement states

The current APK URL is null, so the download control is disabled and labeled “Download coming soon.” The QR slot is a labeled dashed-inset placeholder, not a scannable code. An approved HTTPS APK URL activates the download link; the QR image remains separately replaceable. No supplied contact, privacy, or terms destination is fabricated. Analytics is prepared but disabled in the content configuration. These are current availability states, not visual promises of a release.

## Do's and Don'ts

### Do:
- **Do** use the shared warm palette, self-hosted type pairing, and existing section-container rhythm.
- **Do** preserve visible focus, tab keyboard navigation, meaningful labels, and reduced-motion behavior.
- **Do** keep missing screenshots, brand artwork, and QR artwork replaceable and explicitly identified.
- **Do** update this record and its sidecar when the implemented visual system changes.

### Don't:
- **Don't** present the phone illustrations as actual app screenshots or an approved mobile redesign.
- **Don't** imply a working download, store listing, or scannable QR while those assets are unavailable.
- **Don't** place essential explanations solely inside animation or miniature placeholder labels.
- **Don't** introduce an invented tonal scale, form system, or interaction state into this source-based record.
