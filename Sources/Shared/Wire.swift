import Foundation
import Network
import Security
#if os(macOS)
import SystemConfiguration
#endif

public let port: NWEndpoint.Port = 7420
public let pairPort: NWEndpoint.Port = 7422    // pairing, plain TCP; advertised over Bonjour
public let serviceType = "_hither._tcp"
/// The "app" to open for a whole display rather than one window: its menu bar, Dock and every window on it.
public let desktopApp = "@desktop"

/// Every control/input message. One loose struct beats a dozen types for a wire this small.
public struct Msg: Codable {
    public var t: String
    public var app: String?, title: String?, icon: Data?
    public var w: Double?, h: Double?, x: Double?, y: Double?, dx: Double?, dy: Double?
    public var k: Int?, b: Int?, c: Int?, p: Int?, mp: Int?
    public var text: String?         // "text": typed characters (iPhone keyboard), not key codes
    public var f: UInt64?, seq: UInt32?
    public var down: Bool?, rep: Bool?
    public var items: [Item]?
    public var path: [Int]?          // menu path: indices from the menu bar down
    public var menu: [MenuEntry]?
    /// viewer → host on "open": what it can do beyond H.264 ("hevc", "hevc422", "audio"), and "restore" = put the window
    /// back to its own size when done (a phone borrows windows); in "pair1"/"pair2", "viewer" = a device that only views
    public var caps: [String]?
    public var codec: String?        // "h264" | "hevc" | "hevc422": host's current choice (in "windows"), or a new one ("codec")
    public var dark: Bool?           // Keep Screen Dark on the host: its setting (in "windows"), or a new one ("dark")
    public var scale: Double?        // a desktop's "resize": the viewer's screen is Retina (2) or not (1)
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

#if os(macOS)
/// ~/.hither: pairings and settings, readable by you only.
public let configDir: URL = {
    let d = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hither")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return d
}()

/// The launcher's loopback relay to the paired Mac `name`, which that Mac's proxies connect through, listens on a
/// port of its own, kept here.
public func relayPortFile(_ name: String) -> URL { configDir.appending(path: "relay-\(name).port") }

/// …and its loopback relay for video datagrams.
public func videoRelayPortFile(_ name: String) -> URL { configDir.appending(path: "relay-\(name).video.port") }

/// The relay port for `host` ("mini" or "mini.local"); nil while the launcher isn't running.
public func relayPort(for host: String) -> NWEndpoint.Port? { port(in: relayPortFile, for: host) }
public func videoRelayPort(for host: String) -> NWEndpoint.Port? { port(in: videoRelayPortFile, for: host) }

private func port(in file: (String) -> URL, for host: String) -> NWEndpoint.Port? {
    let name = host.split(separator: ".").first.map(String.init) ?? host
    return (try? String(contentsOf: file(name), encoding: .utf8)).flatMap { UInt16($0) }.flatMap(NWEndpoint.Port.init(rawValue:))
}

/// This Mac's short network name ("mini" for mini.local): Bonjour name, proxy suffix ("Cursor · mini"), and how the
/// other Mac reaches this one.
public func localName() -> String {
    SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName
}
#else
/// "iPhone" or "iPad": what the Mac calls this device when pairing. (The user's own device name needs an entitlement.)
public func localName() -> String {
    var u = utsname()
    uname(&u)
    let machine = withUnsafeBytes(of: u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine   // "iPhone17,1"
    return String(model.prefix { $0.isLetter })
}
#endif

/// A device this one is paired with. Pairing between Macs is mutual: each can open the other's windows.
/// A `viewer` (iPhone) only opens this Mac's windows; it shares none of its own.
/// `addr`: the IP it paired from, a way back when its name doesn't resolve here (a Mac in someone else's tailnet).
public struct Peer: Codable {
    public var id: String, name: String, token: Data
    public var viewer: Bool?
    public var addr: String?
    public init(id: String, name: String, token: Data, viewer: Bool? = nil, addr: String? = nil) {
        self.id = id; self.name = name; self.token = token; self.viewer = viewer; self.addr = addr
    }
}

/// This device's ID and its pairings: ~/.hither/pairings.json on a Mac, the Keychain on iPhone.
public struct Pairings: Codable {
    public var id: String
    public var peers: [Peer]

    public static func load() -> Pairings {
        if let d = read(), let p = try? JSONDecoder().decode(Pairings.self, from: d) { return p }
        let p = Pairings(id: UUID().uuidString, peers: [])
        p.save()
        return p
    }

    public func save() {
        try? Self.write(JSONEncoder().encode(self))
    }

    #if os(macOS)
    static let url = configDir.appending(path: "pairings.json")
    static func read() -> Data? { try? Data(contentsOf: url) }
    static func write(_ d: Data) throws {
        try d.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    #else
    static let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "dev.hither", kSecAttrAccount: "pairings"]
    static func read() -> Data? {
        var v: CFTypeRef?
        guard SecItemCopyMatching(item.merging([kSecReturnData: true]) { $1 } as CFDictionary, &v) == errSecSuccess else { return nil }
        return v as? Data
    }
    static func write(_ d: Data) throws {
        if SecItemUpdate(item as CFDictionary, [kSecValueData: d] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(item.merging([kSecValueData: d, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 } as CFDictionary, nil)
        }
    }
    #endif

    /// The paired device `host` names: "mini.local", "mini" or the address it paired from.
    public func peer(for host: String) -> Peer? {
        peers.first { $0.name == host || "\($0.name).local" == host || $0.addr == host }
    }

    /// Client side of a connection to `host`: our ID with that pair's key.
    public func tls(to host: String) -> NWParameters {
        tlsParams(psks: [(id, peer(for: host)?.token ?? Data(count: 32))])   // unpaired: fails the handshake
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

/// Framing: [kind u8][len u32][body]. kind 1 = JSON Msg, 2 = video packet, 3 = audio (48 kHz stereo Int16 PCM),
/// 4 = clipboard (Clip).
public final class Wire {
    public let conn: NWConnection
    public let queue: DispatchQueue
    public var onMsg: (Msg) -> Void = { _ in }
    public var onVideo: (Data) -> Void = { _ in }
    public var onAudio: (Data) -> Void = { _ in }
    public var onClip: (Data) -> Void = { _ in }
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
                } else if kind == 4 {
                    self.onClip(body)
                }
                self.read()
            }
        }
    }

    /// Keying material only the two ends of this TLS session know (RFC 5705 exporter): it seals the video datagrams.
    public func secret(_ label: String = "hither video") -> Data? {
        guard let m = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return label.withCString { sec_protocol_metadata_create_secret(m.securityProtocolMetadata, label.utf8.count, $0, 32) }
            .map { Data($0 as DispatchData) }
    }

    public func send(_ m: Msg) { frame(1, try! JSONEncoder().encode(m)) }
    public func sendVideo(_ d: Data) { frame(2, d) }
    public func sendAudio(_ d: Data) { frame(3, d) }
    public func sendClip(_ d: Data) { frame(4, d) }

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
    public mutating func u64() -> UInt64 { int(UInt64.self) }
    public mutating func bytes(_ n: Int) -> Data { defer { i += n }; return d[i..<i + n] }
    public mutating func rest() -> Data { defer { i = d.endIndex }; return d[i...] }
}
