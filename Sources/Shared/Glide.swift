import CoreGraphics
import Foundation

/// The glide after a flick: a viewer whose touch scrolls have no momentum of their own makes it, the way a Mac trackpad
/// does, as momentum scroll events after the gesture's end. Velocity decays exponentially with elapsed time (not
/// frames), so it goes as far, as fast, at 30, 60 or 120 Hz; a stalled frame resumes at most `longestStep` on.
public struct Glide {
    /// CGMomentumScrollPhase raw values (not CGScrollPhase: that's the gesture's own, over by now).
    public enum Phase: Int { case began = 1, changed = 2, ended = 3 }
    public struct Step: Equatable {
        public let delta: CGPoint
        public let phase: Phase
        public init(delta: CGPoint, phase: Phase) { self.delta = delta; self.phase = phase }
    }

    /// Seconds for the speed to fall to 1/e: UIScrollView's normal deceleration (0.998 per ms).
    public static let timeConstant = -0.001 / log(0.998)
    /// The most time one step covers: after a stall the glide carries on rather than jumping.
    public static let longestStep = 0.05

    private let velocity: CGPoint   // at the flick, units per second
    private let stopSpeed: CGFloat
    private var elapsed = 0.0       // glide time so far (stalls beyond longestStep don't count)
    private var last: TimeInterval
    public private(set) var ended = false

    /// nil if the flick is slower than `minimum` (it just stops); otherwise it glides until slower than `stop`.
    /// At most `maximum` fast: a velocity estimate can spike.
    public init?(velocity v: CGPoint, at now: TimeInterval, minimum: CGFloat, stop: CGFloat, maximum: CGFloat) {
        let speed = hypot(v.x, v.y)
        guard speed >= minimum, speed > stop, speed > 0 else { return nil }
        let k = min(1, maximum / speed)
        velocity = CGPoint(x: v.x * k, y: v.y * k)
        stopSpeed = stop
        last = now
    }

    /// The first event, right after the gesture's end: nothing moved yet.
    public var start: Step { Step(delta: .zero, phase: .began) }

    /// How far it glides from the last step to `now`. The last step is `.ended`; nil after that.
    public mutating func step(to now: TimeInterval) -> Step? {
        guard !ended else { return nil }
        let dt = min(max(0, now - last), Self.longestStep), tau = Self.timeConstant
        last = now
        let a = exp(-elapsed / tau), b = exp(-(elapsed + dt) / tau)
        elapsed += dt
        let d = CGFloat(tau * (a - b))
        if hypot(velocity.x, velocity.y) * CGFloat(b) < stopSpeed { ended = true }
        return Step(delta: CGPoint(x: velocity.x * d, y: velocity.y * d), phase: ended ? .ended : .changed)
    }

    /// Stopped short (a new touch, a switch, closing): the end event, if it hasn't been sent; nil if it has.
    public mutating func stop() -> Step? {
        guard !ended else { return nil }
        ended = true
        return Step(delta: .zero, phase: .ended)
    }
}
