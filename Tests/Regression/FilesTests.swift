import Foundation
import Network
import Shared

/// Finder files over a loopback Wire: a folder (nested, empty file, executable, a symlink that's skipped) and a file
/// bigger than a chunk and than the old 8 MB clipboard limit, into a folder that already holds one of the names.
func testFiles() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "hither-files-\(UUID().uuidString)")
    let src = root.appending(path: "src"), dest = root.appending(path: "dest")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: src.appending(path: "Folder/sub"), withIntermediateDirectories: true)
    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: src.appending(path: "Folder/sub/a.txt"))
    try Data().write(to: src.appending(path: "Folder/empty.txt"))
    try Data("#!/bin/sh\n".utf8).write(to: src.appending(path: "Folder/run.sh"))
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appending(path: "Folder/run.sh").path)
    try fm.createSymbolicLink(atPath: src.appending(path: "Folder/link").path, withDestinationPath: "/etc/hosts")
    let big = Data((0..<(9 << 20) + 12_345).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 7) })
    try big.write(to: src.appending(path: "big.bin"))
    try Data("already here".utf8).write(to: dest.appending(path: "big.bin"))

    let queue = DispatchQueue(label: "hither.tests.files")
    let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0), answered = DispatchSemaphore(value: 0)
    let listener = try NWListener(using: .tcp, on: .any)
    var server: Wire?, inbox: FileInbox?, result: Result<[URL], Error>?, answer: String?, failure: Error?
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { conn in
        let w = Wire(conn, queue: queue)
        server = w
        w.onMsg = { m in
            switch m.t {
            case "files":
                do { inbox = try FileInbox(m.files ?? [], into: dest) } catch { failure = error; finished.signal() }
            case "filesend":
                guard let box = inbox else { return }
                result = Result { try box.finish() }
                var r = Msg("filesgot"); r.text = Files.summary(box.entries)
                w.send(r)
                finished.signal()
            default: break
            }
        }
        w.onFileData = { d in
            do { try inbox?.take(d) } catch { failure = error; finished.signal() }
        }
        w.start()
    }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, let p = listener.port else { throw RegressionFailure(message: "files listener") }
    let client = Wire(NWConnection(host: "127.0.0.1", port: p, using: .tcp), queue: DispatchQueue(label: "hither.tests.files.client"))
    defer { client.close(); server?.close(); listener.cancel() }
    client.onMsg = { m in answer = m.text ?? m.t; answered.signal() }
    client.start()
    var last: UInt64 = 0
    Files.send([src.appending(path: "Folder"), src.appending(path: "big.bin")], over: client) { sent, _ in last = sent }

    guard finished.wait(timeout: .now() + 20) == .success else { throw RegressionFailure(message: "file copy didn't finish") }
    if let failure { throw RegressionFailure(message: "file copy failed: \(failure)") }
    guard answered.wait(timeout: .now() + 5) == .success else {
        throw RegressionFailure(message: "file copy didn't finish")
    }
    let urls = try result!.get()
    try expectEqual(urls.map(\.lastPathComponent), ["Folder", "big 2.bin"])
    try expectEqual(try Data(contentsOf: dest.appending(path: "big 2.bin")), big)
    try expectEqual(try Data(contentsOf: dest.appending(path: "big.bin")), Data("already here".utf8))
    try expectEqual(try String(contentsOf: dest.appending(path: "Folder/sub/a.txt"), encoding: .utf8), "hello")
    try expectEqual(try Data(contentsOf: dest.appending(path: "Folder/empty.txt")), Data())
    let mode = try fm.attributesOfItem(atPath: dest.appending(path: "Folder/run.sh").path)[.posixPermissions] as? NSNumber
    try expectEqual(mode?.intValue, 0o755)
    try expectFalse(fm.fileExists(atPath: dest.appending(path: "Folder/link").path))
    try expectEqual(try fm.contentsOfDirectory(atPath: dest.path).filter { $0.hasPrefix(".hither-") }, [])   // staging gone
    try expectEqual(last, UInt64(big.count + 15))
    try expectEqual(answer, "2 items (9.4 MB)")

    // a name that would land outside the folder is refused before anything is written
    for bad in ["../evil", "/etc/evil", "a//b", "a/./b", ""] {
        if (try? FileInbox([FileEntry(path: bad, size: 1)], into: dest)) != nil { throw RegressionFailure(message: "accepted \"\(bad)\"") }
    }
    // a copy that ends early leaves nothing behind, and data past the files' sizes is an error
    let cut = try FileInbox([FileEntry(path: "cut.bin", size: 10)], into: dest)
    try cut.take(Data(count: 5))
    try expectNil(try? cut.finish())
    let over = try FileInbox([FileEntry(path: "over.bin", size: 2)], into: dest)
    try expectNil(try? over.take(Data(count: 3)))
    over.abort()
    try expectEqual(try fm.contentsOfDirectory(atPath: dest.path).sorted(), ["Folder", "big 2.bin", "big.bin"])
}
