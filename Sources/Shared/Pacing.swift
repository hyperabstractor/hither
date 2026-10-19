import Foundation

/// A display mode by its size in points and in pixels (HiDPI: twice the points).
public struct ModeSize: Equatable {
    public let width: Int, height: Int, pixelWidth: Int
    public init(width: Int, height: Int, pixelWidth: Int) { self.width = width; self.height = height; self.pixelWidth = pixelWidth }
}

/// Which of a display's modes a viewer's screen (points, and Retina or not) shows best: for a Retina viewer a HiDPI mode
/// about the size of its own screen if there is one, so text is as sharp as on the screen itself; then the shape that
/// fills the viewer's window most; among near-equals, the most room.
public func bestMode(_ modes: [ModeSize], for viewer: CGSize, scale: Double) -> Int? {
    let usable = modes.indices.filter { modes[$0].width >= 1024 }
    let hiDPI = usable.filter { let m = modes[$0]
        return m.pixelWidth >= 2 * m.width && Double(m.width) >= 0.75 * viewer.width && Double(m.height) >= 0.75 * viewer.height }
    let pool = scale >= 2 && !hiDPI.isEmpty ? hiDPI : usable
    let a = viewer.width / viewer.height
    let fills = { (i: Int) -> Double in let r = Double(modes[i].width) / Double(modes[i].height); return min(r / a, a / r) }
    guard let most = pool.map(fills).max() else { return nil }
    let sharp = { (i: Int) in scale >= 2 ? modes[i].pixelWidth : -modes[i].pixelWidth }   // HiDPI only if it can be seen
    return pool.filter { most - fills($0) < 0.02 }.max { a, b in
        (modes[a].width * modes[a].height, sharp(a)) < (modes[b].width * modes[b].height, sharp(b))
    }
}

/// Adaptive Desktop: the mode closest to the viewer's window (points, Retina or not), so the picture shows near 1:1
/// instead of scaled. Shape counts most, then size; a bit bigger beats a bit smaller (scaled down stays sharp).
public func closestMode(_ modes: [ModeSize], to window: CGSize, scale: Double) -> Int? {
    guard window.width > 0, window.height > 0 else { return nil }
    let usable = modes.indices.filter { modes[$0].width >= 800 }
    let hiDPI = usable.filter { modes[$0].pixelWidth >= 2 * modes[$0].width }
    let plain = usable.filter { modes[$0].pixelWidth < 2 * modes[$0].width }
    let pool = scale >= 2 ? (hiDPI.isEmpty ? usable : hiDPI) : (plain.isEmpty ? usable : plain)
    func cost(_ i: Int) -> Double {
        let w = Double(modes[i].width), h = Double(modes[i].height)
        let shape = abs(log((w / h) / (window.width / window.height)))
        let size = log(w * h / (window.width * window.height))
        return 4 * shape + (size < 0 ? -1.5 * size : size)
    }
    return pool.min { cost($0) < cost($1) }
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
