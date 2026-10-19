import AppKit
import AVFoundation
import Network
import os
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications
import Shared

// One binary, three roles, picked by the bundle it runs from:
//   cli       hither <host> <app> [title-substring]  |  hither <host> --list      (dev)
//   launcher  "Hither.app": menu-bar list of the host's windows, creates proxy apps on demand
//   proxy     "Cursor · mini.app": its own Dock/Cmd-Tab identity; one local window per remote window

let info = Bundle.main.infoDictionary ?? [:]
let role = info["HitherRole"] as? String ?? "cli"
let openNote = Notification.Name("dev.hither.open")
let launcherID = "dev.hither.app"
let quitNote = Notification.Name("dev.hither.quit")   // launcher quitting → proxies go too (they need its relay)

func short(_ host: String) -> String { host.split(separator: ".").first.map(String.init) ?? host }
/// Proxies go through the launcher's loopback relay for their Mac (only the launcher needs Local Network access);
/// TLS still runs end to end with the host, so the relay only ever sees ciphertext. No relay yet (the launcher isn't
/// running): port 0 fails at once, and the proxy retries.
func dial(_ host: String) -> Wire {
    let tls = Pairings.load().tls(to: host)
    let c = role == "proxy"
        ? NWConnection(host: "127.0.0.1", port: relayPort(for: host) ?? .any, using: tls)
        : NWConnection(host: NWEndpoint.Host(host), port: port, using: tls)
    return Wire(c, queue: DispatchQueue(label: "wire"))
}
/// Runs on the main thread even while a menu is open (plain main-queue blocks wait for tracking to end).
func onMain(_ f: @escaping () -> Void) { RunLoop.main.perform(inModes: [.common], block: f); CFRunLoopWakeUp(CFRunLoopGetMain()) }

/// What the user calls `host`: its paired name, even when it's reached by address.
func macName(_ host: String) -> String { Pairings.load().peer(for: host)?.name ?? short(host) }

// Clipboard, only on request: Send Clipboard puts this Mac's on `name`'s (it confirms with "clipset"),
// Get Clipboard asks for theirs ("clipget", answered with a clipboard frame or "cliperr"). Files copied in Finder
// go by FileCopy instead, on a connection of their own.
/// What a clipboard action reports: progress (`done` nil), then once how it ended.
typealias ClipStatus = (_ text: String, _ done: Bool?) -> Void

/// Sends this Mac's clipboard to `host`; nil when it went (or a file copy started), or why it didn't.
func pushClipboard(over wire: Wire?, to host: String, status: @escaping ClipStatus) -> String? {
    let name = macName(host)
    guard let wire else { return "Not connected to \(name)" }
    let c = Clip.read()
    if c.files { FileCopy(host, status: status).send(Files.onClipboard()); return nil }
    if c.parts.isEmpty { return "Your clipboard is empty" }
    wire.sendClip(c.encoded())
    return nil
}
/// `host`'s clipboard arrived: it becomes this Mac's. Returns what to tell the user, or nil when it holds files,
/// which then come by FileCopy (reported through `status`).
func receivedClipboard(_ d: Data, from host: String, status: @escaping ClipStatus) -> String? {
    let name = macName(host)
    guard let c = Clip(decoding: d) else { return "Couldn't read \(name)'s clipboard" }
    if c.files { FileCopy(host, status: status).get(); return nil }
    if c.parts.isEmpty { return "\(name)'s clipboard is empty" }
    c.write()
    return "Got \(c.summary) from \(name)"
}

/// One copy of Finder files to or from `host`, on its own connection so a big one never holds up a window's input
/// or video. What arrives goes into Downloads and onto the clipboard, ready to paste in Finder.
final class FileCopy {
    static var running: [FileCopy] = []   // main thread, oldest first; a copy lives until it ends
    /// Main thread: a copy started, moved on (twice a second at most) or ended. The launcher shows it in the menu bar.
    static var changed: (FileCopy) -> Void = { _ in }
    let host: String, name: String, wire: Wire, status: ClipStatus
    let started = CACurrentMediaTime()
    // main thread
    var outgoing = true
    var what = "files"                          // "Spock3.app", "3 items"
    var done: UInt64 = 0, total: UInt64 = 0
    var result: (ok: Bool, text: String)?       // once it ended
    var cancelled = false
    var landed: [URL] = []                      // where received files went
    // the wire's queue (get) or the sending thread (send)
    var inbox: FileInbox?
    var shown = 0.0

    init(_ host: String, status: @escaping ClipStatus) {
        self.host = host
        name = macName(host)
        wire = dial(host)   // not .background: macOS's delay-based throttling crawls on a 300 ms link (50 MB: >75 s vs 10 s)
        self.status = status
    }

    /// "↓ Spock3.app from mini-pb"
    var heading: String { "\(outgoing ? "↑" : "↓") \(what) \(outgoing ? "to" : "from") \(name)" }

    /// "51% of 60.5 MB · 4.2 MB/s · about 10 s left"
    var detail: String {
        let f = { (n: UInt64) in ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file) }
        guard total > 0 else { return "Starting…" }
        var s = "\(percent)% of \(f(total))"
        let t = CACurrentMediaTime() - started
        if t >= 1, done > 0 {
            let rate = Double(done) / t, left = Double(total - done) / rate
            s += " · \(f(UInt64(rate)))/s"
            if left >= 1 { s += " · about " + (left < 60 ? "\(Int(left)) s" : left < 3600 ? "\(Int(left / 60)) min" : String(format: "%.1f h", left / 3600)) + " left" }
        }
        return s
    }

    var percent: Int { total > 0 ? Int(done * 100 / total) : 0 }

    func send(_ urls: [URL]) {
        what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        start { [self] m in
            switch m.t {
            case "filesgot": end("Sent \(m.text ?? what) to \(name)'s Downloads (on its clipboard)", ok: true)
            case "fileserr": end(m.text ?? "Couldn't copy to \(name)", ok: false)
            default: break
            }
        }
        Files.send(urls, over: wire) { [self] sent, total in progress(sent, total) }
    }

    func get() {
        outgoing = false
        start { [self] m in
            switch m.t {
            case "files":
                let entries = m.files ?? []
                onMain { [self] in what = Files.name(entries); total = Files.total(entries) }
                do { inbox = try FileInbox(entries, into: Files.downloads) } catch { fail(error) }
            case "filesend":
                guard let box = inbox else { return }
                inbox = nil
                do {
                    let urls = try box.finish()
                    onMain { [self] in landed = urls; Files.putOnClipboard(urls) }
                    var r = Msg("filesgot"); r.text = Files.summary(box.entries)
                    wire.send(r)
                    end("Got \(Files.summary(box.entries)) from \(name): in Downloads and on the clipboard", ok: true)
                } catch { fail(error) }
            case "fileserr": end(m.text ?? "Couldn't copy from \(name)", ok: false)
            default: break
            }
        }
        wire.onFileData = { [self] d in
            guard let box = inbox else { return }
            do { try box.take(d) } catch { return fail(error) }
            progress(box.received, box.total)
        }
        wire.send(Msg("filesget"))
    }

    /// Main thread: stop it; the other end throws away what it had of it.
    func cancel() {
        cancelled = true
        var e = Msg("fileserr"); e.text = "Cancelled on \(localName())"
        wire.send(e)
        end("Cancelled", ok: false)
    }

    private func start(_ onMsg: @escaping (Msg) -> Void) {
        onMain { [self] in
            FileCopy.running.append(self)
            FileCopy.changed(self)
            status("\(heading)…", nil)
        }
        wire.onMsg = onMsg
        wire.onClose = { [self] in end("Copy with \(name) stopped: connection lost", ok: false) }
        wire.start()
    }

    private func progress(_ sent: UInt64, _ of: UInt64) {
        let now = CACurrentMediaTime()
        guard now - shown >= 0.5 else { return }
        shown = now
        onMain { [self] in
            guard result == nil else { return }
            done = sent; total = of
            FileCopy.changed(self)
            status("\(heading): \(detail)", nil)
        }
    }

    private func fail(_ error: Error) {
        var e = Msg("fileserr"); e.text = error.localizedDescription
        wire.send(e)
        end(error.localizedDescription, ok: false)
    }

    private func end(_ s: String, ok: Bool) {
        onMain { [self] in
            guard result == nil else { return }
            result = (ok, s)
            if ok { done = total }
            wire.queue.async { [self] in inbox?.abort(); inbox = nil }   // a copy cut off partway leaves nothing behind
            wire.close()
            FileCopy.running.removeAll { $0 === self }
            status(s, ok)
            FileCopy.changed(self)
        }
    }
}
/// ⌃⌥⌘C / ⌃⌥⌘V in a remote window, shown on the Edit menu items too.
let clipMods: NSEvent.ModifierFlags = [.control, .option, .command]

// NSEvent.Phase → CGScrollPhase / CGMomentumScrollPhase raw values
func cgPhase(_ p: NSEvent.Phase) -> Int {
    p.contains(.began) ? 1 : p.contains(.changed) ? 2 : p.contains(.ended) ? 4 : p.contains(.cancelled) ? 8 : p.contains(.mayBegin) ? 128 : 0
}
func cgMomentum(_ p: NSEvent.Phase) -> Int {
    p.contains(.began) ? 1 : p.contains(.changed) ? 2 : p.contains(.ended) ? 3 : 0
}

final class StreamView: NSView {
    let video = AVSampleBufferDisplayLayer()
    var depacketizer = Depacketizer()
    var keySeq: UInt32 = 0
    var sentAt: [UInt32: CFTimeInterval] = [:]
    var samples: [Double] = []
    var allSamples: [Double] = []
    var onLatency: (Int) -> Void = { _ in }
    var send: (Msg) -> Void = { _ in }
    var onClipboard: (_ send: Bool) -> Void = { _ in }   // ⌃⌥⌘C sends this Mac's clipboard, ⌃⌥⌘V gets theirs
    var onZoom: () -> Void = {}
    var zoomKeys = false   // Native Desktop: ⌃⌥⌘= / − / 0 / 9 zoom here instead of going to the host
    var remoteSize = CGSize.zero { didSet { if remoteSize != oldValue { place() } } }   // the host window's size in points
    /// Native Desktop: nil = fit the window; else remote points × zoom, scrolled by `pan` where it's bigger than the window.
    private(set) var zoom: CGFloat?
    var pan = CGPoint.zero
    private(set) var picture = CGRect.zero   // where the video is in this view
    var panTimer: Timer?
    var held = -1   // the mouse button down (-1: none), so edge scrolling while dragging keeps dragging

