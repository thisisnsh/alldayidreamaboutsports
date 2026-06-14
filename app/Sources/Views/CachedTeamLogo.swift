import SwiftUI

/// A team or league logo from the API CDN, for static SwiftUI surfaces (picker,
/// menu, Fan-of strip, pills). Disk caching is free: `AsyncImage` goes through
/// `URLSession.shared`, which consults the `URLCache.shared` configured at
/// launch — so each URL downloads once and is reused app-wide. Falls back to an
/// SF Symbol when the URL is empty or still loading.
struct CachedTeamLogo: View {
    let url: String
    var size: CGFloat = 28
    var fallbackSymbol: String = "shield.lefthalf.filled"

    var body: some View {
        Group {
            if let u = URL(string: url), !url.isEmpty {
                AsyncImage(url: u) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        placeholder
                    }
                }
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
