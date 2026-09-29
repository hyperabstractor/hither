import AppKit
import AVFoundation
import Network
import ServiceManagement
import UniformTypeIdentifiers
import Shared

// One binary, three roles, picked by the bundle it runs from:
//   cli       uc-viewer <host> <app> [title-substring]  |  uc-viewer <host> --list      (dev)
//   launcher  "Unified Control.app": menu-bar list of the host's windows, creates proxy apps on demand
//   proxy     "Cursor · mini.app": its own Dock/Cmd-Tab identity; one local window per remote window

let key = loadKey()
let info = Bundle.main.infoDictionary ?? [:]
let role = info["UCRole"] as? String ?? "cli"
let openNote = Notification.Name("dev.unified-control.open")
let launcherID = "dev.unified-control.launcher"
let quitNote = Notification.Name("dev.unified-control.quit")   // launcher quitting → proxies go too (they need its relay)

func short(_ host: String) -> String { host.split(separator: ".").first.map(String.init) ?? host }
/// Proxies go through the launcher's loopback relay (only the launcher needs Local Network access);
/// TLS still runs end to end with the host, so the relay only ever sees ciphertext.
func dial(_ host: String) -> Wire {
    let c = role == "proxy"
        ? NWConnection(host: "127.0.0.1", port: relayPort, using: tlsParams(key: key))
        : NWConnection(host: NWEndpoint.Host(host), port: port, using: tlsParams(key: key))
    return Wire(c, queue: DispatchQueue(label: "wire"))
}
/// Runs on the main thread even while a menu is open (plain main-queue blocks wait for tracking to end).
func onMain(_ f: @escaping () -> Void) { RunLoop.main.perform(inModes: [.common], block: f); CFRunLoopWakeUp(CFRunLoopGetMain()) }

// NSEvent.Phase → CGScrollPhase / CGMomentumScrollPhase raw values
func cgPhase(_ p: NSEvent.Phase) -> Int {
    p.contains(.began) ? 1 : p.contains(.changed) ? 2 : p.contains(.ended) ? 4 : p.contains(.cancelled) ? 8 : p.contains(.mayBegin) ? 128 : 0
}
func cgMomentum(_ p: NSEvent.Phase) -> Int {
    p.contains(.began) ? 1 : p.contains(.changed) ? 2 : p.contains(.ended) ? 3 : 0
}

