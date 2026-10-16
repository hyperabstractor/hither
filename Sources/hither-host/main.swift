import AppKit
import ScreenCaptureKit
import VideoToolbox
import IOKit.pwr_mgt
import Network
import Shared

// Host: runs on the Mac that owns the apps. Streams one window per connection, injects the viewer's input.

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let panelService = "com.apple.appkit.xpc.openAndSavePanelService"  // Open/Save dialogs live in this process
let bitrate = Int(ProcessInfo.processInfo.environment["HITHER_BITRATE"] ?? "") ?? 40_000_000
/// ~/.hither/codec: h264 (default) | hevc | hevc422. Chosen from the app's Video Codec menu.
let codecURL = configDir.appending(path: "codec")
let codecs = ["h264", "hevc", "hevc422"]
func currentCodec() -> String {
    let c = (try? String(contentsOf: codecURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return codecs.contains(c) ? c : "h264"
}
var lastRaised: CGWindowID = 0   // the window that currently has input focus on this Mac
/// All input injection runs here: it's serialized system-wide anyway, and an app switch (with its wait)
/// must never stall a session's capture/encode/ack queue.
let inputQ = DispatchQueue(label: "input")
/// Menu reads and presses: AX calls into the app can block (a menu item that runs a modal panel), so keep them
/// off both the session and input queues.
let menuQ = DispatchQueue(label: "menu")
var lastInputAt: CFTimeInterval = 0
/// Input through a window proxy (not a desktop): a new window soon after is the user's doing, so it follows them.
/// Through a desktop they already see it there.
var lastWindowInputAt: CFTimeInterval = 0
var wakeID: IOPMAssertionID = 0, lastWake: CFTimeInterval = 0
/// Runs on inputQ. Remote use counts as someone at this Mac: wakes a sleeping display (capture needs it) and
/// resets the idle timer, exactly like touching its own keyboard.
func wake() {
    guard CACurrentMediaTime() - lastWake > 1 else { return }
    lastWake = CACurrentMediaTime()
    IOPMAssertionDeclareUserActivity("Hither input" as CFString, kIOPMUserActiveLocal, &wakeID)
}
// new-window following (all on the main queue)
var watchers: [ObjectIdentifier: Session] = [:]   // launcher connections that receive "appeared"
var knownWindows: Set<CGWindowID> = []            // every window seen so far
var watchPrimed = false
var launchingApps: Set<String> = []                // bundles a proxy is launching: their first window is already spoken for   // while the user is typing/clicking, background windows hold their frames

func axWindow(pid: pid_t, id: CGWindowID) -> AXUIElement? {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v)
    return (v as? [AXUIElement])?.first { var w: CGWindowID = 0; return _AXUIElementGetWindow($0, &w) == .success && w == id }
}

/// Press this window's close button in place. Raising it first would steal the Mac's focus; a save sheet stays
/// on the window, so a window that doesn't actually close remains in the next list.
func pressClose(_ id: CGWindowID) {
    guard id != 0,
          let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
          let pid = info[kCGWindowOwnerPID as String] as? pid_t,
          let win = axWindow(pid: pid, id: id) else { return log("close: window \(id) not found") }
    var btn: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &btn) == .success,
          let btn, CFGetTypeID(btn) == AXUIElementGetTypeID() else { return log("close: window \(id) has no close button") }
    let err = AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
    if err != .success { log("close: window \(id) press \(err.rawValue)") }
}

final class Session: NSObject, SCStreamOutput, SCStreamDelegate {
    let q = DispatchQueue(label: "session")
    let wire: Wire
    var onEnd: () -> Void = {}

    var pid: pid_t = 0
    var windowID: CGWindowID = 0     // the display's ID when streaming the whole desktop
    var desktop = false              // a whole display, not one app's window
    var opened = false               // streaming something: keeps this Mac's screen dark (Dark)
    var viewer: (size: CGSize, scale: Double)?   // desktop: the viewer's screen, whose shape a dark display may take (Dark.fit)
    var ax: AXUIElement?
    var display: SCDisplay!
    var frame = CGRect.zero          // window frame, global points, top-left origin
    var scale: CGFloat = 2
    var excluded: Set<CGWindowID> = []
    var stream: SCStream?
    var timer: DispatchSourceTimer?
    var ticks = 0
    var ended = false
    var title: String?               // remote window title, pushed to the viewer when it changes
    var sentIcons: Set<String> = []  // app icons already sent on this connection

    var encoder: VTCompressionSession?
    var encSize = (0, 0)
    var forceKey = true
    var unacked = 0                  // frames sent but not yet acked by the viewer
    var window = FrameWindow()       // how many may be: grows over a long link, shrinks when it fills
    var held = false                 // a frame waited on the window since the last ack
    var pending: CVPixelBuffer?      // newest frame we skipped while the viewer was behind
    var inputSeq: UInt32 = 0         // last injected keyDown seq, stamped on frames for the latency meter
    var scrollAcc = (0.0, 0.0)

    // 5-second stats, logged from poll()
    var appName = ""
    var inflight: [CFTimeInterval] = []   // submit times of unacked frames, oldest first
    var nFrames = 0, nBytes = 0, nKeys = 0, nDelayed = 0, nRaises = 0
    var encMs = 0.0, raiseMs = 0.0, rtts: [Double] = []
    var lastEncode: CFTimeInterval = 0
    var codec = "h264"
    var viewerHEVC = false
    var viewer422 = false
    var viewerAudio = false
    var original: CGRect?            // the window's frame before a viewer that asked for "restore" resized it
    let audioQ = DispatchQueue(label: "audio")
    var nAudio = 0
    var audioPeak: Float = 0   // loudest sample in the stats window: 0 = silence
    var lastFrame: CVPixelBuffer?   // re-sent on a codec switch
    var pumpQueued = false
    var visible = true

