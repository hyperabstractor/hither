import Shared
import SwiftUI
import UIKit

/// One window of the app (a scene): the session it shows, if any, and the window scene it's in.
final class SceneModel: ObservableObject {
    let key = UUID().uuidString
    @Published fileprivate(set) var shown: RemoteWindow?
    fileprivate(set) weak var windowScene: UIWindowScene?
    var scale: Double { windowScene.map { Double($0.screen.scale) } ?? 2 }
}

/// Every session open on this device, in any of its windows: a Mac's Desktop or one of its windows each, with its
/// own connection. Opening what's already open shows that session (or brings forward the window showing it: a
/// session's picture is in one place at a time). Going Home leaves them open; one closes when you close it, when it
/// closes on the Mac, or when its Mac is unpaired.
///
/// The bookkeeping is SessionBook's: where each session is follows from it (`sync`), and each RemoteWindow does what
/// that means for its connection, input and sound. Everything here runs on the main queue.
final class Sessions: ObservableObject {
    @Published private(set) var all: [RemoteWindow] = []   // in the order they opened
    let macs: Macs

    private var book = SessionBook()
    private var windows: [UUID: RemoteWindow] = [:]
    private var scenes: [String: Weak] = [:]
    private var persistentIDs: [String: String] = [:]   // scene key → its UISceneSession's, once known
    private var audioOwner: UUID?
    private var shownBefore: [String: UUID] = [:]
    private var observers: [NSObjectProtocol] = []
    private var tick: Timer?
    private var syncing = false

    private struct Weak { weak var model: SceneModel? }
    private var now: Double { CACurrentMediaTime() }

