import Foundation
import Network
import Shared
import UIKit

/// One iPhone or iPad as the keyboard of another: you look at a Mac's window on the iPad and type on the iPhone, its
/// keyboard taking the whole of its screen (KeyboardScreen). The two talk to each other, on the Wi-Fi they share or
/// the iPhone's Personal Hotspot; what's typed goes into the session the iPad shows, as if typed on the iPad, and so
/// to whichever Mac and window that is. The Macs know nothing of it.
///
/// The keyboard listens while its Keyboard screen is up, and says so over Bonjour: `keysPairService` to pair (once,
/// by comparing a code, as with a Mac), `keysService` for the device paired with it to connect to, over TLS with the
/// pair's key. The other device, the screen, looks for its paired keyboards whenever Hither is in front and connects
/// by itself. On a Personal Hotspot, where Bonjour may not cross, the screen also tries its router, which there is
/// the iPhone.
///
///   keyboard → screen   "text" {text}, "key" {k, f} (a Mac key pressed and let go, with these modifiers),
///                       "kblatch" {f} (modifiers latched there: they join the screen's next click)
///   screen → keyboard   "kbinfo" {title} (what it types into), "kbreset" (the Mac's cursor moved: what was typed
///                       can't be revised from there any more), "kbused" (a click took the latched modifiers)
///   both, first         "kbhello" {peer}
///
/// Everything here runs on the main queue.
final class KeyLink: ObservableObject {
    static let keysService = "_hither-kb._tcp", keysPairService = "_hither-kbpair._tcp"
    static let keysPort: NWEndpoint.Port = 7424

    /// A keyboard showing nearby, not paired with yet.
    struct Nearby: Identifiable {
        let id: String, name: String, endpoint: NWEndpoint
    }

    /// The iPhones and iPads paired with, either way round.
    @Published private(set) var paired: [Peer] = Pairings.load().keyboards
    @Published var prompt: CodePrompt?
    @Published var problem: String?

    // as the screen
    @Published private(set) var nearby: [Nearby] = []
    @Published private(set) var keyboard: Peer?    // the keyboard typing here now
    private(set) var latched: UInt64 = 0           // modifiers latched on it, for the next click here
    /// What's typed there ("text", "key"): for the session in use.
    var onInput: (Msg) -> Void = { _ in }
    /// What the session in use shows, for the keyboard to say what it types into ("" = nothing open).
    var target: () -> String = { "" }

    // as the keyboard
    @Published private(set) var serving = false
    @Published private(set) var screen: Peer?      // the device it types into now
    @Published private(set) var typingInto = ""    // …and what that shows
    /// "kbreset", "kbused": for the Keyboard screen.
    var onScreen: (Msg) -> Void = { _ in }

    private let myID = Pairings.load().id
    private var wire: Wire?                        // the one link, whichever end this is
    private var pairing: PairSession?
    private var active = true
    private var observers: [NSObjectProtocol] = []

    // as the screen
    private var browsers: [NWBrowser] = []
    private var found: [String: NWEndpoint] = [:]   // keyboards serving now, by ID
    private var dialing: Wire?
    private var retry: Timer?
    private var sentTarget: String?
    private let path = NWPathMonitor()

    // as the keyboard
    private var listener: NWListener?, pairListener: NWListener?

