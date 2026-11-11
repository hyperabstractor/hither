import AVFoundation
import Shared
import UIKit

/// The remote window's picture, and touch, pointer and typing back to it:
///   tap = click (tap again quickly for a double or triple click), two-finger tap = right click,
///   drag = scroll (flick and it glides on, as on a Mac trackpad; touch to stop it),
///   touch and hold then drag = press and drag (select text, move a divider).
///   A Desktop also zooms and moves here: pinch, or drag with two fingers. That changes nothing on the Mac.
/// A mouse or trackpad on an iPad points, clicks (secondary click = right click), drags and scrolls like one on a Mac.
/// Typing goes to the Mac as text, through an invisible text view iOS can write into and revise (dictation from the
/// keyboard's mic key; see TypingBuffer); the keys on the keyboard (KeyBar) send esc, tab, arrows and modifiers as Mac keys.
/// A hardware keyboard sends Mac keys, modifiers and shortcuts included (those the iPad keeps for itself excepted).
/// While the on-screen keyboard is up, the picture moves up just enough to keep the spot you last touched in view.
final class StreamView: UIView, UIGestureRecognizerDelegate {
    let video = AVSampleBufferDisplayLayer()
    var depacketizer = Depacketizer()
    var remoteSize = CGSize.zero { didSet { if remoteSize != oldValue { setNeedsLayout() } } }
    /// App windows: Mac points per viewer point for the window size we ask for: 1 = actual size, more = more fits.
    var scale = 1.0 { didSet { if scale != oldValue { onWantSize(wantSize) } } }
    var send: (Msg) -> Void = { _ in }
    var onWantSize: (CGSize) -> Void = { _ in }
    var onLatency: (Int) -> Void = { _ in }
    var onZoom: () -> Void = {}
    /// The on-screen keyboard went away: whoever takes hardware keys when it isn't up should have them again.
    var onResign: () -> Void = {}
    /// A session is open with the Mac. Without one nothing new is pressed (it would never reach the Mac, and its key
    /// up or repeats would go to the next session), and going without one forgets what was held: that session is gone.
    var live = false { didSet { if !live { forgetInput() } } }

    /// A Desktop: pinch and two fingers zoom and move the picture here (one finger still scrolls).
    var zoomable = false {
        didSet {
            pinch.isEnabled = zoomable
            twoFingers.isEnabled = zoomable
            drag.maximumNumberOfTouches = zoomable ? 1 : 2
            if !zoomable { zoom = nil }
            setNeedsLayout()
        }
    }
    /// nil = fit; else Mac points × zoom, moved by `offset` where it's bigger than this view.
    private(set) var zoom: CGFloat?
    private var offset = CGPoint.zero
    /// An Adaptive Desktop is never scaled up (1): pixel for pixel, centered. Otherwise fit fills the view.
    var maxFit: CGFloat = .greatestFiniteMagnitude { didSet { if maxFit != oldValue { setNeedsLayout() } } }
    private(set) var picture = CGRect.zero     // where the video is, before any lift for the keyboard

    let keys = KeyBar()
    private var keysGap: NSLayoutConstraint!
    /// The key panel moved (with the keyboard, or shown or hidden): what avoids it should look again.
    var onKeysMoved: () -> Void = {}
    private let typing = TypingBuffer()        // first responder while the on-screen keyboard is up
    private var keyboardFrame: CGRect?         // in the screen's coordinate space
    private var focus: CGPoint?                // last touch, in window points
    private var lift: CGFloat = 0              // how far the picture is moved up for the keyboard
    private var lastTap: (at: CFTimeInterval, point: CGPoint, count: Int)?
    private var scrollAt = CGPoint.zero        // a scroll goes where it started, like a trackpad's under the pointer
    private var scrolling: UIPanGestureRecognizer?   // the scroll that began in this session: only its moves and end go
    private var keySeq: UInt32 = 0
    private var sentAt: [UInt32: CFTimeInterval] = [:]
    private var samples: [Double] = []

    private let tap = UITapGestureRecognizer(), rightTap = UITapGestureRecognizer()
    private let drag = UIPanGestureRecognizer(), hold = UILongPressGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer(), twoFingers = UIPanGestureRecognizer()
    private let wheel = UIPanGestureRecognizer(), hover = UIHoverGestureRecognizer()
    private var anchor: (spot: CGPoint, zoom: CGFloat)?   // a pinch or two-finger move: what stays under the fingers