final class StreamView: NSView {
    let video = AVSampleBufferDisplayLayer()
    var format: CMVideoFormatDescription?
    var keySeq: UInt32 = 0
    var sentAt: [UInt32: CFTimeInterval] = [:]
    var samples: [Double] = []
    var allSamples: [Double] = []
    var onLatency: (Int) -> Void = { _ in }
    var send: (Msg) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        video.videoGravity = .resizeAspect
        video.backgroundColor = NSColor.black.cgColor
        layer = video
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }   // top-left origin, same as CG global coords on the host

    // MARK: video

    func show(_ packet: Data) {
        var r = Reader(packet)
        let seq = r.u32()
        let params = (0..<Int(r.u8())).map { _ in r.bytes(Int(r.u16())) }
        let body = r.rest()

        if !params.isEmpty {
            let bufs = params.map { p -> UnsafeMutablePointer<UInt8> in
                let m = UnsafeMutablePointer<UInt8>.allocate(capacity: p.count)
                p.copyBytes(to: m, count: p.count)
                return m
            }
            defer { bufs.forEach { $0.deallocate() } }
            var fd: CMFormatDescription?
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: params.count,
                parameterSetPointers: bufs.map { UnsafePointer($0) }, parameterSetSizes: params.map(\.count),
                nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            if let fd { format = fd }
        }
        guard let format else { return }

        var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: body.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: body.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &bb)
        guard let bb else { return }
        body.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: body.count) }
        var sb: CMSampleBuffer?
        var size = body.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        guard let sb else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
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

    func mouse(_ e: NSEvent, _ kind: Int, _ button: Int) {
        let p = convert(e.locationInWindow, from: nil)
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
        let p = convert(e.locationInWindow, from: nil)
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

    /// Synthetic keystroke for the latency self-test (UC_TEST_TYPE).
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
    var windowID: Int     // pins reconnects to the exact remote window, even after its title changes
    let view = StreamView(frame: .zero)
    var window: NSWindow?
    var wire: Wire?
    var appName = "", remoteTitle = "", latency = ""
    var remoteSize = CGSize.zero
    var retries = 0
    var done = false

    init(host: String, app: String, title: String? = nil, windowID: Int = 0) {
        self.host = host; self.app = app; titleFilter = title; self.windowID = windowID
        super.init()
        view.send = { [weak self] in self?.wire?.send($0) }
        view.onLatency = { [weak self] ms in self?.latency = "\(ms) ms"; self?.updateTitle() }
        proxies.append(self)
        connect()
    }

    func connect() {
        let w = dial(host)
        w.onClose = { [weak self] in DispatchQueue.main.async { self?.lost() } }
        w.onVideo = { [view, weak w] d in
            w?.send(Msg("ack"))
            DispatchQueue.main.async { view.show(d) }
        }
        w.onMsg = { [weak self] m in DispatchQueue.main.async { self?.handle(m) } }
        wire = w
        w.start()
        var m = Msg("open"); m.app = app; m.title = titleFilter; m.k = windowID
        w.send(m)
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
        case "title": remoteTitle = m.title ?? ""; updateTitle()
        case "opened" where window != nil:   // reconnected: same local window, re-sync its size to the host
            retries = 0
            if window?.isKeyWindow == true { wire?.send(Msg("focus")) }
            remoteSize = CGSize(width: m.w ?? 0, height: m.h ?? 0)
            updateTitle()
            windowDidResize(Notification(name: NSWindow.didResizeNotification))
        case "opened": open(m)
        case "size":
            remoteSize = CGSize(width: m.w ?? 0, height: m.h ?? 0)
            guard let w = window, !w.inLiveResize, !w.styleMask.contains(.fullScreen), w.contentLayoutRect.size != fit(remoteSize) else { return }
            w.setContentSize(fit(remoteSize))
        default: break
        }
    }

    func open(_ m: Msg) {
        // already showing that remote window (e.g. picked twice from the menu)? just bring it forward
        if let other = proxies.first(where: { $0 !== self && $0.window != nil && $0.windowID == m.k }) {
            other.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return finish()
        }
        windowID = m.k ?? 0
        appName = m.app ?? app
        remoteTitle = m.title ?? ""
        remoteSize = CGSize(width: m.w ?? 800, height: m.h ?? 600)
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size ?? remoteSize
        let size = CGSize(width: min(remoteSize.width, screen.width), height: min(remoteSize.height, screen.height - 28))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.fullScreenPrimary]
        w.acceptsMouseMovedEvents = true
        w.contentView = view
        w.delegate = self
        w.makeFirstResponder(view)
        if let last = proxies.last(where: { $0.window != nil })?.window { w.setFrameTopLeftPoint(last.cascadeTopLeft(from: .zero)) } else { w.center() }
        window = w
        updateTitle()
        w.makeKeyAndOrderFront(nil)
        if let icon = m.icon.flatMap(NSImage.init(data:)) { NSApp.applicationIconImage = icon }
        NSApp.activate()
        if size != remoteSize { windowDidResize(Notification(name: NSWindow.didResizeNotification)) }
        if let n = Int(ProcessInfo.processInfo.environment["UC_TEST_TYPE"] ?? "") { selfTest(n) }
        if let s = ProcessInfo.processInfo.environment["UC_TEST_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), s.count == 2 {
            w.setContentSize(CGSize(width: s[0], height: s[1]))  // test hook: resize without touching the mouse
        }
    }

    /// UC_TEST_TYPE=n: type n × ("a", Backspace) — document ends unchanged — then log key→frame latency.
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

    /// Title mirrors the remote window; the subtitle says where it really runs.
    func updateTitle(status: String? = nil) {
        guard let window else { return }
        window.title = remoteTitle.isEmpty ? appName : remoteTitle
        let extra = status ?? latency
        window.subtitle = "\(appName) on \(short(host))" + (extra.isEmpty ? "" : " · \(extra)")
    }

    func windowDidResize(_ n: Notification) {
        guard let s = window?.contentLayoutRect.size, s != remoteSize else { return }
        var m = Msg("resize"); m.w = s.width.rounded(); m.h = s.height.rounded()
        wire?.send(m)
    }

    func windowDidEndLiveResize(_ n: Notification) {
        // host may have clamped us (window can't exceed its display there) — snap to what it really is
        if let w = window, !w.styleMask.contains(.fullScreen), w.contentLayoutRect.size != fit(remoteSize) { w.setContentSize(fit(remoteSize)) }
    }

    /// Never grow past this screen: if the host can't shrink its window (some apps refuse), show it scaled instead.
    func fit(_ s: CGSize) -> CGSize {
        guard let v = (window?.screen ?? NSScreen.main)?.visibleFrame.size else { return s }
        return CGSize(width: min(s.width, v.width), height: min(s.height, v.height - 28))
    }

    /// Opened, Cmd-Tab, Dock click, Space swipe… whenever this proxy becomes key here, bring the real window
    /// forward on the host, so hover and the first keystroke already land in the right place.
    func windowDidBecomeKey(_ n: Notification) { wire?.send(Msg("focus")) }

    func windowWillClose(_ n: Notification) { window = nil; finish() }

    func finish() {
        done = true
        wire?.close()
        window?.delegate = nil
        window?.close()
        window = nil
        proxies.removeAll { $0 === self }
        if proxies.isEmpty && role != "launcher" { NSApp.terminate(nil) }
    }
}

