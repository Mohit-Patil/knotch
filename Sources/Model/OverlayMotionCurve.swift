import SwiftUI

/// Presentation progress only. Terminal bounds and process lifetime never follow this curve.
struct OverlayMotionCurve {
    var from: Double
    var to: Double
    var initialVelocity: Double = 0
    var reducedMotion = false

    var duration: Double { reducedMotion ? 0.12 : (to == 1 ? 0.58 : 0.34) }

    func sample(at time: Double) -> (value: Double, velocity: Double) {
        if time >= duration { return (to, 0) }
        let time = max(0, time)
        if reducedMotion {
            let t = time / duration
            return (from + (to - from) * t * t * (3 - 2 * t),
                    (to - from) * 6 * t * (1 - t) / duration)
        }
        let spring = Spring(duration: to == 1 ? 0.34 : 0.22, bounce: to == 1 ? 0.28 : 0)
        return (from + spring.value(target: to - from, initialVelocity: initialVelocity, time: time),
                spring.velocity(target: to - from, initialVelocity: initialVelocity, time: time))
    }
}
