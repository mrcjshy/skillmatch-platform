# SkillMatch public website
<!-- impeccable:product-schema 1 -->

## Platform
web

## Users
Local Workers looking for livelihood opportunities and Clients who need their skills, in the Santa Ana, Pateros project context.

## Product Purpose
Introduce SkillMatch, explain its Android app experience, and direct visitors to an approved download when supplied. This document covers the public website only; docs/DECISIONS.md and docs/SECURITY.md remain authoritative for product behavior.

## Capabilities and Constraints
The website is informational. All Worker, Client, and Administrator operations belong to the existing native app. No authentication, database access, live marketplace, payments, or role operations on the web. The Try a match demo runs the public matching rules on labeled sample data in the visitor's browser and connects to nothing.
Matching is rule-based. Eligible Workers choose whether to accept; the first valid acceptance creates the booking. Support-tool descriptions follow D-004: profile-based resume, rule-based skill gaps, and fixed-knowledge FAQ assistance.

## Brand Commitments
Preserve the SkillMatch name and the app's identity: the two-piece S logo, copied unchanged from the current Android app into public/website/, and the app's cobalt, canvas and ink colors.

## Evidence on Hand
The app's logo and favicon, real app screens and one recorded app animation from test builds, the locked matching rules in docs/DECISIONS.md, and CC0 street photographs of Santa Ana, Pateros. The app screens still need the owner's approval before any public deployment. No APK URL, QR image, contact destination, or public policy content has been supplied. Do not invent them.

## Accessibility & Inclusion
Responsive mobile through desktop, keyboard controls, visible focus, reduced motion, and readable contrast. No essential content inside decorative effects.
