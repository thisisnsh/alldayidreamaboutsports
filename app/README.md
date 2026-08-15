# macOS app

SwiftUI menu bar app, macOS 14+, team `983LBM5U6B`. The Xcode project is
generated — never edit the `.xcodeproj`, edit `project.yml` and rerun `xcodegen`.

## Build & run

```sh
brew install xcodegen
xcodegen                                   # → AllDayIDreamAboutSports.xcodeproj
open AllDayIDreamAboutSports.xcodeproj     # or:
xcodebuild -scheme AllDayIDreamAboutSports -configuration Debug build
```

## Testing — three build configurations

The app only touches the world through three protocols (`Sources/Services/Backend.swift`):
`GoogleAuthProviding`, `BackendAPI`, `ScoresProviding`. The build configuration
picks the implementation — that's the release flag:

| | `Debug` | `Staging` | `Release` |
|---|---|---|---|
| Services | fake/offline | `dreamaboutsports-staging` | `dreamaboutsports-prod` |
| Sign-in | bypassed as "Dev Fan" | staging Google OAuth | production Google OAuth |
| Firebase config | none | `GoogleService-Info-Staging.plist` | `GoogleService-Info-Production.plist` |
| Backend/data | in-memory seed data | staging URLs from `project.yml` | production URLs from `project.yml` |
| Intended use | normal Xcode development | end-to-end testing | shipped app |

**Day-to-day dev loop:**

1. Build & run **Debug** from Xcode (⌘R). No sign-in — you're already "Dev Fan"
   with the fan teams in `DevConfig.fanTeams`; the popover shows a seeded LIVE
   match (Brazil 2–1 USA, 73′) plus scheduled and finished fixtures, and
   celebration counts are pre-populated. ~8s after launch, random match events
   start firing automatically (fan goals weighted highest), so celebrations and
   pills appear hands-free.

   The seeded fixtures are still World Cup sides while the demo catalog now
   leads with the top five club leagues, so a fresh Debug run also exercises the
   one-time "the World Cup has ended" migration prompt (delete the
   `leagueMigrationPrompted` default to see it again).
2. **Everything is a code knob in `Sources/Dev/DevConfig.swift`**: the fake
   profile, the fan-team list, auto-events on/off, first-event delay, interval
   range, and event weights. Fixtures/counts seed data lives next door in
   `Sources/Dev/FakeBackend.swift`. Edit, ⌘R, observe.
3. Settings shows a small 🧪 pill so you always know you're in a dev session
   (no dev controls — the auto loop and `DevConfig` are the controls). The
   simulated events run through the real EventRouter/Overlay pipeline, exactly
   as a state change polled from the scores CDN would; `Settings → Celebration
   → Preview animation` fires one on demand.
4. Tap the ball during the window; the fake `/celebrate` logs and accumulates,
   and the count text reflects it (POST → GET round-trip, all in memory).
   Each click counts as 4 celebrations and lands 4 mini balls on the bottom
   edge of the screen.

**Why Debug needs no backend** (each network path, and what disables it):

| Path | In Debug |
|---|---|
| Google sign-in (`GIDSignIn`) | never invoked — `FakeGoogleAuth`, and bootstrap bypasses the flow entirely |
| Backend API (`URLSession` in `APIClient`) | never instantiated — `FakeBackendAPI` |
| Scores CDN (`URLSession` in `CDNScoresClient`) | never instantiated — `FakeScores` (incl. the kill-switch backup `config.json`) |
| Remote Config / Crashlytics / Analytics | `GoogleService-Info.plist` absent → Firebase never configured (there is no Messaging — push was dropped for polling + CDN) |
| Sparkle appcast fetch | updater not started in dev builds (`startingUpdater: false`) |
| Profile photo (`AsyncImage`) | dev profile has `photoURL: nil` |

Debug builds also skip login-item registration (`LaunchAtLogin`), so your dev
build never sneaks into Login Items. Nothing in a Debug session reaches the
network at all.

## Real-service configuration

Each environment needs two files from its Firebase/Google Cloud project:

1. Firebase console → macOS app → download `GoogleService-Info.plist`. Save it
   as `Resources/GoogleService-Info-Staging.plist` or
   `Resources/GoogleService-Info-Production.plist`.
2. Google Auth Platform → Clients → create an **iOS-type** OAuth client for
   bundle id `com.alldayidreamaboutsports.mac`, then download its plist. You do
   not add that downloaded OAuth plist to the app. Copy its two values into the
   matching configuration in `project.yml`:
   - `CLIENT_ID` → `GOOGLE_CLIENT_ID`
   - `REVERSED_CLIENT_ID` → `GOOGLE_REVERSED_CLIENT_ID`

The reversed client ID is not another credential. It is the same client ID
rearranged into a macOS URL scheme so Google can return control to the app after
browser sign-in. The OAuth plists for both environments:

