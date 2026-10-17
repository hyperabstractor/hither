import CryptoKit
import Foundation
import Network

// Video over UDP. TCP delivers in order, so one lost packet holds every later frame for a round trip, and at India ⇄
// Florida's ~320 ms even 1% loss caps TCP near 1 Mbps. Datagrams let a loss cost one frame's repair instead. QUIC would
// do, but Network.framework turns TLS 1.3 off once a pre-shared key is set, and QUIC needs 1.3; so it's plain UDP,
// sealed with a key the TLS-PSK control connection exports (the pairing stays the only trust root).
//
// Datagram: [tag u64][counter u64][ChaChaPoly ciphertext][tag 16]. The tag names the session (the host has one UDP
// port for all of them), the counter is the nonce and the replay check. Plaintext starts with a type byte:
//   host → viewer  1 fragment  [seq u32][index u16][count u16][flags u8][token u32][bytes]
//                     flags: 1 keyframe, 2 resent, 4 independent (built only on frames the viewer confirmed, so it
//                     decodes whatever was lost before it), 8 the token is the frame's long-term reference (LTR)
//   viewer → host  2 ack       [seq u32: newest whole frame][flags u8: 1 need a keyframe, 2 that frame was repaired]
//                              [n u8]([token u32])*n: the LTR tokens of the last frames shown, for the encoder
//                  3 nack      [seq u32][n u16]([index u16])*n   n = 0: the whole frame
//                  4 input     [JSON Msg with its order n]: three copies, as well as the one on TCP
// Acks also go out every 250 ms as a keepalive: they hold the NAT open and tell the host the path still works.

public let videoPort: NWEndpoint.Port = 7421
/// Each datagram stays under Tailscale's 1280-byte MTU with IP/UDP, the seal (32) and the fragment header (14).
public let fragmentSize = 1150

/// One direction pair of sealed datagrams for a session. Not thread-safe: keep it on one queue.
public struct Seal {
    let key: SymmetricKey, host: Bool
    public let tag: UInt64
    private var counter: UInt64 = 0
    private var highest: UInt64 = 0, seen: UInt64 = 0   // replay window: the newest counter and the 64 below it

    /// `secret` from `Wire.secret`, `tag` from the host's "udp" message; `host` picks which nonces are ours.
    public init(secret: Data, tag: UInt64, host: Bool) { key = SymmetricKey(data: secret); self.tag = tag; self.host = host }

    public static func tag(of d: Data) -> UInt64? {
        guard d.count >= 8 else { return nil }
        var r = Reader(d)
        return r.u64()
    }

    public mutating func seal(_ plain: Data) -> Data {
        counter += 1
        var head = Data(capacity: 16 + plain.count + 16)
        head.put(tag); head.put(counter)
        let box = try! ChaChaPoly.seal(plain, using: key, nonce: nonce(host, counter), authenticating: head)
        head.append(box.ciphertext); head.append(box.tag)
        return head
    }

    /// The plaintext, or nil for anything forged, damaged, for another session, or seen before.
    public mutating func open(_ d: Data) -> Data? {
        guard d.count >= 32 else { return nil }
        var r = Reader(d)
        guard r.u64() == tag else { return nil }
        let c = r.u64()
        guard c > highest || (highest - c < 64 && seen & (1 << (highest - c)) == 0) else { return nil }
        let body = r.rest()
        guard let box = try? ChaChaPoly.SealedBox(nonce: nonce(!host, c), ciphertext: body.dropLast(16), tag: body.suffix(16)),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: d.prefix(16)) else { return nil }
        if c > highest { seen = c - highest >= 64 ? 0 : seen << (c - highest); highest = c }
        seen |= 1 << (highest - c)
        return plain
    }

    private func nonce(_ fromHost: Bool, _ c: UInt64) -> ChaChaPoly.Nonce {
        var n = Data(capacity: 12)
        n.put(UInt32(fromHost ? 0 : 1)); n.put(c)
        return try! ChaChaPoly.Nonce(data: n)
    }
}

/// Host side: a video packet → fragments, kept for two seconds in case the viewer asks for some again. An empty
/// packet stands for a frame the encoder dropped, so its number isn't missed.
public struct Fragmenter {
    private var sent: [UInt32: (at: Double, parts: [Data], resent: [Double])] = [:]
    public init() {}

