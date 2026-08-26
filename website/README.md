<div align="center">

<img src="assets/app-icon.png" width="112" alt="All Day I Dream About Sports app icon">

# All Day I Dream About Sports

**Live football scores for Europe's top five leagues — dropped right below your MacBook notch.**

[Website](https://alldayidreamaboutsports.com) &nbsp;·&nbsp;
[Download](https://alldayidreamaboutsports.com) &nbsp;·&nbsp;
[Demo](https://youtu.be/XW4_LArebM8) &nbsp;·&nbsp;
[Privacy](https://alldayidreamaboutsports.com/privacy)

Free · macOS 14+ · Premier League · La Liga · Serie A · Bundesliga · Ligue 1

<img src="assets/og-image.jpg" width="720" alt="Live match alert dropping below the MacBook notch">

</div>

---

## Overview

A menu bar app for people who are supposed to be working while their team plays.

- **Notch drops** — goals, cards, penalties, VAR, subs, kickoff and full-time
  slide in below the notch, then get out of the way.
- **Live capsule** — pin the running score to any corner of the screen.
- **Celebrate together** — tap the ball when your team scores and watch the
  counter climb with fans around the world.
- **Your teams** — follow clubs across the top five leagues.

**Note:** 
This repository has landing page code for [alldayidreamaboutsports.com](https://alldayidreamaboutsports.com).
The macOS app and its backend are closed source.

## Architecture

**Stack**

- **App** — SwiftUI, Sparkle (auto-update) 
- **Backend** — TypeScript + Express on GCP Cloud Run 
- **Polling** — GCP Cloud Scheduler → GCP Cloud Tasks → the service 
- **Data** — Firebase Firestore 
- **Delivery** — Cloudflare R2 + Cloudflare CDN 
- **Auth** — Google OAuth 
- **Control plane** — Firebase Remote Config 
- **CI/CD** — GitHub Actions

**Shape**

```
                       ┌── only runs while matches are live
                       ▼
 Football Data ──▶ Cloud Run ──▶ Cloudflare R2 ──▶ CDN edge
       API           │      ▲                         │
                     ▼      │    sign-in · celebrate  │  poll
                 Firestore  └────── menu bar apps ◀───┘
```

**How it fits together**

- **Everything is polled, nothing is pushed.** Match state sits in Cloudflare R2
  as JSON with a short TTL, and every user reads that same cached object through
  the CDN — so serving 1M users costs the same as serving 1.
- **Read cost is fixed.** Cloudflare's tiered caching absorbs the stampede when
  every client's copy expires at once, so the edge answers and R2 barely sees it.
- **GCP Cloud Scheduler dispatches to GCP Cloud Tasks**, which drive Cloud Run to
  poll the football data API and publish what changed to R2. The cadence lives in
  the queue, so nothing sleeps and CPU is billed per fetch.
- **Polling only runs inside a match window**, which makes write cost proportional
  to the number of matches, not to the time of day or the number of users.
- **Celebrations are the one real per-user cost**, so they're batched: one call per
  goal from the app, aggregated in memory and flushed to sharded Firestore
  counters, then republished as another cached object.
- **Firebase Remote Config is the control plane** — kill switch, forced updates and
  feature flags, applied to running apps in realtime.
- **Sparkle powered updates.** In place app updates with delta patches from an
  EdDSA-signed appcast.
- **GitHub Actions handles release** Backend deploys, app builds and Apple notarization.

## The website

- HTML, CSS and vanilla JS.
- Run it with `python3 -m http.server` and open the folder. That's the whole
  toolchain.

```
index.html · privacy/ · style.css · script.js · assets/
```

## Contributions

Not accepting pull requests. Bug reports and ideas are welcome — open an issue
or email [support@alldayidreamaboutsports.com](mailto:support@alldayidreamaboutsports.com).

## Legal

© Nishant Hada. All rights reserved. Not affiliated with FIFA, UEFA, or any
league or club; badges and marks belong to their owners.
