#if DEV_BACKEND
import Foundation

// ╔══════════════════════════════════════════════════════════════════════╗
// ║  DEMO SCRIPT — a deterministic show to record the product demo.       ║
// ║  Edit the timeline below, ⌘R, and the SAME events fire at the SAME    ║
// ║  seconds with the SAME scoreline every run — no randomness. Several   ║
// ║  matches run in parallel; each moment names which one it belongs to.  ║
// ║  Compiled only into Debug (DEV_BACKEND) builds; see DemoEngine in     ║
// ║  FakeBackend.swift for the runtime that plays it.                     ║
// ║                                                                       ║
// ║  The matches are INVENTED (famous clubs, real current players, made-  ║
// ║  up scorelines). What the menu shows the moment the app opens:        ║
// ║    Yesterday  Atlético 1-3 Real Madrid · Bayern 4-0 Leipzig (FT)      ║
// ║    Today      Liverpool 2-1 Man United (FT, earlier today)            ║
// ║               Man City 0-1 Arsenal (LIVE, 2nd half)                   ║
// ║               Real Madrid 1-0 Barcelona (LIVE, 1st half)              ║
// ║               Bayern vs Dortmund (kicks off ~35s into the show)       ║
// ║               PSG vs Marseille · Inter vs Juventus (later today)      ║
// ║    Tomorrow   Tottenham vs Man City · Liverpool vs Chelsea            ║
// ║  Then ~3 minutes of goals (Haaland, Mbappé, Kane, Yamal …), cards,    ║
// ║  subs, a VAR-disallowed goal, half-times and full-times.              ║
// ║                                                                       ║
// ║  Kickoff times are relative to launch (see DemoKickoff), so whatever  ║
// ║  time you record, live games kicked off a plausible while ago and     ║
// ║  scheduled ones are still ahead.                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

@MainActor
enum DevConfig {
    /// Teams you follow, as API team ids: Real Madrid 541, Man City 50,
    /// Liverpool 40, Bayern 157, PSG 85, Inter 505. The menu lists only
    /// matches involving these, so every demo fixture has one of them. A goal
    /// by a followed team runs the full celebration; the opponent's goals
    /// (Barça, Arsenal, Dortmund …) are notch pills — the reel mixes both.
    static let fanTeams = ["541", "50", "40", "157", "85", "505"]

    /// Start the timeline automatically at launch. Turn off to drive the
    /// show by hand from Settings → Developer (Play / Restart / Stop).
    static let autostart = true

