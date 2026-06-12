import Foundation

/// Counts the user's taps locally during the celebration window and sends ONE
/// batched request when the ball disappears — never one request per tap.
@MainActor
final class CelebrationService {
    static let shared = CelebrationService()

    private var api: BackendAPI { Services.api }
    private var taps = 0
    private var context: (fixtureId: Int, teamCode: String)?

    func beginWindow(fixtureId: Int, teamCode: String) {
        // If a previous window never flushed (rapid back-to-back goals), flush it first.
        flush()
        context = (fixtureId, teamCode)
        taps = 0
    }

    /// One physical click emits 4 mini balls on screen, so it counts as 4
    /// celebrations — keep in sync with MiniBallBursts.ballsPerClick.
    static let tapsPerClick = 4

    func registerTap() {
        guard ControlPlane.shared.celebrationEnabled else { return }
        taps += Self.tapsPerClick
    }

    func endWindow() {
        flush()
    }

    private func flush() {
        guard let context, taps > 0, ControlPlane.shared.celebrationEnabled else {
            self.context = nil
            return
        }
        let payload = (context.fixtureId, context.teamCode, min(taps, 200))
        self.context = nil
        taps = 0
        Task {
            try? await api.celebrate(fixtureId: payload.0, teamCode: payload.1, taps: payload.2)
        }
    }
}
