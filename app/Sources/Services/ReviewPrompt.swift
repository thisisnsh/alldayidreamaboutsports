import AppKit
import StoreKit

/// Asks for an App Store rating on followed-team wins: the 1st, 7th, 13th, …
/// (every 6th, starting with the first). A win is the best moment to ask, and
/// spacing them out keeps it from nagging. StoreKit still decides whether the
/// sheet actually appears (at most 3 times a year in App Store builds).
@MainActor
enum ReviewPrompt {
    private static let winCountKey = "followedTeamWins"
    private static let interval = 6
    /// Let the full-time pill land before the review sheet takes focus.
    private static let delay: Duration = .seconds(4)

    /// Count a finished match if a followed team won it. Called once per
    /// FULL_TIME event — EventRouter's dedupe guarantees one call per match.
    static func recordFullTime(_ event: MatchEvent, fans: Set<Int>) {
        guard event.type == .fullTime,
              let winner = event.winnerTeamId, fans.contains(winner) else { return }
        let wins = AppDefaults.shared.integer(forKey: winCountKey) + 1
        AppDefaults.shared.set(wins, forKey: winCountKey)
        guard (wins - 1) % interval == 0 else { return }
        AppLog.info(.fixtures, "review_requested wins=\(wins) fixture_id=\(event.fixtureId)")
        AppAnalytics.reviewRequested(wins: wins)
        Task {
            try? await Task.sleep(for: delay)
            // Menu bar app: nothing of ours is frontmost, so bring the app
            // forward or the sheet can open behind whatever the user is in.
            NSApp.activate(ignoringOtherApps: true)
            SKStoreReviewController.requestReview()
        }
    }
}

extension MatchEvent {
    /// The winning side of a finished match — on pens after a shootout, else
    /// on goals — or nil for a draw.
    var winnerTeamId: Int? {
        if let home = penHome, let away = penAway, home != away {
            return home > away ? homeTeamId : awayTeamId
        }
        guard homeGoals != awayGoals else { return nil }
        return homeGoals > awayGoals ? homeTeamId : awayTeamId
    }
}