    /// Replay from the top once the timeline finishes. Off for recording: the
    /// show plays once and the final scoreboard stays put. Settings →
    /// Developer → Restart replays it for another take.
    static let loops = false

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
    // fixture   which parallel match the event belongs to (.mciArs, …).
    // `minute`  the match clock shown at that beat (`extra:` is the `+2` in
    //           `45+2`). The demo clock holds the last beat's minute.
    // Scores per match are tracked automatically as goals fire, so you never
    // hand-maintain a scoreline: a `.goal(.home)` makes it 1-0, a later
    // `.goalDisallowed(.home)` puts it back. Cards and subs accumulate the
    // same way, which is what a PINNED CAPSULE's timeline is rebuilt from.
    //
    // `silent: true` beats at `at: 0` build the state the app opens on —
    // finished results and matches already in progress — without firing a
    // single pill. Everything after that is the live show.
    //
    // Beats are played in `at` order regardless of where they sit in this
    // array (DemoEngine sorts), so blocks stay grouped per match. Beats are
    // ~8s apart across matches so each pill/celebration gets its moment. A
    // fixture with NO moments never kicks off: it stays SCHEDULED.
    static let timeline: [DemoMoment] = [
        // ── YESTERDAY: Atlético Madrid 1-3 Real Madrid (FT) ─────────────
        DemoMoment(at: 0, .atmMad, minute: 1,  silent: true, .kickoff),
        DemoMoment(at: 0, .atmMad, minute: 11, silent: true, .goal(.away, player: "Kylian Mbappé")),       // 0-1
        DemoMoment(at: 0, .atmMad, minute: 34, silent: true, .goal(.home, player: "Julián Álvarez")),      // 1-1
        DemoMoment(at: 0, .atmMad, minute: 45, silent: true, .halfTime),
        DemoMoment(at: 0, .atmMad, minute: 58, silent: true, .yellowCard(.home, player: "Koke")),
        DemoMoment(at: 0, .atmMad, minute: 67, silent: true, .goal(.away, player: "Jude Bellingham")),     // 1-2
        DemoMoment(at: 0, .atmMad, minute: 88, silent: true, .goal(.away, player: "Vinícius Júnior")),     // 1-3
        DemoMoment(at: 0, .atmMad, minute: 90, silent: true, .fullTime),

        // ── YESTERDAY: Bayern München 4-0 RB Leipzig (FT) ───────────────
        DemoMoment(at: 0, .bayRbl, minute: 1,  silent: true, .kickoff),
        DemoMoment(at: 0, .bayRbl, minute: 8,  silent: true, .goal(.home, player: "Harry Kane")),          // 1-0
        DemoMoment(at: 0, .bayRbl, minute: 29, silent: true, .goal(.home, player: "Michael Olise")),       // 2-0
        DemoMoment(at: 0, .bayRbl, minute: 45, silent: true, .halfTime),
        DemoMoment(at: 0, .bayRbl, minute: 61, silent: true, .goal(.home, player: "Harry Kane", kind: "penalty")), // 3-0
        DemoMoment(at: 0, .bayRbl, minute: 79, silent: true, .goal(.home, player: "Jamal Musiala")),       // 4-0
        DemoMoment(at: 0, .bayRbl, minute: 90, silent: true, .fullTime),

        // ── TODAY, EARLIER: Liverpool 2-1 Manchester United (FT) ────────
        DemoMoment(at: 0, .livMun, minute: 1,  silent: true, .kickoff),
        DemoMoment(at: 0, .livMun, minute: 14, silent: true, .goal(.home, player: "Mohamed Salah")),       // 1-0
        DemoMoment(at: 0, .livMun, minute: 39, silent: true, .yellowCard(.away, player: "Casemiro")),
        DemoMoment(at: 0, .livMun, minute: 45, silent: true, .halfTime),
        DemoMoment(at: 0, .livMun, minute: 53, silent: true, .goal(.away, player: "Bruno Fernandes", kind: "penalty")), // 1-1
        DemoMoment(at: 0, .livMun, minute: 64, silent: true, .substitution(.home, playerIn: "Florian Wirtz", playerOut: "Curtis Jones")),
        DemoMoment(at: 0, .livMun, minute: 81, silent: true, .goal(.home, player: "Florian Wirtz")),       // 2-1
        DemoMoment(at: 0, .livMun, minute: 90, silent: true, .fullTime),

        // ── LIVE: Manchester City vs Arsenal — opens 0-1, 2nd half ──────
        // City followed (celebrates), Arsenal not (pills). Haaland brace
        // turns it round; Ødegaard's equaliser is chalked off by VAR.
        DemoMoment(at: 0,   .mciArs, minute: 1,  silent: true, .kickoff),
        DemoMoment(at: 0,   .mciArs, minute: 12, silent: true, .goal(.away, player: "Bukayo Saka")),       // 0-1
        DemoMoment(at: 0,   .mciArs, minute: 29, silent: true, .yellowCard(.home, player: "Rodri")),
        DemoMoment(at: 0,   .mciArs, minute: 45, silent: true, .halfTime),
        DemoMoment(at: 0,   .mciArs, minute: 52, silent: true, .substitution(.away, playerIn: "Gabriel Martinelli", playerOut: "Leandro Trossard")),
        DemoMoment(at: 4,   .mciArs, minute: 58, .goal(.home, player: "Erling Haaland")),                  // 1-1 🎉
        DemoMoment(at: 20,  .mciArs, minute: 63, .yellowCard(.away, player: "Declan Rice")),
        DemoMoment(at: 44,  .mciArs, minute: 67, .substitution(.home, playerIn: "Phil Foden", playerOut: "Omar Marmoush")),
        DemoMoment(at: 66,  .mciArs, minute: 71, .varDecision(.home, detail: "Penalty confirmed")),
        DemoMoment(at: 74,  .mciArs, minute: 73, .goal(.home, player: "Erling Haaland", kind: "penalty")), // 2-1 🎉
        DemoMoment(at: 90,  .mciArs, minute: 78, .goal(.away, player: "Martin Ødegaard")),                 // 2-2 pill
        DemoMoment(at: 98,  .mciArs, minute: 79, .goalDisallowed(.away)),                                  // VAR → 2-1
        DemoMoment(at: 122, .mciArs, minute: 86, .redCard(.away, player: "Gabriel Magalhães")),
        DemoMoment(at: 146, .mciArs, minute: 90, extra: 5, .fullTime),

        // ── LIVE: Real Madrid vs Barcelona — opens 1-0, 1st half ────────
        // Madrid followed (celebrates), Barça not (pills).
        DemoMoment(at: 0,   .madBar, minute: 1,  silent: true, .kickoff),
        DemoMoment(at: 0,   .madBar, minute: 18, silent: true, .goal(.home, player: "Vinícius Júnior")),   // 1-0
        DemoMoment(at: 0,   .madBar, minute: 31, silent: true, .yellowCard(.away, player: "Gavi")),
        DemoMoment(at: 12,  .madBar, minute: 38, .goal(.away, player: "Lamine Yamal")),                    // 1-1 pill
        DemoMoment(at: 28,  .madBar, minute: 41, .goal(.home, player: "Kylian Mbappé")),                   // 2-1 🎉
        DemoMoment(at: 52,  .madBar, minute: 45, extra: 2, .halfTime),
        DemoMoment(at: 106, .madBar, minute: 52, .goal(.home, player: "Jude Bellingham")),                 // 3-1 🎉
        DemoMoment(at: 130, .madBar, minute: 60, .goal(.away, player: "Robert Lewandowski")),              // 3-2 pill
        DemoMoment(at: 154, .madBar, minute: 64, .substitution(.home, playerIn: "Rodrygo", playerOut: "Vinícius Júnior")),
        DemoMoment(at: 170, .madBar, minute: 71, .yellowCard(.away, player: "Raphinha")),
        DemoMoment(at: 186, .madBar, minute: 82, .goal(.home, player: "Kylian Mbappé")),                   // 4-2 🎉
        DemoMoment(at: 202, .madBar, minute: 90, extra: 3, .fullTime),

        // ── LIVE SOON: Bayern München vs Borussia Dortmund ──────────────
        // Listed as scheduled when the app opens, kicks off during the show.
        DemoMoment(at: 36,  .bayDor, minute: 1,  .kickoff),
        DemoMoment(at: 58,  .bayDor, minute: 9,  .goal(.home, player: "Harry Kane")),                     // 1-0 🎉
        DemoMoment(at: 82,  .bayDor, minute: 17, .yellowCard(.away, player: "Nico Schlotterbeck")),
        DemoMoment(at: 114, .bayDor, minute: 24, .goal(.home, player: "Jamal Musiala")),                   // 2-0 🎉
        DemoMoment(at: 138, .bayDor, minute: 31, .goal(.away, player: "Serhou Guirassy")),                 // 2-1 pill
        DemoMoment(at: 162, .bayDor, minute: 38, .goal(.home, player: "Michael Olise")),                   // 3-1 🎉
        DemoMoment(at: 194, .bayDor, minute: 45, extra: 1, .halfTime),

        // PSG vs Marseille, Inter vs Juventus and tomorrow's two fixtures have
        // no moments → they stay SCHEDULED at their kickoff times.

        // ── SYNTHETIC EDGE CASES (off by default) ───────────────────────
        // Extra time + a SHOOTOUT, so the capsule shows the pen tally
        // (`2+P3 – 2+P2`, spaced en-dash) and the "won on pens" full-time.
        // Drop Bayern's half-time above while you run it:
        // DemoMoment(at: 200, .bayDor, minute: 91,  .extraTime),
        // DemoMoment(at: 204, .bayDor, minute: 120, .penaltyShootout),
        // DemoMoment(at: 208, .bayDor, minute: 120, .penaltyKick(.home, player: "Harry Kane",     scored: true)),
        // DemoMoment(at: 212, .bayDor, minute: 120, .penaltyKick(.away, player: "Julian Brandt",  scored: true)),
        // DemoMoment(at: 216, .bayDor, minute: 120, .penaltyKick(.home, player: "Joshua Kimmich", scored: true)),
        // DemoMoment(at: 220, .bayDor, minute: 120, .penaltyKick(.away, player: "Karim Adeyemi",  scored: false)),
        // DemoMoment(at: 224, .bayDor, minute: 120, .fullTime),
        //
        // DISALLOWED-OFFSIDE PHANTOM: VAR chalks the goal off, the aggregate
        // drops but the event lingers (goalEvents.count > goals) — pin Madrid
        // and open it: the goal renders STRUCK THROUGH, scoreline still right.
        // DemoMoment(at: 34, .madBar, minute: 42, .goalDisallowedOffside(.home)),
    ]
}

