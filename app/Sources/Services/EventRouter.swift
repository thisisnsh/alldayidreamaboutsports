import Foundation
import SwiftUI

/// Decides what each incoming event becomes:
/// - GOAL by a followed team → full celebration (crest confetti + tap window),
///   or a notch pill if the user prefers pills for goals
/// - everything else in a followed match → notch pill
/// The pill IS the notification — each event type can be toggled in Settings
/// (all on by default). Animations are queued so simultaneous matches never
/// overlap on screen.
@MainActor
final class EventRouter {
    static let shared = EventRouter()

    private var seenEventIds: [String] {
        get { AppDefaults.shared.stringArray(forKey: "handledEventIds") ?? [] }
        set { AppDefaults.shared.set(newValue, forKey: "handledEventIds") }
    }

    /// Out-of-order staleness tolerance (minutes). A VAR event whose incident
    /// minute is more than this behind the greatest minute we've ALREADY
    /// notified for a fixture is a late/backfilled decision and is suppressed.
    private static let eventStaleMinutes = 3

    /// Greatest incident minute we've already surfaced per fixture — the
    /// high-water mark for the out-of-order staleness guard. In-memory is enough:
    /// a restart reseeds LiveStore's baseline (which emits nothing), so there's
    /// no pre-launch event to replay against a lost mark.
    private var maxNotifiedMinute: [Int: Int] = [:]

    /// Drop every stored id for a fixture once its match is over. Event ids are
    /// `"<fixtureId>:<type>:…"`, so a finished match's ids share that prefix. A
    /// finished fixture is never polled again (LiveStore.finished) and a re-seen
    /// baseline is FINISHED (MatchDiff guard), so these ids can't recur —
    /// keeping them would just grow `handledEventIds` across a whole tournament.
    func purgeEvents(forFixture fixtureId: Int) {
        let prefix = "\(fixtureId):"
        let before = seenEventIds
        let remaining = before.filter { !$0.hasPrefix(prefix) }
        guard remaining.count != before.count else { return }
        seenEventIds = remaining
        maxNotifiedMinute[fixtureId] = nil
        AppLog.info(.fixtures, "event_storage_purged fixture_id=\(fixtureId) removed=\(before.count - remaining.count) remaining=\(remaining.count)")
    }

