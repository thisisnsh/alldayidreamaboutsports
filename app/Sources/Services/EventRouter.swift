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

    private var seenEventIds: [String] = []

    func handlePush(_ userInfo: [String: Any]) {
        guard ControlPlane.shared.isOperational else { return }
        switch userInfo["kind"] as? String {
        case "match_event":
            guard let event = MatchEvent(fcmData: userInfo) else { return }
            route(event)
        case "celebration_count":
            guard let fixtureId = Int(userInfo["fixtureId"] as? String ?? ""),
                  let json = (userInfo["totals"] as? String)?.data(using: .utf8),
                  let totals = try? JSONDecoder().decode([String: Int].self, from: json)
            else { return }
            AppSession.shared.celebrationTotals[fixtureId] = totals
        default:
            break
        }
    }

    func route(_ event: MatchEvent) {
        // FCM topics can redeliver; drop anything we've animated already.
        guard !seenEventIds.contains(event.eventId) else { return }
        seenEventIds.append(event.eventId)
        if seenEventIds.count > 200 { seenEventIds.removeFirst(100) }

        let settings = AppSession.shared.prefs.settings
        guard settings.eventEnabled(event.type) else { return }

        // Only matches involving a team the user is a fan of — FCM topics
        // scope this server-side, but dev simulations and redeliveries don't.
        let fans = AppSession.shared.fanTeamCodes
        guard fans.contains(event.homeTeam) || fans.contains(event.awayTeam) else { return }

        let isFanGoal = event.type == .goal && event.teamCode.map(fans.contains) == true

        // One queue for everything: the event joins the next notification
        // set; fan goals additionally drive confetti + the center ball when
        // their set displays.
        OverlayManager.shared.submit(event, isFanGoal: isFanGoal)

        // VAR took the goal back — stop celebrating it.
        if event.type == .goalCancelled {
            OverlayManager.shared.cancelGoal(fixtureId: event.fixtureId, teamCode: event.teamCode)
        }
        Task { await AppSession.shared.refreshFixtures() }
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
        case .penaltyShootout: "penalties"
        }
    }
}

// MARK: Pill appearance — the SF Symbol carries the event, no emoji icons.

@MainActor
func pillText(for event: MatchEvent) -> String {
    let teams = AppSession.shared.teams
    let flag = event.teamCode.map { TeamCatalog.team(for: $0, in: teams).flag } ?? ""
    let minute = event.minute.map { "\($0)′ " } ?? ""
    // Kickoff carries the matchup; score-bearing events (goal, half/full-time,
    // penalties) carry it in their score subheading instead.
    let homeFlag = TeamCatalog.team(for: event.homeTeam, in: teams).flag
    let awayFlag = TeamCatalog.team(for: event.awayTeam, in: teams).flag
    let matchup = "\(homeFlag) \(event.homeName) vs \(event.awayName) \(awayFlag)"
    switch event.type {
    case .kickoff: return "Kickoff — \(matchup)"
    case .goal: return "\(minute)Goal — \(event.player ?? event.teamCode ?? "") \(flag)"
    case .goalCancelled: return "\(minute)VAR: goal disallowed \(flag)"
    case .yellowCard: return "\(minute)Yellow card — \(event.player ?? "") \(flag)"
    case .redCard: return "\(minute)Red card — \(event.player ?? "") \(flag)"
    case .halfTime: return "Half-time"
    case .fullTime: return "Full-time"
    case .penaltyShootout: return "Penalty shootout!"
    }
}

/// Score subheading: 🏳️ Team 1 - 0 Team 🏳️
@MainActor
func pillSubtext(for event: MatchEvent) -> String? {
    switch event.type {
    case .goal, .halfTime, .fullTime, .penaltyShootout:
        let teams = AppSession.shared.teams
        let homeFlag = TeamCatalog.team(for: event.homeTeam, in: teams).flag
        let awayFlag = TeamCatalog.team(for: event.awayTeam, in: teams).flag
        return "\(homeFlag) \(event.homeName) \(event.homeGoals) - \(event.awayGoals) \(event.awayName) \(awayFlag)"
    default:
        return nil
    }
}

func pillIcon(for event: MatchEvent) -> String {
    pillIcon(for: event.type)
}

func pillIcon(for type: MatchEventType) -> String {
    switch type {
    case .kickoff: "play.circle.fill"
    case .goal: "soccerball"
    case .goalCancelled: "xmark.circle.fill"
    case .yellowCard, .redCard: "rectangle.portrait.fill"
    case .halfTime: "pause.circle.fill"
    case .fullTime: "flag.checkered"
    case .penaltyShootout: "target"
    }
}

func pillIconColor(for event: MatchEvent) -> Color {
    pillIconColor(for: event.type)
}

func pillIconColor(for type: MatchEventType) -> Color {
    switch type {
    case .yellowCard: .yellow
    case .redCard, .goalCancelled: .red
    case .kickoff: .green
    default: .white
    }
}
