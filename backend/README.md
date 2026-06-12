# Backend — one Cloud Run service

TypeScript/Express. Two personalities in one deployable:
- **Public API** for the app: sign-in, prefs, celebrate.
- **Internal poller** (`/internal/*`): Cloud Scheduler hits it every minute
  with an OIDC token; it polls API-Football every 15s during live matches,
  diffs state, publishes FCM events, and writes CDN JSON to R2.

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
| `R2_BUCKET_SCORES` | optional | default `alldayidreamaboutsports-scores` |
| `SCHEDULER_SA_EMAIL` | optional | default `sports-scheduler@$PROJECT.iam.gserviceaccount.com` |
| `LEAGUE_ID` / `SEASON` | optional | default `1` / `2026` (World Cup) |
| `SERVICE_URL` | optional | enforces OIDC audience on `/internal/*` |

Local dev against staging: `gcloud auth application-default login` gives the
Admin SDK credentials.

## Endpoints

| Route | Auth | What |
|---|---|---|
| `GET /healthz` | none | liveness |
| `POST /auth/signin` | Google ID token | verify → upsert user → session JWT (30d) |
| `GET/PUT /me/prefs` | session JWT | `fanOf: { football: { "1": ["BRA"] } }` + settings |
| `POST /celebrate` | session JWT | `{fixtureId, teamCode, taps}` — ONE batched call per goal per user |
| `DELETE /me` | session JWT | account deletion |
| `POST /internal/poll` | scheduler OIDC | one tick: ≤4 polls × 15s |
| `POST /internal/test-event` | scheduler OIDC | inject fake events on staging |

Trigger a test goal on staging:

```sh
TOKEN=$(gcloud auth print-identity-token \
  --impersonate-service-account=sports-scheduler@<PROJECT>.iam.gserviceaccount.com \
  --audiences=<SERVICE_URL>)
curl -X POST "<SERVICE_URL>/internal/test-event" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"type":"GOAL","teamCode":"BRA","homeGoals":1}'
```

## Cost-critical invariants (don't break these)

1. `Store.applyMatchState` is the publish-once guarantee — deterministic event
   ids + Firestore transaction. Poller retries must never double-fire a goal.
2. `/celebrate` accepts a batched count; the aggregator flushes to sharded
   counters every 1.5s. Firestore writes are O(instances), never O(users).
3. Everything the app polls goes to R2 with `Cache-Control` — never serve
   per-user reads from Firestore.

## Deploy

Push to `main` (paths `backend/**`) → `backend-deploy.yml` → staging.
Manual prod: Actions → backend-deploy → run with `environment: prod`.
First-time setup: `infra/setup-gcp.sh` + `infra/README.md`.
