import Foundation

/// Where a viewer's session (one Mac window, or a Mac's Desktop) is. That decides what its connection does.
public enum SessionPlace: Equatable {
    case front                    // shown in a scene that's in front and active
    case inactive                 // shown, its scene inactive for a moment (Control Center, the app switcher): still on screen
    case parked(since: Double)    // open but not shown anywhere: connected for a while, then suspended
    case background               // its scene or the app is in the background, or its scene was disconnected

    public var shown: Bool { self == .front || self == .inactive }
}

/// A scene's state, as a SwiftUI ScenePhase says it.
public enum SceneState { case active, inactive, background }

/// What a session's connection should do.
public enum SessionConnection { case connect, keep, drop }

/// What a session shows: a window of a Mac (its ID; 0 = an app's main window, not known yet) or its Desktop (the
/// display's ID; 0 = the main one, not known yet).
public struct SessionTarget: Equatable {
    public var mac: String, bundle: String, window: Int
    public init(mac: String, bundle: String, window: Int) { self.mac = mac; self.bundle = bundle; self.window = window }

    public var desktop: Bool { bundle == desktopApp }

    /// Opening this would show what the session `open` already does: the same Desktop (the main one is any, until
    /// the host says which display it is), the same window, or for an app (window 0) any window of it. A session
    /// still opening an app (window 0) gets the app's main window, unknown till then; unless `appWindows` (the Mac's
    /// list of that app's windows) has just one: then it's that one.
    public func reaches(_ open: SessionTarget, appWindows: [Int] = []) -> Bool {
        guard mac == open.mac, desktop == open.desktop else { return false }
        if desktop { return window == 0 || open.window == 0 || window == open.window }
        if window == 0 { return bundle == open.bundle }
        if open.window == 0 { return bundle == open.bundle && appWindows == [window] }
        return window == open.window
    }
}

/// The sessions open on this device and the scenes (windows of the app) showing them: which is shown where, what
/// each scene showed before, and from that where each session is. The app keeps one book; this is its bookkeeping,
/// with the connections and views left to the app.
public struct SessionBook {
    /// Hidden this long, a session's connection is let go of (it reconnects when shown): an unused session shouldn't
    /// keep a Mac from locking (Keep Screen Dark locks it 2 minutes after its last connection ends).
    public static let parkedLimit: Double = 300

    public static func connection(_ p: SessionPlace, now: Double) -> SessionConnection {
        switch p {
        case .front, .inactive: .connect
        case .parked(let since): now - since < parkedLimit ? .keep : .drop   // a suspended one stays so until shown
        case .background: .drop
        }
    }

    public struct Session: Equatable {
        public let id: UUID
        public fileprivate(set) var target: SessionTarget
        public fileprivate(set) var touchedAt: Double   // last used: shown, or input sent
    }

    public enum Shown: Equatable { case here, elsewhere(scene: String) }

    public private(set) var sessions: [Session] = []
    public private(set) var shown: [String: UUID] = [:]     // scene → the session it shows
    private var recent: [String: [UUID]] = [:]              // scene → sessions it showed, most recent last
    private var phases: [String: SceneState] = [:]
    private var parkedSince: [UUID: Double] = [:]
    private var orphaned: [UUID: String] = [:]              // shown in a scene that was disconnected: its persistent ID
    public private(set) var appBackground = false

    public init() {}

    public func scene(showing id: UUID) -> String? { shown.first { $0.value == id }?.key }

    public func place(_ id: UUID) -> SessionPlace {
        if appBackground || orphaned[id] != nil { return .background }
        if let scene = scene(showing: id) {
            switch phases[scene] ?? .active {
            case .active: return .front
            case .inactive: return .inactive
            case .background: return .background
            }
        }
        return .parked(since: parkedSince[id] ?? 0)
    }

    /// The session open for `t` (the most recently used, if several are), other than `except`. `appWindows`: the
    /// windows the Mac lists for `t`'s app (see `reaches`).
    public func match(_ t: SessionTarget, except: UUID? = nil, appWindows: [Int] = []) -> UUID? {
        sessions.filter { $0.id != except && t.reaches($0.target, appWindows: appWindows) }.max { $0.touchedAt < $1.touchedAt }?.id
    }

    /// A session for `t`: the one open for it, or a new one with `id`, parked until it's shown.
    @discardableResult
    public mutating func add(_ t: SessionTarget, id: UUID, now: Double, appWindows: [Int] = []) -> (id: UUID, new: Bool) {
        if let m = match(t, appWindows: appWindows) { return (m, false) }
        sessions.append(Session(id: id, target: t, touchedAt: now))
        parkedSince[id] = now
        return (id, true)
    }

