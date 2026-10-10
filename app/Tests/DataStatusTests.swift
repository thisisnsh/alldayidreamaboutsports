import Foundation

@main
struct DataStatusTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000)
        precondition(LiveScoreUpdate().status(at: now) == .checking)
        precondition(LiveScoreUpdate(confirmedAt: now).status(at: now) == .current)
        precondition(LiveScoreUpdate(confirmedAt: now.addingTimeInterval(-60)).status(at: now) == .current)
        precondition(LiveScoreUpdate(confirmedAt: now.addingTimeInterval(-61)).status(at: now) == .delayed)
        precondition(LiveScoreUpdate(confirmedAt: now, failed: true).status(at: now) == .delayed)
        precondition(LiveScoreUpdate(failed: true).status(at: now) == .delayed)
        // A successful unchanged read clears the failure and renews freshness.
        var recovered = LiveScoreUpdate(confirmedAt: now.addingTimeInterval(-120), failed: true)
        recovered = LiveScoreUpdate(confirmedAt: now)
        precondition(recovered.status(at: now) == .current)
        print("Live score freshness checks passed")
    }
}