    public mutating func fragments(_ packet: Data, seq: UInt32, key: Bool, independent: Bool = false, token: UInt32? = nil,
                                   at now: Double) -> [Data] {
        let count = max(1, (packet.count + fragmentSize - 1) / fragmentSize)
        let flags: UInt8 = (key ? 1 : 0) | (independent ? 4 : 0) | (token != nil ? 8 : 0)
        let parts = (0..<count).map { i in
            fragment(seq, i, count, flags, token ?? 0, packet.dropFirst(i * fragmentSize).prefix(fragmentSize))
        }
        sent = sent.filter { now - $0.value.at < 2 }
        sent[seq] = (now, parts, Array(repeating: -.infinity, count: count))
        return parts
    }

    /// The fragments `indices` of frame `seq` (all of them when empty), marked resent; none once it's too old. A
    /// fragment resent less than `gap` ago is skipped: the viewer asked before that copy could arrive, and sending
    /// it again would only add to whatever queue delayed it.
    public mutating func resend(_ seq: UInt32, _ indices: [Int], at now: Double = 0, gap: Double = 0) -> [Data] {
        guard var f = sent[seq] else { return [] }
        let want = (indices.isEmpty ? Array(f.parts.indices) : indices.filter(f.parts.indices.contains)).filter { now - f.resent[$0] >= gap }
        for i in want { f.resent[i] = now }
        sent[seq] = f
        return want.map {
            var p = f.parts[$0]
            p[p.startIndex + 9] |= 2
            return p
        }
    }

    private func fragment(_ seq: UInt32, _ i: Int, _ count: Int, _ flags: UInt8, _ token: UInt32, _ bytes: Data) -> Data {
        var d = Data(capacity: 14 + bytes.count)
        d.put(UInt8(1)); d.put(seq); d.put(UInt16(i)); d.put(UInt16(count)); d.put(flags); d.put(token); d.append(bytes)
        return d
    }
}

/// Viewer side: fragments back into whole video packets, in order. A missing fragment is asked for again (a nack)
/// rather than waited out; a frame that can't be repaired in time is dropped, and since every later P-frame would
/// decode to garbage, nothing more is shown until a keyframe, which the acks ask for. A keyframe that arrives whole
/// skips over anything older still being repaired, and so does an independent frame (LTR): it was built only on
/// frames shown here, so nothing lost before it matters. With those, only the newest frame is ever asked for again.
public struct Reassembler {
    struct Partial {
        var parts: [Data?], key = false, repaired = false, independent = false, token: UInt32? = nil
        var heard: Double, nacked: Double?   // last fragment in; last nack out
        var nacks = 0
        var started: Double                  // first noticed: it gives up a while after this
        var complete: Bool { !parts.isEmpty && !parts.contains(nil) }
    }
    /// The next frame to hand on. nil until the first fragment.
    public private(set) var next: UInt32?
    private var frames: [UInt32: Partial] = [:]
    private var newest: (seq: UInt32, index: Int)?   // the furthest fragment heard: anything sent before it is late
    /// Waiting for a keyframe: at the start, and after a frame was lost.
    public private(set) var broken = true
    /// The newest whole frame, for acks, and whether it needed a resend.
    public private(set) var acked: (seq: UInt32, repaired: Bool)?
    /// Time to wait for a resend before asking again: a round trip, learned from resends, and a margin.
    public private(set) var resendWait = 0.4
    public private(set) var lost = 0, repairedCount = 0
    /// Resent fragments that weren't needed: a copy was already here, or the frame was already shown. Near zero
    /// unless the viewer asks too soon.
    public private(set) var spurious = 0
    private var passed: Set<UInt32> = []   // recent frames given up or skipped: resends for them came late, not spuriously
    private var newestIndependent = false  // the newest frame heard was independent: older ones will never be needed
    /// LTR tokens of the last few frames handed on, newest last: acks carry them so the encoder can build on them.
    public private(set) var shownTokens: [UInt32] = []

    public init() {}

