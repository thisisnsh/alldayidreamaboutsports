# Backend — one Cloud Run service

TypeScript/Express. The app only reads the CDN; this service runs the
**internal fetch pipeline** (`/internal/*`): one Cloud Scheduler job hits
  `/internal/dispatch` every minute (OIDC); it enqueues 12 Cloud Tasks spaced 5s
  apart, each calling `/internal/fetch`. A fetch is one range read PER LEAGUE
  (API-Football's `league` parameter takes a single integer) over a three-day UTC
  window, which diffs state and writes CDN JSON to R2, then returns in ~1s. The
  cadence lives in Cloud Tasks `scheduleTime` (sub-minute), so no request ever
  sleeps — CPU is billed only per short fetch, not for waiting between polls.

  The dispatcher gates itself on a live match window: outside
  `[kickoff−30min, kickoff+4h]` for every fixture it knows about, it enqueues
  nothing at all. That is what keeps five leagues — live ~38 hours a week, not
  168 — inside the API-Football quota.

## Develop

```sh
npm install
npm test            # vitest — polling, scheduling, provider mapping
npm run typecheck
npm run dev         # tsx watch (needs env below)
```

## Environment

| Var | Source | Notes |
|---|---|---|
| `GCP_PROJECT_ID` | deploy flag | Cloud Tasks project |
| `API_FOOTBALL_KEY` | Secret Manager | Ultra plan key |
| `R2_ENDPOINT` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Secret Manager | R2 S3 API |
| `R2_BUCKET_SCORES` | deploy var | required environment-specific scores bucket |
| `SCHEDULER_SA_EMAIL` | optional | default `sports-scheduler@$PROJECT.iam.gserviceaccount.com` |
| `TASKS_QUEUE` / `TASKS_LOCATION` | deploy var | default `live-scores` / `us-central1` — Cloud Tasks fan-out target |
| `LEAGUE_IDS` | optional | comma-separated; default `39,140,135,78,61` (Europe's top five). Seasons are NOT configured here — they resolve per-league from `catalog.json`, so the August rollover needs no deploy |
| `SERVICE_URL` | set by setup-gcp | dispatcher task target + enforces OIDC audience on `/internal/*` |

Local dev against staging: `gcloud auth application-default login` gives the
cloud credentials.

## Endpoints

| Route | Auth | What |
|---|---|---|
| `GET /internal/healthz` | scheduler/deploy OIDC | liveness |
| `POST /internal/dispatch` | scheduler OIDC | enqueue 12 Cloud Tasks at 5s offsets → `/internal/fetch` |
| `POST /internal/fetch` | scheduler OIDC | one fetch: read range per league → diff → R2 |
| `POST /internal/sync-schedule` | scheduler OIDC | every 6h: rewrite `fixtures-{date}.json` for today±1, so the dispatch gate has something to read while the poller sleeps |
| `POST /internal/sync-catalog` | scheduler OIDC | daily: leagues + teams (with logos) → `catalog.json` |
| `POST /internal/cache-health` | scheduler OIDC | `cf-cache-status` probe; skips `matches/*` outside a match window |
| `POST /internal/test-event` | scheduler OIDC | inject fake events on staging |

## Diagnostics

Backend logs are structured JSON in Google Cloud Logging. Useful staging
queries:

```sh
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="alldayidreamaboutsports-backend" AND jsonPayload.message=~"poll_|match_state_published|dispatch_|schedule_sync"' \
  --project=dreamaboutsports-staging --order=desc --limit=200
```

The messages worth knowing:

| Message | Means |
|---|---|
| `poll_provider_complete` | one tick finished; carries a per-league fixture count |
| `match_state_published` | a `matches/{id}.json` actually changed — logs before → after, so a bad publish (wrong score, stuck clock, missing scorer) is auditable |
| `dispatch_skipped_no_match_window` | the gate is shut; no tasks enqueued, no API calls |
| `match_window_loaded` | the gate read a fixture file (at most every 10 min per date per instance) |
| `league_seasons_missing` | a configured league has no season in `catalog.json` and is being skipped — run `/internal/sync-catalog` |
| `score_decreased` | a per-side goal count dropped (real VAR disallow vs a feed glitch) |

Trigger a test goal on staging — it writes a synthetic `matches/{id}.json` plus
a row for it in today's `fixtures-{date}.json`, so a polling client discovers and
picks it up exactly as it would a real one. The endpoint refuses to run unless
`R2_BUCKET_SCORES` is a staging bucket. The schedule file is edge-cached for 12h,
so a client that already loaded today's copy only sees the new row after a
manual ↻ once the edge copy refreshes; the row also opens the match window, so
the poller runs (and spends API quota) for the next four hours:

```sh
TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account=sports-scheduler@<PROJECT>.iam.gserviceaccount.com \
  --audiences=<SERVICE_URL>)
curl -X POST "<SERVICE_URL>/internal/test-event" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"fixtureId":999999,"homeGoals":1,"minute":73}'
```

Defaults are a live La Liga Real Madrid–Barcelona fixture; every field in
`testEventSchema` (`routes.ts`) can be overridden.

## Cost-critical invariants (don't break these)

1. Match comparison state lives in private R2 and uses conditional writes.
   Nothing is pushed: the app polls the published object, so a write that lands
   is a goal delivered to everyone at once.
2. Everything the app fetches goes to R2 with `Cache-Control`.
3. The dispatcher only enqueues inside a match window. Five leagues polled 24/7
   would be ~95,000 API calls/day against a 75,000 quota; window-gated, a peak
   Saturday is ~51,900. Do not remove the gate to "simplify" the dispatcher.

There is no user-write API, aggregation queue, or Firestore dependency.
Legacy data cleanup: `node infra/retire-celebrations.mjs --project <project>`
from the repository root previews old Firestore/R2 data; add `--apply` only
after deploying the backend without `/celebrate`.

## Deploy

Push to `main` (paths `backend/**`) → `backend-deploy.yml` → staging.
Manual prod: Actions → backend-deploy → run with `environment: prod`.
First-time setup: `infra/setup-gcp.sh` + `infra/README.md`.

All routes are private behind Cloud Run IAM. `sports-scheduler` invokes the
operational routes; `sports-deploy` may only pass the application's health
check. `secure-backend.sh` removes public invokers and enables the IAM check,
including on direct `run.app` URLs. Ingress remains reachable for authenticated
GitHub smoke checks; being on GCP alone does not grant invocation rights.