    init(_ conn: NWConnection) {
        wire = Wire(conn, queue: q)
        super.init()
        wire.onMsg = { [unowned self] in handle($0) }
        wire.onClose = { [unowned self] in log("connection closed (\(conn.endpoint))"); stop() }
        log("connection from \(conn.endpoint)")
        wire.start()
    }

    func handle(_ m: Msg) {
        switch m.t {
        case "list": Task { await list() }
        case "watch": DispatchQueue.main.async { watchers[ObjectIdentifier(self)] = self }
        case "codec":
            try? (codecs.contains(m.codec ?? "") ? m.codec! : "h264").write(to: codecURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { sessions.values.forEach { $0.applyCodec() } }
            Task { await list() }   // reply with the new state
        case "apps": Task { apps() }
        case "dark":
            let on = m.dark ?? false
            DispatchQueue.main.async { Dark.enabled = on }
            Task { await list() }   // reply with the new state
        case "lock": DispatchQueue.main.async { Dark.lock() }
        case "open":
            viewerHEVC = m.caps?.contains("hevc") == true   // older viewers only decode H.264
            viewer422 = m.caps?.contains("hevc422") == true   // an iPhone may not decode 4:2:2
            viewerAudio = m.caps?.contains("audio") == true
            if m.caps?.contains("restore") == true { original = .zero }   // filled in once the window is known
            inputQ.async { wake() }   // a sleeping display may give the new window no frames
            if m.app == desktopApp { Task { await openDesktop(CGDirectDisplayID(m.k ?? 0)) } }
            else { Task { await open(m.app ?? "", m.title, id: CGWindowID(m.k ?? 0)) } }
        case "ack":
            unacked -= 1
            if !inflight.isEmpty {
                let now = CACurrentMediaTime(), rtt = (now - inflight.removeFirst()) * 1000
                rtts.append(rtt)
                window.ack(rtt: rtt, at: now, held: held)
                held = false
            }
            pump()
        case "keyframe": forceKey = true
        case "menu":
            let path = m.path ?? [], seq = m.seq
            menuQ.async {
                var r = Msg("menu"); r.seq = seq
                r.menu = self.menuItems(at: path)?.map(describe) ?? []
                self.wire.send(r)
            }
        case "press":
            let path = m.path ?? []
            inputQ.async {
                lastInputAt = CACurrentMediaTime()   // File › New Window etc. count as the user's doing
                lastWindowInputAt = lastInputAt
                wake()
                self.focus(force: false)   // e.g. File › Save acts on the key window, so make it ours
                menuQ.async { if let e = self.menuItems(at: path.dropLast())?[safe: path.last ?? -1] { AXUIElementPerformAction(e, kAXPressAction as CFString) } }
            }
        case "visible":   // proxy window fully hidden (minimized, other Space, covered, app hidden) → encode nothing
            visible = m.down ?? true
            log("\(appName) \(visible ? "visible" : "hidden — paused")")
            pump()   // newly visible: send whatever changed while hidden
        case "focus": if pid != 0 { inputQ.async { self.focus(force: false) } }   // proxy became the active window on the client
        case "resize":
            if !desktop { resize(m.w ?? frame.width, m.h ?? frame.height) }
            else if let w = m.w, let h = m.h, w > 0, h > 0 {   // a shape to fit, if dark
                viewer = (CGSize(width: w, height: h), m.scale ?? 1)
                DispatchQueue.main.async { Dark.tick() }
            }
        case "close": menuQ.async { pressClose(CGWindowID(m.k ?? 0)) }   // launcher menu's X; AX can block on a modal
        default:
            let f = frame
            inputQ.async { self.input(m, frame: f) }
        }
    }

    // MARK: window selection

    func candidates(_ c: SCShareableContent) -> [SCWindow] {
        c.windows.filter { w in
            guard w.windowLayer == 0, w.frame.width > 100, let owner = w.owningApplication,
                  !isOurs(owner.bundleIdentifier) else { return false }
            let contained = c.windows.contains { other in
                other.windowID != w.windowID && other.windowLayer == 0
                    && other.owningApplication?.processID == owner.processID && other.frame.contains(w.frame)
            }
            return isIndependentWindow(pid: owner.processID, id: w.windowID, hasContainingWindow: contained) != false
        }
    }

    func list() async {
        let c: SCShareableContent
        do { c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) } catch { return fail("\(error)") }
        var m = Msg("windows")
        m.codec = currentCodec()
        m.dark = Dark.enabled
        m.items = q.sync {
            candidates(c).map { w in
                let o = w.owningApplication!
                let icon = sentIcons.insert(o.bundleIdentifier).inserted
                    ? NSRunningApplication(processIdentifier: o.processID)?.icon.flatMap(png) : nil
                return Item(id: Int(w.windowID), app: o.applicationName, bundle: o.bundleIdentifier, title: w.title ?? "", icon: icon)
            }
        }
        wire.send(m)
    }