    /// A fragment in. Returns the packets now ready to decode, oldest first.
    public mutating func receive(_ d: Data, at now: Double) -> [Data] {
        var r = Reader(d)
        guard d.count >= 14, r.u8() == 1 else { return [] }
        let seq = r.u32(), i = Int(r.u16()), count = Int(r.u16()), flags = r.u8(), token = r.u32()
        guard count > 0, i < count else { return [] }
        if next == nil { next = seq }
        guard let n = next, !before(seq, n) else {   // delivered or given up
            if flags & 2 != 0, !passed.contains(seq) { spurious += 1 }
            return []
        }
        if newest.map({ before($0.seq, seq) || ($0.seq == seq && $0.index < i) }) ?? true {
            newest = (seq, i)
            newestIndependent = flags & 4 != 0
        }
        var f = frames[seq] ?? Partial(parts: [], heard: now, nacked: nil, started: now)
        if f.parts.count != count { f.parts = Array(repeating: nil, count: count) }   // first heard of it (or a whole-frame nack placeholder)
        if f.parts[i] != nil { spurious += 1 }
        if f.parts[i] == nil {
            f.parts[i] = r.rest()
            if flags & 2 != 0 {
                f.repaired = true
                // a round trip, from first asks only: a later ask may be answered by the copy an earlier one brought
                if f.nacks == 1, let t = f.nacked { resendWait = 0.8 * resendWait + 0.2 * max(0.05, (now - t) * 1.3 + 0.03) }
            }
        }
        f.key = f.key || flags & 1 != 0
        f.independent = f.independent || flags & 4 != 0
        if flags & 8 != 0 { f.token = token }
        f.heard = now
        frames[seq] = f
        if f.complete {
            if let a = acked, !before(a.seq, seq) {} else { acked = (seq, f.repaired) }
            if f.repaired { repairedCount += 1 }
            if f.key || f.independent, seq != n {   // a picture that needs nothing older: skip what's still missing
                for s in frames.keys where before(s, seq) { frames[s] = nil }
                var s = n
                while before(s, seq) { pass(s); s = s &+ 1 }
                next = seq
            }
        }
        return deliver()
    }

    /// What to ask for again now: (frame, missing indices; empty = the whole frame). Also gives up on frames that
    /// waited too long, which may free later frames to decode.
    public mutating func tick(at now: Double) -> (nacks: [(seq: UInt32, indices: [Int])], ready: [Data]) {
        guard let top = newest, var s = next else { return ([], []) }
        var nacks: [(seq: UInt32, indices: [Int])] = []
        while !before(top.seq, s) {
            defer { s = s &+ 1 }
            var f = frames[s] ?? Partial(parts: [], heard: now, nacked: nil, started: now)   // nothing of it heard yet
            if f.complete { continue }
            // In order: the frame up next goes once repairing it took too long, or at once if a loss already means
            // waiting for a keyframe and this isn't one
            if s == next, (broken && !f.key) || now - f.started > max(1, 3 * resendWait) {
                frames[s] = nil
                lost += 1
                pass(s)
                if !newestIndependent { broken = true }   // with LTR a newer frame repairs the picture by itself
                next = s &+ 1
                continue
            }
            // a newer independent frame is coming: it will show instead, so this one isn't worth a round trip
            if newestIndependent, s != top.seq { frames[s] = f; continue }
            // late: sent before something that already came, or anything once the frame went quiet. (A big frame
            // takes a while to arrive: what's after the newest fragment heard is still on its way.)
            let quiet = now - f.heard > 0.03
            let missing = f.parts.indices.filter { f.parts[$0] == nil && (quiet || s != top.seq || $0 < top.index) }
            if !missing.isEmpty || f.parts.isEmpty, f.nacked.map({ now - $0 > resendWait }) ?? true {
                nacks.append((s, f.parts.isEmpty || missing.count > 500 ? [] : missing))
                f.nacked = now
                f.nacks += 1
            }
            frames[s] = f
        }
        return (nacks, deliver())
    }

    private mutating func deliver() -> [Data] {
        var out: [Data] = []
        while let n = next, let f = frames[n], f.complete {
            frames[n] = nil
            next = n &+ 1
            let p = f.parts.reduce(into: Data()) { $0.append($1!) }
            if p.isEmpty { continue }          // the encoder dropped it: nothing to show, and nothing lost
            if broken && !f.key && !f.independent { continue }   // can't decode without the reference that was lost
            broken = false
            if let t = f.token { shownTokens = (shownTokens + [t]).suffix(4) }
            out.append(p)
        }
        return out
    }

    private mutating func pass(_ s: UInt32) {
        passed.insert(s)
        if passed.count > 256 { passed.remove(passed.min { before($0, $1) }!) }
    }

