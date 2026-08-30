#if DEV_BACKEND
import Foundation

// ╔══════════════════════════════════════════════════════════════════════╗
// ║  DEMO SCRIPT — a deterministic show you can rehearse and present.     ║
// ║  Edit the timeline below, ⌘R, and the SAME events fire at the SAME    ║
// ║  seconds with the SAME scoreline every run — no randomness. Several   ║
// ║  matches run in parallel; each moment names which one it belongs to.  ║
// ║  Compiled only into Debug (DEV_BACKEND) builds; see DemoEngine in     ║
// ║  FakeBackend.swift for the runtime that plays it.                     ║
// ║                                                                       ║
// ║  Six famous fixtures, one per top-five league:                        ║
// ║    • "All Teams" shows all six.                                       ║
// ║    • "My Teams" shows exactly three — the ones involving `fanTeams`:  ║
// ║      Man City vs Arsenal, Real Madrid vs Barcelona, Bayern vs         ║
// ║      Dortmund.                                                        ║
// ║                                                                       ║
// ║  NOTHING BELOW IS MADE UP. Every goal, card, substitution and minute  ║
// ║  is lifted from a real meeting between those two clubs (each block    ║
// ║  names its match), so a pinned capsule's timeline reads like a real   ║
// ║  one. The only invented numbers are the celebration tap totals (our   ║
// ║  own metric, not match data) and the clearly-marked synthetic block   ║
// ║  at the bottom, which is commented out.                               ║
// ╚══════════════════════════════════════════════════════════════════════╝

@MainActor
enum DevConfig {
    /// You are signed in as this user before the first frame renders —
    /// no login window, no Google, no Keychain.
    static let profile = Profile(
        sub: "dev-user",
        email: "john@doe.com",
        name: "John Doe",
        photoURL: profilePhoto
    )

    /// The dev profile photo, loaded the same way a real Google photo is — any
    /// URL `TeamLogoStore` can fetch works here, including a local
    /// `file:///Users/you/me.jpg` if you'd rather not hit the network.
    private static let profilePhoto = "https://avatars.githubusercontent.com/u/32385519?v=4"