// MARK: - launcher (menu bar)

final class Launcher: NSObject, NSMenuDelegate {
    let host = info["UCHost"] as? String ?? "mini.local"
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    var wire: Wire?
    var items: [Item] = []
    var icons: [String: Data] = [:]
    var state = "connecting…"
    var relay: NWListener?

    func start() {
        status.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Unified Control")
        menu.delegate = self
        status.menu = menu
        rebuild()
        refresh()
        startRelay()
    }

    /// Loopback-only byte pipe: proxy ⇄ launcher ⇄ host. Keeps the per-app Local Network prompt away.
    // ponytail: relays to this launcher's one host; key the relay by host when there's a second Mac
    func startRelay() {
        let q = DispatchQueue(label: "relay")
        let params = NWParameters(tls: nil, tcp: tcpOptions())
        params.requiredInterfaceType = .loopback
        guard let l = try? NWListener(using: params, on: relayPort) else { return log("relay: port \(relayPort) busy") }
        l.newConnectionHandler = { [host] local in
            let remote = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcpOptions()))
            for c in [local, remote] {
                c.stateUpdateHandler = { s in
                    switch s {
                    case .failed, .cancelled, .waiting: local.cancel(); remote.cancel()
                    default: break
                    }
                }
                c.start(queue: q)
            }
            pipe(local, remote)
            pipe(remote, local)
        }
        l.stateUpdateHandler = { if case .failed(let e) = $0 { log("relay: \(e)") } }
        l.start(queue: q)
        relay = l
    }

    func menuWillOpen(_ m: NSMenu) { refresh() }

    /// One long-lived control connection; each menu open asks for a fresh window list.
    func refresh() {
        if wire == nil {
            let w = dial(host)
            w.onClose = { [weak self] in onMain { self?.wire = nil; self?.state = "can't reach \(self?.host ?? "")"; self?.rebuild() } }
            w.onMsg = { [weak self] m in if m.t == "windows" { onMain { self?.update(m.items ?? []) } } }
            wire = w
            w.start()
        }
        wire?.send(Msg("list"))
    }

    func update(_ new: [Item]) {
        for i in new { if let icon = i.icon { icons[i.bundle] = icon } }
        items = new
        state = ""
        rebuild()
    }

    func rebuild() {
        menu.removeAllItems()
        menu.addItem(withTitle: state.isEmpty ? "On \(short(host))" : "\(short(host)): \(state)", action: nil, keyEquivalent: "").isEnabled = false
        var apps: [String] = []
        for i in items where !apps.contains(i.bundle) { apps.append(i.bundle) }
        for b in apps {
            let wins = items.filter { $0.bundle == b }
            // app row opens its main window, like launching the app; window rows open that exact window
            add(wins[0].app, Item(id: 0, app: wins[0].app, bundle: b, title: ""), indent: 0).image = icons[b].flatMap(NSImage.init(data:)).map {
                $0.size = NSSize(width: 16, height: 16); return $0
            }
            for w in wins { add(w.title.isEmpty ? "Untitled" : w.title, w, indent: 1) }
        }
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit Unified Control", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @discardableResult func add(_ title: String, _ item: Item, indent: Int) -> NSMenuItem {
        let mi = menu.addItem(withTitle: title, action: #selector(open(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = item
        mi.indentationLevel = indent
        return mi
    }

    @objc func open(_ sender: NSMenuItem) {
        guard let w = sender.representedObject as? Item else { return }
        do {
            let (url, id) = try ensureProxy(w)
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                NSApp.yieldActivation(to: running)
                DistributedNotificationCenter.default().postNotificationName(openNote, object: id, userInfo: ["window": w.id], deliverImmediately: true)
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.arguments = ["--window", String(w.id)]
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, e in if let e { log("launch \(url.lastPathComponent): \(e)") } }
            }
        } catch {
            log("proxy for \(w.app): \(error)")
        }
    }

    /// ~/Applications/Unified Control/<App> · <host>.app — a tiny bundle around this same binary, so the
    /// remote app gets its own name + icon in the Dock, Cmd-Tab and Spotlight. Rebuilt when this binary changes.
    func ensureProxy(_ w: Item) throws -> (URL, String) {
        let fm = FileManager.default
        let id = "dev.unified-control.proxy.\(short(host)).\(w.bundle)".filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let name = "\(w.app) · \(short(host))"
        let url = fm.homeDirectoryForCurrentUser.appending(path: "Applications/Unified Control/\(name.replacingOccurrences(of: "/", with: "-")).app")
        let exe = url.appending(path: "Contents/MacOS/uc-viewer")
        let me = Bundle.main.executableURL!
        let mtime = { (u: URL) in try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        if let theirs = mtime(exe), let mine = mtime(me), theirs >= mine { return (url, id) }

        try? fm.removeItem(at: url)
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: url.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: me, to: exe)
        var plist: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleExecutable": "uc-viewer", "CFBundlePackageType": "APPL", "NSHighResolutionCapable": true,
            "UCRole": "proxy", "UCHost": host, "UCApp": w.bundle,
        ]
        if let png = icons[w.bundle], writeICNS(png, to: url.appending(path: "Contents/Resources/AppIcon.icns")) {
            plist["CFBundleIconFile"] = "AppIcon"
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appending(path: "Contents/Info.plist"))
        sign(url)
        LSRegisterURL(url as CFURL, true)
        return (url, id)
    }

    @objc func quit() {
        DistributedNotificationCenter.default().postNotificationName(quitNote, object: nil, userInfo: nil, deliverImmediately: true)
        NSApp.terminate(nil)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { log("login item: \(error)") }
        rebuild()
    }
}

