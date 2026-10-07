# TODO before shipping 🚢

**Status checked 2026-10-07 against revision `494bd80`, live GCP/Cloudflare,
GitHub settings and deployment runs.** Most cloud provisioning is complete.
Checked items below have supporting evidence; unchecked items are either still
pending or explicitly unverified. This check changed documentation only.

The remaining release work includes privacy/telemetry disclosures and legacy
profile handling, a production deployment of the patched dependencies, staging
test preparation and manual end-to-end testing, website migration to the App
Store, and GitHub publication/security settings. R2 alert delivery and Apple
account/App Store setup could not be verified. See
[`OPEN_SOURCE_REVIEW.md`](OPEN_SOURCE_REVIEW.md) for evidence and limitations.

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
      Notifications capability is needed — the app polls. **Unverified:** local
      project settings do not establish current membership or App ID capabilities.
- [x] **Subscribe to API-Football "Ultra"** ($29/mo) and copy the API key. This
      is the live-scores data feed the backend polls. It runs year-round now, so
      this is a standing $29/mo, not a six-week rental. Both configured keys
      return an active Ultra subscription with a 75,000/day allowance.
- [x] **Domain** `alldayidreamaboutsports.com`: keep it **registered at
      Hostinger** (that's fine — you own and renew it there), but later you'll
      point its **nameservers at Cloudflare** so Cloudflare can serve the
      download/scores files for free. Registrar (Hostinger) and DNS host
      (Cloudflare) are two separate jobs; you only move the DNS job. Registration
      at Hostinger and delegation to Cloudflare are already verified.

## 2. Google Cloud + Firebase — do staging first, then repeat for prod — `infra/README.md`

This is the backend brain: a project that runs polling, plus Firebase for
product analytics and crash reports. You'll run
this whole section twice. **Note the short project name:** GCP caps project ids at
30 characters and `alldayidreamaboutsports-staging` is 31 — one too long — so we
use the shorter `dreamaboutsports-` prefix for the GCP project id only.
Everything else (bundle id, buckets, domain) still uses the full name.

- [x] **Create the projects and provision services:** `gcloud projects create dreamaboutsports-staging`
      (then enable billing) →
      `./infra/setup-gcp.sh dreamaboutsports-staging us-central1`.
      The script turns on the APIs and creates service accounts so you don't have
      to click through the console. Both projects are active with Cloud Run,
      the task queue, all four scheduler jobs, service accounts and deployment
      federation configured. Billing linkage itself could not be queried because
      the Cloud Billing API is disabled; no API was enabled during this check.
- [x] **Add Firebase staging and prod** and save their downloaded configs as
      `app/Resources/GoogleService-Info-Staging.plist`. This file points at
      `dreamaboutsports-staging`; the build now includes it only in `Staging`.
      Prod is also registered and configured as `GoogleService-Info-Production.plist`.
- [x] **Retire legacy celebration data** with `infra/retire-celebrations.mjs`
      after deploying the backend without shared counts. Both environments have
      no celebration documents (including missing parents), no `celebrate/`
      R2 objects, no retired celebration Remote Config parameters, and no
      obsolete runtime Firestore/Firebase Admin grants.
- [ ] **Decide how to handle legacy profiles:** Firestore still contains 2
      staging and 6 production `users` records. The celebration cleanup does
      not delete profiles. Both databases have deny-all client rules; document
      retention/deletion and align the privacy policy before release.
- [x] **Set the real secret values:** the provider-issued `api-football-key`
      and the three R2 credentials (you'll have
      those after section 3). Secrets are how the backend gets credentials
      without hard-coding them. All four latest secret versions are enabled in
      both projects; the API keys and R2 credentials work. An API-Football key
      comes from the provider; a random locally generated value will not work.
- [x] **Verify private backend invocation**: authenticated health succeeds in
      the successful staging (Oct 7) and prod (Oct 5) deployment smoke tests;
      anonymous health returns 403 in fresh checks of both services. Only the
      environment's scheduler and deploy identities have `run.invoker`.

## 3. Cloudflare R2 (storage + custom domains) — `infra/setup-r2.sh`

R2 is object storage like an S3 bucket, but Cloudflare serves it through their
CDN with **zero egress fees** — that's what keeps the bill near $0 even if the
app blows up (on plain GCP the same traffic could cost hundreds to thousands).
The app fetches fixtures and live scores from here whenever
the menu opens. The `scores.` custom domains are the reason the domain's DNS
lives on Cloudflare.

- [x] **Provision R2/CDN configuration** with `./infra/setup-r2.sh` and `CLOUDFLARE_API_TOKEN`,
      `CLOUDFLARE_ACCOUNT_ID`, and `CLOUDFLARE_ZONE_ID` to create the buckets,
      attach the custom domains, disable `r2.dev`, create Cache Rules, enable
      Smart Tiered Cache, and apply WAF rate limits. Both scores buckets and
      domains exist; all four existing buckets have `r2.dev` disabled. Cache
      rules, tiered caching, Smart Tiered Cache and the origin-only rate limit
      are enabled. The staging custom domain is currently **disabled**; see §6.
- [x] **Move DNS to Cloudflare:** add `alldayidreamaboutsports.com` as a site in
      Cloudflare, then change the **nameservers at Hostinger** to the two
      Cloudflare gives you. (You're not moving the domain — just who answers DNS.
      You keep renewing at Hostinger.) The zone is active and DNS delegates to
      `carter.ns.cloudflare.com` / `desiree.ns.cloudflare.com`.
- [x] **Set each GitHub environment's `R2_BUCKET_SCORES` var** to its scores
      bucket after the script completes. The custom domains only work because
      DNS is now on Cloudflare.
- [x] **Configure each environment's R2 credentials** (read+write on its scores bucket
      only) → save as GCP secrets
      `r2-access-key-id` / `r2-secret-access-key` / `r2-endpoint` so the backend
      can write score files. Both backends have published objects. Read-only
      access probes succeed for the intended bucket and return 403 for the
      other three existing buckets. Token policy metadata was not accessible;
      no write probe was performed.

