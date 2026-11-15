import AVFoundation
import Foundation

/// Who plays, and how much of their sound is queued: AudioOut's bookkeeping, apart from the audio engine (and so
/// testable). A handover starts an epoch: what the last owner queued no longer counts, its buffers' completions
/// (when the player drops them) change nothing, and nothing is taken until the new owner is in.
///
/// How much is buffered stretches with the network: it starts at ~30 ms, and sound that ran dry mid-flow and came back
/// moments later (a Wi-Fi spike, not a pause in the sound) adds that gap, up to ~200 ms, so the next spike like it
/// plays through. After 15 s without one it comes back down 20 ms at a time, staying in step with the video when the
/// network is good.
public struct AudioQueue {
    public static let start = 1_440      // ~30 ms: the least buffered before playing
    public static let deepest = 9_600    // ~200 ms: the most, however shaky the network
    public static let headroom = 1_920   // ~40 ms over the target: past this, drop incoming sound to stay in step
    static let hiccup = 0.3              // ran dry and back within this: the network, not a pause in the sound
    static let flowing = 0.2             // …after playing at least this long (not a click)
    static let steady = 15.0             // this long without one: 20 ms less

    public private(set) var owner: ObjectIdentifier?
    public private(set) var queued = 0   // frames scheduled, not yet played
    public private(set) var epoch = 0
    public private(set) var target = start   // frames buffered before playing
    public var limit: Int { target + Self.headroom }
    private var handing = false
    private var dryAt: Double?, flowingSince: Double?, steadySince = 0.0

    public init() {}

    /// `frames` from `id` arriving at `now` (seconds) to schedule: the epoch to report their completion with, or nil
    /// to drop them (not the owner, a handover under way, or enough queued).
    public mutating func accept(_ frames: Int, from id: ObjectIdentifier, now: Double) -> Int? {
        guard owner == id, !handing, frames > 0 else { return nil }
        if let dry = dryAt {   // sound again after running dry
            dryAt = nil
            let gap = now - dry
            if gap < Self.hiccup, let f = flowingSince, dry - f >= Self.flowing {
                target = min(Self.deepest, target + Int(gap * 48_000) + 960)
                steadySince = now
            }
            flowingSince = nil
        }
        if target > Self.start && now - steadySince >= Self.steady {
            target = max(Self.start, target - 960)
            steadySince = now
        }
        guard queued < limit else { return nil }
        queued += frames
        if flowingSince == nil && queued >= target { flowingSince = now }   // it plays from here
        return epoch
    }

    /// Scheduled frames played, or were dropped, at `now`. True if that leaves nothing queued (pause, and buffer up
    /// again). From an epoch before a handover: nothing changes.
    public mutating func played(_ frames: Int, epoch e: Int, now: Double) -> Bool {
        guard e == epoch else { return false }
        queued -= frames
        guard queued == 0 else { return false }
        dryAt = now
        return true
    }

    public var ready: Bool { queued >= target }

    /// Start handing over to `id`: nothing more is taken, and what's queued is the last epoch's. False if `id` is the
    /// owner already, and nothing's to be done; else the player drops what it has, then `finishHandover`.
    public mutating func beginHandover(to id: ObjectIdentifier?) -> Bool {
        guard owner != id || handing else { return false }
        owner = nil
        handing = true
        epoch += 1
        queued = 0
        target = Self.start   // another Mac, maybe another network
        dryAt = nil; flowingSince = nil
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

    /// Int16 interleaved stereo in. Start once the target is buffered (~30 ms, more on a shaky network: AudioQueue).
    /// Sound arrives and plays in real time, so any surplus (a burst at start, the two Macs' clocks drifting) would
    /// never drain: ~40 ms past the target, drop the incoming ~20 ms chunk to stay in step with the video.
    public func play(_ pcm: Data, from id: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        let frames = pcm.count / 4, now = ProcessInfo.processInfo.systemUptime, was = q.target
        let accepted = q.accept(frames, from: id, now: now)
        if q.target != was { log("audio: buffering \(q.target * 1000 / 48_000) ms (\(q.target > was ? "the network hiccuped" : "steady"))") }
        guard let epoch = accepted else { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            _ = q.played(frames, epoch: epoch, now: now)
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
            if self.q.played(frames, epoch: epoch, now: ProcessInfo.processInfo.systemUptime) { self.node.pause() }   // ran dry: re-buffer before resuming
            self.lock.unlock()
        }
        if !node.isPlaying && q.ready { node.play() }
    }
}
