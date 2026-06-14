import AppKit
import SwiftUI

/// Loads team logos as `NSImage`s for the Canvas-drawn celebration surfaces
/// (the center ball and the mini-ball confetti), where `AsyncImage` can't be
/// used. Memoizes in memory and bumps `version` when a new logo arrives so the
/// enclosing `TimelineView`/`Canvas` repaints with it. Network/disk caching is
/// handled by `URLCache.shared` (configured in AppDelegate), so this never
/// re-downloads a logo already fetched elsewhere in the app.
@MainActor
final class TeamLogoStore: ObservableObject {
    static let shared = TeamLogoStore()

    /// Bumped whenever a new image finishes loading — observe to trigger redraws.
    @Published private(set) var version = 0

    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []

    /// The cached image for a URL, or nil while it loads (kicking off a fetch).
    func image(for url: String) -> NSImage? {
        if let img = images[url] { return img }
        guard !url.isEmpty, let parsed = URL(string: url), !loading.contains(url) else { return nil }
        loading.insert(url)
        Task {
            let img = await Self.load(parsed)
            loading.remove(url)
            if let img {
                images[url] = img
                version &+= 1
            }
        }
        return nil
    }

    /// Warm a set of logos ahead of a celebration so they're ready to draw.
    func preload(_ urls: [String]) {
        for url in urls { _ = image(for: url) }
    }

    private static func load(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
