import ActivityKit
import SwiftUI

/// iOS implementation of the pin control shared with the Mac score list.
@MainActor
final class PinnedCapsuleManager: ObservableObject {
    static let shared = PinnedCapsuleManager()
    @Published private(set) var pinnedFixtureIds: Set<Int> = []
    @Published var errorMessage: String?
    private var observers: [String: Task<Void, Never>] = [:]

    func isPinned(_ id: Int) -> Bool { pinnedFixtureIds.contains(id) }

    func restore() {
        let active = Activity<ScoreActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        pinnedFixtureIds = Set(active.map { $0.attributes.fixtureId })
        for activity in active { observe(activity) }
    }

    func toggle(fixtureId: Int) {
        if isPinned(fixtureId) { unpin(fixtureId: fixtureId); return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            errorMessage = "Live Activities are disabled. Enable them for this app in Settings to pin scores."
            return
        }
        let session = AppSession.shared
        guard let fixture = session.fixtures.first(where: { $0.fixtureId == fixtureId }),
              fixture.isLive else {
            errorMessage = "You can pin a match once it is live."
            return
        }
        let attributes = ScoreActivityAttributes(
            fixtureId: fixtureId, home: fixture.home.name, away: fixture.away.name,
            homeCode: TeamCatalog.shortName(for: fixture.home.id, in: session.allTeams, fallback: fixture.home.name),
            awayCode: TeamCatalog.shortName(for: fixture.away.id, in: session.allTeams, fallback: fixture.away.name),
            competition: session.leagueName(for: fixture.leagueId) ?? "Football"
        )
        do {
            // The app still polls while open; ActivityKit receives background updates directly.
            let activity = try Activity.request(attributes: attributes, content: content(for: fixture), pushType: PushRegistration.isConfigured && !DemoMode.isActive ? .token : nil)
            pinnedFixtureIds.insert(fixtureId)
            observe(activity)
        } catch {
            errorMessage = "Couldn't pin this score. Try again or remove another pinned match."
            AppLog.error(.app, "live_activity_start_failed", error: error)
        }
    }

    func unpin(fixtureId: Int) {
        pinnedFixtureIds.remove(fixtureId)
        for activity in Activity<ScoreActivityAttributes>.activities where activity.attributes.fixtureId == fixtureId {
            PushRegistration.shared.removeActivity(activity.id)
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func synchronize() async {
        restore()
        let session = AppSession.shared
        let fixtures = session.fixtures + session.neighborFixtures.values.flatMap { $0 }
        for activity in Activity<ScoreActivityAttributes>.activities {
            guard !Task.isCancelled else { return }
            guard activity.activityState == .active || activity.activityState == .stale else { continue }
            guard let fixture = fixtures.first(where: { $0.fixtureId == activity.attributes.fixtureId }) else {
                if session.scheduleState == .ready {
                    await activity.end(nil, dismissalPolicy: .immediate)
                    pinnedFixtureIds.remove(activity.attributes.fixtureId)
                }
                continue
            }
            let content = content(for: fixture)
            if fixture.status == "FINISHED" || !fixture.isLive {
                await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(3600)))
                pinnedFixtureIds.remove(fixture.fixtureId)
            } else {
                await activity.update(content)
            }
        }
    }

    private func content(for fixture: Fixture) -> ActivityContent<ScoreActivityAttributes.ContentState> {
        let update = AppSession.shared.liveScoreUpdates[fixture.fixtureId]
        let confirmed = update?.confirmedAt ?? .distantPast
        let clock = fixture.status == "FINISHED" ? "Full-time"
            : fixture.status == "HALF_TIME" ? "Half-time"
            : fixture.minute.map { "\($0)\(fixture.extra.map { "+\($0)" } ?? "")′" } ?? "Live"
        return ActivityContent(state: .init(score: fixture.scorelineText, clock: clock,
                                            updatedAt: confirmed, finished: fixture.status == "FINISHED"),
                               staleDate: update?.failed == true ? Date() : confirmed.addingTimeInterval(60))
    }

    private func observe(_ activity: Activity<ScoreActivityAttributes>) {
        PushRegistration.shared.observe(activity)
        guard observers[activity.id] == nil else { return }
        observers[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .dismissed || state == .ended {
                    self?.pinnedFixtureIds.remove(activity.attributes.fixtureId)
                    self?.observers[activity.id] = nil
                    PushRegistration.shared.removeActivity(activity.id)
                    return
                }
            }
        }
    }
}
