import Foundation

// ╔══════════════════════════════════════════════════════════════════════╗
// ║  DEMO SCRIPT — a deterministic made-up matchday. Edit the timeline    ║
// ║  below, ⌘R, and the SAME events fire at the SAME seconds with the     ║
// ║  SAME scoreline every run — no randomness. Several matches run in     ║
// ║  parallel; each moment names which one it belongs to. Debug builds    ║
// ║  play it at launch; every build (Staging, Release — App Review too)   ║
// ║  plays it when the Settings title is tapped five times (DemoMode).    ║
// ║  See DemoEngine in FakeBackend.swift for the runtime that plays it.   ║
// ║                                                                       ║
// ║  The matches are INVENTED: 20 real clubs, each in exactly one of 10   ║
// ║  fixtures, with made-up scorelines. One club per fixture is followed, ║
// ║  so every match lists and both celebrations and pills show. What the  ║
// ║  menu shows the moment the demo starts:                               ║
// ║    Yesterday  Atlético 2-0 Sevilla · Bayern 3-1 Leverkusen (FT)       ║
// ║    Today      Liverpool 2-1 Man United (FT, earlier today)            ║
// ║               Man City 0-1 Arsenal (LIVE, 2nd half)                   ║
// ║               Real Madrid 1-0 Barcelona (LIVE, 1st half)              ║
// ║               Inter vs Juventus (kicks off ~35s into the show)        ║
// ║               PSG vs Marseille · Dortmund vs Leipzig (later today)    ║
// ║    Tomorrow   Chelsea vs Tottenham · AC Milan vs Napoli               ║
// ║  Then ~4 minutes of goals (Haaland, Mbappé, Lautaro, Yamal …), cards, ║
// ║  subs, a VAR-disallowed goal, half-times and full-times. Inter vs     ║
// ║  Juventus is left running in the second half when the script ends.    ║
// ║                                                                       ║
// ║  Kickoff times are relative to when the demo starts (DemoKickoff), so ║
// ║  whenever it runs, live games kicked off a plausible while ago and    ║
// ║  scheduled ones are still ahead.                                      ║
// ╚══════════════════════════════════════════════════════════════════════╝

@MainActor
enum DevConfig {
    /// Teams you follow during the demo, as API team ids — one per fixture:
    /// Atlético 530, Bayern 157, Liverpool 40, Man City 50, Real Madrid 541,
    /// Inter 505, PSG 85, Dortmund 165, Chelsea 49, AC Milan 489. The menu
    /// lists only matches involving these. A goal by a followed team runs the
    /// full celebration; the opponent's goals (Arsenal, Barça, Juventus …) are
    /// notch pills — the show mixes both.
    static let fanTeams = ["530", "157", "40", "50", "541", "505", "85", "165", "49", "489"]

    /// Debug: start the timeline automatically at launch. Turn off to drive
    /// the show by hand from Settings → Demo (Play / Restart / Stop).
    static let autostart = true

    /// Replay from the top once the timeline finishes. Off: the show plays
    /// once and the final scoreboard stays put. Settings → Demo → Restart (or
    /// five more taps on the Settings title) replays it.
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
        // ── YESTERDAY: Atlético Madrid 2-0 Sevilla (FT) ─────────────────
        DemoMoment(at: 0, .atmSev, minute: 1,  silent: true, .kickoff),
        DemoMoment(at: 0, .atmSev, minute: 23, silent: true, .goal(.home, player: "Julián Álvarez")),      // 1-0
        DemoMoment(at: 0, .atmSev, minute: 45, silent: true, .halfTime),
        DemoMoment(at: 0, .atmSev, minute: 57, silent: true, .yellowCard(.home, player: "Koke")),
        DemoMoment(at: 0, .atmSev, minute: 71, silent: true, .goal(.home, player: "Julián Álvarez", kind: "penalty")), // 2-0
        DemoMoment(at: 0, .atmSev, minute: 90, silent: true, .fullTime),

