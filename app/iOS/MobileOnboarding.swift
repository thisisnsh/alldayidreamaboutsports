import SwiftUI

struct MobileOnboarding: View {
    @EnvironmentObject private var session: AppSession
    let finish: () -> Void
    @ObservedObject private var notifications = MatchNotifications.shared
    @State private var step = 0
    @State private var query = ""

    var body: some View {
        VStack(spacing: 20) {
            ScrollView {
                VStack(spacing: 20) {
                    switch step {
                    case 0:
                        LogoMarquee(logos: session.allTeams.map(\.logo), fadeTo: 0.55)
                            .frame(height: 180).accessibilityHidden(true)
                        title("All Day I Dream\nAbout Sports")
                        Text("Live scores for the teams you follow. Your matchday, always close.")
                        Text("No account needed.").font(.subheadline).foregroundStyle(.secondary)
                    case 1:
                        title("Who do you follow?")
                        Text("Choose your teams. You can change them anytime.")
                        TeamSearchField(query: $query)
                        TeamLeagueList(query: query, columns: 3)
                    case 2:
                        Image(systemName: "pin.circle.fill").font(.system(size: 64))
                        title("Keep the score close")
                        Text("Open a live match and tap Pin to Lock Screen. Its score appears as a Live Activity, and in the Dynamic Island on supported iPhones.")
                        Text("Scores update from polling while this app is open. When background delivery is connected, your pinned scores and enabled match alerts can also update while your device is locked.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("Enabling background alerts shares selected team IDs and alert preferences with our push service.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Enable match notifications") { Task { await notifications.enable() } }
                            .buttonStyle(.primaryPill)
                        Text(notifications.permissionMessage).font(.caption).foregroundStyle(.secondary)
                        Text("Optional: turn on Keep screen awake in Settings to follow a match without auto-lock.")
                            .font(.caption).foregroundStyle(.secondary)
                    default:
                        Image(systemName: "checkmark.circle").font(.system(size: 64))
                        title("You're all set")
                        Text("Your matches, teams and settings are all right here.")
                    }
                }
                .multilineTextAlignment(.center)
                .padding(24)
            }
            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }.buttonStyle(.hoverHighlight)
                }
                Spacer()
                Text("\(step + 1) of 4").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(step == 3 ? "Show matches" : step == 0 ? "Get started" : "Continue") {
                    if step == 3 { finish() } else { withAnimation { step += 1 } }
                }
                .buttonStyle(.primaryPill)
                .disabled(step == 1 && session.fanTeamIds.isEmpty)
            }
            .padding()
            if step == 0 {
                Link("Privacy policy", destination: URL(string: "https://alldayidreamaboutsports.com/privacy/")!)
                    .font(.caption).padding(.bottom)
            }
        }
        .frame(maxWidth: 680)
        .task { await session.refreshCatalog() }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(.largeTitle, design: .rounded, weight: .heavy))
    }
}