// MARK: - Timeline vocabulary

/// A team in a demo match, named once so events can refer to a side. `id` is
/// the API team id (also the fan key); `logo` is its CDN image. Every id here
/// is in the live catalog (and in FakeScores.hardcodedCatalog), so the app
/// resolves its full name and its short code (the label the menu, pills and a
/// resting capsule show).
struct DemoTeam {
    let id: Int
    let code: String
    let name: String
    var logo: String { TeamCatalog.logoURL(id) }

    static let realMadrid = DemoTeam(id: 541, code: "REA", name: "Real Madrid")
    static let barcelona = DemoTeam(id: 529, code: "BAR", name: "Barcelona")
    static let atletico = DemoTeam(id: 530, code: "ATM", name: "Atletico Madrid")
    static let manCity = DemoTeam(id: 50, code: "MCI", name: "Manchester City")
    static let arsenal = DemoTeam(id: 42, code: "ARS", name: "Arsenal")
    static let liverpool = DemoTeam(id: 40, code: "LIV", name: "Liverpool")
    static let manUnited = DemoTeam(id: 33, code: "MUN", name: "Manchester United")
    static let chelsea = DemoTeam(id: 49, code: "CHE", name: "Chelsea")
    static let tottenham = DemoTeam(id: 47, code: "TOT", name: "Tottenham")
    static let bayern = DemoTeam(id: 157, code: "BAY", name: "Bayern München")
    static let dortmund = DemoTeam(id: 165, code: "DOR", name: "Borussia Dortmund")
    static let leipzig = DemoTeam(id: 173, code: "LEI", name: "RB Leipzig")
    static let psg = DemoTeam(id: 85, code: "PSG", name: "Paris Saint Germain")
    static let marseille = DemoTeam(id: 81, code: "MAR", name: "Marseille")
    static let inter = DemoTeam(id: 505, code: "INT", name: "Inter")
    static let juventus = DemoTeam(id: 496, code: "JUV", name: "Juventus")
}