        // ── YESTERDAY: Bayern München 3-1 Bayer Leverkusen (FT) ─────────
        DemoMoment(at: 0, .bayLev, minute: 1,  silent: true, .kickoff),
        DemoMoment(at: 0, .bayLev, minute: 8,  silent: true, .goal(.home, player: "Harry Kane")),          // 1-0
        DemoMoment(at: 0, .bayLev, minute: 29, silent: true, .goal(.away, player: "Patrik Schick")),       // 1-1
        DemoMoment(at: 0, .bayLev, minute: 45, silent: true, .halfTime),
        DemoMoment(at: 0, .bayLev, minute: 61, silent: true, .goal(.home, player: "Michael Olise")),       // 2-1
        DemoMoment(at: 0, .bayLev, minute: 79, silent: true, .goal(.home, player: "Jamal Musiala")),       // 3-1
        DemoMoment(at: 0, .bayLev, minute: 90, silent: true, .fullTime),

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

        // ── LIVE SOON: Inter vs Juventus ────────────────────────────────
        // Listed as scheduled when the demo starts, kicks off during the show
        // and is still running (2nd half) when the script ends, so there is
        // always a live match on the board afterwards.
        DemoMoment(at: 36,  .intJuv, minute: 1,  .kickoff),
        DemoMoment(at: 58,  .intJuv, minute: 9,  .goal(.home, player: "Lautaro Martínez")),               // 1-0 🎉
        DemoMoment(at: 82,  .intJuv, minute: 17, .yellowCard(.away, player: "Manuel Locatelli")),
        DemoMoment(at: 114, .intJuv, minute: 24, .goal(.home, player: "Marcus Thuram")),                  // 2-0 🎉
        DemoMoment(at: 138, .intJuv, minute: 31, .goal(.away, player: "Kenan Yıldız")),                   // 2-1 pill
        DemoMoment(at: 162, .intJuv, minute: 38, .goal(.home, player: "Nicolò Barella")),                 // 3-1 🎉
        DemoMoment(at: 194, .intJuv, minute: 45, extra: 1, .halfTime),
        DemoMoment(at: 226, .intJuv, minute: 46, .substitution(.away, playerIn: "Dušan Vlahović", playerOut: "Jonathan David")),

        // PSG vs Marseille, Dortmund vs Leipzig and tomorrow's two fixtures
        // have no moments → they stay SCHEDULED at their kickoff times.

        // ── SYNTHETIC EDGE CASES (off by default) ───────────────────────
        // Extra time + a SHOOTOUT, so the capsule shows the pen tally
        // (`2+P3 – 2+P2`, spaced en-dash) and the "won on pens" full-time.
        // Drop Inter's half-time and sub above while you run it:
        // DemoMoment(at: 200, .intJuv, minute: 91,  .extraTime),
        // DemoMoment(at: 204, .intJuv, minute: 120, .penaltyShootout),
        // DemoMoment(at: 208, .intJuv, minute: 120, .penaltyKick(.home, player: "Lautaro Martínez", scored: true)),
        // DemoMoment(at: 212, .intJuv, minute: 120, .penaltyKick(.away, player: "Dušan Vlahović",   scored: true)),
        // DemoMoment(at: 216, .intJuv, minute: 120, .penaltyKick(.home, player: "Nicolò Barella",   scored: true)),
        // DemoMoment(at: 220, .intJuv, minute: 120, .penaltyKick(.away, player: "Kenan Yıldız",     scored: false)),
        // DemoMoment(at: 224, .intJuv, minute: 120, .fullTime),
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
    static let sevilla = DemoTeam(id: 536, code: "SEV", name: "Sevilla")
    static let manCity = DemoTeam(id: 50, code: "MCI", name: "Manchester City")
    static let arsenal = DemoTeam(id: 42, code: "ARS", name: "Arsenal")
    static let liverpool = DemoTeam(id: 40, code: "LIV", name: "Liverpool")
    static let manUnited = DemoTeam(id: 33, code: "MUN", name: "Manchester United")
    static let chelsea = DemoTeam(id: 49, code: "CHE", name: "Chelsea")
    static let tottenham = DemoTeam(id: 47, code: "TOT", name: "Tottenham")
    static let bayern = DemoTeam(id: 157, code: "BAY", name: "Bayern München")
    static let leverkusen = DemoTeam(id: 168, code: "LEV", name: "Bayer Leverkusen")
    static let dortmund = DemoTeam(id: 165, code: "DOR", name: "Borussia Dortmund")
    static let leipzig = DemoTeam(id: 173, code: "LEI", name: "RB Leipzig")
    static let psg = DemoTeam(id: 85, code: "PSG", name: "Paris Saint Germain")
    static let marseille = DemoTeam(id: 81, code: "MAR", name: "Marseille")
    static let inter = DemoTeam(id: 505, code: "INT", name: "Inter")
    static let juventus = DemoTeam(id: 496, code: "JUV", name: "Juventus")
    static let milan = DemoTeam(id: 489, code: "MIL", name: "AC Milan")
    static let napoli = DemoTeam(id: 492, code: "NAP", name: "Napoli")
}