    init(macs: Macs) {
        self.macs = macs
        macs.sessions = self
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.appInBackground(true)
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.appInBackground(false)
            },
            nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
                self?.lowOnMemory()
            },
            nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { [weak self] n in
                if let s = n.object as? UIWindowScene { self?.disconnected(s) }
            },
        ]
        // hidden sessions hang up after a while (SessionBook.parkedLimit)
        tick = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.sync() }
    }

    func window(_ id: UUID) -> RemoteWindow? { windows[id] }

    // MARK: scenes

    func register(_ scene: SceneModel) {
        scenes[scene.key] = Weak(model: scene)
        sync()
    }

    func attach(_ scene: SceneModel, to ws: UIWindowScene) {
        guard scene.windowScene !== ws else { return }
        scene.windowScene = ws
        persistentIDs[scene.key] = ws.session.persistentIdentifier
    }

    func phase(_ scene: SceneModel, _ p: ScenePhase) {
        book.setState(p == .active ? .active : p == .inactive ? .inactive : .background, of: scene.key, now: now)
        sync()
    }

    /// The window that shows `w`, if it's in another one than `scene`.
    func elsewhere(_ w: RemoteWindow, from scene: SceneModel) -> Bool {
        book.scene(showing: w.id).map { $0 != scene.key } ?? false
    }

    /// Bring that window forward (it shows the session wanted).
    private func activate(_ key: String) {
        guard let ws = scenes[key]?.model?.windowScene else { return }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: ws.session)) { e in
            log("couldn't bring that window forward: \(e.localizedDescription)")
        }
    }

    /// A window was disconnected: closed, or let go of by iOS to save memory (it may come back, restored). What it
    /// showed hangs up and waits, until it's shown again or the window is discarded.
    private func disconnected(_ ws: UIWindowScene) {
        guard let key = scenes.first(where: { $0.value.model?.windowScene === ws })?.key
                ?? persistentIDs.first(where: { $0.value == ws.session.persistentIdentifier })?.key else { return }
        forget(scene: key)
        sync()
    }

    private func forget(scene key: String) {
        book.sceneGone(key, persistentID: persistentIDs[key], now: now)
        scenes[key] = nil
        persistentIDs[key] = nil
        shownBefore[key] = nil
    }

    /// Windows closed for good (the app switcher, or closed in Stage Manager): their sessions close too.
    func discarded(_ persistentIDs: Set<String>) {
        book.discarded(persistentIDs).forEach { windows[$0]?.finish() }
    }

    // MARK: opening, showing, closing

    /// The session for `item` on `mac`: the one open for it, or a new one (connecting, hidden until shown).
    @discardableResult
    func session(for item: Item, on mac: Peer, scale: Double) -> RemoteWindow {
        macs.remember(item, on: mac)
        let t = SessionTarget(mac: mac.id, bundle: item.bundle, window: item.id)
        let (id, new) = book.add(t, id: UUID(), now: now, appWindows: appWindows(item, on: mac))
        if new { windows[id] = RemoteWindow(id: id, mac: mac, item: item, macs: macs, sessions: self, scale: scale) }
        sync()
        return windows[id]!
    }

    /// Show `item` in `scene`: its open session, or a new one.
    func open(_ item: Item, on mac: Peer, in scene: SceneModel) {
        show(session(for: item, on: mac, scale: scene.scale), in: scene)
    }

    /// Show `w` in `scene` (what it showed stays open, hidden); if another window shows it, that one comes forward.
    func show(_ w: RemoteWindow, in scene: SceneModel) {
        switch book.show(w.id, in: scene.key, now: now) {
        case .here?: w.sceneScale = scene.scale   // only where it's shown: another window may be on another screen
        case .elsewhere(let other)?: activate(other)
        case nil: break
        }
        sync()
    }

    /// Home in `scene`: what it showed stays open.
    func home(_ scene: SceneModel) {
        book.home(scene.key, now: now)
        sync()
    }

    func close(_ w: RemoteWindow) { w.finish() }

    func closeAll() { windows.values.forEach { $0.finish() } }

    /// Before its pairing goes: every session of that Mac closes, hidden ones too, and nothing of theirs comes back
    /// (a finished RemoteWindow never connects again, and late messages find it done).
    func closeAll(of mac: Peer) {
        for id in book.removeAll(mac: mac.id, now: now) { windows.removeValue(forKey: id)?.finish() }
        sync()
    }

    /// `w` finished (closed here or on the Mac, or a duplicate): gone, and a window that showed it shows the one it
    /// showed before, or its Home.
    func ended(_ w: RemoteWindow) {
        guard windows.removeValue(forKey: w.id) != nil else { return }
        book.remove(w.id, now: now)
        sync()
    }

    /// The host said what `w` shows (the app's main window is this one, the main display that one). Already open in
    /// another session: that one stays, shown where `w` was, and `w` closes.
    func resolved(_ w: RemoteWindow) {
        guard let keepID = book.resolve(w.id, to: w.target), let keep = windows[keepID] else { return }
        let key = book.scene(showing: w.id)
        macs.flash("\(keep.title) is already open: showing it")
        w.finish()
        if let key, let scene = scenes[key]?.model { show(keep, in: scene) }
        // closing `w` lets the Mac put the window back as `w` found it, whenever it gets to that: `keep` asks for
        // its size again now, and once more if the window then changes from what it asked for
        keep.fitAgain()
    }

    /// The Mac opened a window because of what `w` did: show it in `w`'s place (`w` stays open).
    func follow(_ item: Item, from w: RemoteWindow) {
        guard let key = book.scene(showing: w.id), let scene = scenes[key]?.model else { return }
        open(item, on: w.mac, in: scene)
    }

    func isOpen(_ item: Item, on mac: Peer) -> Bool {
        book.match(SessionTarget(mac: mac.id, bundle: item.bundle, window: item.id), appWindows: appWindows(item, on: mac)) != nil
    }

    /// The windows `mac` lists for `item`'s app: with just one, a session still opening that app is opening it.
    private func appWindows(_ item: Item, on mac: Peer) -> [Int] {
        (macs.windows[mac.id] ?? []).filter { $0.bundle == item.bundle }.map(\.id)
    }

    // MARK: events from the Macs

    /// New windows there: for the session of that Mac on screen that was used last, which may show one.
    func appeared(_ items: [Item], on mac: Peer) {
        if let id = book.newWindows(on: mac.id) { windows[id]?.appeared(items) }
    }

    /// Each session of that Mac (a hidden one when it's next shown).
    func codecChanged(_ codec: String, on mac: Peer) {
        windows.values.filter { $0.mac.id == mac.id }.forEach { $0.codecChanged(codec) }
    }

    /// Input sent by hand to a session on screen: the sound follows the session used last. (Not keys and buttons
    /// let go of when it's hidden or its window goes inactive: RemoteWindow doesn't count those.)
    func touched(_ w: RemoteWindow) {
        book.touch(w.id, now: now)
        if !syncing && book.audioOwner != audioOwner { sync() }   // during one (keys let go of on hiding): it sees to it
    }

    // MARK: the app

    private func appInBackground(_ b: Bool) {
        book.setAppBackground(b)
        sync()
    }

    /// Hidden sessions let go of their connections and pictures; what they show and their zoom stay.
    private func lowOnMemory() {
        for (id, w) in windows where !book.place(id).shown { w.pause(droppingPicture: true) }
    }

    /// Everything follows the book: what each window shows, where each session is (and so its connection), who
    /// plays sound.
    private func sync() {
        syncing = true
        defer { syncing = false }
        let t = now
        for (key, s) in scenes where s.model == nil { forget(scene: key) }   // gone without a disconnect seen
        for s in scenes.values.compactMap(\.model) {
            let w = book.shown[s.key].flatMap { windows[$0] }
            if s.shown !== w { s.shown = w }
        }
        for (id, w) in windows { w.move(to: book.place(id), now: t) }
        let owner = book.audioOwner
        for (id, w) in windows { w.audioOwner = id == owner }
        if owner != audioOwner {
            audioOwner = owner
            AudioOut.shared.hand(to: owner.flatMap { windows[$0] }.map(ObjectIdentifier.init))
        }
        let ordered = book.sessions.compactMap { windows[$0.id] }
        if ordered.map(\.id) != all.map(\.id) { all = ordered }
        if book.shown != shownBefore {   // which window shows what changed: lists that say so are out of date
            shownBefore = book.shown
            objectWillChange.send()
        }
    }
}

/// The window scene a SwiftUI view is in.
struct SceneProbe: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.found = found
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ v: Probe, context: Context) { v.found = found }

    final class Probe: UIView {
        var found: (UIWindowScene) -> Void = { _ in }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let s = window?.windowScene { found(s) }
        }
    }
}
