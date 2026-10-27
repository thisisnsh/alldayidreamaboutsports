import SwiftUI

/// Team crests drifting in vertical columns, neighbours running opposite ways,
/// each crest a random size. Fades out toward the bottom so text can sit under
/// it. Decorative: the welcome screens' backdrop.
struct LogoMarquee: View {
    /// Built once per logo set, not per frame: the TimelineView only offsets.
    private let columns: [Column]
    private let columnWidth: CGFloat
    private let fadeTo: CGFloat
    private let strength: Double
    @ObservedObject private var store = TeamLogoStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let spacing: CGFloat = 18
    /// How many crests to cycle through. Well under TeamLogoStore's cache
    /// limit so the marquee never evicts the picker's logos.
    private static let maxLogos = 48

    /// - Parameters:
    ///   - fadeTo: How far down (0–1) the crests have fully faded.
    ///   - strength: Opacity at the top, so the crests stay a backdrop.
    init(logos: [String], columnCount: Int = 7, columnWidth: CGFloat = 84, fadeTo: CGFloat = 0.85, strength: Double = 0.45) {
        self.columnWidth = columnWidth
        self.fadeTo = fadeTo
        self.strength = strength
        var rng = SeededGenerator(seed: 2026)
        let pool = Array(Set(logos.filter { !$0.isEmpty })).sorted().shuffled(using: &rng).prefix(Self.maxLogos)
        guard !pool.isEmpty else {
            columns = []
            return
        }
        let perColumn = max(6, pool.count / columnCount)
        columns = (0..<columnCount).map { c in
            let items = (0..<perColumn).map { i in
                Item(
                    id: i,
                    logo: pool[(c * perColumn + i) % pool.count],
                    size: CGFloat.random(in: 26...62, using: &rng)
                )
            }
            return Column(
                id: c,
                items: items,
                speed: CGFloat.random(in: 9...16, using: &rng) * (c.isMultiple(of: 2) ? 1 : -1),
                phase: CGFloat.random(in: 0...1, using: &rng)
            )
        }
    }

    var body: some View {
        // The columns are far taller than the view (they wrap). Hanging them
        // off a Color.clear overlay keeps them from sizing the view, which
        // would push everything else out of the window.
        Color.clear
            .overlay(alignment: .top) {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    let t = CGFloat(context.date.timeIntervalSinceReferenceDate)
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(columns) { column in
                            columnView(column, at: t)
                        }
                    }
                }
            }
            .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.6), location: fadeTo * 0.5),
                    .init(color: .clear, location: fadeTo),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .opacity(strength)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One column, drawn three times end to end and wrapped, so it loops
    /// seamlessly however far it has scrolled.
    private func columnView(_ column: Column, at t: CGFloat) -> some View {
        let height = column.height(spacing: Self.spacing)
        let travel = (t * column.speed + column.phase * height).truncatingRemainder(dividingBy: height)
        let offset = travel < 0 ? travel + height : travel
        return VStack(spacing: Self.spacing) {
            ForEach(0..<3, id: \.self) { _ in
                ForEach(column.items) { item in
                    crest(item)
                }
            }
        }
        .offset(y: -offset)
        .frame(width: columnWidth, alignment: .top)
    }

    @ViewBuilder
    private func crest(_ item: Item) -> some View {
        Group {
            if let image = store.image(for: item.logo) {
                #if os(macOS)
                Image(nsImage: image).resizable().scaledToFit()
                #else
                Image(uiImage: image).resizable().scaledToFit()
                #endif
            } else {
                Color.clear
            }
        }
        .frame(width: item.size, height: item.size)
    }

    private struct Item: Identifiable {
        let id: Int
        let logo: String
        let size: CGFloat
    }

    private struct Column: Identifiable {
        let id: Int
        let items: [Item]
        /// Points per second; negative runs downward.
        let speed: CGFloat
        /// Starting point in the loop, so columns don't line up.
        let phase: CGFloat

        /// One copy of the column, including the gap before the next copy.
        func height(spacing: CGFloat) -> CGFloat {
            items.reduce(0) { $0 + $1.size + spacing }
        }
    }
}

/// SplitMix64: the same "random" layout on every open, so the marquee doesn't
/// reshuffle each time the view rebuilds.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
