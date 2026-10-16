import Foundation

/// How many encoded frames the host lets be in flight (sent, not yet acked by the viewer). Two keeps latency lowest on
/// a home network, but over a long link (India to Florida, ~290 ms) two per round trip is about 7 fps. So the window
/// grows while acks come back without queueing delay, and shrinks once they start to queue, which means the link is
/// full and more frames would only wait in line.
public struct FrameWindow {
    public static let range = 2...16
    public private(set) var limit = range.lowerBound
    private var samples: [(at: Double, rtt: Double)] = []   // the last 10 s: their minimum is the unqueued round trip

    public init() {}

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
