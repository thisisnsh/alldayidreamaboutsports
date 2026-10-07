import AppKit
import FirebaseCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = MenuPopoverController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disk-backed HTTP cache so team/league logos (API CDN) download once and
        // are reused across the app — no third-party image service, no cost.
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 64 << 20)

        // Firebase config is optional in dev builds (plist is gitignored).
        // It is used solely for Analytics and Crashlytics.
        if FirebaseConfigured.isConfigured {
            FirebaseApp.configure()
            AppAnalytics.configureAppMetadata()
            AppAnalytics.appOpen()
            AppLog.configureFirebaseCollection()
        } else {
            AppLog.info(.app, "firebase_unconfigured")
        }

        AppSession.shared.bootstrap()
        menuController.install()

        #if DEV_BACKEND
        // Play the deterministic demo timeline (DevConfig.timeline) so
        // animations can be eyeballed hands-free.
        if DevConfig.autostart {
            DemoEngine.shared.start()
        }
        #else
        // A fresh install gets the one-time setup window. After that, launch
        // is silent: the app lives in the menu bar (and starts at login).
        if OnboardingWindowController.shared.isNeeded {
            OnboardingWindowController.shared.show()
        }
        #endif

        // Recover live polling after system sleep: App Nap + sleep suspend the
        // LiveStore loop, so on wake we reconcile finished matches and poll now.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in self?.recoverLivePolling() }
        }
    }

    // Foreground (e.g. the user clicks into the app): same recovery as wake —
    // the loop may have been App-Napped while idle in the menu bar.
    func applicationDidBecomeActive(_ notification: Notification) {
        recoverLivePolling()
    }

    /// After idle/sleep the LiveStore `Task.sleep` loop may be throttled or
    /// suspended. Reconcile any finished-while-suspended fan match and run one
    /// immediate poll pass. `reconcileFanMatches` is the
    /// only path that can un-stick a past-window match; `refreshNow` covers
    /// in-window ones.
    @MainActor private func recoverLivePolling() {
        #if DEV_BACKEND
        return
        #else
        Task {
            await LiveStore.shared.reconcileFanMatches()
            await LiveStore.shared.refreshNow()
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppSession.shared.stopAllActivity()
        // Quitting drops the cached fixtures/scores so the next
        // launch re-fetches fresh rather than flashing a stale board.
        AppSession.shared.clearMatchCache()
        // UserDefaults writes are async (cfprefsd flushes them on a later runloop
        // tick). Terminate gives no such tick, so without forcing a flush the
        // removals in clearMatchCache() are lost and the next launch reads the
        // stale cache back. synchronize() blocks until the writes hit disk.
        AppDefaults.shared.synchronize()
    }

    // App is invisible except the menu bar — reopening from Finder/Spotlight
    // opens the popover (or setup, if it was never finished).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if OnboardingWindowController.shared.isNeeded {
            OnboardingWindowController.shared.show()
        } else {
            MenuPopoverController.shared.showMenu()
        }
        return false
    }
}

/// AppKit owns the status item so a transient popover closes on focus loss and
/// always clears the status button's highlighted state. Left click toggles the
/// popover; right click opens a small native menu.
@MainActor
final class MenuPopoverController: NSObject, NSPopoverDelegate {
    static let shared = MenuPopoverController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var eventMonitor: Any?
    private var keyMonitor: Any?
    /// When the popover went up, for the `menu_closed` duration. Non-nil only
    /// while it is showing, so the close event can't fire twice (or at all for
    /// a close that never followed an open).
    private var menuOpenedAt: Date?

    func install() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "soccerball", accessibilityDescription: "All Day I Dream About Sports")
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = MenuPopoverView.size(following: AppSession.shared.fanTeams.count)
        popover.contentViewController = NSHostingController(
            rootView: MenuPopoverView().environmentObject(AppSession.shared)
        )
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showQuickMenu()
        } else if popover.isShown {
            close()
        } else {
            showMenu()
        }
    }

    /// Open the menu popover anchored to the status item, on `page`. No-op if
    /// it's already shown (beyond switching page) or the status item isn't
    /// available yet — the popover anchors to the button, and a button that
    /// hasn't been placed in the menu bar (e.g. at cold launch) would drop the
    /// popover in a random corner. Callers that need it shown reliably must do
    /// so once the menu bar item exists (a reopen/click).
    func showMenu(page: PopoverPage = .home) {
        guard let button = statusItem.button, button.window != nil else { return }
        guard !popover.isShown else {
            PopoverRouter.shared.go(page)
            return
        }
        PopoverRouter.shared.reset(to: page)
        // Sized while closed: the follow count can change on the Teams page,
        // but the new height waits for the next open.
        let size = MenuPopoverView.size(following: AppSession.shared.fanTeams.count)
        PopoverRouter.shared.height = size.height
        popover.contentSize = size
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        // Fired here, not from the SwiftUI body: the hosting controller is built
        // once at `install()` and reused, so `.onAppear` never fires per open.
        menuOpenedAt = Date()
        AppAnalytics.screenView(MenuPopoverView.screen)
        TeamLogoStore.shared.retryFailed()
        startRefreshing()
    }

    func close() {
        popover.performClose(nil)
        statusItem.button?.highlight(false)
        stopRefreshing()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        if let openedAt = menuOpenedAt {
            menuOpenedAt = nil
            AppAnalytics.menuClosed(openSeconds: Date().timeIntervalSince(openedAt))
        }
        stopRefreshing()
    }

    // MARK: Right-click menu

    private func showQuickMenu() {
        guard let button = statusItem.button else { return }
        close()
        let menu = NSMenu()
        menu.addItem(item("Open", action: #selector(openFromMenu)))
        menu.addItem(item("Settings…", action: #selector(openSettingsFromMenu), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Report a Bug…", action: #selector(reportBugFromMenu)))
        menu.addItem(item("Request a Feature…", action: #selector(requestFeatureFromMenu)))
        menu.addItem(.separator())
        menu.addItem(item("Quit All Day I Dream About Sports", action: #selector(quitFromMenu), key: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openFromMenu() { showMenu() }
    @objc private func openSettingsFromMenu() { showMenu(page: .settings) }
    @objc private func reportBugFromMenu() { Feedback.reportBug() }
    @objc private func requestFeatureFromMenu() { Feedback.requestFeature() }
    @objc private func quitFromMenu() {
        AppAnalytics.appQuit(source: "status_menu")
        NSApp.terminate(nil)
    }

    private func startRefreshing() {
        // Live scores flow continuously from LiveStore (always-on poll loop) —
        // opening the menu just nudges a schedule refresh for immediate
        // freshness.
        Task { await AppSession.shared.refreshFixtures() }
        // .transient doesn't reliably close the popover on outside clicks for
        // accessory-policy apps on macOS Sequoia+, so we add our own monitor.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        // A menu bar app has no main menu to carry shortcuts, so the popover
        // handles its own: ⌘, opens Settings, Esc steps back to the matches
        // (and only closes the popover from there).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let router = PopoverRouter.shared
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
                router.go(.settings)
                return nil
            }
            if event.keyCode == 53, router.page != .home { // Esc
                router.go(.home)
                return nil
            }
            return event
        }
    }

    private func stopRefreshing() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
