import Foundation
import Shared

private let mini = "mini", air = "air"
private func desktop(_ mac: String, _ display: Int = 0) -> SessionTarget { SessionTarget(mac: mac, bundle: desktopApp, window: display) }
private func window(_ mac: String, _ bundle: String, _ id: Int) -> SessionTarget { SessionTarget(mac: mac, bundle: bundle, window: id) }

/// Opening what's open shows that session: a Desktop (the main one is any until the display is known), a window, an
/// app's main window (any of its windows); and once the host says which window or display a session got, a second
/// session on it is the duplicate.
func testSessionTargets() throws {
    // the main Desktop until known; a known display only itself
    try expectTrue(desktop(mini).reaches(desktop(mini, 5)))
    try expectTrue(desktop(mini, 5).reaches(desktop(mini)))
    try expectTrue(desktop(mini, 5).reaches(desktop(mini, 5)))
    try expectFalse(desktop(mini, 5).reaches(desktop(mini, 6)))
    try expectFalse(desktop(mini).reaches(desktop(air)))
    try expectFalse(desktop(mini).reaches(window(mini, "com.apple.TextEdit", 0)))
    try expectFalse(window(mini, "com.apple.TextEdit", 0).reaches(desktop(mini)))
    // windows: the same one; an app: any of its windows; a window isn't reached by another of its app's
    try expectTrue(window(mini, "com.apple.TextEdit", 41).reaches(window(mini, "com.apple.TextEdit", 41)))
    try expectFalse(window(mini, "com.apple.TextEdit", 42).reaches(window(mini, "com.apple.TextEdit", 41)))
    try expectTrue(window(mini, "com.apple.TextEdit", 0).reaches(window(mini, "com.apple.TextEdit", 41)))
    try expectTrue(window(mini, "com.apple.TextEdit", 0).reaches(window(mini, "com.apple.TextEdit", 0)))
    try expectFalse(window(mini, "com.apple.TextEdit", 41).reaches(window(mini, "com.apple.TextEdit", 0)))   // that app's main window may be another
    try expectFalse(window(mini, "com.apple.Safari", 0).reaches(window(mini, "com.apple.TextEdit", 41)))
    // a session still opening TextEdit gets its main window: window 41, if that's the only one the Mac lists for it
    try expectTrue(window(mini, "com.apple.TextEdit", 41).reaches(window(mini, "com.apple.TextEdit", 0), appWindows: [41]))
    try expectFalse(window(mini, "com.apple.TextEdit", 41).reaches(window(mini, "com.apple.TextEdit", 0), appWindows: [41, 42]))
    try expectFalse(window(mini, "com.apple.TextEdit", 41).reaches(window(mini, "com.apple.Safari", 0), appWindows: [41]))
    try expectFalse(window(air, "com.apple.TextEdit", 41).reaches(window(mini, "com.apple.TextEdit", 41)))

    var book = SessionBook()
    let a = UUID(), b = UUID(), c = UUID()
    try expectEqual(book.add(desktop(mini), id: a, now: 0).new, true)
    try expectEqual(book.add(desktop(mini), id: b, now: 1).id, a)                  // the same Desktop: that session
    try expectEqual(book.add(window(mini, "com.apple.TextEdit", 0), id: b, now: 2).new, true)
    try expectEqual(book.add(window(mini, "com.apple.TextEdit", 41), id: c, now: 3, appWindows: [41]).id, b)   // its only one: joins
    try expectEqual(book.add(window(mini, "com.apple.TextEdit", 41), id: c, now: 3, appWindows: [41, 42]).new, true)   // may be another
    // the app's session turns out to have window 41: it's the duplicate, the one already open stays
    try expectEqual(book.resolve(b, to: window(mini, "com.apple.TextEdit", 41)), c)
    // a Desktop on another display is its own; on the same one, a duplicate
    let d = UUID()
    try expectEqual(book.resolve(a, to: desktop(mini, 1)), nil)
    try expectEqual(book.add(desktop(mini, 2), id: d, now: 4).new, true)
    try expectEqual(book.resolve(d, to: desktop(mini, 2)), nil)
    try expectEqual(book.resolve(d, to: desktop(mini, 1)), a)
    // not known yet: no duplicate
    try expectEqual(book.resolve(d, to: desktop(mini, 0)), nil)
}

