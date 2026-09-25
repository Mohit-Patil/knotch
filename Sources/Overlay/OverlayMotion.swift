import AppKit
import QuartzCore

/// Uses the window's display refresh, with no idle timer or permanent polling.
@MainActor
final class OverlayMotion: NSObject {
    @MainActor private final class Target: NSObject {
        weak var owner: OverlayMotion?
        @objc func step(_ link: CADisplayLink) { owner?.step(link) }
    }

    private let target = Target()
    private var link: CADisplayLink?
    private var curve = OverlayMotionCurve(from: 0, to: 0)
    private var startedAt: CFTimeInterval = 0
    private var onFrame: ((Double, Bool) -> Void)?
    private var onCompletion: (() -> Void)?
    private(set) var value: Double = 0
    private(set) var velocity: Double = 0
    var isAnimating: Bool { link != nil }

    override init() { super.init(); target.owner = self }
    isolated deinit { link?.invalidate() }

    func move(to destination: Double, in view: NSView, reducedMotion: Bool,
              animated: Bool, frame: @escaping (Double, Bool) -> Void,
              completion: @escaping () -> Void) {
        if isAnimating, curve.to == destination, curve.reducedMotion == reducedMotion { return }
        if isAnimating { sample() }
        link?.invalidate()
        link = nil
        onCompletion = nil
        if !animated || abs(value - destination) < 0.00001 && abs(velocity) < 0.00001 {
            value = destination; velocity = 0
            onFrame = nil
            frame(destination, reducedMotion)
            completion()
            return
        }
        curve = OverlayMotionCurve(from: value, to: destination,
                                   initialVelocity: velocity, reducedMotion: reducedMotion)
        startedAt = CACurrentMediaTime()
        onFrame = frame
        onCompletion = completion
        frame(value, reducedMotion)
        let next = view.displayLink(target: target, selector: #selector(Target.step(_:)))
        link = next
        next.add(to: .main, forMode: .common)
    }

    func cancel(at value: Double) {
        link?.invalidate(); link = nil
        onFrame = nil; onCompletion = nil
        self.value = value; velocity = 0
    }

    private func sample() {
        let next = curve.sample(at: CACurrentMediaTime() - startedAt)
        value = next.value; velocity = next.velocity
    }

    private func step(_ sender: CADisplayLink) {
        guard sender === link else { return }
        sample()
        onFrame?(value, curve.reducedMotion)
        if CACurrentMediaTime() - startedAt >= curve.duration {
            value = curve.to; velocity = 0
            onFrame?(value, curve.reducedMotion)
            link?.invalidate(); link = nil
            let completion = onCompletion
            onFrame = nil; onCompletion = nil
            completion?()
        }
    }
}
