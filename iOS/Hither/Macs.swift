import Foundation
import Network
import Shared
import UIKit

/// A Mac nearby running Hither, found over Bonjour. `shares`: Share This Mac is on, so there's something to show.
struct NearbyMac: Identifiable {
    let id: String, name: String, endpoint: NWEndpoint, shares: Bool
}

/// The pairing code on screen, waiting for Pair or Cancel.
struct CodePrompt: Identifiable {
    let id = UUID()
    let code: String, mac: String
    let answer: (Bool) -> Void
}

/// Files that just arrived from a Mac, ready to share or save elsewhere.
struct Received: Identifiable {
    let id = UUID()
    let text: String, urls: [URL]
}

/// Bonjour, pairing, and one control connection per paired Mac that lists its windows and apps, carries its settings
/// (Keep Screen Dark, Lock, Video Codec) and the clipboard, and says when new windows open there. Each window you
/// open has its own connection (a session: RemoteWindow, kept by Sessions), and each file copy (FileCopy). Everything
/// here runs on the main queue.
final class Macs: ObservableObject {
    @Published var nearby: [NearbyMac] = []
    @Published var paired: [Peer] = Pairings.load().peers
    @Published var windows: [String: [Item]] = [:]   // by Mac (its peer ID)
    @Published var apps: [String: [Item]] = [:]
    @Published var state: [String: String] = [:]     // why a Mac has no list: "Connecting…", "Can't reach mini"
    @Published var dark: [String: Bool] = [:]        // Keep Screen Dark is on there (from its "windows" replies)
    @Published var codec: [String: String] = [:]     // its video codec: "h264", "hevc", "hevc422"
    @Published var prompt: CodePrompt?
    @Published var problem: String?      // pairing failed
    @Published var noLocalNetwork = false   // Local Network access is off: nothing nearby can be found
    @Published var notice: String?       // a passing status: "Sent text (12 bytes) to mini"
    @Published var copies: [FileCopy] = []
    @Published var received: Received?
    var icons: [String: UIImage] = [:]   // by bundle; a list carries each app's icon once per connection
    /// The sessions open: new windows on a Mac may be shown by one, a codec change reconnects them, and unpairing a
    /// Mac closes its own.
    weak var sessions: Sessions?

    private var browser: NWBrowser?
    private var pairing: PairSession?
    private var wires: [String: Wire] = [:]
    private var reached: [String: String] = [:]      // the name each control connection dialed: file copies go there too
    private var listWaiters: [String: [([Item]) -> Void]] = [:]
    private var active = true

    /// Share This Mac is off there (as far as Bonjour says): it can't be reached, and here's why.
    func stopsSharing(_ mac: Peer) -> Bool { nearby.first { $0.id == mac.id }?.shares == false }

    func connected(_ mac: Peer) -> Bool { wires[mac.id]?.conn.state == .ready }

    init() {
        browse()
        paired.forEach { connect($0) }
    }

    // MARK: pairing

