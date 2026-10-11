import AVFoundation
import SwiftUI

// Hither for iPhone: a viewer only. It pairs with a Mac running Hither, lists that Mac's windows and apps, and shows
// one window at a time, full screen, resized to fit the phone (and put back when you're done). It shares nothing.

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
