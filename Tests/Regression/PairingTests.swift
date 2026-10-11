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