/// When a demo fixture kicks off. Fixed against the moment the demo started
/// (not re-read from the clock), so rows never drift while you record.
enum DemoKickoff {
    /// Today, `minutes` from launch (negative = already kicked off), snapped
    /// to a quarter hour so it reads like a real schedule (19:30, not 19:37).
    /// Clamped into today so it never slips into the yesterday/tomorrow pages.
    case today(minutes: Int)
    /// `day` days from today (-1 yesterday, 1 tomorrow) at a fixed time.
    case day(Int, hour: Int, minute: Int)

    /// Demo start rounded down to the quarter hour. Set at launch for Debug;
    /// `reanchor()` moves it each time DemoMode starts the show, so a demo
    /// turned on hours after launch still opens on a plausible matchday.
    private(set) static var anchor = quarterHourFloor(Date())

    static func reanchor() {
        anchor = quarterHourFloor(Date())
    }

    private static func quarterHourFloor(_ now: Date) -> Date {
        let calendar = Calendar.current
        let minute = calendar.component(.minute, from: now)
        let second = calendar.component(.second, from: now)
        let floored = calendar.date(bySetting: .second, value: 0, of: now) ?? now
        return floored.addingTimeInterval(-Double((minute % 15) * 60 + second))
    }

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

// Ids sit in a block (99000xx) no real API-Football fixture uses, so a demo
// match can never be mistaken for, or merged over, a real one.
extension DemoFixture {

    // ── Yesterday (finished)
    static let atmSev = DemoFixture(
        id: 9900001, leagueId: 140, round: "Regular Season - 8",
        home: .atletico, away: .sevilla, kickoff: .day(-1, hour: 21, minute: 0)
    )
    static let bayLev = DemoFixture(
        id: 9900002, leagueId: 78, round: "Regular Season - 7",
        home: .bayern, away: .leverkusen, kickoff: .day(-1, hour: 18, minute: 30)
    )

    // ── Today
    /// Finished earlier today.
    static let livMun = DemoFixture(
        id: 9900003, leagueId: 39, round: "Regular Season - 8",
        home: .liverpool, away: .manUnited, kickoff: .today(minutes: -180)
    )
    /// Live in the second half when the demo starts.
    static let mciArs = DemoFixture(
        id: 9900004, leagueId: 39, round: "Regular Season - 8",
        home: .manCity, away: .arsenal, kickoff: .today(minutes: -60)
    )
    /// Live in the first half when the demo starts.
    static let madBar = DemoFixture(
        id: 9900005, leagueId: 140, round: "Regular Season - 9",
        home: .realMadrid, away: .barcelona, kickoff: .today(minutes: -30)
    )
    /// Scheduled when the demo starts, kicks off during the show. Also the
    /// showcase's fixture (see DemoEngine.runShowcase).
    static let intJuv = DemoFixture(
        id: 9900006, leagueId: 135, round: "Regular Season - 7",
        home: .inter, away: .juventus, kickoff: .today(minutes: 0)
    )
    static let psgMar = DemoFixture(
        id: 9900007, leagueId: 61, round: "Regular Season - 8",
        home: .psg, away: .marseille, kickoff: .today(minutes: 90)
    )
    static let dorRbl = DemoFixture(
        id: 9900008, leagueId: 78, round: "Regular Season - 8",
        home: .dortmund, away: .leipzig, kickoff: .today(minutes: 150)
    )

    // ── Tomorrow (scheduled)
    static let cheTot = DemoFixture(
        id: 9900009, leagueId: 39, round: "Regular Season - 9",
        home: .chelsea, away: .tottenham, kickoff: .day(1, hour: 17, minute: 30)
    )
    static let milNap = DemoFixture(
        id: 9900010, leagueId: 135, round: "Regular Season - 8",
        home: .milan, away: .napoli, kickoff: .day(1, hour: 20, minute: 0)
    )

    /// Every match the demo knows about (drives the scoreboard).
    static let demoMatches = [atmSev, bayLev, livMun, mciArs, madBar, intJuv, psgMar, dorRbl, cheTot, milNap]
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
