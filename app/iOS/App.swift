import SwiftUI
import FirebaseCore
import FirebaseAppCheck

@main
struct SportsMobileApp: App {
    @UIApplicationDelegateAdaptor(MobileAppDelegate.self) private var appDelegate
    @StateObject private var session = AppSession.shared

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reset-onboarding") {
            AppDefaults.shared.removeObject(forKey: "mobileOnboardingComplete")
        }
        #endif
        if FirebaseConfigured.isConfigured {
            AppCheck.setAppCheckProviderFactory(SportsAppCheckFactory())
            FirebaseApp.configure()
        }
        AppLog.configureFirebaseCollection()
        AppAnalytics.configureAppMetadata()
        AppAnalytics.appOpen()
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024)
        MatchNotifications.shared.configure()
        AppSession.shared.bootstrap()
        PinnedCapsuleManager.shared.restore()
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView().environmentObject(session)
        }
    }
}

struct MobileRootView: View {
    @EnvironmentObject private var session: AppSession
    @Environment(\.scenePhase) private var phase
    @AppStorage("mobileOnboardingComplete", store: AppDefaults.shared) private var onboarded = false
    @AppStorage("mobileKeepAwake", store: AppDefaults.shared) private var keepAwake = false
    @ObservedObject private var pins = PinnedCapsuleManager.shared

    var body: some View {
        Group {
            if onboarded { MenuPopoverView() }
            else { MobileOnboarding { onboarded = true } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackground())
        .appTheme(session.prefs.settings.theme ?? .system)
        .respectReducedMotion()
        .alert("Pinned score", isPresented: Binding(get: { pins.errorMessage != nil }, set: {
            if !$0 { pins.errorMessage = nil }
        })) {
            Button("OK") { pins.errorMessage = nil }
        } message: { Text(pins.errorMessage ?? "") }
        .onChange(of: keepAwake) { _, enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled && phase == .active
        }
        .onChange(of: phase) { _, value in
            MatchNotifications.shared.isForeground = value == .active
            UIApplication.shared.isIdleTimerDisabled = keepAwake && value == .active
            if value == .background { PushRegistration.shared.requestSync() }
        }
        .task(id: phase) {
            MatchNotifications.shared.isForeground = phase == .active
            UIApplication.shared.isIdleTimerDisabled = keepAwake && phase == .active
            guard phase == .active else {
                LiveStore.shared.stop()
                DemoEngine.shared.stop()
                // Resume with current scores, without announcing missed goals as new.
                if phase == .background { LiveStore.shared.resetBaseline() }
                return
            }
            PushRegistration.shared.start()
            await MatchNotifications.shared.refreshPermission()
            guard !Task.isCancelled else { return }
            if DemoMode.isActive { DemoEngine.shared.start() }
            else { LiveStore.shared.start() }
            await session.refreshFixtures()
            while !Task.isCancelled {
                session.reprojectIfDayChanged()
                await pins.synchronize()
                await PushRegistration.shared.synchronize()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .onChange(of: session.prefs) { _, _ in PushRegistration.shared.requestSync() }
        .onOpenURL { url in
            guard url.scheme == "alldaysports", url.host == "match" else { return }
            PopoverRouter.shared.reset()
        }
    }
}
