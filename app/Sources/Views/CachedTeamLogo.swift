import SwiftUI

/// A team or league logo from the API CDN, for static SwiftUI surfaces (picker,
/// menu, Fan-of strip, pills). Reads `TeamLogoStore`'s shared in-memory cache
/// (disk-backed by `URLCache.shared`) rather than `AsyncImage`, which drops its
/// image on view teardown and — inside a `ScrollView` — can have its reload
/// cancelled and never retried, blanking the flags. Falls back to an SF Symbol
/// when the URL is empty or still loading.
struct CachedTeamLogo: View {
    let url: String
    var size: CGFloat = 28
    var fallbackSymbol: String = "shield.lefthalf.filled"
    var neutralBacking = false
    @Environment(\.colorScheme) private var scheme

    @ObservedObject private var store = TeamLogoStore.shared

    var body: some View {
        Group {
            if let image = store.image(for: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .padding(neutralBacking && scheme == .dark ? size * 0.1 : 0)
        .frame(width: size, height: size)
        .background {
            if neutralBacking && scheme == .dark {
                RoundedRectangle(cornerRadius: size * 0.2).fill(Color.white.opacity(0.92))
            }
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: fallbackSymbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .padding(size * 0.1)
    }
}