    /// Installed apps here, so the client can make a proxy for each (Spotlight there finds "Xcode · mini").
    func apps() {
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appending(path: "Applications").path]
        var seen = Set<String>(), items: [Item] = []
        for d in dirs {
            for name in ((try? fm.contentsOfDirectory(atPath: d)) ?? []).sorted() where name.hasSuffix(".app") {
                let path = "\(d)/\(name)"
                guard let b = Bundle(path: path), let id = b.bundleIdentifier, !isOurs(id),
                      !["LSUIElement", "LSBackgroundOnly"].contains(where: { isTrue(b.object(forInfoDictionaryKey: $0)) }),  // menu-bar/agent apps
                      seen.insert(id).inserted else { continue }
                let label = fm.displayName(atPath: path)
                items.append(Item(id: 0, app: label.hasSuffix(".app") ? String(label.dropLast(4)) : label, bundle: id, title: "",
                                  icon: png(NSWorkspace.shared.icon(forFile: path))))
            }
        }
        var m = Msg("apps"); m.items = items
        wire.send(m)
        log("sent \(items.count) installed apps")
    }

    func pick(_ c: SCShareableContent, _ app: String, _ title: String?, _ id: CGWindowID) -> SCWindow? {
        let windows = candidates(c)
        let selected = WindowCandidate.select(from: windows.map { w in
            let owner = w.owningApplication!
            return WindowCandidate(id: Int(w.windowID), app: owner.applicationName, bundle: owner.bundleIdentifier,
                                   title: w.title ?? "", area: w.frame.width * w.frame.height)
        }, app: app, title: title, id: Int(id))
        return windows.first { Int($0.windowID) == selected }
    }

    func open(_ app: String, _ title: String?, id: CGWindowID) async {
        do {
            var win: SCWindow?, launched = false
            for _ in 0..<60 {   // a cold-launched app gets up to ~30 s to show its first window
                let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                win = pick(c, app, title, id)
                if win != nil || title != nil || id != 0 { break }
                if !launched {
                    // not running, or running without a window: launch / reopen it, like clicking its Dock icon
                    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { break }
                    launched = true
                    await MainActor.run { _ = launchingApps.insert(app) }
                    log("launching \(url.lastPathComponent)")
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            let picked = win?.windowID
            DispatchQueue.main.async {
                if let picked { knownWindows.insert(picked) }   // ours now: the watcher mustn't announce it too
                if launched { launchingApps.remove(app) }
            }
            guard let win else { return fail("no window matching '\(app)'\(title.map { " / '\($0)'" } ?? "")") }
            let owner = win.owningApplication!
            q.sync {
                pid = owner.processID
                opened = true
                codec = viewerCodec()
                if case .hostPort(_, let port) = wire.conn.endpoint { appName = "\(owner.applicationName):\(port)" }
                else { appName = owner.applicationName }
                windowID = win.windowID
                ax = axWindow(pid: pid, id: windowID)
                frame = win.frame
                if original != nil { original = win.frame }
            }
            var m = Msg("opened")
            m.app = owner.applicationName
            m.title = win.title
            m.w = win.frame.width; m.h = win.frame.height
            m.k = Int(win.windowID)
            m.icon = NSRunningApplication(processIdentifier: pid)?.icon.flatMap(png)
            wire.send(m)
            log("opening \(owner.applicationName) '\(win.title ?? "")', accessibility=\(AXIsProcessTrusted())")
            await capture()
        } catch {
            fail("\(error)")
        }
    }

    /// The whole display `id` (0, or one that's gone: the main one), like Screen Sharing but through Hither's stream.
    func openDesktop(_ id: CGDirectDisplayID) async {
        let main = CGMainDisplayID()
        q.sync {
            desktop = true
            opened = true
            codec = viewerCodec()
            windowID = id != 0 && CGDisplayIsOnline(id) != 0 ? id : main
            frame = CGDisplayBounds(windowID)
            if case .hostPort(_, let port) = wire.conn.endpoint { appName = "Desktop:\(port)" } else { appName = "Desktop" }
        }
        var m = Msg("opened")
        m.app = "Desktop"
        m.title = localName()
        m.w = frame.width; m.h = frame.height
        m.k = Int(windowID)
        wire.send(m)
        log("opening desktop \(Int(frame.width))×\(Int(frame.height)), accessibility=\(AXIsProcessTrusted())")
        await capture()
    }

    /// (Re)attach capture to whatever display the window is on *now*. Displays come and go
    /// (Screen Sharing connects/disconnects, monitor sleeps), so a stopped stream retries instead of dying.
    func capture() async {
        guard !ended else { return }
        guard q.sync(execute: readFrame) != nil else {
            if q.sync(execute: { desktop }) { log("no display yet, retrying"); return retry() }   // a headless Mac between screens
            return fail("window closed")
        }
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let setup: (SCContentFilter, SCStreamConfiguration)? = q.sync {
                guard let r = readFrame(), let d = c.displays.first(where: { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }) ?? c.displays.first
                else { return nil }
                frame = r
                display = d
                if !d.frame.contains(frame) { resize(min(r.width, d.frame.width), min(r.height, d.frame.height)) }
                let f = filter(c)
                scale = CGFloat(SCShareableContent.info(for: f).pointPixelScale)
                return (f, config())
            }
            guard let setup else { log("no display yet, retrying"); return retry() }
            let s = SCStream(filter: setup.0, configuration: setup.1, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
            if viewerAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ) }
            try await s.startCapture()
            q.async {
                guard !self.ended else { s.stopCapture { _ in }; return }
                self.stream = s
                self.forceKey = true
                if self.timer == nil { self.startPolling() }
                var m = Msg("size"); m.w = self.frame.width; m.h = self.frame.height
                self.wire.send(m)
                log("streaming \(Int(self.frame.width))×\(Int(self.frame.height)) @\(self.scale)x on display \(setup.0.contentRect.size)")
            }
        } catch {
            log("capture failed: \(error.localizedDescription), retrying")
            retry()
        }
    }

    func retry() {
        Task { try? await Task.sleep(for: .seconds(2)); await capture() }
    }

    func fail(_ why: String) {
        q.async {
            guard !self.ended else { return }
            self.ended = true
            self.timer?.cancel(); self.timer = nil
            log(why)
            var m = Msg("closed"); m.title = why
            // Let the terminal message drain before closing; otherwise the viewer mistakes closure for a network drop.
            self.wire.sendAndClose(m)
        }
    }

    /// Capture the whole app on the display (so menus, sheets, popovers, Open/Save panels come along),
    /// cropped to our window, minus the app's *other* main windows so they don't bleed through.
    func filter(_ c: SCShareableContent) -> SCContentFilter {
        if desktop { return SCContentFilter(display: display, excludingWindows: []) }
        let apps = c.applications.filter { $0.processID == pid || $0.bundleIdentifier == panelService }
        // ponytail: "fully inside our frame" = sheet/dialog heuristic; per-window proxies if it misfires
        let others = c.windows.filter { $0.owningApplication?.processID == pid && $0.windowID != windowID
            && $0.windowLayer == 0 && !frame.contains($0.frame) }
        excluded = Set(others.map(\.windowID))
        return SCContentFilter(display: display, including: apps, exceptingWindows: others)
    }

    func config() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        c.width = Int(frame.width * scale) & ~1
        c.height = Int(frame.height * scale) & ~1
        // 4:2:2 needs more color than 4:2:0 capture carries: hand the encoder full RGB and let it subsample
        c.pixelFormat = codec == "hevc422" ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.showsCursor = false
        c.queueDepth = 5
        if viewerAudio {   // only this window's app(s), per the content filter
            c.capturesAudio = true
            c.sampleRate = 48_000
            c.channelCount = 2
            c.excludesCurrentProcessAudio = true
        }
        return c
    }

    // MARK: tracking the real window

    func startPolling() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func readFrame() -> CGRect? {
        if desktop {   // a display that went away (Screen Sharing's, say): follow the main one
            if CGDisplayIsOnline(windowID) == 0 { windowID = CGMainDisplayID() }
            let r = CGDisplayBounds(windowID)
            return r.isEmpty ? nil : r
        }
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] else { return nil }
        if let t = info[kCGWindowName as String] as? String, t != title {
            if title != nil { var m = Msg("title"); m.title = t; wire.send(m) }
            title = t
        }
        return CGRect(dictionaryRepresentation: b as! CFDictionary)
    }

    func poll() {
        guard !ended else { return }
        guard let r = readFrame() else { return desktop ? () : fail("window closed") }
        if r != frame {
            frame = r
            // Moved where capture can't follow (partly off its display, onto another): the stream would keep the old
            // rect, now empty, and the viewer would see black. Set up capture again, which brings the window back.
            stream?.updateConfiguration(config()) { [weak self] e in
                guard let self, let e else { return }
                log("updateConfiguration for \(r): \(e.localizedDescription), reattaching")
                q.async {
                    guard let s = self.stream else { return }
                    self.stream = nil
                    s.stopCapture { _ in }
                    self.retry()
                }
            }
            var m = Msg("size"); m.w = r.width; m.h = r.height
            wire.send(m)
        }
        ticks += 1
        if ticks % 20 == 0 && (nFrames > 0 || nRaises > 0 || nAudio > 0) {
            let r = rtts.sorted()
            log(String(format: "stats %@: %d fps %.1f Mbps keyframes=%d encode=%.1fms delivery med/max=%.0f/%.0fms window=%d delayed=%d raises=%d (%.0fms avg) audio=%d/s peak=%.2f",
                       appName, nFrames / 5, Double(nBytes) * 8 / 5e6, nKeys, nFrames > 0 ? encMs / Double(nFrames) : 0,
                       r.isEmpty ? 0 : r[r.count / 2], r.last ?? 0, window.limit, nDelayed, nRaises, nRaises > 0 ? raiseMs / Double(nRaises) : 0, nAudio / 5, audioPeak))
            nAudio = 0; audioPeak = 0; nFrames = 0; nBytes = 0; nKeys = 0; nDelayed = 0; nRaises = 0; encMs = 0; raiseMs = 0; rtts = []
        }
        if ticks % 4 == 0 {  // new/closed sibling windows → refresh exclusions ~1/s
            Task {
                guard let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
                q.async {
                    let before = self.excluded
                    let f = self.filter(c)
                    if self.excluded != before { self.stream?.updateContentFilter(f) { _ in } }
                }
            }
        }
    }

    func resize(_ w: Double, _ h: Double) {
        guard let ax else { return log("resize: no AX handle for window \(windowID)") }
        let size = CGSize(width: w, height: h)
        var pos = frame.origin
        if let d = display?.frame, !d.contains(CGRect(origin: pos, size: size)) { pos = d.origin }  // AX clamps below the menu bar
        place(ax, size, pos)
        if stream != nil { poll() } else { frame = readFrame() ?? frame }
    }

    /// Chromium/Electron apps ignore AX resizes while AXEnhancedUserInterface is on; switch it off around
    /// the resize, and do size→position→size like Rectangle (a move can be refused until the size fits).
    func place(_ ax: AXUIElement, _ size: CGSize, _ pos: CGPoint) {
        var size = size, pos = pos
        let (w, h) = (size.width, size.height)
        let app = AXUIElementCreateApplication(pid), enhanced = "AXEnhancedUserInterface" as CFString
        var was: CFTypeRef?
        AXUIElementCopyAttributeValue(app, enhanced, &was)
        if (was as? Bool) == true { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanFalse) }
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
        let err = AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        if (was as? Bool) == true { AXUIElementSetAttributeValue(app, enhanced, kCFBooleanTrue) }
        if err != .success { log("resize to \(Int(w))×\(Int(h)) failed: \(err.rawValue)") }
        q.asyncAfter(deadline: .now() + 0.5) { log("resize \(Int(w))×\(Int(h)) (enhanced=\(was.map { "\($0)" } ?? "nil")) → \(self.readFrame().map { "\($0.size)" } ?? "nil")") }
    }

    // MARK: capture → encode → send

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { return audio(sb) }
        guard type == .screen, let px = sb.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[.status] as? Int).flatMap({ SCFrameStatus(rawValue: $0) }) == .complete else { return }
        if pending != nil { nDelayed += 1 }
        pending = px   // keep only the newest frame
        pump()
    }

    /// Encode the newest captured frame once the viewer has caught up (no more in flight than the window allows). The
    /// Mac has one hardware encoder, so: focused window full rate; visible background ≤10 fps (2 while you type); hidden paused.
    func pump() {
        guard !ended, visible, let p = pending else { return }
        guard unacked < window.limit else { held = true; return }
        let busy = CACurrentMediaTime() - lastInputAt < 0.5
        let gap = desktop || windowID == lastRaised ? 0 : busy ? 0.5 : 0.1   // a desktop is always the one in front
        let wait = lastEncode + gap - CACurrentMediaTime()
        guard wait <= 0 else {
            if !pumpQueued {
                pumpQueued = true
                q.asyncAfter(deadline: .now() + wait) { self.pumpQueued = false; self.pump() }
            }
            return
        }
        pending = nil
        encode(p)
    }

    /// App audio → 48 kHz stereo Int16, sent raw (~1.5 Mbps: nothing on a LAN, and no codec delay).
    func audio(_ sb: CMSampleBuffer) {
        guard let fd = sb.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block) == noErr else { return }
        let bufs = UnsafeMutableAudioBufferListPointer(list)
        let frames = CMSampleBufferGetNumSamples(sb), ch = max(Int(asbd.mChannelsPerFrame), 1)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        var out = [Int16](repeating: 0, count: frames * 2), peak: Float = 0
        for i in 0..<frames {
            for c in 0..<2 {
                let src = min(c, ch - 1)   // mono → both ears
                let v = interleaved ? bufs[0].mData!.assumingMemoryBound(to: Float.self)[i * ch + src]
                                    : bufs[src].mData!.assumingMemoryBound(to: Float.self)[i]
                out[i * 2 + c] = Int16(max(-1, min(1, v)) * 32767)
                peak = max(peak, abs(v))
            }
        }
        wire.sendAudio(out.withUnsafeBytes { Data($0) })
        q.async { self.nAudio += 1; self.audioPeak = max(self.audioPeak, peak) }
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        q.async {
            log("capture stopped: \(error.localizedDescription) — reattaching")
            self.stream = nil
            self.retry()
        }
    }

    /// Codec changed from the launcher: new encoder now, and re-send the current picture so the switch shows at once.
    func applyCodec() {
        q.async {
            let c = self.viewerCodec()
            guard c != self.codec, self.pid != 0 else { return }
            let recapture = (c == "hevc422") != (self.codec == "hevc422")   // capture pixel format differs
            self.codec = c
            if recapture { self.stream?.updateConfiguration(self.config()) { if let e = $0 { log("updateConfiguration: \(e)") } } }
            if let e = self.encoder { VTCompressionSessionInvalidate(e) }
            self.encoder = nil
            if self.pending == nil { self.pending = self.lastFrame }
            self.pump()
        }
    }

    /// The chosen codec, stepped down to what this viewer decodes.
    func viewerCodec() -> String {
        let c = currentCodec()
        return !viewerHEVC ? "h264" : c == "hevc422" && !viewer422 ? "hevc" : c
    }

    func encode(_ px: CVPixelBuffer) {
        lastFrame = px
        let size = (CVPixelBufferGetWidth(px), CVPixelBufferGetHeight(px))
        if encoder == nil || encSize != size { makeEncoder(size) }
        guard let encoder else { return }
        let props = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        unacked += 1
        let seq = inputSeq, t0 = CACurrentMediaTime()
        lastEncode = t0
        inflight.append(t0)
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: px, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard let self else { return }
            guard status == noErr, let sb else { self.q.async { self.unacked -= 1; _ = self.inflight.popLast() }; return }
            let p = packet(sb, seq), ms = (CACurrentMediaTime() - t0) * 1000
            self.wire.sendVideo(p)
            self.q.async { self.nFrames += 1; self.nBytes += p.count; self.encMs += ms; if p[4] & 0x7f != 0 { self.nKeys += 1 } }
        }
    }

    func makeEncoder(_ size: (Int, Int)) {
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
        var s: VTCompressionSession?
        let type = codec == "h264" ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        func create(_ spec: [CFString: Any]) -> OSStatus {
            VTCompressionSessionCreate(allocator: nil, width: Int32(size.0), height: Int32(size.1), codecType: type,
                                       encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                       outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        // hardware is required (creation fails rather than silently falling back to software), low-latency
        // rate control where the encoder offers it, otherwise plain real-time mode
        let hwOnly: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        let lowLatency = create(hwOnly.merging([kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]) { $1 }) == noErr
        if !lowLatency && create(hwOnly) != noErr { log("no hardware \(codec) encoder, using software"); _ = create([:]) }
        guard let s else { return log("encoder create failed for \(codec)") }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if !lowLatency { VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber) }
        let profile = [
            "h264": kVTProfileLevel_H264_ConstrainedHigh_AutoLevel, "hevc": kVTProfileLevel_HEVC_Main_AutoLevel,
            "hevc422": kVTProfileLevel_HEVC_Main42210_AutoLevel,
        ][codec]!
        let pst = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        var hw: CFTypeRef?
        let hst = VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &hw)
        log("encoder \(codec) \(size.0)×\(size.1): lowLatency=\(lowLatency) profile=\(pst == noErr ? "ok" : "rejected (\(pst))") "
            + "usingHardware=\(hst == noErr ? "\(hw as? Bool ?? false)" : "not reported (\(hst))")")
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        encoder = s
        encSize = size
        forceKey = true
    }

    // MARK: input

    /// Keys/clicks land in whatever is frontmost on this Mac, so make sure that's our window first.
    func focus(force: Bool) {
        guard !desktop else { return }   // the whole screen: input goes wherever it lands, as at the Mac itself
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard force || front != pid || lastRaised != windowID else { return }
        if nRaises < 3 { log("raise \(appName): front=\(front.map(String.init) ?? "nil") pid=\(pid) lastRaised=\(lastRaised) win=\(windowID)") }
        let t0 = CACurrentMediaTime()
        defer { let ms = (CACurrentMediaTime() - t0) * 1000; q.async { self.nRaises += 1; self.raiseMs += ms } }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let ax {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        lastRaised = windowID
        if front != pid { usleep(30_000) }  // ponytail: fixed wait for activation; poll frontmost if keys still get lost
    }

    /// Runs on inputQ. `frame` is a snapshot taken on the session queue.
    func input(_ m: Msg, frame: CGRect) {
        guard pid != 0 || desktop else { return }
        if m.t != "mouse" || m.k != 0 {   // hover doesn't count
            lastInputAt = CACurrentMediaTime()
            if !desktop { lastWindowInputAt = lastInputAt }
            wake()
        }
        let pt = CGPoint(x: frame.minX + (m.x ?? 0), y: frame.minY + (m.y ?? 0))
        let flags = CGEventFlags(rawValue: m.f ?? 0)
        switch m.t {
        case "key":
            focus(force: false)
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(m.k ?? 0), keyDown: m.down ?? true) else { return }
            e.flags = flags
            if m.rep == true { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            e.post(tap: .cghidEventTap)
            if let s = m.seq { q.async { self.inputSeq = s } }
        case "text":
            focus(force: false)
            // one key event per character carrying the character itself, so the layout and key codes don't matter
            for ch in m.text ?? "" {
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                    e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    e.flags = []
                    e.post(tap: .cghidEventTap)
                }
            }
            if let s = m.seq { q.async { self.inputSeq = s } }
        case "flags":
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(m.k ?? 0), keyDown: true) else { return }
            e.type = .flagsChanged
            e.flags = flags
            e.post(tap: .cghidEventTap)
        case "mouse":
            let b = min(m.b ?? 0, 2), kind = m.k ?? 0
            if kind == 1 { focus(force: true) }
            // hover lands on whatever is topmost at that point here; skip it unless that's our window
            if kind == 0 && !desktop && lastRaised != windowID { return }
            let types: [[CGEventType]] = [[.mouseMoved, .mouseMoved, .mouseMoved],
                                          [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                          [.leftMouseUp, .rightMouseUp, .otherMouseUp],
                                          [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]]
            guard let e = CGEvent(mouseEventSource: nil, mouseType: types[kind][b], mouseCursorPosition: pt,
                                  mouseButton: CGMouseButton(rawValue: UInt32(b))!) else { return }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(m.c ?? 1))
            e.flags = flags
            e.post(tap: .cghidEventTap)
        case "scroll":
            focus(force: false)   // same as hover: scroll goes to the topmost window at the point, so be it
            let lines = m.b == 1
            scrollAcc.0 += m.dy ?? 0; scrollAcc.1 += m.dx ?? 0
            let dy = Int32(scrollAcc.0), dx = Int32(scrollAcc.1)   // carry sub-pixel remainder to the next event
            scrollAcc.0 -= Double(dy); scrollAcc.1 -= Double(dx)
            guard let e = CGEvent(scrollWheelEvent2Source: nil, units: lines ? .line : .pixel, wheelCount: 2,
                                  wheel1: dy, wheel2: dx, wheel3: 0) else { return }
            e.location = pt
            e.flags = flags
            if !lines {
                e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(m.p ?? 0))
                e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(m.mp ?? 0))
            }
            e.post(tap: .cghidEventTap)
        default: break
        }
    }

    // MARK: menus

    /// Walk the app's menu bar by child indices: [] = bar items, [i] = items of bar item i's menu, [i, j] = submenu of item j…
    func menuItems(at path: some Collection<Int>) -> [AXUIElement]? {
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar) == .success
        else { return nil }
        var items = children(bar as! AXUIElement)
        for i in path {
            guard let item = items[safe: i], let menu = children(item).first else { return nil }   // an item's one child is its AXMenu
            items = children(menu)
        }
        return items
    }

    /// Tell a watching launcher about new windows (icons once per app per connection, like the list).
    func announce(_ items: [Item]) {
        q.async {
            var m = Msg("appeared")
            m.items = items.map { i in
                var i = i
                if self.sentIcons.insert(i.bundle).inserted {
                    i.icon = NSRunningApplication.runningApplications(withBundleIdentifier: i.bundle).first?.icon.flatMap(png)
                }
                return i
            }
            self.wire.send(m)
        }
    }

    func stop() {
        ended = true
        if let o = original, o != .zero, let ax, readFrame()?.size != o.size { place(ax, o.size, o.origin) }   // the phone let go
        let id = ObjectIdentifier(self)
        DispatchQueue.main.async { watchers[id] = nil }
        timer?.cancel(); timer = nil
        stream?.stopCapture { _ in }; stream = nil
        if let e = encoder { VTCompressionSessionInvalidate(e) }; encoder = nil
        onEnd()
    }
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
    return v as? [AXUIElement] ?? []
}

