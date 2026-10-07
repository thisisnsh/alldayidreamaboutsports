import AppKit

/// One currently connected display exposed to Settings. Display selection is
/// intentionally process-local: reconnecting or relaunching starts on the main
/// display instead of persisting hardware identifiers in UserDefaults.
struct OverlayDisplayOption: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
}

extension Notification.Name {
    static let overlayDisplayTargetDidChange = Notification.Name("overlayDisplayTargetDidChange")
}

/// The single display used by every app-owned overlay: pinned capsules, notch
/// notifications, confetti, and the interactive goal ball.
@MainActor
final class OverlayDisplayTarget: ObservableObject {
    static let shared = OverlayDisplayTarget()

    @Published private(set) var displays: [OverlayDisplayOption] = []
    @Published private(set) var selectedDisplayID: CGDirectDisplayID?

    private var screenObserver: NSObjectProtocol?

    private init() {
        refreshScreens(fallbackToMain: true, notify: false)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshScreens(fallbackToMain: true, notify: true)
            }
        }
    }

    var selectedScreen: NSScreen? {
        guard let selectedDisplayID else { return nil }
        return NSScreen.screens.first { displayID(for: $0) == selectedDisplayID }
    }

    func select(_ displayID: CGDirectDisplayID) {
        guard displays.contains(where: { $0.id == displayID }), selectedDisplayID != displayID else { return }
        selectedDisplayID = displayID
        NotificationCenter.default.post(name: .overlayDisplayTargetDidChange, object: self)
        AppLog.info(.prefs, "overlay_display_changed display_id=\(displayID)")
    }

    private func refreshScreens(fallbackToMain: Bool, notify: Bool) {
        let screens = NSScreen.screens
        let refreshed = screens.compactMap { screen -> OverlayDisplayOption? in
            guard let id = displayID(for: screen) else { return nil }
            return OverlayDisplayOption(id: id, name: screen.localizedName)
        }
        let oldSelection = selectedDisplayID
        displays = refreshed

        if oldSelection == nil || !refreshed.contains(where: { $0.id == oldSelection }) {
            let fallback = fallbackToMain ? (NSScreen.main ?? screens.first) : screens.first
            selectedDisplayID = fallback.flatMap(displayID(for:)) ?? refreshed.first?.id
        }

        // Never post from `init`: observers read `OverlayDisplayTarget.shared`,
        // and re-entering the static initializer traps in swift_once.
        if notify {
            NotificationCenter.default.post(name: .overlayDisplayTargetDidChange, object: self)
        }
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
