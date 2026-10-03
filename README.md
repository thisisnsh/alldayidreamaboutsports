# All Day I Dream About Sports ⚽☁️

macOS menu bar app for Europe's top five leagues — the Premier League, La Liga,
Serie A, Bundesliga and Ligue 1. Follow your teams, get live goal celebration
animations on a transparent overlay, tap the ball to celebrate with fans across
the globe, and see fixtures at a glance — all from the menu bar.

Website: [alldayidreamaboutsports.com](https://alldayidreamaboutsports.com)

## How it works (the 10-cent version)

**Nothing is pushed and nothing is per-user.** One backend poller asks
[API-Football](https://www.api-football.com) for a three-day UTC fixture range
every 5 seconds — one call per league — and writes every match's state to
Cloudflare R2 as JSON with a 5s edge TTL. Every Mac polls those same cached
objects. One goal costs us one R2 write however many people are watching, and
the reads are served by Cloudflare's edge, which is unmetered on a proxied zone.
The app is anonymous — there is no sign-in.

The poller is **gated on a live match window**: outside
`[kickoff−30min, kickoff+4h]` for every fixture it knows about, it enqueues no
work at all. Five leagues are live roughly 38 hours a week, not 168 — that gate
is what keeps them inside the API-Football quota.

```
                     ┌── 5s tick, only inside a match window
                     ▼
API-Football ──▶ Cloud Run backend ──▶ R2 JSON ──▶ Cloudflare CDN
                      │      ▲                          │
                      ▼      │ /celebrate               │ 5s poll
                 Firestore   └──────── menu bar apps ◀──┘
```

Only `/celebrate` scales with users, at roughly **$17 per 1M concurrent**.
Everything else scales with *matches*, or with nothing at all — which is why
the whole bill is ~$55/month at 1M concurrent users. See
[backend/README.md](backend/README.md) for the cost-critical invariants that
keep it that way.

## Repo layout

| Dir | What | Docs |
|---|---|---|
| `app/` | macOS app (SwiftUI, macOS 14+, XcodeGen) | [app/README.md](app/README.md) — build, test, Mac App Store release |
| `backend/` | Cloud Run service: poller + public API (TypeScript) | [backend/README.md](backend/README.md) — endpoints, env, deploy |
| `infra/` | GCP/R2 setup scripts, Remote Config template, Firestore rules | [infra/README.md](infra/README.md) — one-time cloud setup, kill-switch runbook |
| `.github/` | CI: backend test/deploy | [.github/README.md](.github/README.md) — workflow overview |

The landing page + privacy policy live in the separate **public** repo
[`thisisnsh/alldayidreamaboutsports.com`](https://github.com/thisisnsh/alldayidreamaboutsports.com)
(GitHub Pages isn't free on this private repo).

**Shipping for the first time?** Work through [TODO.md](TODO.md) top to bottom.

## Quick start

- Backend: `cd backend && npm install && npm test && npm run dev`
- App: `brew install xcodegen && cd app && xcodegen && open AllDayIDreamAboutSports.xcodeproj`
  (real-service setup and staging/prod builds: [app/README.md](app/README.md#real-service-configuration))
- One-time cloud setup: see [`infra/README.md`](infra/README.md)

## Release

The app ships only through the Mac App Store, straight from Xcode: Product →
Archive → Distribute App → App Store Connect. No CI, no DMG. See
[app/README.md](app/README.md#mac-app-store). Kill switch and forced updates are
driven by Firebase Remote Config (`kill_switch`, `min_build`).
