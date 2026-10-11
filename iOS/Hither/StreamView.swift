import AVFoundation
import Shared
import UIKit

/// The remote window's picture, and touch and typing back to it:
///   tap = click (tap again quickly for a double or triple click), two-finger tap = right click,
///   drag = scroll, touch and hold then drag = press and drag (select text, move a divider).
/// Typing goes to the Mac as text; the bar above the keyboard sends esc, tab, arrows and modifiers as Mac keys.
/// While the keyboard is up, the picture moves up just enough to keep the spot you last touched in view.
final class StreamView: UIView, UIKeyInput {
    let video = AVSampleBufferDisplayLayer()
    var depacketizer = Depacketizer()
    var remoteSize = CGSize.zero { didSet { if remoteSize != oldValue { setNeedsLayout() } } }
    /// Mac points per phone point for the window size we ask for: 1 = actual size, more = more fits, smaller text.
    var scale = 1.0 { didSet { if scale != oldValue { onWantSize(wantSize) } } }
    var send: (Msg) -> Void = { _ in }
    var onWantSize: (CGSize) -> Void = { _ in }
    var onLatency: (Int) -> Void = { _ in }

    let keys = KeyBar()
    private var keyboard: CGFloat = 0          // how much of this view the keyboard covers
    private var focus: CGPoint?                // last touch, in window points
    private var lift: CGFloat = 0              // how far the picture is moved up for the keyboard
    private var lastTap: (at: CFTimeInterval, point: CGPoint, count: Int)?
    private var scrollAt = CGPoint.zero        // a scroll goes where it started, like a trackpad's under the pointer
    private var keySeq: UInt32 = 0
    private var sentAt: [UInt32: CFTimeInterval] = [:]
    private var samples: [Double] = []

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isMultipleTouchEnabled = true
        video.videoGravity = .resize   // the layer is laid out at the window's own aspect
        video.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(video)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(rightTapped(_:)))
        rightTap.numberOfTouchesRequired = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        [tap, rightTap, pan, hold].forEach(addGestureRecognizer)

        keys.onKey = { [weak self] in self?.press($0) }
        keys.onHide = { [weak self] in _ = self?.resignFirstResponder() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: picture

    /// The window size to ask the Mac for: this view's size × scale, in Mac points.
    var wantSize: CGSize { CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded()) }

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
        if bounds.width > 0 { onWantSize(wantSize) }
    }

    /// Aspect-fit, then lifted if the keyboard would cover the spot last touched.
    private func place(animated: Bool = false, duration: Double = 0.25) {
        let r = remoteSize, b = bounds
        var f = b
        if r.width > 0, r.height > 0 {
            let s = min(b.width / r.width, b.height / r.height)
            f = CGRect(x: (b.width - r.width * s) / 2, y: (b.height - r.height * s) / 2, width: r.width * s, height: r.height * s)
        }
        lift = 0
        if keyboard > 0, let p = focus, r.width > 0 {
            let y = f.minY + p.y * f.width / r.width, visible = b.height - keyboard
            lift = min(max(0, y + 44 - visible), max(0, f.maxY - visible))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        video.frame = f.offsetBy(dx: 0, dy: -lift)
        CATransaction.commit()
    }

    func show(_ packet: Data) {
        guard let (seq, sb) = depacketizer.sampleBuffer(packet) else { return }
        let renderer = video.sampleBufferRenderer
        if renderer.status == .failed {
            log("decoder failed: \(renderer.error?.localizedDescription ?? "?") — asking for keyframe")
            renderer.flush()
            send(Msg("keyframe"))
        }
        renderer.enqueue(sb)
        meter(seq)
    }

    /// key→frame: time from sending a key to the first frame the host captured after typing it.
    private func meter(_ seq: UInt32) {
        let now = CACurrentMediaTime()
        let hit = sentAt.keys.filter { $0 <= seq }
        if let last = hit.max(), let t = sentAt[last] {
            samples.append((now - t) * 1000)
            if samples.count > 30 { samples.removeFirst() }
            onLatency(Int(samples.sorted()[samples.count / 2]))
        }
        hit.forEach { sentAt[$0] = nil }
        sentAt = sentAt.filter { now - $0.value < 1 }   // keys that changed nothing on screen
    }

    // MARK: touch → mouse

    /// A point in this view → the same spot in the Mac window.
    private func remote(_ p: CGPoint) -> CGPoint {
        remotePoint(CGPoint(x: p.x, y: p.y + lift), view: bounds.size, remote: remoteSize)
    }

    private func mouse(_ kind: Int, _ p: CGPoint, button: Int = 0, count: Int = 1, flags: UInt64 = 0) {
        let r = remote(p)
        var m = Msg("mouse")
        m.x = r.x; m.y = r.y; m.k = kind; m.b = button; m.f = flags
        if kind == 1 || kind == 2 { m.c = count }
        send(m)
    }

    private func click(_ p: CGPoint, button: Int, count: Int) {
        focus = remote(p)
        let f = keys.take()
        mouse(0, p)   // the pointer moves there first, as it would with a mouse (hover states, tooltips)
        mouse(1, p, button: button, count: count, flags: f)
        mouse(2, p, button: button, count: count, flags: f)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self), now = CACurrentMediaTime()
        var count = 1
        if let l = lastTap, now - l.at < 0.4, hypot(p.x - l.point.x, p.y - l.point.y) < 16 { count = l.count % 3 + 1 }
        lastTap = (now, p, count)
        click(p, button: 0, count: count)
    }

    @objc private func rightTapped(_ g: UITapGestureRecognizer) { click(g.location(in: self), button: 1, count: 1) }

    /// Scrolls follow the finger. No momentum after a flick: that would have to be made up here.
    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard remoteSize.width > 0, video.frame.width > 0 else { return }
        if g.state == .began { scrollAt = remote(g.location(in: self)) }
        let t = g.translation(in: self), s = video.frame.width / remoteSize.width
        g.setTranslation(.zero, in: self)
        var m = Msg("scroll")
        m.x = scrollAt.x; m.y = scrollAt.y; m.dx = t.x / s; m.dy = t.y / s; m.f = 0; m.b = 0
        switch g.state {   // CGScrollPhase
        case .began: m.p = 1
        case .ended: m.p = 4
        case .cancelled, .failed: m.p = 8
        default: m.p = 2
        }
        m.mp = 0
        send(m)
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            focus = remote(p)
            mouse(0, p)
            mouse(1, p, flags: keys.take())
        case .changed: mouse(3, p)
        case .ended, .cancelled: mouse(2, p)
        default: break
        }
    }

    // MARK: keyboard

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { keys }
    var hasText: Bool { true }   // so Delete always comes through

    // no help from iOS: the Mac app does its own completion and correction
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var inlinePredictionType = UITextInlinePredictionType.no

    func insertText(_ text: String) {
        if text == "\n" { return press(Keys.returnKey) }
        if text == "\t" { return press(Keys.tab) }
        // with ⌘, ⌃ or ⌥ latched it's a shortcut: send the key itself
        if keys.latched & (Keys.command | Keys.control | Keys.option) != 0, text.count == 1, let k = Keys.code(for: text.first!) {
            return press(k.code, k.shift ? Keys.shift : 0)
        }
        _ = keys.take()
        keySeq += 1
        sentAt[keySeq] = CACurrentMediaTime()
        var m = Msg("text"); m.text = text; m.seq = keySeq
        send(m)
    }

    func deleteBackward() { press(Keys.delete) }

    /// A Mac key with the latched modifiers, down and up.
    func press(_ code: Int, _ flags: UInt64 = 0) {
        let arrow = (Keys.left...Keys.up).contains(code)
        let f = keys.take() | flags | (arrow ? Keys.arrowFlags : 0)
        keySeq += 1
        sentAt[keySeq] = CACurrentMediaTime()
        var d = Msg("key"); d.k = code; d.down = true; d.f = f; d.seq = keySeq
        var u = Msg("key"); u.k = code; u.down = false; u.f = f
        send(d)
        send(u)
    }

    @objc private func keyboardChanged(_ n: Notification) {
        guard let end = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, let screen = window?.screen else { return }
        let k = convert(end, from: screen.coordinateSpace)
        keyboard = max(0, bounds.maxY - k.minY)
        place(animated: true, duration: n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25)
    }
}
