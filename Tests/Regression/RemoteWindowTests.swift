import Foundation
import Network
import Shared

/// Optional integration check against an already paired host, both directly and through the installed relay.
/// The requested ID is absent from the host's own window list; this must never open an existing app window.
func testMissingRemoteWindow(host: String, app: String, throughRelay: Bool) throws {
    let queue = DispatchQueue(label: "hither.tests.remote")
    let done = DispatchSemaphore(value: 0)
    let connection = NWConnection(host: NWEndpoint.Host(throughRelay ? "127.0.0.1" : host),
                                  port: throughRelay ? relayPort : port, using: Pairings.load().tls(to: host))
    let wire = Wire(connection, queue: queue)
    var outcome: String?
    var requested = false
    var receivedClosed = false
    wire.onMsg = { message in
        switch message.t {
        case "windows":
            let windows = message.items ?? []
            guard windows.contains(where: { $0.bundle == app }) else {
                outcome = "Open a normal window of \(app) before running the remote regression"
                return wire.close()
            }
            var missingID = Int(UInt32.max)
            while windows.contains(where: { $0.id == missingID }) { missingID -= 1 }
            var open = Msg("open"); open.app = app; open.k = missingID
            requested = true
            wire.send(open)
        case "opened":
            outcome = "Host incorrectly substituted window \(message.k ?? 0) for a missing ID"
            wire.close()
        case "closed": receivedClosed = true
        default: break
        }
    }
    wire.onClose = { done.signal() }
    wire.start()
    wire.send(Msg("list"))
    guard done.wait(timeout: .now() + 10) == .success else {
        wire.close()
        throw RegressionFailure(message: "Remote window regression timed out (relay=\(throughRelay))")
    }
    if let outcome { throw RegressionFailure(message: outcome) }
    guard requested, receivedClosed else {
        throw RegressionFailure(message: "Remote stream closed without delivering the terminal message (relay=\(throughRelay))")
    }
}
