# All Day I Dream About Sports ⚽☁️

macOS menu bar app for FIFA World Cup 2026: follow your teams, get live goal
celebration animations on a transparent overlay, tap the ball to celebrate with
fans across the globe, and see fixtures at a glance — all from the menu bar.

Website: [alldayidreamaboutsports.com](https://alldayidreamaboutsports.com)

## How it works (the 10-cent version)

One backend poller asks [API-Football](https://www.api-football.com) for live
scores every 15 seconds. Goal and match events fan out to every Mac via free
FCM topic push (`l1_BR`, `l1_US`, …). Everything clients poll (fixtures, live
scores, celebration counts, backup kill switch) is cached JSON on Cloudflare R2.
Sign-in is Google OAuth verified by our own API — no per-user billing anywhere.
That is how 10M users/day costs hundreds, not thousands, per month.

```
API-Football ──15s──▶ Cloud Run backend ──▶ FCM topics ──▶ menu bar apps
                          │    ▲                              ▲
                          ▼    │ /auth /me /celebrate         │
                     Firestore │                              │
                          ▼    │                              │
                     R2 JSON ──┴───── Cloudflare CDN ─────────┘
```

## Repo layout

| Dir | What | Docs |
|---|---|---|
| `app/` | macOS app (SwiftUI, macOS 14+, XcodeGen) | [app/README.md](app/README.md) — build, codesign, notarize, Sparkle, release |
| `backend/` | Cloud Run service: poller + public API (TypeScript) | [backend/README.md](backend/README.md) — endpoints, env, deploy |
| `web/` | Landing page + privacy policy (GitHub Pages) | [web/README.md](web/README.md) — Pages setup, DNS |
| `infra/` | GCP/R2 setup scripts, Remote Config template, Firestore rules | [infra/README.md](infra/README.md) — one-time cloud setup, kill-switch runbook |
| `.github/` | CI: backend test/deploy, app release, web deploy | [.github/README.md](.github/README.md) — workflow overview |

**Shipping for the first time?** Work through [TODO.md](TODO.md) top to bottom.

## Quick start

- Backend: `cd backend && npm install && npm test && npm run dev`
- App: `brew install xcodegen && cd app && xcodegen && open AllDayIDreamAboutSports.xcodeproj`
  (drop your `GoogleService-Info.plist` into `app/Resources/` — gitignored)
- One-time cloud setup: see [`infra/README.md`](infra/README.md)

## Release

Tag `v*` → GitHub Actions builds, signs (Developer ID), notarizes, staples,
generates the Sparkle appcast, and uploads to `download.alldayidreamaboutsports.com`.
Kill switch and forced updates are driven by Firebase Remote Config
(`kill_switch`, `min_build`) with an R2 `config.json` backup.
