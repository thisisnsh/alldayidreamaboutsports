import AppKit
import StoreKit

/// Asks for an App Store rating on followed-team goals: every 6th (6th, 12th,
/// 18th, …), but never twice within a week — a 6th goal asked recently skips
/// the 12th, and the next ask waits for the 18th. A goal is the best moment to
/// ask, and spacing them out keeps it from nagging. StoreKit still decides
/// whether the sheet actually appears (at most 3 times a year in App Store
/// builds).
@MainActor
enum ReviewPrompt {
    private static let goalCountKey = "followedTeamGoals"
    private static let lastRequestKey = "reviewLastRequestedAt"
    private static let interval = 6
    private static let minGap: TimeInterval = 7 * 24 * 60 * 60
    /// Let the goal pill land before the review sheet takes focus.
    private static let delay: Duration = .seconds(4)

    /// Count a goal if a followed team scored it. Called once per GOAL event —
    /// EventRouter's dedupe guarantees one call per goal.
    static func recordGoal(_ event: MatchEvent, fans: Set<Int>) {
        guard event.type == .goal,
              let scorer = event.teamId, fans.contains(scorer) else { return }
        let goals = AppDefaults.shared.integer(forKey: goalCountKey) + 1
        AppDefaults.shared.set(goals, forKey: goalCountKey)
        guard goals % interval == 0 else { return }
        let now = Date()
        if let last = AppDefaults.shared.object(forKey: lastRequestKey) as? Date,
           now.timeIntervalSince(last) < minGap {
            AppLog.info(.fixtures, "review_skipped goals=\(goals) reason=asked_this_week")
            return
        }
        AppDefaults.shared.set(now, forKey: lastRequestKey)
        AppLog.info(.fixtures, "review_requested goals=\(goals) fixture_id=\(event.fixtureId)")
        AppAnalytics.reviewRequested(goals: goals)
        Task {
            try? await Task.sleep(for: delay)
            // Menu bar app: nothing of ours is frontmost, so bring the app
            // forward or the sheet can open behind whatever the user is in.
            NSApp.activate(ignoringOtherApps: true)
            SKStoreReviewController.requestReview()
        }
    }
}
