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
   with 5 fan teams; the popover shows a seeded LIVE match (Brazil 2–1 USA,
   73′) plus scheduled and finished fixtures, and celebration counts are
   pre-populated. ~8s after launch, random match events start firing
   automatically (fan goals weighted highest), so celebrations and pills
   appear hands-free.
2. **Everything is a code knob in `Sources/Dev/DevConfig.swift`**: the fake
   profile, the fan-team list, auto-events on/off, first-event delay, interval
   range, and event weights. Fixtures/counts seed data lives next door in
   `Sources/Dev/FakeBackend.swift`. Edit, ⌘R, observe.
3. Settings shows a small 🧪 pill so you always know you're in a dev session
   (no dev controls — the auto loop and `DevConfig` are the controls). The
   simulated events are the exact payloads FCM would deliver, through the real
   EventRouter/Overlay pipeline; `Settings → Celebration → Preview animation`
   fires one on demand.
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
| FCM / Remote Config / Crashlytics / Analytics | `GoogleService-Info.plist` absent → Firebase never configured |
| Sparkle appcast fetch | updater not started in dev builds (`startingUpdater: false`) |
| Profile photo (`AsyncImage`) | dev profile has `photoURL: nil` |

Debug builds also skip login-item registration (`LaunchAtLogin`), so your dev
build never sneaks into Login Items. The only outbound thing left is clicking
a fixture, which opens FIFA.com in your browser — deliberate.

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
| `Sources/AppDelegate.swift` | transient AppKit menu, Firebase/APNs bootstrap, Sparkle updater, reopen handling |
| `Sources/Services/` | session/auth, backend API, local prefs, kill switch (`ControlPlane`), event routing, tap batching |
| `Sources/Overlay/` | the two overlay panels: full-screen click-through display + small clickable ball; celebration, notch pill, particles |
| `Sources/Views/` | login, popover, team picker, settings, kill/update gate |

Key invariants:
- Overlay panels use `sharingType = .none` (invisible to screen sharing) and
  never take focus (`nonactivatingPanel`).
- ONE event queue, displayed in sets: up to `notchStackMax` pills show at
  once for `pillHoldSeconds`, then the next set follows — nothing is ever
  dropped. A ✕ under the stack ends the set early. Fan goals in the
  displayed set fire one confetti burst each (fire-and-forget) and share a
  single center ball carrying every scorer's flag; taps celebrate them all.
- Celebration taps are batched: ONE `/celebrate` request per celebrated
  team, sent when the ball disappears.
- `ControlPlane` gates everything; `kill_switch`/`min_build` from Remote Config
  (real-time) with `config.json` on the scores CDN as backup.
- Fixture date files bootstrap and persist the daily schedule once. While the
  menu is open, only followed-team `matches/{fixtureId}.json` objects that are
  live or starting within one minute are polled. Finished fixtures and
  celebration totals remain in the local cache; celebration totals refresh
  only when the cached and newly fetched scores differ.

## Code signing & notarization (one-time setup)

1. **Certificate**: Xcode → Settings → Accounts → team 983LBM5U6B → download
   "Developer ID Application". Verify: `security find-identity -v -p codesigning`.
2. **Notary profile**:
   ```sh
   xcrun notarytool store-credentials notary-alldayidreamaboutsports \
     --apple-id <your-apple-id> --team-id 983LBM5U6B \
     --password <app-specific-password>   # appleid.apple.com → App-Specific Passwords
   ```
3. **Push capability**: developer.apple.com → Identifiers →
   `com.alldayidreamaboutsports.mac` → enable Push Notifications; create an
   APNs auth key (.p8) and upload it in Firebase → Cloud Messaging.

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
1. Tag `v1.0.0` → `.github/workflows/app-release.yml` builds the code-signed,
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
