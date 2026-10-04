import AppKit
import ImageIO
import SwiftUI

/// Loads remote images as `NSImage`s — team and league crests — memoized in
/// memory and shared app-wide (the picker/menu via `CachedTeamLogo`, and the
/// Canvas-drawn celebration surfaces). Bumps `version` when a load finishes, success or failure, so
/// observers repaint and a rendered fallback gets one retry. Network/disk
/// caching is handled by `URLCache.shared` (configured in AppDelegate), so this
/// never re-downloads an image already fetched elsewhere in the app.
@MainActor
final class TeamLogoStore: ObservableObject {
    static let shared = TeamLogoStore()

    /// Bumped whenever a new image finishes loading — observe to trigger redraws.
    @Published private(set) var version = 0

    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var warmTask: Task<Void, Never>?
    /// Consecutive failed loads per URL, cleared the moment one succeeds.
    private var failures: [String: Int] = [:]
    /// When a URL that failed twice may be asked for again.
    private var coolingUntil: [String: Date] = [:]

    /// The cached image for a URL, or nil while it loads (kicking off a fetch).
    /// A URL that has just failed twice is in its cooldown and returns nil
    /// without touching the network until the window is up.
    func image(for url: String) -> NSImage? {
        if let img = images[url] { return img }
        if let until = coolingUntil[url], until > Date() { return nil }
        guard !url.isEmpty, let parsed = URL(string: url), !loading.contains(url) else { return nil }
        loading.insert(url)
        Task {
            let img = await Self.load(parsed)
            loading.remove(url)
            if let img {
                failures[url] = nil
                coolingUntil[url] = nil
                images[url] = img
            } else {
                // A rendered fallback is the signal to refresh, so bumping
                // `version` below is what sends the retry: observers redraw and
                // the redraw calls back in here. The cooldown on the second
                // failure is what stops that pair from looping forever.
                let count = (failures[url] ?? 0) + 1
                if count >= 2 {
                    failures[url] = nil
                    coolingUntil[url] = Date().addingTimeInterval(Self.failureCooldown)
                } else {
                    failures[url] = count
                }
            }
            version &+= 1
        }
        return nil
    }

    /// Re-request every logo whose last load failed, ignoring any cooldown —
    /// called when the menu opens, so a crest that blanked out (e.g. two
    /// failures while the network was down after wake) comes back the next
    /// time the user looks, instead of staying a placeholder for hours.
    func retryFailed() {
        let urls = Set(failures.keys).union(coolingUntil.keys)
        guard !urls.isEmpty else { return }
        failures = [:]
        coolingUntil = [:]
        for url in urls { _ = image(for: url) }
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
        let last = AppDefaults.shared.object(forKey: "logoRefreshedAt") as? Date ?? .distantPast
        let stale = Date().timeIntervalSince(last) > 24 * 3600
        if stale { AppDefaults.shared.set(Date(), forKey: "logoRefreshedAt") }
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
    /// How long a URL that failed twice in a row is left alone. `TimeInterval`
    /// rather than `Duration` because it is compared against `Date()`.
    private static let failureCooldown: TimeInterval = 6 * 3600

    private static func load(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await RemoteData.load(
            URLRequest(url: url), maxBytes: 1024 * 1024, hosts: ["media.api-sports.io"]
        ), (response as? HTTPURLResponse)?.statusCode == 200,
           let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) == 1,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0, width <= 2048, height <= 2048,
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}
