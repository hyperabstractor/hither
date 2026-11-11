import Foundation

/// A display mode by its size in points and in pixels (HiDPI: twice the points).
public struct ModeSize: Equatable {
    public let width: Int, height: Int, pixelWidth: Int
    public init(width: Int, height: Int, pixelWidth: Int) { self.width = width; self.height = height; self.pixelWidth = pixelWidth }
}

/// Adaptive Desktop sizes on the iPad: Default is the view's own points (1:1, Retina), More Space and Most Space give
/// the Mac that many times more, which the viewer shows scaled down to fit (still Retina-rendered, like a Mac's own
/// scaled modes, so text stays sharp, just smaller).
public enum DesktopSpace: Double, CaseIterable, Sendable {
    case standard = 1, more = 1.25, most = 1.5
    public var name: String { switch self { case .standard: "Default"; case .more: "More Space"; case .most: "Most Space" } }
    /// The Mac's screen, in points, for a view this size.
    public func size(for view: CGSize) -> CGSize {
        CGSize(width: (view.width * rawValue).rounded(.down), height: (view.height * rawValue).rounded(.down))
    }
}

/// Adaptive Desktop on a virtual display, which can be any size: exactly the viewer's window (no bigger than its room),
/// in whole points, never below the smallest size macOS lays a desktop out in (a smaller window shows it scaled down).
public func virtualSize(for window: CGSize, within room: CGSize) -> (width: Int, height: Int)? {
    guard window.width > 0, window.height > 0 else { return nil }
    let w = room.width > 0 ? min(window.width, room.width) : window.width, h = room.height > 0 ? min(window.height, room.height) : window.height
    return (max(640, Int(w.rounded(.down))), max(480, Int(h.rounded(.down))))
}

/// App windows for a Retina viewer: the HiDPI mode with the most room, so their text is captured at 2x.
public func largestRetina(_ modes: [ModeSize]) -> Int? {
    modes.indices.filter { modes[$0].width >= 1024 && modes[$0].pixelWidth >= 2 * modes[$0].width }
        .max { (modes[$0].width * modes[$0].height, modes[$0].pixelWidth) < (modes[$1].width * modes[$1].height, modes[$1].pixelWidth) }
}

/// How many encoded frames the host lets be in flight (sent, not yet acked by the viewer). Two keeps latency lowest on
/// a home network, but over a long link (India to Florida, ~290 ms) two per round trip is about 7 fps. So the window
/// grows while acks come back without queueing delay, and shrinks once they start to queue, which means the link is
/// full and more frames would only wait in line.
public struct FrameWindow {
    public static let range = 2...16
    public private(set) var limit = range.lowerBound
    private var samples: [(at: Double, rtt: Double)] = []   // the last 10 s: their minimum is the unqueued round trip

    public init() {}

    /// The quickest round trip lately (ms): the link's own, without queueing.
    public var base: Double? { samples.map(\.rtt).min() }

    /// A frame was acked `rtt` ms after it was sent. `held`: a newer frame waited on the window meanwhile, so more
    /// room would have been used.
    public mutating func ack(rtt: Double, at now: Double, held: Bool) {
        samples.append((now, rtt))
        samples.removeFirst(samples.prefix { now - $0.at > 10 }.count)
        let base = samples.map(\.rtt).min() ?? rtt
        let queued = rtt - base
        if queued > max(30, base / 4) {
            limit = max(Self.range.lowerBound, limit - 1)
        } else if held && queued < max(10, base / 10) {
            limit = min(Self.range.upperBound, limit + 1)
        }
    }
}
