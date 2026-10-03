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
   Firebase is used for Remote Config only — there is no Cloud Messaging / APNs
   setup (push was dropped in favour of polling + CDN).
2. **Remote Config** → import `remoteconfig.template.json`, publish.
3. **Firestore rules** → deploy `firestore.rules` (deny-all; backend uses Admin SDK):
   `firebase deploy --only firestore:rules`

### Backend API domain

Cloud Run assigns the backend a stable `*.run.app` service URL after its first
deployment. The app uses environment-specific custom domains instead:

| Environment | App API base URL |
|---|---|
| staging | `https://api-staging.alldayidreamaboutsports.com` |
| prod | `https://api.alldayidreamaboutsports.com` |

After the first backend deploy, create a Cloud Run domain mapping:

1. Open **Google Cloud Console → Cloud Run → Domain mappings → Add mapping**.
2. Select `alldayidreamaboutsports-backend` and the appropriate GCP project.
3. Map `api-staging.alldayidreamaboutsports.com` for staging or
   `api.alldayidreamaboutsports.com` for production.
4. Verify ownership of `alldayidreamaboutsports.com` when prompted.
5. Add the DNS records Google displays to Cloudflare DNS as **DNS only**
   records. Do not proxy these records through Cloudflare.
6. Verify:

   ```sh
   curl -fsS https://api-staging.alldayidreamaboutsports.com/healthz/
   # or production:
   curl -fsS https://api.alldayidreamaboutsports.com/healthz/
   ```

Cloud Run domain mappings are a convenient initial setup but remain a preview
feature. Before high-volume production traffic, put a global external
Application Load Balancer and Cloud Armor in front of Cloud Run, then restrict
Cloud Run ingress so the public `run.app` URL cannot bypass those controls.
Until then, deployment caps Cloud Run at 50 instances to bound scaling cost;
raising that cap trades stronger availability for higher billing exposure.
Maximum instances does not cap the total bill or downstream-service usage.

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

Downloads also use separate staging/prod buckets and custom domains so test
releases never reach the production auto-update feed.
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
both scores hostnames and the download hostnames in the
`http_request_cache_settings` phase. Those rules make matching objects eligible
for cache, set Edge TTL to "use Cache-Control if present, bypass cache if not",
and set Browser TTL to respect origin. Without this, every app request reaches
R2 and incurs a Class B operation. Smart Tiered Caching is mandatory —
~26 R2 reads/s vs ~600/s — because it absorbs the per-TTL expiry stampede by
funneling edge misses through a small number of upper-tier data centers.

Object TTLs (plan §3): `matches/*` and `celebrate/*` are
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
| all scores/download custom domains, R2 origin reads only | 200/10s per IP + colo | Counts only origin requests, so cache hits are not penalized |

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
production backend is deployed and its jobs run. The `download-staging.` /
`download.` buckets held the old website DMGs + Sparkle appcast; the app now
ships only through the Mac App Store, so nothing publishes to them any more.

DNS for `alldayidreamaboutsports.com`: apex → **GitHub Pages** (A records
185.199.108.153/.109/.110/.111). The website lives in the **public** repo
`thisisnsh/alldayidreamaboutsports.com` (Settings → Pages → Source = "Deploy
from a branch" `main`/root, custom domain + HTTPS enforced) — Pages isn't free on
this private repo. `scores-staging.`, `scores.`, `download-staging.`, and
`download.` -> R2 custom domains (Cloudflare-proxied).

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

## Kill switch runbook

- **Kill**: Firebase console → Remote Config → `kill_switch=true` → Publish.
  Running apps lock within seconds (real-time RC). Backup if Firebase is down:
  upload `{"killSwitch":true,"message":"..."}` as `config.json` to `alldayidreamaboutsports-scores`.
- **Recover**: publish `kill_switch=false` in Firebase and clear `killSwitch`
  from the R2 `config.json` (or set it to `false`) if the backup was used.
  The app stays killed until every source that enabled the switch clears it.
- **Force update**: set `min_build` to the new build number after a bad
  release — only once that build is live on the App Store.
- **Offer update**: set `latest_build` to the newest published build. Older
  installs show a soft "Update available" banner atop the menu (still usable);
  leave at `0` to hide the banner.
- **Celebration cost spike**: `celebration_enabled=false`.

## Remote Config fetch cadence

`remote_config_fetch_interval_seconds` controls how often a running app forces a
periodic Remote Config fetch. Default **300 s (5 min)**; accepted range **60 –
86400 s**. Missing, malformed, non-finite, zero, negative or out-of-range values
fall back to 300 s, so a bad edit can't create a tight billing loop or switch
refreshes off. The app also carries a local 300 s bootstrap default it uses
until the template's value has been fetched.

The interval only governs the *periodic* loop, which one app-wide task owns (the
menu bar popover has no Remote Config timer — opening it or leaving it open does
not change fetch frequency):

- **Startup** fetches immediately.
- **Foreground / wake** fetches immediately (`applicationDidBecomeActive`).
- **Real-time invalidations** stay enabled, so a publish still lands within
  seconds without waiting for the next periodic fetch.

Publishing a new value takes effect without a restart — the real-time listener
applies it and reschedules the next fetch. Verify in the app log:
`firebase_state_applied … rc_fetch_seconds=300` and
`periodic_fetch_scheduled interval_seconds=300`.

Lowering the interval multiplies billable Remote Config fetches per install once
Firebase's usage-based pricing applies. Raise it, don't lower it, unless an
incident needs faster recovery than the real-time listener provides.
