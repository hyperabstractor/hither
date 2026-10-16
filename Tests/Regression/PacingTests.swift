import Shared

/// The host's frame window: two in flight at first, more while acks come back unqueued and a frame was waiting
/// (a long link), fewer once acks queue (a full link), and an old minimum round trip ages out after 10 s.
func testFrameWindow() throws {
    var w = FrameWindow(), t = 0.0
    func acks(_ n: Int, rtt: Double, held: Bool) { for _ in 0..<n { t += 1.0 / 60; w.ack(rtt: rtt, at: t, held: held) } }

    acks(30, rtt: 290, held: false)
    try expectEqual(w.limit, 2)           // nothing waited: no reason to grow
    acks(30, rtt: 290, held: true)
    try expectEqual(w.limit, 16)          // India ⇄ Florida with frames waiting: open up
    acks(5, rtt: 290 + 120, held: true)
    try expectEqual(w.limit, 11)          // acks queueing: back off, one per ack
    acks(30, rtt: 290 + 120, held: true)
    try expectEqual(w.limit, 2)

    var lan = FrameWindow()
    for i in 0..<30 { lan.ack(rtt: 8 + Double(i % 3), at: Double(i) / 60, held: true) }
    try expectEqual(lan.limit, 16)        // jitter of a few ms on a LAN isn't queueing

    var moved = FrameWindow()
    moved.ack(rtt: 20, at: 0, held: true)
    moved.ack(rtt: 290, at: 1, held: true)
    try expectEqual(moved.limit, 2)       // looks queued against the old route's 20 ms…
    moved.ack(rtt: 290, at: 12, held: true)
    try expectEqual(moved.limit, 3)       // …until that minimum is 10 s old
}
