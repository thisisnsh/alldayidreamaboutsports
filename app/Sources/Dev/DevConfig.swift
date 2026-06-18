#if DEV_BACKEND
import Foundation

// ╔══════════════════════════════════════════════════════════════════════╗
// ║  DEMO SCRIPT — a deterministic show you can rehearse and present.     ║
// ║  Edit the timeline below, ⌘R, and the SAME events fire at the SAME    ║
// ║  seconds with the SAME scoreline every run — no randomness. Several   ║
// ║  matches run in parallel; each moment names which one it belongs to.  ║
// ║  Compiled only into Debug (DEV_BACKEND) builds; see DemoEngine in     ║
// ║  FakeBackend.swift for the runtime that plays it.                     ║
// ╚══════════════════════════════════════════════════════════════════════╝

@MainActor
enum DevConfig {
    /// You are signed in as this user before the first frame renders —
    /// no login window, no Google, no Keychain.
    static let profile = Profile(
        sub: "dev-user",
        email: "dev@alldayidreamaboutsports.com",
        name: "Dev Fan",
        photoURL: nil
    )

    /// Teams you follow, as API team ids (BRA 6, ARG 26, ENG 10, FRA 2). A goal
    /// by ANY of these runs the full celebration; everyone else's goals are
    /// notch pills. Must cover both sides of the `braArg` match below (you're a
    /// fan of both teams there) and the followed side of every other match.
    static let fanTeams = ["6", "26", "10", "2"]

    /// Start the timeline automatically at launch. Turn off to drive the
    /// show by hand from Settings → Developer (Play / Restart / Stop).
    static let autostart = true

    /// Replay from the top once the timeline finishes — good for a looping
    /// kiosk demo. Off = play through once and stop.
    static let loops = true

    /// Before the timeline proper, fire one pill of EVERY event type (kickoff,
    /// goal, VAR, cards, half/full-time, extra time, shootout, penalty kicks)
    /// so you can eyeball every pill layout the moment the show starts. Runs
    /// once per Play/Restart, then the normal timeline takes over from 0–0.
    static let showcaseAtStart = true
    /// Seconds between showcase pills — enough to read each as it stacks.
    static let showcaseSpacing = 2.5

