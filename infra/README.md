# Infra — one-time setup checklist

Two environments: `dreamaboutsports-staging` and `dreamaboutsports-prod`. Everything
below is per environment unless marked global.

## 1. GCP + Firebase

```sh
gcloud projects create dreamaboutsports-staging && gcloud billing projects link ...
./setup-gcp.sh dreamaboutsports-staging us-central1
```

Then in the [Firebase console](https://console.firebase.google.com):

1. **Add Firebase to the GCP project**, register the macOS app (bundle id
   `com.thisisnsh.alldaysports`), and download `GoogleService-Info.plist`.
   Save it locally as `app/Resources/GoogleService-Info-Staging.plist` or
   `app/Resources/GoogleService-Info-Production.plist`. See
   [`app/README.md`](../app/README.md#real-service-configuration).
   Firebase is used for Analytics and Crashlytics only — there is no Remote
   Config and no Cloud Messaging / APNs setup (push was dropped in favour of
   polling + CDN).
2. Firestore is no longer used. Keep existing databases deny-all; retire only
   the legacy celebration collection with `retire-celebrations.mjs` after deploy.
   The cleanup also removes retired count files, Remote Config parameters, and
   the runtime's obsolete Firestore/Firebase Admin IAM grants.

### Private backend

The Mac app reads the public scores CDN only. Cloud Scheduler and Cloud Tasks
call the backend's `run.app` URL using the scheduler service account and an
OIDC audience equal to that URL. No app API custom domain is needed.

`secure-backend.sh <project> <region>` grants invocation to `sports-scheduler`
and `sports-deploy`, removes anonymous invokers, and enables Cloud Run IAM.
The app verifies service identity too: deployment credentials only access
`GET /internal/healthz`. GitHub obtains a short-lived ID token for its smoke test.

All ingress stays addressable to support authenticated GitHub smoke checks;
unauthenticated requests are denied before reaching the container. Merely
originating inside GCP does not authenticate a request.

## 2. Cloudflare

```sh
CLOUDFLARE_API_TOKEN=<token> \
CLOUDFLARE_ACCOUNT_ID=<account-id> \
CLOUDFLARE_ZONE_ID=<zone-id> \
./setup-r2.sh
```

The scores data and comparison state are environment-specific:

| Environment | Bucket | Custom domain | GitHub environment var |
|---|---|---|---|
| staging | `alldayidreamaboutsports-staging-scores` | `scores-staging.alldayidreamaboutsports.com` | `R2_BUCKET_SCORES=alldayidreamaboutsports-staging-scores` |
| prod | `alldayidreamaboutsports-scores` | `scores.alldayidreamaboutsports.com` | `R2_BUCKET_SCORES=alldayidreamaboutsports-scores` |

`R2_BUCKET_SCORES` is required by deployment and the backend has no fallback,
so staging cannot accidentally write into the production scores bucket.

`setup-r2.sh` owns the full R2/CDN setup: it creates the buckets, attaches the
custom domains, disables every bucket's public `r2.dev` URL, creates the Cache
Rules, enables Tiered Cache + Smart Tiered Cache topology, and applies WAF rate
limits. If the Cloudflare API env vars are omitted it only creates buckets and
disables `r2.dev` through wrangler, then prints the exact command to rerun for
the full setup.

The app must access R2 objects only through the custom domains above, never an
`r2.dev` URL or the S3 API endpoint. The custom domain puts Cloudflare's CDN in
front of R2. Cache hits are served by Cloudflare; cache misses still read R2 as
the origin. Public `r2.dev` URLs bypass the zone Cache Rules and WAF, so the
script keeps them disabled.

JSON is not cached by Cloudflare by default. The script creates Cache Rules for
both scores hostnames in the
`http_request_cache_settings` phase. Those rules make matching objects eligible
for cache, set Edge TTL to "use Cache-Control if present, bypass cache if not",
and set Browser TTL to respect origin. Without this, every app request reaches
R2 and incurs a Class B operation. Smart Tiered Caching is mandatory —
~26 R2 reads/s vs ~600/s — because it absorbs the per-TTL expiry stampede by
funneling edge misses through a small number of upper-tier data centers.

Object TTLs (plan §3): `matches/*` are
`public, max-age=5, stale-while-revalidate=25`; `fixtures-*` and `catalog.json`
are `public, max-age=43200` (12h). The `/internal/cache-health` scheduler job
(every 5 min) reads `cf-cache-status` and alerts if users start hitting R2 —
treat a falling hit ratio or rising R2 reads as sev-1. It probes `catalog.json`
year-round, but skips `matches/*` outside a live match window: those files are
stale by design between matches, so probing them would page us about a
Wednesday.

Four scheduler jobs run per environment: `dispatch-live-scores` (every minute,
self-gating on the match window), `sync-schedule` (every 6h), `sync-catalog`
(daily) and `cache-health` (every 5 min). Cloud Scheduler's free tier is three
jobs, so the fourth costs $0.10/month.

The same script manages the zone `http_ratelimit` ruleset. Cloudflare may cap
the zone at one rate-limit rule depending on plan, so the setup uses a single
origin-only rule across all R2 custom domains. That protects the expensive path:
cache-busting requests that would otherwise read R2.

| Scope | Limit | Why |
|---|---:|---|
| both scores custom domains, R2 origin reads only | 200/10s per IP + colo | Counts only origin requests, so cache hits are not penalized |

Override the request limit with `R2_ORIGIN_RATE_LIMIT_REQUESTS_PER_10_SECONDS`.
On Cloudflare Free, the mitigation timeout must stay at 10 seconds.

An R2 custom domain returning `404` usually means the domain is connected but
the requested object has not been uploaded yet. After the first backend deploy:

```sh
# Reconcile scheduler targets with the real Cloud Run URL.
./setup-gcp.sh dreamaboutsports-staging us-central1

# Populate catalog.json immediately.
gcloud scheduler jobs run sync-catalog \
  --project=dreamaboutsports-staging --location=us-central1

# Populate the three UTC fixture files immediately. Run this BEFORE the
# dispatcher: the dispatch gate reads these files to decide whether any match
# is in its [kickoff-30min, kickoff+4h] window, and with no file it stays shut.
gcloud scheduler jobs run sync-schedule \
  --project=dreamaboutsports-staging --location=us-central1

# Then the live tick. Inside a match window the dispatcher enqueues 12 Cloud
# Tasks (5s apart) that hit /internal/fetch, giving ~every-5s polling; outside
# one it enqueues nothing and returns {"enqueued":0}.
gcloud scheduler jobs run dispatch-live-scores \
  --project=dreamaboutsports-staging --location=us-central1

# Polling no longer needs pausing to save API-Football quota — the handler gates
# itself. Pause it only to stop live scores outright:
gcloud scheduler jobs pause  dispatch-live-scores --location=us-central1
gcloud scheduler jobs resume dispatch-live-scores --location=us-central1

curl -fsS https://scores-staging.alldayidreamaboutsports.com/catalog.json >/dev/null
curl -fsS https://scores-staging.alldayidreamaboutsports.com/fixtures-$(date -u +%F).json >/dev/null
```

Production `scores.alldayidreamaboutsports.com` remains empty until the
production backend is deployed and its jobs run.

DNS for `alldayidreamaboutsports.com`: apex → **GitHub Pages** (A records
185.199.108.153/.109/.110/.111). The website lives in the separate repo
`thisisnsh/alldayidreamaboutsports.com` (Settings → Pages → Source = "Deploy
from a branch" `main`/root, custom domain + HTTPS enforced). `scores-staging.`
and `scores.` -> R2 custom domains (Cloudflare-proxied). The script no longer
manages the retired `*-downloads` buckets or `download.` domains; delete them
from the Cloudflare dashboard if they still exist.

## 3. API-Football

Subscribe to **Ultra** ($29/mo) at
[api-football.com/pricing](https://www.api-football.com/pricing). Key → secret
`api-football-key`.

The polled leagues are `LEAGUE_IDS` on the Cloud Run service — by default
`39,140,135,78,61` (Premier League, La Liga, Serie A, Bundesliga, Ligue 1).
Seasons are **not** configured anywhere: they resolve per-league from
`catalog.json`, so the August rollover needs no deploy.

Ultra allows 75,000 calls/day. A peak Saturday is ~51,900 (69%): five range
calls plus one enrichment call per 5s tick, across a ~12h union match window,
plus 20 for the schedule sync and 12 for the catalog sync. An average day is
nearer 22,000. A sixth league does not fit without the Mega plan — watch the
request counter on the first live weekend.

## 4. Apple (global, once)

The app ships only through the Mac App Store and is signed by Xcode's automatic
signing — no certificates, notarization or signing secrets live in this repo or
in CI. At [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list),
register the explicit App ID `com.thisisnsh.alldaysports` with **Keychain Sharing**. Push
Notifications are not used (the app polls the scores CDN), so no APNs key /
Cloud Messaging setup is required. App Store Connect setup and the
archive/upload flow: [`app/README.md`](../app/README.md#mac-app-store).

## GitHub secrets/vars summary

| Where | Name | Source |
|---|---|---|
| env secret | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DEPLOY_SERVICE_ACCOUNT` | setup-gcp.sh output |
| env var | `GCP_PROJECT_ID`, `GCP_REGION`, `R2_BUCKET_SCORES` | setup-gcp.sh output + scores bucket table |

There are no app secrets in GitHub: the app is built and uploaded from Xcode.
The backend reads its R2 creds from GCP Secret Manager (`r2-*`, via
`backend-deploy.yml`).

## Emergency-stop runbook

The app has no remote switches — it only reads the scores CDN, so the levers
are server-side.

- **Stop notifications** (keep the app usable): pause the live poller.
  `matches/*` stop changing, so the app keeps showing the last scores but no
  new events fire.
  ```sh
  gcloud scheduler jobs pause dispatch-live-scores --location=us-central1
  ```
  Recover with `gcloud scheduler jobs resume …`.
- **Stop the app**: in the Cloudflare dashboard, add a WAF custom rule on the
  zone that blocks the scores hostname (`scores.alldayidreamaboutsports.com`
  for prod). WAF runs before the cache, so cached objects are blocked too.
  Every fetch fails, and the app goes quiet: no scores, no events, failures
  logged once per fixture per session. Recover by disabling the rule.
- **Old builds**: there is no forced update. Keep CDN JSON changes additive;
  put a breaking schema change under a new path (e.g. `v2/`) so older builds
  keep reading the old files.

## Deployment trust

Run `bash infra/configure-deploy-trust.sh <project> <staging|prod>` with `gcloud`,
`gh`, and `jq` available. It reconciles existing providers and IAM bindings.
GitHub identity must match the immutable repository and owner IDs, `main`,
`.github/workflows/backend-deploy.yml@refs/heads/main`, and that project's
exact environment subject. Staging credentials cannot satisfy production trust.
A token from another branch or workflow is rejected even if it belongs to this
repository. Renaming the repository requires explicitly reconciling this trust.

In GitHub, restrict both environments to the `main` branch and require a
production reviewer where the plan supports that protection. GCP conditions
remain mandatory regardless of GitHub plan. Do not weaken them to unblock a
feature-branch deploy; merge reviewed changes to `main` instead.

## Scores request guard

The scores CDN serves canonical GET/HEAD JSON paths only. Native app requests
need no query string or Origin header. `secure_scores.py` blocks query strings,
cache-fragmenting headers (including Origin), unsupported methods, and unrelated
paths before R2. This deliberately excludes browser cross-origin consumers;
review that policy before exposing a browser API.

Preview without credentials:

```sh
python3 infra/secure_scores.py --plan
python3 -m unittest discover -s infra/test -v
```

Apply with `CLOUDFLARE_ZONE_ID` and a `CLOUDFLARE_API_TOKEN` granting **Zone WAF
Edit** on this zone in your local environment:

```sh
python3 infra/secure_scores.py --apply
```

The script inserts/updates only its managed rule, before skip rules, and reads
it back. Existing emergency blocks and unrelated rules remain intact. Full R2
setup also applies this guard. Verify canonical `/catalog.json` returns 200 and
warms to HIT, while a query variant and an `Origin` header receive 403. Test
both score hosts in their intended access context; staging Access may reject
requests first. Never run a production load test to check this.

This guard is not a global cost cap: distributed traffic and nonexistent match
IDs still need monitoring. Configure Cloudflare R2 operations/billing alerts
for the account, and verify delivery to an operator. The application cannot
verify account billing alerts with its bucket-scoped S3 credentials.

## Resource-scoped backend IAM

`setup-gcp.sh` grants the runtime read access only to its four named secrets.
Deployment can act as the runtime and default Cloud Build identity, and manage
source objects only in the project's regional `run-sources` bucket. It no longer
grants project-wide Secret Accessor, Service Account User, or Storage Admin.

For existing projects, review the read-only plan first:

```sh
bash infra/scope-backend-iam.sh dreamaboutsports-staging us-central1 --plan
bash infra/scope-backend-iam.sh dreamaboutsports-staging us-central1 --apply
```

The script preflights required resources and adds replacements before removing
legacy unconditional grants. It preserves conditional and unrelated bindings.
Test a staging source deployment before applying the same migration to prod.
If using a custom build service account instead of the project's default, adapt
the build identity resolution before applying this script.
