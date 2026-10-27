import Foundation

/// Made-up matchday data on demand, in every build. A live-scores app is blank
/// whenever none of your teams is playing, so App Review (or anyone) can tap
/// the Settings title five times to swap the real scores for the DevConfig
/// demo: ten matches across yesterday, today and tomorrow — finished, live,
/// kicking off and scheduled — with goals, cards and celebrations firing
/// through the real overlay pipeline.
///
/// Debug (DEV_BACKEND) builds are always in demo mode. Elsewhere it lasts the
/// session: nothing the demo touches is persisted (followed teams, fixture
/// cache, match archive, review-prompt goal count), so Exit — or quitting —
/// puts the real app back exactly as it was.
@MainActor
final class DemoMode: ObservableObject {
    static let shared = DemoMode()

    #if DEV_BACKEND
    @Published private(set) var isActive = true
    #else
    @Published private(set) var isActive = false
    #endif

    static var isActive: Bool { shared.isActive }

    /// Taps on the Settings title that turn the demo on.
    static let tapsToActivate = 5

    /// Swap in the demo and play it from the top. Already on: restart it, so
    /// the gesture doubles as a replay.
    func activate() {
        DemoKickoff.reanchor()
        if !isActive {
            isActive = true
            LiveStore.shared.stop()
            clearOverlays()
            AppSession.shared.enterDemo(fanTeams: DevConfig.fanTeams)
            AppAnalytics.demoActivated()
            AppLog.info(.app, "demo_mode_activated")
        }
        DemoEngine.shared.restart()
    }

    /// Back to real scores and the user's own teams. Debug builds have no
    /// real backend to go back to, so this is a no-op there.
    func exit() {
        #if !DEV_BACKEND
        guard isActive else { return }
        DemoEngine.shared.stop()
        isActive = false
        clearOverlays()
        FakeStore.shared.resetMatches()
        AppSession.shared.leaveDemo()
        AppAnalytics.demoExited()
        AppLog.info(.app, "demo_mode_exited")
        #endif
    }

    /// Pills, celebrations and pinned capsules belong to one data source;
    /// none may outlive the switch to the other.
    private func clearOverlays() {
        #if os(macOS)
        OverlayManager.shared.dismissAll()
        #endif
        for fixtureId in PinnedCapsuleManager.shared.pinnedFixtureIds {
            PinnedCapsuleManager.shared.unpin(fixtureId: fixtureId)
        }
    }
}