/// Each window of the app shows one session at a time, and a session is in one window at a time. Home leaves it open;
/// closing it shows what that window showed before (if it's still open and not shown elsewhere), else Home.
/// Unpairing a Mac closes its sessions, hidden ones too.
func testSessionSelection() throws {
    var book = SessionBook()
    let one = "scene-1", two = "scene-2"
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    book.add(desktop(mini), id: a, now: 0)
    book.add(desktop(air), id: b, now: 0)
    book.add(window(mini, "com.apple.TextEdit", 41), id: c, now: 0)
    book.add(window(air, "com.apple.Safari", 7), id: d, now: 0)
    try expectEqual(book.show(a, in: one, now: 1), .here)
    try expectEqual(book.show(b, in: one, now: 2), .here)     // a: hidden, still open
    try expectEqual(book.shown[one], b)
    try expectEqual(book.place(a), .parked(since: 2))
    try expectEqual(book.show(c, in: two, now: 3), .here)
    // a session shown in the other window: that window comes forward, nothing moves
    try expectEqual(book.show(c, in: one, now: 4), .elsewhere(scene: two))
    try expectEqual(book.shown[one], b)
    try expectNil(book.show(UUID(), in: one, now: 4))
    // Home: still open
    book.home(two, now: 5)
    try expectNil(book.shown[two])
    try expectEqual(book.sessions.count, 4)
    try expectEqual(book.place(c), .parked(since: 5))

    // closing what scene one shows (b): it shows a again, the one before
    try expectEqual(book.remove(b, now: 6), [one: a])
    try expectEqual(book.shown[one], a)
    // what it showed before is in the other window now: not taken from there; nothing else it showed: Home
    try expectEqual(book.show(c, in: one, now: 7), .here)
    try expectEqual(book.show(a, in: two, now: 8), .here)
    try expectEqual(book.remove(c, now: 9), [one: Optional<UUID>.none])
    try expectNil(book.shown[one])
    try expectEqual(book.shown[two], a)

    // unpair mini: its sessions close wherever they are; air's stay
    try expectEqual(Set(book.removeAll(mac: mini, now: 10)), [a])
    try expectNil(book.shown[two])
    try expectEqual(book.sessions.map(\.id), [d])
    try expectNil(book.match(desktop(mini)))
    try expectEqual(book.match(window(air, "com.apple.Safari", 7)), d)
}

