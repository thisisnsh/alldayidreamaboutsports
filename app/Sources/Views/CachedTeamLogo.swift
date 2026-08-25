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

    @ObservedObject private var store = TeamLogoStore.shared

    var body: some View {
        Group {
            if let image = store.image(for: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
    }

    private var placeholder: some View {
        Image(systemName: fallbackSymbol)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
            .padding(size * 0.1)
    }
}

/// The signed-in user's profile photo, on the same `TeamLogoStore` backing as
/// `CachedTeamLogo` — so it gets the same retry-then-back-off recovery instead
/// of `AsyncImage`'s drop-on-teardown, which left the menu and Settings showing
/// a permanent person glyph. Frame and circular clip live here so the two call
/// sites can't drift apart.
struct CachedProfilePhoto: View {
    let url: String?
    var size: CGFloat = 36

    @ObservedObject private var store = TeamLogoStore.shared

    var body: some View {
        Group {
            if let url, let image = store.image(for: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
