import Foundation
import Network
import os
import Shared
import UIKit

/// What's on screen: one Mac window, or the Mac's whole Desktop, over its own connection. Like a proxy window on the
/// Mac, minus the window: it asks the Mac to size the real window to fit ("restore" puts it back when the connection
/// ends), and it reconnects after a Wi-Fi blip or when the app comes back to the front. It can switch to another
/// window of the same Mac (a new one the app opened, or one picked from the Windows menu); when the one shown closes,
/// it goes back to the one before.
///
/// Video comes over UDP once the host's datagrams get through (the shared VideoLink), else over TCP; input goes over
/// both, numbered, and the host applies each once, in order.
final class RemoteWindow: ObservableObject {
    let mac: Peer
    weak var macs: Macs?
    private(set) var item: Item       // a window (its ID pins it), an app (ID 0: its main window) or the Desktop
    var isDesktop: Bool { item.bundle == desktopApp }
    /// The window's ID, or the Mac display's for a Desktop (which can change: displays come and go over there).
    private(set) var windowID: Int
    let view = StreamView()
    @Published var title = ""
    @Published var status = "Connecting…"   // empty while the picture is live
    @Published var latency = ""
    @Published var closed = false           // gone on the Mac, or never found: leave the stream screen
    /// Showing something else now: the controls follow.
    var onSwitch: () -> Void = {}

