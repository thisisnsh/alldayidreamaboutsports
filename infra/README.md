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
   `com.alldayidreamaboutsports.mac`), download `GoogleService-Info.plist` →
   `app/Resources/` locally, base64 → GitHub secret `GOOGLE_SERVICE_INFO_PLIST_B64`.
2. **Cloud Messaging** → upload the APNs auth key (.p8 from Apple Developer →
   Keys → Apple Push Notifications service). Without this, zero push delivery.
3. **Remote Config** → import `remoteconfig.template.json`, publish.
4. **Firestore rules** → deploy `firestore.rules` (deny-all; backend uses Admin SDK):
   `firebase deploy --only firestore:rules`

## 2. Google OAuth (sign-in) — ⚠️ ship blocker

[Console → APIs & Services → OAuth consent screen](https://console.cloud.google.com/apis/credentials/consent):

- External, app name "All Day I Dream About Sports", domain
  `alldayidreamaboutsports.com`, privacy policy `https://alldayidreamaboutsports.com/privacy`.
- Scopes: only `openid`, `email`, `profile` (non-sensitive → no review wait).
- **Publishing status: In production** — in Testing mode sign-in caps at 100 users.
- Credentials → OAuth client ID → **iOS type** (used for macOS apps), bundle id
  `com.alldayidreamaboutsports.mac`. The client id goes to:
  - secret `google-oauth-client-id` (backend verifies the ID token audience)
  - `GIDClientID` in `app/project.yml`, and its reversed form in the URL scheme.

## 3. Cloudflare

```sh
./setup-r2.sh   # then follow its printed dashboard steps
```

DNS for `alldayidreamaboutsports.com`: apex → **GitHub Pages** (A records
185.199.108.153/.109/.110/.111, deployed by `web-deploy.yml`; repo Settings →
Pages → Source = "GitHub Actions", custom domain + HTTPS enforced), `scores.`
and `download.` → R2 custom domains (Cloudflare-proxied).

## 4. API-Football

Subscribe to **Ultra** ($29/mo, cancel after the final) at
[api-football.com/pricing](https://www.api-football.com/pricing). Key → secret
`api-football-key`. World Cup = league `1`, season `2026`.

## 5. Sparkle keys (global, once)

```sh
# from a Sparkle release download
./bin/generate_keys   # prints public key, stores private key in Keychain
./bin/generate_keys -x sparkle_ed_private_key  # export for CI
```

- Public key → `SUPublicEDKey` in `app/project.yml`.
- Private key file content → GitHub secret `SPARKLE_ED_PRIVATE_KEY`. Keep a
  Keychain/password-manager backup — losing it strands all installed apps.

## 6. Apple signing (global, once)

- Developer ID Application certificate → export .p12 → base64 → GitHub secrets
  `MACOS_CERT_P12_B64`, `MACOS_CERT_PASSWORD`.
- App-specific password for notarytool → `APPLE_ID`, `APPLE_TEAM_ID`,
  `APPLE_APP_PASSWORD`.
- Identifiers → register `com.alldayidreamaboutsports.mac` with the
  **Push Notifications** capability.

## 7. Other backend secrets

```sh
openssl rand -hex 32 | gcloud secrets versions add session-jwt-secret --data-file=-
```

## GitHub secrets/vars summary

| Where | Name | Source |
|---|---|---|
| env secret | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DEPLOY_SERVICE_ACCOUNT` | setup-gcp.sh output |
| env var | `GCP_PROJECT_ID`, `GCP_REGION` | setup-gcp.sh output |
| repo secret | `GOOGLE_SERVICE_INFO_PLIST_B64` | Firebase console |
| repo secret | `MACOS_CERT_P12_B64`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | Apple |
| repo secret | `SPARKLE_ED_PRIVATE_KEY` | generate_keys |
| repo secret | `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT` | Cloudflare R2 token |

## Kill switch runbook

- **Kill**: Firebase console → Remote Config → `kill_switch=true` → Publish.
  Running apps lock within seconds (real-time RC). Backup if Firebase is down:
  upload `{"killSwitch":true,"message":"..."}` as `config.json` to `alldayidreamaboutsports-scores`.
- **Force update**: set `min_build` to the new build number after a bad release.
- **Celebration cost spike**: `celebration_enabled=false`.
