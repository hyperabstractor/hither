import CryptoKit
import Foundation
import Network
import Shared

/// Pairs two Macs the way Bluetooth does: an X25519 key exchange, then both Macs show the same 6-digit code derived
/// from it, and you click Pair on both once you've checked they match. Each side commits to its random nonce before
/// seeing the other's, so a machine in the middle can't steer the two codes to match (one-in-a-million per try).
/// The resulting key never crosses the network; it becomes the TLS key for every later connection, both directions.
///
///   initiator → pair1  {peer, name, key}
///   responder → pair2  {peer, name, key, commit = H(keyR ‖ keyI ‖ nonceR)}
///   initiator → pair3  {nonce}
///   responder → pair4  {nonce}            both show H(keyI ‖ keyR ‖ nonceI ‖ nonceR) as 6 digits
///   each side → pairok | pairno           each stores the other once both sides clicked Pair
///
/// Everything runs on the main queue.
final class PairSession {
    let wire: Wire
    let initiator: Bool
    /// Show the code and report the user's answer.
    var confirm: (_ code: String, _ theirName: String, _ answer: @escaping (Bool) -> Void) -> Void = { _, _, a in a(false) }
    /// The paired Mac, or nil. `failure` says why, unless the user here cancelled.
    var onDone: (Peer?) -> Void = { _ in }
    private(set) var failure: String?

    private let myID = Pairings.load().id
    private let secret = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    private var pub: Data { secret.publicKey.rawRepresentation }
    private var them = Peer(id: "", name: "", token: Data())
    private var theirKey = Data(), theirCommit = Data(), theirNonce = Data()
    private var step = 0, mine = false, theirs = false, over = false

    init(_ conn: NWConnection, initiator: Bool) {
        wire = Wire(conn, queue: .main)
        wire.maxLen = 64 << 10   // nobody is authenticated yet
        self.initiator = initiator
        wire.onMsg = { self.handle($0) }   // cycle on purpose, broken in finish()
        wire.onClose = { self.finish(nil, "The connection closed.") }
    }

    func start() {
        wire.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { self.finish(nil, "Pairing timed out.") }
        if initiator { send("pair1") { $0.peer = self.myID; $0.name = localName(); $0.key = self.pub } }
    }

    private func handle(_ m: Msg) {
        switch (m.t, initiator, step) {
        case ("pair1", false, 0), ("pair2", true, 0):
            guard let id = m.peer, !id.isEmpty, let name = m.name, validName(name), let key = m.key, key.count == 32 else {
                return finish(nil, "The other Mac sent something unexpected.")
            }
            them.id = id; them.name = name; theirKey = key; theirCommit = m.commit ?? Data()
            step = 1
            if initiator {
                send("pair3") { $0.nonce = self.nonce }
            } else {
                send("pair2") {
                    $0.peer = self.myID; $0.name = localName(); $0.key = self.pub
                    $0.commit = hash(self.pub, self.theirKey, self.nonce)
                }
            }
        case ("pair3", false, 1), ("pair4", true, 1):
            guard let n = m.nonce, n.count == 32 else { return finish(nil, "The other Mac sent something unexpected.") }
            theirNonce = n
            if initiator {
                guard hash(theirKey, pub, theirNonce) == theirCommit else { return finish(nil, "Pairing failed. Try again.") }
            } else {
                send("pair4") { $0.nonce = self.nonce }
            }
            ask()
        case ("pairok", _, 2):
            theirs = true
            if mine { finish(them, nil) }
        case ("pairno", _, _):
            finish(nil, "\(them.name) didn't pair.")
        default:
            finish(nil, "The other Mac sent something unexpected.")
        }
    }

    private func ask() {
        let (kI, kR, nI, nR) = initiator ? (pub, theirKey, nonce, theirNonce) : (theirKey, pub, theirNonce, nonce)
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirKey),
              let shared = try? secret.sharedSecretFromKeyAgreement(with: key) else { return finish(nil, "Pairing failed. Try again.") }
        them.token = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: nI + nR, sharedInfo: Data("hither-pair".utf8),
                                                    outputByteCount: 32).withUnsafeBytes { Data($0) }
        let n = hash(kI, kR, nI, nR).prefix(4).reduce(0) { $0 << 8 | UInt32($1) } % 1_000_000
        step = 2
        confirm(String(format: "%03d %03d", n / 1000, n % 1000), them.name) { yes in
            guard !self.over else { return }
            guard yes else { self.wire.send(Msg("pairno")); return self.finish(nil, nil) }
            self.mine = true
            self.wire.send(Msg("pairok"))
            if self.theirs { self.finish(self.them, nil) }
        }
    }

    private func finish(_ peer: Peer?, _ why: String?) {
        guard !over else { return }
        over = true
        failure = why
        wire.onMsg = { _ in }
        wire.onClose = {}
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [wire] in wire.close() }   // let a last pairok/pairno go out
        onDone(peer)
    }

    private func send(_ t: String, _ fill: (inout Msg) -> Void) {
        var m = Msg(t)
        fill(&m)
        wire.send(m)
    }
}

private func hash(_ parts: Data...) -> Data { Data(SHA256.hash(data: parts.reduce(Data(), +))) }

/// A peer's name ends up in a hostname ("mini.local") and in proxy app names, so only allow what a local host name can be.
func validName(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 63 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
}

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
