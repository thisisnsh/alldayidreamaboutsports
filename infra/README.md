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
   `com.alldayidreamaboutsports.mac`), and download `GoogleService-Info.plist`.
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

## 2. Google OAuth (sign-in) — ⚠️ ship blocker

[Console → APIs & Services → OAuth consent screen](https://console.cloud.google.com/apis/credentials/consent):

- External, app name "All Day I Dream About Sports", domain
  `alldayidreamaboutsports.com`, privacy policy `https://alldayidreamaboutsports.com/privacy`.
- Scopes: only `openid`, `email`, `profile` (non-sensitive → no review wait).
- **Publishing status: In production** — in Testing mode sign-in caps at 100 users.
- Clients → create client → **iOS type** (used by Google Sign-In for this macOS
  app), bundle id `com.alldayidreamaboutsports.mac`, then download its plist.
  Put its `CLIENT_ID` in the environment's `google-oauth-client-id` Secret
  Manager secret. Put its `CLIENT_ID` and `REVERSED_CLIENT_ID` in the matching
  `Staging`/`Release` settings in `app/project.yml`; the reversed value is only
  the callback URL scheme. Full example: [`app/README.md`](../app/README.md#real-service-configuration).

  ```sh
  printf '%s' '<CLIENT_ID>' | gcloud secrets versions add google-oauth-client-id \
    --project=dreamaboutsports-staging --data-file=-
  ```

## 3. Cloudflare

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
treat a falling hit ratio or rising R2 reads as sev-1.

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

# Populate the three UTC fixture files immediately. The dispatcher enqueues 12
# Cloud Tasks (5s apart) that hit /internal/fetch, giving ~every-5s polling.
gcloud scheduler jobs run dispatch-live-scores \
  --project=dreamaboutsports-staging --location=us-central1

# Control polling by pausing/resuming the single dispatcher job (saves
# API-Football quota outside match windows):
gcloud scheduler jobs pause  dispatch-live-scores --location=us-central1
gcloud scheduler jobs resume dispatch-live-scores --location=us-central1

curl -fsS https://scores-staging.alldayidreamaboutsports.com/catalog.json >/dev/null
curl -fsS https://scores-staging.alldayidreamaboutsports.com/fixtures-$(date -u +%F).json >/dev/null
```

Production `scores.alldayidreamaboutsports.com` remains empty until the
production backend is deployed and its jobs run. The downloads domain remains
empty until the first signed release is published with `app/scripts/publish.sh`.

DNS for `alldayidreamaboutsports.com`: apex → **GitHub Pages** (A records
185.199.108.153/.109/.110/.111). The website lives in the **public** repo
`thisisnsh/alldayidreamaboutsports.com` (Settings → Pages → Source = "Deploy
from a branch" `main`/root, custom domain + HTTPS enforced) — Pages isn't free on
this private repo. `scores-staging.`, `scores.`, `download-staging.`, and
`download.` -> R2 custom domains (Cloudflare-proxied).

## 4. API-Football

Subscribe to **Ultra** ($29/mo, cancel after the final) at
[api-football.com/pricing](https://www.api-football.com/pricing). Key → secret
`api-football-key`. World Cup = league `1`, season `2026`.

## 5. Sparkle keys (global, once)

```sh
# from a Sparkle release download
./bin/generate_keys   # prints public key, stores private key in Keychain
./bin/generate_keys -x sparkle_private_key  # export for backup
```

- Public key → `SUPublicEDKey` in `app/project.yml`.
- Private key stays in your **login Keychain** — the appcast is signed locally by
  `app/scripts/publish.sh`, not in CI. Keep a
  Keychain/password-manager backup — losing it strands all installed apps.

## 6. Apple signing (global, once)

GitHub Actions uses a **Developer ID Application** certificate to sign the app
and DMG, then submits both to Apple's notary service. These are repository-level
credentials shared by both environments.

### Signing certificate

1. In Xcode, open **Settings → Accounts**, select the Apple ID and team
   `983LBM5U6B`, then open **Manage Certificates**. Create or download a
   **Developer ID Application** certificate. Do not use an **Apple Development**
   certificate.
2. Confirm macOS can use the certificate and its private key:

   ```sh
   security find-identity -v -p codesigning
   ```

   The output must include:

   ```text
   Developer ID Application: Nishant Hada (983LBM5U6B)
   ```

3. In Keychain Access, select the **login** keychain and **My Certificates**.
   Expand the Developer ID Application certificate and confirm that it contains
   a private key. Right-click the parent certificate, choose **Export**, save it
   as a `.p12`, and protect it with a strong export password. If `.p12` is
   disabled, the certificate/private-key pair is not selected; export from
   **My Certificates**, not **Certificates** or **All Items**.
4. Convert the `.p12` to Base64 and copy it to the clipboard:

   ```sh
   base64 -i /path/to/developer-id-application.p12 | pbcopy
   ```

5. In **GitHub → repository Settings → Secrets and variables → Actions**, add:

   | Secret | Value |
   |---|---|
   | `MACOS_CERT_P12_B64` | Base64 value copied above |
   | `MACOS_CERT_PASSWORD` | Password used when exporting the `.p12` |

Keep a secure backup of the `.p12` and its password, then delete the unprotected
local export when it is no longer needed.

### Notarization credentials

Create an app-specific password for the Apple ID associated with the developer
team at [account.apple.com](https://account.apple.com). Add these GitHub
repository secrets:

| Secret | Value |
|---|---|
| `APPLE_ID` | Apple ID email address |
| `APPLE_TEAM_ID` | `983LBM5U6B` |
| `APPLE_APP_PASSWORD` | Generated app-specific password, not the Apple ID password |

The `app-release.yml` workflow imports the `.p12` into a temporary keychain,
signs the app and DMG, submits both with `notarytool`, and staples Apple's
notarization tickets.

### App identifier

At [developer.apple.com](https://developer.apple.com/account/resources/identifiers/list),
register `com.alldayidreamaboutsports.mac`. Push Notifications are not used (the
app polls the scores CDN), so no APNs key / Cloud Messaging setup is required.

## 7. Other backend secrets

```sh
openssl rand -hex 32 | gcloud secrets versions add session-jwt-secret --data-file=-
```

## GitHub secrets/vars summary

| Where | Name | Source |
|---|---|---|
| env secret | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DEPLOY_SERVICE_ACCOUNT` | setup-gcp.sh output |
| env var | `GCP_PROJECT_ID`, `GCP_REGION`, `R2_BUCKET_SCORES` | setup-gcp.sh output + scores bucket table |
| repo secret | `GOOGLE_SERVICE_INFO_PRODUCTION_PLIST_B64` | Production Firebase plist; app release workflow |
| repo secret | `GOOGLE_OAUTH_PRODUCTION_CLIENT_ID`, `GOOGLE_OAUTH_PRODUCTION_REVERSED_CLIENT_ID` | Production OAuth plist; app release workflow |
| repo secret | `MACOS_CERT_P12_B64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Apple |

The Sparkle private key and R2 credentials are **not** GitHub secrets: the
appcast is signed and uploaded to R2 locally (`app/scripts/publish.sh`), and the
backend reads its R2 creds from GCP Secret Manager (`r2-*`, via
`backend-deploy.yml`).

## Kill switch runbook

- **Kill**: Firebase console → Remote Config → `kill_switch=true` → Publish.
  Running apps lock within seconds (real-time RC). Backup if Firebase is down:
  upload `{"killSwitch":true,"message":"..."}` as `config.json` to `alldayidreamaboutsports-scores`.
- **Recover**: publish `kill_switch=false` in Firebase and clear `killSwitch`
  from the R2 `config.json` (or set it to `false`) if the backup was used.
  The app stays killed until every source that enabled the switch clears it.
- **Force update**: set `min_build` to the new build number after a bad release.
- **Celebration cost spike**: `celebration_enabled=false`.
