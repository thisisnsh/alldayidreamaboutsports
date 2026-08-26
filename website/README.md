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

## What it is

A menu bar app for people who are supposed to be working while their team plays.

- **Notch drops** — goals, cards, penalties, VAR, subs, kickoff and full-time
  slide in below the notch, then get out of the way.
- **Live capsule** — pin the running score to any corner of the screen.
- **Celebrate together** — tap the ball when your team scores and watch the
  counter climb with fans around the world.
- **Your teams** — follow clubs across the top five leagues.

## What's in this repository

- The landing page and privacy policy at
  [alldayidreamaboutsports.com](https://alldayidreamaboutsports.com) — static,
  no build step, served by GitHub Pages.
- **The macOS app and its backend are closed source, in a private repo.**
- The architecture below is the part worth reading.

## Architecture

**Stack**

| | |
|---|---|
| App | SwiftUI, macOS 14+, XcodeGen, Sparkle (auto-update) |
| Backend | TypeScript + Express on Cloud Run |
| Polling | Cloud Scheduler → Cloud Tasks → the service |
| Data | Firestore (accounts, celebration counters) |
| Delivery | Cloudflare R2 behind the Cloudflare CDN |
| Auth | Google OAuth, verified server-side |
| Control plane | Firebase Remote Config |
| CI/CD | GitHub Actions — deploys, signing, Apple notarization |

**Shape**

```
                       ┌── only runs while matches are live
                       ▼
 Football API ──▶ Cloud Run ──▶ Cloudflare R2 ──▶ CDN edge
                    │      ▲                        │
                    ▼      │  sign-in · celebrate    │  poll
                Firestore  └────── menu bar apps ◀───┘
```

**How it fits together**

- **Nothing is pushed.** No APNs, no sockets, no per-user fan-out. The backend
  writes match state to R2 as JSON with a short cache lifetime, and every Mac
  polls the same cached object through the CDN.
- **Cloud Scheduler wakes a dispatcher, which enqueues short polling tasks on
  Cloud Tasks.** The cadence lives in the queue, so no request ever sleeps and
  CPU is billed per fetch, not for waiting.
- **The dispatcher gates itself on live matches.** Outside a match window it
  enqueues nothing — no API calls, no writes, no compute. Football happens for a
  fraction of the week, and the bill follows the football.
- **Each task diffs and publishes.** One range read per league, compared against
  private state in R2 with conditional writes, and only what changed gets
  published. One goal costs one write, whether ten people are watching or ten
  million.
- **Cloudflare does the delivery.** Cache Rules make the JSON cacheable, tiered
  caching absorbs the expiry stampede when every client's copy goes stale at
  once, and R2 is reachable only through custom domains — no public bucket URLs
  or S3 endpoints. A scheduled probe watches the cache-hit ratio and alerts if
  users start reaching the origin.
- **Celebrations are the one thing that scales with users**, so they're batched:
  the app sends one call per goal, the backend aggregates in memory and flushes
  to sharded Firestore counters, and the total is republished as another cached
  object. Writes track server instances, not fans.
- **Firestore is deny-all to clients.** Everything goes through the backend's
  admin path. Public routes are rate-limited, internal routes require
  service-to-service auth.
- **Remote Config is the control plane** — kill switch, forced-update floor,
  soft update banner and a celebration feature flag, applied to running apps in
  seconds, with an R2 fallback in case Firebase itself is the outage.
- **The app derives events itself.** Polled state → diff → event router →
  transparent click-through overlay, so a missed poll can't fire a phantom
  alert. Auth, API and scores are protocols, so a Debug build swaps in fakes and
  plays a scripted matchday with zero network calls.
- **Releases are signed, notarized and stapled in CI**, then shipped through
  Sparkle with delta updates. The appcast signing key never enters CI — it stays
  in a local keychain.

## The website

- Hand-written HTML, CSS and vanilla JS. No framework, no bundler, no
  dependencies, no build.
- The hero is a playable recreation of the app in DOM — the page demonstrates
  the product instead of describing it.
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