    /// Show `id` in `scene` (what it showed is parked), unless another scene shows it: that one is to come forward
    /// instead, as one session's picture can only be in one place. nil: no such session.
    @discardableResult
    public mutating func show(_ id: UUID, in scene: String, now: Double) -> Shown? {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        if let other = self.scene(showing: id), other != scene { return .elsewhere(scene: other) }
        if let was = shown[scene], was != id { parkedSince[was] = now }
        shown[scene] = id
        parkedSince[id] = nil
        orphaned[id] = nil
        recent[scene, default: []].removeAll { $0 == id }
        recent[scene, default: []].append(id)
        sessions[i].touchedAt = now
        return .here
    }

    /// `scene` goes Home: what it showed stays open, parked.
    public mutating func home(_ scene: String, now: Double) {
        guard let id = shown.removeValue(forKey: scene) else { return }
        parkedSince[id] = now
    }

    /// `id` closed. A scene that showed it shows what it showed before it, if that's still open and not shown in
    /// another scene; else nothing (its Home). Returns the scenes that showed it, and what they show now.
    @discardableResult
    public mutating func remove(_ id: UUID, now: Double) -> [String: UUID?] {
        sessions.removeAll { $0.id == id }
        parkedSince[id] = nil
        orphaned[id] = nil
        for k in recent.keys { recent[k]?.removeAll { $0 == id } }
        var changed: [String: UUID?] = [:]
        for (scene, s) in shown where s == id {
            shown[scene] = nil
            let next = recent[scene]?.last { self.scene(showing: $0) == nil }
            if let next { show(next, in: scene, now: now) }
            changed[scene] = next
        }
        return changed
    }

    /// Every session of `mac` closes (it's unpaired). Returns them.
    public mutating func removeAll(mac: String, now: Double) -> [UUID] {
        let ids = sessions.filter { $0.target.mac == mac }.map(\.id)
        ids.forEach { remove($0, now: now) }
        return ids
    }

    /// The host said which window (or display) `id` has. If another session already shows that, the other stays
    /// and `id` is the duplicate: that other session is returned, to show instead (and `id` closes).
    public mutating func resolve(_ id: UUID, to t: SessionTarget) -> UUID? {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return nil }
        sessions[i].target = t
        guard t.window != 0 else { return nil }
        return sessions.first { $0.id != id && $0.target.mac == t.mac && $0.target.desktop == t.desktop && $0.target.window == t.window }?.id
    }

    /// A scene that becomes active is the one being used (a tap into it, its window brought forward): what it shows
    /// counts as just used.
    public mutating func setState(_ s: SceneState, of scene: String, now: Double) {
        let was = phases[scene]
        phases[scene] = s
        if s == .active, was != .active, let id = shown[scene] { touch(id, now: now) }
    }
    public mutating func setAppBackground(_ b: Bool) { appBackground = b }

    public mutating func touch(_ id: UUID, now: Double) {
        if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].touchedAt = now }
    }

    /// `scene` was disconnected (closed by the user, or let go of by the system to save memory): what it showed
    /// goes to the background (its connection is let go of) until it's shown again, a restored scene included, or the
    /// scene is discarded (`discarded`).
    public mutating func sceneGone(_ scene: String, persistentID: String?, now: Double) {
        if let id = shown.removeValue(forKey: scene) {
            parkedSince[id] = now
            orphaned[id] = persistentID ?? ""
        }
        recent[scene] = nil
        phases[scene] = nil
    }

    /// Scenes closed for good: the sessions they showed when they went, to close (unless shown again since).
    public func discarded(_ persistentIDs: Set<String>) -> [UUID] {
        orphaned.filter { persistentIDs.contains($0.value) }.map(\.key)
    }

    /// Of the sessions on screen that pass `ok`, the one used last in an active scene; if every scene showing one
    /// is inactive for the moment (Control Center over them all), the one used last of those. Hidden and background
    /// ones never.
    private func latest(_ ok: (Session) -> Bool = { _ in true }) -> UUID? {
        let on = sessions.filter { ok($0) && place($0.id).shown }
        let front = on.filter { place($0.id) == .front }
        return (front.isEmpty ? on : front).max { $0.touchedAt < $1.touchedAt }?.id
    }

    /// The app's sound: the session on screen used last.
    public var audioOwner: UUID? { latest() }

    /// A new window on `mac` may be shown by the session on screen used last, of that Mac; by no other.
    public func newWindows(on mac: String) -> UUID? { latest { $0.target.mac == mac } }
}
