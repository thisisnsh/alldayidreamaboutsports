# Apple apps

SwiftUI menu bar app for macOS 14+, plus an iPhone/iPad app for iOS/iPadOS 17+.
Team `983LBM5U6B`, app bundle id `com.thisisnsh.alldaysports` (shared across platforms).
The Xcode project is generated — edit `project.yml` and rerun `xcodegen`, rather
than editing the ignored `.xcodeproj`.

## iPhone and iPad

Select **AllDayIDreamAboutSportsMobile** in Xcode and an iPhone or iPad destination.
The mobile app embeds **ScoreLiveActivity**, a WidgetKit extension with Lock Screen
and Dynamic Island presentations. Onboarding runs inside the app; afterward, the
Mac menu's matches, teams, and timeline views fill the app. The iPad content column
is centered and bounded to 680 points; it also adapts to narrower windows.
Mobile settings omit Mac-only launch-at-login, display, and overlay controls.

Debug uses the existing scripted matchday. Staging and Release use the existing
scores CDN configurations. Mobile builds select optional `GoogleService-Info-iOS-Staging.plist` /
`GoogleService-Info-iOS-Production.plist` files. Background delivery requires the
matching mobile Firebase/App Check configuration; no Mac configuration is copied automatically.

```sh
xcodegen
xcodebuild -scheme AllDayIDreamAboutSportsMobile -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

`SportsMobileUITests` exercises onboarding completion and persistence, matches,
Live Activity pin/unpin, and settings. Run the same scheme's tests with an iPad
destination to cover the tablet layout. Screenshots are attached to test results.

### Foreground polling and background push

The mobile app retains the Mac CDN poll/diff pipeline while active. The separate
[`push/` service](../push/README.md) polls the CDN independently and can send APNs
updates directly to pinned Live Activities and normal match notifications while
the device is locked. It does not modify or depend on the existing backend's code.

Background delivery requires the mobile push endpoint, Firebase App Check setup,
Apple provisioning and service credentials described in that README. Until they
are configured, contributor builds retain foreground polling and display an honest
“not configured” status. Debug/demo builds never register fake matches remotely.

The mobile target contains App Attest and push entitlements, frequent Live Activity
support, device/activity token rotation, and subscription sync. Settings expose the
connection status and per-event notification choices. Local polling supplies alerts
while active; foreground remote alerts are suppressed to avoid duplicate banners.
“Keep screen awake” remains optional. Scores remain stale-labeled if neither polling
nor push confirms them. APNs cannot guarantee delivery timing or every alert.

Signing keys are never included in the app or repository. Background subscriptions
contain only the delivery tokens, pinned fixture IDs, and (when alerts are enabled)
selected team IDs/event preferences, under a random installation credential. See
`push/README.md` for retention, deployment, verification and rollback details.

## Mac build & run

```sh
brew install xcodegen
xcodegen                                   # → AllDayIDreamAboutSports.xcodeproj
open AllDayIDreamAboutSports.xcodeproj     # or:
xcodebuild -scheme AllDayIDreamAboutSports -configuration Debug build
```

## Testing — three build configurations

The app only touches the world through protocol (`Sources/Services/Backend.swift`):
`ScoresProviding`. The build configuration
picks the implementation — that's the release flag:

| | `Debug` | `Staging` | `Release` |
|---|---|---|---|
| Services | fake/offline | `dreamaboutsports-staging` | `dreamaboutsports-prod` |
| Firebase config | none | `GoogleService-Info-Staging.plist` | `GoogleService-Info-Production.plist` |
| Backend/data | in-memory seed data | staging URLs from `project.yml` | production URLs from `project.yml` |
| Intended use | normal Xcode development | end-to-end testing | shipped app |

**Day-to-day dev loop:**

1. Build & run **Debug** from Xcode (⌘R). You're already following one club
   in each of the demo's ten matches (`DevConfig.fanTeams`; 20 clubs, none
   twice). The popover shows the demo matchday: City vs Arsenal and Madrid vs
   Barça live, Inter vs Juventus kicking off during the show, Liverpool vs
   United finished, two later kickoffs, plus results on yesterday's page and
   fixtures on tomorrow's. `DevConfig.timeline` plays once at launch (~4 min),
   so pills and goal celebrations all appear hands-free.
2. **Everything is a code knob in `Sources/Dev/DevConfig.swift`**: the fan-team
   list, the deterministic timeline itself, autostart,
   looping, and the two warm-up passes (`showcaseAtStart`, `clockWalkAtStart`).
   The fixtures those beats play out on, and the fake catalog behind the picker,
   live next door in `Sources/Dev/FakeBackend.swift`. Edit, ⌘R, observe.
3. Settings shows a small 🧪 pill so you always know you're in a dev session,
   and a Demo card (Restart / Play / Stop) for the timeline. The
   simulated events run through the real EventRouter/Overlay pipeline, exactly
   as a state change polled from the scores CDN would; `Settings → Celebration
   → Preview animation` fires one on demand.
4. Tap the ball during the window for local mini-ball animations. No taps are
   uploaded and no shared count is displayed.

**Demo data in any build (App Review):** tap the **Settings** title five
times (within 3s of each other) and any build — Staging and Release included —
swaps real scores for the same demo, re-anchored to now, and jumps back to the
matches. Five more taps replay it; Settings → Demo → Exit demo (or quitting)
returns to real scores and your own teams. Nothing the demo touches is
persisted, the live poll loop is paused while it runs, and demo goals don't
count toward the rating prompt. `demo_activated` / `demo_exited` show up in
Analytics. App Review notes for each submission:

> Live scores only appear while the user's teams are playing. To see the app
> with live matches at any time: click the ⚽ menu bar icon → gear (Settings) →
> click the "Settings" title five times. The app loads a made-up matchday
> (finished, live and upcoming matches; goal alerts and celebrations start
> within seconds). Settings → Demo → Exit demo returns to real data.

**Why Debug needs no backend** (each network path, and what disables it):

| Path | In Debug |
|---|---|
| Scores CDN (`URLSession` in `CDNScoresClient`) | never instantiated — `FakeScores` |
| Crashlytics / Analytics | `GoogleService-Info.plist` absent → Firebase never configured |

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

Crashlytics collects crashes and non-fatal errors in both Staging and Release
(never Debug); errors go up scrubbed to a coarse label. Every analytics event
is also a Crashlytics breadcrumb, and Staging additionally sends every log line
as one. Analytics is Firebase `FirebaseAnalyticsCore` — no ad ID, no automatic
screen views, no ad personalization signals — so App Store Connect's privacy
labels are just usage + diagnostics data, not linked to identity and not used
for tracking. Crashlytics is not a live arbitrary-log viewer; use Console.app or
`log stream` for the complete live stream.

## Mac App Store

The app is sandboxed (`App.entitlements`: app sandbox + outgoing network + the
Firebase keychain group) and Xcode signs it automatically — Apple Development
when you run it, Apple Distribution when you archive it for upload. There is no
in-app updater and no forced update: the App Store installs updates. Launch at login starts OFF (guideline 2.4.5 bars
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
   `Resources/GoogleService-Info-Production.plist`.
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

Older builds can't be forced to update, so keep the CDN JSON contract
backward-compatible (additive fields; breaking changes under a new path).

## Source map

| Dir | What |
|---|---|
| `Sources/App.swift` | SwiftUI entry point (a hidden scene; AppKit owns the UI) |
| `Sources/AppDelegate.swift` | status item, popover and right-click menu, Firebase bootstrap (Crashlytics/Analytics), reopen handling |
| `Sources/Services/` | local prefs, scores CDN, live polling, event routing |
| `Sources/Overlay/` | the two overlay panels: full-screen click-through display + small clickable ball; celebration, notch pill, particles |
| `Sources/Views/` | the popover (matches, Teams and Settings pages) and the first-run onboarding window |

Key invariants:
- Overlay panels use `sharingType = .readOnly`, so they show up in screen
  sharing and recordings, and never take focus (`nonactivatingPanel`).
- Two overlay queues feed displayed sets: goal events are selected first, then
  remaining slots fill from non-goals. The visible stack is chronological
  within the selected set, oldest at top and newest at bottom, and shows for
  `pillHoldSeconds`. A ✕ under the stack ends the set early. Fan goals start
  one shared center-ball celebration only when their goal pill reaches the
  displayed set; closing the ball does not dismiss or pause queued
  notifications.
- Ball taps only animate on the current Mac. No upload or global count exists.
- No remote config: poll interval, overlay timing and the VAR staleness
  window are constants, and fans can follow any number of teams. The
  emergency stop is server-side (`infra/README.md`).
- Fixture date files bootstrap and persist the daily schedule once. Only
  followed-team `matches/{fixtureId}.json` objects inside their live window are
  polled — from kickoff−5min (`LiveStore.preKickoffLead`) until FINISHED, capped
  at 3.5h. The backend publishes those objects from kickoff−5min too, so the
  two ends agree and no client 404s its way to kickoff. Finished fixtures remain
  in the local cache.
- The published `fixtures` list is fan-filtered. The full day's fixtures — up to
  ~48 across five leagues — stay in the working set for the poll loop, but only
  the user's own are published and written to the local cache.

## Reproducible contributor checks

`xcodegen` restores the tracked `Package.resolved` into the generated project.
Firebase is pinned to the reviewed version. To update dependencies, change the
pin in `project.yml`, resolve deliberately, copy the new generated lockfile to
`app/Package.resolved`, and review both changes together.

```sh
bash scripts/test-notch-motion.sh
bash scripts/test-security.sh
xcodegen
xcodebuild -scheme AllDayIDreamAboutSports -configuration Debug \
  -onlyUsePackageVersionsFromResolvedFile -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO build
```

The security checks cover hostile match counters and event bursts as well as
remote URL/size limits. Network and cached fixtures reject negative or excessive
values: scores/cards at most 100, minutes at most 300, stoppage at most 60,
each team event list and VAR list at most 100, and shootout kicks at most 200.
Schedule responses allow at most 512 fixtures. A diff exceeding 64 events updates
the accepted score but emits no overlay burst. Invalid snapshots leave the last
valid live state intact; an invalid persisted cache triggers a fresh bootstrap.

For signed forks, replace `DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER`, and
the keychain access group in `App.entitlements` with your own values. Real-service
builds also need your own Firebase plists and scores URLs. Debug uses fake match
state but reads the public production catalog and API-Sports logos; switch
`FakeScores.fetchCatalog()` to `hardcodedCatalog` for a fixed catalog snapshot.