    init() {
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.active = false
                self?.restart()
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.active = true
                self?.restart()
            },
        ]
        path.start(queue: .main)
        restart()
    }

    /// Be the keyboard (the Keyboard screen is up), or go back to looking for one.
    func serve(_ on: Bool) {
        guard serving != on else { return }
        serving = on
        restart()
    }

    /// One role at a time, and neither in the background (iOS would stop both anyway).
    private func restart() {
        hangUp()
        stopLooking()
        stopListening()
        guard active else { return }
        if serving { listen() } else { look() }
    }

    private func hangUp() {
        let w = wire, d = dialing
        wire = nil; dialing = nil
        w?.close(); d?.close()
        keyboard = nil; screen = nil
        latched = 0; typingInto = ""; sentTarget = nil
    }

    // MARK: pairing (either end)

    private func pair(_ s: PairSession) {
        pairing = s
        s.confirm = { [weak self] code, name, answer in
            self?.prompt = CodePrompt(code: code, mac: name, keyboard: true, answer: answer)
        }
        s.onDone = { [weak self, unowned s] p in
            guard let self else { return }
            pairing = nil
            prompt = nil
            guard var p else { problem = s.failure; return }
            p.keys = true
            var all = Pairings.load()
            all.peers.removeAll { $0.keys == true && ($0.id == p.id || $0.name == p.name) }   // paired again: the new key
            all.peers.append(p)
            all.save()
            paired = all.keyboards
            restart()   // the keyboard listens with the new key; the screen connects
        }
        s.start()
    }

    func unpair(_ p: Peer) {
        var all = Pairings.load()
        all.peers.removeAll { $0.keys == true && $0.id == p.id }
        all.save()
        paired = all.keyboards
        restart()
    }

    // MARK: the screen: find the paired keyboard, take what it types

    /// Pair with a keyboard showing nearby: both then show a code to compare.
    func pair(with n: Nearby) {
        guard pairing == nil else { return }
        pair(PairSession(NWConnection(to: n.endpoint, using: NWParameters(tls: nil, tcp: tcpOptions())), initiator: true))
    }

    private func look() {
        let browse = { [weak self] (type: String, found: @escaping ([Nearby]) -> Void) in
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: NWParameters())
            b.browseResultsChangedHandler = { results, _ in
                var seen = Set<String>()
                found(results.compactMap { r in
                    guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata,
                          let id = txt["id"], id != self?.myID, seen.insert(id).inserted else { return nil }
                    return Nearby(id: id, name: name, endpoint: r.endpoint)
                })
            }
            b.start(queue: .main)
            self?.browsers.append(b)
        }
        browse(Self.keysPairService) { [weak self] all in
            guard let self else { return }
            nearby = all.filter { n in !self.paired.contains { $0.id == n.id } }.sorted { $0.name < $1.name }
        }
        browse(Self.keysService) { [weak self] all in
            guard let self else { return }
            found = Dictionary(all.map { ($0.id, $0.endpoint) }) { a, _ in a }
            connect()
        }
        retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if keyboard == nil { connect() } else { tellTarget() }
        }
    }

    private func stopLooking() {
        browsers.forEach { $0.cancel() }
        browsers = []
        found = [:]
        nearby = []
        retry?.invalidate(); retry = nil
    }

    /// To a paired keyboard that's serving: one Bonjour shows, or on a Personal Hotspot (an expensive network whose
    /// router is the iPhone) the router itself.
    private func connect() {
        guard !serving, active, wire == nil, dialing == nil else { return }
        for p in paired {
            if let e = found[p.id] { return dial(NWConnection(to: e, using: tls(p)), p) }
        }
        let now = path.currentPath
        guard now.isExpensive, now.usesInterfaceType(.wifi) || now.usesInterfaceType(.wiredEthernet), let p = paired.first else { return }
        for case .hostPort(let host, _) in now.gateways {
            return dial(NWConnection(host: host, port: Self.keysPort, using: tls(p)), p)
        }
    }

    private func tls(_ p: Peer) -> NWParameters { tlsParams(psks: [(myID, p.token)]) }

    private func dial(_ c: NWConnection, _ p: Peer) {
        let w = Wire(c, queue: .main)
        w.maxLen = 64 << 10
        w.onMsg = { [weak self, weak w] m in
            guard let self, let w else { return }
            if dialing === w, m.t == "kbhello", m.peer == p.id {   // it's the keyboard, and it has our key
                dialing = nil
                wire = w
                keyboard = p
                var hello = Msg("kbhello"); hello.peer = myID
                w.send(hello)
                tellTarget()
                return
            }
            guard wire === w else { return }
            if m.t == "kblatch" { latched = m.f ?? 0 } else { onInput(m) }
            tellTarget()   // typed into something else than it was told: say so
        }
        w.onClose = { [weak self, weak w] in
            guard let self, let w else { return }
            if dialing === w { dialing = nil }
            guard wire === w else { return }
            wire = nil
            keyboard = nil
            latched = 0
            sentTarget = nil
        }
        dialing = w
        w.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak w] in   // nothing there: try again later
            if let self, let w, dialing === w { w.close() }
        }
    }

    /// To the keyboard, as the screen ("kbreset", "kbused").
    func tell(_ m: Msg) {
        guard keyboard != nil else { return }
        wire?.send(m)
    }

    /// What the keyboard types into, whenever it changes.
    private func tellTarget() {
        guard keyboard != nil, let w = wire else { return }
        let t = target()
        guard t != sentTarget else { return }
        sentTarget = t
        var m = Msg("kbinfo"); m.title = t
        w.send(m)
    }

    // MARK: the keyboard: listen, send what's typed

    private func listen() {
        // paired devices, over TLS with the pair's key; a fixed port, so a hotspot's guest finds it at its router
        if paired.isEmpty {
            // nobody to let in yet
        } else if let l = try? NWListener(using: tlsParams(psks: paired.map { ($0.id, $0.token) }), on: Self.keysPort) {
            l.service = service(Self.keysService)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { if case .failed(let e) = $0 { log("keyboard listener: \(e)") } }
            l.start(queue: .main)
            listener = l
        } else {
            log("keyboard: couldn't listen on \(Self.keysPort)")
        }
        // anyone nearby, to pair: nothing is typed anywhere until the codes were compared on both
        if let l = try? NWListener(using: NWParameters(tls: nil, tcp: tcpOptions())) {
            l.service = service(Self.keysPairService)
            l.newConnectionHandler = { [weak self] c in
                guard let self, pairing == nil else { return c.cancel() }
                pair(PairSession(c, initiator: false))
            }
            l.start(queue: .main)
            pairListener = l
        }
    }

    private func service(_ type: String) -> NWListener.Service {
        NWListener.Service(name: localName(), type: type, txtRecord: NWTXTRecord(["id": myID]))
    }

    private func stopListening() {
        listener?.cancel(); listener = nil
        pairListener?.cancel(); pairListener = nil
    }

    /// The screen connected (it has a paired key, or TLS wouldn't have let it this far): the newest one counts.
    private func accept(_ c: NWConnection) {
        let w = Wire(c, queue: .main)
        w.maxLen = 64 << 10
        w.onMsg = { [weak self, weak w] m in
            guard let self, let w, wire === w else { return }
            switch m.t {
            case "kbhello": screen = paired.first { $0.id == m.peer }
            case "kbinfo": typingInto = m.title ?? ""
            default: onScreen(m)
            }
        }
        w.onClose = { [weak self, weak w] in
            guard let self, let w, wire === w else { return }
            wire = nil
            screen = nil
            typingInto = ""
        }
        let old = wire
        wire = w
        screen = nil
        old?.close()
        w.start()
        var hello = Msg("kbhello"); hello.peer = myID
        w.send(hello)
    }

    /// To the screen, as the keyboard ("text", "key", "kblatch").
    func send(_ m: Msg) {
        guard screen != nil else { return }
        wire?.send(m)
    }
}
