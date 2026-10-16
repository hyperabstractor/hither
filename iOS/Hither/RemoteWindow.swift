import Foundation
import Network
import os
import Shared
import UIKit

/// One Mac window on the phone, over its own connection. Like a proxy window on the Mac, minus the window: it
/// asks the Mac to size the real window to fit the phone ("restore" puts it back when the connection ends), and it
/// reconnects after a Wi-Fi blip or when the app comes back to the front.
final class RemoteWindow: ObservableObject {
    let mac: Peer, app: String
    var windowID: Int     // pins reconnects to the exact window, even after its title changes
    let view = StreamView()
    @Published var title = ""
    @Published var status = "Connecting…"   // empty while the picture is live
    @Published var latency = ""
    @Published var closed = false           // gone on the Mac, or never found: leave the stream screen
    private var wire: Wire?
    private let activeWire = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)   // video and audio arrive off main
    private var opened = false              // this connection has its window; resizes can go out
    private var requested: CGSize?          // the size last asked for on this connection
    private var retries = 0
    private var host = ""                   // the name this connection dialed (see Reach)
    private var done = false, paused = false

    init(mac: Peer, app: String, windowID: Int, title: String) {
        self.mac = mac; self.app = app; self.windowID = windowID; self.title = title
        view.send = { [weak self] in self?.wire?.send($0) }
        view.onWantSize = { [weak self] in self?.resize($0) }
        view.onLatency = { [weak self] ms in self?.latency = "\(ms) ms" }
        connect()
    }

    func connect() {
        guard !done, !paused, wire == nil else { return }
        let hosts = Reach.hosts(mac)
        host = hosts[retries % hosts.count]   // each retry tries the Mac's other name
        let w = Wire(NWConnection(host: NWEndpoint.Host(host), port: port, using: Pairings.load().tls(to: host)),
                     queue: DispatchQueue(label: "wire"))
        w.onClose = { [weak self, weak w] in
            DispatchQueue.main.async {
                guard let self, let w, self.wire === w else { return }
                self.activeWire.withLock { $0 = nil }
                self.wire = nil
                self.lost()
            }
        }
        w.onVideo = { [weak self, weak w] d in
            guard let self, let w, self.activeWire.withLock({ $0 == ObjectIdentifier(w) }) else { return }
            w.send(Msg("ack"))
            DispatchQueue.main.async { [weak self, weak w] in
                guard let self, let w, self.wire === w, !self.done else { return }
                self.view.show(d)
            }
        }
        let me = ObjectIdentifier(self)
        w.onAudio = { [weak self, weak w] data in
            guard let self, let w, self.activeWire.withLock({ $0 == ObjectIdentifier(w) }) else { return }
            AudioOut.shared.play(data, from: me)
        }
        w.onMsg = { [weak self, weak w] m in
            DispatchQueue.main.async { [weak self, weak w] in
                guard let self, let w, self.wire === w, !self.done else { return }
                self.handle(m)
            }
        }
        wire = w
        opened = false
        requested = nil
        activeWire.withLock { $0 = ObjectIdentifier(w) }
        w.start()
        // no "hevc422": an iPhone may not decode HEVC 4:2:2
        var m = Msg("open"); m.app = app; m.k = windowID; m.caps = ["hevc", "audio", "restore"]
        w.send(m)
        Reach.giveUpLater(on: w)
    }

    func lost() {
        guard !done, !paused else { return }
        guard retries < 30 else { status = "Can't reach \(mac.name)"; return }
        retries += 1
        status = "Reconnecting…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    func handle(_ m: Msg) {
        switch m.t {
        case "opened":
            let id = m.k ?? 0
            guard id > 0, windowID == 0 || id == windowID else {
                log("rejected window \(id) from \(host); expected \(windowID)")
                return finish()
            }
            windowID = id
            opened = true
            retries = 0
            Reach.worked(host, for: mac)
            status = ""
            if let t = m.title, !t.isEmpty { title = t } else if let a = m.app { title = a }
            view.remoteSize = CGSize(width: m.w ?? 0, height: m.h ?? 0)
            AudioOut.shared.claim(ObjectIdentifier(self))
            wire?.send(Msg("focus"))   // bring it to the front on the Mac, so the first tap and key land there
            resize(view.wantSize)
        case "size": view.remoteSize = CGSize(width: m.w ?? 0, height: m.h ?? 0)
        case "title": if let t = m.title, !t.isEmpty { title = t }
        case "closed": log(m.title ?? "closed"); finish()
        default: break
        }
    }

    /// Ask for the window at this size. If the app won't go that small, the picture is scaled to fit instead.
    func resize(_ s: CGSize) {
        guard opened, s.width > 0, s.height > 0, s != requested else { return }
        requested = s
        var m = Msg("resize"); m.w = s.width; m.h = s.height
        wire?.send(m)
    }

    /// In the background iOS suspends the app and its connections. Hang up cleanly instead (the Mac puts the window
    /// back) and open it again on return.
    func pause() {
        paused = true
        drop()
    }

    func resume() {
        guard paused else { return }
        paused = false
        retries = 0
        status = "Reconnecting…"
        connect()
    }

    func finish() {
        guard !done else { return }
        done = true
        closed = true
        drop()
        AudioOut.shared.release(ObjectIdentifier(self), next: nil)
    }

    private func drop() {
        activeWire.withLock { $0 = nil }
        let w = wire
        wire = nil
        w?.close()
    }
}