    // ── THE TIMELINE ────────────────────────────────────────────────────
    // `at`      seconds after the demo starts (deterministic — not random).
    // fixture   which parallel match the event belongs to (.braArg, …).
    // `minute`  match clock shown in the pill.
    // Scores per match are tracked automatically as goals fire, so you never
    // hand-maintain a scoreline: a `.goal(.home)` makes it 1-0, a later
    // `.goalDisallowed(.home)` puts it back. Multiple moments sharing the same
    // `at` fire together — that's how you stage overlaps across matches to
    // stress the notch stack, goal-priority selection, chronological display
    // order, and shared center-ball celebrations.
    static let timeline: [DemoMoment] = [
        // Three matches kick off seconds apart.
        DemoMoment(at: 0,  .braArg, minute: 1,  .kickoff),
        DemoMoment(at: 1,  .engUsa, minute: 1,  .kickoff),
        DemoMoment(at: 2,  .fraGer, minute: 1,  .kickoff),

        // QUEUE STRESS: kickoff pills are still on screen, so this whole burst
        // waits. The next visible set should pick all goals first (fan + nonfan
        // across several teams), fill remaining slots with cards/VAR, and keep
        // the visible stack chronological inside that selected set.
        DemoMoment(at: 5,  .braArg, minute: 9,  .goal(.home, player: "Vinícius Jr")), // fan
        DemoMoment(at: 5,  .engUsa, minute: 9,  .goal(.away, player: "Pulisic")),     // nonfan opponent
        DemoMoment(at: 5,  .fraGer, minute: 9,  .goal(.home, player: "Mbappé")),      // fan
        DemoMoment(at: 5,  .fraGer, minute: 10, .goal(.away, player: "Musiala")),     // nonfan opponent
        DemoMoment(at: 5,  .engUsa, minute: 10, .goal(.home, player: "Kane")),        // fan
        DemoMoment(at: 5,  .braArg, minute: 10, .goal(.away, player: "Messi")),       // fan, different team
        DemoMoment(at: 5,  .engUsa, minute: 11, .yellowCard(.away, player: "Adams")),
        DemoMoment(at: 5,  .fraGer, minute: 11, .yellowCard(.away, player: "Rüdiger")),
        DemoMoment(at: 5,  .braArg, minute: 12, .redCard(.away, player: "Otamendi")),
        DemoMoment(at: 5,  .braArg, minute: 12, .yellowCard(.home, player: "Casemiro")),
        DemoMoment(at: 5,  .engUsa, minute: 12, .yellowCard(.home, player: "Rice")),
        DemoMoment(at: 5,  .fraGer, minute: 12, .redCard(.away, player: "Tah")),
        DemoMoment(at: 5,  .braArg, minute: 13, .goalDisallowed(.home)),             // fan goal cancelled before display

        // More goals arrive while the stress burst is still draining.
        DemoMoment(at: 9,  .engUsa, minute: 14, .goal(.home, player: "Saka")),
        DemoMoment(at: 9,  .fraGer, minute: 15, .goal(.home, player: "Griezmann")),

        // ARG extend the lead — you're a fan of BOTH teams in this match, so
        // an away goal here ALSO runs the full celebration when displayed.
        DemoMoment(at: 13, .braArg, minute: 22, .goal(.away, player: "Álvarez")),

        DemoMoment(at: 16, .engUsa, minute: 26, .yellowCard(.away, player: "McKennie")),
        DemoMoment(at: 18, .fraGer, minute: 30, .goal(.away, player: "Wirtz")), // opponent → pill only

        // TRIPLE OVERLAP: a goal in every match at the same second.
        DemoMoment(at: 22, .braArg, minute: 35, .goal(.home, player: "Rodrygo")),
        DemoMoment(at: 22, .engUsa, minute: 35, .goal(.away, player: "Reyna")), // opponent → pill only
        DemoMoment(at: 22, .fraGer, minute: 36, .goal(.home, player: "Dembélé")),

        DemoMoment(at: 26, .braArg, minute: 37, .goalDisallowed(.home)),          // VAR pulls BRA's latest back

        // Half-times roll in close together.
        DemoMoment(at: 30, .braArg, minute: 45, .halfTime),
        DemoMoment(at: 31, .engUsa, minute: 45, .halfTime),
        DemoMoment(at: 32, .fraGer, minute: 45, .halfTime),

        // Celebration surges (tap counts) for the followed matches.
        DemoMoment(at: 36, .braArg, minute: 45, .celebrationSurge(["6": 3_200_000, "26": 2_800_000])),
        DemoMoment(at: 37, .engUsa, minute: 45, .celebrationSurge(["10": 1_900_000, "2384": 540_000])),

        // Second half.
        DemoMoment(at: 41, .fraGer, minute: 52, .goal(.home, player: "Kolo Muani")),
        DemoMoment(at: 45, .engUsa, minute: 61, .redCard(.away, player: "Robinson")),

        // OVERLAP in one match: ARG go ahead and BRA reply in the same
        // instant — two full celebrations queued back to back.
        DemoMoment(at: 49, .braArg, minute: 70, .goal(.away, player: "Álvarez")),
        DemoMoment(at: 49, .braArg, minute: 70, .goal(.home, player: "Raphinha")),

        // Germany claw back to level — the France match is heading the distance.
        DemoMoment(at: 50, .fraGer, minute: 74, .goal(.away, player: "Gnabry")),
        DemoMoment(at: 53, .engUsa, minute: 82, .goal(.home, player: "Bellingham")),
        DemoMoment(at: 56, .fraGer, minute: 88, .celebrationSurge(["2": 4_100_000, "25": 770_000])),
        DemoMoment(at: 58, .fraGer, minute: 90, .goal(.away, player: "Havertz")),

        // Two matches end in normal time.
        DemoMoment(at: 60, .braArg, minute: 90, .fullTime),
        DemoMoment(at: 61, .engUsa, minute: 90, .fullTime),

        // Extra time, a goal each way, then a shootout decides it.
        DemoMoment(at: 63, .fraGer, minute: 91,  .extraTime),
        DemoMoment(at: 66, .fraGer, minute: 105, .goal(.home, player: "Thuram")),
        DemoMoment(at: 69, .fraGer, minute: 118, .goal(.away, player: "Füllkrug")),
        DemoMoment(at: 72, .fraGer, minute: 120, .penaltyShootout),

        // The shootout — every kick is its own pill (scored ✓ / missed ✗),
        // and the running pen tally rides along in the subheading.
        DemoMoment(at: 74, .fraGer, minute: 120, .penaltyKick(.home, player: "Mbappé",     scored: true)),  // 1-0
        DemoMoment(at: 76, .fraGer, minute: 120, .penaltyKick(.away, player: "Tah",        scored: true)),  // 1-1
        DemoMoment(at: 78, .fraGer, minute: 120, .penaltyKick(.home, player: "Coman",      scored: false)), // 1-1
        DemoMoment(at: 80, .fraGer, minute: 120, .penaltyKick(.away, player: "Musiala",    scored: true)),  // 1-2
        DemoMoment(at: 82, .fraGer, minute: 120, .penaltyKick(.home, player: "Tchouaméni", scored: true)),  // 2-2
        DemoMoment(at: 84, .fraGer, minute: 120, .penaltyKick(.away, player: "Goretzka",   scored: false)), // 2-2
        DemoMoment(at: 86, .fraGer, minute: 120, .penaltyKick(.home, player: "Hernández",  scored: true)),  // 3-2
        DemoMoment(at: 88, .fraGer, minute: 120, .penaltyKick(.away, player: "Sané",       scored: false)), // 3-2

        DemoMoment(at: 90, .fraGer, minute: 120, .fullTime),  // France win 3-2 on penalties
    ]

