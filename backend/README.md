# Backend — one Cloud Run service

TypeScript/Express. Two personalities in one deployable:
- **Public API** for the app: sign-in, prefs, celebrate.
- **Internal fetch** (`/internal/*`): one Cloud Scheduler job hits
  `/internal/dispatch` every minute (OIDC); it enqueues 12 Cloud Tasks spaced 5s
  apart, each calling `/internal/fetch`. A fetch is a single read of a three-day
  UTC fixture range that diffs state, publishes FCM events, and writes CDN JSON
  to R2, then returns in ~1s. The cadence lives in Cloud Tasks `scheduleTime`
  (sub-minute), so no request ever sleeps — CPU is billed only per short fetch,
  not for waiting between polls.

## Develop

```sh
npm install
npm test            # vitest — diff engine, celebrations, provider mapping
npm run typecheck
npm run dev         # tsx watch (needs env below)
```

## Environment

| Var | Source | Notes |
|---|---|---|
| `GCP_PROJECT_ID` | deploy flag | Firestore/FCM project |
| `API_FOOTBALL_KEY` | Secret Manager | Ultra plan key |
| `SESSION_JWT_SECRET` | Secret Manager | `openssl rand -hex 32` |
| `GOOGLE_OAUTH_CLIENT_ID` | Secret Manager | iOS-type client id (token audience) |
| `R2_ENDPOINT` / `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Secret Manager | R2 S3 API |
| `R2_BUCKET_SCORES` | deploy var | required environment-specific scores bucket |
| `SCHEDULER_SA_EMAIL` | optional | default `sports-scheduler@$PROJECT.iam.gserviceaccount.com` |
| `TASKS_QUEUE` / `TASKS_LOCATION` | deploy var | default `live-scores` / `us-central1` — Cloud Tasks fan-out target |
| `LEAGUE_ID` / `SEASON` | optional | default `1` / `2026` (World Cup) |
| `SERVICE_URL` | set by setup-gcp | dispatcher task target + enforces OIDC audience on `/internal/*` |

Local dev against staging: `gcloud auth application-default login` gives the
Admin SDK credentials.

## Endpoints

| Route | Auth | What |
|---|---|---|
| `GET /healthz/` | none | liveness |
| `POST /auth/signin` | Google ID token | verify → upsert user → session JWT (30d) |
| `GET/PUT /me/prefs` | session JWT | `fanOf: { football: { "1": ["6"] } }` + settings |
| `POST /celebrate` | session JWT | `{fixtureId, teamId, taps}` — ONE batched call per goal per user |
| `DELETE /me` | session JWT | account deletion |
| `POST /internal/dispatch` | scheduler OIDC | enqueue 12 Cloud Tasks at 5s offsets → `/internal/fetch` |
| `POST /internal/fetch` | scheduler OIDC | one fetch: read range → diff → notify → R2 |
| `POST /internal/test-event` | scheduler OIDC | inject fake events on staging |

Trigger a test goal on staging:

```sh
TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account=sports-scheduler@<PROJECT>.iam.gserviceaccount.com \
  --audiences=<SERVICE_URL>)
curl -X POST "<SERVICE_URL>/internal/test-event" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"type":"GOAL","teamId":6,"homeGoals":1}'
```

## Cost-critical invariants (don't break these)

1. Match comparison state lives in private R2 and uses conditional writes.
   FCM is sent before state advances, favoring duplicate delivery over missed goals.
2. `/celebrate` accepts a batched count; the aggregator flushes to sharded
   counters every 1.5s. Firestore writes are O(instances), never O(users).
3. Everything the app fetches goes to R2 with `Cache-Control` — never serve
   per-user reads from Firestore.

`/celebrate` is limited to 60 calls per minute per authenticated user on each
Cloud Run instance. This is basic abuse protection, not a globally coordinated
quota. At high traffic, enforce an additional edge rate limit with Cloud Armor
or another gateway in front of Cloud Run.

Sign-in is limited to 10 attempts per minute per client IP, and authenticated
API routes are limited to 120 calls per minute per user on each Cloud Run
instance. Deployment caps the service at 50 instances as a scaling-cost
safeguard. These limits reduce abuse but do not cap the total bill or replace a
global Cloud Armor rate limit in front of production.

## Deploy

Push to `main` (paths `backend/**`) → `backend-deploy.yml` → staging.
Manual prod: Actions → backend-deploy → run with `environment: prod`.
First-time setup: `infra/setup-gcp.sh` + `infra/README.md`.
