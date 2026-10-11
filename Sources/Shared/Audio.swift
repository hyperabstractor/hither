import AVFoundation
import Foundation

/// Plays the remote app's audio. Every window of the app receives it; only the owner (first open window) plays,
/// so two Cursor windows don't sound twice, and another takes over when the owner closes.
public final class AudioOut {
    public static let shared = AudioOut()
    let engine = AVAudioEngine(), node = AVAudioPlayerNode()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let lock = NSLock()
    var owner: ObjectIdentifier?
    var queued = 0   // frames scheduled, not yet played

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if ProcessInfo.processInfo.environment["HITHER_TEST_AUDIO"] != nil {   // test hook: buffer depth + device delay
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
                lock.lock(); let q = queued; lock.unlock()
                log("audio: buffered \(q * 1000 / 48_000) ms, output device \(Int(engine.outputNode.presentationLatency * 1000)) ms")
            }
        }
    }

    public func claim(_ id: ObjectIdentifier) { lock.lock(); if owner == nil { owner = id }; lock.unlock() }
    public func release(_ id: ObjectIdentifier, next: ObjectIdentifier?) { lock.lock(); if owner == id { owner = next }; lock.unlock() }

    /// Int16 interleaved stereo in. Start once ~30 ms is buffered (absorbs Wi-Fi jitter). Sound arrives and plays in
    /// real time, so any surplus (a burst at start, the two Macs' clocks drifting) would never drain: past ~70 ms
    /// buffered, drop the incoming ~20 ms chunk to stay in step with the video.
    public func play(_ pcm: Data, from id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        guard owner == id, queued < 3_360 else { return }
        let frames = pcm.count / 4
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self), l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<frames { l[i] = Float(s[2 * i]) / 32768; r[i] = Float(s[2 * i + 1]) / 32768 }
        }
        if !engine.isRunning { try? engine.start() }
        queued += frames
        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queued -= frames
            if self.queued == 0 { self.node.pause() }   // ran dry: re-buffer before resuming
            self.lock.unlock()
        }
        if !node.isPlaying && queued >= 1_440 { node.play() }
    }
}