/// Where a session is decides its connection: on screen (active or a moment inactive) it connects; hidden it stays
/// connected 5 minutes, then hangs up and stays so until shown; in the background (the app, its window, or its window
/// disconnected) it hangs up at once. Discarding a disconnected window closes what it showed; restoring it doesn't.
func testSessionLifecycle() throws {
    var book = SessionBook()
    let s = "scene", a = UUID(), b = UUID()
    book.add(desktop(mini), id: a, now: 0)
    book.add(desktop(air), id: b, now: 0)
    book.show(a, in: s, now: 100)
    try expectEqual(book.place(a), .front)
    try expectEqual(SessionBook.connection(.front, now: 100), .connect)
    book.setState(.inactive, of: s, now: 0)
    try expectEqual(book.place(a), .inactive)
    try expectEqual(SessionBook.connection(book.place(a), now: 100), .connect)   // still on screen: stays connected
    try expectTrue(book.place(a).shown)
    book.setState(.background, of: s, now: 0)
    try expectEqual(book.place(a), .background)
    try expectEqual(SessionBook.connection(book.place(a), now: 100), .drop)
    book.setState(.active, of: s, now: 0)

    // hidden: kept, then let go of at 5 minutes, and not connected again until shown
    book.show(b, in: s, now: 200)
    try expectEqual(book.place(a), .parked(since: 200))
    try expectEqual(SessionBook.connection(book.place(a), now: 200 + 299), .keep)
    try expectEqual(SessionBook.connection(book.place(a), now: 200 + 300), .drop)
    try expectEqual(SessionBook.connection(book.place(a), now: 200 + 10_000), .drop)
    book.show(a, in: s, now: 900)
    try expectEqual(SessionBook.connection(book.place(a), now: 900), .connect)

    // the app in the background: everything hangs up, shown or not; back, only what's shown connects
    book.setAppBackground(true)
    try expectEqual([book.place(a), book.place(b)], [.background, .background])
    book.setAppBackground(false)
    try expectEqual(book.place(a), .front)
    try expectEqual(SessionBook.connection(book.place(b), now: 901), .keep)   // hidden: as it was (hung up), until shown

    // its window disconnected: background until shown again (restored) or discarded
    book.sceneGone(s, persistentID: "P1", now: 1000)
    try expectNil(book.shown[s])
    try expectEqual(book.place(a), .background)
    try expectEqual(book.discarded(["P2"]), [])
    let restored = "scene-restored"
    book.show(a, in: restored, now: 1001)
    try expectEqual(book.place(a), .front)
    try expectEqual(book.discarded(["P1"]), [])               // shown again: not the closed window's any more
    book.sceneGone(restored, persistentID: "P3", now: 1002)
    try expectEqual(book.discarded(["P3"]), [a])
}

/// Sound and new windows go to the session on screen used last: not to hidden ones, not to every one of that Mac,
/// and to none while nothing's on screen.
func testSessionRouting() throws {
    var book = SessionBook()
    let left = "left", right = "right", a = UUID(), b = UUID(), c = UUID()
    book.add(window(mini, "com.apple.TextEdit", 41), id: a, now: 0)
    book.add(window(mini, "com.apple.Safari", 7), id: b, now: 0)
    book.add(desktop(air), id: c, now: 0)
    try expectNil(book.audioOwner)                            // nothing on screen
    book.show(a, in: left, now: 1)
    book.show(b, in: right, now: 2)                           // side by side: both on screen
    try expectEqual(book.audioOwner, b)                       // shown last
    book.touch(a, now: 3)                                     // a tap in the left one
    try expectEqual(book.audioOwner, a)
    try expectEqual(book.newWindows(on: mini), a)
    try expectNil(book.newWindows(on: air))                   // air's Desktop isn't on screen
    book.show(c, in: left, now: 4)                            // a hidden: sound and new windows go elsewhere
    try expectEqual(book.audioOwner, c)
    try expectEqual(book.newWindows(on: mini), b)
    book.touch(a, now: 5)                                     // input to a hidden one (a key let go of) changes nothing
    try expectEqual(book.audioOwner, c)
    book.setState(.background, of: left, now: 0)
    try expectEqual(book.audioOwner, b)                       // its window in the background: the other one's
    book.setState(.inactive, of: right, now: 0)
    try expectEqual(book.audioOwner, b)                       // a moment inactive: still on screen, still plays
    book.setAppBackground(true)
    try expectNil(book.audioOwner)
    try expectNil(book.newWindows(on: mini))
}

