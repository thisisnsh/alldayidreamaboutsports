import Foundation
import SwiftUI

/// Decides what each incoming event becomes:
/// - GOAL by a followed team → full celebration (ball + confetti + tap window),
///   or a notch pill if the user prefers pills for goals
/// - everything else in a followed match → notch pill
/// The pill IS the notification — each event type can be toggled in Settings
/// (all on by default). Animations are queued so simultaneous matches never
/// overlap on screen.
@MainActor
final class EventRouter {
    static let shared = EventRouter()

    private var seenEventIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "handledEventIds") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "handledEventIds") }
    }

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
        AppLog.info(.fixtures, "event_storage_purged fixture_id=\(fixtureId) removed=\(before.count - remaining.count) remaining=\(remaining.count)")
    }

    func route(_ event: MatchEvent) {
        guard ControlPlane.shared.isOperational else {
            AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=control_plane_disabled")
            return
        }
        // Signed out = silent.
        guard AppSession.shared.isSignedIn else {
            AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=signed_out")
            return
        }
        // The poll loop recomputes deterministic ids; drop anything we've
        // animated already (a re-read of an unchanged file diffs to nothing,
        // but a baseline-less restart could re-surface a recent transition).
        guard !seenEventIds.contains(event.eventId) else {
            AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=duplicate")
            return
        }
        var handled = seenEventIds
        handled.append(event.eventId)
        if handled.count > 500 { handled.removeFirst(250) }
        seenEventIds = handled

        let settings = AppSession.shared.prefs.settings
        guard settings.eventEnabled(event.type) else {
            AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=event_disabled type=\(event.type.rawValue)")
            return
        }

        // Only matches involving a team the user is a fan of — the poll loop
        // already scopes which match files we read, but guard anyway.
        let fans = AppSession.shared.fanTeamIds
        guard fans.contains(event.homeTeamId) || fans.contains(event.awayTeamId) else {
            AppLog.info(.fixtures, "event_rejected event_id=\(event.eventId) reason=no_followed_team")
            return
        }

        let isFanGoal = event.type == .goal && event.teamId.map(fans.contains) == true
        AppLog.info(.fixtures, "event_routed event_id=\(event.eventId) type=\(event.type.rawValue) fixture_id=\(event.fixtureId) fan_goal=\(isFanGoal)")

        // One queue for everything: the event joins the next notification
        // set; fan goals additionally drive confetti + the center ball when
        // their set displays.
        OverlayManager.shared.submit(event, isFanGoal: isFanGoal)

        // VAR took the goal back — stop celebrating it.
        if event.type == .goalCancelled {
            OverlayManager.shared.cancelGoal(fixtureId: event.fixtureId, teamId: event.teamId)
        }
    }
}

extension PrefSettings {
    /// Every event type is on by default; Settings → Events can switch any off.
    func eventEnabled(_ type: MatchEventType) -> Bool {
        (notifications ?? [:])[type.settingsKey, default: true]
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
        case .fullTime: "full_time"
        case .extraTime: "extra_time"
        case .penaltyShootout: "penalties"
        case .penaltyKick: "penalty_kicks"
        case .celebration: "celebrations"
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
    TeamCatalog.team(for: id, in: AppSession.shared.teams).logo
}

@MainActor
private func teamName(_ id: Int) -> String {
    TeamCatalog.team(for: id, in: AppSession.shared.teams).name
}

/// The leading team's (name, id), or nil when level. The matchup / score
/// itself rides in the subtitle row, so the title only needs the one team.
@MainActor
private func leaderInfo(for event: MatchEvent) -> (name: String, teamId: Int)? {
    guard event.homeGoals != event.awayGoals else { return nil }
    let homeLeads = event.homeGoals > event.awayGoals
    return homeLeads ? (event.homeName, event.homeTeamId) : (event.awayName, event.awayTeamId)
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
        let scorer = event.player ?? event.teamId.map(teamName) ?? ""
        return [.text("\(minute)Goal"), dash, .text("\(scorer) ", bold: true)] + teamChip
    case .goalCancelled: return [.text("\(minute)VAR"), dash, .text("Goal disallowed ")] + teamChip
    case .yellowCard: return [.text("\(minute)Yellow card"), dash, .text("\(event.player ?? "") ", bold: true)] + teamChip
    case .redCard: return [.text("\(minute)Red card"), dash, .text("\(event.player ?? "") ", bold: true)] + teamChip
    case .halfTime:
        if let leader = leaderInfo(for: event) {
            return [.text("Half-time"), dash, .text(leader.name, bold: true), .text(" ahead "), .logo(url: teamLogo(leader.teamId))]
        }
        return [.text("Half-time"), dash, .text("Tight match")]
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
    case .celebration: return [] // never a backend event; counts build their own text
    }
}

/// Score subheading: Team 1 - 0 Team, with "(pens 4-2)" when a shootout is in
/// play. Text only — the secondary row carries no team logos (the title row's
/// trailing logo already identifies the subject team).
@MainActor
func pillSubtitle(for event: MatchEvent) -> [PillSegment]? {
    switch event.type {
    // Every in-match event shows the score row (kickoff reads 0 - 0, which
    // also gives us the "–" separator instead of a "vs"); only celebrations,
    // which build their own text, fall through to nil.
    case .kickoff, .goal, .goalCancelled, .yellowCard, .redCard, .halfTime,
         .fullTime, .extraTime, .penaltyShootout, .penaltyKick:
        let pens = (event.penHome != nil || event.penAway != nil)
            ? " (pens \(event.penHome ?? 0)-\(event.penAway ?? 0))" : ""
        return [
            .text("\(event.homeName) \(event.homeGoals) "),
            .text("-"),
            .text(" \(event.awayGoals) \(event.awayName)"),
            .text(pens),
        ]
    default:
        return nil
    }
}

/// Winner of a decided shootout as (name, id), or nil if level / no shootout.
@MainActor
private func shootoutWinnerInfo(for event: MatchEvent) -> (name: String, teamId: Int)? {
    guard let home = event.penHome, let away = event.penAway, home != away else { return nil }
    let homeWon = home > away
    return homeWon ? (event.homeName, event.homeTeamId) : (event.awayName, event.awayTeamId)
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
    case .fullTime: "flag.fill"
    case .extraTime: "clock.fill"
    case .penaltyShootout, .penaltyKick: "target"
    case .celebration: "party.popper"
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
    case .celebration: .blue
    default: .primary
    }
}
