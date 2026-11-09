import AVFoundation
import Foundation

/// Who plays, and how much of their sound is queued: AudioOut's bookkeeping, apart from the audio engine (and so
/// testable). A handover starts an epoch: what the last owner queued no longer counts, its buffers' completions
/// (when the player drops them) change nothing, and nothing is taken until the new owner is in.
public struct AudioQueue {
    public static let most = 3_360    // ~70 ms: past this, drop incoming sound to stay in step with the video
    public static let start = 1_440   // ~30 ms buffered before playing

    public private(set) var owner: ObjectIdentifier?
    public private(set) var queued = 0   // frames scheduled, not yet played
    public private(set) var epoch = 0
    private var handing = false

    public init() {}

    /// `frames` from `id` to schedule: the epoch to report their completion with, or nil to drop them (not the
    /// owner, a handover under way, or enough queued).
    public mutating func accept(_ frames: Int, from id: ObjectIdentifier) -> Int? {
        guard owner == id, !handing, queued < Self.most, frames > 0 else { return nil }
        queued += frames
        return epoch
    }

    /// Scheduled frames played, or were dropped. True if that leaves nothing queued (pause, and buffer up again).
    /// From an epoch before a handover: nothing changes.
    public mutating func played(_ frames: Int, epoch e: Int) -> Bool {
        guard e == epoch else { return false }
        queued -= frames
        return queued == 0
    }

    public var ready: Bool { queued >= Self.start }

    /// Start handing over to `id`: nothing more is taken, and what's queued is the last epoch's. False if `id` is the
    /// owner already, and nothing's to be done; else the player drops what it has, then `finishHandover`.
    public mutating func beginHandover(to id: ObjectIdentifier?) -> Bool {
        guard owner != id || handing else { return false }
        owner = nil
        handing = true
        epoch += 1
        queued = 0
        return true
    }

    public mutating func finishHandover(to id: ObjectIdentifier?) {
        owner = id
        handing = false
    }

    /// The Mac viewer's way: the first window to open plays, and the next takes over when it closes.
    public mutating func claim(_ id: ObjectIdentifier) { if owner == nil && !handing { owner = id } }
    public mutating func release(_ id: ObjectIdentifier, next: ObjectIdentifier?) { if owner == id { owner = next } }
}

/// Plays the remote app's audio. Every window of the app receives it; only the owner plays, so two Cursor windows
/// don't sound twice. On a Mac the first open window owns it and another takes over when it closes (claim, release);
/// on an iPhone or iPad the session on screen used last does (hand).
public final class AudioOut {
    public static let shared = AudioOut()
    let engine = AVAudioEngine(), node = AVAudioPlayerNode()
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    let lock = NSLock()
    var q = AudioQueue()

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if ProcessInfo.processInfo.environment["HITHER_TEST_AUDIO"] != nil {   // test hook: buffer depth + device delay
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
                lock.lock(); let queued = q.queued; lock.unlock()
                log("audio: buffered \(queued * 1000 / 48_000) ms, output device \(Int(engine.outputNode.presentationLatency * 1000)) ms")
            }
        }
    }

    public func claim(_ id: ObjectIdentifier) { lock.lock(); q.claim(id); lock.unlock() }
    public func owns(_ id: ObjectIdentifier) -> Bool { lock.lock(); defer { lock.unlock() }; return q.owner == id }
    public func release(_ id: ObjectIdentifier, next: ObjectIdentifier?) { lock.lock(); q.release(id, next: next); lock.unlock() }

    /// `id` plays from now on (nil: nobody). A new owner starts clean: what the last one had queued is dropped, so none
    /// of its sound plays after the switch. Call on one thread (the main one). The player is stopped without the lock
    /// held: it may call its buffers' completions right there, and they take the lock.
    public func hand(to id: ObjectIdentifier?) {
        lock.lock()
        let changed = q.beginHandover(to: id)
        lock.unlock()
        guard changed else { return }
        if engine.isRunning { node.stop() }   // drops what's scheduled; their completions are of the last epoch
        lock.lock()
        q.finishHandover(to: id)
        lock.unlock()
    }

    /// Int16 interleaved stereo in. Start once ~30 ms is buffered (absorbs Wi-Fi jitter). Sound arrives and plays in
    /// real time, so any surplus (a burst at start, the two Macs' clocks drifting) would never drain: past ~70 ms
    /// buffered, drop the incoming ~20 ms chunk to stay in step with the video.
    public func play(_ pcm: Data, from id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        let frames = pcm.count / 4
        guard let epoch = q.accept(frames, from: id) else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            _ = q.played(frames, epoch: epoch)
            return
        }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self), l = buf.floatChannelData![0], r = buf.floatChannelData![1]
            for i in 0..<frames { l[i] = Float(s[2 * i]) / 32768; r[i] = Float(s[2 * i + 1]) / 32768 }
        }
        if !engine.isRunning { try? engine.start() }
        node.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.q.played(frames, epoch: epoch) { self.node.pause() }   // ran dry: re-buffer before resuming
            self.lock.unlock()
        }
        if !node.isPlaying && q.ready { node.play() }
    }
}