```text
# staging (dreamaboutsports-staging)
CLIENT_ID          = 291291942072-cqsmesng18bagi6psv69n5ch4kcnvj2s.apps.googleusercontent.com
REVERSED_CLIENT_ID = com.googleusercontent.apps.291291942072-cqsmesng18bagi6psv69n5ch4kcnvj2s

# production (dreamaboutsports-prod)
CLIENT_ID          = 680190781802-t248eiqmjqaorv3ucok84t1ap9rrgc8q.apps.googleusercontent.com
REVERSED_CLIENT_ID = com.googleusercontent.apps.680190781802-t248eiqmjqaorv3ucok84t1ap9rrgc8q
```

Both staging and production values are already configured in `project.yml`. The
Firebase plists themselves are gitignored, so each must exist locally (and as a
CI secret) before building — see "CI secrets" below. Regenerate and build the
environment you want:

```sh
xcodegen
xcodebuild -scheme AllDayIDreamAboutSports -configuration Staging build
xcodebuild -scheme AllDayIDreamAboutSports -configuration Release build
```

### CI secrets

`app-release.yml` builds the `Release` config and so needs the production
Firebase/OAuth values as GitHub Actions secrets (the plists are gitignored and
never reach the runner otherwise):

| Secret | Value |
|---|---|
| `GOOGLE_SERVICE_INFO_PRODUCTION_PLIST_B64` | base64 of `GoogleService-Info-Production.plist` |
| `GOOGLE_OAUTH_PRODUCTION_CLIENT_ID` | production `CLIENT_ID` |
| `GOOGLE_OAUTH_PRODUCTION_REVERSED_CLIENT_ID` | production `REVERSED_CLIENT_ID` |

Regenerate the base64 whenever the plist changes:

```sh
base64 -i app/Resources/GoogleService-Info-Production.plist | tr -d '\n'
```

The build phase copies only the selected environment's Firebase plist into the
app bundle as `GoogleService-Info.plist`; a Release build does not contain or
use staging Firebase configuration. Both source plists are gitignored.

## Staging diagnostics

The app writes structured `debug`, `info`, and `error` entries through Apple's
unified logging system. In Console.app, select the Mac and filter for subsystem
`com.alldayidreamaboutsports.mac`, or stream them in Terminal:

```sh
log stream --level debug --predicate 'subsystem == "com.alldayidreamaboutsports.mac"'
```

Staging builds also send log breadcrumbs to Firebase Crashlytics. Errors are
recorded as non-fatal Crashlytics issues, where their preceding debug/info
breadcrumbs are visible. Release builds explicitly disable Crashlytics
collection. Crashlytics is not a live arbitrary-log viewer; use Console.app or
`log stream` for the complete live stream.

The backend must accept the same client ID as the app. Add each environment's
`CLIENT_ID` to its GCP Secret Manager secret:

```sh
printf '%s' '<CLIENT_ID>' | gcloud secrets versions add google-oauth-client-id \
  --project=dreamaboutsports-staging --data-file=-
```

Use `dreamaboutsports-prod` and the production client ID for production.

`Staging` also has separate `APP_API_BASE_URL` and `APP_SCORES_BASE_URL` build
settings. They target the `api-staging` and `scores-staging` custom domains,
respectively. Finish the staging Cloud Run domain mapping and DNS before using
the build. Neither setting can silently call production.

## Source map

| Dir | What |
|---|---|
| `Sources/App.swift` | window scenes (login, picker, settings, gate) |
| `Sources/AppDelegate.swift` | transient AppKit menu, Firebase bootstrap (Remote Config + Crashlytics/Analytics — no Messaging), Sparkle updater, reopen handling |
| `Sources/Services/` | session/auth, backend API, local prefs, kill switch (`ControlPlane`), event routing, tap batching |
| `Sources/Overlay/` | the two overlay panels: full-screen click-through display + small clickable ball; celebration, notch pill, particles |
| `Sources/Views/` | login, popover, team picker, settings, kill/update gate |

Key invariants:
- Overlay panels use `sharingType = .none` (invisible to screen sharing) and
  never take focus (`nonactivatingPanel`).
- Two overlay queues feed displayed sets: goal events are selected first, then
  remaining slots fill from non-goals. The visible stack is chronological
  within the selected set, oldest at top and newest at bottom, and shows for
  `pillHoldSeconds`. A ✕ under the stack ends the set early. Fan goals start
  one shared center-ball celebration only when their goal pill reaches the
  displayed set; closing the ball does not dismiss or pause queued
  notifications.
- Celebration taps are batched: ONE `/celebrate` request per celebrated
  team, sent when the ball disappears.
- `ControlPlane` gates everything; `kill_switch`/`min_build` from Remote Config
  (real-time) with `config.json` on the scores CDN as backup.
- Fixture date files bootstrap and persist the daily schedule once. Only
  followed-team `matches/{fixtureId}.json` objects inside their live window are
  polled — from kickoff−5min (`LiveStore.preKickoffLead`) until FINISHED, capped
  at 3.5h. The backend publishes those objects from kickoff−5min too, so the
  two ends agree and no client 404s its way to kickoff. Finished fixtures and
  celebration totals remain in the local cache; celebration totals refresh only
  when the cached and newly fetched scores differ.
- The published `fixtures` list is fan-filtered. The full day's fixtures — up to
  ~48 across five leagues — stay in the working set for the poll loop, but only
  the user's own are published and written to the local cache.