/// When a demo fixture kicks off. Fixed against the moment the app launched
/// (not re-read from the clock), so rows never drift while you record.
enum DemoKickoff {
    /// Today, `minutes` from launch (negative = already kicked off), snapped
    /// to a quarter hour so it reads like a real schedule (19:30, not 19:37).
    /// Clamped into today so it never slips into the yesterday/tomorrow pages.
    case today(minutes: Int)
    /// `day` days from today (-1 yesterday, 1 tomorrow) at a fixed time.
    case day(Int, hour: Int, minute: Int)

    /// Launch time rounded down to the quarter hour.
    static let anchor: Date = {
        let now = Date()
        let minute = Calendar.current.component(.minute, from: now)
        let floored = Calendar.current.date(bySetting: .second, value: 0, of: now) ?? now
        return floored.addingTimeInterval(-Double((minute % 15) * 60 + Calendar.current.component(.second, from: now)))
    }()

    var date: Date {
        let calendar = Calendar.current
        switch self {
        case let .today(minutes):
            let date = Self.anchor.addingTimeInterval(Double(minutes) * 60)
            let start = calendar.startOfDay(for: Self.anchor)
            let latest = start.addingTimeInterval(24 * 60 * 60 - 15 * 60)
            return min(max(date, start), latest)
        case let .day(offset, hour, minute):
            let today = calendar.startOfDay(for: Self.anchor)
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
    }
}

/// One match the demo runs. Several play in parallel — see `demoMatches`.
struct DemoFixture {
    let id: Int
    let leagueId: Int
    let round: String
    let home: DemoTeam
    let away: DemoTeam
    let kickoff: DemoKickoff