func describe(_ e: AXUIElement) -> MenuEntry {
    let keys = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute, kAXMenuItemCmdCharAttribute,
                kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute] as [CFString]
    var vals: CFArray?
    AXUIElementCopyMultipleAttributeValues(e, keys as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &vals)
    let a = vals as? [Any] ?? []   // missing attributes come back as AXValue errors, which the casts below skip
    return MenuEntry(title: a[safe: 0] as? String ?? "", enabled: a[safe: 1] as? Bool ?? false,
                     checked: !(a[safe: 2] as? String ?? "").isEmpty, key: a[safe: 3] as? String ?? "",
                     mods: a[safe: 4] as? Int ?? 0, sub: !(a[safe: 5] as? [AXUIElement] ?? []).isEmpty)
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

/// Hither's own apps (host, launcher, "Cursor · mini" proxies) are never offered: with both Macs hosting,
/// the Air would otherwise stream its proxies of the Mini back to the Mini.
func isOurs(_ bundle: String) -> Bool { bundle.hasPrefix("dev.hither.") }

// MARK: dark screen

/// Keep Screen Dark: while anything here is streamed, this Mac's own monitors show black, so whoever is near it
/// doesn't see what you do. Their gamma tables are zeroed: capture happens before gamma, so the stream is unaffected,
/// and macOS restores the colors by itself if this process dies. Two minutes after the last stream closes, the Mac
/// locks and its monitors come back, showing the lock screen. Screen Sharing's virtual display is left alone.
/// Everything here runs on the main queue.
enum Dark {
    static let url = configDir.appending(path: "dark")
    static var enabled = FileManager.default.fileExists(atPath: url.path) {
        didSet {
            if enabled { FileManager.default.createFile(atPath: url.path, contents: nil) } else { try? FileManager.default.removeItem(at: url) }
            log("keep screen dark: \(enabled ? "on" : "off")")
            tick()
        }
    }
    static let grace = 120.0          // after the last stream closes: then lock
    static var lastStream = -Double.infinity
    static var lockedAt = -Double.infinity
    static var dark = false           // gamma currently zeroed by us