/// Two windows side by side: the one in active use has the sound and new windows, not one used later that's now
/// inactive. A window coming back to active counts as used; with every window inactive for a moment, the one used
/// last keeps them; hidden and background ones never have them.
func testSessionFocus() throws {
    var book = SessionBook()
    let left = "left", right = "right", a = UUID(), b = UUID(), c = UUID()
    book.add(window(mini, "com.apple.TextEdit", 41), id: a, now: 0)
    book.add(window(mini, "com.apple.Safari", 7), id: b, now: 0)
    book.add(desktop(mini), id: c, now: 0)
    book.show(b, in: right, now: 1)
    book.show(a, in: left, now: 2)
    book.touch(a, now: 3)                                    // a used last
    // right is brought forward, left goes inactive (before any input to b): b
    book.setState(.inactive, of: left, now: 4)
    book.setState(.active, of: right, now: 4)               // already active: no change of its own
    try expectEqual(book.audioOwner, b)
    try expectEqual(book.newWindows(on: mini), b)
    // left active again: it's being used, so a, though b's window is active too
    book.setState(.active, of: left, now: 5)
    try expectEqual(book.audioOwner, a)
    try expectEqual(book.newWindows(on: mini), a)
    // both inactive (Control Center): the one used last keeps them
    book.setState(.inactive, of: left, now: 6)
    book.setState(.inactive, of: right, now: 6)
    try expectEqual(book.audioOwner, a)
    // right back first: its b counts as used now
    book.setState(.active, of: right, now: 7)
    try expectEqual(book.audioOwner, b)
    // showing a session from a menu counts as using it: c replaces b on the right, and has the sound
    book.show(c, in: right, now: 8)
    try expectEqual(book.audioOwner, c)
    try expectEqual(book.newWindows(on: mini), c)
    // input to a hidden session (b, parked) or one in the background never takes them
    book.touch(b, now: 9)
    book.setState(.background, of: right, now: 10)
    book.touch(c, now: 11)
    try expectEqual(book.audioOwner, a)                     // left is inactive, but the only one on screen
    book.setState(.background, of: left, now: 12)
    try expectNil(book.audioOwner)
}

/// Handing the sound to another session: nothing is taken mid-handover, what the last owner queued no longer counts
/// (its buffers' completions, when the player drops them, change nothing), and the new owner starts from empty. Handing
/// to nobody when the last session closes drops its sound too. The Mac viewer's claim and release work as before.
func testAudioHandover() throws {
    final class Window {}
    let a = ObjectIdentifier(Window.self), b = ObjectIdentifier(NSObject.self)
    var q = AudioQueue()
    q.claim(a)
    try expectEqual(q.owner, a)
    let e0 = try expectSome(q.accept(960, from: a))
    try expectNil(q.accept(960, from: b))                   // not the owner
    _ = q.accept(960, from: a)
    try expectEqual(q.queued, 1920)
    try expectTrue(q.ready)

    try expectTrue(q.beginHandover(to: b))
    try expectNil(q.accept(960, from: b))                   // mid-handover: nobody's sound is taken
    try expectNil(q.accept(960, from: a))
    q.finishHandover(to: b)
    try expectEqual(q.owner, b)
    try expectEqual(q.queued, 0)
    let e1 = try expectSome(q.accept(960, from: b))
    try expectFalse(q.played(960, epoch: e0))               // a's dropped buffers completing: b's count untouched
    try expectFalse(q.played(960, epoch: e0))
    try expectEqual(q.queued, 960)
    try expectTrue(q.played(960, epoch: e1))                // b's own: ran dry, pause and buffer up again
    try expectEqual(q.queued, 0)

    try expectFalse(q.beginHandover(to: b))                 // already b's: nothing to drop
    try expectTrue(q.beginHandover(to: nil))                // the last session closed: its sound goes too
    q.finishHandover(to: nil)
    try expectNil(q.owner)
    try expectNil(q.accept(960, from: b))

    // a Mac's windows: the first claims, a later claim doesn't take it, release hands it on
    var m = AudioQueue()
    m.claim(a); m.claim(b)
    try expectEqual(m.owner, a)
    m.release(b, next: nil)
    try expectEqual(m.owner, a)
    m.release(a, next: b)
    try expectEqual(m.owner, b)
    // so many frames queued: the rest is dropped to stay in step with the video
    _ = m.accept(AudioQueue.most, from: b)
    try expectNil(m.accept(960, from: b))
}

private func expectSome<T>(_ v: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let v else { throw RegressionFailure(message: "\(file):\(line): unexpected nil") }
    return v
}