    // what's held down on the Mac because of us, so it's always let go again (app switch, disconnect, another window)
    private var heldKeys: Set<Int> = []
    private var heldModifiers: Set<Int> = []
    private var capsLock = false
    private var repeatTimer: Timer?
    private var pointer: (button: Int, at: CGPoint)?      // a mouse or trackpad button held
    private var holding: CGPoint?                         // touch and hold, then drag

    // a flick's glide: momentum scrolls, one per frame, to where the drag scrolled (`scrollAt`)
    private var glide: Glide?
    private var glideLink: CADisplayLink?
    private var touchStoppedGlide = false                 // so the tap that stopped it doesn't click too

    init() {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isMultipleTouchEnabled = true
        video.videoGravity = .resize   // the layer is laid out at the window's own aspect
        video.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(video)

        // fingers and Pencil; a mouse or trackpad comes as touches of its own (touchesBegan…) and as scrolls
        let touch = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
        tap.addTarget(self, action: #selector(tapped(_:)))
        rightTap.addTarget(self, action: #selector(rightTapped(_:)))
        rightTap.numberOfTouchesRequired = 2
        drag.addTarget(self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 2
        hold.addTarget(self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        pinch.addTarget(self, action: #selector(transformed(_:)))
        twoFingers.addTarget(self, action: #selector(transformed(_:)))
        twoFingers.minimumNumberOfTouches = 2
        twoFingers.maximumNumberOfTouches = 2
        for g in [tap, rightTap, drag, hold, twoFingers] { g.allowedTouchTypes = touch }
        pinch.delegate = self
        twoFingers.delegate = self
        pinch.isEnabled = false
        twoFingers.isEnabled = false
        wheel.addTarget(self, action: #selector(dragged(_:)))
        wheel.allowedScrollTypesMask = .all   // trackpad and mouse wheel scrolls, no touches
        wheel.allowedTouchTypes = []
        hover.addTarget(self, action: #selector(hovered(_:)))
        [tap, rightTap, drag, hold, pinch, twoFingers, wheel, hover].forEach(addGestureRecognizer)

        // the keys ride on the keyboard, floating or docked (KeyBar), by the guide that follows either
        keyboardLayoutGuide.followsUndockedKeyboard = true
        keys.isHidden = true
        keys.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keys)
        keysGap = keys.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        let belowTop = keys.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor)   // keyboard at the top:
        keysGap.priority = .defaultHigh                                                               // over its edge
        NSLayoutConstraint.activate([keysGap, belowTop, keys.centerXAnchor.constraint(equalTo: keyboardLayoutGuide.centerXAnchor),
                                     keys.widthAnchor.constraint(equalTo: keyboardLayoutGuide.widthAnchor)])
        typing.onEdit = { [weak self] in self?.type($0) }
        typing.onInsert = { [weak self] in self?.typedKey($0) ?? false }
        typing.onDelete = { [weak self] in self?.typedDelete(empty: $0) ?? false }
        typing.onPresses = { [weak self] in self?.hardware($0, down: $1) ?? false }
        typing.onResign = { [weak self] in DispatchQueue.main.async { self?.showKeys(); self?.onResign() } }
        addSubview(typing)
        keys.onKey = { [weak self] in
            self?.press($0)
            self?.resetTyping()   // esc, tab and arrows: the cursor may be anywhere now
        }
        keys.onHide = { [weak self] in self?.stopTyping() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // its window's scene going inactive (switching apps, Control Center, a call): nothing may stay pressed on the
        // Mac. Only its own: another window of this app can be in front meanwhile.
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { glideLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {   // closing, or gone from the screen: nothing may keep scrolling
            lettingGo = true
            stopGlide()
            endScroll()
            lettingGo = false
        } else {
            setNeedsLayout()   // shown (again): its size, from where it is now, goes to the Mac (layoutSubviews)
        }
    }

    /// Pinch and two-finger drags go together; and a one-finger scroll that started a moment before the second finger
    /// landed doesn't keep them from starting (it's cancelled once they do).
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let zooming = [pinch, twoFingers]
        return zooming.contains(g) && (zooming.contains(other) || other === drag)
    }

    // MARK: picture

    /// The window size to ask the Mac for: this view's size × scale, in Mac points.
    var wantSize: CGSize { CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded()) }

    override func layoutSubviews() {
        // a floating keyboard: two rows a little above it; docked (or a hardware keyboard): one row on top of it
        let k = keyboardLayoutGuide.layoutFrame
        keys.compact = k.width < bounds.width - 1
        keysGap.constant = keys.compact ? -8 : 0
        let was = keys.frame
        super.layoutSubviews()
        if keys.frame != was, !keys.isHidden { onKeysMoved() }
        place()
        if bounds.width > 0 { onWantSize(wantSize) }
    }

    /// Where the picture is now, lifted for the keyboard included: input maps through this.
    private var shown: CGRect { picture.offsetBy(dx: 0, dy: -lift) }

    /// Fit (or zoomed), then lifted if the keyboard would cover the spot last touched. `keepLift`: zooming around a
    /// spot, which `anchored` keeps where it is for the lift there is now; working it out again would move it.
    private func place(animated: Bool = false, duration: Double = 0.25, keepLift: Bool = false) {
        let r = pictureRect(view: bounds.size, remote: remoteSize, zoom: zoom, pan: offset, maxFit: maxFit)
        offset = r.pan
        // fit on whole points, so a 1:1 picture lands on whole pixels too
        picture = remoteSize == .zero ? bounds
            : zoom == nil ? CGRect(origin: CGPoint(x: r.rect.minX.rounded(.down), y: r.rect.minY.rounded(.down)), size: r.rect.size) : r.rect
        if keepLift { return draw(animated: animated, duration: duration) }
        lift = 0
        if let keyboard = keyboardCover, let p = focus, remoteSize.width > 0 {
            let s = picture.width / remoteSize.width
            let x = picture.minX + p.x * s, y = picture.minY + p.y * s
            // A floating keyboard only hides the part of the picture it actually covers.
            if !keyboard.isEmpty, x >= keyboard.minX, x <= keyboard.maxX, y <= keyboard.maxY {
                lift = min(max(0, y + 44 - keyboard.minY), max(0, picture.maxY - keyboard.minY))
            }
        }
        draw(animated: animated, duration: duration)
    }

    /// What the keyboard and the keys on it cover of this view, while typing.
    var keyboardCover: CGRect? {
        guard isTyping else { return nil }
        var r = CGRect.null
        if let keyboardFrame, let screen = window?.screen { r = bounds.intersection(convert(keyboardFrame, from: screen.coordinateSpace)) }
        let k = keyboardLayoutGuide.layoutFrame
        if k.height > safeAreaInsets.bottom + 1 { r = r.union(k) }
        if !keys.isHidden { r = r.union(keys.frame) }
        return r.isNull || r.isEmpty ? nil : r
    }

    private func draw(animated: Bool, duration: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(duration)
        video.frame = shown
        CATransaction.commit()
        // the invisible text the keyboard types into sits where the typing likely goes (the spot last touched), so
        // anything iOS shows beside it (dictation's) is there too
        if let p = focus, remoteSize.width > 0 {
            let s = shown.width / remoteSize.width
            typing.frame.origin = CGPoint(x: min(max(shown.minX + p.x * s, 0), max(0, bounds.width - 1)),
                                          y: min(max(shown.minY + p.y * s, 0), max(0, bounds.height - 1)))
        }
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

    /// The decoder gave up (iOS can take it away from a picture that's off screen): only a new stream fixes it.
    var pictureFailed: Bool { video.sampleBufferRenderer.status == .failed }

    /// Low on memory while hidden: let the decoder and the picture go. Zoom stays; the next stream starts afresh.
    func dropPicture() {
        video.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        depacketizer = Depacketizer()
        sentAt = [:]
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

    // MARK: zoom (Desktop)

    static let zoomSteps: [CGFloat] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4]
    /// The picture's scale now, fit included: Mac points → points here.
    var scaleNow: CGFloat { remoteSize.width > 0 ? picture.width / remoteSize.width : 1 }
    private var fitScale: CGFloat {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return 1 }
        return min(bounds.width / remoteSize.width, bounds.height / remoteSize.height, maxFit)
    }

    /// nil = fit. Keeps what's under `around` (default: the middle) where it is.
    func setZoom(_ z: CGFloat?, around a: CGPoint? = nil) {
        guard remoteSize.width > 0 else { return }
        let a = a ?? CGPoint(x: bounds.midX, y: bounds.midY)
        if let z = z.map({ min(max($0, 0.1), 4) }) { anchored(z, spot: remote(a), at: a) } else { zoom = nil; place() }
        onZoom()
    }

    func zoomStep(_ dir: Int) {
        let now = scaleNow
        if let next = dir > 0 ? Self.zoomSteps.first(where: { $0 > now + 0.005 }) : Self.zoomSteps.last(where: { $0 < now - 0.005 }) {
            setZoom(next <= fitScale + 0.005 && dir < 0 ? nil : next)
        } else if dir < 0 {
            setZoom(nil)
        }
    }

    /// Zoom to `z` with the Mac's point `spot` at `a`, as input sees it: through the picture as drawn, lifted for the
    /// keyboard. The lift stays as it is meanwhile; it's worked out again when the keyboard or the layout changes.
    private func anchored(_ z: CGFloat, spot: CGPoint, at a: CGPoint) {
        zoom = z
        offset = Shared.pan(keeping: spot, at: a, zoom: z, lift: lift)
        place(keepLift: true)
    }

    /// Pinch and two-finger drags, together: the spot first under the fingers stays under them. Whenever a finger
    /// gesture starts or ends, that spot is taken again, so the other one carries on from where things are.
    @objc private func transformed(_ g: UIGestureRecognizer) {
        guard remoteSize.width > 0 else { return }
        let active = { (r: UIGestureRecognizer) in r.state == .began || r.state == .changed }
        let source: UIGestureRecognizer = active(twoFingers) ? twoFingers : pinch
        let a = source.location(in: self)
        if g.state != .changed {
            stopGlide()
            if active(drag) { drag.isEnabled = false; drag.isEnabled = true }   // it ends, cancelled: no stray scroll
            if active(pinch) || active(twoFingers) {
                anchor = (remote(a), scaleNow)
                pinch.scale = 1
            } else {   // all fingers up: back to fit if it's about there
                anchor = nil
                if let z = zoom, z <= fitScale * 1.02 { zoom = nil; place() }
                onZoom()
            }
            return
        }
        guard let start = anchor else { return }
        anchored(min(max(start.zoom * (active(pinch) ? pinch.scale : 1), fitScale), 4), spot: start.spot, at: a)
    }

    /// Zoomed in past the view, a pointer leads: where it is across the view is where it is across the Mac's screen.
    private func follow(_ p: CGPoint) {
        guard zoomable, zoom != nil, picture.width > bounds.width || picture.height > bounds.height else { return }
        let f = { (v: CGFloat, size: CGFloat) in min(max(v / size, 0), 1) }
        offset = CGPoint(x: f(p.x, bounds.width) * (picture.width - bounds.width), y: f(p.y, bounds.height) * (picture.height - bounds.height))
        place()
    }

    // MARK: touch → mouse

    /// A point in this view → the same spot on the Mac.
    private func remote(_ p: CGPoint) -> CGPoint { remoteSize == .zero ? p : remotePoint(p, in: shown, remote: remoteSize) }

    private func mouse(_ kind: Int, _ p: CGPoint, button: Int = 0, count: Int = 1, flags: UInt64 = 0) {
        let r = remote(p)
        var m = Msg("mouse")
        m.x = r.x; m.y = r.y; m.k = kind; m.b = button; m.f = flags
        if kind == 1 || kind == 2 { m.c = count }
        send(m)
    }

    private func click(_ p: CGPoint, button: Int, count: Int) {
        focus = remote(p)
        resetTyping()
        let f = keys.take()
        mouse(0, p)   // the pointer moves there first, as it would with a mouse (hover states, tooltips)
        mouse(1, p, button: button, count: count, flags: f)
        mouse(2, p, button: button, count: count, flags: f)
        closeSwitcher()   // a tap on an app in the switcher picks it; anywhere else, the one it's on
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        if touchStoppedGlide { touchStoppedGlide = false; return }   // that touch only stopped a glide
        let p = g.location(in: self), now = CACurrentMediaTime()
        var count = 1
        if let l = lastTap, now - l.at < 0.4, hypot(p.x - l.point.x, p.y - l.point.y) < 16 { count = l.count % 3 + 1 }
        lastTap = (now, p, count)
        click(p, button: 0, count: count)
    }

    @objc private func rightTapped(_ g: UITapGestureRecognizer) {
        if touchStoppedGlide { touchStoppedGlide = false; return }
        click(g.location(in: self), button: 1, count: 1)
    }

    /// A finger (or, from `wheel`, a trackpad or mouse wheel) scrolls what's under it. A finger's flick glides on
    /// afterwards (`glide`); a trackpad or mouse makes its own momentum, so nothing is added to theirs.
    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        guard remoteSize.width > 0, shown.width > 0 else { return }
        if g === drag, g.state == .began || g.state == .changed, anchor != nil { return }   // zooming
        if g.state == .began {
            stopGlide()
            endScroll()   // another one still going (a trackpad's and a finger's at once): it ends first
            guard live else { return }   // nothing new without a session; its moves and end are ignored too
            scrolling = g
            scrollAt = remote(g.location(in: self))
        }
        let t = g.translation(in: self), s = shown.width / remoteSize.width
        g.setTranslation(.zero, in: self)
        // from before a disconnect, a switch or letting go of input: not for this session, and no glide from it
        guard scrolling === g else { return }
        var m = Msg("scroll")
        m.x = scrollAt.x; m.y = scrollAt.y; m.dx = t.x / s; m.dy = t.y / s; m.f = g === wheel ? modifierFlags(g.modifierFlags) : 0; m.b = 0
        switch g.state {   // CGScrollPhase
        case .began: m.p = 1
        case .ended: m.p = 4
        case .cancelled, .failed: m.p = 8
        default: m.p = 2
        }
        m.mp = 0
        send(m)
        guard g.state != .began, g.state != .changed else { return }
        scrolling = nil
        if g === drag, g.state == .ended, anchor == nil, live { flick(g.velocity(in: self), scale: s) }
    }

    /// The scroll under way ends here, cancelled (`sending`, while there's a session to tell); whatever that
    /// gesture does later is ignored.
    private func endScroll(sending: Bool = true) {
        guard scrolling != nil else { return }
        scrolling = nil
        guard sending, live else { return }
        var m = Msg("scroll")
        m.x = scrollAt.x; m.y = scrollAt.y; m.dx = 0; m.dy = 0; m.f = 0; m.b = 0
        m.p = 8   // CGScrollPhase cancelled
        m.mp = 0
        send(m)
    }

    /// Something else is being touched (the floating controls): a glide stops at once.
    func stopMomentum() { stopGlide() }

    // MARK: glide after a flick

    /// The finger left moving fast enough: glide on from that speed, slowing down, in the Mac's points as the drag was.
    /// Speeds are in points here per second, the finger's own.
    private func flick(_ v: CGPoint, scale s: CGFloat) {
        stopGlide()
        guard let g = Glide(velocity: CGPoint(x: v.x / s, y: v.y / s), at: CACurrentMediaTime(),
                            minimum: 250 / s, stop: 20 / s, maximum: 8000 / s) else { return }
        glide = g
        sendGlide(g.start)
        let link = CADisplayLink(target: GlideTicker(self), selector: #selector(GlideTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    fileprivate func glideTick(_ link: CADisplayLink) {
        guard live, var g = glide else { return stopGlide(sending: false) }
        let step = g.step(to: link.targetTimestamp)
        glide = g
        if let step { sendGlide(step) }
        if g.ended { stopGlide(sending: false) }
    }

    /// Stop gliding: tell the Mac the momentum ended (`sending`), unless the session's gone or it already has.
    private func stopGlide(sending: Bool = true) {
        glideLink?.invalidate()
        glideLink = nil
        if var g = glide, let end = g.stop(), sending, live { sendGlide(end) }
        glide = nil
    }

    private func sendGlide(_ step: Glide.Step) {
        var m = Msg("scroll")
        m.x = scrollAt.x; m.y = scrollAt.y; m.dx = step.delta.x; m.dy = step.delta.y; m.f = 0; m.b = 0
        m.p = 0   // the gesture is over: momentum only
        m.mp = step.phase.rawValue
        send(m)
    }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            guard live else { return }
            stopGlide()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            focus = remote(p)
            resetTyping()
            holding = p
            mouse(0, p)
            mouse(1, p, flags: keys.take())
        case .changed:
            guard holding != nil else { return }   // let go of already (releaseInput)
            holding = p
            mouse(3, p)
        case .ended, .cancelled:
            guard holding != nil else { return }
            holding = nil
            mouse(2, p)
        default: break
        }
    }

    // MARK: mouse and trackpad

    /// UIKeyModifierFlags use the same bits as CGEventFlags; only the ones a click or scroll carries.
    private func modifierFlags(_ f: UIKeyModifierFlags) -> UInt64 {
        UInt64(f.intersection([.shift, .control, .alternate, .command, .alphaShift]).rawValue)
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed, pointer == nil else { return }
        let p = g.location(in: self)
        follow(p)
        mouse(0, p)
    }

    private func pointerTouch(_ touches: Set<UITouch>) -> UITouch? { touches.first { $0.type == .indirectPointer } }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if event?.allTouches?.count == touches.count { touchStoppedGlide = glide != nil }   // the first finger(s) down
        stopGlide()
        guard let t = pointerTouch(touches), pointer == nil else { return super.touchesBegan(touches, with: event) }
        guard live else { return }
        let p = t.location(in: self), b = event?.buttonMask.contains(.secondary) == true ? 1 : 0
        pointer = (b, p)
        focus = remote(p)
        resetTyping()
        mouse(0, p)
        mouse(1, p, button: b, count: max(1, t.tapCount), flags: modifierFlags(event?.modifierFlags ?? []) | keys.take())
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = pointerTouch(touches), let held = pointer else { return super.touchesMoved(touches, with: event) }
        let p = t.location(in: self)
        pointer = (held.button, p)
        follow(p)
        mouse(3, p, button: held.button, flags: modifierFlags(event?.modifierFlags ?? []))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = pointerTouch(touches), let held = pointer else { return super.touchesEnded(touches, with: event) }
        pointer = nil
        mouse(2, t.location(in: self), button: held.button, count: max(1, t.tapCount), flags: modifierFlags(event?.modifierFlags ?? []))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerTouch(touches) != nil, let held = pointer else { return super.touchesCancelled(touches, with: event) }
        pointer = nil
        mouse(2, held.at, button: held.button)
    }

    // MARK: on-screen keyboard

    /// The on-screen keyboard is up for this view (typing into `typing`).
    var isTyping: Bool { typing.isFirstResponder }

    /// Bring up the on-screen keyboard, starting with nothing typed.
    @discardableResult func startTyping() -> Bool {
        typing.reset()
        defer { showKeys() }
        return typing.becomeFirstResponder()
    }

    /// The keys while typing, else not.
    private func showKeys() {
        guard keys.isHidden == isTyping else { return }
        keys.isHidden = !isTyping
        if isTyping { bringSubviewToFront(keys) }
        setNeedsLayout()
        onKeysMoved()
    }

    /// Put the on-screen keyboard away; `onResign` follows.
    @discardableResult func stopTyping() -> Bool { typing.resignFirstResponder() }

    /// Where the Mac's text cursor is no longer follows what was typed here (a click, a key that moves it, a menu
    /// item): what's been typed can't be revised or deleted from here any more, only what's typed next.
    func resetTyping() { typing.reset() }

    // no edit menu shortcuts here (⌘C, ⌘V…): they go to the Mac as keys
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    /// What the typed text changed by (a character typed, or dictation revising what it wrote), on the Mac: Deletes,
    /// then the text, with Return and Tab in it as those keys. Latched modifiers don't carry into text.
    private func type(_ edit: TypingEdit) {
        _ = keys.take()
        for _ in 0..<edit.deletes { key(Keys.delete) }
        var run = ""
        for c in edit.insert {
            guard c.isNewline || c == "\t" else { run.append(c); continue }
            if !run.isEmpty { text(run); run = "" }
            key(c == "\t" ? Keys.tab : Keys.returnKey)
        }
        if !run.isEmpty { text(run) }
    }

    /// Typed, but a Mac key instead of text: Return, Tab, or with ⌘, ⌃ or ⌥ latched the shortcut for that key. True
    /// when it was; the cursor may be anywhere after, so what was typed before is forgotten.
    private func typedKey(_ text: String) -> Bool {
        if text == "\n" {
            press(Keys.returnKey)
        } else if text == "\t" {
            press(Keys.tab)
        } else if keys.latched & (Keys.command | Keys.control | Keys.option) != 0, text.count == 1, let k = Keys.code(for: text.first!) {
            press(k.code, k.shift ? Keys.shift : 0)
        } else {
            return false
        }
        resetTyping()
        return true
    }

    /// Delete as a Mac key: with nothing typed to take back (it goes on deleting what's there on the Mac), or with
    /// modifiers latched (⌥ deletes a word). Otherwise the typed text loses a character and that goes as a Delete.
    private func typedDelete(empty: Bool) -> Bool {
        guard empty || keys.latched != 0 else { return false }
        press(Keys.delete)
        if !empty { resetTyping() }
        return true
    }

    private func text(_ text: String) {
        keySeq += 1
        sentAt[keySeq] = CACurrentMediaTime()
        var m = Msg("text"); m.text = text; m.seq = keySeq
        send(m)
    }

    /// A Mac key with the latched modifiers, down and up.
    func press(_ code: Int, _ flags: UInt64 = 0) { key(code, flags: keys.take() | flags) }

    /// A Mac key, down and up, with just these modifiers.
    private func key(_ code: Int, flags: UInt64 = 0) {
        let f = flags | Keymap.implicitFlags(code)
        keySeq += 1
        sentAt[keySeq] = CACurrentMediaTime()
        var d = Msg("key"); d.k = code; d.down = true; d.f = f; d.seq = keySeq
        var u = Msg("key"); u.k = code; u.down = false; u.f = f
        send(d)
        send(u)
    }

    @objc private func keyboardChanged(_ n: Notification) {
        keyboardFrame = isTyping ? n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect : nil
        place(animated: true, duration: n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25)
    }

    // MARK: hardware keyboard

    /// The modifiers held on the hardware keyboard (and caps lock), as the host posts them.
    private var hardwareFlags: UInt64 {
        heldModifiers.reduce(capsLock ? Keymap.capsLock : 0) { $0 | (Keymap.modifierFlag($1) ?? 0) }
    }

    /// Keys from a hardware keyboard, as Mac keys. Returns whether they went to the Mac (keys a Mac keyboard doesn't
    /// have stay with the iPad). Presses that come together (⌘ and S in one event) arrive as a set, in no order: the
    /// modifiers go first going down and last coming up, and each key also carries the modifiers iOS says are held,
    /// so ⌘S is ⌘S whatever the order, and even if ⌘ was held before this screen had the keyboard. They come from
    /// `typing` while the on-screen keyboard is up, else from the screen showing this view. A key that isn't a
    /// modifier means the cursor may have moved: what the on-screen keyboard typed before is forgotten.
    func hardware(_ presses: Set<UIPress>, down: Bool) -> Bool {
        let pressed = presses.compactMap { p in p.key.flatMap { k in Keymap.macKey(hid: k.keyCode.rawValue).map { (k, $0) } } }
        let rank = { (code: Int) in (Keymap.modifierFlag(code) != nil) == down ? 0 : 1 }
        let modifiersFirst = pressed.sorted { rank($0.1) < rank($1.1) }
        for (key, code) in modifiersFirst {
            capsLock = key.modifierFlags.contains(.alphaShift)
            if let flag = Keymap.modifierFlag(code) {
                if flag != Keymap.capsLock {
                    if !down { heldModifiers.remove(code) } else if live { heldModifiers.insert(code) } else { continue }
                }
                var m = Msg("flags"); m.k = code; m.f = hardwareFlags
                send(m)
            } else if down {
                resetTyping()
                keyDown(code, repeating: heldKeys.contains(code), held: modifierFlags(key.modifierFlags))
            } else {
                keyUp(code)
            }
        }
        return !pressed.isEmpty
    }

    // MARK: app switcher

    private var switcher = Keymap.AppSwitcher()
    private var switcherTimer: Timer?
    var onSwitcher: (Bool) -> Void = { _ in }   // the Mac's app switcher went up or away

    /// The Mac's app switcher, as ⌘ held and Tab at the Mac: the first call shows it, on the app used before, and
    /// each one after moves to the next app. ⌘ is let go of, switching to the app it's on, 2 s after the last call
    /// or at once with a tap (on an app in it: that one). False without a session.
    func switchApps() -> Bool {
        guard live else { return false }
        stopGlide()
        resetTyping()
        let opening = !switcher.isOpen
        switcher.next(held: heldModifiers.sorted(), capsLock: capsLock).forEach(send)
        switcherTimer?.invalidate()
        switcherTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.closeSwitcher() }
        if opening { onSwitcher(true) }
        return true
    }

    /// Let go of ⌘: the Mac switches to the app picked. `sending` false: the session's gone, just forget it.
    func closeSwitcher(sending: Bool = true) {
        switcherTimer?.invalidate(); switcherTimer = nil
        guard switcher.isOpen else { return }
        let up = switcher.close()
        if sending { up.forEach(send) }
        onSwitcher(false)
    }

    /// A shortcut exactly as given (Keymap.shortcut), sent on its own: what's latched on the bar above the keyboard
    /// stays for the next key, and modifiers held on a hardware keyboard don't join in. False without a session.
    func shortcut(_ key: Int, modifiers: [Int]) -> Bool {
        guard live else { return false }
        stopGlide()
        resetTyping()
        Keymap.shortcut(key, modifiers: modifiers, held: heldModifiers.sorted(), capsLock: capsLock).forEach(send)
        return true
    }

    private func keyDown(_ code: Int, repeating: Bool, held: UInt64) {
        guard live else { return }
        var d = Msg("key"); d.k = code; d.down = true; d.f = hardwareFlags | held | keys.take() | Keymap.implicitFlags(code)
        if repeating {
            d.rep = true   // iOS repeats it itself: no repeats of our own
            repeatTimer?.invalidate(); repeatTimer = nil
        } else {
            keySeq += 1
            sentAt[keySeq] = CACurrentMediaTime()
            d.seq = keySeq
            heldKeys.insert(code)
            startRepeat(code, held: held)
        }
        send(d)
    }

    private func keyUp(_ code: Int) {
        guard heldKeys.remove(code) != nil else { return }
        if heldKeys.isEmpty { repeatTimer?.invalidate(); repeatTimer = nil }
        var u = Msg("key"); u.k = code; u.down = false; u.f = hardwareFlags | Keymap.implicitFlags(code)
        send(u)
    }

    /// A key held down repeats, as on a Mac (posted keys don't repeat by themselves there): the newest key held only.
    private func startRepeat(_ code: Int, held: UInt64) {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
                guard let self, heldKeys.contains(code) else { return t.invalidate() }
                var d = Msg("key"); d.k = code; d.down = true; d.rep = true; d.f = hardwareFlags | held | Keymap.implicitFlags(code)
                send(d)
            }
        }
    }