    /// Sequence order that survives the u32 wrapping.
    func before(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
}

public func ackDatagram(_ seq: UInt32, needKey: Bool, repaired: Bool, tokens: [UInt32] = []) -> Data {
    var d = Data(); d.put(UInt8(2)); d.put(seq); d.put(UInt8((needKey ? 1 : 0) | (repaired ? 2 : 0)))
    d.put(UInt8(tokens.count)); for t in tokens { d.put(t) }
    return d
}

public func nackDatagram(_ seq: UInt32, _ indices: [Int]) -> Data {
    var d = Data(); d.put(UInt8(3)); d.put(seq); d.put(UInt16(indices.count))
    for i in indices { d.put(UInt16(i)) }
    return d
}

/// Messages that are input: numbered and sent over UDP too, so a loss on TCP doesn't hold a keystroke for a round trip.
public let inputTypes: Set<String> = ["key", "text", "flags", "mouse", "scroll"]

/// Host side: input arrives once over TCP and up to three times over UDP, in any order. Each is applied once, in the
/// order it was made; one that's early waits for the ones before it, which TCP always brings.
public struct InputOrder {
    private var next: UInt32 = 1
    private var held: [UInt32: Msg] = [:]
    public init() {}

    /// The messages now ready to apply, in order. Unnumbered ones (an older viewer) go straight through.
    public mutating func take(_ m: Msg) -> [Msg] {
        guard let n = m.n else { return [m] }
        guard Int32(bitPattern: n &- next) >= 0, held[n] == nil else { return [] }   // a copy of one already in
        held[n] = m
        var out: [Msg] = []
        while let m = held.removeValue(forKey: next) { out.append(m); next &+= 1 }
        return out
    }
}

/// HITHER_DROP=0.05 drops that share of video datagrams at random (outgoing on the host, incoming on a viewer), to
/// test recovery without touching the system's network shaping.
public let dropRate = Double(ProcessInfo.processInfo.environment["HITHER_DROP"] ?? "") ?? 0

/// The viewer's end: one UDP flow to the host (or the launcher's loopback relay), whole frames out in order.
public final class VideoLink {
    let conn: NWConnection
    let queue = DispatchQueue(label: "video-link")
    var seal: Seal
    var assembler = Reassembler()
    var timer: DispatchSourceTimer?
    var lastAckAt = 0.0
    /// A packet ready to decode, on the link's queue.
    public var onFrame: (Data) -> Void = { _ in }
    public private(set) var frames = 0
    /// For logs and tests, read on any queue (approximate).
    public var counts: (lost: Int, repaired: Int, spurious: Int) { (assembler.lost, assembler.repairedCount, assembler.spurious) }

    public init(secret: Data, tag: UInt64, to host: NWEndpoint.Host, port: NWEndpoint.Port) {
        seal = Seal(secret: secret, tag: tag, host: false)
        let udp = NWProtocolUDP.Options()
        let p = NWParameters(dtls: nil, udp: udp)
        if host == "127.0.0.1" { p.requiredInterfaceType = .loopback }
        conn = NWConnection(host: host, port: port, using: p)
    }

    public func start() {
        conn.stateUpdateHandler = { s in if case .failed(let e) = s { log("video link failed: \(e)") } }
        conn.start(queue: queue)
        receive()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil; conn.cancel() }

    /// The host went back to TCP video: frames up to `seq` will never come.
    public func reset() { queue.async { self.assembler = Reassembler() } }

    private func receive() {
        conn.receiveMessage { [weak self] d, _, _, err in
            guard let self else { return }
            if let d, dropRate == 0 || Double.random(in: 0..<1) >= dropRate, let plain = seal.open(d) {
                let before = assembler.acked?.seq
                for p in assembler.receive(plain, at: ProcessInfo.processInfo.systemUptime) { frames += 1; onFrame(p) }
                if assembler.acked?.seq != before { ack() }
            }
            if err == nil { receive() }
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let (nacks, ready) = assembler.tick(at: now)
        for p in ready { frames += 1; onFrame(p) }
        for n in nacks { send(nackDatagram(n.seq, n.indices)) }
        if now - lastAckAt > 0.25 || (assembler.broken && now - lastAckAt > 0.1) { ack() }
    }

    private func ack() {
        lastAckAt = ProcessInfo.processInfo.systemUptime
        let a = assembler.acked
        send(ackDatagram(a?.seq ?? 0, needKey: assembler.broken, repaired: a?.repaired ?? false, tokens: assembler.shownTokens))
    }

    /// An input message (with its `n`) as three datagrams, the copies 10 and 30 ms apart so one burst of loss
    /// rarely takes all three. Anything too big for one goes by TCP alone.
    public func sendInput(_ m: Msg) {
        guard let json = try? JSONEncoder().encode(m), json.count < 1100 else { return }
        let d = Data([4]) + json
        queue.async { self.send(d) }
        queue.asyncAfter(deadline: .now() + 0.01) { self.send(d) }
        queue.asyncAfter(deadline: .now() + 0.03) { self.send(d) }
    }

    private func send(_ plain: Data) { conn.send(content: seal.seal(plain), completion: .idempotent) }
}
