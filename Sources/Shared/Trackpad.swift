import CoreGraphics
import Foundation

/// An iPhone as the trackpad of the iPad showing a Mac (the iOS app's KeyLink): how far the pointer goes for the
/// finger. A slow finger moves it point for point, for fine work; a fast one several times as far, across the other
/// screen in one swipe, as a Mac's trackpad does.
public enum Trackpad {
    /// The pointer's distance per finger distance, for a finger moving at `speed` points a second.
    public static func gain(speed: CGFloat) -> CGFloat { min(max(0.6 + speed / 350, 1), 4.5) }

    /// How far the pointer goes for a finger that moved by `d` in `dt` seconds.
    public static func move(_ d: CGPoint, in dt: TimeInterval) -> CGPoint {
        let g = gain(speed: hypot(d.x, d.y) / CGFloat(max(dt, 1.0 / 240)))
        return CGPoint(x: d.x * g, y: d.y * g)
    }
}