    func route(_ event: MatchEvent) {
        // The poll loop recomputes deterministic ids; drop anything we've
        // animated already (a re-read of an unchanged file diffs to nothing,
        // but a baseline-less restart could re-surface a recent transition).
        guard !seenEventIds.contains(event.eventId) else {
            AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=duplicate")
            AppAnalytics.eventDropped(reason: "duplicate", type: event.type.rawValue)
            return
        }
        var handled = seenEventIds
        handled.append(event.eventId)
        if handled.count > 500 { handled.removeFirst(250) }
        seenEventIds = handled

        if event.type == .goalCancelled {
            applyGoalCancellation(event)
        } else if event.type == .goal {
            // Symmetric with the cancellation below: a goal (re-)awarded at this
            // score frees its GOAL_CANCELLED id, so a second disallow at the
            // same score — 0→1→0→1→0 — isn't swallowed as a duplicate, which
            // would also leave the GOAL id stuck and drop the next 1.
            forgetEventId(event.eventId.replacingOccurrences(of: ":GOAL:", with: ":GOAL_CANCELLED:"))
        }

        // Count followed-team goals before the mute check: a muted goal pill
        // still means the team scored.
        ReviewPrompt.recordGoal(event, fans: AppSession.shared.fanTeamIds)

        let settings = AppSession.shared.prefs.settings
        guard settings.eventEnabled(event.type) else {
            AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=event_disabled type=\(event.type.rawValue)")
            // Are people muting event types? This is the only place that says so.
            AppAnalytics.eventDropped(reason: "event_disabled", type: event.type.rawValue)
            return
        }

        // Only matches involving a team the user is a fan of — the poll loop
        // already scopes which match files we read, but guard anyway.
        let fans = AppSession.shared.fanTeamIds
        guard fans.contains(event.homeTeamId) || fans.contains(event.awayTeamId) else {
            AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=no_followed_team")
            AppAnalytics.eventDropped(reason: "no_followed_team", type: event.type.rawValue)
            return
        }

        // Out-of-order staleness guard. An event's minute is API-Football's
        // incident minute, and the feed can inject a VAR outcome minutes after
        // the fact — surfacing a "67′" pill while play is at 79′. Suppress a
        // guarded event (VAR only) whose minute falls more than the
        // tolerance behind the greatest minute we've ALREADY notified for this
        // fixture. Non-guarded / minute-less events pass through, and every
        // minute-bearing event (goals, cards, subs) raises the mark.
        if let absMin = event.absoluteMinute {
            // Only a fixture we've already notified an event for has a mark; the
            // first event for a fixture can never be "out of order" (and this
            // avoids an Int.min underflow when a guarded event lands first).
            if event.type.isStalenessGuarded,
               let mark = maxNotifiedMinute[event.fixtureId],
               mark - absMin > Self.eventStaleMinutes {
                AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=stale_out_of_order event_min=\(absMin) max_notified=\(mark)")
                // Is the staleness guard eating real goals? Only this can tell us.
                AppAnalytics.eventDropped(reason: "stale_minute", type: event.type.rawValue)
                return
            }
            maxNotifiedMinute[event.fixtureId] = maxNotifiedMinute[event.fixtureId].map { Swift.max($0, absMin) } ?? absMin
        }

        let isFanGoal = event.type == .goal && event.teamId.map(fans.contains) == true
        AppLog.info(.fixtures, "event_routed event_id=\(event.eventId) type=\(event.type.rawValue) fixture_id=\(event.fixtureId) fan_goal=\(isFanGoal)")
        // The accepted half of the `event_dropped` split above: between them
        // they account for everything the feed produced — what reached a screen,
        // and where the rest went.
        let celebrates = isFanGoal && (settings.goalCenter ?? true)
        AppAnalytics.eventShown(type: event.type.rawValue,
                                presentation: celebrates ? "celebration" : "pill")

        // Every event joins the overlay queues. Goals are prioritized for the
        // next displayed set; followed-team goals fire their confetti only
        // once their goal pill reaches that set.
        OverlayManager.shared.submit(event, isFanGoal: isFanGoal)
    }

    /// A goal was taken back — stop celebrating it, and un-dedupe the matching
    /// GOAL id (ids are deterministic). If the goal is re-awarded — a real VAR
    /// reversal, or the feed self-correcting a transient drop on the next poll —
    /// MatchDiff re-emits GOAL and the pill actually shows, instead of the
    /// dedupe silently swallowing it. This is state, not presentation, so it
    /// runs even when the "Goal disallowed" pill itself is muted.
    private func applyGoalCancellation(_ event: MatchEvent) {
        OverlayManager.shared.cancelGoal(fixtureId: event.fixtureId, teamId: event.teamId)
        forgetEventId(event.eventId.replacingOccurrences(of: ":GOAL_CANCELLED:", with: ":GOAL:"))
    }

    private func forgetEventId(_ id: String) {
        guard let idx = seenEventIds.firstIndex(of: id) else { return }
        var ids = seenEventIds
        ids.remove(at: idx)
        seenEventIds = ids
    }
}

extension PrefSettings {
    /// Every event type is on by default; Settings → Events can switch any off.
    func eventEnabled(_ type: MatchEventType) -> Bool {
        (notifications ?? [:])[type.settingsKey, default: true]
    }
}

extension MatchEvent {
    /// The incident minute folded with stoppage `extra` for ordering comparisons,
    /// or nil for whole-match events (kickoff/HT/FT/…) that carry no minute.
    var absoluteMinute: Int? {
        minute.map { $0 + (extra ?? 0) }
    }
}

extension MatchEventType {
    /// Event types subject to the out-of-order staleness guard. Only VAR: it's
    /// the one the feed backfills long after the fact (a decision api-football
    /// injects minutes late), and a stale VAR pill is pure noise. Everything else
    /// — goals, cards, subs, status — always shows.
    var isStalenessGuarded: Bool {
        self == .varDecision
    }
}

extension MatchEventType {
    var settingsKey: String {
        switch self {
        case .kickoff: "kickoff"
        case .goal: "goals"
        case .goalCancelled: "var"
        case .yellowCard: "yellow_cards"
        case .redCard: "red_cards"
        case .halfTime: "half_time"
        // Shares half-time's toggle: one setting gates both the break's start
        // and end, so there's no separate "Second half" row in Settings.
        case .secondHalf: "half_time"
        case .fullTime: "full_time"
        case .extraTime: "extra_time"
        case .penaltyShootout: "penalties"
        case .penaltyKick: "penalty_kicks"
        case .substitution: "substitutions"
        case .varDecision: "var_decisions"
        }
    }
}

