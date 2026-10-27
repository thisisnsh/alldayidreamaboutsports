import ActivityKit
import Foundation

/// Shared by the app and widget extension; contains the latest confirmed poll result.
struct ScoreActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var score: String
        var clock: String
        var updatedAt: Date
        var finished: Bool
    }

    var fixtureId: Int
    var home: String
    var away: String
    var homeCode: String
    var awayCode: String
    var competition: String
}
