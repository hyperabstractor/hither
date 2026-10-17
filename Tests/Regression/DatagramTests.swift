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

/// A frame the encoder dropped goes as an empty packet: the viewer skips its number without losing the picture. And
/// a fragment asked for twice within a round trip goes again only once.
func testFragments() throws {
    var frag = Fragmenter(), asm = Reassembler()
    var shown: [Data] = []
    for (seq, p) in [(UInt32(1), Data([1, 2, 3])), (2, Data()), (3, Data([4]))] {
        for d in frag.fragments(p, seq: seq, key: seq == 1, at: 0) { shown += asm.receive(d, at: 0) }
    }
    try expectEqual(shown, [Data([1, 2, 3]), Data([4])])
    try expectFalse(asm.broken)
    try expectEqual(frag.resend(1, [0], at: 1, gap: 0.3).count, 1)
    try expectEqual(frag.resend(1, [0], at: 1.2, gap: 0.3).count, 0)   // the first copy may still be on its way
    try expectEqual(frag.resend(1, [], at: 1.4, gap: 0.3).count, 1)
}

/// With LTR every frame is independent once the viewer confirmed one: a frame missing a piece is skipped the moment
/// a newer frame arrives whole, it isn't asked for again, no keyframe is needed, and acks carry the shown tokens.
func testIndependentFrames() throws {
    var frag = Fragmenter(), asm = Reassembler()
    var shown: [Data] = []
    for d in frag.fragments(Data([1]), seq: 1, key: true, token: 10, at: 0) { shown += asm.receive(d, at: 0) }
    let broken = frag.fragments(Data(count: 3000), seq: 2, key: false, independent: true, token: 11, at: 0)
    for d in broken.dropLast() { shown += asm.receive(d, at: 0) }   // its last piece is lost
    for d in frag.fragments(Data([3]), seq: 3, key: false, independent: true, token: 12, at: 0) { shown += asm.receive(d, at: 0.001) }
    try expectEqual(shown, [Data([1]), Data([3])])
    try expectFalse(asm.broken)
    try expectEqual(asm.shownTokens, [10, 12])
    try expectTrue(asm.tick(at: 1).nacks.isEmpty)
    try expectEqual(asm.receive(frag.resend(2, [2])[0], at: 1), [])   // a late copy of the skipped frame is ignored…
    try expectEqual(asm.spurious, 0)                                   // …and wasn't asked for, so isn't spurious either
}

/// Input comes in by TCP and UDP copies in any order: each is applied once, in the order it was made.
func testInputOrder() throws {
    var order = InputOrder()
    func key(_ n: UInt32?) -> Msg { var m = Msg("key"); m.n = n; m.k = Int(n ?? 0); return m }
    try expectEqual(order.take(key(2)).map(\.n), [])          // early: waits for 1
    try expectEqual(order.take(key(2)).map(\.n), [])          // a second copy
    try expectEqual(order.take(key(1)).map(\.n), [1, 2])
    try expectEqual(order.take(key(1)).map(\.n), [])          // TCP's copy, late
    try expectEqual(order.take(key(3)).map(\.n), [3])
    try expectEqual(order.take(key(nil)).count, 1)             // an older viewer's, unnumbered
}

/// Seeded, so a failure repeats.
private struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

/// Ten seconds of 60 fps over a 320 ms round trip at 30 Mbps that loses 3% of datagrams each way: every frame the
/// viewer shows is the host's, in order; lost fragments come back on request, and only those, so the picture never
/// stalls for long; and a frame that can't be saved costs a keyframe, not the rest of the stream.
func testLossyLink() throws {
    var rng = LCG(s: 1)
    let oneWay = 0.16, loss = 0.03, perDatagram = Double(fragmentSize + 42) * 8 / 30e6
    var free = 0.0   // when the link can take the next datagram toward the viewer: big frames take a while to arrive
    func toward(_ d: Data, _ t: Double) -> (at: Double, d: Data) { free = max(free, t) + perDatagram; return (free + oneWay, d) }
    var resent = 0, dropped = 0
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
            for d in frag.fragments(p, seq: seq, key: key, at: t) { if rng.next() >= loss { toViewer.append(toward(d, t)) } else { dropped += 1 } }
        }
        for m in toHost where m.at <= t {
            if m.needKey { wantKey = true }
            if let (s, idx) = m.nack {
                for d in frag.resend(s, idx, at: t, gap: 0.9 * 2 * oneWay) { resent += 1; if rng.next() >= loss { toViewer.append(toward(d, t)) } else { dropped += 1 } }
            }
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
    guard seqs.count > 500, worst < 1.2, after < 1, resent < 2 * dropped else {
        throw RegressionFailure(message: "lossy link: \(seqs.count)/\(seq) shown, first at \(after) s, worst stall \(worst) s, \(asm.lost) lost, \(asm.repairedCount) repaired, \(resent) resent for \(dropped) dropped")
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
