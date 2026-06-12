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

## Testing — two flavors, one flag

The app only touches the world through three protocols (`Sources/Services/Backend.swift`):
`GoogleAuthProviding`, `BackendAPI`, `ScoresProviding`. The build configuration
picks the implementation — that's the release flag:

| | `-configuration Debug` | `-configuration Release` |
|---|---|---|
| Compilation condition | `DEV_BACKEND` | — |
| Sign-in | **bypassed** — already signed in as "Dev Fan" at launch, no login window | real Google OAuth |
| Fan teams | hardcoded list in `Sources/Dev/DevConfig.swift` | user-picked, roams via backend |
| Match events | auto-fire randomly on a timer (+ manual Settings buttons) | FCM pushes |
| GET (prefs/teams/fixtures/counts) | hardcoded seed data (`Sources/Dev/FakeBackend.swift`) | Cloud Run + scores CDN |
| POST (prefs/celebrate) | appends to the in-memory fakes — next GET sees it | real writes |
| Network / API-Football quota | **zero** (verified: no TCP connections at runtime) | via backend |

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

**Testing the real stack locally:** build with `-configuration Release`
(plus `GoogleService-Info.plist` in `Resources/` and a real `GIDClientID` in
`project.yml` — see below). Settings keeps a "Preview animation" button in all
flavors.

- `GoogleService-Info.plist` (Firebase console → macOS app) goes in
  `Resources/`. It's gitignored. Missing = push/remote-config silently disabled.
- Replace `YOUR_CLIENT_ID` in `project.yml` (both `GIDClientID` and the
  reversed URL scheme) with the iOS-type OAuth client id, then rerun `xcodegen`.

## Source map

| Dir | What |
|---|---|
| `Sources/App.swift` | `MenuBarExtra` + window scenes (login, picker, settings, gate) |
| `Sources/AppDelegate.swift` | Firebase/APNs bootstrap, Sparkle updater, reopen handling |
| `Sources/Services/` | session/auth, backend API, FCM topics, kill switch (`ControlPlane`), event routing, tap batching |
| `Sources/Overlay/` | the two overlay panels: full-screen click-through display + small clickable ball; celebration, notch pill, particles |
| `Sources/Views/` | login, popover, team picker, settings, kill/update gate |

Key invariants:
- Overlay panels use `sharingType = .none` (invisible to screen sharing) and
  never take focus (`nonactivatingPanel`).
- Celebration taps are batched: ONE `/celebrate` request per goal, sent when
  the ball disappears.
- `ControlPlane` gates everything; `kill_switch`/`min_build` from Remote Config
  (real-time) with `config.json` on the scores CDN as backup.

## Code signing & notarization (one-time setup)

1. **Certificate**: Xcode → Settings → Accounts → team 983LBM5U6B → download
   "Developer ID Application". Verify: `security find-identity -v -p codesigning`.
2. **Notary profile** (used by `scripts/release.sh`):
   ```sh
   xcrun notarytool store-credentials notary-profile \
     --apple-id <your-apple-id> --team-id 983LBM5U6B \
     --password <app-specific-password>   # appleid.apple.com → App-Specific Passwords
   ```
3. **Push capability**: developer.apple.com → Identifiers →
   `com.alldayidreamaboutsports.mac` → enable Push Notifications; create an
   APNs auth key (.p8) and upload it in Firebase → Cloud Messaging.

## Sparkle updates

- `SUPublicEDKey` in `project.yml` is the public half of the key generated on
  this machine (2026-06-11); the private key lives in your login Keychain as
  "Private key for signing Sparkle updates". **Back it up** — losing it strands
  every installed copy:
  ```sh
  # export for backup / GitHub secret SPARKLE_ED_PRIVATE_KEY (CI signing)
  build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle_private_key
  ```
- Feed: `https://download.alldayidreamaboutsports.com/appcast.xml` (R2 bucket
  `alldayidreamaboutsports-downloads`), checked hourly, auto-installs.
- Force-update: bump `min_build` in Remote Config; older builds show the
  blocking gate wired to Sparkle.

## Releasing

**Local (mirrors the AI Thing flow, DMG-based):**
```sh
export R2_ENDPOINT=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
./scripts/release.sh 1.0.0          # build → notarize app → DMG → notarize DMG
                                    # → staple → appcast → upload to R2
```
Keeps every shipped DMG in `~/Releases/AllDayIDreamAboutSports` so
`generate_appcast` can emit delta updates.

**CI:** push a tag `v1.0.0` → `.github/workflows/app-release.yml` does the same
on a macOS runner (needs the GitHub secrets listed in `infra/README.md`) and
also attaches the DMG to a GitHub Release.

Build numbers: CI uses the workflow run number; local uses `yymmddHHMM`. Both
are monotonic — `min_build` comparisons stay sane.
