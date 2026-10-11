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

/// Bonjour, pairing, and one control connection to the paired Mac that lists its windows and apps. Each window
/// you open has its own connection (RemoteWindow). Everything here runs on the main queue.
final class Macs: ObservableObject {
    @Published var nearby: [NearbyMac] = []
    @Published var paired: [Peer] = Pairings.load().peers
    @Published var windows: [Item] = []
    @Published var apps: [Item] = []
    @Published var state = ""            // why there's no list: "Connecting…", "Can't reach mini"
    @Published var prompt: CodePrompt?
    @Published var problem: String?      // pairing failed
    var icons: [String: UIImage] = [:]   // by bundle; a list carries each app's icon once per connection

    private var browser: NWBrowser?
    private var pairing: PairSession?
    private var wire: Wire?
    private var active = true

    /// The Mac this app shows: the first one paired.
    var mac: Peer? { paired.first }
    var host: String? { mac.map { "\($0.name).local" } }
    /// The paired Mac has Share This Mac off (as far as Bonjour says): it can't be reached, and here's why.
    var macStopsSharing: Bool { nearby.first { $0.id == mac?.id }?.shares == false }

    init() {
        browse()
        connect()
    }

    // MARK: pairing

    func browse() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            self?.nearby = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata,
                      let id = txt["id"], seen.insert(id).inserted else { return nil }
                return NearbyMac(id: id, name: name, endpoint: r.endpoint, shares: txt["shares"] != "0")
            }.sorted { $0.name < $1.name }
        }
        b.stateUpdateHandler = { s in
            switch s {
            case .failed(let e), .waiting(let e): log("browse: \(e)")   // NoAuth = Local Network access is off
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
            reconnect()
        }
        s.start()
    }

    func unpair() {
        guard let p = mac else { return }
        var all = Pairings.load()
        all.peers.removeAll { $0.id == p.id }
        all.save()
        paired = all.peers
        reconnect()
    }

    // MARK: the Mac's windows and apps

    /// Keeps trying while the app is in front: the Mac may be asleep, or Local Network access not granted yet.
    func connect() {
        guard active, wire == nil, let host else { return }
        if windows.isEmpty { state = "Connecting…" }
        let w = Wire(NWConnection(host: NWEndpoint.Host(host), port: port, using: Pairings.load().tls(to: host)), queue: .main)
        w.onMsg = { [weak self] m in
            guard let self else { return }
            switch m.t {
            case "windows": state = ""; windows = keepIcons(m.items ?? [])
            case "apps": apps = keepIcons(m.items ?? []).sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
            default: break
            }
        }
        w.onClose = { [weak self, weak w] in
            guard let self, let w, wire === w else { return }
            wire = nil
            state = "Can't reach \(mac?.name ?? "the Mac")"
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connect() }
        }
        wire = w
        w.start()
        w.send(Msg("list"))
    }

    func reconnect() {
        let w = wire
        wire = nil
        w?.close()
        windows = []
        apps = []
        connect()
    }

    func keepIcons(_ items: [Item]) -> [Item] {
        for i in items { if let d = i.icon, let img = UIImage(data: d) { icons[i.bundle] = img } }
        return items.map { var i = $0; i.icon = nil; return i }
    }

    func refresh() {
        connect()
        wire?.send(Msg("list"))
    }

    func loadApps() {
        connect()
        wire?.send(Msg("apps"))
    }

    /// Close it on the Mac (a save sheet can keep it open; it's then back in the next list).
    func close(_ w: Item) {
        var m = Msg("close"); m.k = w.id
        wire?.send(m)
        windows.removeAll { $0.id == w.id }
    }

    func suspend() {
        active = false
        let w = wire
        wire = nil
        w?.close()
    }

    func resume() {
        active = true
        refresh()
    }
}
