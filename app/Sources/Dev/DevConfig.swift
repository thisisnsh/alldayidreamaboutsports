#if DEV_BACKEND
import Foundation

// ╔══════════════════════════════════════════════════════════════════════╗
// ║  DEMO SCRIPT — a deterministic show you can rehearse and present.     ║
// ║  Edit the timeline below, ⌘R, and the SAME events fire at the SAME    ║
// ║  seconds with the SAME scoreline every run — no randomness. Several   ║
// ║  matches run in parallel; each moment names which one it belongs to.  ║
// ║  Compiled only into Debug (DEV_BACKEND) builds; see DemoEngine in     ║
// ║  FakeBackend.swift for the runtime that plays it.                     ║
// ║  Club sides only — the World Cup is archived, so the demo runs on the ║
// ║  same five domestic leagues the app actually follows, and every team  ║
// ║  id below exists in FakeScores.demoCatalog (name, code and crest).    ║
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

    /// Teams you follow, as API team ids (LIV 40, MCI 50, ARS 42, INT 505). A
    /// goal by ANY of these runs the full celebration; everyone else's goals are
    /// notch pills. Must cover both sides of the `livMci` match below (you're a
    /// fan of both teams there) and the followed side of every other match.
    static let fanTeams = ["40", "50", "42", "505"]

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
    static let showcaseAtStart = false
    /// Before anything else, step ONE fixture through every half change on
    /// the local clock (0′ → HT → 45′ → ET → 90′ → ET HT → 105′ → FT), then
    /// an empty-name goal and a disallow→re-award cycle. Eyeball the
    /// menu/capsule time label at each step. Runs once per Play/Restart.
    static let clockWalkAtStart = false
    /// Seconds between showcase pills — enough to read each as it stacks.
    static let showcaseSpacing = 2.5

    // ── THE TIMELINE ────────────────────────────────────────────────────
    // `at`      seconds after the demo starts (deterministic — not random).
    // fixture   which parallel match the event belongs to (.livMci, …).
    // `minute`  match clock shown in the pill.
    // Scores per match are tracked automatically as goals fire, so you never
    // hand-maintain a scoreline: a `.goal(.home)` makes it 1-0, a later
    // `.goalDisallowed(.home)` puts it back. Multiple moments sharing the same
    // `at` fire together — that's how you stage overlaps across matches to
    // stress the notch stack, goal-priority selection, chronological display
    // order, and shared center-ball celebrations.
    //
    // NOT wired in: its three fixtures aren't in `demoMatches`. To run it,
    // rename it to `timeline` (renaming the reel below) and set
    // `DemoFixture.demoMatches = [livMci, arsMun, intJuv]`.
    static let timeline1: [DemoMoment] = [
        // Three matches kick off seconds apart.
        DemoMoment(at: 0,  .livMci, minute: 1,  .kickoff),
        DemoMoment(at: 1,  .arsMun, minute: 1,  .kickoff),
        DemoMoment(at: 2,  .intJuv, minute: 1,  .kickoff),

        // QUEUE STRESS: kickoff pills are still on screen, so this whole burst
        // waits. The next visible set should pick all goals first (fan + nonfan
        // across several teams), fill remaining slots with cards/VAR, and keep
        // the visible stack chronological inside that selected set.
        DemoMoment(at: 5,  .livMci, minute: 9,  .goal(.home, player: "Salah")),          // fan
        DemoMoment(at: 5,  .arsMun, minute: 9,  .goal(.away, player: "Mbeumo")),         // nonfan opponent
        DemoMoment(at: 5,  .intJuv, minute: 9,  .goal(.home, player: "Lautaro Martínez")), // fan
        DemoMoment(at: 5,  .intJuv, minute: 10, .goal(.away, player: "Yıldız")),         // nonfan opponent
        DemoMoment(at: 5,  .arsMun, minute: 10, .goal(.home, player: "Gyökeres")),       // fan
        DemoMoment(at: 5,  .livMci, minute: 10, .goal(.away, player: "Haaland")),        // fan, different team
        DemoMoment(at: 5,  .arsMun, minute: 11, .yellowCard(.away, player: "Casemiro")),
        DemoMoment(at: 5,  .intJuv, minute: 11, .yellowCard(.away, player: "Locatelli")),
        DemoMoment(at: 5,  .livMci, minute: 12, .redCard(.away, player: "Rodri")),
        DemoMoment(at: 5,  .livMci, minute: 12, .yellowCard(.home, player: "Gravenberch")),
        DemoMoment(at: 5,  .arsMun, minute: 12, .yellowCard(.home, player: "Rice")),
        DemoMoment(at: 5,  .intJuv, minute: 12, .redCard(.away, player: "Bremer")),
        DemoMoment(at: 5,  .livMci, minute: 13, .goalDisallowed(.home)),             // fan goal cancelled before display

        // More goals arrive while the stress burst is still draining.
        DemoMoment(at: 9,  .arsMun, minute: 14, .goal(.home, player: "Saka")),
        DemoMoment(at: 9,  .intJuv, minute: 15, .goal(.home, player: "Thuram")),

        // City extend the lead — you're a fan of BOTH teams in this match, so
        // an away goal here ALSO runs the full celebration when displayed.
        DemoMoment(at: 13, .livMci, minute: 22, .goal(.away, player: "Foden")),

        DemoMoment(at: 16, .arsMun, minute: 26, .yellowCard(.away, player: "Mount")),
        DemoMoment(at: 18, .intJuv, minute: 30, .goal(.away, player: "Openda")), // opponent → pill only

        // TRIPLE OVERLAP: a goal in every match at the same second.
        DemoMoment(at: 22, .livMci, minute: 35, .goal(.home, player: "Gakpo")),
        DemoMoment(at: 22, .arsMun, minute: 35, .goal(.away, player: "Šeško")), // opponent → pill only
        DemoMoment(at: 22, .intJuv, minute: 36, .goal(.home, player: "Barella")),

        DemoMoment(at: 26, .livMci, minute: 37, .goalDisallowed(.home)),          // VAR pulls Liverpool's latest back

        // Half-times roll in close together.
        DemoMoment(at: 30, .livMci, minute: 45, .halfTime),
        DemoMoment(at: 31, .arsMun, minute: 45, .halfTime),
        DemoMoment(at: 32, .intJuv, minute: 45, .halfTime),

        // Celebration surges (tap counts) for the followed matches.
        DemoMoment(at: 36, .livMci, minute: 45, .celebrationSurge(["40": 3_200_000, "50": 2_800_000])),
        DemoMoment(at: 37, .arsMun, minute: 45, .celebrationSurge(["42": 1_900_000, "33": 540_000])),

        // Second half.
        DemoMoment(at: 41, .intJuv, minute: 52, .goal(.home, player: "Çalhanoğlu")),
        DemoMoment(at: 45, .arsMun, minute: 61, .redCard(.away, player: "Dalot")),

        // OVERLAP in one match: City go ahead and Liverpool reply in the same
        // instant — two full celebrations queued back to back.
        DemoMoment(at: 49, .livMci, minute: 70, .goal(.away, player: "Doku")),
        DemoMoment(at: 49, .livMci, minute: 70, .goal(.home, player: "Wirtz")),

        // Juventus claw back to level — the Inter match is heading the distance.
        DemoMoment(at: 50, .intJuv, minute: 74, .goal(.away, player: "Conceição")),
        DemoMoment(at: 53, .arsMun, minute: 82, .goal(.home, player: "Ødegaard")),
        DemoMoment(at: 56, .intJuv, minute: 88, .celebrationSurge(["505": 4_100_000, "496": 770_000])),
        DemoMoment(at: 58, .intJuv, minute: 90, .goal(.away, player: "Vlahović")),

        // Two matches end in normal time.
        DemoMoment(at: 60, .livMci, minute: 90, .fullTime),
        DemoMoment(at: 61, .arsMun, minute: 90, .fullTime),

        // Extra time, a goal each way, then a shootout decides it. League play
        // never goes past 90 — this tail is here purely to exercise the ET /
        // shootout / pen-tally rendering that a cup competition will need.
        DemoMoment(at: 63, .intJuv, minute: 91,  .extraTime),
        DemoMoment(at: 66, .intJuv, minute: 105, .goal(.home, player: "Dimarco")),
        DemoMoment(at: 69, .intJuv, minute: 118, .goal(.away, player: "Kalulu")),
        DemoMoment(at: 72, .intJuv, minute: 120, .penaltyShootout),

        // The shootout — every kick is its own pill (scored ✓ / missed ✗),
        // and the running pen tally rides along in the subheading.
        DemoMoment(at: 74, .intJuv, minute: 120, .penaltyKick(.home, player: "Çalhanoğlu", scored: true)),  // 1-0
        DemoMoment(at: 76, .intJuv, minute: 120, .penaltyKick(.away, player: "Vlahović",   scored: true)),  // 1-1
        DemoMoment(at: 78, .intJuv, minute: 120, .penaltyKick(.home, player: "Bonny",      scored: false)), // 1-1
        DemoMoment(at: 80, .intJuv, minute: 120, .penaltyKick(.away, player: "Yıldız",     scored: true)),  // 1-2
        DemoMoment(at: 82, .intJuv, minute: 120, .penaltyKick(.home, player: "Barella",    scored: true)),  // 2-2
        DemoMoment(at: 84, .intJuv, minute: 120, .penaltyKick(.away, player: "Locatelli",  scored: false)), // 2-2
        DemoMoment(at: 86, .intJuv, minute: 120, .penaltyKick(.home, player: "Dimarco",    scored: true)),  // 3-2
        DemoMoment(at: 88, .intJuv, minute: 120, .penaltyKick(.away, player: "Conceição",  scored: false)), // 3-2

        DemoMoment(at: 90, .intJuv, minute: 120, .fullTime),  // Inter win 3-2 on penalties
    ]

    // ── DEMO REEL (the one that plays) ──────────────────────────────────
    // A Premier League matchday: Manchester City 4-2 Manchester United, with
    // the rest of the day's card around it. You follow Man City (50 is in
    // fanTeams), so every City goal is a full center-ball celebration; United
    // goals and all other events are pills.
    static let timeline: [DemoMoment] = [
        // ── Past matches — fire at t=0 so the scoreboard opens with them
        // already finished. Their pills appear as a brief burst up front.

        // Liverpool 3-1 Arsenal (early kickoff; finished hours before the derby)
        // DemoMoment(at: 0, .livArs, minute: 1,  .kickoff),
        // DemoMoment(at: 0, .livArs, minute: 21, .goal(.home, player: "Salah")),          // 1-0
        // DemoMoment(at: 0, .livArs, minute: 45, .halfTime),
        // DemoMoment(at: 0, .livArs, minute: 50, .goal(.away, player: "Saka")),            // 1-1
        // DemoMoment(at: 0, .livArs, minute: 76, .goal(.home, player: "Timber (OG)")),     // 2-1
        // DemoMoment(at: 0, .livArs, minute: 77, .yellowCard(.home, player: "Mac Allister")),
        // DemoMoment(at: 0, .livArs, minute: 90, .goal(.home, player: "Ekitiké")),         // 3-1 (pen)
        // DemoMoment(at: 0, .livArs, minute: 90, .fullTime),

        // Inter 1-1 Juventus, decided on PENALTIES (afternoon kickoff). A league
        // fixture never actually goes to a shootout — this one does so the ET
        // and pen-tally rendering stays covered until a cup competition lands.
        DemoMoment(at: 0, .intJuv, minute: 1,  .kickoff),
        DemoMoment(at: 10, .intJuv, minute: 6,  .goal(.home, player: "Lautaro Martínez")), // 1-0
        // DISALLOWED-OFFSIDE PHANTOM: VAR chalks off the 6' goal for offside. The
        // aggregate drops back to 0-0, but the goal event lingers in the list
        // (goalEvents.count > goals) — pin Inter and hover: the 6' goal shows
        // STRUCK THROUGH while the scoreline stays correct.
        DemoMoment(at: 12, .intJuv, minute: 7,  .goalDisallowedOffside(.home)),           // → 0-0, 6' struck
        DemoMoment(at: 20, .intJuv, minute: 13, .yellowCard(.home, player: "Barella")),
        DemoMoment(at: 23, .intJuv, minute: 32, .yellowCard(.away, player: "Locatelli")),
        DemoMoment(at: 30, .intJuv, minute: 45, extra: 7, .goal(.away, player: "Vlahović")), // 1-1 (45+7')
        DemoMoment(at: 35, .intJuv, minute: 45, .halfTime),
        // Still level after 90 and extra time — Inter go to a SHOOTOUT.
        // Pin Inter and the capsule scoreline switches to the pen tally
        // (`1+P3 – 1+P2`), using the same spaced en-dash separator as a
        // regular result — the exact case to eyeball for consistent spacing.
        DemoMoment(at: 37, .intJuv, minute: 91,  .extraTime),
        DemoMoment(at: 40, .intJuv, minute: 120, .penaltyShootout),
        DemoMoment(at: 41, .intJuv, minute: 120, .penaltyKick(.home, player: "Çalhanoğlu", scored: true)),  // 1-0
        DemoMoment(at: 42, .intJuv, minute: 120, .penaltyKick(.away, player: "Vlahović",   scored: true)),  // 1-1
        DemoMoment(at: 43, .intJuv, minute: 120, .penaltyKick(.home, player: "Dimarco",    scored: true)),  // 2-1
        DemoMoment(at: 44, .intJuv, minute: 120, .penaltyKick(.away, player: "Openda",     scored: false)), // 2-1
        DemoMoment(at: 45, .intJuv, minute: 120, .penaltyKick(.home, player: "Barella",    scored: true)),  // 3-1
        DemoMoment(at: 46, .intJuv, minute: 120, .penaltyKick(.away, player: "Yıldız",     scored: true)),  // 3-2
        DemoMoment(at: 47, .intJuv, minute: 120, .penaltyKick(.home, player: "Thuram",     scored: false)), // 3-2
        DemoMoment(at: 48, .intJuv, minute: 120, .penaltyKick(.away, player: "Conceição",  scored: false)), // 3-2
        DemoMoment(at: 49, .intJuv, minute: 120, .fullTime),  // Inter win 3-2 on penalties

        // Real Madrid vs Barcelona and Milan vs Napoli have no events →
        // they stay SCHEDULED, appearing as upcoming in the scoreboard.

        // ── Manchester City 4-2 Manchester United (live, evening kickoff) ──
        DemoMoment(at: 40,  .mciMun, minute: 1,  .kickoff),

        // VAR confirms the spot kick, then Haaland converts — exercises the
        // varDecision pill and the "Penalty goal" label.
        DemoMoment(at: 46, .mciMun, minute: 11, .varDecision(.home, detail: "Penalty confirmed")),
        DemoMoment(at: 50, .mciMun, minute: 12, .goal(.home, player: "Haaland", kind: "penalty")), // pen → 1-0
        // DemoMoment(at: 90, .mciMun, minute: 12, .celebrationSurge(["50": 2_400_000, "33": 0])),

        DemoMoment(at: 60, .mciMun, minute: 36, .goal(.away, player: "Bruno Fernandes")), // 1-1
        DemoMoment(at: 61, .mciMun, minute: 42, .goal(.home, player: "Haaland")),         // 2-1
        // DemoMoment(at: 47, .mciMun, minute: 42, .celebrationSurge(["50": 3_800_000, "33": 120_000])),
        DemoMoment(at: 70, .mciMun, minute: 45, extra: 7, .goal(.away, player: "Mbeumo")), // 2-2 (45+7')
        DemoMoment(at: 72, .mciMun, minute: 45, .halfTime),

        DemoMoment(at: 83, .mciMun, minute: 47, .goal(.home, player: "Foden")),           // 3-2

        // A sub each way — exercises the substitution pill + timeline rows.
        DemoMoment(at: 94, .mciMun, minute: 63, .substitution(.home, playerIn: "Doku", playerOut: "Marmoush")),
        DemoMoment(at: 97, .mciMun, minute: 64, .substitution(.away, playerIn: "Amad", playerOut: "Mbeumo")),

        // Maguire turns it into his own net — the own goal credits CITY
        // (the benefiting side), matching the backend's attribution.
        DemoMoment(at: 100, .mciMun, minute: 85, .goal(.home, player: "Maguire", kind: "own")), // OG → 4-2

        // OUT-OF-ORDER VAR (must be IGNORED): API-Football backfills a 67'
        // "Penalty confirmed" long after the fact. By now the 85' own goal is the
        // latest event we've notified, so EventRouter's staleness guard drops this
        // (85-67 > event_stale_minutes) — NO pill should appear. Contrast with the
        // in-order 11' VAR above, which shows normally. This is the exact
        // real-world case (a 67' VAR that surfaced at 79') the guard fixes.
        DemoMoment(at: 105, .mciMun, minute: 67, .varDecision(.home, detail: "Penalty confirmed")),

        DemoMoment(at: 110, .mciMun, minute: 90, .fullTime),
    ]
}