func pipe(_ from: NWConnection, _ to: NWConnection) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, eof, err in
        if let data, !data.isEmpty { to.send(content: data, completion: .idempotent) }
        if eof || err != nil { from.cancel(); to.cancel(); return }
        pipe(from, to)
    }
}

func writeICNS(_ png: Data, to url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithData(png as CFData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dst, img, nil)
    return CGImageDestinationFinalize(dst)
}

/// Stable dev identity when its keychain exists (keeps the Local Network approval across updates), else ad-hoc.
func sign(_ url: URL) {
    let kc = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Keychains/uc-signing.keychain-db").path
    let hasKC = FileManager.default.fileExists(atPath: kc)
    if hasKC { run("/usr/bin/security", ["unlock-keychain", "-p", "uc", kc]) }  // throwaway keychain, see scripts/common.sh
    if !(hasKC && run("/usr/bin/codesign", ["--force", "--sign", "Unified Control Dev", "--keychain", kc, url.path])) {
        run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
    }
}

@discardableResult func run(_ tool: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}

// MARK: - main

let app = NSApplication.shared
var launcher: Launcher?
var listWire: Wire?   // must outlive the `if` below

switch role {
case "launcher":
    app.setActivationPolicy(.accessory)
    launcher = Launcher()
    launcher?.start()
case "proxy":
    let host = info["UCHost"] as! String, remoteApp = info["UCApp"] as! String
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
    guard args.count >= 3 else {
        print("usage: uc-viewer <host> <app> [window-title-substring]\n       uc-viewer <host> --list")
        exit(1)
    }
    if args[2] == "--list" {
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