    // ── DEMO REEL (unused) ──────────────────────────────────────────────
    // The 2022 World Cup Final, beat for beat, for SCREEN-RECORDING a demo:
    // Argentina 3–3 France, Argentina win 4–2 on penalties (Lusail,
    // 18 Dec 2022). Real scorers, real bookings, real minutes, real shootout
    // order (France shot first; Montiel's kick won it). You follow both ARG
    // and FRA, so every goal here is a full center-ball celebration. There
    // were no red cards in the final. Stoppage-time bookings use the clock
    // minute (45/90); the true time is noted in the trailing comment.
    //
    // NOT wired in. To record with it: swap this in for `timeline` above
    // (e.g. rename to `timeline`), and add `argFra` to
    // `DemoFixture.demoMatches` so its scoreboard renders.
    static let demo: [DemoMoment] = [
        DemoMoment(at: 0,  .argFra, minute: 1,   .kickoff),

        // Argentina race into a two-goal lead. A celebration surge follows
        // every goal, ramping toward 6.5M (ARG) / 5.4M (FRA) by full time.
        DemoMoment(at: 4,  .argFra, minute: 23,  .goal(.home, player: "Lionel Messi")),   // 1–0 (penalty)
        DemoMoment(at: 6,  .argFra, minute: 23,  .celebrationSurge(["26": 1_100_000, "2": 0])),
        DemoMoment(at: 11, .argFra, minute: 36,  .goal(.home, player: "Ángel Di María")), // 2–0
        DemoMoment(at: 13, .argFra, minute: 36,  .celebrationSurge(["26": 2_400_000, "2": 0])),

        DemoMoment(at: 15, .argFra, minute: 45,  .yellowCard(.home, player: "Enzo Fernández")), // 45+7'
        DemoMoment(at: 18, .argFra, minute: 45,  .halfTime),

        DemoMoment(at: 22, .argFra, minute: 55,  .yellowCard(.away, player: "Adrien Rabiot")),

        // Mbappé's 97-second double drags France level.
        DemoMoment(at: 26, .argFra, minute: 80,  .goal(.away, player: "Kylian Mbappé")),  // 2–1 (penalty)
        DemoMoment(at: 27, .argFra, minute: 80,  .celebrationSurge(["26": 2_400_000, "2": 1_100_000])),
        DemoMoment(at: 28, .argFra, minute: 81,  .goal(.away, player: "Kylian Mbappé")),  // 2–2
        DemoMoment(at: 30, .argFra, minute: 81,  .celebrationSurge(["26": 2_400_000, "2": 3_400_000])),
        DemoMoment(at: 31, .argFra, minute: 87,  .yellowCard(.away, player: "Marcus Thuram")),
        DemoMoment(at: 34, .argFra, minute: 90,  .yellowCard(.away, player: "Olivier Giroud")), // 90+5'
        DemoMoment(at: 36, .argFra, minute: 90,  .yellowCard(.home, player: "Marcos Acuña")),   // 90+8'

        // Extra time: Messi edges Argentina ahead, Mbappé's third levels it again.
        DemoMoment(at: 39, .argFra, minute: 91,  .extraTime),
        DemoMoment(at: 43, .argFra, minute: 108, .goal(.home, player: "Lionel Messi")),   // 3–2
        DemoMoment(at: 45, .argFra, minute: 108, .celebrationSurge(["26": 5_100_000, "2": 3_400_000])),
        DemoMoment(at: 48, .argFra, minute: 114, .yellowCard(.home, player: "Leandro Paredes")),
        DemoMoment(at: 50, .argFra, minute: 116, .yellowCard(.home, player: "Gonzalo Montiel")),
        DemoMoment(at: 52, .argFra, minute: 118, .goal(.away, player: "Kylian Mbappé")),  // 3–3 (penalty)
        DemoMoment(at: 53, .argFra, minute: 118, .celebrationSurge(["26": 5_700_000, "2": 4_900_000])),

        // The shootout — France first; each kick its own pill (scored ✓ /
        // missed ✗) with the running pen tally riding along in the subheading.
        DemoMoment(at: 55, .argFra, minute: 120, .penaltyShootout),
        DemoMoment(at: 57, .argFra, minute: 120, .yellowCard(.home, player: "Emiliano Martínez")), // booked in the shootout
        DemoMoment(at: 59, .argFra, minute: 120, .penaltyKick(.away, player: "Kylian Mbappé",      scored: true)),  // 0–1
        DemoMoment(at: 61, .argFra, minute: 120, .penaltyKick(.home, player: "Lionel Messi",       scored: true)),  // 1–1
        DemoMoment(at: 63, .argFra, minute: 120, .penaltyKick(.away, player: "Kingsley Coman",     scored: false)), // 1–1 ✗ (saved)
        DemoMoment(at: 65, .argFra, minute: 120, .penaltyKick(.home, player: "Paulo Dybala",       scored: true)),  // 2–1
        DemoMoment(at: 67, .argFra, minute: 120, .penaltyKick(.away, player: "Aurélien Tchouaméni", scored: false)), // 2–1 ✗
        DemoMoment(at: 69, .argFra, minute: 120, .penaltyKick(.home, player: "Leandro Paredes",    scored: true)),  // 3–1
        DemoMoment(at: 71, .argFra, minute: 120, .penaltyKick(.away, player: "Randal Kolo Muani",  scored: true)),  // 3–2
        DemoMoment(at: 73, .argFra, minute: 120, .penaltyKick(.home, player: "Gonzalo Montiel",    scored: true)),  // 4–2 — champions
        
        DemoMoment(at: 78, .argFra, minute: 120, .fullTime),  // Argentina win 4–2 on penalties
    ]
}

