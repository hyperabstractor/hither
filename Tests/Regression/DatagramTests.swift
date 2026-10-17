import Foundation
import Network
import Shared

/// A sealed datagram opens only for its own session and the other end, once: not forged, damaged or replayed.
func testSeal() throws {
    let secret = Data(repeating: 7, count: 32)
    var host = Seal(secret: secret, tag: 42, host: true), viewer = Seal(secret: secret, tag: 42, host: false)
    let d = host.seal(Data("frame".utf8))
    try expectEqual(Seal.tag(of: d), 42)
    try expectTrue(d.count == 5 + 32)
    try expectEqual(viewer.open(d), Data("frame".utf8))
    try expectNil(viewer.open(d))                                   // replayed
    var bad = host.seal(Data("x".utf8)); bad[bad.count - 1] ^= 1
    try expectNil(viewer.open(bad))                                 // damaged
    var own = Seal(secret: secret, tag: 42, host: true)
    try expectNil(own.open(host.seal(Data("x".utf8))))              // our own direction reflected back
    var other = Seal(secret: Data(repeating: 8, count: 32), tag: 42, host: false)
    try expectNil(other.open(host.seal(Data("x".utf8))))            // another session's key
    let late = host.seal(Data("late".utf8)), soon = host.seal(Data("soon".utf8))
    try expectEqual(viewer.open(soon), Data("soon".utf8))
    try expectEqual(viewer.open(late), Data("late".utf8))           // out of order is fine, once
    try expectNil(viewer.open(late))
}

/// Seeded, so a failure repeats.
private struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

/// Ten seconds of 60 fps over a 320 ms round trip that loses 3% of datagrams each way: every frame the viewer shows
/// is the host's, in order; lost fragments come back on request, so the picture never stalls for long; and a frame
/// that can't be saved costs a keyframe, not the rest of the stream.
func testLossyLink() throws {
    var rng = LCG(s: 1)
    let oneWay = 0.16, loss = 0.03
    var frag = Fragmenter(), asm = Reassembler()
    var toViewer: [(at: Double, d: Data)] = [], toHost: [(at: Double, nack: (UInt32, [Int])?, needKey: Bool)] = []
    var sent: [UInt32: Data] = [:], shown: [Data] = [], shownAt: [Double] = []
    var wantKey = true, lastKey = -1.0
    var t = 0.0, seq: UInt32 = 0
    while t < 10 {
        // host: a frame every 1/60 s, mostly small, a keyframe when asked (at most once a round trip)
        if t >= Double(seq) / 60 {
            seq += 1
            let key = wantKey && t - lastKey > 2 * oneWay
            if key { wantKey = false; lastKey = t }
            let size = key ? 120_000 : seq % 30 == 0 ? 40_000 : 2_000 + Int(rng.next() * 6000)
            var p = Data(count: size); p.withUnsafeMutableBytes { $0.storeBytes(of: seq, as: UInt32.self) }
            sent[seq] = p
            for d in frag.fragments(p, seq: seq, key: key, at: t) where rng.next() >= loss { toViewer.append((t + oneWay, d)) }
        }
        for m in toHost where m.at <= t {
            if m.needKey { wantKey = true }
            if let (s, idx) = m.nack { for d in frag.resend(s, idx) where rng.next() >= loss { toViewer.append((t + oneWay, d)) } }
        }
        toHost.removeAll { $0.at <= t }
        // viewer
        for m in toViewer where m.at <= t { for p in asm.receive(m.d, at: t) { shown.append(p); shownAt.append(t) } }
        toViewer.removeAll { $0.at <= t }
        let (nacks, ready) = asm.tick(at: t)
        for p in ready { shown.append(p); shownAt.append(t) }
        for n in nacks where rng.next() >= loss { toHost.append((t + oneWay, n, false)) }
        if asm.broken, rng.next() >= loss { toHost.append((t + oneWay, nil, true)) }
        t += 0.002
    }
    let seqs = shown.map { $0.withUnsafeBytes { $0.load(as: UInt32.self) } }
    for (s, p) in zip(seqs, shown) { try expectEqual(p, sent[s]) }
    try expectEqual(seqs, seqs.sorted())
    try expectEqual(Set(seqs).count, seqs.count)
    let gaps = zip(shownAt.dropFirst(), shownAt).map { $0 - $1 }.sorted()
    let worst = gaps.last ?? 99, after = shownAt.first ?? 99
    guard seqs.count > 500, worst < 1.2, after < 0.5 else {
        throw RegressionFailure(message: "lossy link: \(seqs.count)/\(seq) shown, first at \(after) s, worst stall \(worst) s, \(asm.lost) lost, \(asm.repairedCount) repaired")
    }
}

/// The real thing on loopback: a VideoLink against a sealed UDP flow, with fragments resent when it asks.
func testVideoLink() throws {
    let secret = Data(repeating: 9, count: 32), q = DispatchQueue(label: "hither.tests.udp")
    let listener = try NWListener(using: .udp, on: .any)
    let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    var seal = Seal(secret: secret, tag: 5, host: true), frag = Fragmenter(), got: [Data] = []
    let frames = (1...20).map { i in Data((0..<(i == 1 ? 9000 : 3000)).map { UInt8(truncatingIfNeeded: $0 * i) }) }
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { flow in
        flow.start(queue: q)
        var started = false
        func rx() {
            flow.receiveMessage { d, _, _, err in
                guard let d, let plain = seal.open(d) else { if err == nil { rx() }; return }
                var r = Reader(plain)
                switch r.u8() {
                case 2 where !started:   // first keepalive: the path works, send the frames, losing every 4th fragment
                    started = true
                    var n = 0
                    for (i, f) in frames.enumerated() {
                        for p in frag.fragments(f, seq: UInt32(i + 100), key: i == 0, at: 0) {
                            n += 1
                            if n % 4 != 0 { flow.send(content: seal.seal(p), completion: .idempotent) }
                        }
                    }
                case 3:
                    let s = r.u32(), idx = (0..<Int(r.u16())).map { _ in Int(r.u16()) }
                    for p in frag.resend(s, idx) { flow.send(content: seal.seal(p), completion: .idempotent) }
                default: break
                }
                rx()
            }
        }
        rx()
    }
    listener.start(queue: q)
    defer { listener.cancel() }
    guard ready.wait(timeout: .now() + 5) == .success else { throw RegressionFailure(message: "UDP listener did not start") }
    let link = VideoLink(secret: secret, tag: 5, to: "127.0.0.1", port: listener.port!)
    link.onFrame = { got.append($0); if got.count == frames.count { done.signal() } }
    link.start()
    defer { link.stop() }
    guard done.wait(timeout: .now() + 5) == .success else {
        throw RegressionFailure(message: "VideoLink delivered \(got.count) of \(frames.count) frames")
    }
    try expectEqual(got, frames)
}
