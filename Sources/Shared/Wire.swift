import Foundation
import Network
import Security

public let port: NWEndpoint.Port = 7420
public let relayPort: NWEndpoint.Port = 7421   // launcher's loopback relay on the client Mac

/// Every control/input message. One loose struct beats a dozen types for a wire this small.
public struct Msg: Codable {
    public var t: String
    public var app: String?, title: String?, icon: Data?
    public var w: Double?, h: Double?, x: Double?, y: Double?, dx: Double?, dy: Double?
    public var k: Int?, b: Int?, c: Int?, p: Int?, mp: Int?
    public var f: UInt64?, seq: UInt32?
    public var down: Bool?, rep: Bool?
    public var items: [Item]?
    public var path: [Int]?          // menu path: indices from the menu bar down
    public var menu: [MenuEntry]?
    public var caps: [String]?       // viewer → host on "open": decoders it has beyond H.264 (e.g. "hevc")
    public var codec: String?        // "h264" | "hevc" | "hevc422": host's current choice (in "windows"), or a new one ("codec")
    public init(_ t: String) { self.t = t }
}

/// One item of a remote menu. Empty title = separator. `mods` uses AX bits: 1 shift, 2 option, 4 control, 8 no-command.
public struct MenuEntry: Codable {
    public var title: String, enabled: Bool, checked: Bool, key: String, mods: Int, sub: Bool
    public init(title: String, enabled: Bool, checked: Bool, key: String, mods: Int, sub: Bool) {
        self.title = title; self.enabled = enabled; self.checked = checked; self.key = key; self.mods = mods; self.sub = sub
    }
}

/// One shareable window in a "windows" list. `icon` (PNG) is sent once per app per connection.
public struct Item: Codable {
    public var id: Int, app: String, bundle: String, title: String, icon: Data?
    public init(id: Int, app: String, bundle: String, title: String, icon: Data? = nil) {
        self.id = id; self.app = app; self.bundle = bundle; self.title = title; self.icon = icon
    }
}

public func log(_ s: String) { FileHandle.standardError.write(Data("[uc] \(s)\n".utf8)) }

/// Pre-shared key both Macs hold in ~/.unified-control/psk (deploy script creates + copies it).
public func loadKey() -> Data {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".unified-control/psk")
    guard let d = try? Data(contentsOf: url), d.count >= 32 else {
        log("missing \(url.path) — run scripts/deploy-host.sh"); exit(1)
    }
    return d
}

/// TLS-PSK over TCP: encrypted, and only holders of the key can connect (it injects input, so this matters).
public func tlsParams(key: Data) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let k = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let id = Data("uc".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, k as __DispatchData, id as __DispatchData)
    sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
        tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
    return NWParameters(tls: tls, tcp: tcpOptions())
}

public func tcpOptions() -> NWProtocolTCP.Options {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    // notice a dead peer (host restarted, Mac asleep, Wi-Fi gone) in seconds, not TCP's default minutes
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 2
    tcp.keepaliveInterval = 1
    tcp.keepaliveCount = 3
    tcp.connectionDropTime = 5
    return tcp
}

/// Framing: [kind u8][len u32][body]. kind 1 = JSON Msg, 2 = video packet, 3 = audio (48 kHz stereo Int16 PCM).
public final class Wire {
    public let conn: NWConnection
    public let queue: DispatchQueue
    public var onMsg: (Msg) -> Void = { _ in }
    public var onVideo: (Data) -> Void = { _ in }
    public var onAudio: (Data) -> Void = { _ in }
    public var onClose: () -> Void = {}
    private var closed = false

    public init(_ conn: NWConnection, queue: DispatchQueue) { self.conn = conn; self.queue = queue }

    public func start() {
        conn.stateUpdateHandler = { [weak self] s in
            switch s {
            case .waiting(let e): log("connection waiting: \(e)"); self?.close()   // callers run their own retry loops
            case .failed(let e): log("connection failed: \(e)"); self?.close()
            case .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: queue)
        read()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose()
    }

    private func read() {
        conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] h, _, eof, err in
            guard let self, let h, h.count == 5, err == nil else {
                log(err.map { "read error: \($0)" } ?? (eof ? "peer closed the connection" : "short read"))
                self?.close(); return
            }
            var r = Reader(h)
            let kind = r.u8(), len = Int(r.u32())
            self.conn.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, _, err in
                guard let body, body.count == len, err == nil else { self.close(); return }
                if kind == 1 {
                    if let m = try? JSONDecoder().decode(Msg.self, from: body) { self.onMsg(m) }
                } else if kind == 2 {
                    self.onVideo(body)
                } else if kind == 3 {
                    self.onAudio(body)
                }
                self.read()
            }
        }
    }

    public func send(_ m: Msg) { frame(1, try! JSONEncoder().encode(m)) }
    public func sendVideo(_ d: Data) { frame(2, d) }
    public func sendAudio(_ d: Data) { frame(3, d) }

    private func frame(_ kind: UInt8, _ body: Data) {
        var d = Data(capacity: body.count + 5)
        d.put(kind); d.put(UInt32(body.count)); d.append(body)
        conn.send(content: d, completion: .idempotent)
    }
}

public extension Data {
    mutating func put<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}

public struct Reader {
    let d: Data
    var i: Int
    public init(_ d: Data) { self.d = d; i = d.startIndex }
    mutating func int<T: FixedWidthInteger>(_: T.Type) -> T {
        var v = T.zero
        for _ in 0..<MemoryLayout<T>.size { v = v << 8 | T(d[i]); i += 1 }
        return v
    }
    public mutating func u8() -> UInt8 { int(UInt8.self) }
    public mutating func u16() -> UInt16 { int(UInt16.self) }
    public mutating func u32() -> UInt32 { int(UInt32.self) }
    public mutating func bytes(_ n: Int) -> Data { defer { i += n }; return d[i..<i + n] }
    public mutating func rest() -> Data { defer { i = d.endIndex }; return d[i...] }
}
