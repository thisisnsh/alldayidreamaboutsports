import SwiftUI

/// One clock drives the silhouette, text and shadow. Keeping the geometry
/// separate also lets us inspect every intermediate frame without a window.
enum NotchDropAnimation {
    static let arrivalDuration: TimeInterval = 0.72
    static let returnDuration: TimeInterval = 0.46
    static let arrivalStagger: TimeInterval = 0.22
    static let returnStagger: TimeInterval = 0.055
    static let arrival = Animation.timingCurve(0.22, 0.8, 0.24, 1, duration: arrivalDuration)
    static let returning = Animation.timingCurve(0.4, 0, 0.3, 1, duration: returnDuration)

    static func returnDelay(index: Int, count: Int) -> TimeInterval {
        Double(max(0, count - index - 1)) * returnStagger
    }

    static func retirementDelay(count: Int) -> TimeInterval {
        returnDelay(index: 0, count: count) + returnDuration + 0.08
    }
}

struct NotchDropMotion {
    let progress: CGFloat
    /// Final slot in panel coordinates; the screen's top edge is y = 0.
    let slot: CGRect
    /// A single point on the notch's bottom edge, never the notch's outline.
    let origin: CGPoint
    let corner: CGFloat
    let contentInset: CGFloat

    private var p: CGFloat { min(max(progress, 0), 1) }

    static func smoothstep(_ start: CGFloat, _ end: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(max((value - start) / (end - start), 0), 1)
        return t * t * (3 - 2 * t)
    }

    var body: CGRect {
        // Grow a rounded pill out of a point below the camera. On return the
        // same pill shrinks into that point; it never becomes a camera housing.
        let scale = Self.smoothstep(0, 1, p)
        let width = slot.width * scale
        let height = slot.height * scale
        let centerX = origin.x + (slot.midX - origin.x) * p
        let top = origin.y + (slot.minY - origin.y) * p
        return CGRect(x: centerX - width / 2, y: top, width: width, height: height)
    }

    var topRadius: CGFloat {
        // Preserve the pill's proportions, including both rounded ends.
        min(corner, slot.width / 2, slot.height / 2) * Self.smoothstep(0, 1, p)
    }

    var bottomRadius: CGFloat {
        topRadius
    }

    var contentOpacity: Double {
        // Lower drops travel through older ones. Show their text only as it
        // enters its own slot, and fade it before it crosses another on return.
        let clearance = Self.smoothstep(-contentInset, 0, contentOffset)
        return Double(Self.smoothstep(0.32, 0.8, p) * clearance)
    }
    var contentScale: CGFloat { 0.96 + 0.04 * Self.smoothstep(0.32, 1, p) }
    var contentOffset: CGFloat { body.midY - slot.midY }
    /// Keep the source black-on-black. A shadow on the neck creates a halo
    /// around the camera housing, so only the detached body casts one.
    var shadowOpacity: Double {
        let clearance = Self.smoothstep(0, 8, body.minY - origin.y)
        return 0.4 * Double(Self.smoothstep(0.68, 1, p) * clearance)
    }

    var bodyPath: Path {
        let b = body
        let t = topRadius
        let r = bottomRadius
        var path = Path()
        path.move(to: CGPoint(x: b.minX + t, y: b.minY))
        path.addLine(to: CGPoint(x: b.maxX - t, y: b.minY))
        path.addQuadCurve(to: CGPoint(x: b.maxX, y: b.minY + t),
                          control: CGPoint(x: b.maxX, y: b.minY))
        path.addLine(to: CGPoint(x: b.maxX, y: b.maxY - r))
        path.addQuadCurve(to: CGPoint(x: b.maxX - r, y: b.maxY),
                          control: CGPoint(x: b.maxX, y: b.maxY))
        path.addLine(to: CGPoint(x: b.minX + r, y: b.maxY))
        path.addQuadCurve(to: CGPoint(x: b.minX, y: b.maxY - r),
                          control: CGPoint(x: b.minX, y: b.maxY))
        path.addLine(to: CGPoint(x: b.minX, y: b.minY + t))
        path.addQuadCurve(to: CGPoint(x: b.minX + t, y: b.minY),
                          control: CGPoint(x: b.minX, y: b.minY))
        path.closeSubpath()
        return path
    }

    var silhouette: Path {
        let b = body
        let rootY = max(0, origin.y - 1)
        // A short, narrow connection at the bottom center. Never draw a long
        // tether through the stack or spread across the notch's bottom edge.
        let joinY = min(b.midY, b.minY + topRadius + 2)
        let length = joinY - rootY
        let clearance = max(0, b.minY - origin.y)
        let attachment = (1 - Self.smoothstep(0.18, 0.5, p))
            * (1 - Self.smoothstep(6, 22, clearance))
        let root = min(8, b.width / 2) * attachment
        let join = min(8, b.width * 0.25) * attachment
        guard length > 0, attachment > 0, root > 0, b.height > 0 else { return bodyPath }
        let waist = min(root, join) * 0.35
        let middleY = rootY + length * 0.52
        let x = origin.x
        var neck = Path()
        // Both subpaths wind the same way. Nonzero filling combines them
        // without cancellation or a Boolean union's thin-path precision loss.
        neck.move(to: CGPoint(x: x + root, y: rootY))
        neck.addCurve(to: CGPoint(x: x + waist, y: middleY),
                      control1: CGPoint(x: x + root, y: rootY + length * 0.25),
                      control2: CGPoint(x: x + waist, y: middleY - length * 0.18))
        neck.addCurve(to: CGPoint(x: x + join, y: joinY),
                      control1: CGPoint(x: x + waist, y: middleY + length * 0.22),
                      control2: CGPoint(x: x + join * 0.35, y: joinY))
        neck.addLine(to: CGPoint(x: x - join, y: joinY))
        neck.addCurve(to: CGPoint(x: x - waist, y: middleY),
                      control1: CGPoint(x: x - join * 0.35, y: joinY),
                      control2: CGPoint(x: x - waist, y: middleY + length * 0.22))
        neck.addCurve(to: CGPoint(x: x - root, y: rootY),
                      control1: CGPoint(x: x - waist, y: middleY - length * 0.18),
                      control2: CGPoint(x: x - root, y: rootY + length * 0.25))
        neck.closeSubpath()
        var path = bodyPath
        path.addPath(neck)
        return path
    }
}
