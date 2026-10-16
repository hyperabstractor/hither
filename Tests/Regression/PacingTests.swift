import Foundation
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

/// The office LG ultrawide (its real mode list) viewed from a 15" MacBook Air (1710×1112 points, Retina): the
/// 1920×1080 HiDPI mode, sharp and 16:9, not the 4:3 mode that fills its window a hair better. A non-Retina viewer
/// gets the same room without HiDPI (it couldn't show the extra pixels, and they'd cost a 4K encode).
func testDisplayFit() throws {
    let lg = [(3440, 1440, 3440), (2560, 1080, 2560), (2048, 1080, 4096), (1920, 1080, 3840), (1920, 1080, 1920),
              (1600, 1200, 1600), (2048, 858, 2048), (1920, 804, 1920), (1344, 1008, 1344), (1720, 720, 1720),
              (1720, 720, 3440), (1280, 960, 1280), (1600, 670, 1600), (1280, 720, 1280), (1024, 768, 1024),
              (1344, 562, 1344), (1280, 540, 2560), (1280, 536, 1280), (960, 540, 1920), (800, 600, 1600), (800, 600, 800)]
        .map { ModeSize(width: $0.0, height: $0.1, pixelWidth: $0.2) }
    let air = CGSize(width: 1710, height: 1112)
    try expectEqual(bestMode(lg, for: air, scale: 2).map { lg[$0] }, ModeSize(width: 1920, height: 1080, pixelWidth: 3840))
    try expectEqual(bestMode(lg, for: air, scale: 1).map { lg[$0] }, ModeSize(width: 1920, height: 1080, pixelWidth: 1920))
    try expectEqual(bestMode(lg, for: CGSize(width: 1920, height: 1080), scale: 2).map { lg[$0] }, ModeSize(width: 1920, height: 1080, pixelWidth: 3840))
}