// MARK: - Timeline vocabulary

/// A team in a demo match, named once so events can refer to a side. `id` is
/// the API team id (also the fan key); `logo` is its CDN image. Every id here
/// is in FakeScores.demoCatalog, so the app resolves its full name and its
/// short code (the label the menu, pills and a resting capsule show).
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
    // ── Fixtures for the parallel stress timeline (see DevConfig.timeline1) ──

    /// Fan of BOTH sides — every goal here is a full celebration.
    static let livMci = DemoFixture(
        id: 1001, leagueId: 39, round: "Regular Season - 12",
        home: DemoTeam(id: 40, code: "LIV", name: "Liverpool"),
        away: DemoTeam(id: 50, code: "MCI", name: "Manchester City")
    )
    /// Fan of the home side only; Manchester United is the opponent (pills).
    static let arsMun = DemoFixture(
        id: 1002, leagueId: 39, round: "Regular Season - 12",
        home: DemoTeam(id: 42, code: "ARS", name: "Arsenal"),
        away: DemoTeam(id: 33, code: "MUN", name: "Manchester United")
    )
    /// Fan of the home side only; Juventus is the opponent (pills). Also the
    /// reel's shootout fixture, and the showcase's (see DemoEngine.runShowcase).
    static let intJuv = DemoFixture(
        id: 1003, leagueId: 135, round: "Regular Season - 3",
        home: DemoTeam(id: 505, code: "INT", name: "Inter"),
        away: DemoTeam(id: 496, code: "JUV", name: "Juventus")
    )

    // ── Fixtures for the demo reel (see DevConfig.timeline) ─────────────

    /// The derby the reel is built around. Fan of the home side only.
    static let mciMun = DemoFixture(
        id: 1489384, leagueId: 39, round: "Regular Season - 3",
        home: DemoTeam(id: 50, code: "MCI", name: "Manchester City"),
        away: DemoTeam(id: 33, code: "MUN", name: "Manchester United")
    )
    /// Finished before the derby kicks off. Fan of BOTH sides.
    static let livArs = DemoFixture(
        id: 1489382, leagueId: 39, round: "Regular Season - 3",
        home: DemoTeam(id: 40, code: "LIV", name: "Liverpool"),
        away: DemoTeam(id: 42, code: "ARS", name: "Arsenal")
    )
    /// No events in the reel — stays SCHEDULED, and neither side is followed.
    static let madBar = DemoFixture(
        id: 1489385, leagueId: 140, round: "Regular Season - 3",
        home: DemoTeam(id: 541, code: "MAD", name: "Real Madrid"),
        away: DemoTeam(id: 529, code: "BAR", name: "Barcelona")
    )
    /// No events in the reel — stays SCHEDULED, and neither side is followed.
    static let milNap = DemoFixture(
        id: 1489386, leagueId: 135, round: "Regular Season - 3",
        home: DemoTeam(id: 489, code: "MIL", name: "AC Milan"),
        away: DemoTeam(id: 492, code: "NAP", name: "Napoli")
    )

    /// Every match the demo runs in parallel (drives the live scoreboard).
    static let demoMatches = [mciMun, livArs, intJuv, madBar, milNap]
}