    static func start() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
        // any display change (mode, wake, a monitor plugged in) resets gamma: black it out again at once
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if !flags.contains(.beginConfigurationFlag) { DispatchQueue.main.async { if Dark.dark { Dark.blackOut() } } }
        }, nil)
        tick()
    }

    /// Once a second: macOS resets gamma now and then (display sleep/wake, Night Shift, a resolution change), so
    /// black it out again whenever that happened.
    static func tick() {
        let now = CACurrentMediaTime()
        let streaming = sessions.values.contains { $0.opened && !$0.ended }
        if streaming { lastStream = now }
        let idle = now - lastStream
        if enabled && !streaming && idle >= grace && idle < grace + 2 && now - lockedAt > grace {
            log("nothing streamed for \(Int(grace)) s: locking")
            lock()
        }
        fit()
        // dark while in use, through the grace period, and for a moment after locking so the desktop never flashes up
        if enabled && (idle < grace || now - lockedAt < 2) { blackOut() } else if dark { restore() }
    }

    static var fitted: [CGDirectDisplayID: CGDisplayMode] = [:]   // displays switched to a viewer's shape: their own mode
    static var fittedTo: [CGDirectDisplayID: CGDisplayMode] = [:] // …and the mode they were switched to (macOS reports the
                                                                   // old one for a moment after a switch)

    /// A dark monitor nobody looks at can take the shape of the screen a Desktop is viewed on, so the stream fills that
    /// window instead of being a letterboxed strip (an ultrawide on a laptop). Back to its own mode once no dark Desktop
    /// wants it; the change is the host's alone, so macOS undoes it if the host dies.
    static func fit() {
        var want: [CGDirectDisplayID: (size: CGSize, scale: Double)] = [:]
        if enabled {
            for s in sessions.values where s.desktop && s.opened && !s.ended { if let v = s.viewer { want[s.windowID] = v } }
        }
        for (d, own) in fitted where want[d] == nil {
            fitted[d] = nil
            fittedTo[d] = nil
            set(d, own)
        }
        let physical = physicalDisplays()
        for (d, viewer) in want where physical.contains(d) {
            guard let current = CGDisplayCopyDisplayMode(d), let best = bestMode(d, for: viewer.size, scale: viewer.scale),
                  best.width != current.width || best.height != current.height,
                  fittedTo[d].map({ $0.width != best.width || $0.height != best.height }) ?? true else { continue }
            if fitted[d] == nil { fitted[d] = current }
            fittedTo[d] = best
            set(d, best)
        }
    }

    static func bestMode(_ d: CGDirectDisplayID, for viewer: CGSize, scale: Double) -> CGDisplayMode? {
        let modes = (CGDisplayCopyAllDisplayModes(d, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() }
        return Shared.bestMode(modes.map { ModeSize(width: $0.width, height: $0.height, pixelWidth: $0.pixelWidth) },
                               for: viewer, scale: scale).map { modes[$0] }
    }

    static func set(_ d: CGDirectDisplayID, _ m: CGDisplayMode) {
        var c: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&c)
        CGConfigureDisplayWithDisplayMode(c, d, m, nil)
        let err = CGCompleteDisplayConfiguration(c, .forAppOnly)
        log("display \(d) → \(m.width)×\(m.height): \(err == .success ? "ok" : "error \(err.rawValue)")")
        if dark { blackOut() }   // a mode change resets gamma: black again before anyone sees the desktop
    }

    static func blackOut() {
        for d in physicalDisplays() where !isBlack(d) {
            var zero = [CGGammaValue](repeating: 0, count: 256)
            let err = CGSetDisplayTransferByTable(d, 256, &zero, &zero, &zero)
            if err != .success { log("dark: display \(d): \(err.rawValue)") }
            if !dark { log("screen dark") }
            dark = true
        }
    }

    static func restore() {
        CGDisplayRestoreColorSyncSettings()
        dark = false
        log("screen back")
    }

    static func isBlack(_ d: CGDirectDisplayID) -> Bool {
        var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r, n: UInt32 = 0
        guard CGGetDisplayTransferByTable(d, 256, &r, &g, &b, &n) == .success, n > 0 else { return false }
        return r[Int(n) - 1] == 0 && g[Int(n) - 1] == 0 && b[Int(n) - 1] == 0
    }

    /// Monitors someone could be looking at: not virtual ones (Screen Sharing's, whose picture is what you'd see).
    static func physicalDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).filter { d in
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d }?.localizedName ?? ""
            return !name.localizedCaseInsensitiveContains("virtual")
        }
    }

    /// Lock the screen (the menu's Lock, or after the grace period), the same as Control-Command-Q here.
    static func lock() {
        lockedAt = CACurrentMediaTime()
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: down) else { continue }   // kVK_ANSI_Q
            e.flags = [.maskControl, .maskCommand]
            e.post(tap: .cghidEventTap)
        }
        log("locked")
    }
}

