import AppKit
import SwiftUI

/// Loads team logos as `NSImage`s, memoized in memory and shared app-wide (the
/// picker/menu via `CachedTeamLogo`, and the Canvas-drawn celebration surfaces).
/// Bumps `version` when a new logo arrives so observers repaint. Network/disk
/// caching is handled by `URLCache.shared` (configured in AppDelegate), so this
/// never re-downloads a logo already fetched elsewhere in the app.
@MainActor
final class TeamLogoStore: ObservableObject {
    static let shared = TeamLogoStore()

    /// Bumped whenever a new image finishes loading — observe to trigger redraws.
    @Published private(set) var version = 0

    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var warmTask: Task<Void, Never>?

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

    /// Fetch+cache every logo (used when the picker opens). If the last refresh
    /// was over 24h ago, re-fetch them all too, swapping each in place once
    /// decoded so nothing flashes to a placeholder.
    ///
    /// Five leagues means ~150 logos, not ~50, so this staggers: a batch goes on
    /// the wire, then a short pause, rather than 150 concurrent requests the
    /// moment the picker opens. Re-opening the picker cancels the previous warm
    /// instead of stacking a second sweep on top of it.
    func warm(_ urls: [String]) {
        let last = UserDefaults.standard.object(forKey: "logoRefreshedAt") as? Date ?? .distantPast
        let stale = Date().timeIntervalSince(last) > 24 * 3600
        if stale { UserDefaults.standard.set(Date(), forKey: "logoRefreshedAt") }
        let targets = urls.filter { !$0.isEmpty }
        warmTask?.cancel()
        warmTask = Task { [weak self] in
            for (index, url) in targets.enumerated() {
                if Task.isCancelled { return }
                guard let self else { return }
                if self.images[url] == nil {
                    _ = self.image(for: url) // kicks off its own fetch; doesn't block
                } else if stale, let parsed = URL(string: url) {
                    Task {
                        if let img = await Self.load(parsed) {
                            self.images[url] = img
                            self.version &+= 1
                        }
                    }
                }
                if index % Self.warmBatchSize == Self.warmBatchSize - 1 {
                    try? await Task.sleep(for: Self.warmBatchPause)
                }
            }
        }
    }

    private static let warmBatchSize = 12
    private static let warmBatchPause = Duration.milliseconds(120)

    private static func load(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
