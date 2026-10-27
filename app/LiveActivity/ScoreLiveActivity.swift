import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ScoresWidgets: WidgetBundle {
    var body: some Widget { ScoreLiveActivity() }
}

struct ScoreLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScoreActivityAttributes.self) { context in
            VStack(spacing: 10) {
                HStack {
                    Text(context.attributes.competition).lineLimit(1)
                    Spacer()
                    Text(context.isStale ? "Updates paused or delayed" : context.state.clock)
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(context.attributes.home).frame(maxWidth: .infinity, alignment: .leading)
                    Text(context.state.score).font(.title2.bold()).monospacedDigit().fixedSize()
                    Text(context.attributes.away).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.headline).lineLimit(2).minimumScaleFactor(0.7)
                if context.isStale {
                    Text("Open the app to refresh scores").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .foregroundStyle(.white)
            .widgetURL(URL(string: "alldaysports://match/\(context.attributes.fixtureId)"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.homeCode).font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.awayCode).font(.headline)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.score).font(.title2.bold()).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "Open app to resume updates" : context.state.clock)
                        .font(.caption)
                }
            } compactLeading: {
                Text(context.attributes.homeCode).font(.caption2)
            } compactTrailing: {
                Text(context.state.score).monospacedDigit().font(.caption2)
            } minimal: {
                Image(systemName: "soccerball")
            }
            .widgetURL(URL(string: "alldaysports://match/\(context.attributes.fixtureId)"))
        }
    }
}