    /// Teams you follow, as API team ids: MCI 50, ARS 42, Real Madrid 541,
    /// Bayern 157. A goal by ANY of these runs the full celebration; everyone
    /// else's goals are notch pills. This picks exactly three of the six demo
    /// fixtures into "My Teams", and deliberately mixes the two cases:
    ///   • mciArs — BOTH sides followed, so every goal there celebrates.
    ///   • madBar / bayDor — home side only, so the away goals stay pills.
    /// Man United vs Liverpool, Inter vs Milan and PSG vs Marseille have no
    /// followed team, so they only ever show under "All Teams".
    static let fanTeams = ["50", "42", "541", "157"]

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
    // fixture   which parallel match the event belongs to (.mciArs, …).
    // `minute`  the real match clock (`extra:` is the `+7` in `45+7`).
    // Scores per match are tracked automatically as goals fire, so you never
    // hand-maintain a scoreline: a `.goal(.home)` makes it 1-0, a later
    // `.goalDisallowed(.home)` puts it back. Cards and subs accumulate the
    // same way, which is what a PINNED CAPSULE's hover timeline is rebuilt
    // from — that's why every fan match below carries its goals, yellows,
    // reds and substitutions, not just the goals.
    //
    // HOW MANY MATCHES ARE LIVE AT ONCE is purely a function of the `at`
    // values: a fixture is live from its `.kickoff` until its `.fullTime`, so
    // overlapping those windows is how you get two (or three) running side by
    // side — as written, City–Arsenal, Madrid–Barça and Bayern–Dortmund are
    // all live around t=45–48s, which stresses the notch stack, goal-priority
    // selection and the shared center-ball celebration. Want one at a time?
    // Push each kickoff past the previous full-time.
    //
    // Beats are played in `at` order regardless of where they sit in this
    // array (DemoEngine sorts), so blocks can stay grouped per match while you
    // retime them. Moments sharing the same `at` fire together. A fixture with
    // NO moments never kicks off: it stays SCHEDULED and shows in "All Teams"
    // with its kickoff time (see `kickoffOffsetMinutes`).
    static let timeline: [DemoMoment] = [
        // ── Manchester United 3-2 Liverpool — SILENT ────────────────────
        // Real match: Premier League, 3 May 2026, Old Trafford.
        // Every beat is `silent: true`, so the match is simply already over
        // when the app opens: it sits in "All Teams" at 3-2 with its history,
        // and not one pill fires. That's also what production does — a match
        // with no followed team is never polled, so it can't notify anything.
        DemoMoment(at: 0, .munLiv, minute: 1,  silent: true, .kickoff),
        DemoMoment(at: 0, .munLiv, minute: 6,  silent: true, .goal(.home, player: "Matheus Cunha")),   // 1-0
        DemoMoment(at: 0, .munLiv, minute: 14, silent: true, .goal(.home, player: "Benjamin Šeško")),  // 2-0
        DemoMoment(at: 0, .munLiv, minute: 45, silent: true, .halfTime),
        DemoMoment(at: 0, .munLiv, minute: 47, silent: true, .goal(.away, player: "Dominik Szoboszlai")), // 2-1
        DemoMoment(at: 0, .munLiv, minute: 49, silent: true, .yellowCard(.home, player: "Luke Shaw")),
        DemoMoment(at: 0, .munLiv, minute: 56, silent: true, .goal(.away, player: "Cody Gakpo")),      // 2-2
        DemoMoment(at: 0, .munLiv, minute: 75, silent: true, .yellowCard(.away, player: "Curtis Jones")),
        DemoMoment(at: 0, .munLiv, minute: 77, silent: true, .goal(.home, player: "Kobbie Mainoo")),   // 3-2
        DemoMoment(at: 0, .munLiv, minute: 81, silent: true, .yellowCard(.home, player: "Bruno Fernandes")),
        DemoMoment(at: 0, .munLiv, minute: 85, silent: true, .yellowCard(.away, player: "Cody Gakpo")),
        DemoMoment(at: 0, .munLiv, minute: 90, silent: true, .fullTime),

        // ── Manchester City 2-1 Arsenal ─────────────────────────────────
        // Real match: Premier League, 19 April 2026, Etihad Stadium.
        // BOTH sides are followed, so every goal here is a full center-ball
        // celebration — including Arsenal's. Kicks off first, at t=2.
        DemoMoment(at: 30 + 10,  .mciArs, minute: 1,  .kickoff),
        DemoMoment(at: 30 + 20,  .mciArs, minute: 15, .yellowCard(.home, player: "Marc Guéhi")),
        DemoMoment(at: 30 + 30, .mciArs, minute: 16, .goal(.home, player: "Rayan Cherki")),    // 1-0
        DemoMoment(at: 30 + 40, .mciArs, minute: 18, .goal(.away, player: "Kai Havertz")),     // 1-1
        DemoMoment(at: 30 + 50, .mciArs, minute: 36, .yellowCard(.away, player: "Cristhian Mosquera")),
        DemoMoment(at: 30 + 60, .mciArs, minute: 45, .halfTime),
        DemoMoment(at: 30 + 70, .mciArs, minute: 45, .celebrationSurge(["50": 3_800_000, "42": 2_400_000])),
        DemoMoment(at: 30 + 80, .mciArs, minute: 45, .substitution(.away, playerIn: "Gabriel Martinelli", playerOut: "Noni Madueke")),
        DemoMoment(at: 30 + 90, .mciArs, minute: 65, .goal(.home, player: "Erling Haaland")),  // 2-1
        DemoMoment(at: 30 + 100, .mciArs, minute: 74, .substitution(.away, playerIn: "Leandro Trossard", playerOut: "Eberechi Eze")),
        DemoMoment(at: 30 + 120, .mciArs, minute: 74, .substitution(.away, playerIn: "Ben White", playerOut: "Cristhian Mosquera")),
        DemoMoment(at: 30 + 130, .mciArs, minute: 82, .yellowCard(.away, player: "Gabriel Magalhães")),
        DemoMoment(at: 30 + 140, .mciArs, minute: 84, .substitution(.away, playerIn: "Viktor Gyökeres", playerOut: "Martín Zubimendi")),
        DemoMoment(at: 30 + 150, .mciArs, minute: 85, .substitution(.home, playerIn: "Phil Foden", playerOut: "Rayan Cherki")),
        DemoMoment(at: 30 + 160, .mciArs, minute: 88, .substitution(.home, playerIn: "Nico González", playerOut: "Rodri")),
        DemoMoment(at: 30 + 170, .mciArs, minute: 88, .substitution(.home, playerIn: "Sávio", playerOut: "Jeremy Doku")),
        DemoMoment(at: 30 + 180, .mciArs, minute: 90, extra: 6, .substitution(.home, playerIn: "Nathan Aké", playerOut: "Antoine Semenyo")),
        DemoMoment(at: 30 + 190, .mciArs, minute: 90, .fullTime),

        // ── Real Madrid 2-1 Barcelona ───────────────────────────────────
        // Real match: LaLiga, 26 October 2025, Santiago Bernabéu — the last
        // Clásico played at Madrid's ground, so home/away match this fixture
        // (the newer one, 10 May 2026, was Barcelona 2-0 at Camp Nou). It is
        // also the Clásico with the SENDINGS-OFF: Pedri's second yellow at
        // 90+10 and Lunin's red after the final whistle, which is what puts
        // red cards on the capsule timeline. Only Madrid is followed, so
        // Barça's goal is a pill while Madrid's two celebrate.
        // Kicks off 18s after City–Arsenal — the two run side by side, while
        // their listed kickoff times stay an hour apart.
        DemoMoment(at: 190 + 10, .madBar, minute: 1,  .kickoff),
        DemoMoment(at: 190 + 20, .madBar, minute: 22, .goal(.home, player: "Kylian Mbappé")),   // 1-0
        DemoMoment(at: 190 + 30, .madBar, minute: 23, .yellowCard(.home, player: "Federico Valverde")),
        DemoMoment(at: 190 + 40, .madBar, minute: 38, .goal(.away, player: "Fermín López")),    // 1-1, pill only
        DemoMoment(at: 190 + 50, .madBar, minute: 42, .yellowCard(.away, player: "Pedri")),
        DemoMoment(at: 190 + 60, .madBar, minute: 43, .goal(.home, player: "Jude Bellingham")), // 2-1
        DemoMoment(at: 190 + 70, .madBar, minute: 45, .halfTime),
        DemoMoment(at: 190 + 80, .madBar, minute: 45, .celebrationSurge(["541": 5_100_000, "529": 4_700_000])),
        DemoMoment(at: 190 + 90, .madBar, minute: 66, .substitution(.home, playerIn: "Brahim Díaz", playerOut: "Arda Güler")),
        DemoMoment(at: 190 + 100, .madBar, minute: 72, .substitution(.home, playerIn: "Dani Carvajal", playerOut: "Federico Valverde")),
        DemoMoment(at: 190 + 120, .madBar, minute: 72, .substitution(.home, playerIn: "Rodrygo", playerOut: "Vinícius Júnior")),
        DemoMoment(at: 190 + 130, .madBar, minute: 74, .substitution(.away, playerIn: "Ronald Araújo", playerOut: "Eric García")),
        DemoMoment(at: 190 + 140, .madBar, minute: 74, .substitution(.away, playerIn: "Marc Casadó", playerOut: "Ferran Torres")),
        DemoMoment(at: 190 + 150, .madBar, minute: 83, .substitution(.away, playerIn: "Roony Bardghji", playerOut: "Pau Cubarsí")),
        DemoMoment(at: 190 + 160, .madBar, minute: 90, .substitution(.home, playerIn: "Gonzalo García", playerOut: "Jude Bellingham")),
        DemoMoment(at: 190 + 170, .madBar, minute: 90, extra: 1, .substitution(.home, playerIn: "Dani Ceballos", playerOut: "Kylian Mbappé")),
        DemoMoment(at: 190 + 180, .madBar, minute: 90, extra: 7, .substitution(.away, playerIn: "Gerard Martín", playerOut: "Alejandro Balde")),
        // Pedri walks for a second yellow, then it boils over after the whistle.
        DemoMoment(at: 190 + 190,  .madBar, minute: 90, extra: 10, .redCard(.away, player: "Pedri")),
        DemoMoment(at: 190 + 200, .madBar, minute: 90, extra: 11, .yellowCard(.home, player: "Rodrygo")),
        DemoMoment(at: 190 + 210, .madBar, minute: 90, extra: 11, .yellowCard(.away, player: "Ferran Torres")),
        DemoMoment(at: 190 + 220, .madBar, minute: 90, extra: 11, .redCard(.home, player: "Andriy Lunin")),
        DemoMoment(at: 190 + 230, .madBar, minute: 90, .fullTime),

        // ── Bayern München 3-2 Borussia Dortmund ────────────────────────
        // Real match: Der Klassiker, Bundesliga, 28 February 2026 — played at
        // Dortmund, so the sides are swapped here to keep Bayern at home; the
        // events themselves are exactly as they happened. Kicks off last, so
        // for a stretch all three followed matches are live at once. Only
        // Bayern is followed: Kane's two (one from the spot, so the pill reads
        // "Penalty goal") and Kimmich's winner celebrate, Dortmund's are pills.
        // DemoMoment(at: 40,  .bayDor, minute: 1,  .kickoff),
        // DemoMoment(at: 46,  .bayDor, minute: 20, .yellowCard(.away, player: "Nico Schlotterbeck")),
        // DemoMoment(at: 58,  .bayDor, minute: 26, .goal(.away, player: "Nico Schlotterbeck")), // 0-1, pill only
        // DemoMoment(at: 63,  .bayDor, minute: 45, .halfTime),
        // DemoMoment(at: 67,  .bayDor, minute: 45, .celebrationSurge(["157": 2_900_000, "165": 1_300_000])),
        // DemoMoment(at: 71,  .bayDor, minute: 45, extra: 5, .substitution(.away, playerIn: "Ramy Bensebaini", playerOut: "Emre Can")),
        // DemoMoment(at: 76,  .bayDor, minute: 54, .goal(.home, player: "Harry Kane")),         // 1-1
        // DemoMoment(at: 80,  .bayDor, minute: 62, .substitution(.home, playerIn: "Jamal Musiala", playerOut: "Serge Gnabry")),
        // DemoMoment(at: 84,  .bayDor, minute: 67, .substitution(.away, playerIn: "Serhou Guirassy", playerOut: "Fábio Silva")),
        // DemoMoment(at: 88,  .bayDor, minute: 70, .goal(.home, player: "Harry Kane", kind: "penalty")), // 2-1
        // DemoMoment(at: 92,  .bayDor, minute: 74, .substitution(.away, playerIn: "Julian Brandt", playerOut: "Karim Adeyemi")),
        // DemoMoment(at: 95,  .bayDor, minute: 75, .substitution(.away, playerIn: "Jobe Bellingham", playerOut: "Felix Nmecha")),
        // DemoMoment(at: 99,  .bayDor, minute: 75, .substitution(.away, playerIn: "Samuele Inácio", playerOut: "Maximilian Beier")),
        // DemoMoment(at: 114, .bayDor, minute: 83, .goal(.away, player: "Daniel Svensson")),    // 2-2
        // DemoMoment(at: 120, .bayDor, minute: 87, .goal(.home, player: "Joshua Kimmich")),     // 3-2
        // DemoMoment(at: 124, .bayDor, minute: 90, .substitution(.home, playerIn: "Tom Bischof", playerOut: "Konrad Laimer")),
        // DemoMoment(at: 127, .bayDor, minute: 90, extra: 2, .substitution(.home, playerIn: "Leon Goretzka", playerOut: "Joshua Kimmich")),
        // DemoMoment(at: 130, .bayDor, minute: 90, extra: 2, .substitution(.home, playerIn: "Kim Min-Jae", playerOut: "Michael Olise")),
        // DemoMoment(at: 134, .bayDor, minute: 90, .fullTime),

        // Inter vs Milan and PSG vs Marseille have no moments → they stay
        // SCHEDULED, listed under "All Teams" at 16:30 and 17:30.

        // ── SYNTHETIC EDGE CASES (off by default) ───────────────────────
        // None of this happened in the real matches above — it exists only to
        // exercise rendering that a league fixture can't produce. Uncomment a
        // block to run it, and drop the conflicting real beats (e.g. Bayern's
        // 90' full-time) while you do.
        //
        // Extra time + a SHOOTOUT, so the capsule shows the pen tally
        // (`2+P3 – 2+P2`, spaced en-dash) and the "won on pens" full-time:
        // DemoMoment(at: 138, .bayDor, minute: 91,  .extraTime),
        // DemoMoment(at: 142, .bayDor, minute: 120, .penaltyShootout),
        // DemoMoment(at: 146, .bayDor, minute: 120, .penaltyKick(.home, player: "Harry Kane",     scored: true)),
        // DemoMoment(at: 150, .bayDor, minute: 120, .penaltyKick(.away, player: "Julian Brandt",  scored: true)),
        // DemoMoment(at: 154, .bayDor, minute: 120, .penaltyKick(.home, player: "Joshua Kimmich", scored: true)),
        // DemoMoment(at: 158, .bayDor, minute: 120, .penaltyKick(.away, player: "Karim Adeyemi",  scored: false)),
        // DemoMoment(at: 162, .bayDor, minute: 120, .fullTime),
        //
        // DISALLOWED-OFFSIDE PHANTOM: VAR chalks the goal off, the aggregate
        // drops but the event lingers (goalEvents.count > goals) — pin Madrid
        // and hover: the 22' goal renders STRUCK THROUGH, scoreline still right.
        // DemoMoment(at: 34, .madBar, minute: 23, .goalDisallowedOffside(.home)),
        //
        // VAR pill, then an OUT-OF-ORDER one that must be IGNORED: by t=64 the
        // 82' yellow is the latest event routed, so EventRouter's staleness
        // guard drops a backfilled 55' decision — no pill should appear.
        // DemoMoment(at: 8,  .mciArs, minute: 15, .varDecision(.home, detail: "Penalty confirmed")),
        // DemoMoment(at: 64, .mciArs, minute: 55, .varDecision(.home, detail: "Penalty confirmed")),
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
}

/// One match the demo runs. Several play in parallel — see `demoMatches`.
struct DemoFixture {
    let id: Int
    let leagueId: Int
    let round: String
    let home: DemoTeam
    let away: DemoTeam
    /// The fixture's kickoff time, as a 24h hour and minute — a FAKE clock, not
    /// an offset from when you hit Play. Today's date is filled in around it, so
    /// "All Teams" reads like a printed matchday (12:30, 13:30, 14:30 …)
    /// however long the reel has been running. Independent of the `at` seconds
    /// in the timeline: two matches can kick off 20 seconds apart in the demo
    /// and still show an hour between them here. Keep the hours between 00 and
    /// 23 — a row outside today is filtered out by `publishFixtures()`.
    let kickoffHour: Int
    let kickoffMinute: Int

