#if DEV_BACKEND
import Foundation

// ╔══════════════════════════════════════════════════════════════════════╗
// ║  DEV KNOBS — edit, ⌘R, done. Compiled only into Debug builds.        ║
// ║  Everything the dev build shows comes from here + FakeBackend.swift. ║
// ╚══════════════════════════════════════════════════════════════════════╝

@MainActor
enum DevConfig {
    /// You are signed in as this user before the first frame renders —
    /// no login window, no Google, no Keychain.
    static let profile = Profile(
        sub: "dev-user",
        email: "dev@alldayidreamaboutsports.com",
        name: "Dev Fan",
        photoURL: nil
    )

    /// Teams you're a fan of. First one is who DevSimulator scores goals for
    /// (full celebration animation). FIFA trigram codes — see TeamCatalog.
    static let fanTeams = ["BRA", "ARG", "ENG", "JPN", "FRA"]

    /// Fire random match events on a timer so animations appear hands-free.
    /// Flip off (or use the Settings 🧪 toggle) when you'd rather drive
    /// events with the Settings buttons.
    static let autoEventsEnabled = true

    /// Seconds after launch until the first auto event.
    static let firstAutoEventAfterSeconds: Double = 8

    /// Gap between auto events (a random value in this range each time).
    static let autoEventIntervalSeconds: ClosedRange<Double> = 20 ... 40

    /// Relative weights for which event the auto loop fires.
    /// fanGoal = full ball-drop celebration; the rest are notch pills.
    static let autoEventWeights: [(weight: Int, fire: @MainActor () -> Void)] = [
        (5, DevSimulator.fanGoal),
        (1, DevSimulator.opponentGoal),
        (1, DevSimulator.yellowCard),
        (1, DevSimulator.varCancelled),
        (1, DevSimulator.countPush),
        (1, DevSimulator.fullTime),
    ]
}
#endif
