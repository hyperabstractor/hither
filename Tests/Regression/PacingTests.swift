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
    // Adaptive Desktop: a mode that fits the viewer's room shows 1:1 and the window snaps to it; a bigger one only
    // when it fills the window much better. Retina for Retina.
    let room = CGSize(width: 1710, height: 1045)   // the Air: visible area less the title bar
    // the LG's Retina modes that fit the Air are tiny (1280×540): 1920×1080 a little scaled down fills it
    try expectEqual(snapMode(lg, to: room, within: room, scale: 2).map { lg[$0] }, ModeSize(width: 1920, height: 1080, pixelWidth: 3840))
    try expectEqual(snapMode(lg, to: CGSize(width: 1700, height: 760), within: CGSize(width: 1800, height: 1045), scale: 2).map { lg[$0] }, ModeSize(width: 1720, height: 720, pixelWidth: 3440))
    try expectEqual(snapMode(lg, to: CGSize(width: 1700, height: 760), within: CGSize(width: 1800, height: 1045), scale: 1).map { lg[$0] }, ModeSize(width: 1720, height: 720, pixelWidth: 1720))
    try expectEqual(snapMode(lg, to: CGSize(width: 3440, height: 1440), within: CGSize(width: 3440, height: 1440), scale: 1).map { lg[$0] }, ModeSize(width: 3440, height: 1440, pixelWidth: 3440))
    try expectEqual(snapMode(lg, to: CGSize(width: 1250, height: 560), within: room, scale: 2).map { lg[$0] }, ModeSize(width: 1280, height: 540, pixelWidth: 2560))
    // the Mini's Acer 4K (its Retina modes, all 16:9) from the Air: 1:1 modes that fit beat a scaled-down 1920×1080
    let acer = [(800, 600), (840, 525), (960, 540), (1024, 576), (1152, 648), (1280, 720), (1504, 846), (1600, 900),
                (1680, 945), (1920, 1080), (2048, 1152), (2304, 1296), (2560, 1440)].map { ModeSize(width: $0.0, height: $0.1, pixelWidth: 2 * $0.0) }
    try expectEqual(snapMode(acer, to: room, within: room, scale: 2).map { acer[$0] }, ModeSize(width: 1680, height: 945, pixelWidth: 3360))
    try expectEqual(snapMode(acer, to: CGSize(width: 1300, height: 750), within: room, scale: 2).map { acer[$0] }, ModeSize(width: 1280, height: 720, pixelWidth: 2560))
    try expectEqual(snapMode(acer, to: CGSize(width: 1590, height: 890), within: room, scale: 2).map { acer[$0] }, ModeSize(width: 1600, height: 900, pixelWidth: 3200))
    try expectEqual(snapMode(acer, to: CGSize(width: 2000, height: 1100), within: CGSize(width: 2560, height: 1400), scale: 2).map { acer[$0] }, ModeSize(width: 1920, height: 1080, pixelWidth: 3840))
    // …and shown pixel for pixel, centered, in a full-screen window bigger than it (never scaled up)
    let oneToOne = pictureRect(view: CGSize(width: 1710, height: 1075), remote: CGSize(width: 1680, height: 945), zoom: nil, pan: .zero, maxFit: 1).rect
    try expectEqual(oneToOne, CGRect(x: 15, y: 65, width: 1680, height: 945))
    // app windows for a Retina viewer: the roomiest HiDPI mode
    try expectEqual(largestRetina(lg).map { lg[$0] }, ModeSize(width: 2048, height: 1080, pixelWidth: 4096))
    try expectNil(largestRetina([ModeSize(width: 3440, height: 1440, pixelWidth: 3440)]))
    // Native Desktop zoom: fit letterboxes; 100% of a 3440×1440 screen in a 1700×1000 view scrolls, clamped
    let view = CGSize(width: 1700, height: 1000), lgSize = CGSize(width: 3440, height: 1440)
    let fit = pictureRect(view: view, remote: lgSize, zoom: nil, pan: .zero).rect
    try expectEqual(fit.width, 1700); try expectTrue(fit.minY > 0)
    let full = pictureRect(view: view, remote: lgSize, zoom: 1, pan: CGPoint(x: 5000, y: -20))
    try expectEqual(full.pan, CGPoint(x: 1740, y: 0))
    try expectEqual(full.rect, CGRect(x: -1740, y: 0, width: 3440, height: 1440))
    try expectEqual(remotePoint(CGPoint(x: 1700, y: 1000), in: full.rect, remote: lgSize), CGPoint(x: 3440, y: 1000))
    try expectEqual(remotePoint(CGPoint(x: 850, y: 500), in: fit, remote: lgSize),
                    remotePoint(CGPoint(x: 850, y: 500), view: view, remote: lgSize))
}