    var kickoffTime: Date { kickoff.date }
}

extension DemoFixture {
    // ── Yesterday (finished)
    static let atmMad = DemoFixture(
        id: 1489310, leagueId: 140, round: "Regular Season - 8",
        home: .atletico, away: .realMadrid, kickoff: .day(-1, hour: 21, minute: 0)
    )
    static let bayRbl = DemoFixture(
        id: 1489311, leagueId: 78, round: "Regular Season - 7",
        home: .bayern, away: .leipzig, kickoff: .day(-1, hour: 18, minute: 30)
    )

    // ── Today
    /// Finished earlier today.
    static let livMun = DemoFixture(
        id: 1489302, leagueId: 39, round: "Regular Season - 8",
        home: .liverpool, away: .manUnited, kickoff: .today(minutes: -180)
    )
    /// Live in the second half when the app opens.
    static let mciArs = DemoFixture(
        id: 1489301, leagueId: 39, round: "Regular Season - 8",
        home: .manCity, away: .arsenal, kickoff: .today(minutes: -60)
    )
    /// Live in the first half when the app opens.
    static let madBar = DemoFixture(
        id: 1489303, leagueId: 140, round: "Regular Season - 9",
        home: .realMadrid, away: .barcelona, kickoff: .today(minutes: -30)
    )
    /// Scheduled at launch, kicks off during the show. Also the showcase's
    /// fixture (see DemoEngine.runShowcase).
    static let bayDor = DemoFixture(
        id: 1489304, leagueId: 78, round: "Regular Season - 8",
        home: .bayern, away: .dortmund, kickoff: .today(minutes: 0)
    )
    static let psgMar = DemoFixture(
        id: 1489306, leagueId: 61, round: "Regular Season - 8",
        home: .psg, away: .marseille, kickoff: .today(minutes: 90)
    )
    static let intJuv = DemoFixture(
        id: 1489305, leagueId: 135, round: "Regular Season - 7",
        home: .inter, away: .juventus, kickoff: .today(minutes: 150)
    )

    // ── Tomorrow (scheduled)
    static let totMci = DemoFixture(
        id: 1489320, leagueId: 39, round: "Regular Season - 9",
        home: .tottenham, away: .manCity, kickoff: .day(1, hour: 17, minute: 30)
    )
    static let livChe = DemoFixture(
        id: 1489321, leagueId: 39, round: "Regular Season - 9",
        home: .liverpool, away: .chelsea, kickoff: .day(1, hour: 20, minute: 0)
    )

    /// Every match the demo knows about (drives the scoreboard).
    static let demoMatches = [atmMad, bayRbl, livMun, mciArs, madBar, bayDor, psgMar, intJuv, totMci, livChe]
}

/// Which team an action belongs to, relative to its match's fixture.
enum DemoSide { case home, away }

/// What happens at a moment. The engine turns each into the same event the
/// poll-diff would produce, and keeps that match's scoreboard in step.
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
    /// Update the scoreboard but show NOTHING — no pill, no celebration. Use it
    /// for a match that was already over when you opened the app: it lands in
    /// the list at its real full-time score with its history intact, instead of
    /// replaying an hour of football as a pile of pills at t=0.
    let silent: Bool
    let action: DemoAction

    init(
        at: Double,
        _ fixture: DemoFixture,
        minute: Int,
        extra: Int? = nil,
        silent: Bool = false,
        _ action: DemoAction
    ) {
        self.at = at
        self.fixture = fixture
        self.minute = minute
        self.extra = extra
        self.silent = silent
        self.action = action
    }
}
#endif
