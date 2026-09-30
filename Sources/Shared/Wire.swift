import Foundation
import Network
import Security
import SystemConfiguration

public let port: NWEndpoint.Port = 7420
public let relayPort: NWEndpoint.Port = 7421   // launcher's loopback relay on the client Mac
public let pairPort: NWEndpoint.Port = 7422    // pairing, plain TCP; advertised over Bonjour
public let serviceType = "_hither._tcp"

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
    public var peer: String?, name: String?, key: Data?, nonce: Data?, commit: Data?   // pairing
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

public func log(_ s: String) { FileHandle.standardError.write(Data("[hither] \(s)\n".utf8)) }

/// ~/.hither: pairings and settings, readable by you only.
public let configDir: URL = {
    let d = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hither")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return d
}()

/// This Mac's short network name ("mini" for mini.local): Bonjour name, proxy suffix ("Cursor · mini"), and how the
/// other Mac reaches this one.
public func localName() -> String {
    SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
}

/// A Mac this one is paired with. Pairing is mutual: each can open the other's windows.
public struct Peer: Codable {
    public var id: String, name: String, token: Data
    public init(id: String, name: String, token: Data) { self.id = id; self.name = name; self.token = token }
}

/// This Mac's ID and its pairings, in ~/.hither/pairings.json.
public struct Pairings: Codable {
    public var id: String
    public var peers: [Peer]
    static let url = configDir.appending(path: "pairings.json")

    public static func load() -> Pairings {
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Pairings.self, from: d) { return p }
        let p = Pairings(id: UUID().uuidString, peers: [])
        p.save()
        return p
    }

    public func save() {
        try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }

    /// Client side of a connection to `host` ("mini.local" or "mini"): our ID with that pair's key.
    public func tls(to host: String) -> NWParameters {
        let peer = peers.first { $0.name == host || "\($0.name).local" == host }
        return tlsParams(psks: [(id, peer?.token ?? Data(count: 32))])   // unpaired: fails the handshake
    }
}

/// TLS-PSK over TCP: encrypted, and only paired Macs get in (it injects input, so this matters). The client offers
/// its ID with the pair's key; the server holds every paired Mac's key and picks by that ID.
public func tlsParams(psks: [(id: String, key: Data)]) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let dd = { (d: Data) in d.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData }
    for (id, key) in psks { sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dd(key), dd(Data(id.utf8))) }
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
    public var maxLen = Int.max   // cap it where the peer isn't authenticated yet (pairing)
    private let sendLock = NSLock()  // audio, encoder and control messages arrive from different queues
    private var closed = false
    private var closing = false

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
        sendLock.lock()
        guard !closed else { sendLock.unlock(); return }
        closed = true
        sendLock.unlock()
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
            guard len <= self.maxLen else { log("oversized message"); self.close(); return }
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

    /// Send the last control message and a TCP/TLS finish. Keep receiving until the peer closes,
    /// with a bounded fallback for peers that never acknowledge the end of the stream.
    public func sendAndClose(_ m: Msg) {
        let d = framed(1, try! JSONEncoder().encode(m))
        sendLock.lock()
        guard !closed, !closing else { sendLock.unlock(); return }
        closing = true
        conn.send(content: d, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [weak self] error in
            if let error {
                log("final send failed: \(error)")
                self?.queue.async { self?.close() }
            }
        })
        sendLock.unlock()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.close() }
    }

    private func frame(_ kind: UInt8, _ body: Data) {
        let d = framed(kind, body)
        sendLock.lock()
        guard !closed, !closing else { sendLock.unlock(); return }
        conn.send(content: d, completion: .idempotent)
        sendLock.unlock()
    }

    private func framed(_ kind: UInt8, _ body: Data) -> Data {
        var d = Data(capacity: body.count + 5)
        d.put(kind); d.put(UInt32(body.count)); d.append(body)
        return d
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
