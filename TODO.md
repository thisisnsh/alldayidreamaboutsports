# TODO before shipping 🚢

The big picture: this is a Mac menu-bar app that shows live scores from Europe's
top five leagues and fires a goal celebration on your screen. To go live you need
(1) accounts to build & sign the app, (2) a cloud backend that watches matches and
publishes their state to a CDN, (3) cheap storage + a website for downloads, and
(4) one real end-to-end test during an actual match before you tag `v1.0.0`.

Do the sections in order — later steps reuse values from earlier ones. The exact
commands live in the linked READMEs; this file explains *why* each step exists so
you don't paste things blindly.

**Nothing here involves push.** Goals reach the app because every Mac polls a
CDN-cached JSON object, not because we send anything — so there is no APNs key,
no Push Notifications capability, and no Firebase Cloud Messaging to configure.

### How "staging" vs "prod" works (read this once)

You build the app in three flavors:

- **Debug** — fake/offline (no network, no API quota). For local
  UI work. This is what you get from a plain Xcode run.
- **Staging** — real services, but pointed at a throwaway
  `dreamaboutsports-staging` cloud project. This is the build you use for the
  section-6 live test.
- **Prod** — real services pointed at `dreamaboutsports-prod`. This is the actual
  `v1.0.0` you ship to people.

