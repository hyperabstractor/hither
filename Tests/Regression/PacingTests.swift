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

/// Display sizes: Adaptive's on a virtual display (exactly the viewer's, or more of them), and the Retina mode app
/// windows get (the office LG ultrawide's real mode list).
func testDisplayFit() throws {
    let lg = [(3440, 1440, 3440), (2560, 1080, 2560), (2048, 1080, 4096), (1920, 1080, 3840), (1920, 1080, 1920),
              (1600, 1200, 1600), (2048, 858, 2048), (1920, 804, 1920), (1344, 1008, 1344), (1720, 720, 1720),
              (1720, 720, 3440), (1280, 960, 1280), (1600, 670, 1600), (1280, 720, 1280), (1024, 768, 1024),
              (1344, 562, 1344), (1280, 540, 2560), (1280, 536, 1280), (960, 540, 1920), (800, 600, 1600), (800, 600, 800)]
        .map { ModeSize(width: $0.0, height: $0.1, pixelWidth: $0.2) }
    let room = CGSize(width: 1710, height: 1045)   // the Air: visible area less the title bar
    // the iPad mini's view (1158×756) with more space: 1.25× and 1.5× the points, shown scaled down
    try expectEqual(DesktopSpace.more.size(for: CGSize(width: 1158, height: 756)), CGSize(width: 1447, height: 945))
    try expectEqual(DesktopSpace.most.size(for: CGSize(width: 1158, height: 756)), CGSize(width: 1737, height: 1134))
    try expectEqual(DesktopSpace.standard.size(for: CGSize(width: 1158, height: 756)), CGSize(width: 1158, height: 756))
    // on a virtual display: the window's size exactly, within its room, not below what macOS lays out
    try expectEqual(virtualSize(for: CGSize(width: 1133, height: 744), within: CGSize(width: 1133, height: 744)).map { [$0.width, $0.height] }, [1133, 744])   // iPad mini
    try expectEqual(virtualSize(for: CGSize(width: 1700.6, height: 1200), within: room).map { [$0.width, $0.height] }, [1700, 1045])
    try expectEqual(virtualSize(for: CGSize(width: 500, height: 300), within: room).map { [$0.width, $0.height] }, [640, 480])
    try expectEqual(virtualSize(for: .zero, within: room).map { [$0.width, $0.height] }, nil)
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
