import AppKit
import ScreenCaptureKit
import VideoToolbox
import Network
import Shared

// Host: runs on the Mac that owns the apps. Streams one window per connection, injects the viewer's input.

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ el: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let panelService = "com.apple.appkit.xpc.openAndSavePanelService"  // Open/Save dialogs live in this process
let bitrate = Int(ProcessInfo.processInfo.environment["UC_BITRATE"] ?? "") ?? 40_000_000
var lastRaised: CGWindowID = 0   // the window that currently has input focus on this Mac
/// All input injection runs here: it's serialized system-wide anyway, and an app switch (with its wait)
/// must never stall a session's capture/encode/ack queue.
let inputQ = DispatchQueue(label: "input")
/// Menu reads and presses: AX calls into the app can block (a menu item that runs a modal panel), so keep them
/// off both the session and input queues.
let menuQ = DispatchQueue(label: "menu")
var lastInputAt: CFTimeInterval = 0
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

final class Session: NSObject, SCStreamOutput, SCStreamDelegate {
    let q = DispatchQueue(label: "session")
    let wire: Wire
    var onEnd: () -> Void = {}

    var pid: pid_t = 0
    var windowID: CGWindowID = 0
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
    var pending: CVPixelBuffer?      // newest frame we skipped while the viewer was behind
    var inputSeq: UInt32 = 0         // last injected keyDown seq, stamped on frames for the latency meter
    var scrollAcc = (0.0, 0.0)

