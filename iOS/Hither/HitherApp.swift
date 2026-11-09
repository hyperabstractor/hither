import AVFoundation
import SwiftUI

// Hither for iPhone and iPad: a viewer only. It pairs with a Mac running Hither, lists that Mac's windows and apps,
// and shows them (a window resized to fit, and put back when you're done, or the Mac's whole Desktop) full screen,
// several at once if you like: each is a session of its own, a tap apart, and on iPad each can have a window of its
// own. It shares nothing of its own, apart from a clipboard or files you choose to send.

/// What every window of the app shares: the Macs, and the sessions open with them.
enum Hither {
    static let macs = Macs()
    static let sessions = Sessions(macs: macs)
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Windows closed for good: what they showed closes too.
    func application(_ application: UIApplication, didDiscardSceneSessions scenes: Set<UISceneSession>) {
        Hither.sessions.discarded(Set(scenes.map(\.persistentIdentifier)))
    }
}

@main
struct HitherApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    init() {
        // the Mac app's sound plays with the ring switch on silent too, alongside other audio
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        // a window's value: the session it shows (Open in New Window opens one with it; one showing it already
        // comes forward instead). Restored after a relaunch it names nothing open, and the window shows Home.
        WindowGroup(for: UUID.self) { $session in
            SceneRoot(macs: Hither.macs, sessions: Hither.sessions, requested: $session)
                .onChange(of: phase) { _, p in   // the whole app's: every window in the background, or one back
                    if p == .background { Hither.macs.suspend() } else if p == .active { Hither.macs.resume() }
                }
        }
    }
}

/// One window of the app: Home, and over it the session it shows.
struct SceneRoot: View {
    @ObservedObject var macs: Macs
    let sessions: Sessions
    @Binding var requested: UUID?
    @StateObject private var scene = SceneModel()
    @Environment(\.scenePhase) private var phase   // this window's

    var body: some View {
        HomeView(macs: macs, sessions: sessions, scene: scene)
            .background(SceneProbe { sessions.attach(scene, to: $0) })
            .onAppear {
                sessions.register(scene)
                sessions.phase(scene, phase)
                show(requested)
            }
            .onChange(of: phase) { _, p in sessions.phase(scene, p) }
            .onChange(of: requested) { _, id in show(id) }
            // the window's value follows what it shows, so opening a session in a new window finds this one
            .onChange(of: scene.shown?.id) { _, id in if requested != id { requested = id } }
    }

    private func show(_ id: UUID?) {
        guard let id else { return }
        guard let w = sessions.window(id) else { requested = nil; return }   // closed, or from before a relaunch
        guard scene.shown !== w else { return }
        sessions.show(w, in: scene)
        if scene.shown?.id != requested { requested = scene.shown?.id }   // shown in another window instead
    }
}