// MARK: Pill appearance — the SF Symbol carries the event; teams are logos.

/// One inline piece of a pill line: plain text or a team logo. Pills are built
/// as a sequence of these so a team reads as its rendered logo, never an emoji.
enum PillSegment {
    case text(String, bold: Bool = false)
    case logo(url: String)
}

@MainActor
private func teamLogo(_ id: Int) -> String {
    TeamCatalog.team(for: id, in: AppSession.shared.allTeams).logo
}

extension MatchEvent {
    /// The full name this payload carries for one side of the match — the
    /// fallback whenever the catalog has no shorter label for that team.
    func wireName(for teamId: Int) -> String {
        teamId == awayTeamId ? awayName : homeName
    }

    /// How a side is labelled in a pill: the catalog's short code, or the
    /// payload's full name when there's none. Pills are one line hanging off
    /// the notch, so they always take the compact form.
    @MainActor func shortName(for teamId: Int) -> String {
        TeamCatalog.shortName(for: teamId, in: AppSession.shared.allTeams, fallback: wireName(for: teamId))
    }
}

/// The leading team's (name, id), or nil when level. The matchup / score
/// itself rides in the subtitle row, so the title only needs the one team.
@MainActor
private func leaderInfo(for event: MatchEvent) -> (name: String, teamId: Int)? {
    guard event.homeGoals != event.awayGoals else { return nil }
    let teamId = event.homeGoals > event.awayGoals ? event.homeTeamId : event.awayTeamId
    return (event.shortName(for: teamId), teamId)
}

// Every in-match pill follows one grammar so the eye can learn it:
//   [SF icon] [minute′] Label — <bold key noun> [team logo]
// The SF icon (added by NotchPillRow) carries the event type; the team logo is
// always the rightmost element; the score lives in the subtitle. The three
// whole-match events (kickoff / extra time / shootout) have no single subject
// team, so they carry no trailing logo — both teams show in the score row.
@MainActor
func pillTitle(for event: MatchEvent) -> [PillSegment] {
    let minute = event.minute.map { "\($0)\(event.extra.map { "+\($0)" } ?? "")′ " } ?? ""
    let teamChip: [PillSegment] = event.teamId.map { [.logo(url: teamLogo($0))] } ?? []
    // The em-dash is its OWN segment (not baked into the label string) so the
    // uniform inter-segment gap falls equally on both sides — otherwise the
    // left gap is just the in-string space while the right gap is space + the
    // HStack spacing, and the dash sits visibly off-centre.
    let dash: PillSegment = .text(" — ")
    switch event.type {
    case .kickoff: return [.text("Kickoff")]
    case .goal:
        // Backend now always sends a scorer; if it's ever missing, name the
        // scoring team — never the home team (that mislabels away goals).
        let scorer = event.player ?? event.teamId.map { event.shortName(for: $0) } ?? ""
        let label: String
        switch event.goalKind {
        case "own": label = "Own goal"
        case "penalty": label = "Penalty goal"
        default: label = "Goal"
        }
        return [.text("\(minute)\(label)"), dash, .text("\(scorer) ", bold: true)] + teamChip
    // Neutral label + red xmark (icon set by NotchPillRow): a score drop can be
    // a feed correction, not only a VAR call — don't assert "VAR".
    case .goalCancelled: return [.text("\(minute)Goal disallowed ")] + teamChip
    case .yellowCard: return [.text("\(minute)Yellow card"), dash, .text("\(event.player ?? "") ", bold: true)] + teamChip
    case .redCard: return [.text("\(minute)Red card"), dash, .text("\(event.player ?? "") ", bold: true)] + teamChip
    case .halfTime:
        if let leader = leaderInfo(for: event) {
            return [.text("Half-time"), dash, .text(leader.name, bold: true), .text(" ahead "), .logo(url: teamLogo(leader.teamId))]
        }
        return [.text("Half-time"), dash, .text("Tight match")]
    case .secondHalf: return [.text("Second half starts")]
    case .fullTime:
        // After a shootout the winner is whoever has more pens, not goals.
        if let winner = shootoutWinnerInfo(for: event) {
            return [.text("Full-time"), dash, .text(winner.name, bold: true), .text(" won on pens "), .logo(url: teamLogo(winner.teamId))]
        }
        if let leader = leaderInfo(for: event) {
            return [.text("Full-time"), dash, .text(leader.name, bold: true), .text(" won "), .logo(url: teamLogo(leader.teamId))]
        }
        return [.text("Full-time"), dash, .text("Match draw")]
    case .extraTime: return [.text("Extra time")]
    case .penaltyShootout: return [.text("Penalty shootout!")]
    case .penaltyKick:
        let outcome = (event.scored ?? false) ? "scored ✓" : "missed ✗"
        return [.text("\(minute)Penalty"), dash, .text("\(event.player ?? "") ", bold: true), .text("\(outcome) ")] + teamChip
    case .substitution:
        // `player` = coming on (bold), `playerOut` = leaving.
        let onName = event.player ?? ""
        let offSuffix = event.playerOut.map { "for \($0) " } ?? ""
        return [.text("\(minute)Sub"), dash, .text("\(onName) ", bold: true), .text(offSuffix)] + teamChip
    case .varDecision:
        return [.text("\(minute)VAR"), dash, .text("\(event.varDetail ?? "Review") ")] + teamChip
    }
}

