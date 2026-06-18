# TODO before shipping 🚢

The big picture: this is a Mac menu-bar app that shows live World Cup scores and
fires a goal celebration on your screen. To go live you need (1) accounts to
build & sign the app, (2) a cloud backend that watches matches and pushes goals,
(3) cheap storage + a website for downloads, and (4) one real end-to-end test
during an actual match before you tag `v1.0.0`.

Do the sections in order — later steps reuse values from earlier ones. The exact
commands live in the linked READMEs; this file explains *why* each step exists so
you don't paste things blindly. Tournament is LIVE, so target `v1.0.0` within
3 days.

### How "staging" vs "prod" works (read this once)

You build the app in three flavors:

- **Debug** — fake/offline (no sign-in, no network, no API quota). For local
  UI work. This is what you get from a plain Xcode run.
- **Staging** — real services, but pointed at a throwaway
  `dreamaboutsports-staging` cloud project. This is the build you use for the
  section-6 live test.
- **Prod** — real services pointed at `dreamaboutsports-prod`. This is the actual
  `v1.0.0` you ship to people.

Because of that, most cloud things get created **twice** — once in staging, once
in prod (you'll see "per env" below). The app carries **two**
`GoogleService-Info.plist` files (a staging one and a prod one) and the
`Staging`/`Release` build configuration copies in the right one. The **one**
thing you make once and reuse for both is
the APNs push key (`.p8`) — it's tied to your Apple account, not to a project.

---

## 1. Accounts & money (≈30 min)

These are the paid/identity things nothing else works without.

- [ ] **Apple Developer membership** active for team `983LBM5U6B`. Then register
      the app's bundle id `com.alldayidreamaboutsports.mac` and turn on the
      **Push Notifications** capability — without this, goal alerts can't reach
      the app.
- [ ] **Create an APNs auth key (`.p8`)** at developer.apple.com → Keys. This is
      the credential Apple's push servers check. You upload it to Firebase later.
      Download it once and keep it safe — Apple only lets you download it one time.
- [ ] **Subscribe to API-Football "Ultra"** ($29/mo) and copy the API key. This
      is the live-scores data feed the backend polls. (Cancel it after the final.)
- [ ] **Domain** `alldayidreamaboutsports.com`: keep it **registered at
      Hostinger** (that's fine — you own and renew it there), but later you'll
      point its **nameservers at Cloudflare** so Cloudflare can serve the
      download/scores files for free. Registrar (Hostinger) and DNS host
      (Cloudflare) are two separate jobs; you only move the DNS job.

## 2. Google Cloud + Firebase — do staging first, then repeat for prod — `infra/README.md`

This is the backend brain: a project that holds your database (Firestore),
push messaging (FCM), and the remote on/off switches (Remote Config). You'll run
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
- [ ] **Upload the APNs `.p8`** in Firebase → Cloud Messaging. Skip this and push
      silently fails — no error, just no goal alerts ever arrive.
- [ ] **Import + publish** `infra/remoteconfig.template.json` in Remote Config.
      These are the live switches (kill switch, minimum build, celebration
      toggles) you can flip without shipping an update.
- [ ] **Deploy** `infra/firestore.rules` (they deny all direct access — the app
      only ever talks to the backend, never the database directly).
- [ ] **Push the OAuth consent screen to "In production"** (in Google Auth
      Platform). While it's in "Testing" mode, only 100 people total can ever
      sign in — that's a hard ship-blocker.
- [ ] **Finish Google OAuth per environment.** You already created the staging
      iOS-type OAuth client for `com.alldayidreamaboutsports.mac`; its values are
      now configured in `app/project.yml`. Add its `CLIENT_ID` as the staging
      Secret Manager secret `google-oauth-client-id` so the backend accepts the
      same sign-ins. For prod, create another OAuth client in the prod project,
      put its `CLIENT_ID` in the prod backend secret, and replace the two
      production placeholders in `app/project.yml`. `REVERSED_CLIENT_ID` is not
      a secret: it is the callback URL scheme that lets Google reopen the app.
      See [app/README.md](app/README.md#real-service-configuration) for the exact
      values and build commands.
- [ ] **Set the real secret values:** `api-football-key`, `session-jwt-secret`
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
The app fetches fixtures, live scores, and celebration counts from here whenever
the menu opens, and downloads ship from here too. Custom domains (`scores.` /
`download.`) are the reason the domain's DNS lives on Cloudflare.

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
      can write score files. Releases upload to R2 from your Mac via
      `app/scripts/publish.sh` using your own local R2 env vars — no GitHub
      `R2_*` secrets needed.
- [ ] **After the first release:** add a redirect rule so
      `download.../latest` always points at the newest DMG (the website's
      download button links there, so it never goes stale).

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
- [ ] **Add the release secrets** (for building & notarizing the prod app in CI):
      `GOOGLE_SERVICE_INFO_PRODUCTION_PLIST_B64`,
      `GOOGLE_OAUTH_PRODUCTION_CLIENT_ID`,
      `GOOGLE_OAUTH_PRODUCTION_REVERSED_CLIENT_ID`, `MACOS_CERT_P12_B64`,
      `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`.
      (The Sparkle signing key and R2 creds stay on your Mac.)

## 5. Signing & Sparkle (on this Mac — mostly DONE)

This is the code-signing/auto-update plumbing so macOS trusts the app and it can
update itself.

- [x] Sparkle EdDSA keypair generated (2026-06-11); public key already in
      `app/project.yml`.
- [ ] **Back up the Sparkle private key** (Keychain → "Private key for signing
      Sparkle updates", or `generate_keys -x`). This key signs every update — if
      you lose it, *no existing install can ever update again* and you'd have to
      get everyone to reinstall by hand. It lives in your Keychain (used locally
      by `publish.sh`), not in CI.
- [ ] **Export your Developer ID certificate** as a `.p12` → add to CI secrets so
      CI can sign release builds.

## 6. End-to-end test on staging (during any live group-stage match)

Don't ship without watching the whole pipeline work on a real goal. Use a
**staging build** (section "How staging vs prod works" above).

- [ ] **Deploy the backend to staging:** `gh workflow run backend-deploy.yml`,
      then re-run `setup-gcp.sh` so the match scheduler gets the real deployed
      URL.
- [ ] **Sign in** on a staging build and follow both teams that are playing.
- [ ] **Inject a test goal** (steps in `backend/README.md`) → the celebration
      should fire, and tapping it should round-trip a count back to the backend.
- [ ] **Then watch a real goal:** it should land < 30s behind the TV broadcast,
      the event pill should show, and the popover score should reconcile.
- [ ] **Test the kill switch:** flip `kill_switch=true` in Remote Config → a
      running app should lock within seconds; flip it back and it recovers. This
      is your emergency "turn it off" button during matches.
- [ ] **Test the update gate:** set `min_build` above the current build → the
      "please update" gate should appear; reset it afterward.
- [ ] **Test the notch pill** on a notched Mac *and* on an external / non-notch
      display, since the layout differs.

## 7. Ship

- [ ] **Redo sections 2–3 for prod** (`dreamaboutsports-prod` + prod
      plist/secrets) and deploy the backend to prod.
- [ ] **Tag `v1.0.0`** → CI builds the DMG. Download and test it, then
      `./app/scripts/publish.sh <dmg> --release` to push the appcast + delta
      updates to the `download.` domain.
- [ ] **Verify Gatekeeper** on a *clean* Mac: `spctl --assess` should say
      "Notarized Developer ID" — that's macOS confirming the app is trusted.
- [ ] **Check the website is live** (public repo): download button works and the
      privacy page is reachable (the OAuth consent screen links to it).
- [ ] **Verify the Sparkle appcast** contains the shipped build, and keep Remote
      Config `min_build` unchanged unless you need to force older installs to
      update.
- [ ] **📣 Announce** — and keep the kill-switch runbook (`infra/README.md`)
      handy during matches.

## Post-MVP (cut from v1, revisit after launch)

- [ ] Global tap-rate ball-density pulses (currently: local balls + final count).
- [ ] Multi-display picker for the overlay (currently: main screen only).
- [ ] Quiet hours; football-data.org fallback provider; localization.
- [ ] Cancel API-Football after the final (July 19, 2026); flip `kill_switch`
      with a "see you next time" message.
