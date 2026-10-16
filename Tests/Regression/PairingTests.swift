import Foundation
import Network
import Shared

/// An iPhone pairs as a viewer: the Mac stores it with `viewer` set (so it never shows up as the Mac to browse),
/// the iPhone stores the Mac as an ordinary peer, and both hold the same key and saw the same code.
func testViewerPairing() throws {
    let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcpOptions()), on: .any)
    var sessions: [PairSession] = [], codes: [String] = [], mac: Peer?, phone: Peer?, failure: String?
    func run(_ s: PairSession) {
        sessions.append(s)
        s.confirm = { code, _, answer in codes.append(code); answer(true) }
        s.onDone = { p in
            guard let p else { failure = s.failure ?? "?"; return }
            if s.initiator { phone = p } else { mac = p }
        }
        s.start()
    }
    listener.newConnectionHandler = { run(PairSession($0, initiator: false)) }
    listener.stateUpdateHandler = { state in
        guard case .ready = state else { return }
        let c = NWConnection(host: "127.0.0.1", port: listener.port!, using: NWParameters(tls: nil, tcp: tcpOptions()))
        run(PairSession(c, initiator: true, viewer: true))
    }
    listener.start(queue: .main)
    defer { listener.cancel() }

    let deadline = Date() + 5   // PairSession runs on the main queue: keep it turning while we wait
    while (mac == nil || phone == nil) && failure == nil && Date() < deadline { RunLoop.main.run(until: Date() + 0.05) }
    if let failure { throw RegressionFailure(message: "viewer pairing failed: \(failure)") }
    guard let mac, let phone else { throw RegressionFailure(message: "viewer pairing timed out") }
    try expectEqual(codes.count, 2)
    try expectEqual(codes[0], codes[1])
    try expectEqual(mac.token, phone.token)
    try expectEqual(mac.viewer, true)   // the Mac's record of the iPhone
    try expectNil(phone.viewer)         // the iPhone's record of the Mac
    try expectTrue(sessions.first { !$0.initiator }?.theyView == true)
}

/// A Mac is tried by its Bonjour name, its Tailscale name, then the address it paired from; the one that answered
/// last goes first. Pairings saved before `addr` existed still load, and a connection to the address gets the pair's key.
func testReach() throws {
    let old = #"{"id":"me","peers":[{"id":"P","name":"mini","token":"AAAA"}]}"#
    let loaded = try JSONDecoder().decode(Pairings.self, from: Data(old.utf8))
    try expectNil(loaded.peers[0].addr)
    try expectEqual(Reach.hosts(loaded.peers[0]).count, 2)

    let id = "reach-test-\(UUID().uuidString)"
    let json = #"{"id":"me","peers":[{"id":"\#(id)","name":"mini-pb","token":"AAAA","addr":"100.103.209.65"}]}"#
    let pairings = try JSONDecoder().decode(Pairings.self, from: Data(json.utf8))
    let mac = pairings.peers[0]
    defer { UserDefaults.standard.removeObject(forKey: "reach.\(id)") }
    try expectEqual(Reach.hosts(mac), ["mini-pb.local", "mini-pb", "100.103.209.65"])
    Reach.worked("100.103.209.65", for: mac)
    try expectEqual(Reach.hosts(mac), ["100.103.209.65", "mini-pb.local", "mini-pb"])
    for host in Reach.hosts(mac) { try expectEqual(pairings.peer(for: host)?.id, id) }
    try expectNil(pairings.peer(for: "mini"))
}