// MARK: - Timeline vocabulary

/// A team in a demo match, named once so events can refer to a side. `id` is
/// the API team id (also the FCM topic / fan key); `logo` is its CDN image.
struct DemoTeam {
    let id: Int
    let code: String
    let name: String
    var logo: String { TeamCatalog.logoURL(id) }
}

/// One match the demo runs. Several play in parallel — see `demoMatches`.
struct DemoFixture {
    let id: Int
    let leagueId: Int
    let round: String
    let home: DemoTeam
    let away: DemoTeam
}

extension DemoFixture {
    /// Fan of BOTH sides — every goal here is a full celebration.
    static let braArg = DemoFixture(
        id: 1001, leagueId: 1, round: "Semi-finals",
        home: DemoTeam(id: 6, code: "BRA", name: "Brazil"),
        away: DemoTeam(id: 26, code: "ARG", name: "Argentina")
    )
    /// Fan of the home side only; USA is the opponent (pills).
    static let engUsa = DemoFixture(
        id: 1002, leagueId: 1, round: "Group B - 2",
        home: DemoTeam(id: 10, code: "ENG", name: "England"),
        away: DemoTeam(id: 2384, code: "USA", name: "United States")
    )
    /// Fan of the home side only; Germany is the opponent (pills).
    static let fraGer = DemoFixture(
        id: 1003, leagueId: 1, round: "Quarter-finals",
        home: DemoTeam(id: 2, code: "FRA", name: "France"),
        away: DemoTeam(id: 25, code: "GER", name: "Germany")
    )

    // ── Fixture for the unused `demo` reel (see DevConfig.demo) ───────────
    /// The 2022 World Cup Final. Fan of BOTH sides — every goal is a full
    /// celebration.
    static let argFra = DemoFixture(
        id: 2001, leagueId: 1, round: "Final",
        home: DemoTeam(id: 26, code: "ARG", name: "Argentina"),
        away: DemoTeam(id: 2, code: "FRA", name: "France")
    )

    /// Every match the demo runs in parallel (drives the live scoreboard).
    static let demoMatches = [braArg, engUsa, fraGer]
}

/// Which team an action belongs to, relative to its match's fixture.
enum DemoSide { case home, away }

/// What happens at a moment. The engine turns each into the same FCM-shaped
/// push the backend would send, and keeps that match's scoreboard in step.
enum DemoAction {
    case kickoff
    case goal(DemoSide, player: String)
    case goalDisallowed(DemoSide)          // VAR — undoes that side's last goal
    case yellowCard(DemoSide, player: String)
    case redCard(DemoSide, player: String)
    case halfTime
    case fullTime
    case extraTime                         // "Extra time begins"
    case penaltyShootout
    case penaltyKick(DemoSide, player: String, scored: Bool) // one shootout kick
    case celebrationSurge([String: Int])   // a celebration_count push (taps by team)
}

/// One scripted beat: fire `action` in `fixture` at `at` seconds after start.
struct DemoMoment {
    let at: Double
    let fixture: DemoFixture
    let minute: Int
    let action: DemoAction

    init(at: Double, _ fixture: DemoFixture, minute: Int, _ action: DemoAction) {
        self.at = at
        self.fixture = fixture
        self.minute = minute
        self.action = action
    }
}
#endif