    // 5-second stats, logged from poll()
    var appName = ""
    var inflight: [CFTimeInterval] = []   // submit times of unacked frames, oldest first
    var nFrames = 0, nBytes = 0, nKeys = 0, nDelayed = 0, nRaises = 0
    var encMs = 0.0, raiseMs = 0.0, rtts: [Double] = []
    var lastEncode: CFTimeInterval = 0
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
        case "apps": Task { apps() }
        case "open": Task { await open(m.app ?? "", m.title, id: CGWindowID(m.k ?? 0)) }
        case "ack":
            unacked -= 1
            if !inflight.isEmpty { rtts.append((CACurrentMediaTime() - inflight.removeFirst()) * 1000) }
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
                self.focus(force: false)   // e.g. File › Save acts on the key window, so make it ours
                menuQ.async { if let e = self.menuItems(at: path.dropLast())?[safe: path.last ?? -1] { AXUIElementPerformAction(e, kAXPressAction as CFString) } }
            }
        case "visible":   // proxy window fully hidden (minimized, other Space, covered, app hidden) → encode nothing
            visible = m.down ?? true
            log("\(appName) \(visible ? "visible" : "hidden — paused")")
            pump()   // newly visible: send whatever changed while hidden
        case "focus": if pid != 0 { inputQ.async { self.focus(force: false) } }   // proxy became the active window on the client
        case "resize": resize(m.w ?? frame.width, m.h ?? frame.height)
        default:
            let f = frame
            inputQ.async { self.input(m, frame: f) }
        }
    }

    // MARK: window selection

    func candidates(_ c: SCShareableContent) -> [SCWindow] {
        c.windows.filter { $0.windowLayer == 0 && $0.frame.width > 100 && $0.owningApplication != nil
            && $0.owningApplication!.bundleIdentifier != Bundle.main.bundleIdentifier }
    }

    func list() async {
        let c: SCShareableContent
        do { c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) } catch { return fail("\(error)") }
        var m = Msg("windows")
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
                guard let b = Bundle(path: path), let id = b.bundleIdentifier, id != Bundle.main.bundleIdentifier,
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
        let a = app.lowercased()
        return candidates(c).first(where: { $0.windowID == id }) ?? candidates(c).filter({
            let o = $0.owningApplication!
            return (o.applicationName.lowercased().contains(a) || o.bundleIdentifier.lowercased() == a)
                && (title == nil || ($0.title ?? "").localizedCaseInsensitiveContains(title!))
        }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
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
                if case .hostPort(_, let port) = wire.conn.endpoint { appName = "\(owner.applicationName):\(port)" }
                else { appName = owner.applicationName }
                windowID = win.windowID
                ax = axWindow(pid: pid, id: windowID)
                frame = win.frame
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

    /// (Re)attach capture to whatever display the window is on *now*. Displays come and go
    /// (Screen Sharing connects/disconnects, monitor sleeps), so a stopped stream retries instead of dying.
    func capture() async {
        guard !ended else { return }
        guard q.sync(execute: readFrame) != nil else { fail("window closed"); return q.async { self.wire.close() } }
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
            try await s.startCapture()
            q.async {
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
        log(why)
        var m = Msg("closed"); m.title = why
        wire.send(m)
    }

    /// Capture the whole app on the display (so menus, sheets, popovers, Open/Save panels come along),
    /// cropped to our window, minus the app's *other* main windows so they don't bleed through.
    func filter(_ c: SCShareableContent) -> SCContentFilter {
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
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.showsCursor = false
        c.queueDepth = 5
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
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
              let b = info[kCGWindowBounds as String] else { return nil }
        if let t = info[kCGWindowName as String] as? String, t != title {
            if title != nil { var m = Msg("title"); m.title = t; wire.send(m) }
            title = t
        }
        return CGRect(dictionaryRepresentation: b as! CFDictionary)
    }

    func poll() {
        guard let r = readFrame() else { fail("window closed"); return wire.close() }
        if r != frame {
            frame = r
            stream?.updateConfiguration(config()) { if let e = $0 { log("updateConfiguration: \(e)") } }
            var m = Msg("size"); m.w = r.width; m.h = r.height
            wire.send(m)
        }
        ticks += 1
        if ticks % 20 == 0 && (nFrames > 0 || nRaises > 0) {
            let r = rtts.sorted()
            log(String(format: "stats %@: %d fps %.1f Mbps keyframes=%d encode=%.1fms delivery med/max=%.0f/%.0fms delayed=%d raises=%d (%.0fms avg)",
                       appName, nFrames / 5, Double(nBytes) * 8 / 5e6, nKeys, nFrames > 0 ? encMs / Double(nFrames) : 0,
                       r.isEmpty ? 0 : r[r.count / 2], r.last ?? 0, nDelayed, nRaises, nRaises > 0 ? raiseMs / Double(nRaises) : 0))
            nFrames = 0; nBytes = 0; nKeys = 0; nDelayed = 0; nRaises = 0; encMs = 0; raiseMs = 0; rtts = []
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
        var size = CGSize(width: w, height: h)
        var pos = frame.origin
        if let d = display?.frame, !d.contains(CGRect(origin: pos, size: size)) { pos = d.origin }  // AX clamps below the menu bar
        // Chromium/Electron apps ignore AX resizes while AXEnhancedUserInterface is on; switch it off around
        // the resize, and do size→position→size like Rectangle (a move can be refused until the size fits).
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
        if stream != nil { poll() } else { frame = readFrame() ?? frame }
    }

    // MARK: capture → encode → send

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = sb.imageBuffer,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[.status] as? Int).flatMap({ SCFrameStatus(rawValue: $0) }) == .complete else { return }
        if pending != nil { nDelayed += 1 }
        pending = px   // keep only the newest frame
        pump()
    }

    /// Encode the newest captured frame once the viewer has caught up (≤2 frames in flight). The Mac has one
    /// hardware encoder, so: focused window full rate; visible background ≤10 fps (2 while you type); hidden paused.
    func pump() {
        guard visible, let p = pending, unacked < 2 else { return }
        let busy = CACurrentMediaTime() - lastInputAt < 0.5
        let gap = windowID == lastRaised ? 0 : busy ? 0.5 : 0.1
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

    func stream(_ s: SCStream, didStopWithError error: Error) {
        q.async {
            log("capture stopped: \(error.localizedDescription) — reattaching")
            self.stream = nil
            self.retry()
        }
    }

    func encode(_ px: CVPixelBuffer) {
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
            self.q.async { self.nFrames += 1; self.nBytes += p.count; self.encMs += ms; if p[4] != 0 { self.nKeys += 1 } }
        }
    }

    func makeEncoder(_ size: (Int, Int)) {
        if let e = encoder { VTCompressionSessionInvalidate(e) }
        encoder = nil
        var s: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(size.0), height: Int32(size.1), codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { return log("encoder create failed: \(st)") }
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
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
        guard pid != 0 else { return }
        if m.t != "mouse" || m.k != 0 { lastInputAt = CACurrentMediaTime() }   // hover doesn't count
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
        case "flags":
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(m.k ?? 0), keyDown: true) else { return }
            e.type = .flagsChanged
            e.flags = flags
            e.post(tap: .cghidEventTap)
        case "mouse":
            let b = min(m.b ?? 0, 2), kind = m.k ?? 0
            if kind == 1 { focus(force: true) }
            // hover lands on whatever is topmost at that point here; skip it unless that's our window
            if kind == 0 && lastRaised != windowID { return }
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
        let id = ObjectIdentifier(self)
        DispatchQueue.main.async { watchers[id] = nil }
        timer?.cancel(); timer = nil
        stream?.stopCapture { _ in }; stream = nil
        if let e = encoder { VTCompressionSessionInvalidate(e) }; encoder = nil
        onEnd()
    }
}

