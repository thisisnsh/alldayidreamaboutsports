import AppKit
import SwiftUI

/// Every dimension in the notch drops and the island's match card, scaled by the
/// user's `notchDropSize` setting. Medium is the baseline; small/large step it
/// down/up proportionally. The compact pin (beside the notch) does NOT scale:
/// it has to fit the menu bar's height.
struct NotchPillMetrics {
    let icon: CGFloat
    let title: CGFloat
    let subtitle: CGFloat
    /// The tinted disc behind each drop's event icon.
    let disc: CGFloat
    let hPad: CGFloat
    let vPad: CGFloat
    /// Vertical padding inside a drop pill.
    let pillVPad: CGFloat
    let rowSpacing: CGFloat
    /// Bottom corner radius of the match card, and of each drop pill.
    let corner: CGFloat
    /// Width of the island while it shows a match card.
    let islandWidth: CGFloat

    init(_ size: CapsuleSize) {
        switch size {
        case .small:
            icon = 11; title = 11; subtitle = 9.5; disc = 24
            hPad = 14; vPad = 10; pillVPad = 8; rowSpacing = 8; corner = 18; islandWidth = 340
        case .medium:
            icon = 13; title = 13; subtitle = 11; disc = 28
            hPad = 18; vPad = 12; pillVPad = 10; rowSpacing = 10; corner = 22; islandWidth = 390
        case .large:
            icon = 15; title = 15; subtitle = 13; disc = 34
            hPad = 22; vPad = 15; pillVPad = 13; rowSpacing = 12; corner = 26; islandWidth = 460
        }
    }
}

/// One event drop's content, centered like the original notch pills: the
/// SF Symbol leads the headline ("Goal", "Yellow card") on one line, the
/// scoreline sits under it. Drops are always black (they split off the
/// notch), so this renders in the dark color scheme whatever the theme.
struct NotchDropContent: View {
    let item: NotchItem
    let metrics: NotchPillMetrics

    /// `.primary` icons (goal, sub, VAR…) are white on black; a fan goal's
    /// ball is green, the one color that says "yours".
    private var tint: Color {
        if item.fanGoal != nil { return .green }
        return item.iconColor == .primary ? .white : item.iconColor
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: metrics.icon, weight: .semibold))
                    .foregroundStyle(tint)
                SegmentLine(segments: item.title, size: metrics.title, weight: .semibold, color: .primary)
            }
            if let subtitle = item.subtitle {
                SegmentLine(segments: subtitle, size: metrics.subtitle, weight: .medium, color: .secondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, metrics.hPad)
        .padding(.vertical, metrics.pillVPad)
        .accessibilityElement(children: .combine)
    }
}

/// One drop line, built from `PillSegment`s: text runs interleaved with team
/// logos (no emoji). Kept to a single line.
struct SegmentLine: View {
    let segments: [PillSegment]
    let size: CGFloat
    let weight: Font.Weight
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .text(string, bold):
                    Text(string)
                        .font(.system(size: size, weight: bold ? .bold : weight, design: .rounded))
                        .foregroundStyle(color)
                case let .logo(url):
                    CachedTeamLogo(url: url, size: size + 4)
                }
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Drops splitting off the notch

private enum NotchDropPlane { case body, content }

private struct NotchNotificationFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, frame in frame })
    }
}

/// Animate a complete frame, rather than passing an animating environment
/// value into children that SwiftUI can implicitly animate a second time.
private struct NotchDropFrame: View, Animatable {
    var progress: CGFloat
    let item: NotchItem
    let metrics: NotchPillMetrics
    let geometry: NotchGeometry
    let slot: CGRect
    let plane: NotchDropPlane
    let reduceMotion: Bool
    let hovered: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        // Paths are in panel coordinates. Translate back into this row's
        // local coordinates after calculating the notch's bottom-center origin.
        let motion = NotchDropMotion(
            progress: reduceMotion ? 1 : progress,
            slot: slot,
            origin: geometry.dropOrigin(centerX: slot.midX),
            corner: metrics.corner,
            contentInset: metrics.pillVPad
        )
        let local = CGAffineTransform(translationX: -slot.minX, y: -slot.minY)
        let bodyPath = motion.bodyPath.applying(local)
        ZStack(alignment: .topLeading) {
            switch plane {
            case .body:
                bodyPath.fill(.black)
                    .shadow(color: .black.opacity(reduceMotion ? 0.4 : motion.shadowOpacity), radius: 10, y: 4)
                motion.silhouette.applying(local).fill(.black)
            case .content:
                NotchDropContent(item: item, metrics: metrics)
                    .frame(width: slot.width, height: slot.height)
                    .scaleEffect(reduceMotion ? 1 : motion.contentScale)
                    .offset(y: reduceMotion ? 0 : motion.contentOffset)
                    // Reveal text inside the moving body. It never appears
                    // in the empty slot below, or spills out during return.
                    .clipShape(bodyPath)
                    .clipped()
                    .opacity(reduceMotion ? Double(progress) : motion.contentOpacity)
                    .opacity(hovered ? 0.2 : 1)
            }
        }
        .opacity(reduceMotion && plane == .body ? Double(progress) : 1)
        .transaction { $0.animation = nil }
    }
}