    /// Sending what letting go takes (key and button ups, a scroll's end): not input of the user's own.
    private(set) var lettingGo = false

    /// Let go of everything this view holds down on the Mac: keys, modifiers, a mouse button, a touch-and-hold drag.
    func releaseInput() {
        lettingGo = true
        defer { lettingGo = false }
        resetTyping()
        stopGlide()
        endScroll()
        closeSwitcher()
        repeatTimer?.invalidate(); repeatTimer = nil
        for code in heldKeys {
            var u = Msg("key"); u.k = code; u.down = false; u.f = 0
            send(u)
        }
        heldKeys = []
        for code in heldModifiers {
            var m = Msg("flags"); m.k = code; m.f = 0
            send(m)
        }
        heldModifiers = []
        if let held = pointer { pointer = nil; mouse(2, held.at, button: held.button) }
        if let p = holding { holding = nil; mouse(2, p) }
    }

    /// The session ended without a chance to let go (the connection dropped): forget what was held, sending nothing.
    private func forgetInput() {
        closeSwitcher(sending: false)
        resetTyping()
        stopGlide(sending: false)
        endScroll(sending: false)
        repeatTimer?.invalidate(); repeatTimer = nil
        heldKeys = []
        heldModifiers = []
        pointer = nil
        holding = nil
    }

    @objc private func resignedActive(_ n: Notification) {
        guard let scene = window?.windowScene, n.object as? UIScene === scene else { return }
        releaseInput()
    }
}

/// Drives a glide once a frame without the display link (which keeps its target) keeping the view.
private final class GlideTicker: NSObject {
    private weak var view: StreamView?
    init(_ view: StreamView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.glideTick(link)
    }
}