func isTrue(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? String).map { $0 == "1" || $0.lowercased() == "yes" || $0.lowercased() == "true" } ?? false) }

func png(_ img: NSImage) -> Data? {
    var r = NSRect(x: 0, y: 0, width: 256, height: 256)
    guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

// MARK: main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Started by the Hither menu bar app, which restarts us if we die: go when it goes.
let parentWatch = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
parentWatch.setEventHandler { exit(0) }
parentWatch.resume()
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)   // a hung app can't stall us for AX's default 6 s
if !CGPreflightScreenCaptureAccess() { log("requesting Screen Recording permission"); CGRequestScreenCaptureAccess() }
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    log("requesting Accessibility permission")
}

var sessions: [ObjectIdentifier: Session] = [:]
// Only paired Macs get in. The app restarts us when pairings change.
let peers = Pairings.load().peers
if peers.isEmpty { log("not paired with any Mac yet") }
let listener = try! NWListener(using: tlsParams(psks: peers.map { ($0.id, $0.token) }), on: port)
listener.newConnectionHandler = { conn in
    let s = Session(conn)
    let id = ObjectIdentifier(s)
    s.onEnd = { DispatchQueue.main.async { sessions[id] = nil } }
    sessions[id] = s
}
listener.stateUpdateHandler = { log("listener: \($0)") }
listener.start(queue: .main)
Dark.start()