Because of that, most cloud things get created **twice** — once in staging, once
in prod (you'll see "per env" below). The app carries **two**
`GoogleService-Info.plist` files (a staging one and a prod one) and the
`Staging`/`Release` build configuration copies in the right one. The things you
make once and reuse for both are the Apple App ID and the App Store Connect
record — they're tied to your account, not to a project.

---

## 1. Accounts & money (≈30 min)

These are the paid/identity things nothing else works without.

- [ ] **Apple Developer membership** active for team `983LBM5U6B`. Then register
      the app's bundle id `com.thisisnsh.alldaysports` (explicit, Keychain Sharing). No Push
      Notifications capability is needed — the app polls.
- [ ] **Subscribe to API-Football "Ultra"** ($29/mo) and copy the API key. This
      is the live-scores data feed the backend polls. It runs year-round now, so
      this is a standing $29/mo, not a six-week rental.
- [ ] **Domain** `alldayidreamaboutsports.com`: keep it **registered at
      Hostinger** (that's fine — you own and renew it there), but later you'll
      point its **nameservers at Cloudflare** so Cloudflare can serve the
      download/scores files for free. Registrar (Hostinger) and DNS host
      (Cloudflare) are two separate jobs; you only move the DNS job.

## 2. Google Cloud + Firebase — do staging first, then repeat for prod — `infra/README.md`

This is the backend brain: a project that runs polling and
the remote on/off switches (Remote Config). You'll run
this whole section twice. **Note the short project name:** GCP caps project ids at
30 characters and `alldayidreamaboutsports-staging` is 31 — one too long — so we
use the shorter `dreamaboutsports-` prefix for the GCP project id only.
Everything else (bundle id, buckets, domain) still uses the full name.

- [ ] **Create the project:** `gcloud projects create dreamaboutsports-staging`
      (then enable billing) →
      `./infra/setup-gcp.sh dreamaboutsports-staging us-central1`.
      The script turns on the APIs and creates service accounts so you don't have
      to click through the console.
- [x] **Add Firebase staging** and save its downloaded config as
      `app/Resources/GoogleService-Info-Staging.plist`. This file points at
      `dreamaboutsports-staging`; the build now includes it only in `Staging`.
      Repeat for prod later as `GoogleService-Info-Production.plist`.
- [ ] **Import + publish** `infra/remoteconfig.template.json` in Remote Config.
      These are the live switches (kill switch, minimum build, animation
      settings) you can flip without shipping an update.
- [ ] **Retire legacy celebration data** with `infra/retire-celebrations.mjs`
      after deploying the backend without shared counts.
- [ ] **Set the real secret values:** `api-football-key`
      (generate with `openssl rand -hex 32`), and the three R2 keys (you'll have
      those after section 3). Secrets are how the backend gets credentials
      without hard-coding them.
- [ ] **Verify the staging API domain** after deploying it:
      `curl -fsS https://api-staging.alldayidreamaboutsports.com/healthz/`.
      `APP_API_BASE_URL` under `Staging` already points at that custom domain,
      so finish its Cloud Run domain mapping and DNS before the end-to-end test.

## 3. Cloudflare R2 (storage + custom domains) — `infra/setup-r2.sh`

R2 is object storage like an S3 bucket, but Cloudflare serves it through their
CDN with **zero egress fees** — that's what keeps the bill near $0 even if the
app blows up (on plain GCP the same traffic could cost hundreds to thousands).
The app fetches fixtures and live scores from here whenever
the menu opens. The `scores.` custom domains are the reason the domain's DNS
lives on Cloudflare.

- [ ] **Run `./infra/setup-r2.sh`** with `CLOUDFLARE_API_TOKEN`,
      `CLOUDFLARE_ACCOUNT_ID`, and `CLOUDFLARE_ZONE_ID` to create the buckets,
      attach the custom domains, disable `r2.dev`, create Cache Rules, enable
      Smart Tiered Cache, and apply WAF rate limits.
- [ ] **Move DNS to Cloudflare:** add `alldayidreamaboutsports.com` as a site in
      Cloudflare, then change the **nameservers at Hostinger** to the two
      Cloudflare gives you. (You're not moving the domain — just who answers DNS.
      You keep renewing at Hostinger.)
- [ ] **Set each GitHub environment's `R2_BUCKET_SCORES` var** to its scores
      bucket after the script completes. The custom domains only work because
      DNS is now on Cloudflare.
- [ ] **Create an R2 API token** (read+write all four buckets) → save as GCP secrets
      `r2-access-key-id` / `r2-secret-access-key` / `r2-endpoint` so the backend
      can write score files.

## 4. GitHub repo settings

Two repos: this **private** one (the app + backend) and a **public** one that
hosts the marketing website on free GitHub Pages.

- [ ] **Push this private repo** to GitHub as `thisisnsh/alldayidreamaboutsports`.
      Heads up: the WIF condition in `setup-gcp.sh` and the README badge URLs
      assume that exact `owner/repo` slug — if you rename it, update those too.
- [ ] **Publish the website:** follow the README in the separate public repo
      [`thisisnsh/alldayidreamaboutsports.com`](https://github.com/thisisnsh/alldayidreamaboutsports.com),
      then set its Pages custom domain to `alldayidreamaboutsports.com` and
      enforce HTTPS.
- [ ] **DNS for the website:** in **Cloudflare** (DNS now lives there), point the
      apex at GitHub Pages — A records to `185.199.108–111.153`, set to
      **DNS-only / grey cloud** (not proxied), so Pages can verify the domain.
- [ ] **Create `staging` + `prod` environments** in repo settings and add the
      secrets/vars listed in the table in `infra/README.md`. This is how CI
      deploys to the right cloud project.
## 5. Mac App Store (one-time) — `app/README.md#mac-app-store`

The app ships only through the Mac App Store, built and uploaded from Xcode with
automatic signing — no certificates to export, no notarization, no CI.

- [ ] **Register Firebase Apple apps** for `com.thisisnsh.alldaysports` in staging and
      prod, and replace both `GoogleService-Info-*.plist` files.
- [ ] **Create the App Store Connect record** (New macOS App,
      `com.thisisnsh.alldaysports`): listing, screenshots, privacy labels.

## 6. End-to-end test on staging (during any live league match)

Don't ship without watching the whole pipeline work on a real goal. Use a
**staging build** (section "How staging vs prod works" above).

- [ ] **Deploy the backend to staging:** `gh workflow run backend-deploy.yml`,
      then re-run `setup-gcp.sh` so the match scheduler gets the real deployed
      URL.
- [ ] **Follow both teams that are playing** on a staging build.
- [ ] **Inject a test goal** (steps in `backend/README.md`) → the celebration
      should fire, and tapping the ball should animate locally without an upload.
- [ ] **Then watch a real goal:** it should land < 30s behind the TV broadcast,
      the event pill should show, and the popover score should reconcile.
- [ ] **Test the kill switch:** flip `kill_switch=true` in Remote Config → a
      running app should lock within seconds; flip it back and it recovers. This
      is your emergency "turn it off" button during matches.
- [ ] **Test the update gate:** set `min_build` above the current build → the
      "please update" gate should appear; reset it afterward.
- [ ] **Test the notch pill** on a notched Mac *and* on an external / non-notch
      display, since the layout differs.
- [ ] **Watch the dispatch gate open and close.** `/internal/dispatch` should
      return `{"enqueued":0}` outside a match window and `{"enqueued":12}` inside
      it. If it never opens, `sync-schedule` has not written the fixture files it
      reads. This is the control that keeps five leagues inside the API quota.
- [ ] **Check the API-Football request counter** against ~51,900/day on the first
      busy Saturday (69% of the Ultra quota).

## 7. Ship

- [ ] **Redo sections 2–3 for prod** (`dreamaboutsports-prod` + prod
      plist/secrets) and deploy the backend to prod.
- [ ] **Archive in Xcode and upload** (Product → Archive → Distribute App →
      App Store Connect), test the build via TestFlight, then submit for review.
- [ ] **Check the website is live** (public repo): it links to the App Store
      listing and the privacy page is reachable.
- [ ] Keep Remote Config `min_build` unchanged unless you need to force older
      installs to update — and only raise it once that build is live.
- [ ] **📣 Announce** — and keep the kill-switch runbook (`infra/README.md`)
      handy during matches.

## Post-MVP (cut from v1, revisit after launch)

- [ ] Multi-display picker for the overlay (currently: main screen only).
- [ ] Quiet hours; football-data.org fallback provider; localization.
- [ ] A sixth competition (Champions League) needs either the Mega plan or a
      per-league gate — five leagues already use 69% of the Ultra quota on a
      Saturday.
