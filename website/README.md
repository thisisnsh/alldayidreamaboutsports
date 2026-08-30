<div align="center">

<img src="src/assets/app-icon.png" width="112" alt="All Day I Dream About Sports app icon">

# All Day I Dream About Sports

**Live football scores for Europe's top five leagues — dropped right below your MacBook notch.**

[Website](https://alldayidreamaboutsports.com) &nbsp;·&nbsp;
[Download](https://alldayidreamaboutsports.com) &nbsp;·&nbsp;
[Demo](https://youtu.be/B75DYFddkV0) &nbsp;·&nbsp;
[Privacy](https://alldayidreamaboutsports.com/privacy)

Free · macOS 14+ · Premier League · La Liga · Serie A · Bundesliga · Ligue 1

<img src="src/assets/og-image.jpg" width="720" alt="Live match alert dropping below the MacBook notch">

<img src="media/all-sports-promo.gif" width="720" alt="All Day I Dream About Sports app demo">

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

**Note:** This repository has landing page code for
[alldayidreamaboutsports.com](https://alldayidreamaboutsports.com). The macOS
app and its backend are closed source.

## Architecture

**Stack**

- **App** — [SwiftUI][swiftui], [Sparkle][sparkle] (auto-update)
- **Backend** — [TypeScript][ts] + [Express][express] on [GCP Cloud Run][run]
- **Polling** — [GCP Cloud Scheduler][scheduler] → [GCP Cloud Tasks][tasks] → the service
- **Data** — [Firebase Firestore][firestore]
- **Delivery** — [Cloudflare R2][r2] + [Cloudflare CDN][cdn]
- **Auth** — [Google OAuth][oauth]
- **Control plane** — [Firebase Remote Config][rc]
- **CI/CD** — [GitHub Actions][actions]

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

- **Everything is polled, nothing is pushed.** Match state sits in
  [Cloudflare R2][r2] as JSON with a short TTL, and every user reads that same
  cached object through the [CDN][cdn] — so serving 1M users costs the same as
  serving 1.
- **Read cost is fixed.** Cloudflare's [tiered caching][tiered] absorbs the
  stampede when every client's copy expires at once, so the edge answers and
  [R2][r2] barely sees it.
- **[GCP Cloud Scheduler][scheduler] dispatches to [GCP Cloud Tasks][tasks]**,
  which drive [Cloud Run][run] to poll the football data API and publish what
  changed to [R2][r2]. The cadence lives in the queue, so nothing sleeps and CPU
  is billed per fetch.
- **Polling only runs inside a match window**, which makes write cost
  proportional to the number of matches, not to the time of day or the number of
  users.
- **Celebrations are the one real per-user cost**, so they're batched: one call
  per goal from the app, aggregated in memory and flushed to sharded
  [Firestore][firestore] counters, then republished as another cached object.
- **[Firebase Remote Config][rc] is the control plane** — kill switch, forced
  updates and feature flags, applied to running apps in realtime.
- **[Sparkle][sparkle] powered updates.** In place app updates with delta patches
  from an EdDSA-signed appcast.
- **[GitHub Actions][actions] handles release.** Backend deploys, app builds and
  [Apple notarization][notarize].

## The website

155 pages, built with [Eleventy][11ty] and deployed to [GitHub Pages][pages] by
[Actions][actions]. One home page, two hubs, six competition pages, 144 team
pages, privacy and 404 — every competition and every team the app covers has a
page of its own.

```bash
npm install
npm run build     # → _site/
npm run serve     # local dev server
npm run verify    # asserts the built site (see below)
npm run data      # regenerate leagues/teams/crests from the live catalog
```

**Layout**

```
.eleventy.js
src/
  _data/       site.js · faq.js · features.js
               leagues.json · teams.json      (generated)
               teamExtras.json · leagueExtras.json  (hand-authored)
  _includes/   layouts/ · partials/
  index.njk · leagues/ · teams/ · privacy/ · 404.njk · sitemap.xml.njk
  style.css · script.js · assets/
scripts/
  build-data.mjs     catalog → data + mirrored crests (run by hand, output committed)
  encode-promo.sh    promo reel → mp4/webm/poster for the background layer
  verify-build.mjs   page count, unique titles, dead links, orphans, JSON-LD
```

- **The data is generated, the writing is not.** `build-data.mjs` reads the
  app's live catalog for the leagues, teams and crests; `teamExtras.json`
  carries a hand-written record per team so 144 pages are not 144 copies of
  each other.
- **CI is offline.** The generated data and the 96px WebP crests are committed,
  so a build never depends on the catalog being reachable.
- **The promo reel is not in this repo.** It is encoded by
  `scripts/encode-promo.sh` and served from the same [R2][r2] bucket as the app
  downloads, then used as a fixed background layer behind the whole site.

## Contributions

Not accepting pull requests. Bug reports and ideas are welcome — open an issue
or email [support@alldayidreamaboutsports.com](mailto:support@alldayidreamaboutsports.com).

## Legal

© Nishant Hada. All rights reserved. Not affiliated with FIFA, UEFA, or any
league or club; badges and marks belong to their owners.

[11ty]: https://www.11ty.dev
[pages]: https://pages.github.com
[swiftui]: https://developer.apple.com/xcode/swiftui/
[sparkle]: https://sparkle-project.org
[ts]: https://www.typescriptlang.org
[express]: https://expressjs.com
[run]: https://cloud.google.com/run
[scheduler]: https://cloud.google.com/scheduler
[tasks]: https://cloud.google.com/tasks
[firestore]: https://firebase.google.com/docs/firestore
[r2]: https://developers.cloudflare.com/r2/
[cdn]: https://developers.cloudflare.com/cache/
[tiered]: https://developers.cloudflare.com/cache/how-to/tiered-cache/
[oauth]: https://developers.google.com/identity/protocols/oauth2
[rc]: https://firebase.google.com/docs/remote-config
[actions]: https://github.com/features/actions
[notarize]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
