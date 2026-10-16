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

/// Bonjour, pairing, and one control connection per paired Mac that lists its windows and apps. Each window
/// you open has its own connection (RemoteWindow). Everything here runs on the main queue.
final class Macs: ObservableObject {
    @Published var nearby: [NearbyMac] = []
    @Published var paired: [Peer] = Pairings.load().peers
    @Published var windows: [String: [Item]] = [:]   // by Mac (its peer ID)
    @Published var apps: [String: [Item]] = [:]
    @Published var state: [String: String] = [:]     // why a Mac has no list: "Connecting…", "Can't reach mini"
    @Published var prompt: CodePrompt?
    @Published var problem: String?      // pairing failed
    @Published var noLocalNetwork = false   // Local Network access is off: nothing nearby can be found
    var icons: [String: UIImage] = [:]   // by bundle; a list carries each app's icon once per connection

    private var browser: NWBrowser?
    private var pairing: PairSession?
    private var wires: [String: Wire] = [:]
    private var active = true

    /// Share This Mac is off there (as far as Bonjour says): it can't be reached, and here's why.
    func stopsSharing(_ mac: Peer) -> Bool { nearby.first { $0.id == mac.id }?.shares == false }

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
        guard pairing == nil else { return }
        let s = PairSession(NWConnection(to: n.endpoint, using: NWParameters(tls: nil, tcp: tcpOptions())), initiator: true, viewer: true)
        pairing = s
        s.confirm = { [weak self] code, name, answer in self?.prompt = CodePrompt(code: code, mac: name, answer: answer) }
        s.onDone = { [weak self, unowned s] p in
            guard let self else { return }
            pairing = nil
            prompt = nil
            guard let p else { problem = s.failure; return }   // no failure: cancelled here
            var all = Pairings.load()
            all.peers.removeAll { $0.id == p.id || $0.name == p.name }
            all.peers.append(p)
            all.save()
            paired = all.peers
            drop(p)   // a re-pair has a new key
            connect(p)
        }
        s.start()
    }

    func unpair(_ mac: Peer) {
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
        w.onMsg = { [weak self] m in
            guard let self else { return }
            switch m.t {
            case "windows": Reach.worked(host, for: mac); state[mac.id] = ""; windows[mac.id] = keepIcons(m.items ?? [])
            case "apps": apps[mac.id] = keepIcons(m.items ?? []).sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
            default: break
            }
        }
        w.onClose = { [weak self, weak w] in
            guard let self, let w, wires[mac.id] === w else { return }
            wires[mac.id] = nil
            let next = attempt + 1
            if next % hosts.count == 0 { state[mac.id] = "Can't reach \(mac.name)" }   // tried every name
            DispatchQueue.main.asyncAfter(deadline: .now() + (next % hosts.count == 0 ? 3 : 0.2)) { [weak self] in
                guard let self, let still = paired.first(where: { $0.id == mac.id }) else { return }
                connect(still, attempt: next)
            }
        }
        wires[mac.id] = w
        w.start()
        w.send(Msg("list"))
        Reach.giveUpLater(on: w)
    }

    /// Hang up on this Mac and forget what it showed.
    private func drop(_ mac: Peer) {
        let w = wires.removeValue(forKey: mac.id)
        w?.close()
        windows[mac.id] = nil
        apps[mac.id] = nil
        state[mac.id] = nil
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
