import Foundation
import Network
import Shared

private final class WireEvents {
    private let lock = NSLock()
    private var values: [String] = []

    func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private func testTerminalWire(_ transport: String, serverParams: NWParameters, clientParams: NWParameters) throws {
    let queue = DispatchQueue(label: "hither.tests.wire.\(transport)")
    let ready = DispatchSemaphore(value: 0)
    let serverClosed = DispatchSemaphore(value: 0)
    let clientClosed = DispatchSemaphore(value: 0)
    let events = WireEvents()
    let listener = try NWListener(using: serverParams, on: .any)
    var server: Wire?
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready, .failed: ready.signal()
        default: break
        }
    }
    listener.newConnectionHandler = { connection in
        let wire = Wire(connection, queue: queue)
        server = wire
        wire.onMsg = { message in events.add("message:\(message.t):\(message.title ?? "")") }
        wire.onClose = { events.add("EOF"); serverClosed.signal() }
        wire.start()
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, let listenerPort = listener.port else {
        listener.cancel()
        throw RegressionFailure(message: "\(transport) Wire test listener did not start")
    }

    let connection = NWConnection(host: "127.0.0.1", port: listenerPort, using: clientParams)
    let client = Wire(connection, queue: queue)
    defer { client.close(); server?.close(); listener.cancel() }
    client.onClose = { events.add("client closed"); clientClosed.signal() }
    client.start()
    var before = Msg("before"); before.title = "first"
    var terminal = Msg("closed"); terminal.title = "done"
    var duplicate = Msg("closed"); duplicate.title = "duplicate"
    client.send(before)
    client.sendAndClose(terminal)
    client.sendAndClose(duplicate)
    client.send(Msg("late"))

    guard serverClosed.wait(timeout: .now() + 5) == .success else {
        throw RegressionFailure(message: "\(transport) Wire peer did not observe EOF after final message")
    }
    guard clientClosed.wait(timeout: .now() + 5) == .success else {
        throw RegressionFailure(message: "\(transport) Wire sender did not close after peer EOF")
    }
    let observed = events.snapshot().filter { $0 != "client closed" }
    guard observed == ["message:before:first", "message:closed:done", "EOF"] else {
        throw RegressionFailure(message: "\(transport) Wire terminal order or dedup failed: \(observed)")
    }
}

func testWire() throws {
    try testTerminalWire("tcp", serverParams: .tcp, clientParams: .tcp)

    // Use the same PSK handshake as viewer and host; this exercises TLS's final write as well as TCP's FIN.
    let key = Data(repeating: 0x42, count: 32)
    let identity = "hither-wire-regression"
    try testTerminalWire("tls-psk", serverParams: tlsParams(psks: [(identity, key)]),
                        clientParams: tlsParams(psks: [(identity, key)]))

    // Explicit cancellation is idempotent, including when Network reports cancellation later.
    let cancelEvents = WireEvents()
    let queue = DispatchQueue(label: "hither.tests.wire.cancel")
    let ordinary = Wire(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 9)!, using: .tcp), queue: queue)
    ordinary.onClose = { cancelEvents.add("closed") }
    ordinary.start()
    ordinary.close()
    ordinary.close()
    guard cancelEvents.snapshot() == ["closed"] else {
        throw RegressionFailure(message: "Wire called onClose more than once for ordinary cancellation")
    }
}