/// New windows here show up on the client by themselves when they're plausibly the user's: they appeared within
/// 15 s of input through a proxy (Cmd-N, File › New Window, opening a project, launching an app), or their app is
/// already being streamed. Anything else (someone using this Mac directly, random popups) stays put.
func watchWindows() {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return }
    var fresh: [Item] = []
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let id = w[kCGWindowNumber as String] as? CGWindowID, !knownWindows.contains(id) else { continue }
        guard watchPrimed else { knownWindows.insert(id); continue }
        let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let f = (w[kCGWindowBounds as String]).flatMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) } ?? .zero
        guard f.width > 100, f.height > 100,
              CACurrentMediaTime() - lastWindowInputAt < 15 || sessions.values.contains(where: { $0.pid == pid }),
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              let bundle = app.bundleIdentifier, !isOurs(bundle), !launchingApps.contains(bundle)
        else { knownWindows.insert(id); continue }
        // only real windows: sheets and dialogs already show inside their parent's stream
        let contained = list.contains { other in
            guard (other[kCGWindowNumber as String] as? CGWindowID) != id,
                  (other[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (other[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = other[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(f)
        }
        guard let independent = isIndependentWindow(pid: pid, id: id, hasContainingWindow: contained) else {
            // brand-new windows can take a moment to appear to Accessibility; give it ~3 s
            axTries[id, default: 0] += 1
            if axTries[id]! >= 6 { knownWindows.insert(id); axTries[id] = nil }
            continue
        }
        knownWindows.insert(id)
        axTries[id] = nil
        if independent {
            fresh.append(Item(id: Int(id), app: app.localizedName ?? "", bundle: bundle, title: w[kCGWindowName as String] as? String ?? ""))
        }
    }
    watchPrimed = true
    guard !fresh.isEmpty else { return }
    log("new windows: \(fresh.map { "\($0.app) '\($0.title)'" }.joined(separator: ", "))")
    watchers.values.forEach { $0.announce(fresh) }
}
var axTries: [CGWindowID: Int] = [:]

/// nil = Accessibility doesn't list this window (yet).
func isIndependentWindow(pid: pid_t, id: CGWindowID, hasContainingWindow: Bool) -> Bool? {
    guard let w = axWindow(pid: pid, id: id) else { return nil }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &v) == .success else { return nil }
    guard (v as? String) == kAXStandardWindowSubrole else { return false }

    var parentIsWindow = false
    if AXUIElementCopyAttributeValue(w, kAXParentAttribute as CFString, &v) == .success,
       let parent = v, CFGetTypeID(parent) == AXUIElementGetTypeID() {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXRoleAttribute as CFString, &role)
        parentIsWindow = (role as? String) == kAXWindowRole
    }
    let controls: [Bool?] = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute].map { key in
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(w, key as CFString, &value) {
        case .success: return value != nil
        case .attributeUnsupported, .noValue: return false
        default: return nil
        }
    }
    let hasControls: Bool? = controls.contains(true) ? true : controls.contains(where: { $0 == nil }) ? nil : false
    var settable = DarwinBoolean(false)
    let sizeResult = AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
    let traits = WindowTraits(standard: true, parentIsWindow: parentIsWindow, hasWindowControls: hasControls,
                              resizable: sizeResult == .success ? settable.boolValue : nil, hasContainingWindow: hasContainingWindow)
    return traits.isIndependent
}
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in watchWindows() }

app.run()
