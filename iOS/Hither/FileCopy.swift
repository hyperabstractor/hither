import Foundation
import Network
import Shared
import UIKit

/// One copy of files to or from a Mac, on a connection of its own (as on a Mac) so a big one never holds up a window's
/// input or video. Sent files land in the Mac's Downloads and on its clipboard; files from the Mac's clipboard land in
/// this app's Documents (the Files app shows them), ready to share. A copy that's cancelled or cut off leaves nothing
/// behind on either side. It keeps going for a while if the app goes to the background, and is cancelled if iOS
/// won't wait any longer.
final class FileCopy: ObservableObject, Identifiable {
    let mac: Peer, outgoing: Bool
    private let wire: Wire
    private let started = CACurrentMediaTime()
    // main thread
    @Published private(set) var what = "files"     // "report.pdf", "3 items"
    @Published private(set) var done: UInt64 = 0
    @Published private(set) var total: UInt64 = 0
    private(set) var result: (ok: Bool, text: String)?   // once it ended
    private(set) var landed: [URL] = []                  // where received files went
    var onEnd: (FileCopy) -> Void = { _ in }
    private var cleanup: [URL] = []
    private var shown = 0.0
    private var background = UIBackgroundTaskIdentifier.invalid
    // the wire's queue
    private var inbox: FileInbox?

    init(mac: Peer, host: String, outgoing: Bool) {
        self.mac = mac
        self.outgoing = outgoing
        wire = Wire(NWConnection(host: NWEndpoint.Host(host), port: port, using: Pairings.load().tls(to: host)),
                    queue: DispatchQueue(label: "files"))
    }

    /// "↓ report.pdf from mini"
    var heading: String { "\(outgoing ? "↑" : "↓") \(what) \(outgoing ? "to" : "from") \(mac.name)" }

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// "51% of 60.5 MB · 4.2 MB/s · about 10 s left"
    var detail: String {
        let f = { (n: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
        guard total > 0 else { return "Starting…" }
        var s = "\(Int(fraction * 100))% of \(f(total))"
        let t = CACurrentMediaTime() - started
        if t >= 1, done > 0 {
            let rate = Double(done) / t, left = Double(total - done) / rate
            s += " · \(f(UInt64(rate)))/s"
            if left >= 1 { s += " · about " + (left < 60 ? "\(Int(left)) s" : left < 3600 ? "\(Int(left / 60)) min" : String(format: "%.1f h", left / 3600)) + " left" }
        }
        return s
    }

    /// `cleanup`: files to remove once it ends (the copies a document picker made).
    func send(_ urls: [URL], cleanup: [URL]) {
        self.cleanup = cleanup
        what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        start { [weak self] m in
            guard let self else { return }
            switch m.t {
            case "filesgot": end("Sent \(m.text ?? what) to \(mac.name)'s Downloads (on its clipboard)", ok: true)
            case "fileserr": end(m.text ?? "Couldn't copy to \(mac.name)", ok: false)
            default: break
            }
        }
        Files.send(urls, over: wire) { [weak self] sent, total in self?.progress(sent, total) }
    }

    /// The files on the Mac's clipboard, into `dest`.
    func get(into dest: URL) {
        start { [weak self] m in
            guard let self else { return }
            switch m.t {
            case "files":
                let entries = m.files ?? []
                DispatchQueue.main.async { self.what = Files.name(entries); self.total = Files.total(entries) }
                do { inbox = try FileInbox(entries, into: dest) } catch { fail(error) }
            case "filesend":
                guard let box = inbox else { return }
                inbox = nil
                do {
                    let urls = try box.finish()
                    var r = Msg("filesgot"); r.text = Files.summary(box.entries)
                    wire.send(r)
                    DispatchQueue.main.async { self.landed = urls }
                    end("Got \(Files.summary(box.entries)) from \(mac.name): in Files › On My \(UIDevice.current.model) › Hither", ok: true)
                } catch { fail(error) }
            case "fileserr": end(m.text ?? "Couldn't copy from \(mac.name)", ok: false)
            default: break
            }
        }
        wire.onFileData = { [weak self] d in
            guard let self, let box = inbox else { return }
            do { try box.take(d) } catch { return fail(error) }
            progress(box.received, box.total)
        }
        wire.send(Msg("filesget"))
    }

    /// Stop it; the other end throws away what it had of it.
    func cancel() {
        guard result == nil else { return }
        var e = Msg("fileserr"); e.text = "Cancelled on \(localName())"
        wire.send(e)
        end("Cancelled", ok: false)
    }

    private func start(_ onMsg: @escaping (Msg) -> Void) {
        background = UIApplication.shared.beginBackgroundTask(withName: "Hither file copy") { [weak self] in self?.cancel() }
        wire.onMsg = onMsg
        wire.onClose = { [weak self] in
            guard let self else { return }
            end("Copy with \(mac.name) stopped: connection lost", ok: false)
        }
        wire.start()
    }

    private func progress(_ sent: UInt64, _ of: UInt64) {
        let now = CACurrentMediaTime()
        guard now - shown >= 0.25 else { return }
        shown = now
        DispatchQueue.main.async { [self] in
            guard result == nil else { return }
            done = sent; total = of
        }
    }

    /// On the wire's queue.
    private func fail(_ error: Error) {
        var e = Msg("fileserr"); e.text = error.localizedDescription
        wire.send(e)
        end(error.localizedDescription, ok: false)
    }

    private func end(_ s: String, ok: Bool) {
        DispatchQueue.main.async { [self] in
            guard result == nil else { return }
            result = (ok, s)
            if ok { done = total }
            wire.queue.async { [self] in inbox?.abort(); inbox = nil }   // a copy cut off partway leaves nothing behind
            // let a last "fileserr" or "filesgot" go out before hanging up
            wire.queue.asyncAfter(deadline: .now() + 0.5) { [wire] in wire.close() }
            for u in cleanup { try? FileManager.default.removeItem(at: u) }
            cleanup = []
            if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            onEnd(self)
        }
    }
}