    private var wire: Wire?
    private let activeWire = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)   // video and audio arrive off main
    private var link: VideoLink?             // video over UDP, once the host offers it
    private var viaUDP = false               // a datagram frame was shown: TCP frames still on their way are older
    private var resetting = 0                // "udpoff" resets of the link not finished yet: frames until then are stale
    private var inputN: UInt32 = 0           // this connection's input order (Msg.n)
    private var askedLTR = false             // this connection asked for H.264 long-term references
    private var opened = false               // this connection has its window; resizes can go out
    private var requested: CGSize?           // the window size last asked for on this connection
    private var shaped: (size: CGSize, native: Bool)?   // a Desktop: what the host was last told
    private var shapeLater: DispatchWorkItem?
    private var retries = 0
    private var host = ""                    // the name this connection dialed (see Reach)
    private var done = false, paused = false
    private(set) var lastInputAt = -Double.infinity
    private var history: [Item] = []         // shown before, newest last: where to go back to
    private var menuSeq: UInt32 = 0
    private var menuReplies: [UInt32: ([MenuEntry]?) -> Void] = [:]

    init(mac: Peer, item: Item, macs: Macs?) {
        self.mac = mac; self.item = item; self.macs = macs
        windowID = item.id
        title = Self.title(of: item, on: mac)
        view.send = { [weak self] in self?.send($0) }
        view.onWantSize = { [weak self] in self?.resize($0) }
        view.onLatency = { [weak self] ms in self?.latency = "\(ms) ms" }
        configureView()
        connect()
    }

    static func title(of item: Item, on mac: Peer) -> String {
        item.bundle == desktopApp ? "\(mac.name) Desktop" : item.title.isEmpty ? item.app : item.title
    }

    /// The display this device is on: 2 or 3 = Retina, so the host may capture at 2x (and pick HiDPI modes).
    static var screenScale: Double {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return Double(scene?.traitCollection.displayScale ?? 2)
    }

    // MARK: Desktop: Adaptive or Native

    /// Native keeps the Mac's screen at its own resolution; Adaptive has a dark one take the mode nearest this view
    /// (only while Keep Screen Dark is on there: nobody sees its monitors change). Native unless chosen otherwise:
    /// a screen the size of a phone or tablet would crowd every window on the Mac. Remembered per Mac.
    var native: Bool {
        get { UserDefaults.standard.object(forKey: "desktop.native.\(mac.id)") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "desktop.native.\(mac.id)")
            configureView()
            view.setZoom(nil)
            sendShape()
        }
    }

    private func configureView() {
        view.zoomable = isDesktop
        // Adaptive: the Mac's screen matches this view, shown pixel for pixel; never blown up
        view.maxFit = isDesktop && !native ? 1 : .greatestFiniteMagnitude
    }

    // MARK: connection

    func connect() {
        guard !done, !paused, wire == nil else { return }
        let hosts = Reach.hosts(mac)
        host = hosts[retries % hosts.count]   // each retry tries the Mac's other name
        let w = Wire(NWConnection(host: NWEndpoint.Host(host), port: port, using: Pairings.load().tls(to: host)),
                     queue: DispatchQueue(label: "wire"))
        w.onClose = { [weak self, weak w] in
            DispatchQueue.main.async {
                guard let self, let w, self.wire === w else { return }
                self.drop()   // as for a hang-up here, but nothing held can be let go of: the session is gone
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
        w.onMsg = { [weak self, weak w] m in
            DispatchQueue.main.async { [weak self, weak w] in
                guard let self, let w, self.wire === w, !self.done else { return }
                if m.t == "udp", let tag = m.f { return self.startLink(w, tag: tag) }
                self.handle(m)
            }
        }
        wire = w
        opened = false
        requested = nil
        shaped = nil
        inputN = 0
        viaUDP = false
        activeWire.withLock { $0 = ObjectIdentifier(w) }
        w.start()
        // No "hevc422": this device may not decode HEVC 4:2:2. LTR only while the Mac's codec is H.264: the host
        // keeps H.264 for a viewer that takes LTR, and the codec chosen here should mean what it says.
        askedLTR = (macs?.codec[mac.id] ?? "h264") == "h264"
        var m = Msg("open"); m.app = item.bundle; m.k = windowID
        m.caps = ["hevc", "audio", "restore", "udp", "twice"] + (askedLTR ? ["ltr"] : [])
        m.scale = Self.screenScale
        w.send(m)
        Reach.giveUpLater(on: w)
    }

    /// To the host. Input is numbered and goes over UDP too, once there's a link; TCP stays the backstop.
    func send(_ m: Msg) {
        guard let w = wire else { return }
        var m = m
        if inputTypes.contains(m.t) {
            inputN &+= 1
            m.n = inputN
            link?.sendInput(m)
            if m.t != "mouse" || m.k != 0 { lastInputAt = CACurrentMediaTime() }   // hovering isn't doing anything
        }
        w.send(m)
    }

    /// The host offered video over UDP, sealed with this connection's own secret. Video stays on TCP until a
    /// datagram frame arrives, and goes back to it if the host stops hearing from us ("udpoff").
    private func startLink(_ w: Wire, tag: UInt64) {
        guard wire === w, let secret = w.secret() else { return }
        let l = VideoLink(secret: secret, tag: tag, to: NWEndpoint.Host(host), port: videoPort)
        l.onFrame = { [weak self, weak w, weak l] d in
            DispatchQueue.main.async { [weak self, weak w, weak l] in
                // only this connection's current link, and none from before a fallback to TCP that's still settling
                guard let self, let w, let l, self.wire === w, self.link === l, self.resetting == 0, !self.done else { return }
                if !self.viaUDP { log("video over UDP"); self.viaUDP = true }
                self.view.show(d)
            }
        }
        link?.stop()
        link = l
        resetting = 0
        l.start()
    }

    private func stopLink() {
        link?.stop()
        link = nil
        viaUDP = false
        resetting = 0
    }

    /// The host stopped hearing our datagrams and sends video over TCP again. The link stays (the host takes UDP back
    /// once datagrams get through) but starts over; frames it handed on before that are older than the TCP ones and
    /// are dropped. Its reset reports back after the last of them, in order, so nothing newer is held back.
    private func fellBackToTCP() {
        log("video back on TCP")
        viaUDP = false
        guard let l = link else { return }
        resetting += 1
        l.reset { [weak self, weak l] in
            DispatchQueue.main.async { [weak self, weak l] in
                guard let self, let l, self.link === l, self.resetting > 0 else { return }
                self.resetting -= 1
            }
        }
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
            // a window must be the one asked for; a Desktop's display may have changed (the host falls back to the
            // main one when the last one is gone), and the next reconnect asks for this one
            guard id > 0, isDesktop || windowID == 0 || id == windowID else {
                log("rejected window \(id) from \(host); expected \(windowID)")
                return gone()
            }
            windowID = id
            item.id = isDesktop ? item.id : id
            opened = true
            view.live = true
            retries = 0
            Reach.worked(host, for: mac)
            status = ""
            if !isDesktop { if let t = m.title, !t.isEmpty { title = t } else if let a = m.app { title = a } }
            view.remoteSize = CGSize(width: m.w ?? 0, height: m.h ?? 0)
            AudioOut.shared.claim(ObjectIdentifier(self))
            if isDesktop {
                sendShape()
            } else {
                send(Msg("focus"))   // bring it to the front on the Mac, so the first tap and key land there
                resize(view.wantSize)
            }
        case "size": view.remoteSize = CGSize(width: m.w ?? 0, height: m.h ?? 0)
        case "title": if !isDesktop, let t = m.title, !t.isEmpty { title = t }
        case "closed": log(m.title ?? "closed"); gone()
        case "udpoff": fellBackToTCP()
        case "menu":
            if let seq = m.seq { menuReplies.removeValue(forKey: seq)?(m.menu ?? []) }
        default: break
        }
    }

    /// Ask for the window at this size. If the app won't go that small, the picture is scaled to fit instead.
    /// A Desktop is never resized: its shape goes to the host as "adapt" instead.
    func resize(_ s: CGSize) {
        if isDesktop { return shapeSoon() }
        guard opened, s.width > 0, s.height > 0, s != requested else { return }
        requested = s
        var m = Msg("resize"); m.w = s.width; m.h = s.height
        wire?.send(m)
    }

    /// Rotation, Split View and Stage Manager resize this view many times over; a display mode change is slow and
    /// rearranges the Mac's windows, so the host hears the size once it settles.
    private func shapeSoon() {
        shapeLater?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sendShape() }
        shapeLater = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// A Desktop: Adaptive tells the host this view's size (all the room there is, at this screen's scale), and a
    /// dark display there takes the mode nearest it; Native says to keep its own. The host answers with "size".
    func sendShape() {
        guard isDesktop, opened, let w = wire else { return }
        let s = CGSize(width: view.bounds.width.rounded(.down), height: view.bounds.height.rounded(.down))
        guard native || (s.width > 0 && s.height > 0) else { return }
        if let last = shaped, last.native == native, native || last.size == s { return }
        shaped = (s, native)
        var m = Msg("adapt")
        if !native { m.w = s.width; m.h = s.height; m.x = s.width; m.y = s.height; m.scale = Self.screenScale }
        w.send(m)
    }

    // MARK: switching

    /// Show `new` (another window or app of this Mac, or its Desktop) instead. The one shown now is let go (the Mac
    /// puts it back to its own size) and remembered, to go back to when `new` closes.
    func show(_ new: Item, remember: Bool = true) {
        guard !done else { return }
        let same = new.bundle == item.bundle && (new.bundle == desktopApp || (new.id != 0 && new.id == windowID))
        guard !same else { return }
        if remember, opened {
            history.removeAll { $0.bundle == item.bundle && $0.id == item.id }
            history.append(item)
            if history.count > 10 { history.removeFirst() }
        }
        view.releaseInput()
        drop()
        item = new
        windowID = new.id
        title = Self.title(of: new, on: mac)
        status = "Connecting…"
        latency = ""
        retries = 0
        view.reset()
        configureView()
        if !isDesktop { macs?.remember(new, on: mac) }
        onSwitch()
        connect()
    }

    /// New windows on the Mac (Cmd-N, File › New Window, a link that opened a browser): show the newest, as a Mac
    /// would open it in front, but only if they came from what was done here just now and a window is shown. On a
    /// Desktop they're already in the picture.
    func appeared(_ items: [Item]) {
        guard !isDesktop, opened, CACurrentMediaTime() - lastInputAt < 15,
              let new = items.last(where: { $0.id != windowID }) else { return }
        macs?.flash("\(new.app) opened a window: showing it. Windows goes back.")
        show(new)
    }

    /// What's shown closed on the Mac, or was never found: back to what was shown before, if it's still open there.
    private func gone() {
        let open = macs?.windows[mac.id] ?? []
        while let previous = history.popLast() {
            guard previous.bundle == desktopApp || previous.id == 0 || open.contains(where: { $0.id == previous.id }) else { continue }
            macs?.flash("\(title) closed")
            return show(previous, remember: false)
        }
        finish()
    }

    /// The Mac's codec changed. One that asked for LTR stays H.264 there, so ask again without it.
    func codecChanged(_ codec: String) {
        guard askedLTR, codec != "h264", wire != nil, !done, !paused else { return }
        view.releaseInput()
        drop()
        status = "Switching codec…"
        connect()
    }

    // MARK: the app's menus

    /// The menu at `path` (indices from the menu bar down; [] = the bar), read from the Mac app each time.
    func menu(_ path: [Int], _ done: @escaping ([MenuEntry]?) -> Void) {
        guard opened, !isDesktop, let w = wire else { return done(nil) }
        menuSeq &+= 1
        let seq = menuSeq
        menuReplies[seq] = done
        var m = Msg("menu"); m.path = path; m.seq = seq
        w.send(m)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.menuReplies.removeValue(forKey: seq)?(nil) }
    }

    func pressMenu(_ path: [Int]) {
        var m = Msg("press"); m.path = path
        wire?.send(m)
        lastInputAt = CACurrentMediaTime()   // File › New Window and the like are the user's doing
    }

    // MARK: lifecycle

    /// In the background iOS suspends the app and its connections. Hang up cleanly instead (the Mac puts the window
    /// back) and open it again on return.
    func pause() {
        view.releaseInput()
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
        view.releaseInput()
        done = true
        closed = true
        drop()
        AudioOut.shared.release(ObjectIdentifier(self), next: nil)
    }

    /// Hang up this connection: everything that belonged to it goes too (video link, pending shape and menu replies,
    /// and what the view held down, which it forgets; let go of it first with `view.releaseInput()` while connected).
    private func drop() {
        activeWire.withLock { $0 = nil }
        stopLink()
        shapeLater?.cancel()
        shapeLater = nil
        opened = false
        view.live = false
        let w = wire
        wire = nil
        w?.close()
        let waiting = menuReplies
        menuReplies = [:]
        waiting.values.forEach { $0(nil) }
    }
}