    /// `kickoffHour:kickoffMinute` today, in the local zone.
    var kickoffTime: Date {
        Calendar.current.date(
            bySettingHour: kickoffHour, minute: kickoffMinute, second: 0, of: Date()
        ) ?? Date()
    }
}

extension DemoFixture {
    // ── The six demo fixtures — one per top-five league, plus a second
    // Premier League tie. Three involve a DevConfig.fanTeams side and so appear
    // under "My Teams"; all six appear under "All Teams".

    /// Premier League, BOTH sides followed — every goal is a full celebration.
    static let mciArs = DemoFixture(
        id: 1489301, leagueId: 39, round: "Regular Season - 3",
        home: DemoTeam(id: 50, code: "MCI", name: "Manchester City"),
        away: DemoTeam(id: 42, code: "ARS", name: "Arsenal"),
        kickoffHour: 12, kickoffMinute: 30
    )
    /// Premier League, NEITHER side followed — finished before launch, so it
    /// opens at FT and only ever shows under "All Teams".
    static let munLiv = DemoFixture(
        id: 1489302, leagueId: 39, round: "Regular Season - 3",
        home: DemoTeam(id: 33, code: "MUN", name: "Manchester United"),
        away: DemoTeam(id: 40, code: "LIV", name: "Liverpool"),
        kickoffHour: 10, kickoffMinute: 30
    )
    /// La Liga, HOME side followed — Barcelona's goals stay pills.
    static let madBar = DemoFixture(
        id: 1489303, leagueId: 140, round: "Regular Season - 3",
        home: DemoTeam(id: 541, code: "REA", name: "Real Madrid"),
        away: DemoTeam(id: 529, code: "BAR", name: "Barcelona"),
        kickoffHour: 13, kickoffMinute: 30
    )
    /// Bundesliga, HOME side followed — the reel's card-heavy, penalty-goal
    /// fixture, and the showcase's (see DemoEngine.runShowcase).
    static let bayDor = DemoFixture(
        id: 1489304, leagueId: 78, round: "Regular Season - 3",
        home: DemoTeam(id: 157, code: "BAY", name: "Bayern München"),
        away: DemoTeam(id: 165, code: "DOR", name: "Borussia Dortmund"),
        kickoffHour: 15, kickoffMinute: 30
    )
    /// Serie A, no moments in the reel — stays SCHEDULED, neither side followed.
    static let intMil = DemoFixture(
        id: 1489305, leagueId: 135, round: "Regular Season - 3",
        home: DemoTeam(id: 505, code: "INT", name: "Inter"),
        away: DemoTeam(id: 489, code: "MIL", name: "AC Milan"),
        kickoffHour: 16, kickoffMinute: 30
    )
    /// Ligue 1, no moments in the reel — stays SCHEDULED, neither side followed.
    static let psgMar = DemoFixture(
        id: 1489306, leagueId: 61, round: "Regular Season - 3",
        home: DemoTeam(id: 85, code: "PSG", name: "Paris Saint Germain"),
        away: DemoTeam(id: 81, code: "MAR", name: "Marseille"),
        kickoffHour: 17, kickoffMinute: 30
    )

    /// Every match the demo runs in parallel (drives the live scoreboard).
    static let demoMatches = [mciArs, munLiv, madBar, bayDor, intMil, psgMar]
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