## Code signing & notarization (one-time setup)

1. **Certificate**: Xcode → Settings → Accounts → team 983LBM5U6B → manage
   certificates → create "Developer ID Application". The certificate must appear
   under **My Certificates** in Keychain Access with an expandable private key.
   Export that complete identity as a password-protected `.p12`; never export or
   commit the private key separately. Verify the active identity with:
   ```sh
   security find-identity -v -p codesigning
   ```
2. **Developer ID provisioning profile**: developer.apple.com → Certificates,
   Identifiers & Profiles → Profiles. Create a Developer ID profile for
   `com.alldayidreamaboutsports.mac`, selecting the same certificate exported in
   step 1. The profile must authorize Keychain Sharing. The current profile is
   named `983LBM5U6B.com.alldayidreamaboutsports.mac.3`, UUID
   `1b1e1690-0cf1-4173-ba32-259af8429a4d`, and is valid until 2044-07-01.
3. **GitHub Actions secrets**: encode the P12 and profile without committing
   either file, then set:
   - `MACOS_CERT_P12_B64`: base64-encoded P12
   - `MACOS_CERT_PASSWORD`: P12 export password
   - `MACOS_PROVISIONING_PROFILE_B64`: base64-encoded `.provisionprofile`

   The release workflow verifies that the profile's certificate fingerprint
   matches the imported P12 before it builds.
4. **Notary profile**:
   ```sh
   xcrun notarytool store-credentials notary-alldayidreamaboutsports \
     --apple-id <your-apple-id> --team-id 983LBM5U6B \
     --password <app-specific-password>   # appleid.apple.com → App-Specific Passwords
   ```

There is no push capability to set up. The app polls the scores CDN, so it
needs no Push Notifications entitlement, no APNs auth key, and no Firebase
Cloud Messaging configuration.

### Rotating the Developer ID certificate

The current CI certificate (`0C64AFF32A40DEF952C231B8721C81E89518D4C0`)
expires 2027-02-01. Before then:

1. Create a new Developer ID Application certificate in Xcode and export its
   certificate/private-key identity as a P12.
2. Regenerate the Developer ID profile using that exact new certificate.
3. Replace `MACOS_CERT_P12_B64` and `MACOS_PROVISIONING_PROFILE_B64` in GitHub;
   replace `MACOS_CERT_PASSWORD` too if the P12 password changed.
4. Update the profile name/UUID in `project.yml`, `ExportOptions.plist`, and the
   release workflow, then run a release build to exercise all signing checks.

Do **not** revoke an old Developer ID certificate during routine rotation.
Timestamped releases keep working after certificate expiration, while revocation
can prevent existing signed releases from installing or launching.

## Sparkle updates

- `SUPublicEDKey` in `project.yml` is the public half of the key generated on
  this machine (2026-06-11); the private key lives in your login Keychain as
  "Private key for signing Sparkle updates". The appcast is signed **locally**
  (`publish.sh` reads the key from the Keychain) — it is no longer a CI secret.
  **Back it up** — losing it strands every installed copy:
  ```sh
  # export for backup (any Sparkle download's generate_keys works)
  ./bin/generate_keys -x sparkle_private_key
  ```
- Feed: `https://download.alldayidreamaboutsports.com/appcast.xml` (R2 bucket
  `alldayidreamaboutsports-downloads`), checked hourly, auto-installs.
- Force-update: bump `min_build` in Remote Config; older builds show the
  blocking gate wired to Sparkle.

## Releasing

CI builds the DMG; the Sparkle appcast + delta generation and the R2 upload are
**local** (the EdDSA key and R2 creds stay on your machine, not in CI).
`publish.sh` expects a local Sparkle install with
`$SPARKLE_HOME/bin/generate_appcast`; it does not download Sparkle.

**Normal flow:**
1. Tag `v1.0.0.1` → `.github/workflows/app-release.yml` builds the code-signed,
   notarized, stapled, styled DMG on a macOS runner and uploads it as a
   **workflow artifact** (no appcast, no R2, no GitHub Release).
2. Download the artifact, install the DMG, test it.
3. Publish it:
   ```sh
   cp scripts/.publish.env.example scripts/.publish.env
   # Fill in scripts/.publish.env with R2_* plus Cloudflare purge credentials once.

   ./scripts/publish.sh ~/Downloads/AllDayIDreamAboutSports-1.0.0.dmg \
     --notes ~/Downloads/AllDayIDreamAboutSports-1.0.0.html \
     --release
   # → appcast + deltas (vs prior DMGs) → upload DMG/appcast/deltas/notes to R2
   ```
   Then ensure `download.alldayidreamaboutsports.com/latest` redirects to the
   new DMG.

`publish.sh` defaults to the staging feed and bucket. Use `--release` or
`CHANNEL=release` only when you are intentionally publishing to production.

The script keeps every shipped DMG in `~/Releases/AllDayIDreamAboutSports` so
`generate_appcast` can emit delta updates.

Build numbers: CI uses the workflow run number, so `min_build` comparisons stay
sane.
