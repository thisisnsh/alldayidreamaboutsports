import Foundation

enum DataLoadState {
    case loading, ready, unavailable
}

/// A successful conditional read confirms freshness even when the score hasn't changed.
struct LiveScoreUpdate {
    enum Status { case checking, current, delayed }

    var confirmedAt: Date?
    var failed = false

    func status(at now: Date) -> Status {
        if failed { return .delayed }
        guard let confirmedAt else { return .checking }
        return now.timeIntervalSince(confirmedAt) > 60 ? .delayed : .current
    }
}
