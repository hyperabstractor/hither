import Foundation
import Network
import Shared

/// `hither --selftest`: this Mac pairs with itself over loopback, auto-confirming, and both sides must agree.
func pairSelfTest() -> Never {
    let l = try! NWListener(using: NWParameters(tls: nil, tcp: tcpOptions()), on: .any)
    var sessions: [PairSession] = [], codes: [String] = [], peers: [Peer] = []
    func run(_ s: PairSession) {
        sessions.append(s)
        s.confirm = { code, _, answer in codes.append(code); answer(true) }
        s.onDone = { p in
            guard let p else { print("FAIL: \(s.failure ?? "?")"); exit(1) }
            peers.append(p)
            guard peers.count == 2 else { return }
            precondition(codes.count == 2 && codes[0] == codes[1], "codes differ: \(codes)")
            precondition(peers[0].token == peers[1].token && peers[0].token.count == 32, "keys differ")
            precondition(peers.allSatisfy { $0.name == localName() })
            precondition(!validName("../x") && !validName("") && validName("mini"))
            print("ok: both sides show \(codes[0]) and hold the same key")
            exit(0)
        }
        s.start()
    }
    l.newConnectionHandler = { run(PairSession($0, initiator: false)) }
    l.stateUpdateHandler = { state in
        if case .ready = state {
            run(PairSession(NWConnection(host: "127.0.0.1", port: l.port!, using: NWParameters(tls: nil, tcp: tcpOptions())), initiator: true))
        }
    }
    l.start(queue: .main)
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { print("FAIL: timed out"); exit(1) }
    dispatchMain()
}