/// Which team an action belongs to, relative to its match's fixture.
enum DemoSide { case home, away }

/// What happens at a moment. The engine turns each into the same FCM-shaped
/// push the backend would send, and keeps that match's scoreboard in step.
enum DemoAction {
    case kickoff
    case goal(DemoSide, player: String, kind: String?) // kind: nil | "own" | "penalty"
    case goalDisallowed(DemoSide)          // VAR — undoes that side's last goal (aggregate + event both drop)
    case goalDisallowedOffside(DemoSide)   // VAR/offside — aggregate drops but the goal event lingers (phantom → struck through)
    case yellowCard(DemoSide, player: String)
    case redCard(DemoSide, player: String)
    case halfTime
    case fullTime
    case extraTime                         // "Extra time begins"
    case penaltyShootout
    case penaltyKick(DemoSide, player: String, scored: Bool) // one shootout kick
    case substitution(DemoSide, playerIn: String, playerOut: String)
    case varDecision(DemoSide, detail: String) // a VAR outcome, e.g. "Penalty confirmed"
    case celebrationSurge([String: Int])   // a celebration_count push (taps by team)
}

extension DemoAction {
    /// A regular goal — keeps the many `.goal(side, player:)` timeline entries
    /// short (enum cases can't default their associated values).
    static func goal(_ side: DemoSide, player: String) -> DemoAction {
        .goal(side, player: player, kind: nil)
    }
}

/// One scripted beat: fire `action` in `fixture` at `at` seconds after start.
struct DemoMoment {
    let at: Double
    let fixture: DemoFixture
    let minute: Int
    /// Stoppage minute (the `+7` in `45+7`); nil for a whole-minute beat. Rides
    /// onto the live clock, the drop pill, and the capsule timeline row.
    let extra: Int?
    let action: DemoAction

    init(at: Double, _ fixture: DemoFixture, minute: Int, extra: Int? = nil, _ action: DemoAction) {
        self.at = at
        self.fixture = fixture
        self.minute = minute
        self.extra = extra
        self.action = action
    }
}
#endif