/// Reserve the final slot for the entire lifetime, including return. The
/// measured slot never collapses underneath an animation in flight.
private struct NotchDropRow: View {
    let item: NotchItem
    let metrics: NotchPillMetrics
    let geometry: NotchGeometry
    let plane: NotchDropPlane
    let dismissing: Bool
    let returnDelay: TimeInterval
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var readyForInteraction = false

    var body: some View {
        NotchDropContent(item: item, metrics: metrics)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                GeometryReader { proxy in
                    let slot = proxy.frame(in: .named(NotchDropsLayer.space))
                    ZStack {
                        NotchDropFrame(
                            progress: progress, item: item, metrics: metrics, geometry: geometry,
                            slot: slot, plane: plane, reduceMotion: reduceMotion, hovered: hovered
                        )
                        .allowsHitTesting(false)
                        if plane == .content && readyForInteraction && !dismissing {
                            Button {
                                OverlayManager.shared.dismissNotification(item.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(Color(white: 0.16)))
                                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Close notification")
                            .accessibilityLabel("Close notification")
                            .opacity(hovered ? 1 : 0)
                            .allowsHitTesting(hovered)
                            .accessibilityHidden(!hovered)
                            .animation(.easeOut(duration: 0.12), value: hovered)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .preference(key: NotchNotificationFramesKey.self,
                                value: plane == .content && readyForInteraction && !dismissing ? [item.id: slot] : [:])
                }
            }
            .task {
                guard plane == .content else { return }
                let duration = reduceMotion ? 0.16 : NotchDropAnimation.arrivalDuration
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                readyForInteraction = true
            }
            .accessibilityAction(named: Text("Close notification")) {
                OverlayManager.shared.dismissNotification(item.id)
            }
            .onAppear {
                guard !dismissing else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.16) : NotchDropAnimation.arrival) {
                    progress = 1
                }
            }
            .onChange(of: dismissing) { _, leaving in
                guard leaving else { return }
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.16)
                    : NotchDropAnimation.returning.delay(returnDelay)
                withAnimation(animation) { progress = 0 }
            }
            .onChange(of: reduceMotion) { _, _ in
                // An accessibility change mid-flight must not leave a neck
                // or partly revealed label stranded on screen.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { progress = dismissing ? 0 : 1 }
            }
    }
}

/// Two matching planes keep every label above every silhouette, including a
/// later drop's neck as it passes through an earlier notification.
struct NotchDropsLayer: View {
    static let space = "notchPanel"

    @ObservedObject private var overlay = OverlayManager.shared
    @ObservedObject private var displayTarget = OverlayDisplayTarget.shared
    @ObservedObject private var island = NotchIsland.shared
    @EnvironmentObject private var session: AppSession

    var body: some View {
        let geometry = NotchGeometry(screen: displayTarget.selectedScreen)
        let metrics = NotchPillMetrics(session.prefs.settings.notchDropSize ?? .medium)
        ZStack(alignment: .top) {
            stack(plane: .body, geometry: geometry, metrics: metrics)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            stack(plane: .content, geometry: geometry, metrics: metrics)
        }
        .padding(.top, geometry.bandHeight + OverlayLayout.stackSpacing)
        .onPreferenceChange(NotchNotificationFramesKey.self) { frames in
            DispatchQueue.main.async { NotchIsland.shared.notificationFramesChanged(frames) }
        }
    }

    private func stack(plane: NotchDropPlane, geometry: NotchGeometry, metrics: NotchPillMetrics) -> some View {
        VStack(spacing: OverlayLayout.stackSpacing) {
            ForEach(Array(overlay.activeSet.enumerated()), id: \.element.id) { index, item in
                NotchDropRow(
                    item: item, metrics: metrics, geometry: geometry, plane: plane,
                    dismissing: overlay.isRetracting || overlay.retractingItemIDs.contains(item.id),
                    returnDelay: overlay.retractingItemIDs.contains(item.id) ? 0
                        : NotchDropAnimation.returnDelay(index: index, count: overlay.activeSet.count),
                    hovered: plane == .content && island.hoveredNotificationID == item.id
                )
                .transition(.identity)
            }
        }
    }
}
