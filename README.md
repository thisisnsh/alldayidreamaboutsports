<div align="center">

<img src="website/src/assets/app-icon.png" width="112" alt="All Day I Dream About Sports app icon">

# All Day I Dream About Sports

**Live football scores for Europe's top five leagues - dropped right below your MacBook notch.**

[Website](https://alldayidreamaboutsports.com) &nbsp;·&nbsp;
[Download](https://alldayidreamaboutsports.com) &nbsp;·&nbsp;
[Demo](https://youtu.be/B75DYFddkV0) &nbsp;·&nbsp;
[Privacy](https://alldayidreamaboutsports.com/privacy)

Free · macOS 14+ · Premier League · La Liga · Serie A · Bundesliga · Ligue 1

<img src="website/media/all-sports-promo.gif" width="720" alt="All Day I Dream About Sports app demo">

</div>

---

## Overview

A menu bar app for people who are supposed to be working while their team plays.

- **Notch drops** - goals, cards, penalties, VAR, subs, kickoff and full-time
  slide in below the notch, then get out of the way.
- **Live capsule** - pin the running score to the corner of the screen.
- **Celebrate** - goal animations on a transparent overlay; tap the ball for
  more.
- **Your teams** - follow clubs across the top five leagues.

The app is anonymous - there is no sign-in.

## Architecture

**Stack**

- **App** - [SwiftUI][swiftui], shipped through the [Mac App Store][appstore]
- **Backend** - [TypeScript][ts] + [Express][express] on [GCP Cloud Run][run]
- **Polling** - [GCP Cloud Scheduler][scheduler] → [GCP Cloud Tasks][tasks] → the service
- **Football data** - [API-Football][apifootball]
- **Delivery** - [Cloudflare R2][r2] + [Cloudflare CDN][cdn]
- **Website** - [Eleventy][11ty] on [GitHub Pages][pages]
- **CI/CD** - [GitHub Actions][actions]

**Shape**

```
                       ┌── only runs while matches are live
                       ▼
 API-Football ──▶ Cloud Run ──▶ Cloudflare R2 ──▶ CDN edge
                                                     │ 5s poll
                                  menu bar apps ◀────┘
```

**How it fits together**

- **Everything is polled, nothing is pushed or per-user.** Match state sits in
  [Cloudflare R2][r2] as JSON with a 5s TTL, and every Mac reads that same
  cached object through the [CDN][cdn] - one goal costs one R2 write however
  many people are watching.
- **Read cost is fixed.** Cloudflare's [tiered caching][tiered] absorbs the
  stampede when every client's copy expires at once, so the edge answers and
  [R2][r2] barely sees it.
- **[GCP Cloud Scheduler][scheduler] dispatches to [GCP Cloud Tasks][tasks]**,
  which drive [Cloud Run][run] to poll API-Football every 5 seconds (one call
  per league) and publish what changed to [R2][r2]. The cadence lives in the
  queue, so nothing sleeps and CPU is billed per fetch.
- **Polling only runs inside a match window** (`[kickoff−30min, kickoff+4h]`),
  which makes write cost proportional to the number of matches, not to the time
  of day or the number of users. Five leagues are live roughly 38 hours a week,
  not 168.
- **Celebrations are local.** Goal animations and ball taps run on the Mac;
  there are no shared counts or user writes.
- **The App Store handles updates.** There is no remote config; to stop the app
  in an emergency, cut CDN access - see the
  [emergency-stop runbook](infra/README.md#emergency-stop-runbook).

## Repo layout

| Dir | What | Docs |
|---|---|---|
| `app/` | macOS app (SwiftUI, macOS 14+, XcodeGen) | [app/README.md](app/README.md) - build, test, Mac App Store release |
| `backend/` | Cloud Run service: poller + internal API (TypeScript) | [backend/README.md](backend/README.md) - endpoints, env, deploy |
| `infra/` | GCP/R2 setup scripts | [infra/README.md](infra/README.md) - one-time cloud setup, emergency-stop runbook |
| `website/` | Landing page + privacy policy (Eleventy) | [website/README.md](website/README.md) - build, verify, data |
| `tester/` | Staging-only dev tooling: fake publisher, load test | [tester/README.md](tester/README.md) |
| `.github/` | CI: backend test/deploy, website deploy | [.github/README.md](.github/README.md) - workflow overview |

## Quick start

- Backend: `cd backend && npm install && npm test && npm run dev`
- App: `brew install xcodegen && cd app && xcodegen && open AllDayIDreamAboutSports.xcodeproj`
  (real-service setup and staging/prod builds: [app/README.md](app/README.md#real-service-configuration))
- Website: `cd website && npm install && npm run serve`
- One-time cloud setup: see [infra/README.md](infra/README.md)

## Release

The app ships only through the Mac App Store, straight from Xcode: Product →
Archive → Distribute App → App Store Connect. No release CI, no DMG. See
[app/README.md](app/README.md#mac-app-store). The website deploys to GitHub
Pages on every push to `main` that touches `website/`.

## Contributions

Not accepting pull requests. Bug reports and ideas are welcome - open an issue
or email [hello@thisisnsh.com](mailto:hello@thisisnsh.com). See the
[contribution policy](CONTRIBUTING.md) and the
[security reporting policy](SECURITY.md).

## License

Original source code and bundled app icons are licensed under
[GPL-3.0-only](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md).
Not affiliated with FIFA, UEFA, or any league or club; badges and marks belong
to their owners.

[11ty]: https://www.11ty.dev
[pages]: https://pages.github.com
[swiftui]: https://developer.apple.com/xcode/swiftui/
[appstore]: https://developer.apple.com/app-store/
[ts]: https://www.typescriptlang.org
[express]: https://expressjs.com
[run]: https://cloud.google.com/run
[scheduler]: https://cloud.google.com/scheduler
[tasks]: https://cloud.google.com/tasks
[apifootball]: https://www.api-football.com
[r2]: https://developers.cloudflare.com/r2/
[cdn]: https://developers.cloudflare.com/cache/
[tiered]: https://developers.cloudflare.com/cache/how-to/tiered-cache/
[actions]: https://github.com/features/actions
