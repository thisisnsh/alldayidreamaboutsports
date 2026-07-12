import AppKit
import SwiftUI

/// Monochrome surfaces: pure white app in light mode, pure black in dark.
/// No gradients, no clouds — the flags and animations carry the color.
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        (scheme == .dark ? Color.black : Color.white)
            .ignoresSafeArea()
    }
}

extension View {
    /// Applies the user's theme preference on top of the system appearance.
    func appTheme(_ theme: ThemeChoice) -> some View {
        preferredColorScheme(theme.colorScheme)
    }
}

enum ThemeChoice: String, CaseIterable, Codable {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// AppKit owns the appearance of window chrome and popovers. Setting the
    /// application appearance also makes clearing an explicit Light/Dark choice
    /// back to System take effect on windows that are already open.
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// How big a pinned score capsule draws. Scales every font and logo in the
/// capsule (see `CapsuleMetrics` in `Overlay/PinnedCapsule.swift`); medium is
/// the default when the setting is unset.
enum CapsuleSize: String, CaseIterable, Codable {
    case small, medium, large

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// Vertical edge used by the pinned capsule stack.
enum CapsulePosition: String, CaseIterable, Codable {
    case top, bottom

    var label: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
}

/// Built-in macOS system sound played when a followed team scores. These all
/// ship in `/System/Library/Sounds`, so nothing needs bundling; `NSSound(named:)`
/// resolves each by its filename. `.hero` is the celebratory default.
enum GoalSound: String, CaseIterable, Codable {
    case hero, glass, ping, submarine, funk, sosumi, blow

    static let `default`: GoalSound = .hero

    /// Filename of the system sound in `/System/Library/Sounds`.
    var systemName: String {
        switch self {
        case .hero: "Hero"
        case .glass: "Glass"
        case .ping: "Ping"
        case .submarine: "Submarine"
        case .funk: "Funk"
        case .sosumi: "Sosumi"
        case .blow: "Blow"
        }
    }

    var label: String {
        switch self {
        case .hero: "Hero"
        case .glass: "Glass"
        case .ping: "Ping"
        case .submarine: "Sub"
        case .funk: "Funk"
        case .sosumi: "Sosumi"
        case .blow: "Blow"
        }
    }
}

/// Plays the goal notification sound. Holds the current `NSSound` so it isn't
/// deallocated mid-play, and restarts a fresh instance each time so rapid
/// back-to-back goals (or repeated Settings previews) each ring cleanly.
@MainActor
enum GoalSoundPlayer {
    private static var current: NSSound?

    static func play(_ choice: GoalSound) {
        guard let sound = NSSound(named: choice.systemName) else {
            AppLog.error(.celebrations, "goal_sound_missing name=\(choice.systemName)")
            return
        }
        current?.stop()
        current = sound
        sound.play()
    }
}

// MARK: Buttons — every clickable thing reacts to hover.

/// Row/list buttons: soft highlight + tiny lift on hover, press squish.
struct HoverHighlightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HighlightBody(configuration: configuration)
    }

    private struct HighlightBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1.0))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == HoverHighlightButtonStyle {
    static var hoverHighlight: HoverHighlightButtonStyle { .init() }
}

/// Primary call-to-action: filled pill, inverted text, grows slightly on hover.
struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: Configuration
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        var body: some View {
            configuration.label
                .fontWeight(.semibold)
                .foregroundStyle(scheme == .dark ? .black : .white)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.75 : 1)))
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.04 : 1.0))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == PrimaryPillButtonStyle {
    static var primaryPill: PrimaryPillButtonStyle { .init() }
}

/// Buttons sitting on tinted surfaces (settings cards): always-visible chrome
/// one step stronger than the card, brighter on hover.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration)
    }

    private struct CardBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(hovering ? 0.20 : 0.12))
                )
                .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == CardButtonStyle {
    static var cardButton: CardButtonStyle { .init() }
}

/// Bare hover lift for things that already have their own chrome.
struct HoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}
