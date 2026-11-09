import Foundation
import Network
import os
import Shared
import UIKit

/// A session: one Mac window, or the Mac's whole Desktop, over its own connection. Like a proxy window on the Mac,
/// minus the window: it asks the Mac to size the real window to fit ("restore" puts it back when the connection
/// ends), and it reconnects after a Wi-Fi blip or when it's shown again. What it shows stays the same for as long as
/// it's open (another window is another session: Sessions).
///
/// Sessions says where it is (`place`): on screen, it takes input and plays sound if it's the one used last; hidden,
/// it lets go of input and the Mac stops sending it video and sound, and after a while (or in the background) it
/// hangs up, keeping its zoom and what it shows, to reconnect when it's shown again.
///
/// Video comes over UDP once the host's datagrams get through (the shared VideoLink), else over TCP; input goes over
/// both, numbered, and the host applies each once, in order.
final class RemoteWindow: ObservableObject, Identifiable {
    let id: UUID
    let mac: Peer
    weak var macs: Macs?
    weak var sessions: Sessions?
    private(set) var item: Item       // a window (its ID pins it), an app (ID 0: its main window) or the Desktop
    var isDesktop: Bool { item.bundle == desktopApp }
    /// The window's ID, or the Mac display's for a Desktop (which can change: displays come and go over there).
    private(set) var windowID: Int
    let view = StreamView()
    @Published var title = ""
    @Published var status = "Connecting…"   // empty while the picture is live
    @Published var latency = ""
    @Published private(set) var closed = false   // closed here, gone on the Mac, or never found
    @Published private(set) var place = SessionPlace.parked(since: CACurrentMediaTime())
    @Published private(set) var paused = false   // hung up on purpose (hidden a while, or in the background)
    /// It plays the Mac app's sound (Sessions picks the one on screen used last).
    var audioOwner = false { didSet { if audioOwner != oldValue { tellHost() } } }
    /// The controller showing it, if any: one at a time (a view is in one place only).
    weak var attached: AnyObject?
    /// The scale of the screen it's shown on (2 or 3 = Retina), while it isn't in a window to ask.
    var sceneScale: Double

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
    private var done = false
    private(set) var lastInputAt = -Double.infinity
    private var sentVisible: Bool?, sentAudio: Bool?   // what the host was told on this connection
    private var reconnectWhenShown = false   // hidden when the codec changed: the new one, once it's looked at
    private var refitUntil = 0.0             // a duplicate closed: a size change before this is the Mac putting it back
    private var menuSeq: UInt32 = 0
    private var menuReplies: [UInt32: ([MenuEntry]?) -> Void] = [:]

