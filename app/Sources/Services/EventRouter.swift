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

/// [logo] Home vs Away [logo] — the matchup chip used by kickoff / extra time.
@MainActor
private func matchupSegments(for event: MatchEvent) -> [PillSegment] {
    [
        .logo(url: teamLogo(event.homeTeamId)),
        .text(" \(event.homeName) vs \(event.awayName) "),
        .logo(url: teamLogo(event.awayTeamId)),
    ]
}

/// The leading team as [logo, name], or nil when level.
@MainActor
private func leaderSegments(for event: MatchEvent) -> [PillSegment]? {
    guard event.homeGoals != event.awayGoals else { return nil }
    let homeLeads = event.homeGoals > event.awayGoals
    return [
        .logo(url: teamLogo(homeLeads ? event.homeTeamId : event.awayTeamId)),
        .text(" \(homeLeads ? event.homeName : event.awayName)"),
    ]
}

@MainActor
func pillTitle(for event: MatchEvent) -> [PillSegment] {
    let minute = event.minute.map { "\($0)\(event.extra.map { "+\($0)" } ?? "")′ " } ?? ""
    let teamChip: [PillSegment] = event.teamId.map { [.logo(url: teamLogo($0))] } ?? []
    switch event.type {
    case .kickoff: return [.text("Kickoff — ")] + matchupSegments(for: event)
    case .goal:
        // Backend now always sends a scorer; if it's ever missing, name the
        // scoring team — never the home team (that mislabels away goals).
        let scorer = event.player ?? event.teamId.map(teamName) ?? ""
        return [.text("\(minute)Goal — \(scorer) ")] + teamChip
    case .goalCancelled: return [.text("\(minute)VAR — Goal Disallowed ")] + teamChip
    case .yellowCard: return [.text("\(minute)Yellow card — \(event.player ?? "") ")] + teamChip
    case .redCard: return [.text("\(minute)Red card — \(event.player ?? "") ")] + teamChip
    case .halfTime:
        if let leader = leaderSegments(for: event) {
            return [.text("Half-time — ")] + leader + [.text(" Ahead")]
        }
        return [.text("Half-time — Tight match")]
    case .fullTime:
        // After a shootout the winner is whoever has more pens, not goals.
        if let winner = shootoutWinnerSegments(for: event) {
            return [.text("Full-time — ")] + winner + [.text(" Won on pens")]
        }
        if let leader = leaderSegments(for: event) {
            return [.text("Full-time — ")] + leader + [.text(" Won")]
        }
        return [.text("Full-time — Match Draw")]
    case .extraTime: return [.text("Extra time — ")] + matchupSegments(for: event)
    case .penaltyShootout: return [.text("Penalty shootout!")]
    case .penaltyKick:
        let outcome = (event.scored ?? false) ? "scored ✓" : "missed ✗"
        return [.text("Penalties — \(event.player ?? "") \(outcome) ")] + teamChip
    case .celebration: return [] // never a backend event; counts build their own text
    }
}

/// Score subheading: [logo] Team 1 - 0 Team [logo], with "(pens 4-2)" when a
/// shootout is in play.
@MainActor
func pillSubtitle(for event: MatchEvent) -> [PillSegment]? {
    switch event.type {
    case .goal, .goalCancelled, .halfTime, .fullTime, .extraTime, .penaltyShootout, .penaltyKick:
        let pens = (event.penHome != nil || event.penAway != nil)
            ? " (pens \(event.penHome ?? 0)-\(event.penAway ?? 0))" : ""
        return [
            .logo(url: teamLogo(event.homeTeamId)),
            .text(" \(event.homeName) \(event.homeGoals) "),
            .text("-"),
            .text(" \(event.awayGoals) \(event.awayName) "),
            .logo(url: teamLogo(event.awayTeamId)),
            .text(pens),
        ]
    default:
        return nil
    }
}

/// Winner of a decided shootout as [logo, name], or nil if level / no shootout.
@MainActor
private func shootoutWinnerSegments(for event: MatchEvent) -> [PillSegment]? {
    guard let home = event.penHome, let away = event.penAway, home != away else { return nil }
    let homeWon = home > away
    return [
        .logo(url: teamLogo(homeWon ? event.homeTeamId : event.awayTeamId)),
        .text(" \(homeWon ? event.homeName : event.awayName)"),
    ]
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
    default: .white
    }
}
