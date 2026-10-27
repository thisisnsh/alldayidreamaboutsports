import SwiftUI

// MARK: - Timeline

/// One flattened row of a match's timeline (goal / card / sub / VAR / penalty
/// kick), built straight from the `Fixture` scoreboard so the capsule needs no
/// event stream.
struct CapsuleTimelineRow: Identifiable {
    let id: String
    let minute: Int?
    let extra: Int?
    let icon: String
    let color: Color
    /// What happened: "Goal", "Own goal", "Sub", "VAR", …
    let label: String
    /// Who/what it happened to — player name(s) or VAR detail. Optional.
    let text: String?
    let teamId: Int?
    /// A goal the aggregate no longer counts (disallowed by VAR/offside): the
    /// authoritative `goals` count dropped but the scorer-attributed event still
    /// lingers in `goalEvents`. Rendered struck-through. Always false for
    /// non-goal rows.
    var disallowed: Bool = false

    /// Sort key: match minute (+ stoppage) ascending; shootout kicks (no minute)
    /// sort after everything in taken order.
    var sortKey: Int { minute.map { $0 * 100 + (extra ?? 0) } ?? 1_000_000 }

    var minuteText: String {
        guard let minute else { return "" }
        return extra.map { "\(minute)+\($0)′" } ?? "\(minute)′"
    }
}

@MainActor
func capsuleTimeline(for fixture: Fixture) -> [CapsuleTimelineRow] {
    var rows: [CapsuleTimelineRow] = []

    // `validCount` bounds how many of these events the aggregate still counts.
    // For goals, the authoritative `team.goals` can drop below `goalEvents.count`
    // on a VAR disallow while the reversed goal lingers in the event list — those
    // trailing (most-recent) entries are marked disallowed so they render struck.
    func add(_ events: [MatchTimelineEvent], type: MatchEventType, team: ScoreboardTeam, prefix: String, validCount: Int = .max) {
        for (index, event) in events.enumerated() {
            let label: String = switch (type, event.kind) {
            case (.goal, "own"): "Own goal"
            case (.goal, "penalty"): "Penalty goal"
            default: eventLabel(for: type)
            }
            rows.append(CapsuleTimelineRow(
                id: "\(fixture.fixtureId):\(prefix):\(team.id):\(index)",
                minute: event.minute,
                extra: event.extra,
                icon: pillIcon(for: type),
                color: pillIconColor(for: type),
                label: label,
                text: event.player,
                teamId: team.id,
                disallowed: index >= validCount
            ))
        }
    }

    for team in [fixture.home, fixture.away] {
        add(team.goalEvents, type: .goal, team: team, prefix: "g", validCount: team.goals)
        add(team.yellowCardEvents, type: .yellowCard, team: team, prefix: "y")
        add(team.redCardEvents, type: .redCard, team: team, prefix: "r")

        for (index, sub) in team.subs.enumerated() {
            let names = [sub.playerIn, sub.playerOut.map { "for \($0)" }]
                .compactMap { $0 }.joined(separator: " ")
            rows.append(CapsuleTimelineRow(
                id: "\(fixture.fixtureId):s:\(team.id):\(index)",
                minute: sub.minute,
                extra: sub.extra,
                icon: pillIcon(for: .substitution),
                color: pillIconColor(for: .substitution),
                label: eventLabel(for: .substitution),
                text: names.isEmpty ? nil : names,
                teamId: team.id
            ))
        }
    }

    for (index, record) in fixture.varEvents.enumerated() {
        rows.append(CapsuleTimelineRow(
            id: "\(fixture.fixtureId):v:\(index)",
            minute: record.minute,
            extra: record.extra,
            icon: pillIcon(for: .varDecision),
            color: pillIconColor(for: .varDecision),
            label: eventLabel(for: .varDecision),
            text: record.player.map { "\(record.detail) — \($0)" } ?? record.detail,
            teamId: record.teamId
        ))
    }

    for (index, kick) in (fixture.shootout?.kicks ?? []).enumerated() {
        let scored = kick.scored
        rows.append(CapsuleTimelineRow(
            id: "\(fixture.fixtureId):pk:\(index)",
            minute: nil,
            extra: nil,
            icon: scored ? "checkmark.circle.fill" : "xmark.circle.fill",
            color: scored ? .green : .red,
            label: "Penalty",
            text: kick.player ?? (scored ? "Scored" : "Missed"),
            teamId: kick.teamId
        ))
    }

    return rows.sorted { $0.sortKey < $1.sortKey }
}

private func eventLabel(for type: MatchEventType) -> String {
    switch type {
    case .goal: "Goal"
    case .yellowCard: "Yellow card"
    case .redCard: "Red card"
    case .substitution: "Sub"
    case .varDecision: "VAR"
    default: ""
    }
}