/// Score subheading. Text only — the secondary row carries no team logos (the
/// title row's trailing logo already identifies the subject team).
@MainActor
func pillSubtitle(for event: MatchEvent) -> [PillSegment]? {
    switch event.type {
    // Every in-match event shows the score row (kickoff reads 0 - 0, which
    // also gives us the "–" separator instead of a "vs").
    case .kickoff:
        return [
            .text("\(event.shortName(for: event.homeTeamId)) "),
            .text("vs"),
            .text(" \(event.shortName(for: event.awayTeamId))"),
        ]
    case .goal, .goalCancelled, .yellowCard, .redCard, .halfTime,
         .secondHalf, .fullTime, .extraTime, .penaltyShootout, .penaltyKick,
         .substitution, .varDecision:
        let scoreline = ScorelineFormatter.text(
            homeGoals: event.homeGoals,
            awayGoals: event.awayGoals,
            penHome: event.penHome,
            penAway: event.penAway
        )
        return [
            .text("\(event.shortName(for: event.homeTeamId)) "),
            .text(scoreline),
            .text(" \(event.shortName(for: event.awayTeamId))"),
        ]
    }
}

/// Winner of a decided shootout as (name, id), or nil if level / no shootout.
@MainActor
private func shootoutWinnerInfo(for event: MatchEvent) -> (name: String, teamId: Int)? {
    guard let home = event.penHome, let away = event.penAway, home != away else { return nil }
    let teamId = home > away ? event.homeTeamId : event.awayTeamId
    return (event.shortName(for: teamId), teamId)
}

func pillIcon(for event: MatchEvent) -> String {
    // A taken penalty reads as a converted goal or a miss.
    if event.type == .penaltyKick {
        return (event.scored ?? false) ? "checkmark.circle.fill" : "xmark.circle.fill"
    }
    return pillIcon(for: event.type)
}

func pillIcon(for type: MatchEventType) -> String {
    switch type {
    case .kickoff: "play.circle.fill"
    case .goal: "soccerball"
    case .goalCancelled: "xmark.circle.fill"
    case .yellowCard, .redCard: "rectangle.portrait.fill"
    case .halfTime: "pause.circle.fill"
    case .secondHalf: "play.circle.fill"
    case .fullTime: "flag.fill"
    case .extraTime: "clock.fill"
    case .penaltyShootout, .penaltyKick: "target"
    case .substitution: "arrow.left.arrow.right"
    case .varDecision: "video.fill"
    }
}

func pillIconColor(for event: MatchEvent) -> Color {
    if event.type == .penaltyKick {
        return (event.scored ?? false) ? .green : .red
    }
    return pillIconColor(for: event.type)
}

func pillIconColor(for type: MatchEventType) -> Color {
    switch type {
    case .yellowCard: .yellow
    case .redCard, .goalCancelled: .red
    case .kickoff: .green
    case .fullTime: .green
    case .penaltyShootout: .purple
    default: .primary
    }
}