    /// Looks again from scratch each time the app comes forward: a browser that failed (no network for a while)
    /// stays failed.
    func browse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            self?.nearby = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata,
                      let id = txt["id"], seen.insert(id).inserted else { return nil }
                return NearbyMac(id: id, name: name, endpoint: r.endpoint, shares: txt["shares"] != "0")
            }.sorted { $0.name < $1.name }
        }
        b.stateUpdateHandler = { [weak self, weak b] s in
            switch s {
            case .ready: self?.noLocalNetwork = false
            case .waiting(let e):
                log("browse: \(e)")
                if case .dns(let code) = e, [kDNSServiceErr_PolicyDenied, kDNSServiceErr_NoAuth].contains(Int(code)) { self?.noLocalNetwork = true }
            case .failed(let e):
                log("browse: \(e)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if let self, self.browser === b { self.browse() } }
            default: break
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func pair(with n: NearbyMac) {
        begin(NWConnection(to: n.endpoint, using: NWParameters(tls: nil, tcp: tcpOptions())), address: nil)
    }

    /// A Mac Bonjour can't see (another network, over Tailscale): pair by its name or IP. Hither must be running there,
    /// and someone has to click Pair on its screen too. The address it answered on is kept as a way back to it.
    func pair(address: String) {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        flash("Connecting to \(host)…")
        begin(NWConnection(host: NWEndpoint.Host(host), port: pairPort, using: NWParameters(tls: nil, tcp: tcpOptions())), address: host)
    }

    private func begin(_ c: NWConnection, address: String?) {
        guard pairing == nil else { return }
        let s = PairSession(c, initiator: true, viewer: true)
        pairing = s
        s.confirm = { [weak self] code, name, answer in self?.prompt = CodePrompt(code: code, mac: name, answer: answer) }
        s.onDone = { [weak self, unowned s] p in
            guard let self else { return }
            pairing = nil
            prompt = nil
            guard let p else {   // no failure: cancelled here
                if let address, !s.reachedPeer {
                    problem = "Couldn't reach Hither on \(address). Check that it's running there and that the Mac's firewall lets Hither in."
                } else {
                    problem = s.failure
                }
                return
            }
            // a re-pair replaces the Mac's old entry: the same ID with a new key, or a Mac of the same name set up again
            // (a new ID). Its sessions close first, while the old pairing still stands for them to let go of what they
            // hold (each keeps the Mac as it was paired: its key, name and addresses); then hang up on the old entries
            // before connecting with the new one, whose reconnect timers then find them gone.
            var all = Pairings.load()
            let replaced = all.peers.filter { $0.id == p.id || $0.name == p.name }
            replaced.forEach { self.sessions?.closeAll(of: $0) }
            all.peers.removeAll { $0.id == p.id || $0.name == p.name }
            all.peers.append(p)
            all.save()
            paired = all.peers
            replaced.forEach(drop)
            drop(p)
            connect(p)
        }
        s.start()
    }

    func unpair(_ mac: Peer) {
        sessions?.closeAll(of: mac)   // first, while they can still let go of what they hold there
        var all = Pairings.load()
        all.peers.removeAll { $0.id == mac.id }
        all.save()
        paired = all.peers
        drop(mac)
    }

    // MARK: the Macs' windows and apps

    /// Keeps trying while the app is in front, alternating between the Mac's names: it may be asleep, out of reach
    /// without Tailscale, or Local Network access not granted yet.
    func connect(_ mac: Peer, attempt: Int = 0) {
        guard active, wires[mac.id] == nil else { return }
        let hosts = Reach.hosts(mac), host = hosts[attempt % hosts.count]
        if windows[mac.id, default: []].isEmpty { state[mac.id] = "Connecting…" }
        let w = Wire(NWConnection(host: NWEndpoint.Host(host), port: port, using: Pairings.load().tls(to: host)), queue: .main)
        // everything here runs on the main queue, but a message already read can still arrive after this connection
        // was replaced (suspended, unpaired, re-paired): only the current one speaks for the Mac
        w.onMsg = { [weak self, weak w] m in
            guard let self, let w, wires[mac.id] === w else { return }
            switch m.t {
            case "windows":
                Reach.worked(host, for: mac)
                reached[mac.id] = host
                state[mac.id] = ""
                let items = keepIcons(m.items ?? [])
                windows[mac.id] = items
                dark[mac.id] = m.dark ?? false
                let c = m.codec ?? "h264"
                if codec[mac.id] != c {
                    codec[mac.id] = c
                    sessions?.codecChanged(c, on: mac)
                }
                listWaiters.removeValue(forKey: mac.id)?.forEach { $0(items) }
            case "apps": apps[mac.id] = keepIcons(m.items ?? []).sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
            case "appeared":
                let items = keepIcons(m.items ?? [])
                wires[mac.id]?.send(Msg("list"))
                sessions?.appeared(items, on: mac)
            case "clipset": flash("Sent \(m.text ?? "the clipboard") to \(mac.name)")
            case "cliperr": flash(m.text ?? "Couldn't get \(mac.name)'s clipboard")
            default: break
            }
        }
        w.onClip = { [weak self, weak w] d in
            guard let self, let w, wires[mac.id] === w else { return }
            receivedClipboard(d, from: mac)
        }
        w.onClose = { [weak self, weak w] in
            guard let self, let w, wires[mac.id] === w else { return }
            wires[mac.id] = nil
            listWaiters.removeValue(forKey: mac.id)?.forEach { $0(self.windows[mac.id] ?? []) }
            let next = attempt + 1
            if next % hosts.count == 0 { state[mac.id] = "Can't reach \(mac.name)" }   // tried every name
            DispatchQueue.main.asyncAfter(deadline: .now() + (next % hosts.count == 0 ? 3 : 0.2)) { [weak self] in
                // unpaired or replaced meanwhile: let it go (a re-pair with the same ID connects by itself)
                guard let self, let still = paired.first(where: { $0.id == mac.id }), still.token == mac.token else { return }
                connect(still, attempt: next)
            }
        }
        wires[mac.id] = w
        w.start()
        w.send(Msg("list"))
        w.send(Msg("watch"))   // new windows there: a session on screen may follow them
        Reach.giveUpLater(on: w)
    }

    /// Hang up on this Mac and forget what it showed.
    private func drop(_ mac: Peer) {
        let w = wires.removeValue(forKey: mac.id)
        w?.close()
        windows[mac.id] = nil
        apps[mac.id] = nil
        state[mac.id] = nil
        dark[mac.id] = nil
        codec[mac.id] = nil
        reached[mac.id] = nil
        listWaiters.removeValue(forKey: mac.id)?.forEach { $0([]) }
    }

    func keepIcons(_ items: [Item]) -> [Item] {
        for i in items { if let d = i.icon, let img = UIImage(data: d) { icons[i.bundle] = img } }
        return items.map { var i = $0; i.icon = nil; return i }
    }

    func refresh() {
        for mac in paired {
            connect(mac)
            wires[mac.id]?.send(Msg("list"))
        }
    }

    /// A fresh list of the Mac's windows (what's known already, if it doesn't answer within a second).
    func list(_ mac: Peer, _ done: @escaping ([Item]) -> Void) {
        connect(mac)
        guard let w = wires[mac.id] else { return done(windows[mac.id] ?? []) }
        var once = false
        let finish = { [weak self] (items: [Item]) in
            guard !once else { return }
            once = true
            done(items.isEmpty ? self?.windows[mac.id] ?? [] : items)
        }
        listWaiters[mac.id, default: []].append(finish)
        w.send(Msg("list"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in finish(self?.windows[mac.id] ?? []) }
    }

    func loadApps(_ mac: Peer) {
        connect(mac)
        wires[mac.id]?.send(Msg("apps"))
    }

    /// Close it on the Mac (a save sheet can keep it open; it's then back in the next list).
    func close(_ w: Item, on mac: Peer) {
        var m = Msg("close"); m.k = w.id
        wires[mac.id]?.send(m)
        windows[mac.id]?.removeAll { $0.id == w.id }
    }

    // MARK: Recent

    /// Apps opened from here on `mac`, newest first.
    func recent(on mac: Peer) -> [Item] {
        (UserDefaults.standard.array(forKey: "recent.\(mac.id)") as? [[String: String]] ?? []).compactMap { d in
            d["bundle"].map { Item(id: 0, app: d["app"] ?? $0, bundle: $0, title: "") }
        }
    }

    func remember(_ item: Item, on mac: Peer) {
        guard item.bundle != desktopApp else { return }
        let others = recent(on: mac).filter { $0.bundle != item.bundle }.prefix(9).map { ["bundle": $0.bundle, "app": $0.app] }
        UserDefaults.standard.set([["bundle": item.bundle, "app": item.app]] + others, forKey: "recent.\(mac.id)")
        objectWillChange.send()
    }

    // MARK: settings of each Mac

    /// Keep Screen Dark: while anything there is streamed, its own monitors show black, and two minutes after the last
    /// stream closes it locks. The host answers with its new state.
    func setDark(_ on: Bool, on mac: Peer) {
        guard let w = wires[mac.id] else { return flash("Not connected to \(mac.name)") }
        dark[mac.id] = on
        var m = Msg("dark"); m.dark = on
        w.send(m)
    }

    func lock(_ mac: Peer) {
        guard let w = wires[mac.id] else { return flash("Not connected to \(mac.name)") }
        w.send(Msg("lock"))
        flash("Locked \(mac.name)")
    }

    /// For every window that Mac sends, to here and to other Macs alike.
    func setCodec(_ c: String, on mac: Peer) {
        guard let w = wires[mac.id] else { return flash("Not connected to \(mac.name)") }
        var m = Msg("codec"); m.codec = c
        w.send(m)
    }

    // MARK: clipboard and files, only when asked

    /// This device's clipboard onto the Mac's.
    func sendClipboard(to mac: Peer) {
        guard let w = wires[mac.id] else { return flash("Not connected to \(mac.name)") }
        let c = Clip.read()
        guard !c.parts.isEmpty else { return flash("Your clipboard is empty (or holds nothing a Mac can paste)") }
        w.sendClip(c.encoded())
    }

    /// The Mac's clipboard onto this device's. Files copied in Finder come by a FileCopy instead.
    func getClipboard(from mac: Peer) {
        guard let w = wires[mac.id] else { return flash("Not connected to \(mac.name)") }
        flash("Getting \(mac.name)'s clipboard…")
        w.send(Msg("clipget"))
    }

    private func receivedClipboard(_ d: Data, from mac: Peer) {
        guard let c = Clip(decoding: d) else { return flash("Couldn't read \(mac.name)'s clipboard") }
        if c.files { return start(FileCopy(mac: mac, host: host(of: mac), outgoing: false)) { $0.get(into: Self.inbox) } }
        guard !c.parts.isEmpty else { return flash("\(mac.name)'s clipboard is empty") }
        c.write()
        flash("Got \(c.summary) from \(mac.name)")
    }

    /// Files picked here, into the Mac's Downloads and onto its clipboard. `cleanup`: copies made for the picking,
    /// removed once the copy ends.
    func sendFiles(_ urls: [URL], to mac: Peer, cleanup: [URL] = []) {
        guard !urls.isEmpty else { return }
        start(FileCopy(mac: mac, host: host(of: mac), outgoing: true)) { $0.send(urls, cleanup: cleanup) }
    }

    /// Where files from a Mac go: this app's Documents, which the Files app shows under On My iPad (iPhone) › Hither.
    static var inbox: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    private func host(of mac: Peer) -> String { reached[mac.id] ?? Reach.hosts(mac)[0] }

    private func start(_ c: FileCopy, _ go: (FileCopy) -> Void) {
        c.onEnd = { [weak self] c in
            guard let self else { return }
            copies.removeAll { $0 === c }
            guard let r = c.result else { return }
            if r.ok, !c.landed.isEmpty { received = Received(text: r.text, urls: c.landed) } else { flash(r.text) }
        }
        copies.append(c)
        go(c)
    }

    /// Show `s` for a few seconds.
    func flash(_ s: String) {
        log(s)
        notice = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in if self?.notice == s { self?.notice = nil } }
    }

    // MARK: in the background

    func suspend() {
        active = false
        let all = wires
        wires = [:]
        all.values.forEach { $0.close() }
    }

    func resume() {
        active = true
        browse()
        refresh()
    }
}
