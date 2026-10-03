# macOS app

SwiftUI menu bar app, macOS 14+, team `983LBM5U6B`, bundle id
`com.thisisnsh.alldaysports`. Distributed only through the Mac App Store: built, tested,
archived and uploaded from Xcode. The Xcode project is
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
`BackendAPI` and `ScoresProviding`. The build configuration
picks the implementation — that's the release flag:

| | `Debug` | `Staging` | `Release` |
|---|---|---|---|
| Services | fake/offline | `dreamaboutsports-staging` | `dreamaboutsports-prod` |
| Firebase config | none | `GoogleService-Info-Staging.plist` | `GoogleService-Info-Production.plist` |
| Backend/data | in-memory seed data | staging URLs from `project.yml` | production URLs from `project.yml` |
| Intended use | normal Xcode development | end-to-end testing | shipped app |

**Day-to-day dev loop:**

1. Build & run **Debug** from Xcode (⌘R). You're already following the club sides in `DevConfig.fanTeams` (Liverpool, Man City,
   Arsenal, Inter). The popover shows the demo matchday: Manchester City vs
   Manchester United live, Inter vs Juventus decided on penalties, and two
   scheduled fixtures. `DevConfig.timeline` starts playing at launch, so pills,
   celebrations and celebration counts all appear hands-free.

   Every demo side is a club, so a fresh Debug run does NOT trip the one-time
   "the World Cup has ended" migration prompt. To exercise that, put a World Cup
   team id in `DevConfig.fanTeams` and delete the `leagueMigrationPrompted`
   default.
2. **Everything is a code knob in `Sources/Dev/DevConfig.swift`**: the fan-team
   list, the deterministic timeline itself, autostart,
   looping, and the two warm-up passes (`showcaseAtStart`, `clockWalkAtStart`).
   The fixtures those beats play out on, and the fake catalog behind the picker,
   live next door in `Sources/Dev/FakeBackend.swift`. Edit, ⌘R, observe.
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
| Backend API (`URLSession` in `APIClient`) | never instantiated — `FakeBackendAPI` |
| Scores CDN (`URLSession` in `CDNScoresClient`) | never instantiated — `FakeScores` (incl. the kill-switch backup `config.json`) |
| Remote Config / Crashlytics / Analytics | `GoogleService-Info.plist` absent → Firebase never configured (there is no Messaging — push was dropped for polling + CDN) |

Nothing in a Debug session reaches the network except that one `catalog.json`
read.

## Real-service configuration

Each environment needs its Firebase config: Firebase console → Apple app
`com.thisisnsh.alldaysports` → download `GoogleService-Info.plist`, and save it
as `Resources/GoogleService-Info-Staging.plist` or
`Resources/GoogleService-Info-Production.plist`.
The plists are gitignored, so each must exist locally before building.
Regenerate and build the environment you want:

```sh
xcodegen
xcodebuild -scheme AllDayIDreamAboutSports -configuration Staging build
xcodebuild -scheme AllDayIDreamAboutSports -configuration Release build
```

The build phase copies only the selected environment's Firebase plist into the
app bundle as `GoogleService-Info.plist`; a Release build does not contain or
use staging Firebase configuration. Both source plists are gitignored.

## Staging diagnostics

The app writes structured `debug`, `info`, and `error` entries through Apple's
unified logging system. In Console.app, select the Mac and filter for subsystem
`com.thisisnsh.alldaysports`, or stream them in Terminal:

```sh
log stream --level debug --predicate 'subsystem == "com.thisisnsh.alldaysports"'
```

Staging builds also send log breadcrumbs to Firebase Crashlytics. Errors are
recorded as non-fatal Crashlytics issues, where their preceding debug/info
breadcrumbs are visible. Release builds explicitly disable Crashlytics
collection. Crashlytics is not a live arbitrary-log viewer; use Console.app or
`log stream` for the complete live stream.

## Mac App Store

The app is sandboxed (`App.entitlements`: app sandbox + outgoing network + the
Firebase keychain group) and Xcode signs it automatically — Apple Development
when you run it, Apple Distribution when you archive it for upload. There is no
in-app updater: the App Store installs updates, so the update gate, the
"Update available" banner and "Check for Updates…" all open the App Store's
Updates page (`AppUpdater`). Launch at login starts OFF (guideline 2.4.5 bars
adding a login item without consent); users switch it on in Settings.
`ITSAppUsesNonExemptEncryption = NO` skips the export-compliance question on
every upload.

### One-time setup

1. developer.apple.com → Identifiers → **+** → App IDs → App, bundle id
   `com.thisisnsh.alldaysports` (explicit), capability **Keychain Sharing**. No Push
   Notifications — the app polls.
2. Firebase console, in **both** `dreamaboutsports-staging` and
   `dreamaboutsports-prod`: Add app → Apple, bundle id `com.thisisnsh.alldaysports`.
   Download each `GoogleService-Info.plist` over
   `Resources/GoogleService-Info-Staging.plist` /
   `Resources/GoogleService-Info-Production.plist` (Firebase bundle ids can't
   be edited, so the old `com.alldayidreamaboutsports.mac` apps stay behind).
   Remote Config is per project, so it carries over unchanged.
3. App Store Connect → Apps → **+** → New macOS App with bundle id
   `com.thisisnsh.alldaysports`. Fill in the listing, the privacy labels (Analytics +
   Crashlytics: usage and diagnostics data, not linked to identity).

### Build, test, release

1. `xcodegen && open AllDayIDreamAboutSports.xcodeproj`
2. Test: ⌘R runs **Debug** (fake services). Edit Scheme → Run → Build
   Configuration → **Staging** or **Release** to test the sandboxed app against
   real services (live scores, celebrations, overlays).
3. Bump `MARKETING_VERSION` (user-facing version) and `CURRENT_PROJECT_VERSION`
   (must increase on every upload) in `project.yml`, then rerun `xcodegen`.
4. **Product → Archive** (archives the Release config), then in Organizer
   **Distribute App → App Store Connect → Upload**.
5. In App Store Connect, attach the build to the version and submit for review.

Remote Config `min_build` / `latest_build` compare against
`CURRENT_PROJECT_VERSION`. Raise them only once the build that clears them is
**live** on the App Store — otherwise users get an update prompt with nothing
to update to. Builds 1–3 were the old website DMGs, so App Store builds start
at 4.

## Source map

| Dir | What |
|---|---|
| `Sources/App.swift` | window scenes (login, picker, settings, gate) |
| `Sources/AppDelegate.swift` | transient AppKit menu, Firebase bootstrap (Remote Config + Crashlytics/Analytics — no Messaging), reopen handling |
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