    override init(frame: NSRect) {
        super.init(frame: frame)
        video.videoGravity = .resize   // `picture` keeps the shape
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.masksToBounds = true
        root.isGeometryFlipped = true   // top-left origin, like this view
        root.addSublayer(video)
        layer = root
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }   // top-left origin, same as CG global coords on the host

    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); place() }

    func place() {
        let r = pictureRect(view: bounds.size, remote: remoteSize, zoom: zoom, pan: pan)
        pan = r.pan
        picture = remoteSize == .zero ? bounds : r.rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.frame = picture
        CATransaction.commit()
    }

    // MARK: zoom (Native Desktop)

    static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    /// The picture's scale now, fit included: remote points → points here.
    var scaleNow: CGFloat { remoteSize.width > 0 ? picture.width / remoteSize.width : 1 }

    /// The pointer, if it's over this view.
    var pointerInside: CGPoint? {
        guard let w = window else { return nil }
        let p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : nil
    }

    /// nil = fit. Keeps what's under `anchor` (the pointer, else the middle) where it is.
    func setZoom(_ z: CGFloat?, around anchor: CGPoint? = nil) {
        let a = anchor ?? pointerInside ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let spot = remotePoint(a, in: picture, remote: remoteSize)
        zoom = z
        if let z { pan = CGPoint(x: spot.x * z - a.x, y: spot.y * z - a.y) }
        place()
        onZoom()
    }

    func zoomStep(_ dir: Int) {
        let now = scaleNow
        if let next = dir > 0 ? Self.zoomSteps.first(where: { $0 > now + 0.005 }) : Self.zoomSteps.last(where: { $0 < now - 0.005 }) {
            setZoom(next)
        }
    }

    /// Zoomed in past the window: with the pointer near an edge the picture slides that way, faster the closer it is,
    /// so the whole screen is in reach. The host hears where the pointer now is, as the spot under it changes.
    func edgeScroll() {
        guard zoom != nil, let p = pointerInside, speed(at: p) != .zero else { return }
        guard panTimer == nil else { return }
        var last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, let w = window else { return t.invalidate() }
            var p = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            if held >= 0 { p = CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height)) }   // dragging past the edge
            let now = CACurrentMediaTime(), v = bounds.contains(p) || held >= 0 ? speed(at: p) : .zero
            defer { last = now }
            guard v != .zero else { t.invalidate(); panTimer = nil; return }
            let before = pan
            pan.x += v.x * (now - last); pan.y += v.y * (now - last)
            place()
            guard pan != before else { return }   // at the end already
            let r = remotePoint(p, in: picture, remote: remoteSize)
            var m = Msg("mouse")
            m.x = r.x; m.y = r.y; m.k = held >= 0 ? 3 : 0; m.b = max(held, 0)
            m.f = UInt64(NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
            send(m)
        }
        RunLoop.main.add(t, forMode: .common)
        panTimer = t
    }

    /// Points per second to scroll with the pointer at `p`: within 40 pt of an edge the picture extends past.
    func speed(at p: CGPoint) -> CGPoint {
        let band: CGFloat = 40, fast: CGFloat = 4400   // at the very edge; a quarter of that halfway in
        func axis(_ v: CGFloat, _ size: CGFloat) -> CGFloat {
            v < band ? -fast * pow((band - max(v, 0)) / band, 2) : v > size - band ? fast * pow((min(v, size) - (size - band)) / band, 2) : 0
        }
        return CGPoint(x: picture.width > bounds.width + 0.5 ? axis(p.x, bounds.width) : 0,
                       y: picture.height > bounds.height + 0.5 ? axis(p.y, bounds.height) : 0)
    }

    // MARK: video

    func show(_ packet: Data) {
        guard let (seq, sb) = depacketizer.sampleBuffer(packet) else { return }
        let renderer = video.sampleBufferRenderer
        if renderer.status == .failed {
            log("decoder failed: \(renderer.error?.localizedDescription ?? "?") — asking for keyframe")
            renderer.flush()
            send(Msg("keyframe"))
        }
        renderer.enqueue(sb)
        meter(seq)
    }

    /// key→frame: time from sending a keyDown to the first frame the host captured after injecting it.
    func meter(_ seq: UInt32) {
        let now = CACurrentMediaTime()
        let hit = sentAt.keys.filter { $0 <= seq }
        if let last = hit.max(), let t = sentAt[last] {
            samples.append((now - t) * 1000)
            allSamples.append((now - t) * 1000)
            if samples.count > 30 { samples.removeFirst() }
            onLatency(Int(samples.sorted()[samples.count / 2]))
        }
        hit.forEach { sentAt[$0] = nil }
        sentAt = sentAt.filter { now - $0.value < 1 }  // keys that changed nothing on screen
    }

    // MARK: input → host

    func flags(_ e: NSEvent) -> UInt64 { UInt64(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) }

    /// A point in this view → the same spot in the host window (full screen here is taller than the host's display
    /// allows, so the video can be letterboxed).
    func remote(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return remoteSize == .zero ? p : remotePoint(p, in: picture, remote: remoteSize)
    }

    func mouse(_ e: NSEvent, _ kind: Int, _ button: Int) {
        if kind == 1 { held = button } else if kind == 2 { held = -1 }
        edgeScroll()
        let p = remote(e)
        var m = Msg("mouse")
        m.x = p.x; m.y = p.y; m.k = kind; m.b = button; m.f = flags(e)
        if kind == 1 || kind == 2 { m.c = e.clickCount }
        send(m)
    }

    override func mouseMoved(with e: NSEvent) { mouse(e, 0, 0) }
    override func mouseDown(with e: NSEvent) { mouse(e, 1, 0) }
    override func mouseUp(with e: NSEvent) { mouse(e, 2, 0) }
    override func mouseDragged(with e: NSEvent) { mouse(e, 3, 0) }
    override func rightMouseDown(with e: NSEvent) { mouse(e, 1, 1) }
    override func rightMouseUp(with e: NSEvent) { mouse(e, 2, 1) }
    override func rightMouseDragged(with e: NSEvent) { mouse(e, 3, 1) }
    override func otherMouseDown(with e: NSEvent) { mouse(e, 1, 2) }
    override func otherMouseUp(with e: NSEvent) { mouse(e, 2, 2) }
    override func otherMouseDragged(with e: NSEvent) { mouse(e, 3, 2) }

    override func scrollWheel(with e: NSEvent) {
        let p = remote(e)
        var m = Msg("scroll")
        m.x = p.x; m.y = p.y; m.dx = e.scrollingDeltaX; m.dy = e.scrollingDeltaY; m.f = flags(e)
        m.p = cgPhase(e.phase); m.mp = cgMomentum(e.momentumPhase)
        m.b = e.hasPreciseScrollingDeltas ? 0 : 1
        send(m)
    }

    func key(_ e: NSEvent, down: Bool) {
        var m = Msg("key")
        m.k = Int(e.keyCode); m.down = down; m.rep = e.isARepeat; m.f = flags(e)
        if down && !e.isARepeat { keySeq += 1; m.seq = keySeq; sentAt[keySeq] = CACurrentMediaTime() }
        send(m)
    }

    /// Synthetic keystroke for the latency self-test (HITHER_TEST_TYPE).
    func tap(_ code: Int) {
        keySeq += 1
        sentAt[keySeq] = CACurrentMediaTime()
        var d = Msg("key"); d.k = code; d.down = true; d.f = 0; d.seq = keySeq
        var u = Msg("key"); u.k = code; u.down = false; u.f = 0
        send(d); send(u)
    }

    override func keyDown(with e: NSEvent) { key(e, down: true) }
    override func keyUp(with e: NSEvent) { key(e, down: false) }
    override func flagsChanged(with e: NSEvent) {
        var m = Msg("flags"); m.k = Int(e.keyCode); m.f = flags(e)
        send(m)
    }

    /// Cmd-shortcuts go to the remote app (Cmd-W/Cmd-Q close/quit it, as if local).
    /// Cmd-H / Cmd-M act on this proxy window. AppKit sends no keyUp for Cmd combos, so send both.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown, window?.firstResponder === self else { return false }
        let cmdOnly = e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        switch (cmdOnly, e.charactersIgnoringModifiers) {
        case (true, "h"): NSApp.hide(nil)
        case (true, "m"): window?.miniaturize(nil)
        case (false, "f") where e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .command]:
            window?.toggleFullScreen(nil)   // full screen is about this proxy window, not the host's
        case (false, _) where e.modifierFlags.intersection(.deviceIndependentFlagsMask) == clipMods && [8, 9].contains(e.keyCode):
            onClipboard(e.keyCode == 8)   // kVK_ANSI_C, kVK_ANSI_V
        case (false, _) where zoomKeys && e.modifierFlags.intersection(.deviceIndependentFlagsMask) == clipMods && [24, 27, 29, 25].contains(e.keyCode):
            switch e.keyCode {   // kVK_ANSI_Equal, Minus, 0, 9
            case 24: zoomStep(1)
            case 27: zoomStep(-1)
            case 29: setZoom(1)
            default: setZoom(nil)
            }
        case (true, "`"):   // cycle this proxy app's windows, like any local app
            let ws = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }
            if let i = ws.firstIndex(where: { $0 === window }) { ws[(i + 1) % ws.count].makeKeyAndOrderFront(nil) }
        default: key(e, down: true); key(e, down: false)
        }
        return true
    }
}

// MARK: - one remote window

var proxies: [ProxyWindow] = []