    init(id: UUID, mac: Peer, item: Item, macs: Macs?, sessions: Sessions?, scale: Double) {
        self.id = id; self.mac = mac; self.item = item; self.macs = macs; self.sessions = sessions
        sceneScale = scale
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

    /// The display it's shown on: 2 or 3 = Retina, so the host may capture at 2x (and pick HiDPI modes).
    var screenScale: Double { view.window.map { Double($0.screen.scale) } ?? sceneScale }

    /// The same thing to Sessions: what it shows, on which Mac.
    var target: SessionTarget { SessionTarget(mac: mac.id, bundle: item.bundle, window: isDesktop ? windowID : item.id) }

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
        reconnectWhenShown = false   // this connection asks for the codec as it is now
        var m = Msg("open"); m.app = item.bundle; m.k = windowID
        m.caps = ["hevc", "audio", "restore", "udp", "twice"] + (askedLTR ? ["ltr"] : [])
        m.scale = screenScale
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
            // hovering isn't doing anything, nor is letting go of what's held (hidden, closing, its window inactive)
            if (m.t != "mouse" || m.k != 0) && !view.lettingGo {
                lastInputAt = CACurrentMediaTime()
                if place.shown { sessions?.touched(self) }
            }
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
            tellHost()
            sessions?.resolved(self)   // the same window or display already open in another session: that one stays
            guard !done else { return }
            fitHost()
        case "size":
            let s = CGSize(width: m.w ?? 0, height: m.h ?? 0)
            view.remoteSize = s
            // put back by a duplicate's ending (fitAgain): ask again, once
            if !isDesktop, CACurrentMediaTime() < refitUntil, let r = requested, r != s {
                refitUntil = 0
                requested = nil
                fitHost()
            }
        case "title": if !isDesktop, let t = m.title, !t.isEmpty { title = t }
        case "closed": log(m.title ?? "closed"); gone()
        case "udpoff": fellBackToTCP()
        case "menu":
            if let seq = m.seq { menuReplies.removeValue(forKey: seq)?(m.menu ?? []) }
        default: break
        }
    }

    /// On screen with a connection that has its window: bring it forward on the Mac (so the first tap and key land
    /// there) and ask for it at this view's size; a Desktop says its shape. The size comes from where the view is
    /// shown: one not laid out there yet (just shown again) says it once it is, not the size it had elsewhere.
    private func fitHost() {
        guard opened, place.shown else { return }
        if !isDesktop { send(Msg("focus")) }
        guard view.window != nil, view.bounds.width > 0 else { return view.setNeedsLayout() }
        if isDesktop { sendShape() } else { resize(view.wantSize) }
    }

    /// A duplicate session on this window closed, and the Mac puts the window back as that one found it, at some
    /// point: ask for this one's size again now, and if the window then changes from it (in the next few seconds),
    /// once more. Only once: an app that won't take the size isn't fought over.
    func fitAgain() {
        requested = nil
        shaped = nil
        refitUntil = CACurrentMediaTime() + 5
        fitHost()
    }

    /// Ask for the window at this size. If the app won't go that small, the picture is scaled to fit instead.
    /// A Desktop is never resized: its shape goes to the host as "adapt" instead. Not while hidden: it's laid out
    /// for wherever it's shown next.
    func resize(_ s: CGSize) {
        guard place.shown else { return }
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
        guard isDesktop, opened, place.shown, let w = wire else { return }
        let s = CGSize(width: view.bounds.width.rounded(.down), height: view.bounds.height.rounded(.down))
        guard native || (s.width > 0 && s.height > 0) else { return }
        if let last = shaped, last.native == native, native || last.size == s { return }
        shaped = (s, native)
        var m = Msg("adapt")
        if !native { m.w = s.width; m.h = s.height; m.x = s.width; m.y = s.height; m.scale = screenScale }
        w.send(m)
    }

    // MARK: new windows, closing

    /// New windows on the Mac (Cmd-N, File › New Window, a link that opened a browser): show the newest, as a Mac
    /// would open it in front, if it came from what was done here just now. It's a session of its own (this one
    /// stays open, a tap away in Sessions); one already open comes forward. On a Desktop they're in the picture.
    func appeared(_ items: [Item]) {
        guard !isDesktop, opened, place.shown, CACurrentMediaTime() - lastInputAt < 15,
              let new = items.last(where: { $0.id != windowID }) else { return }
        macs?.flash("\(new.app) opened a window: showing it. Sessions goes back.")
        sessions?.follow(new, from: self)
    }

    /// What's shown closed on the Mac, or was never found: this session closes (Sessions shows what was shown before).
    private func gone() {
        macs?.flash("\(title) closed")
        finish()
    }

    /// The Mac's codec changed. One that asked for LTR stays H.264 there, so ask again without it: now if it's on
    /// screen, else when it's next shown (a hidden one isn't woken for it).
    func codecChanged(_ codec: String) {
        guard askedLTR, codec != "h264", wire != nil, !done, !paused else { return }
        guard place.shown else { reconnectWhenShown = true; return }
        status = "Switching codec…"
        reconnect()
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
        view.resetTyping()   // Edit › Paste and the like change the text where typing goes
        lastInputAt = CACurrentMediaTime()   // File › New Window and the like are the user's doing
    }

    // MARK: where it is

    /// Sessions moved it (shown, hidden, background) or time passed: input, connection and what the host sends
    /// follow. Hiding lets go of whatever's held and puts the keyboard away, and nothing resizes while hidden.
    func move(to p: SessionPlace, now: Double) {
        guard !done else { return }
        let wasShown = place.shown, wasPaused = paused
        if p != place { place = p }
        if wasShown && !p.shown {
            view.releaseInput()
            if view.isTyping { view.stopTyping() }
            shapeLater?.cancel()
            shapeLater = nil
        }
        switch SessionBook.connection(p, now: now) {
        case .connect: if paused { resume() }
        case .drop: if !paused { pause() }
        case .keep: break
        }
        if p.shown && !wasShown && !wasPaused { revealed() }   // after a pause it has a new connection already
        tellHost()
    }

    /// Shown again. The picture carries on from the one there if the decoder still has it (the Mac sends what changed
    /// meanwhile); one that failed while hidden, or a codec change waiting, takes a new connection, which starts with
    /// a whole frame. A Mac it gave up on reaching is tried again.
    private func revealed() {
        guard !paused else { return }
        if wire == nil {
            guard retries >= 30 else { return }   // a reconnect is on its way
            retries = 0
            status = "Connecting…"
            return connect()
        }
        if reconnectWhenShown || view.pictureFailed {
            reconnectWhenShown = false
            status = "Reconnecting…"
            return reconnect()
        }
        fitHost()
    }

    /// The host sends this connection video and sound only while it's on screen, and sound only to the one Sessions
    /// picked: a hidden session costs the Mac no encoding and the network nothing but keepalives.
    private func tellHost() {
        guard opened, let w = wire else { return }
        let visible = place.shown, audio = visible && audioOwner
        if sentVisible != visible {
            var m = Msg("visible"); m.down = visible
            w.send(m)
            sentVisible = visible
        }
        if sentAudio != audio {
            var m = Msg("audio"); m.down = audio
            w.send(m)
            sentAudio = audio
        }
    }

    private func reconnect() {
        view.releaseInput()
        drop()
        connect()
    }

    /// Hang up, keeping what it shows and its zoom, to connect again when it's shown (`move`). Low on memory, the
    /// picture goes too: the next connection starts with a whole frame.
    func pause(droppingPicture: Bool = false) {
        guard !done else { return }
        if !paused {
            view.releaseInput()
            paused = true
            drop()
        }
        if droppingPicture { view.dropPicture() }
    }

    private func resume() {
        guard paused else { return }
        paused = false
        retries = 0
        status = "Reconnecting…"
        connect()
    }

    /// Closed (here, or on the Mac): hang up for good and leave Sessions.
    func finish() {
        guard !done else { return }
        view.releaseInput()
        done = true
        closed = true
        drop()
        // the sound goes to the next session on screen, or nobody, through Sessions' one handover (which drops what
        // this one had queued)
        if let sessions { sessions.ended(self) } else { AudioOut.shared.hand(to: nil) }
    }

    /// What it's doing, in a few words, for lists.
    var summary: String {
        if closed { return "Closed" }
        if paused { return place == .background ? "Disconnected in the background" : "Suspended: reconnects when opened" }
        if !status.isEmpty { return status }
        return place.shown ? latency.isEmpty ? "Connected" : "Connected · \(latency)" : "Hidden, still connected"
    }

    /// Hang up this connection: everything that belonged to it goes too (video link, pending shape and menu replies,
    /// and what the view held down, which it forgets; let go of it first with `view.releaseInput()` while connected).
    private func drop() {
        activeWire.withLock { $0 = nil }
        stopLink()
        shapeLater?.cancel()
        shapeLater = nil
        opened = false
        sentVisible = nil
        sentAudio = nil
        view.live = false
        let w = wire
        wire = nil
        w?.close()
        let waiting = menuReplies
        menuReplies = [:]
        waiting.values.forEach { $0(nil) }
    }
}
