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
    private var targets: [(fixtureId: Int, teamId: String)] = []

    func beginWindow(targets: [(fixtureId: Int, teamId: String)]) {
        // If a previous window never flushed (rapid back-to-back sets), flush it first.
        flush()
        self.targets = targets
        taps = 0
        AppLog.info(.celebrations, "window_started targets=\(targets.map { "\($0.fixtureId):\($0.teamId)" })")
    }

    func registerTap() {
        guard ControlPlane.shared.celebrationEnabled else { return }
        taps += Self.tapsPerClick
    }

    func endWindow() {
        AppLog.info(.celebrations, "window_ended taps=\(taps) targets=\(targets.count)")
        // Did the user engage with this celebration? Capture before flush() zeroes it.
        if !targets.isEmpty {
            AppAnalytics.celebrationTap(tapped: taps > 0)
        }
        flush()
    }

    private func flush() {
        guard !targets.isEmpty, taps > 0,
              ControlPlane.shared.celebrationEnabled,
              ControlPlane.shared.isOperational else {
            targets = []
            taps = 0
            return
        }
        let batch = targets
        let count = min(taps, 200)
        targets = []
        taps = 0
        // Sampling: only a sampled fraction of clients POST their real taps; the
        // server multiplies the received total back up by 1/sample to estimate the
        // global count. The optimistic local add already happened upstream
        // (OverlayManager.flushTapsAndQueueCounts), so a skipped POST still shows
        // the user's own celebration — it just isn't reported. 1.0 = everyone reports.
        let sample = ControlPlane.shared.celebrationSamplePercent
        guard sample >= 1.0 || Double.random(in: 0 ..< 1) < sample else {
            AppLog.info(.celebrations, "upload_sampled_out sample=\(sample) targets=\(batch.count) taps=\(count)")
            // Without this, a low `celebration_sample_percent` is
            // indistinguishable from nobody tapping.
            AppAnalytics.celebrationUploadSampledOut(sample: sample)
            return
        }
        Task {
            for target in batch {
                guard ControlPlane.shared.isOperational else { return }
                do {
                    try await api.celebrate(fixtureId: target.fixtureId, teamId: target.teamId, taps: count)
                    AppLog.info(.celebrations, "upload_complete fixture_id=\(target.fixtureId) team_id=\(target.teamId) taps=\(count)")
                } catch {
                    AppLog.error(.celebrations, "upload_failed fixture_id=\(target.fixtureId) team_id=\(target.teamId) taps=\(count)", error: error)
                    AppAnalytics.celebrationUploadFailed(error: error)
                }
            }
        }
    }
}