## 4. GitHub repo settings

Two repos: this one (the app + backend) and a separate one that hosts the
marketing website on GitHub Pages. The repo lives at
`thisisnsh/alldayidreamaboutsports`; the WIF condition in `setup-gcp.sh` assumes
that exact `owner/repo` slug — if you rename it, reconcile the trust too.

- [ ] **Finish the live security rollout first** (next section). Going public
      before it is applied advertises the gaps those steps close.
- [ ] **Make the repo public**, then in Settings → Code security enable private
      vulnerability reporting, secret scanning with push protection, and
      Dependabot alerts. Everything in git history becomes public too; the
      deleted `confetti-pop.mp3` and old DMG background are still in history.
- [ ] **Protect `main`:** require the backend, app and secret-scan checks (copy
      the exact names from the first workflow runs), require a pull request,
      block force pushes. Settings → Actions: require approval before running
      workflows from outside contributors' forks.
- [x] **Publish the website with its custom domain:** follow the README in the separate public repo
      [`thisisnsh/alldayidreamaboutsports.com`](https://github.com/thisisnsh/alldayidreamaboutsports.com),
      then set its Pages custom domain to `alldayidreamaboutsports.com`. Pages
      reports built/verified and both the homepage and privacy page return 200
      over HTTPS. The website uses an Actions deployment workflow.
- [ ] **Enforce website HTTPS and verify origin DNS:** Pages currently reports
      `https_enforced=false` and certificate state `dns_changed`; HTTP serves
      200 without redirecting. Public apex DNS returns Cloudflare proxy IPs,
      rather than DNS-only Pages records. DNS record details are unavailable
      with the current tokens; verify the intended proxy/origin configuration
      and certificate renewal before enabling HTTPS enforcement.
- [x] **Create `staging` + `prod` environments** in repo settings and add the
      secrets/vars listed in the table in `infra/README.md`. This is how CI
      deploys to the right cloud project. Both contain the required GCP secrets
      and project/region/bucket vars and restrict deployments to `main`.
- [ ] **Require a reviewer on `prod`** where the GitHub plan supports it.
      No reviewer rule is currently present. Exact GCP federation conditions
      already restrict each environment to this repository, `main` and the
      deployment workflow.

## 4a. Live security rollout (before going public)

The scores guard and scoped backend IAM are already applied to both environments.
Alert verification and download migration/cleanup remain.

- [x] **Scores request guard:** with a Cloudflare token limited to Zone WAF
      Edit, run `python3 infra/secure_scores.py --plan`, then `--apply`. Verify
      canonical `/catalog.json` returns 200 and warms to HIT while a query-string
      variant and an `Origin` header get 403 (`infra/README.md`). The enabled
      live rule matches the canonical path/header policy for both hosts. Prod
      passes 200/HIT and 403 probes. Staging rejects query/Origin variants too,
      but canonical requests cannot succeed until its domain is re-enabled.
- [x] **Scoped backend IAM:** resource-level secret access, runtime/build
      impersonation, and source-bucket grants are present in both projects;
      the old project-wide Secret Accessor, Service Account User and Storage
      Admin grants are absent. Subsequent source deployments passed in both.
- [ ] **R2 alerts:** verify operations/billing alerts and actual delivery.
      **Unverified:** notification policy/history APIs return 403 with the
      available tokens. Disabled `r2.dev` and isolation between existing
      buckets are already verified in §3. Ordinary alerts do not impose a
      global spending cap; see review finding 5.
- [ ] **Migrate website dependencies, then delete retired download resources.**
      Both download buckets still exist; prod's download custom domain is
      enabled. The website still uses it for download links and promo media.
      Move those assets and replace download links with the App Store listing
      before deleting buckets/domains/DNS records and obsolete cache rules.

## 5. Mac App Store (one-time) — `app/README.md#mac-app-store`

The app ships only through the Mac App Store, built and uploaded from Xcode with
automatic signing — no certificates to export, no notarization, no CI.

- [x] **Register Firebase Apple apps** for `com.thisisnsh.alldaysports` in staging and
      prod, and replace both `GoogleService-Info-*.plist` files. Both live app
      registrations are active and their IDs match the local config files.
- [ ] **Create the App Store Connect record** (New macOS App,
      `com.thisisnsh.alldaysports`): listing, screenshots, privacy labels.
      **Unverified:** no App Store Connect account inspection was available.
- [ ] **Resolve privacy disclosures and telemetry controls** before submission:
      team IDs/settings still go into telemetry and Crashlytics breadcrumbs,
      and no collection preference is present. The live privacy policy still
      describes removed sign-in/shared counts. See review finding 1.

## 6. End-to-end test on staging (during any live league match)

Don't ship without watching the whole pipeline work on a real goal. Use a
**staging build** (section "How staging vs prod works" above).

- [x] **Deploy the backend to staging:** `gh workflow run backend-deploy.yml`,
      then re-run `setup-gcp.sh` so the match scheduler gets the real deployed
      URL. The latest successful source deployment is Oct 7 (`b2de0e3`);
      all four scheduler targets already use the deployed URL and audience.
- [ ] **Prepare staging for the live test:** re-enable its scores custom domain
      and resume the appropriate scheduler jobs. `dispatch-live-scores`,
      `sync-catalog` and `cache-health` are paused; only `sync-schedule` is
      enabled. Refresh the catalog (its stored copy is from June 18 and has no
      Cache-Control), then verify canonical CDN reads succeed and cache to HIT.
      Today's staging fixture object already exists.
- [ ] **Follow both teams that are playing** on a staging build.
- [ ] **Inject a test goal** (steps in `backend/README.md`) → the celebration
      should fire. The old tap-the-ball interaction has been removed; shared
      celebration uploads are no longer part of this test.
- [ ] **Then watch a real goal:** it should land < 30s behind the TV broadcast,
      the event pill should show, and the popover score should reconcile.
- [ ] **Test the emergency stop:** block the staging scores hostname with a
      Cloudflare WAF rule → a running app should go quiet without errors on
      screen; disable the rule and it recovers (`infra/README.md`).
- [ ] **Test the notch pill** on a notched Mac *and* on an external / non-notch
      display, since the layout differs.
- [ ] **Watch the dispatch gate open and close.** `/internal/dispatch` should
      return `{"enqueued":0}` outside a match window and `{"enqueued":12}` inside
      it. If it never opens, `sync-schedule` has not written the fixture files it
      reads. This is the control that keeps five leagues inside the API quota.
- [ ] **Check the API-Football request counter** against ~51,900/day on the first
      busy Saturday (69% of the Ultra quota).

## 7. Ship

- [x] **Provision prod and deploy its backend** (`dreamaboutsports-prod` + prod
      plist/secrets). The service is deployed, all four jobs are enabled, and
      the scores CDN serves cached catalog/fixture JSON.
- [ ] **Deploy the current verified backend to prod.** The latest observed prod
      deployment is Oct 5 (`1971b58`), whose lockfile still uses `proxy-addr`
      2.0.7. Today's patch and dependency upgrades have reached staging only.
      Promote after staging verification and repeat the deployment smoke test.
- [ ] **Archive in Xcode and upload** (Product → Archive → Distribute App →
      App Store Connect), test the build via TestFlight, then submit for review.
- [ ] **Check the website is live** (public repo): it links to the App Store
      listing and the privacy page is reachable. Reachability is verified, but
      current links still target direct downloads and the privacy text is stale.
- [ ] **📣 Announce** — and keep the emergency-stop runbook (`infra/README.md`)
      handy during matches.

## Post-MVP (cut from v1, revisit after launch)

- [x] Multi-display picker for the overlay: `SettingsPage` uses
      `OverlayDisplayTarget`, and overlays follow the selected screen. Manual
      notch/external-display validation remains in §6.
- [ ] Quiet hours; football-data.org fallback provider; localization.
- [ ] A sixth competition (Champions League) needs either the Mega plan or a
      per-league gate — five leagues already use 69% of the Ultra quota on a
      Saturday.
