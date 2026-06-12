import Foundation

/// Counts the user's taps locally during the ball window and sends ONE
/// batched request per celebrated team when the ball disappears — never one
/// request per tap. With one ball celebrating several teams (multiple fan
/// goals in a set), every tap counts for each of them.
@MainActor
final class CelebrationService {
    static let shared = CelebrationService()

    /// One physical click emits 4 mini balls on screen, so it counts as 4
    /// celebrations — keep in sync with MiniBallBursts.ballsPerClick.
    static let tapsPerClick = 4

    private var api: BackendAPI { Services.api }
    private var taps = 0
    private var targets: [(fixtureId: Int, teamCode: String)] = []

    func beginWindow(targets: [(fixtureId: Int, teamCode: String)]) {
        // If a previous window never flushed (rapid back-to-back sets), flush it first.
        flush()
        self.targets = targets
        taps = 0
    }

    func registerTap() {
        guard ControlPlane.shared.celebrationEnabled else { return }
        taps += Self.tapsPerClick
    }

    func endWindow() {
        flush()
    }

    private func flush() {
        guard !targets.isEmpty, taps > 0, ControlPlane.shared.celebrationEnabled else {
            targets = []
            taps = 0
            return
        }
        let batch = targets
        let count = min(taps, 200)
        targets = []
        taps = 0
        Task {
            for target in batch {
                try? await api.celebrate(fixtureId: target.fixtureId, teamCode: target.teamCode, taps: count)
            }
        }
    }
}
