import AVFoundation
import SwiftUI

// Hither for iPhone and iPad: a viewer only. It pairs with a Mac running Hither, lists that Mac's windows and apps,
// and shows one window (resized to fit, and put back when you're done) or the Mac's whole Desktop at a time, full
// screen. It shares nothing of its own, apart from a clipboard or files you choose to send.

@main
struct HitherApp: App {
    @StateObject private var macs = Macs()
    @Environment(\.scenePhase) private var phase

    init() {
        // the Mac app's sound plays with the ring switch on silent too, alongside other audio
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            HomeView(macs: macs)
                .onChange(of: phase) { _, p in
                    if p == .background { macs.suspend() } else if p == .active { macs.resume() }
                }
        }
    }
}