/// Video packet: [inputSeq u32][paramCount u8]([len u16][SPS/PPS])*[AVCC sample data]
func packet(_ sb: CMSampleBuffer, _ seq: UInt32) -> Data {
    var d = Data()
    d.put(seq)
    let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
    let isKey = !((atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    var params: [Data] = []
    if isKey, let fd = sb.formatDescription {
        var n = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                           parameterSetSizeOut: nil, parameterSetCountOut: &n, nalUnitHeaderLengthOut: nil)
        for i in 0..<n {
            var p: UnsafePointer<UInt8>?, len = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                               parameterSetSizeOut: &len, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let p { params.append(Data(bytes: p, count: len)) }
        }
    }
    d.put(UInt8(params.count))
    for p in params { d.put(UInt16(p.count)); d.append(p) }
    if let bb = sb.dataBuffer {
        let len = CMBlockBufferGetDataLength(bb)
        var body = Data(count: len)
        body.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        d.append(body)
    }
    return d
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

func isTrue(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? String).map { $0 == "1" || $0.lowercased() == "yes" || $0.lowercased() == "true" } ?? false) }

func png(_ img: NSImage) -> Data? {
    var r = NSRect(x: 0, y: 0, width: 256, height: 256)
    guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

// MARK: main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)   // a hung app can't stall us for AX's default 6 s
if !CGPreflightScreenCaptureAccess() { log("requesting Screen Recording permission"); CGRequestScreenCaptureAccess() }
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
    log("requesting Accessibility permission")
}

var sessions: [ObjectIdentifier: Session] = [:]
let listener = try! NWListener(using: tlsParams(key: loadKey()), on: port)
listener.newConnectionHandler = { conn in
    let s = Session(conn)
    let id = ObjectIdentifier(s)
    s.onEnd = { DispatchQueue.main.async { sessions[id] = nil } }
    sessions[id] = s
}
listener.stateUpdateHandler = { log("listener: \($0)") }
listener.start(queue: .main)

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
              CACurrentMediaTime() - lastInputAt < 15 || sessions.values.contains(where: { $0.pid == pid }),
              let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
              let bundle = app.bundleIdentifier, !launchingApps.contains(bundle)
        else { knownWindows.insert(id); continue }
        // only real windows: sheets and dialogs already show inside their parent's stream
        guard let standard = isStandardWindow(pid: pid, id: id) else {
            // brand-new windows can take a moment to appear to Accessibility; give it ~3 s
            axTries[id, default: 0] += 1
            if axTries[id]! >= 6 { knownWindows.insert(id); axTries[id] = nil }
            continue
        }
        knownWindows.insert(id)
        axTries[id] = nil
        if standard {
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
func isStandardWindow(pid: pid_t, id: CGWindowID) -> Bool? {
    guard let w = axWindow(pid: pid, id: id) else { return nil }
    var v: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &v)
    return (v as? String) == kAXStandardWindowSubrole
}
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in watchWindows() }

app.run()
