# TODO before shipping 🚢

Ordered — later steps depend on earlier ones. Commands and details are in the
linked READMEs. Tournament is LIVE; target: tag `v1.0.0` within 3 days.

## 1. Accounts & money (≈30 min)

- [ ] Apple Developer membership active for team `983LBM5U6B`; register bundle id
      `com.alldayidreamaboutsports.mac` with **Push Notifications** capability
- [ ] Create APNs auth key (.p8) — developer.apple.com → Keys
- [ ] Subscribe to **API-Football Ultra** ($29/mo) — grab the API key
- [ ] Domain `alldayidreamaboutsports.com` registered, zone on Cloudflare

## 2. Google Cloud + Firebase (per env: staging, then prod) — `infra/README.md`

- [ ] `gcloud projects create dreamaboutsports-staging` (+ billing) → `./infra/setup-gcp.sh dreamaboutsports-staging us-central1`
- [ ] Add Firebase to the project; register macOS app; download `GoogleService-Info.plist` → `app/Resources/`
- [ ] Upload the APNs .p8 in Firebase → Cloud Messaging (no key = no push, silent failure)
- [ ] Import + publish `infra/remoteconfig.template.json` in Remote Config
- [ ] Deploy `infra/firestore.rules` (deny-all)
- [ ] **OAuth consent screen → "In production"** (Testing mode caps sign-in at 100 users — ship blocker)
- [ ] Create **iOS-type** OAuth client id for the bundle id → put it in:
      - [ ] secret `google-oauth-client-id`
      - [ ] `app/project.yml` → `GIDClientID` + reversed-id URL scheme (then `xcodegen`)
- [ ] Set real secret values: `api-football-key`, `session-jwt-secret` (`openssl rand -hex 32`), R2 trio (after step 3)

## 3. Cloudflare R2 — `infra/setup-r2.sh`

- [ ] Create buckets + custom domains `scores.` / `download.alldayidreamaboutsports.com`
- [ ] R2 API token → GCP secrets `r2-*` (backend). Releases upload to R2 locally via `app/scripts/publish.sh` using your own R2 env vars — no GitHub `R2_*` secrets needed
- [ ] After first release: `download.../latest` redirect rule → newest DMG (the website button points there)

## 4. GitHub repo settings

- [ ] Push this (private) repo to GitHub (`thisisnsh/onlyfansforsports` — or rename; WIF condition in `setup-gcp.sh` and the badge URLs assume this slug)
- [ ] Website: push `web/` contents to the **public** repo `thisisnsh/alldayidreamaboutsports.com`; Settings → Pages → **Source: Deploy from a branch** (`main`/root); custom domain `alldayidreamaboutsports.com`; Enforce HTTPS (remove the domain from this private repo's Pages first)
- [ ] DNS: apex A records → GitHub Pages (`185.199.108–111.153`, grey-cloud/DNS-only)
- [ ] Create `staging` + `prod` environments; add secrets/vars from the table in `infra/README.md`
- [ ] Repo secrets for releases: `GOOGLE_SERVICE_INFO_PLIST_B64`, `MACOS_CERT_P12_B64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` (Sparkle key + R2 creds are local-only, not CI secrets)

## 5. Signing & Sparkle (this Mac — mostly DONE)

- [x] Sparkle EdDSA keypair generated (2026-06-11); public key already in `app/project.yml`
- [ ] **Back up the Sparkle private key** (Keychain → "Private key for signing Sparkle updates", or `generate_keys -x`) — losing it strands every install. It stays in your Keychain (used locally by `publish.sh`/`release.sh`), not a CI secret
- [ ] `xcrun notarytool store-credentials notary-profile --apple-id <id> --team-id 983LBM5U6B --password <app-specific-pw>` (for `app/scripts/release.sh`)
- [ ] Export Developer ID cert as .p12 → CI secrets

## 6. End-to-end test on staging (during any live group-stage match)

- [ ] `gh workflow run backend-deploy.yml` → rerun `setup-gcp.sh` so the scheduler gets the real URL
- [ ] Sign in on a staging build, follow both playing teams
- [ ] Inject a test goal (`backend/README.md`) → celebration fires, tap → count round-trips
- [ ] Real goal latency < 30s behind broadcast; pill events show; popover scores reconcile
- [ ] Flip `kill_switch=true` in Remote Config → running app locks within seconds; flip back
- [ ] Set `min_build` above current → update gate appears; reset
- [ ] Notch pill on a notched Mac AND an external/non-notch display

## 7. Ship

- [ ] Prod pass of sections 2–3, deploy backend to prod
- [ ] Tag `v1.0.0` → CI builds the DMG artifact; download + test, then `./app/scripts/publish.sh <dmg>` → appcast + deltas on `download.` (or full-local `./app/scripts/release.sh 1.0.0`)
- [ ] Gatekeeper check on a clean Mac: `spctl --assess` → "Notarized Developer ID"
- [ ] Website live (public repo), download button works, privacy page reachable (OAuth consent links to it)
- [ ] Set Remote Config `latest_build` to the shipped build number
- [ ] 📣 Announce — and keep the kill-switch runbook (`infra/README.md`) handy during matches

## Post-MVP (cut from v1, revisit after launch)

- [ ] Global tap-rate ball-density pulses (currently: local balls + final count)
- [ ] Multi-display picker for the overlay (currently: main screen)
- [ ] Quiet hours; football-data.org fallback provider; localization
- [ ] Cancel API-Football after the final (July 19, 2026); flip `kill_switch` with a "see you next time" message