final class ProxyWindow: NSObject, NSWindowDelegate {
    let host: String, app: String, titleFilter: String?
    var windowID: Int     // pins reconnects to the exact remote window (a display's ID for the desktop)
    var isDesktop: Bool { app == desktopApp }   // a whole display: resizing here scales it, never resizes it there
    let view = StreamView(frame: .zero)
    var window: NSWindow?
    var wire: Wire?
    var link: VideoLink?   // video over UDP, once the host offers it
    var viaUDP = false     // a datagram frame was shown: TCP frames still on their way are older, so they're dropped
    var inputN: UInt32 = 0 // this connection's input order (Msg.n), on the main thread
    let activeWire = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)
    var appName = "", remoteTitle = "", latency = ""
    var note: String?   // a passing status ("Sent text to mini-pb") shown in place of the latency
    var remoteSize = CGSize.zero { didSet { view.remoteSize = remoteSize } }
    /// Desktop: Native keeps the host's screen at its own resolution (zoom and scroll here); Adaptive has a dark one
    /// take the mode closest to this window. Remembered per Mac.
    var native: Bool {
        get { UserDefaults.standard.bool(forKey: "desktop.native.\(short(host))") }
        set { UserDefaults.standard.set(newValue, forKey: "desktop.native.\(short(host))") }
    }
    var modeControl: NSSegmentedControl?, zoomControl: NSSegmentedControl?, fitButton: NSButton?
    var retries = 0
    var done = false

    init(host: String, app: String, title: String? = nil, windowID: Int = 0) {
        self.host = host; self.app = app; titleFilter = title; self.windowID = windowID
        super.init()
        view.send = { [weak self] in self?.send($0) }
        view.onLatency = { [weak self] ms in self?.latency = "\(ms) ms"; self?.updateTitle() }
        view.onZoom = { [weak self] in self?.updateTitle() }
        view.onClipboard = { [weak self] send in send ? self?.sendClipboard() : self?.getClipboard() }
        proxies.append(self)
        connect()
    }

    func connect() {
        guard !done, wire == nil else { return }
        let w = dial(host)
        w.onClose = { [weak self, weak w] in
            DispatchQueue.main.async {
                guard let self, let w, self.wire === w else { return }
                self.activeWire.withLock { $0 = nil }
                self.wire = nil
                self.link?.stop(); self.link = nil; self.viaUDP = false
                self.lost()
            }
        }
        w.onVideo = { [weak self, weak w] d in
            guard let self, let w, self.activeWire.withLock({ $0 == ObjectIdentifier(w) }) else { return }
            w.send(Msg("ack"))
            DispatchQueue.main.async { [weak self, weak w] in
                guard let self, let w, self.wire === w, !self.done, !self.viaUDP else { return }
                self.view.show(d)
            }
        }
        let me = ObjectIdentifier(self)
        w.onAudio = { [weak self, weak w] data in
            guard let self, let w, self.activeWire.withLock({ $0 == ObjectIdentifier(w) }) else { return }
            AudioOut.shared.play(data, from: me)
        }
        w.onClip = { [weak self] d in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let s = receivedClipboard(d, from: host, status: { [weak self] s, _ in self?.flash(s) }) { flash(s) }
            }
        }
        w.onMsg = { [weak self, weak w] m in
            guard let self, let w, self.activeWire.withLock({ $0 == ObjectIdentifier(w) }) else { return }
            if m.t == "menu" { return RemoteMenus.shared.deliver(m) }
            if m.t == "udp", let tag = m.f { return self.startLink(w, tag: tag) }
            DispatchQueue.main.async { [weak self, weak w] in
                guard let self, let w, self.wire === w, !self.done else { return }
                self.handle(m)
            }
        }
        wire = w
        inputN = 0
        activeWire.withLock { $0 = ObjectIdentifier(w) }
        w.start()
        var m = Msg("open"); m.app = app; m.title = titleFilter; m.k = windowID; m.caps = ["hevc", "hevc422", "audio", "udp", "ltr", "twice"]
        m.scale = (NSScreen.main ?? NSScreen.screens.first).map { Double($0.backingScaleFactor) }   // Retina here: the host may switch to HiDPI
        w.send(m)
    }

    /// To the host. Input is numbered and goes over UDP too, once there's a link: TCP stays the backstop.
    func send(_ m: Msg) {
        guard let w = wire else { return }
        var m = m
        if inputTypes.contains(m.t) {
            inputN &+= 1
            m.n = inputN
            link?.sendInput(m)
        }
        w.send(m)
    }

    /// The host offered video over UDP: sealed with this connection's own secret, straight to the host from the CLI,
    /// through the launcher's loopback relay from a proxy (as for TCP). Video carries on over TCP until it works.
    func startLink(_ w: Wire, tag: UInt64) {
        guard let secret = w.secret() else { return }
        let to: (NWEndpoint.Host, NWEndpoint.Port)
        if role != "proxy" { to = (NWEndpoint.Host(host), videoPort) }
        else if let p = videoRelayPort(for: host) { to = ("127.0.0.1", p) }
        else { return log("no video relay for \(host): video stays on TCP") }
        let l = VideoLink(secret: secret, tag: tag, to: to.0, port: to.1)
        l.onFrame = { [weak self, weak w] d in
            DispatchQueue.main.async { [weak self, weak w] in
                guard let self, let w, self.wire === w, !self.done else { return }
                if !self.viaUDP { log("video over UDP"); self.viaUDP = true }
                self.view.show(d)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wire === w else { return }
            self.link?.stop()
            self.link = l
            l.start()
        }
    }

    /// Keep the window and retry, so a host restart / Wi-Fi blip / sleep resumes instead of closing.
    func lost() {
        guard !done else { return }
        guard retries < (window == nil ? 5 : 60) else { log("disconnected from \(host)"); return finish() }
        retries += 1
        if role == "proxy", NSRunningApplication.runningApplications(withBundleIdentifier: launcherID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: launcherID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)   // relay lives in the launcher
        }
        updateTitle(status: "reconnecting…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
    }

    func handle(_ m: Msg) {
        switch m.t {
        case "closed": log(m.title ?? "closed"); finish()
        case "udpoff": log("video back on TCP"); viaUDP = false; link?.reset()   // the host stopped hearing our datagrams
        case "title": remoteTitle = m.title ?? ""; updateTitle()
        case "clipset": flash("Sent \(m.text ?? "clipboard") to \(macName(host))")
        case "cliperr": flash(m.text ?? "Couldn't get the clipboard")
        case "opened":
            let receivedID = m.k ?? 0
            guard receivedID > 0, windowID == 0 || receivedID == windowID else {
                log("rejected window \(receivedID) from \(host); expected \(windowID)")
                return finish()
            }
            // A second launch or reconnect can target an already visible window on this host.
            if let other = proxies.first(where: { $0 !== self && $0.host == host && $0.window != nil && $0.windowID == receivedID }) {
                other.window?.makeKeyAndOrderFront(nil)
                NSApp.activate()
                return finish()
            }
            windowID = receivedID
            if window != nil {   // reconnected: keep the local window, refresh metadata and size
                retries = 0
                appName = m.app ?? app
                remoteTitle = m.title ?? ""
                if let icon = m.icon.flatMap(NSImage.init(data:)) { NSApp.applicationIconImage = icon }
                if window?.isKeyWindow == true { wire?.send(Msg("focus")) }
                sendVisibility()
                sendAudioOwner()
                remoteSize = CGSize(width: m.w ?? 0, height: m.h ?? 0)
                updateTitle()
                windowDidResize(Notification(name: NSWindow.didResizeNotification))
                sendShape()
            } else {
                open(m)
                RemoteMenus.shared.install()
            }
        case "size":
            remoteSize = CGSize(width: m.w ?? 0, height: m.h ?? 0)
            if isDesktop {   // the display changed mode (Adaptive fit it to this window): take its exact shape, no bigger
                guard !native, let w = window, !w.styleMask.contains(.fullScreen), !w.inLiveResize, remoteSize.width > 0 else { return }
                let cur = w.contentLayoutRect.size, k = min(cur.width / remoteSize.width, cur.height / remoteSize.height)
                let snap = CGSize(width: (remoteSize.width * k).rounded(), height: (remoteSize.height * k).rounded())
                if abs(snap.width - cur.width) > 1 || abs(snap.height - cur.height) > 1 { w.setContentSize(snap) }
                return
            }
            guard let w = window, !w.inLiveResize, !w.styleMask.contains(.fullScreen), w.contentLayoutRect.size != fit(remoteSize) else { return }
            w.setContentSize(fit(remoteSize))
        default: break
        }
    }

    func open(_ m: Msg) {
        windowID = m.k ?? 0
        appName = m.app ?? app
        remoteTitle = m.title ?? ""
        remoteSize = CGSize(width: m.w ?? 800, height: m.h ?? 600)
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? remoteSize
        let size = isDesktop ? fitShape(remoteSize, in: screen)
            : CGSize(width: min(remoteSize.width, screen.width), height: min(remoteSize.height, screen.height - 28))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary]
        w.acceptsMouseMovedEvents = true
        w.contentView = view
        w.delegate = self
        w.makeFirstResponder(view)
        if isDesktop { desktopToolbar(w) }
        if let last = proxies.last(where: { $0.window != nil })?.window { w.setFrameTopLeftPoint(last.cascadeTopLeft(from: .zero)) } else { w.center() }
        window = w
        AudioOut.shared.claim(ObjectIdentifier(self))
        sendAudioOwner()
        updateTitle()
        w.makeKeyAndOrderFront(nil)
        if let icon = m.icon.flatMap(NSImage.init(data:)) { NSApp.applicationIconImage = icon }
        NSApp.activate()
        if size != remoteSize { windowDidResize(Notification(name: NSWindow.didResizeNotification)) }
        sendShape()
        if let n = Int(ProcessInfo.processInfo.environment["HITHER_TEST_TYPE"] ?? "") { selfTest(n) }
        if ProcessInfo.processInfo.environment["HITHER_TEST_MENU"] != nil {   // test hook: dump the first few remote menus
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let bar = RemoteMenus.shared.fetch([]) ?? []
                log("menu bar: " + bar.map(\.title).joined(separator: " | "))
                for i in 1..<min(bar.count, 4) {
                    let t = CACurrentMediaTime(), items = RemoteMenus.shared.fetch([i]) ?? []
                    log("\(bar[i].title) (\(Int((CACurrentMediaTime() - t) * 1000)) ms): " + items.map {
                        $0.title.isEmpty ? "—" : $0.title + ($0.key.isEmpty ? "" : " [\($0.mods)+\($0.key)]") + ($0.enabled ? "" : " (off)")
                            + ($0.checked ? " ✓" : "") + ($0.sub ? " ▸" : "")
                    }.joined(separator: ", "))
                }
            }
        }
        if let n = Double(ProcessInfo.processInfo.environment["HITHER_TEST_HIDE"] ?? "") {   // test hook: hide app for n s
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.hide(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + n) { NSApp.unhide(nil); NSApp.activate(); w.makeKeyAndOrderFront(nil) }
        }
        if let s = ProcessInfo.processInfo.environment["HITHER_TEST_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), s.count == 2 {
            w.setContentSize(CGSize(width: s[0], height: s[1]))  // test hook: resize without touching the mouse
        }
    }

    /// HITHER_TEST_TYPE=n: type n × ("a", Backspace) — document ends unchanged — then log key→frame latency.
    func selfTest(_ n: Int) {
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self, i < n * 2 else {
                t.invalidate()
                let s = self?.view.allSamples.sorted() ?? []
                log(s.isEmpty ? "self-test: no samples" :
                    "self-test \(s.count) keys: median \(Int(s[s.count / 2])) p90 \(Int(s[s.count * 9 / 10])) max \(Int(s.last!)) ms")
                return
            }
            self.view.tap(i % 2 == 0 ? 0 : 51)   // kVK_ANSI_A, kVK_Delete
            i += 1
        }
    }

    @objc func sendClipboard() {
        if let why = pushClipboard(over: wire, to: host, status: { [weak self] s, _ in self?.flash(s) }) { flash(why) }
    }
    @objc func getClipboard() {
        guard let wire else { return flash("Not connected to \(macName(host))") }
        flash("Getting \(macName(host))'s clipboard…")
        wire.send(Msg("clipget"))
    }

    /// Show `s` in the subtitle for a few seconds.
    func flash(_ s: String) {
        log(s)
        note = s
        updateTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, note == s else { return }
            note = nil
            updateTitle()
        }
    }

    /// Title mirrors the remote window; the subtitle says where it really runs.
    func updateTitle(status: String? = nil) {
        guard let window else { return }
        window.title = remoteTitle.isEmpty ? appName : remoteTitle
        var extra = status ?? note ?? latency
        if isDesktop && native && status == nil && note == nil { extra = "\(Int((view.scaleNow * 100).rounded()))%" + (extra.isEmpty ? "" : " · \(extra)") }
        window.subtitle = "\(appName) on \(short(host))" + (extra.isEmpty ? "" : " · \(extra)")
    }

    /// A desktop: Adaptive tells the host this window's size, which a dark display there takes the closest mode to;
    /// Native says to keep its own.
    func sendShape() {
        guard isDesktop, let w = window else { return }
        var m = Msg("adapt")
        if !native {
            let s = w.contentLayoutRect.size
            m.w = s.width.rounded(); m.h = s.height.rounded(); m.scale = Double((w.screen ?? NSScreen.main)?.backingScaleFactor ?? 2)
        }
        wire?.send(m)
    }

    /// `s` scaled down to fit the screen's usable area (title bar included), keeping its shape.
    func fitShape(_ s: CGSize, in screen: CGSize? = nil) -> CGSize {
        guard s.width > 0, s.height > 0, let v = screen ?? (window?.screen ?? NSScreen.main)?.visibleFrame.size else { return s }
        let k = min(1, v.width / s.width, (v.height - 28) / s.height)
        return CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }

    func windowDidResize(_ n: Notification) {
        guard !isDesktop, let s = window?.contentLayoutRect.size, s != remoteSize else { return }
        var m = Msg("resize"); m.w = s.width.rounded(); m.h = s.height.rounded()
        wire?.send(m)
    }

    func windowDidEndLiveResize(_ n: Notification) {
        if isDesktop { return sendShape() }   // Adaptive: the host fits the new size once you let go
        // host may have clamped us (window can't exceed its display there) — snap to what it really is
        if !isDesktop, let w = window, !w.styleMask.contains(.fullScreen), w.contentLayoutRect.size != fit(remoteSize) { w.setContentSize(fit(remoteSize)) }
    }

    /// Never grow past this screen: if the host can't shrink its window (some apps refuse), show it scaled instead.
    func fit(_ s: CGSize) -> CGSize {
        guard let v = (window?.screen ?? NSScreen.main)?.visibleFrame.size else { return s }
        return CGSize(width: min(s.width, v.width), height: min(s.height, v.height - 28))
    }

    func windowDidEnterFullScreen(_ n: Notification) { sendShape() }
    func windowDidExitFullScreen(_ n: Notification) { sendShape() }
    func windowDidChangeScreen(_ n: Notification) { sendShape() }   // Retina or not may have changed

    // MARK: Desktop controls: Adaptive | Native, and Native's zoom

    /// On the right of the ordinary thin title bar (a toolbar would make it twice as tall).
    func desktopToolbar(_ w: NSWindow) {
        let name = short(host)
        let symbol = { (n: String, label: String) in NSImage(systemSymbolName: n, accessibilityDescription: label) ?? NSImage() }
        let zoom = NSSegmentedControl(images: [symbol("minus.magnifyingglass", "Zoom Out"), symbol("1.magnifyingglass", "Actual Size"),
                                               symbol("plus.magnifyingglass", "Zoom In")],
                                      trackingMode: .momentary, target: self, action: #selector(zoomChosen(_:)))
        for (i, tip) in ["Zoom Out (⌃⌥⌘−)", "Actual Size (⌃⌥⌘0)", "Zoom In (⌃⌥⌘=)"].enumerated() { zoom.setToolTip(tip, forSegment: i) }
        let fit = NSButton(image: symbol("arrow.up.left.and.down.right.magnifyingglass", "Fit in Window"), target: self, action: #selector(zoomFit))
        fit.toolTip = "Fit in Window (⌃⌥⌘9)"
        let mode = NSSegmentedControl(labels: ["Adaptive", "Native"], trackingMode: .selectOne, target: self, action: #selector(modeChosen(_:)))
        mode.setToolTip("\(name)'s screen takes the resolution closest to this window (while Keep Screen Dark is on)", forSegment: 0)
        mode.setToolTip("\(name)'s screen keeps its own resolution: zoom here, and the picture scrolls at the edges", forSegment: 1)
        for c in [zoom, fit, mode] as [NSControl] { c.controlSize = .small; c.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        fit.bezelStyle = .accessoryBarAction
        let bar = NSStackView(views: [zoom, fit, mode])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        bar.frame.size = bar.fittingSize
        let acc = NSTitlebarAccessoryViewController()
        acc.view = bar
        acc.layoutAttribute = .trailing
        w.addTitlebarAccessoryViewController(acc)
        zoomControl = zoom; fitButton = fit; modeControl = mode
        view.zoomKeys = native
        updateZoomControls()
    }

    @objc func modeChosen(_ c: NSSegmentedControl) {
        native = c.selectedSegment == 1
        view.zoomKeys = native
        view.setZoom(nil)
        updateZoomControls()
        sendShape()
    }

    @objc func zoomChosen(_ c: NSSegmentedControl) {
        switch c.selectedSegment {
        case 0: view.zoomStep(-1)
        case 1: view.setZoom(1)
        default: view.zoomStep(1)
        }
    }

    @objc func zoomFit() { view.setZoom(nil) }

    func updateZoomControls() {
        zoomControl?.isEnabled = native
        fitButton?.isEnabled = native
        modeControl?.selectedSegment = native ? 1 : 0
        updateTitle()
    }

    /// Opened, Cmd-Tab, Dock click, Space swipe… whenever this proxy becomes key here, bring the real window
    /// forward on the host, so hover and the first keystroke already land in the right place.
    func windowDidBecomeKey(_ n: Notification) { wire?.send(Msg("focus")) }

    /// Fully hidden (minimized, another Space, covered, app hidden) → host stops encoding this window.
    func windowDidChangeOcclusionState(_ n: Notification) { sendVisibility() }

    func sendVisibility() {
        var m = Msg("visible"); m.down = window?.occlusionState.contains(.visible) ?? true
        if ProcessInfo.processInfo.environment["HITHER_TEST_HIDE"] != nil { log("visible=\(m.down!)") }
        wire?.send(m)
    }

    /// Only the window that plays the app's sound needs it: the host stops sending it to the others.
    func sendAudioOwner() {
        var m = Msg("audio"); m.down = AudioOut.shared.owns(ObjectIdentifier(self))
        wire?.send(m)
    }

    func windowWillClose(_ n: Notification) { window = nil; finish() }

    func finish() {
        done = true
        activeWire.withLock { $0 = nil }
        wire?.close()
        link?.stop(); link = nil
        window?.delegate = nil
        window?.close()
        window = nil
        proxies.removeAll { $0 === self }
        let next = proxies.first { $0.window != nil }
        AudioOut.shared.release(ObjectIdentifier(self), next: next.map(ObjectIdentifier.init))
        next?.sendAudioOwner()
        if proxies.isEmpty && role != "launcher" { NSApp.terminate(nil) }
    }
}

// MARK: - the remote app's menu bar

final class RemoteMenu: NSMenu { var path: [Int] = [] }

/// Mirrors the host app's menu bar into this proxy app's own. Each menu is fetched when it opens, so enabled
/// states / checkmarks / Open Recent are current; choosing an item presses the real one on the host.
final class RemoteMenus: NSObject, NSMenuDelegate {
    static let shared = RemoteMenus()
    let lock = NSLock()

    override init() {
        super.init()
        // apps change their top-level menus now and then; refresh whenever this proxy comes forward
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.install()
        }
    }
    var waiting: [UInt32: DispatchSemaphore] = [:], replies: [UInt32: [MenuEntry]] = [:]
    var nextSeq: UInt32 = 0

    /// The proxy window whose connection carries menu traffic: the key one, so presses act on the window you're in.
    var link: ProxyWindow? { proxies.first { $0.window?.isKeyWindow == true } ?? proxies.first { $0.window != nil } }

    /// Blocking round trip (menus must be filled before they show). Replies arrive on the wire queue via deliver().
    func fetch(_ path: [Int]) -> [MenuEntry]? {
        guard let wire = link?.wire else { return nil }
        let sem = DispatchSemaphore(value: 0)
        lock.lock(); nextSeq += 1; let seq = nextSeq; waiting[seq] = sem; lock.unlock()
        var m = Msg("menu"); m.path = path; m.seq = seq
        wire.send(m)
        let ok = sem.wait(timeout: .now() + 0.5) == .success
        lock.lock(); defer { lock.unlock() }
        waiting[seq] = nil
        return ok ? replies.removeValue(forKey: seq) : nil
    }

    func deliver(_ m: Msg) {
        lock.lock(); defer { lock.unlock() }
        guard let seq = m.seq, let sem = waiting[seq] else { return }
        replies[seq] = m.menu ?? []
        sem.signal()
    }

    /// Top level: the host's bar minus its Apple menu. The first item becomes our app menu (shown as "Cursor · mini").
    /// A desktop has no app of its own over there (its menu bar is in the picture): it gets an Edit menu here just for
    /// the clipboard items.
    func install() {
        guard let bar = fetch([]) else { return }
        let main = NSMenu()
        if bar.count > 1 {
            for (i, e) in bar.enumerated() where i > 0 {
                let item = main.addItem(withTitle: e.title, action: nil, keyEquivalent: "")
                item.submenu = submenu(e.title, [i])
            }
        } else if link?.isDesktop == true {
            main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = NSMenu()   // the app menu
            let edit = NSMenu(title: "Edit")
            edit.delegate = self
            main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        } else { return }
        NSApp.mainMenu = main
    }

    /// Send/Get Clipboard, for the window you're in. The keys themselves are caught by StreamView.
    func addClipboardItems(to menu: NSMenu) {
        guard let p = link else { return }
        let name = macName(p.host)
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        for (title, key, action) in [("Send Clipboard to \(name)", "c", #selector(ProxyWindow.sendClipboard)),
                                     ("Get Clipboard from \(name)", "v", #selector(ProxyWindow.getClipboard))] {
            let mi = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            mi.keyEquivalentModifierMask = clipMods
            mi.target = p
        }
    }

    func submenu(_ title: String, _ path: [Int]) -> RemoteMenu {
        let m = RemoteMenu(title: title)
        m.path = path
        m.delegate = self
        m.autoenablesItems = false
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let menu = menu as? RemoteMenu else {   // a desktop's own Edit menu
            menu.removeAllItems()
            return addClipboardItems(to: menu)
        }
        guard let entries = fetch(menu.path) else { return }
        menu.removeAllItems()
        for (j, e) in entries.enumerated() {
            if e.title.isEmpty { menu.addItem(.separator()); continue }
            // shortcuts are shown for reference; the key press itself still goes straight to the remote app
            // (chords like "⌃K ⌃O" can't be shown as a single key equivalent, so they're left off)
            let item = menu.addItem(withTitle: e.title, action: e.sub ? nil : #selector(pick(_:)),
                                    keyEquivalent: e.key.count == 1 ? e.key.lowercased() : "")
            item.target = self
            item.keyEquivalentModifierMask = [e.mods & 8 == 0 ? .command : [], e.mods & 1 != 0 ? .shift : [],
                                              e.mods & 2 != 0 ? .option : [], e.mods & 4 != 0 ? .control : [],
                                              e.mods & 16 != 0 ? .function : []]
            item.isEnabled = e.enabled
            item.state = e.checked ? .on : .off
            item.representedObject = menu.path + [j]
            if e.sub { item.submenu = submenu(e.title, menu.path + [j]) }
        }
        if menu.path.count == 1, menu.title == "Edit" { addClipboardItems(to: menu) }
    }

    @objc func pick(_ sender: NSMenuItem) {
        let win = NSApp.keyWindow
        // window-management items are about this proxy window, not the host's
        switch sender.title {
        case "Minimize": win?.miniaturize(nil)
        case "Zoom": win?.zoom(nil)
        case "Enter Full Screen", "Exit Full Screen", "Toggle Full Screen": win?.toggleFullScreen(nil)
        case "Hide Others": NSApp.hideOtherApplications(nil)
        case "Show All": NSApp.unhideAllApplications(nil)
        case "Hide \(link?.appName ?? "")": NSApp.hide(nil)
        default:
            var m = Msg("press"); m.path = sender.representedObject as? [Int]
            link?.wire?.send(m)
        }
    }
}

/// One window row in the menu bar list: looks like a normal item, with an X that closes that remote window.
final class CloseRow: NSView {
    var hot = false
    var lit = false
    override var isOpaque: Bool { false }
    override var allowsVibrancy: Bool { true }
    var closeRect: NSRect { NSRect(x: bounds.width - 34, y: 0, width: 34, height: bounds.height) }
    var glyphRect: NSRect { NSRect(x: bounds.width - 26, y: (bounds.height - 11) / 2, width: 11, height: 11) }

    override func draw(_ dirtyRect: NSRect) {
        guard let item = enclosingMenuItem else { return }
        let on = item.isHighlighted
        if on {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let font = NSFont.menuFont(ofSize: 0)
        var x = 14 + CGFloat(item.indentationLevel) * 12
        if let image = item.image {
            image.draw(in: NSRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16))
            x += 22
        }
        let shown = NSMutableAttributedString(attributedString: item.attributedTitle ?? NSAttributedString(string: item.title))
        let full = NSRange(location: 0, length: shown.length)
        if full.length > 0 {
            shown.addAttribute(.font, value: font, range: full)
            if on {
                shown.addAttribute(.foregroundColor, value: NSColor.selectedMenuItemTextColor, range: full)
            } else {
                var bare: [NSRange] = []
                shown.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in if value == nil { bare.append(range) } }
                for range in bare { shown.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range) }
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            shown.addAttribute(.paragraphStyle, value: style, range: full)
            shown.draw(with: NSRect(x: x, y: 3, width: max(0, glyphRect.minX - 8 - x), height: 18),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        let tint: NSColor = hot ? .systemRed : (on ? .selectedMenuItemTextColor : .secondaryLabelColor)
        let mark = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))!
        (mark.withSymbolConfiguration(.init(paletteColors: [tint])) ?? mark).draw(in: glyphRect)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let on = closeRect.contains(convert(event.locationInWindow, from: nil))
        let hi = enclosingMenuItem?.isHighlighted == true
        if on != hot || hi != lit { hot = on; lit = hi; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { if hot { hot = false; needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, let launcher = item.target as? Launcher else { return }
        if closeRect.contains(convert(event.locationInWindow, from: nil)) {
            DispatchQueue.main.async { [weak launcher] in launcher?.closeWindow(item) }   // hide after this click finishes
            return
        }
        item.menu?.cancelTracking()
        if let r = item.representedObject as? Row { launcher.openItem(r.item, on: r.mac) }
    }
}

// MARK: - launcher (menu bar)

/// What a row in the menu opens: a window on one of the paired Macs (id 0: the app's main window).
struct Row { let item: Item; let mac: Remote }

/// A row in the Video Codec submenu: that Mac's encoder choice.
struct CodecPick { let mac: Remote; let codec: String }

/// One paired Mac in the menu: a long-lived control connection that lists its windows and apps (each menu open asks
/// for a fresh list), and the loopback relay its proxies reach it through. All but the relay runs on the main queue.
final class Remote {
    private(set) var peer: Peer
    var name: String { peer.name }
    unowned let launcher: Launcher
    let relayPeer: OSAllocatedUnfairLock<Peer>   // read on the relay queue
    var attempt = 0   // the control connection tries the peer's names (Reach.hosts) in turn
    var host = ""     // the name or address the control connection last dialed: file copies go there too
    var wire: Wire?
    var items: [Item] = []
    var state = "connecting…"
    var codec = "h264"   // the host's current video codec (from its "windows" replies)
    var dark = false     // Keep Screen Dark is on over there (from its "windows" replies)
    var relay: NWListener?, videoRelay: NWListener?
    let relayHost = OSAllocatedUnfairLock<NWEndpoint.Host?>(initialState: nil)   // where the byte pipe last reached the host
    var gone = false   // unpaired

    init(_ peer: Peer, launcher: Launcher) {
        self.peer = peer
        self.launcher = launcher
        relayPeer = OSAllocatedUnfairLock(initialState: peer)
        startRelay()
        refresh()
    }

    /// Paired again: a new key, so hang up and connect with it.
    func repaired(_ p: Peer) {
        peer = p
        relayPeer.withLock { $0 = p }
        wire?.close()
        wire = nil
        refresh()
    }

    func stop() {
        gone = true
        wire?.close()
        wire = nil
        relay?.cancel()
        videoRelay?.cancel()
        try? FileManager.default.removeItem(at: relayPortFile(name))
        try? FileManager.default.removeItem(at: videoRelayPortFile(name))
    }

    func refresh() {
        guard !gone else { return }
        if wire == nil {
            let peer = peer, hosts = Reach.hosts(peer), host = hosts[attempt % hosts.count]
            let w = dial(host), me = ObjectIdentifier(w)
            self.host = host
            w.onClose = { [weak self] in
                onMain { [weak self] in
                    guard let self, let cur = wire, ObjectIdentifier(cur) == me else { return }   // already replaced (re-paired)
                    wire = nil
                    attempt += 1
                    let triedAll = attempt % hosts.count == 0
                    if triedAll { state = "can't reach \(peer.name)"; launcher.rebuild() }
                    // keep trying: the Mac may be asleep or out of reach, or this is the Local Network race after login
                    DispatchQueue.main.asyncAfter(deadline: .now() + (triedAll ? 3 : 0.2)) { [weak self] in
                        if self?.wire == nil { self?.refresh() }
                    }
                }
            }
            w.onMsg = { [weak self] m in
                onMain { [weak self] in
                    guard let self, !gone else { return }
                    switch m.t {
                    case "windows": Reach.worked(host, for: peer); codec = m.codec ?? "h264"; dark = m.dark ?? false; update(m.items ?? [])
                    case "apps": launcher.makeProxies(m.items ?? [], on: self)
                    case "appeared": launcher.appeared(m.items ?? [], on: self)
                    case "clipset": launcher.flash("Sent \(m.text ?? "clipboard") to \(name)")
                    case "cliperr": launcher.flash(m.text ?? "Couldn't get \(name)'s clipboard")
                    default: break
                    }
                }
            }
            w.onClip = { [weak self] d in
                onMain { [weak self] in
                    guard let self, !gone else { return }
                    let launcher = launcher
                    if let s = receivedClipboard(d, from: self.host, status: { _, _ in }) { launcher.flash(s) }
                }
            }
            wire = w
            w.start()
            w.send(Msg("apps"))   // every (re)connect: a proxy per installed app, so Spotlight finds "Xcode · mini"
            w.send(Msg("watch"))  // …and new windows over there (Cmd-N, launched apps) open here by themselves
            Reach.giveUpLater(on: w)
        }
        wire?.send(Msg("list"))
    }

    func update(_ new: [Item]) {
        for i in new { if let icon = i.icon { launcher.icons[i.bundle] = icon } }
        items = new
        state = ""
        launcher.rebuild()
    }

    /// Loopback-only byte pipe: proxy ⇄ launcher ⇄ host. Keeps the per-app Local Network prompt away. Each paired Mac
    /// has its own, on a port written to ~/.hither for that Mac's proxies to find.
    func startRelay() {
        let q = DispatchQueue(label: "relay")
        let params = NWParameters(tls: nil, tcp: tcpOptions())
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: .any) else { return log("relay for \(name): no port") }
        l.newConnectionHandler = { [relayPeer, relayHost] local in
            let peer = relayPeer.withLock { $0 }
            local.start(queue: q)   // nothing is read from it until the host end is up
            connectFirst(Reach.hosts(peer), queue: q) { remote in
                guard let remote else { log("relay: can't reach \(peer.name)"); return local.cancel() }
                if case .hostPort(let h, _) = remote.endpoint { relayHost.withLock { $0 = h } }
                var finishedDirections = 0   // both pipe callbacks run on q
                let finished: () -> Void = {
                    finishedDirections += 1
                    if finishedDirections == 2 {
                        q.asyncAfter(deadline: .now() + 2) { local.cancel(); remote.cancel() }
                    }
                }
                for c in [local, remote] {
                    c.stateUpdateHandler = { s in
                        switch s {
                        case .failed, .cancelled, .waiting: local.cancel(); remote.cancel()
                        default: break
                        }
                    }
                }
                switch local.state {   // the proxy may have gone away meanwhile
                case .failed, .cancelled: return remote.cancel()
                default: break
                }
                pipe(local, remote, onEOF: finished)
                pipe(remote, local, onEOF: finished)
            }
        }
        let file = relayPortFile(name)
        l.stateUpdateHandler = { [weak l] s in
            switch s {
            case .ready: if let p = l?.port { try? Data("\(p.rawValue)".utf8).write(to: file, options: .atomic) }
            case .failed(let e): log("relay: \(e)")
            default: break
            }
        }
        l.start(queue: q)
        relay = l
        startVideoRelay(q)
    }

    /// The same for video datagrams: each proxy's flow gets one of its own to the host, at the address the byte pipe
    /// last reached it on. Sealed end to end like TLS, so the relay only forwards. A flow quiet for 15 s is let go.
    func startVideoRelay(_ q: DispatchQueue) {
        let params = NWParameters.udp
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: .any) else { return log("video relay for \(name): no port") }
        l.newConnectionHandler = { [relayHost] local in
            guard let host = relayHost.withLock({ $0 }) else { return local.cancel() }
            let remote = NWConnection(host: host, port: videoPort, using: .udp)
            var heard = CACurrentMediaTime()   // on q
            local.start(queue: q); remote.start(queue: q)
            forward(local, to: remote) { heard = CACurrentMediaTime() }
            forward(remote, to: local) { heard = CACurrentMediaTime() }
            func idle() {
                guard CACurrentMediaTime() - heard < 15 else { local.cancel(); remote.cancel(); return }
                q.asyncAfter(deadline: .now() + 5, execute: idle)
            }
            idle()
        }
        let file = videoRelayPortFile(name)
        l.stateUpdateHandler = { [weak l] s in
            switch s {
            case .ready: if let p = l?.port { try? Data("\(p.rawValue)".utf8).write(to: file, options: .atomic) }
            case .failed(let e): log("video relay: \(e)")
            default: break
            }
        }
        l.start(queue: q)
        videoRelay = l
    }
}

func forward(_ from: NWConnection, to: NWConnection, heard: @escaping () -> Void) {
    from.receiveMessage { d, _, _, err in
        if let d { to.send(content: d, completion: .idempotent); heard() }
        if err == nil { forward(from, to: to, heard: heard) } else { from.cancel(); to.cancel() }
    }
}

final class Launcher: NSObject, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var remotes: [Remote] = []   // the paired Macs whose windows this menu shows (iPhones only view)
    var nearby: [(id: String, name: String, endpoint: NWEndpoint)] = []   // other Macs running Hither (Bonjour)
    var pairListener: NWListener?
    var browser: NWBrowser?
    var pairing: PairSession?
    var asking = false   // a pairing code alert is up
    var pairingHost: String?   // what "Pair with a Mac at an address" is dialling
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var icons: [String: Data] = [:]
    let buildQ = DispatchQueue(label: "proxies")   // all proxy-bundle writes, in order
    var flashing: String?   // a passing status, shown instead of a copy's percentage for a few seconds
    var copyRows: [ObjectIdentifier: (heading: NSMenuItem, detail: NSMenuItem)] = [:]   // updated in place as copies move on

    func start() {
        status.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Hither")
        status.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)   // "↓51%" doesn't jiggle
        menu.delegate = self
        FileCopy.changed = { [weak self] in self?.copyChanged($0) }
        UNUserNotificationCenter.current().delegate = self
        status.menu = menu
        icons[desktopApp] = NSImage(systemSymbolName: "display", accessibilityDescription: "Desktop").flatMap(desktopIcon)
        remotes = Pairings.load().peers.filter { $0.viewer != true }.map { Remote($0, launcher: self) }
        rebuild()
        startPairing()
    }

    // MARK: pairing

    /// Always listening (and advertised) so the other Mac can start pairing; nothing is stored until you click Pair here.
    func startPairing() {
        if let l = try? NWListener(using: NWParameters(tls: nil, tcp: tcpOptions()), on: pairPort) {
            l.service = service()
            l.newConnectionHandler = { [weak self] c in
                guard let self, pairing == nil else { return c.cancel() }   // one at a time
                begin(PairSession(c, initiator: false))
            }
            l.stateUpdateHandler = { if case .failed(let e) = $0 { log("pairing: \(e)") } }
            l.start(queue: .main)
            pairListener = l
        } else {
            log("pairing: port \(pairPort) busy")
        }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let me = Pairings.load().id
            var seen = Set<String>()
            self?.nearby = results.compactMap { r in
                guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata,
                      let id = txt["id"], id != me, seen.insert(id).inserted else { return nil }
                return (id, name, r.endpoint)
            }.sorted { $0.name < $1.name }
            self?.rebuild()
        }
        b.start(queue: .main)
        browser = b
    }

    /// Bonjour: who this Mac is, and whether it shares its windows (an iPhone only offers Macs that do).
    func service() -> NWListener.Service {
        NWListener.Service(name: localName(), type: serviceType, txtRecord: NWTXTRecord(["id": Pairings.load().id, "shares": sharing ? "1" : "0"]))
    }

    @objc func pairWith(_ sender: NSMenuItem) {
        guard pairing == nil, nearby.indices.contains(sender.tag) else { return }
        let c = NWConnection(to: nearby[sender.tag].endpoint, using: NWParameters(tls: nil, tcp: tcpOptions()))
        begin(PairSession(c, initiator: true))
    }

    /// A Mac Bonjour can't see (another network, over Tailscale): pair by its name or IP. Hither must be running
    /// there, and someone has to click Pair on its screen too (Screen Sharing will do).
    @objc func pairByAddress() {
        guard pairing == nil else { return }
        let a = NSAlert()
        a.messageText = "Pair with a Mac at an address"
        a.informativeText = "Its Tailscale name (like mini-pb) or IP address. Hither must be running on that Mac, "
            + "and you'll compare a code on both screens."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "mini-pb or 100.x.y.z"
        a.accessoryView = field
        a.addButton(withTitle: "Pair")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate()
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        pairingHost = host
        begin(PairSession(NWConnection(host: NWEndpoint.Host(host), port: pairPort, using: NWParameters(tls: nil, tcp: tcpOptions())),
                          initiator: true))
    }

    func begin(_ s: PairSession) {
        pairing = s
        s.confirm = { [weak self] code, name, answer in self?.confirmCode(code, name, answer) }
        s.onDone = { [weak self] p in self?.paired(p, s) }
        s.start()
    }

    func confirmCode(_ code: String, _ name: String, _ answer: @escaping (Bool) -> Void) {
        let viewer = pairing?.theyView == true
        DispatchQueue.main.async {   // after any open menu closes
            let a = NSAlert()
            a.messageText = "Pair with \(name)?"
            a.informativeText = viewer
                ? "Check that \(name) shows the same code, then click Pair here and tap Pair on \(name). "
                    + "\(name) will be able to open and control this Mac's apps."
                : "Check that \(name) shows the same code, then click Pair on both Macs. "
                    + "Paired Macs can open and control each other's apps."
            let label = NSTextField(labelWithString: code)
            label.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
            label.sizeToFit()
            a.accessoryView = label
            a.addButton(withTitle: "Pair")
            a.addButton(withTitle: "Cancel")
            NSApp.activate()
            self.asking = true
            let r = a.runModal()
            self.asking = false
            answer(r == .alertFirstButtonReturn)
        }
    }

    func paired(_ p: Peer?, _ s: PairSession) {
        pairing = nil
        let byAddress = pairingHost
        pairingHost = nil
        if asking { NSApp.abortModal() }   // the other side cancelled or went away
        guard let p else {
            if s.initiator, var why = s.failure {
                if let byAddress, !s.reachedPeer {
                    why = "Couldn't reach Hither on \(byAddress). Check that it's running there and that the Mac's "
                        + "firewall lets Hither in."
                }
                let a = NSAlert()
                a.messageText = "Couldn't pair"
                a.informativeText = why
                NSApp.activate()
                a.runModal()
            }
            return
        }
        var all = Pairings.load()
        // a Mac's name is its host name, so a re-paired Mac replaces its old entry; iPhones are all called "iPhone"
        all.peers.removeAll { $0.id == p.id || (p.viewer != true && $0.name == p.name) }
        all.peers.append(p)
        all.save()
        log("paired with \(p.name)")
        restartHost()   // it only lets in devices it knew about when it started
        if p.viewer != true {
            if let mac = remotes.first(where: { $0.peer.id == p.id || $0.name == p.name }) {
                mac.repaired(p)
            } else {
                remotes.append(Remote(p, launcher: self))
            }
        }
        rebuild()
    }

    /// A Mac or an iPhone. Either can no longer connect once the host restarts without its key.
    @objc func unpair(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var all = Pairings.load()
        all.peers.removeAll { $0.id == id }
        all.save()
        restartHost()
        remotes.filter { $0.peer.id == id }.forEach { $0.stop() }
        remotes.removeAll { $0.peer.id == id }
        rebuild()
    }

    func menuWillOpen(_ m: NSMenu) { remotes.forEach { $0.refresh() } }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        menu.items.forEach { $0.view?.needsDisplay = true }
    }

    func makeProxies(_ apps: [Item], on mac: Remote) {
        for a in apps { if let icon = a.icon { icons[a.bundle] = icon } }
        let host = mac.name   // proxies reach it through its relay, by name
        buildQ.async {
            let made = apps.filter { (try? self.ensureProxy($0, icon: $0.icon, host: host))?.2 == true }.count
            log("proxies: \(apps.count) apps on \(host), \(made) created/updated")
        }
        rebuild()
    }

    // MARK: menu

    func rebuild() {
        menu.removeAllItems()
        copyRows = [:]
        for c in FileCopy.running {   // copies under way, at the top: what, how far, and a way out
            let h = menu.addItem(withTitle: c.heading, action: nil, keyEquivalent: "")
            let d = menu.addItem(withTitle: c.detail, action: nil, keyEquivalent: "")
            h.isEnabled = false; d.isEnabled = false; d.indentationLevel = 1
            let x = menu.addItem(withTitle: "Cancel", action: #selector(cancelCopy(_:)), keyEquivalent: "")
            x.target = self; x.representedObject = c; x.indentationLevel = 1
            copyRows[ObjectIdentifier(c)] = (h, d)
        }
        if !FileCopy.running.isEmpty { menu.addItem(.separator()) }
        if remotes.isEmpty { menu.addItem(withTitle: "Not paired", action: nil, keyEquivalent: "").isEnabled = false }
        for (n, mac) in remotes.enumerated() {
            if n > 0 { menu.addItem(.separator()) }
            section(mac)
        }
        // Macs nearby that aren't paired yet; ones elsewhere pair by address (in the footer)
        let paired = Set(remotes.map(\.peer.id))
        let unpaired = nearby.indices.filter { !paired.contains(nearby[$0].id) }
        if remotes.isEmpty && unpaired.isEmpty {
            menu.addItem(withTitle: "Looking for Macs running Hither…", action: nil, keyEquivalent: "").isEnabled = false
        }
        if !remotes.isEmpty && !unpaired.isEmpty { menu.addItem(.separator()) }
        for i in unpaired {
            let mi = menu.addItem(withTitle: "Pair with \(nearby[i].name)…", action: #selector(pairWith(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
        }
        footer()
    }

    /// One paired Mac: its windows, then what to do with it.
    func section(_ mac: Remote) {
        let header = mac.state.isEmpty ? "On \(mac.name)" + (mac.dark ? " · dark" : "") : "\(mac.name): \(mac.state)"
        menu.addItem(withTitle: header, action: nil, keyEquivalent: "").isEnabled = false
        add("Desktop", Row(item: Item(id: 0, app: "Desktop", bundle: desktopApp, title: ""), mac: mac), indent: 0).image = icon(desktopApp)
        var apps: [String] = []
        for i in mac.items where !apps.contains(i.bundle) { apps.append(i.bundle) }
        for b in apps {
            let wins = mac.items.filter { $0.bundle == b }
            if wins.count == 1 {   // one row: "App  window title"
                let w = wins[0], mi = add(w.app, Row(item: w, mac: mac), indent: 0)
                mi.image = icon(b)
                if !w.title.isEmpty && w.title != w.app {
                    let t = NSMutableAttributedString(string: w.app + "  ")
                    t.append(NSAttributedString(string: w.title, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
                    mi.attributedTitle = t
                }
                pinClose(mi)
            } else {   // app row opens its main window; window rows open that exact window
                add(wins[0].app, Row(item: Item(id: 0, app: wins[0].app, bundle: b, title: ""), mac: mac), indent: 0).image = icon(b)
                for w in wins { pinClose(add(w.title.isEmpty ? "Untitled" : w.title, Row(item: w, mac: mac), indent: 1)) }
            }
        }
        let recentItem = menu.addItem(withTitle: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu(), recent = recent(on: mac)
        for r in recent { add(r.app, Row(item: r, mac: mac), indent: 0, to: sub).image = icon(r.bundle) }
        recentItem.submenu = sub
        recentItem.isEnabled = !recent.isEmpty
        // everything else about that Mac, out of the way of its windows
        let more = NSMenu()
        menu.addItem(withTitle: mac.name, action: nil, keyEquivalent: "").submenu = more
        let item = { (title: String, action: Selector, tip: String?) -> NSMenuItem in
            let mi = more.addItem(withTitle: title, action: action, keyEquivalent: "")
            mi.target = self
            mi.representedObject = mac
            mi.toolTip = tip
            return mi
        }
        _ = item("Send Clipboard to \(mac.name)", #selector(sendClipboard(_:)), "Puts what you copied here on \(mac.name)'s clipboard, ready to paste there.")
        _ = item("Get Clipboard from \(mac.name)", #selector(getClipboard(_:)), "Puts what you copied on \(mac.name) on this Mac's clipboard.")
        more.addItem(.separator())
        // what someone at that Mac sees: black while you use it, and locked once you're done
        item("Keep Screen Dark", #selector(toggleDark(_:)),
             "While you use \(mac.name) from here, its own monitors show black, and it locks 2 minutes after you stop.").state = mac.dark ? .on : .off
        _ = item("Lock \(mac.name)", #selector(lockMac(_:)), nil)
        more.addItem(.separator())
        let codecItem = more.addItem(withTitle: "Video Codec", action: nil, keyEquivalent: "")
        let codecs = NSMenu()
        for (title, id) in [("H.264", "h264"), ("HEVC", "hevc"), ("HEVC 4:2:2 (sharpest color)", "hevc422")] {
            let mi = codecs.addItem(withTitle: title, action: #selector(setCodec(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = CodecPick(mac: mac, codec: id)
            mi.state = mac.codec == id ? .on : .off
        }
        codecItem.submenu = codecs
        _ = item("Screen Share \(mac.name)…", #selector(screenShare(_:)), nil)   // Apple's own, for when you want it
        more.addItem(.separator())
        item("Unpair \(mac.name)", #selector(unpair(_:)), nil).representedObject = mac.peer.id
    }

    /// Settings that rarely change, in one submenu. Nothing paired yet: pairing by address stays in sight.
    func footer() {
        menu.addItem(.separator())
        if remotes.isEmpty { menu.addItem(withTitle: "Pair with Mac at Address…", action: #selector(pairByAddress), keyEquivalent: "").target = self }
        let settings = NSMenu()
        menu.addItem(withTitle: "Settings", action: nil, keyEquivalent: "").submenu = settings
        settings.addItem(withTitle: "Pair with Mac at Address…", action: #selector(pairByAddress), keyEquivalent: "").target = self
        for v in Pairings.load().peers where v.viewer == true {
            let mi = settings.addItem(withTitle: "Unpair \(v.name)", action: #selector(unpair(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = v.id
        }
        settings.addItem(.separator())
        let share = settings.addItem(withTitle: "Share This Mac", action: #selector(toggleSharing), keyEquivalent: "")
        share.target = self
        share.state = sharing ? .on : .off
        let login = settings.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit Hither", action: #selector(quit), keyEquivalent: "q").target = self
    }

    func icon(_ bundle: String) -> NSImage? {
        icons[bundle].flatMap(NSImage.init(data:)).map { $0.size = NSSize(width: 16, height: 16); return $0 }
    }

    @discardableResult func add(_ title: String, _ row: Row, indent: Int, to m: NSMenu? = nil) -> NSMenuItem {
        let mi = (m ?? menu).addItem(withTitle: title, action: #selector(open(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = row
        mi.indentationLevel = indent
        return mi
    }

    /// X on a real window (not the app header, which has no single window, and not Recent). Clicking the row still opens it.
    func pinClose(_ mi: NSMenuItem) {
        guard (mi.representedObject as? Row)?.item.id != 0 else { return }
        let font = NSFont.menuFont(ofSize: 0)
        let text = mi.attributedTitle?.string ?? mi.title
        let textW = (text as NSString).size(withAttributes: [.font: font]).width
        let width = 14 + CGFloat(mi.indentationLevel) * 12 + (mi.image == nil ? 0 : 22) + textW + 40
        let view = CloseRow(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        view.autoresizingMask = [.width]
        mi.view = view
    }

    /// Close that window on the host and drop the row. The menu stays open so several can go in one pass.
    /// A window that refuses (a save sheet) is still there the next time the menu opens.
    @objc func closeWindow(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Row, row.item.id != 0, let wire = row.mac.wire else { return }
        let w = row.item, mac = row.mac
        var m = Msg("close"); m.k = w.id
        wire.send(m)
        mac.items.removeAll { $0.id == w.id }
        sender.isHidden = true
        guard !mac.items.contains(where: { $0.bundle == w.bundle && $0.id != 0 }), let menu = sender.menu else { return }
        for item in menu.items {
            if let r = item.representedObject as? Row, r.mac === mac, r.item.bundle == w.bundle { item.isHidden = true }
        }
    }

    /// Apps opened through Hither on `mac`, newest first (launching one that isn't running starts it on the host).
    /// Entries from before there could be more than one Mac belong to the first.
    func recent(on mac: Remote) -> [Item] {
        recentEntries.compactMap { d in
            guard let bundle = d["bundle"], d["host"].map({ $0 == mac.name }) ?? (mac === remotes.first) else { return nil }
            return Item(id: 0, app: d["app"] ?? bundle, bundle: bundle, title: "")
        }
    }

    var recentEntries: [[String: String]] { UserDefaults.standard.array(forKey: "recent") as? [[String: String]] ?? [] }

    func remember(_ w: Item, on mac: Remote) {
        let others = recentEntries.filter { $0["bundle"] != w.bundle || ($0["host"] ?? remotes.first?.name) != mac.name }
        let r = [["bundle": w.bundle, "app": w.app, "host": mac.name]] + others.prefix(19)
        UserDefaults.standard.set(r, forKey: "recent")
    }

    /// A new window appeared on the host because of something done through a proxy: open it like a local app would.
    func appeared(_ new: [Item], on mac: Remote) {
        for i in new {
            if let icon = i.icon { icons[i.bundle] = icon }
            openItem(i, on: mac)
        }
    }

    @objc func open(_ sender: NSMenuItem) {
        if let r = sender.representedObject as? Row { openItem(r.item, on: r.mac) }
    }

    func openItem(_ w: Item, on mac: Remote) {
        if w.bundle != desktopApp { remember(w, on: mac) }   // Recent is for apps; Desktop is always at the top
        let icon = icons[w.bundle], host = mac.name
        buildQ.async {   // same queue as the bulk proxy build, so they never write one bundle at once
            do {
                let (url, id, _) = try self.ensureProxy(w, icon: icon, host: host)
                DispatchQueue.main.async {
                    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                        NSApp.yieldActivation(to: running)
                        DistributedNotificationCenter.default().postNotificationName(openNote, object: id, userInfo: ["window": w.id], deliverImmediately: true)
                    } else {
                        let cfg = NSWorkspace.OpenConfiguration()
                        cfg.arguments = ["--window", String(w.id)]
                        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, e in if let e { log("launch \(url.lastPathComponent): \(e)") } }
                    }
                }
            } catch {
                log("proxy for \(w.app): \(error)")
            }
        }
        rebuild()
    }

    /// ~/Applications/Hither/<App> · <host>.app — a tiny bundle around this same binary, so the remote app
    /// gets its own name + icon in the Dock, Cmd-Tab and Spotlight. Rebuilt when this binary changes (unless running).
    /// Returns (bundle URL, bundle id, whether it was (re)built). Runs on buildQ.
    func ensureProxy(_ w: Item, icon: Data?, host: String) throws -> (URL, String, Bool) {
        let fm = FileManager.default
        let id = "dev.hither.proxy.\(short(host)).\(w.bundle)".filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let name = "\(w.app) · \(short(host))"
        let dir = fm.homeDirectoryForCurrentUser.appending(path: "Applications/Hither")
        // reuse an existing bundle for this id even if the app's display name differs between sources
        let url = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).first { $0.path.hasPrefix(dir.path) }
            ?? dir.appending(path: "\(name.replacingOccurrences(of: "/", with: "-")).app")
        let exe = url.appending(path: "Contents/MacOS/hither")
        let mtime = { (u: URL) in try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        if let theirs = mtime(exe), let mine = mtime(Bundle.main.executableURL!),
           theirs >= mine || !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty { return (url, id, false) }

        try? fm.removeItem(at: url)
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: Bundle.main.executableURL!, to: exe)   // APFS clone: ~no disk space per proxy
        var plist: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleExecutable": "hither", "CFBundlePackageType": "APPL", "NSHighResolutionCapable": true,
            "HitherRole": "proxy", "HitherHost": host, "HitherApp": w.bundle,
        ]
        if let icon, writeICNS(icon, to: url.appending(path: "Contents/Resources/AppIcon.icns")) {
            plist["CFBundleIconFile"] = "AppIcon"
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appending(path: "Contents/Info.plist"))
        run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])   // ad-hoc: proxies need no permissions of their own
        LSRegisterURL(url as CFURL, true)
        return (url, id, true)
    }

    /// Applies to every open window from that Mac at once (it swaps encoders); remembered there for new ones.
    @objc func setCodec(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? CodecPick else { return }
        pick.mac.codec = pick.codec
        rebuild()
        pick.mac.refresh()
        var m = Msg("codec"); m.codec = pick.codec
        pick.mac.wire?.send(m)
    }

    @objc func toggleDark(_ sender: NSMenuItem) {
        guard let mac = sender.representedObject as? Remote else { return }
        mac.dark.toggle()
        rebuild()
        var m = Msg("dark"); m.dark = mac.dark
        mac.wire?.send(m)
    }

    @objc func sendClipboard(_ sender: NSMenuItem) {
        guard let mac = sender.representedObject as? Remote else { return }
        if let why = pushClipboard(over: mac.wire, to: mac.host, status: { _, _ in }) { flash(why) }
    }

    @objc func getClipboard(_ sender: NSMenuItem) {
        guard let mac = sender.representedObject as? Remote else { return }
        guard let wire = mac.wire else { return flash("Not connected to \(mac.name)") }
        wire.send(Msg("clipget"))
    }

    /// A passing status next to the menu bar icon ("Got text from mini-pb"), gone after a few seconds.
    func flash(_ s: String) {
        log(s)
        flashing = s
        refreshStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, flashing == s else { return }
            flashing = nil
            refreshStatus()
        }
    }

    /// Next to the icon: a passing status, else how far the file copies are ("↓51%"), else nothing.
    func refreshStatus() {
        var text = flashing ?? ""
        if text.isEmpty, !FileCopy.running.isEmpty {
            let cs = FileCopy.running, done = cs.reduce(0) { $0 + $1.done }, total = cs.reduce(0) { $0 + $1.total }
            let arrow = cs.allSatisfy(\.outgoing) ? "↑" : cs.allSatisfy { !$0.outgoing } ? "↓" : "↕"
            text = arrow + (total > 0 ? "\(done * 100 / total)%" : "…")
        }
        status.button?.title = text.isEmpty ? "" : " " + text
        status.button?.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        status.length = text.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
    }

    /// A file copy started, moved on or ended.
    func copyChanged(_ c: FileCopy) {
        if let r = c.result {
            log(r.text)
            rebuild()
            flash(r.ok ? "✓" : "⚠")
            if !c.cancelled { notify(c, r) }
        } else if let rows = copyRows[ObjectIdentifier(c)] {
            rows.heading.title = c.heading   // updated in place, so an open menu shows it moving
            rows.detail.title = c.detail
            refreshStatus()
        } else {
            rebuild()
            refreshStatus()
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }   // asks once
        }
    }

    @objc func cancelCopy(_ sender: NSMenuItem) { (sender.representedObject as? FileCopy)?.cancel() }

    /// "Got Spock3.app (60.5 MB) from mini-pb: in Downloads and on the clipboard"; clicking it shows the files.
    func notify(_ c: FileCopy, _ r: (ok: Bool, text: String)) {
        let n = UNMutableNotificationContent()
        n.title = r.ok ? "Copy finished" : "Copy \(c.outgoing ? "to" : "from") \(c.name) failed"
        n.body = r.text
        if !c.landed.isEmpty { n.userInfo = ["paths": c.landed.map(\.path)] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
    }

    // A menu-bar app is always "in front": show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let paths = response.notification.request.content.userInfo["paths"] as? [String] {
            let urls = paths.map { URL(fileURLWithPath: $0) }
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
        done()
    }

    @objc func lockMac(_ sender: NSMenuItem) { (sender.representedObject as? Remote)?.wire?.send(Msg("lock")) }

    @objc func screenShare(_ sender: NSMenuItem) {
        guard let mac = sender.representedObject as? Remote, let host = Reach.hosts(mac.peer).first else { return }   // the name that answered last
        NSWorkspace.shared.open(URL(string: "vnc://\(host)")!)
    }

    @objc func quit() {
        DistributedNotificationCenter.default().postNotificationName(quitNote, object: nil, userInfo: nil, deliverImmediately: true)
        NSApp.terminate(nil)
    }

    /// Off: this Mac's windows aren't offered (the host isn't running); the other Mac's are still shown here.
    @objc func toggleSharing() {
        sharing.toggle()
        sharing ? startHost() : stopHost()
        pairListener?.service = service()
        rebuild()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { log("login item: \(error)") }
        rebuild()
    }
}

/// Plain TCP to the host on the first of `hosts` that's up within Reach.patience, trying them in order; nil if none.
func connectFirst(_ hosts: [String], queue q: DispatchQueue, _ done: @escaping (NWConnection?) -> Void) {
    guard let host = hosts.first else { return done(nil) }
    let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcpOptions()))
    var settled = false   // everything here runs on q
    let next = {
        guard !settled else { return }
        settled = true
        c.cancel()
        connectFirst(Array(hosts.dropFirst()), queue: q, done)
    }
    c.stateUpdateHandler = { s in
        switch s {
        case .ready:
            guard !settled else { return }
            settled = true
            done(c)
        case .waiting, .failed: next()
        default: break
        }
    }
    c.start(queue: q)
    q.asyncAfter(deadline: .now() + Reach.patience, execute: next)
}

func pipe(_ from: NWConnection, _ to: NWConnection, onEOF: @escaping () -> Void) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, eof, err in
        if err != nil { from.cancel(); to.cancel(); return }
        if eof {
            // A read can contain the final ciphertext and EOF together. Forward both before cleanup.
            to.send(content: data, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { error in
                if error != nil { from.cancel(); to.cancel() } else { onEOF() }
            })
            return
        }
        if let data, !data.isEmpty { to.send(content: data, completion: .idempotent) }
        pipe(from, to, onEOF: onEOF)
    }
}

/// The Desktop proxy's icon: a display symbol on a plain tile, as PNG (proxies get theirs from PNG data).
func desktopIcon(_ symbol: NSImage) -> Data? {
    let size = NSSize(width: 256, height: 256)
    let img = NSImage(size: size, flipped: false) { r in
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: r.insetBy(dx: 16, dy: 16), xRadius: 48, yRadius: 48).fill()
        let glyph = symbol.withSymbolConfiguration(.init(pointSize: 120, weight: .regular).applying(.init(paletteColors: [.white]))) ?? symbol
        let g = glyph.size
        glyph.draw(in: NSRect(x: (r.width - g.width) / 2, y: (r.height - g.height) / 2, width: g.width, height: g.height))
        return true
    }
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

func writeICNS(_ png: Data, to url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dst, img, nil)
    return CGImageDestinationFinalize(dst)
}

@discardableResult func run(_ tool: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

/// This Mac's own host (sharing its windows) runs as a helper inside our bundle. Started by us it gets our Screen
/// Recording/Accessibility grants, a crash in capture/encode can't take the menu or relay down, and we restart it.
/// It exits when we do. "Share This Mac" off: not running at all.
var hostProcess: Process?
var hostLog: FileHandle?
var sharing = UserDefaults.standard.object(forKey: "sharing") as? Bool ?? true {
    didSet { UserDefaults.standard.set(sharing, forKey: "sharing") }
}
func startHost() {
    guard sharing, hostProcess == nil else { return }
    let p = Process()
    hostProcess = p
    p.executableURL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/Hither Host.app/Contents/MacOS/hither-host")
    p.standardError = hostLog
    p.terminationHandler = { p in
        DispatchQueue.main.async {
            guard hostProcess === p else { hostLog?.write(Data("[hither] host stopped\n".utf8)); return }   // stopped on purpose
            hostProcess = nil
            hostLog?.write(Data("[hither] host exited (\(p.terminationStatus)), restarting\n".utf8))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { startHost() }
        }
    }
    do { try p.run() } catch { log("host: \(error)"); hostProcess = nil }
}
func stopHost() {
    let p = hostProcess
    hostProcess = nil
    p?.terminate()
}
func restartHost() { hostProcess?.terminate() }   // its termination handler starts a fresh one

// MARK: - main

let app = NSApplication.shared
var launcher: Launcher?
var listWire: Wire?   // must outlive the `if` below

switch role {
case "launcher":
    app.setActivationPolicy(.accessory)
    _ = Pairings.load()   // create this Mac's ID before the host reads it
    FileManager.default.createFile(atPath: "/tmp/hither-host.log", contents: nil)
    hostLog = FileHandle(forWritingAtPath: "/tmp/hither-host.log")
    startHost()
    launcher = Launcher()
    launcher?.start()
case "proxy":
    let host = info["HitherHost"] as! String, remoteApp = info["HitherApp"] as! String
    app.setActivationPolicy(.regular)
    let args = CommandLine.arguments
    let first = args.firstIndex(of: "--window").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 0
    _ = ProxyWindow(host: host, app: remoteApp, windowID: first)   // 0 = app's main window (launched from Dock/Spotlight)
    DistributedNotificationCenter.default().addObserver(forName: openNote, object: Bundle.main.bundleIdentifier, queue: .main) { n in
        _ = ProxyWindow(host: host, app: remoteApp, windowID: n.userInfo?["window"] as? Int ?? 0)
    }
    DistributedNotificationCenter.default().addObserver(forName: quitNote, object: nil, queue: .main) { _ in
        proxies.forEach { $0.done = true }   // don't relaunch the launcher on the way out
        NSApp.terminate(nil)
    }
default:
    let args = CommandLine.arguments
    if args.dropFirst().first == "--selftest" { pairSelfTest() }
    guard args.count >= 3 else {
        print("usage: hither <host> <app> [window-title-substring]\n       hither <host> --list\n       hither <host> --codec h264|hevc|hevc422"
            + "\n       hither <host> --dark on|off\n       hither <host> --lock\n       hither <host> @desktop"
            + "\n       hither <host> --send-clipboard|--get-clipboard\n       hither <host> --send-files <path>…")
        exit(1)
    }
    if args[2] == "--dark", args.count > 3 {   // same as the launcher's Keep Screen Dark
        let w = dial(args[1])
        listWire = w
        w.onMsg = { m in print("keep screen dark: \(m.dark == true ? "on" : "off")"); exit(0) }
        w.onClose = { exit(1) }
        w.start()
        var m = Msg("dark"); m.dark = args[3] == "on"
        w.send(m)
    } else if args[2] == "--lock" {
        let w = dial(args[1])
        listWire = w
        w.onMsg = { _ in print("locked"); exit(0) }
        w.onClose = { exit(1) }
        w.start()
        w.send(Msg("lock"))
        w.send(Msg("list"))   // its reply means the lock went through first
    } else if args[2] == "--send-clipboard" || args[2] == "--get-clipboard" {   // same as the launcher's clipboard items
        let w = dial(args[1]), name = macName(args[1])
        listWire = w
        w.onMsg = { m in print(m.t == "clipset" ? "Sent \(m.text ?? "clipboard") to \(name)" : m.text ?? m.t); exit(m.t == "clipset" ? 0 : 1) }
        let status: ClipStatus = { s, done in print(s); if let done { exit(done ? 0 : 1) } }
        w.onClip = { d in DispatchQueue.main.async { if let s = receivedClipboard(d, from: args[1], status: status) { print(s); exit(0) } } }
        w.onClose = { exit(1) }
        w.start()
        if args[2] == "--get-clipboard" { w.send(Msg("clipget")) }
        else if let why = pushClipboard(over: w, to: args[1], status: status) { print(why); exit(1) }
    } else if args[2] == "--send-files", args.count > 3 {   // as Send Clipboard with these copied in Finder
        FileCopy(args[1], status: { s, done in print(s); if let done { exit(done ? 0 : 1) } }).send(args[3...].map { URL(fileURLWithPath: $0) })
    } else if args[2] == "--codec", args.count > 3 {   // same as the launcher's Video Codec menu
        let w = dial(args[1])
        listWire = w
        w.onMsg = { m in print("codec: \(m.codec ?? "?")"); exit(0) }
        w.onClose = { exit(1) }
        w.start()
        var m = Msg("codec"); m.codec = args[3]
        w.send(m)
    } else if args[2] == "--list" {
        let w = dial(args[1])
        listWire = w
        w.onMsg = { m in
            for i in m.items ?? [] { print("\(i.app) — \(i.title)  [\(i.id)]") }
            exit(0)
        }
        w.onClose = { exit(1) }
        w.start()
        w.send(Msg("list"))
    } else {
        app.setActivationPolicy(.regular)
        _ = ProxyWindow(host: args[1], app: args[2], title: args.count > 3 ? args[3] : nil)
    }
}
app.run()
