import Foundation
import SwiftUI

@main
struct NotchDropMotionTests {
    static func main() {
        // Narrow alerts, long substitutions, every size, and the bottom of a
        // five-drop stack must all start at the same physical source.
        for origin in [CGPoint(x: 380, y: 32), CGPoint(x: 380, y: 0)] {
            for width: CGFloat in [120, 340, 680] {
                for height: CGFloat in [32, 48, 64] {
                    for top: CGFloat in [40, 120, 360] {
                        let slot = CGRect(x: 380 - width / 2, y: top, width: width, height: height)
                        func motion(_ p: CGFloat) -> NotchDropMotion {
                            NotchDropMotion(progress: p, slot: slot, origin: origin, corner: 22, contentInset: 10)
                        }
                        let start = motion(0)
                        precondition(start.body.origin == origin, "Drop must disappear into the bottom-center point")
                        precondition(start.body.midX == slot.midX)
                        precondition(start.body.size == .zero, "Drop must not turn into the notch housing")
                        precondition(start.contentOpacity == 0 && start.shadowOpacity == 0)
                        precondition(start.silhouette.isEmpty || start.silhouette.boundingRect.size == .zero)
                        let end = motion(1)
                        precondition(end.body == slot)
                        precondition(end.contentOffset == 0 && end.contentScale == 1)
                        precondition(end.contentOpacity == 1)

                        var previousBottom = start.body.maxY
                        var previousOpacity = start.contentOpacity
                        for step in 1...1_000 {
                            let frame = motion(CGFloat(step) / 1_000)
                            let b = frame.body
                            precondition(b.midX == slot.midX, "Drop drifted away from the notch")
                            precondition(b.maxY >= previousBottom, "A drop reversed direction during arrival")
                            precondition(frame.contentOpacity >= previousOpacity)
                            if frame.contentOffset <= -10 {
                                precondition(frame.contentOpacity == 0, "A label crossed into an older drop")
                            }
                            if b.minY <= origin.y {
                                precondition(frame.shadowOpacity == 0, "A shadow outlined the notch")
                            }
                            precondition(abs(frame.contentOffset + slot.midY - b.midY) < 0.000_001,
                                         "Text and body are on different trajectories")
                            precondition(b.minY >= origin.y, "A drop climbed up into the camera housing")
                            precondition(abs(b.width * slot.height - b.height * slot.width) < 0.000_001,
                                         "Return stretched the pill into the notch's proportions")
                            precondition(frame.topRadius == frame.bottomRadius,
                                         "Return flattened the pill's top into the notch shape")
                            precondition(frame.topRadius <= min(b.width, b.height) / 2)
                            precondition(frame.bottomRadius <= min(b.width, b.height) / 2)
                            // Core Graphics containment is imprecise for
                            // paths far smaller than a physical display pixel.
                            if b.height > 0.01 {
                                precondition(frame.silhouette.contains(CGPoint(x: b.midX, y: b.midY)),
                                             "A hole appeared: origin=\(origin), slot=\(slot), step=\(step), body=\(b), bodyContains=\(frame.bodyPath.contains(CGPoint(x: b.midX, y: b.midY)))")
                            }
                            // The short connection touches the bottom-center
                            // point without turning into a long tether.
                            if step < 150, b.minY - origin.y < 6, b.width > 0.1 {
                                let connection = CGPoint(x: b.midX, y: (origin.y + b.minY) / 2)
                                precondition(frame.silhouette.contains(connection), "Neck detached early")
                            }
                            if step > 500 {
                                precondition(frame.silhouette.boundingRect == frame.bodyPath.boundingRect,
                                             "A tether remained after separation")
                            }
                            previousBottom = b.maxY
                            previousOpacity = frame.contentOpacity
                        }
                        precondition(motion(-0.01).body == start.body)
                        precondition(motion(1.01).body == end.body)
                    }
                }
            }
        }
        for count in 1...5 {
            precondition(NotchDropAnimation.returnDelay(index: count - 1, count: count) == 0)
            for index in 0..<count {
                let end = NotchDropAnimation.returnDelay(index: index, count: count)
                    + NotchDropAnimation.returnDuration
                precondition(end < NotchDropAnimation.retirementDelay(count: count),
                             "A slot was retired before its animation ended")
            }
        }
        print("Notch drop geometry and retirement checks passed (54,000 intermediate frames)")
    }
}
