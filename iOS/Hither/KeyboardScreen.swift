import Combine
import Shared
import SwiftUI
import UIKit

/// This device as the keyboard of another showing Hither (KeyLink): its own keyboard along the bottom, with all it
/// brings (other languages, dictation, swipe typing), and the rest of the screen for the keys it lacks, big: esc, tab,
/// ⌘⇥, Delete, Return, the modifiers, the arrows, and Cut, Copy, Paste, Undo. Or, in their place, a trackpad (PadView)
/// for the Mac's pointer, which the other device draws; with the keyboard put away it has the whole screen.
struct KeyboardScreen: View {
    @ObservedObject var keys: KeyLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        KeyboardPad(keys: keys, close: { dismiss() })
            .ignoresSafeArea()
            .sheet(item: $keys.prompt) { CodeSheet(prompt: $0) }
            .alert("Couldn't Pair", isPresented: Binding(get: { keys.problem != nil }, set: { if !$0 { keys.problem = nil } })) {
                Button("OK") {}
            } message: {
                Text(keys.problem ?? "")
            }
            .onAppear { keys.serve(true) }
            .onDisappear { keys.serve(false) }
    }
}

private struct KeyboardPad: UIViewControllerRepresentable {
    let keys: KeyLink
    let close: () -> Void

    func makeUIViewController(context: Context) -> KeyboardController { KeyboardController(keys: keys, close: close) }
    func updateUIViewController(_ c: KeyboardController, context: Context) {}
}

/// What's typed goes to the other device as it would go to a Mac from the keys over a session there (StreamView):
/// text as text, by what changed (so dictation can revise it); Return, Tab, Delete with nothing typed to take back,
/// and anything typed with ⌘, ⌃ or ⌥ latched, as Mac keys. The other device says when the Mac's cursor has moved
/// ("kbreset"), from when what was typed here can't be revised any more.
///
/// A modifier latches with a tap, for the next key here or the next click on the other device, and can be held
/// instead, for as many of those as come while it's down.
final class KeyboardController: UIViewController {
    private let keys: KeyLink
    private let close: () -> Void
    private let typing = TypingBuffer()
    private let status = UILabel(), detail = UILabel()
    private let aboveKeyboard = UIView()   // laid out down to the keyboard's top, so the keys are laid out again when it moves
    private var closeButton: UIButton!, keyboardButton: UIButton!, nextButton: UIButton!, correctButton: UIButton!
    private let mode = UISegmentedControl(items: ["Keys", "Trackpad"])
    private let pad = PadView()
    private var keyboardAway = false   // put away with its button: it stays away until that brings it back
    private var rows: [[UIButton]] = []
    private var switchKey: UIButton!   // ⌘⇥: the Mac's app switcher, where the other device shows a Desktop
    private var modifierButtons: [(flag: UInt64, button: UIButton)] = []
    private var watching: Set<AnyCancellable> = []
    private var repeating: Timer?

    // modifiers: on (lit), finger down on its key, used by a key or click while down, down to turn it off again
    private var latched: UInt64 = 0 {
        didSet {
            guard latched != oldValue else { return }
            for (flag, b) in modifierButtons { b.isSelected = latched & flag != 0 }
            var m = Msg("kblatch"); m.f = latched
            keys.send(m)
        }
    }
    private var held: UInt64 = 0, usedHeld: UInt64 = 0, turningOff: UInt64 = 0

    init(keys: KeyLink, close: @escaping () -> Void) {
        self.keys = keys
        self.close = close
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.font = .preferredFont(forTextStyle: .headline)
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.textColor = .secondaryLabel
        for l in [status, detail] {
            l.textAlignment = .center
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.7
            view.addSubview(l)
        }
        detail.numberOfLines = 2
        closeButton = UIButton(configuration: .gray(), primaryAction: UIAction { [weak self] _ in self?.close() })
        closeButton.configuration?.image = UIImage(systemName: "xmark")
        closeButton.configuration?.cornerStyle = .capsule
        closeButton.accessibilityLabel = "Close keyboard"
        view.addSubview(closeButton)
        keyboardButton = UIButton(configuration: .gray(), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            keyboardAway = typing.isFirstResponder
            _ = keyboardAway ? typing.resignFirstResponder() : typing.becomeFirstResponder()
            view.setNeedsLayout()
        })
        keyboardButton.configuration?.cornerStyle = .capsule
        view.addSubview(keyboardButton)
        // the next session open on the other device, round all of them: shown while it has more than one
        nextButton = UIButton(configuration: .gray(), primaryAction: UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.keys.send(Msg("kbnext"))
            self?.typing.reset()
        })
        nextButton.configuration?.image = UIImage(systemName: "rectangle.2.swap")
        nextButton.configuration?.cornerStyle = .capsule
        nextButton.accessibilityLabel = "Next session"
        view.addSubview(nextButton)
        // autocorrection: on unless turned off here (off for commands and code, which it would "correct")
        typing.corrects = UserDefaults.standard.object(forKey: "keyboard.corrects") as? Bool ?? true
        correctButton = UIButton(configuration: .gray(), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            typing.corrects.toggle()
            UserDefaults.standard.set(typing.corrects, forKey: "keyboard.corrects")
            showCorrects()
        })
        correctButton.configuration?.image = UIImage(systemName: "textformat.abc.dottedunderline",
                                                     withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        correctButton.configuration?.contentInsets = .zero
        correctButton.configuration?.cornerStyle = .capsule
        correctButton.changesSelectionAsPrimaryAction = false
        correctButton.configurationUpdateHandler = { b in   // on: filled in
            var c = b.configuration
            c?.background.backgroundColor = b.isSelected ? .tintColor : .tertiarySystemFill
            c?.baseForegroundColor = b.isSelected ? .white : .label
            b.configuration = c
        }
        view.addSubview(correctButton)
        showCorrects()
        mode.selectedSegmentIndex = UserDefaults.standard.bool(forKey: "keyboard.pad") ? 1 : 0
        mode.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(mode.selectedSegmentIndex == 1, forKey: "keyboard.pad")
            view.setNeedsLayout()
        }, for: .valueChanged)
        view.addSubview(mode)
        pad.send = { [weak self] in self?.keys.send($0) }
        view.addSubview(pad)

        let key = { [unowned self] (title: String?, symbol: String?, label: String, code: Int, flags: UInt64, repeats: Bool) in
            plain(title: title, symbol: symbol, label: label, repeats: repeats) { [weak self] in self?.press(code, flags) }
        }
        // the Mac's app switcher, as the ⌘⇥ button on the other device: again for the next app; it switches a moment
        // after the last press, or at once on a click
        switchKey = plain(title: "⌘⇥", symbol: nil, label: "Switch app (Command-Tab)", repeats: false) { [weak self] in
            self?.keys.send(Msg("kbswitch"))
            self?.typing.reset()
        }
        rows = [
            [key("esc", nil, "Escape", Keys.escape, 0, false), key("tab", nil, "Tab", Keys.tab, 0, false), switchKey,
             key(nil, "delete.left", "Delete", Keys.delete, 0, true), key(nil, "return", "Return", Keys.returnKey, 0, false)],
            [("⌃", "Control", Keys.control), ("⌥", "Option", Keys.option), ("⌘", "Command", Keys.command), ("⇧", "Shift", Keys.shift)]
                .map { title, label, flag in modifier(title, label: label, flag) },
            [key(nil, "arrow.left", "Left", Keys.left, 0, true), key(nil, "arrow.up", "Up", Keys.up, 0, true),
             key(nil, "arrow.down", "Down", Keys.down, 0, true), key(nil, "arrow.right", "Right", Keys.right, 0, true)],
            // ⌘X ⌘C ⌘V ⌘Z, by key position
            [key("Cut", nil, "Cut", 0x07, Keys.command, false), key("Copy", nil, "Copy", 0x08, Keys.command, false),
             key("Paste", nil, "Paste", 0x09, Keys.command, false), key("Undo", nil, "Undo", 0x06, Keys.command, false)],
        ]
        rows.joined().forEach(view.addSubview)

        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        aboveKeyboard.isHidden = true
        aboveKeyboard.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(aboveKeyboard)
        NSLayoutConstraint.activate([aboveKeyboard.topAnchor.constraint(equalTo: view.topAnchor),
                                     aboveKeyboard.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                     aboveKeyboard.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                                     aboveKeyboard.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)])
        typing.onEdit = { [weak self] in self?.type($0) }
        typing.onInsert = { [weak self] in self?.typedKey($0) ?? false }
        typing.onDelete = { [weak self] in self?.typedDelete(empty: $0) ?? false }
        view.addSubview(typing)

        keys.onScreen = { [weak self] m in
            switch m.t {
            case "kbreset": self?.typing.reset()
            case "kbused": self?.used()
            default: break
            }
        }
        keys.$screen.combineLatest(keys.$typingInto, keys.$paired).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.say() }.store(in: &watching)
        keys.$sessionsThere.combineLatest(keys.$desktopThere).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.view.setNeedsLayout() }.store(in: &watching)
        // a sheet (the pairing code) takes the keyboard: back once it's gone; and what's latched goes with the link
        keys.$prompt.receive(on: DispatchQueue.main).sink { [weak self] p in if p == nil { self?.showKeyboard() } }.store(in: &watching)
        keys.$screen.receive(on: DispatchQueue.main).sink { [weak self] s in
            guard let self else { return }
            typing.reset()
            if s == nil { latched = 0; held = 0; usedHeld = 0; turningOff = 0 } else if latched != 0 {
                var m = Msg("kblatch"); m.f = latched
                keys.send(m)
            }
        }.store(in: &watching)
        NotificationCenter.default.addObserver(self, selector: #selector(showKeyboard), name: UIApplication.didBecomeActiveNotification, object: nil)
        say()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true   // a keyboard that dims and locks mid-sentence is no keyboard
        showKeyboard()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        repeating?.invalidate()
        keys.onScreen = { _ in }
    }

    // iPadOS's own three-finger gestures (undo, redo, copy, paste) stay out of the trackpad's, keyboard up or away
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    @objc private func showKeyboard() {
        guard viewIfLoaded?.window != nil, presentedViewController == nil, !typing.isFirstResponder, !keyboardAway else { return }
        typing.becomeFirstResponder()
    }

    private func showCorrects() {
        correctButton.isSelected = typing.corrects
        correctButton.accessibilityLabel = typing.corrects ? "Autocorrection is on" : "Autocorrection is off"
    }

    /// What it types into, or what's missing for it to type anywhere.
    private func say() {
        let other = UIDevice.current.userInterfaceIdiom == .pad ? "iPhone or iPad" : "iPad"
        if let s = keys.screen {
            status.text = keys.typingInto.isEmpty ? "Connected to \(s.name)" : keys.typingInto
            detail.text = keys.typingInto.isEmpty ? "Open a Mac's window or Desktop there to type into it." : "Typing on \(s.name)"
        } else if keys.paired.isEmpty {
            status.text = "Not paired yet"
            detail.text = "Open Hither on your \(other), on the same Wi-Fi or this device's hotspot, and tap Pair there."
        } else {
            status.text = "Looking for \(keys.paired.map(\.name).joined(separator: ", "))…"
            detail.text = "Open Hither there, on the same Wi-Fi or this device's hotspot."
        }
    }

    // MARK: layout

    /// The keys, or the trackpad, fill what the keyboard leaves: four rows of four keys, or two of eight where
    /// that's too low (a phone on its side).
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets), gap: CGFloat = 8
        let keyboardTop = min(aboveKeyboard.frame.maxY, safe.maxY)
        let low = keyboardTop - safe.minY < 300
        closeButton.frame = CGRect(x: safe.minX + gap, y: safe.minY + gap, width: 36, height: 36)
        keyboardButton.frame = CGRect(x: safe.maxX - gap - 36, y: safe.minY + gap, width: 36, height: 36)
        keyboardButton.configuration?.image = UIImage(systemName: typing.isFirstResponder ? "keyboard.chevron.compact.down" : "keyboard")
        keyboardButton.accessibilityLabel = typing.isFirstResponder ? "Put the keyboard away" : "Show the keyboard"
        correctButton.frame = closeButton.frame.offsetBy(dx: 36 + gap, dy: 0)
        nextButton.frame = keyboardButton.frame.offsetBy(dx: -(36 + gap), dy: 0)
        nextButton.isHidden = keys.sessionsThere < 2
        switchKey.isEnabled = keys.desktopThere
        // the switch between them: beside the buttons on the left with what it types into after it where it's low,
        // else in the middle with that below
        mode.frame = CGRect(x: low ? correctButton.frame.maxX + gap : safe.midX - 85, y: safe.minY + gap + 2, width: 170, height: 32)
        detail.isHidden = low
        status.textAlignment = low ? .left : .center
        let right = nextButton.isHidden ? keyboardButton.frame.minX : nextButton.frame.minX
        status.frame = low ? CGRect(x: mode.frame.maxX + gap, y: safe.minY + gap, width: max(0, right - mode.frame.maxX - 2 * gap), height: 36)
                           : CGRect(x: safe.minX + gap, y: closeButton.frame.maxY + 6, width: safe.width - 2 * gap, height: 22)
        detail.frame = CGRect(x: safe.minX + gap, y: status.frame.maxY + 2, width: safe.width - 2 * gap, height: 34)
        let top = (low ? closeButton.frame.maxY : detail.frame.maxY) + gap
        let area = CGRect(x: safe.minX + gap, y: top, width: safe.width - 2 * gap, height: max(0, keyboardTop - gap - top))
        let trackpad = mode.selectedSegmentIndex == 1
        pad.isHidden = !trackpad
        pad.frame = area
        rows.joined().forEach { $0.isHidden = trackpad }
        let pad = gap
        let grid: [[UIButton]] = low ? [rows[0] + rows[1], rows[2] + rows[3]] : rows
        let h = (area.height - pad * CGFloat(grid.count - 1)) / CGFloat(grid.count)
        for (r, row) in grid.enumerated() {
            let w = (area.width - pad * CGFloat(row.count - 1)) / CGFloat(row.count)
            for (c, b) in row.enumerated() {
                b.frame = CGRect(x: area.minX + CGFloat(c) * (w + pad), y: area.minY + CGFloat(r) * (h + pad), width: w, height: max(0, h))
            }
        }
    }

    // MARK: keys

    private func button(title: String?, symbol: String?, label: String) -> UIButton {
        var c = UIButton.Configuration.gray()
        c.title = title
        c.image = symbol.map { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)) } ?? nil
        c.baseForegroundColor = .label
        c.cornerStyle = .fixed
        c.background.cornerRadius = 14
        c.contentInsets = .zero
        c.titleLineBreakMode = .byClipping
        c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var a = $0
            a.font = .systemFont(ofSize: 22, weight: .medium)
            return a
        }
        let b = UIButton(configuration: c)
        b.accessibilityLabel = label
        return b
    }

    /// A key that's pressed as the finger lands, like the keyboard's own; Delete and the arrows repeat while held.
    private func plain(title: String?, symbol: String?, label: String, repeats: Bool, _ action: @escaping () -> Void) -> UIButton {
        let b = button(title: title, symbol: symbol, label: label)
        b.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            action()
            guard let self, repeats else { return }
            repeating?.invalidate()
            repeating = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.repeating = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in action() }
            }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in self?.repeating?.invalidate() }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return b
    }

    private func modifier(_ title: String, label: String, _ flag: UInt64) -> UIButton {
        let b = button(title: title, symbol: nil, label: label)
        b.configurationUpdateHandler = { b in   // latched: filled in
            var c = b.configuration
            c?.background.backgroundColor = b.isSelected ? .tintColor : .tertiarySystemFill
            c?.baseForegroundColor = b.isSelected ? .white : .label
            b.configuration = c
        }
        b.changesSelectionAsPrimaryAction = false
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UIDevice.current.playInputClick()
            held |= flag
            if latched & flag != 0 { turningOff |= flag } else { latched |= flag }
        }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            held &= ~flag
            if (turningOff | usedHeld) & flag != 0 { latched &= ~flag }   // tapped again, or held for what it was used on
            turningOff &= ~flag
            usedHeld &= ~flag
        }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        modifierButtons.append((flag, b))
        return b
    }

    /// A key here or a click there took the modifiers: the latched ones are let go of, the held ones once the finger
    /// lifts.
    private func used() {
        usedHeld |= latched & held
        latched &= held
    }

    private func take() -> UInt64 {
        let f = latched
        if f != 0 { used() }
        return f
    }

    // MARK: typing

    /// A Mac key with the latched modifiers, pressed and let go.
    private func press(_ code: Int, _ flags: UInt64 = 0) {
        var m = Msg("key"); m.k = code; m.f = take() | flags
        keys.send(m)
        typing.reset()   // the cursor may be anywhere now
    }

    private func key(_ code: Int) {
        var m = Msg("key"); m.k = code; m.f = 0
        keys.send(m)
    }

    /// What the typed text changed by: Deletes, then the text, with Return and Tab in it as those keys. Latched
    /// modifiers don't carry into text.
    private func type(_ edit: TypingEdit) {
        _ = take()
        for _ in 0..<edit.deletes { key(Keys.delete) }
        var run = ""
        let flush = { [self] in
            guard !run.isEmpty else { return }
            var m = Msg("text"); m.text = run
            keys.send(m)
            run = ""
        }
        for c in edit.insert {
            guard c.isNewline || c == "\t" else { run.append(c); continue }
            flush()
            key(c == "\t" ? Keys.tab : Keys.returnKey)
        }
        flush()
    }

    /// Typed, but a Mac key instead of text: Return, Tab, or with ⌘, ⌃ or ⌥ latched the shortcut for that key.
    private func typedKey(_ text: String) -> Bool {
        if text == "\n" {
            press(Keys.returnKey)
        } else if text == "\t" {
            press(Keys.tab)
        } else if latched & (Keys.command | Keys.control | Keys.option) != 0, text.count == 1, let k = Keys.code(for: text.first!) {
            press(k.code, k.shift ? Keys.shift : 0)
        } else {
            return false
        }
        return true
    }

    /// Delete as a Mac key: with nothing typed to take back, or with modifiers latched (⌥ deletes a word).
    private func typedDelete(empty: Bool) -> Bool {
        guard empty || latched != 0 else { return false }
        press(Keys.delete)
        return true
    }
}

/// A trackpad for the Mac's pointer, which the device this one is the keyboard of draws and moves (StreamView): one
/// finger moves it (faster the faster it goes: Trackpad), a tap clicks (again quickly for a double or triple click),
/// a two-finger tap right-clicks, two fingers scroll, gliding on after a flick, and a touch and hold then moving
/// drags. Modifiers latched beside it join the click, as they do a tap on the other device. Three fingers swiped
/// across it are three fingers swiped across a Desktop there: the Mac's next desktop that way, Mission Control
/// upwards, the app's windows downwards (Keymap.desktopKey).
final class PadView: UIView, UIGestureRecognizerDelegate {
    /// "padmove", "padclick", "paddown", "padup", "padscroll", "padswipe": to the other device (KeyLink).
    var send: (Msg) -> Void = { _ in }

    private let hint = UILabel()
    private let tap = UITapGestureRecognizer(), rightTap = UITapGestureRecognizer()
    private let scroll = UIPanGestureRecognizer(), hold = UILongPressGestureRecognizer()
    private let swipe = UIPanGestureRecognizer()
    private var swiped = false   // that swipe did its one thing already
    private var finger: (touch: UITouch, at: CGPoint, time: TimeInterval, moving: Bool)?   // the one finger that moves the pointer
    private var lastTap: (at: CFTimeInterval, count: Int)?
    private var dragAt: CGPoint?   // touch and hold: the finger, as last seen
    private var glide: Glide?
    private var glideLink: CADisplayLink?
    private static let scrollGain: CGFloat = 1.5   // a phone is a small trackpad

    init() {
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 14
        isMultipleTouchEnabled = true
        hint.text = "Trackpad\nTap to click · two fingers to scroll or right-click · hold, then move, to drag\nThree fingers: left or right for the next desktop, up for Mission Control"
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .tertiaryLabel
        addSubview(hint)
        tap.addTarget(self, action: #selector(tapped))
        rightTap.addTarget(self, action: #selector(rightTapped))
        rightTap.numberOfTouchesRequired = 2
        scroll.addTarget(self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        hold.addTarget(self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 8
        swipe.addTarget(self, action: #selector(swipedThree(_:)))
        swipe.minimumNumberOfTouches = 3
        swipe.maximumNumberOfTouches = 3
        swipe.delegate = self
        [tap, rightTap, scroll, hold, swipe].forEach(addGestureRecognizer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        hint.frame = bounds.insetBy(dx: 16, dy: 8)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopGlide() }   // (the display link keeps this view until then)
    }

    // MARK: one finger: the pointer

    // By touches, not a pan gesture: that one starts only after 10 points, a long way for a pointer. Here it's 4,
    // so a tap's tremble doesn't move it.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopGlide()
        finger = event?.allTouches?.count == 1 ? touches.first.map { ($0, $0.location(in: self), $0.timestamp, false) } : nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let f = finger, touches.contains(f.touch), event?.allTouches?.count == 1 else { return }
        let at = f.touch.location(in: self), d = CGPoint(x: at.x - f.at.x, y: at.y - f.at.y)
        if !f.moving {
            guard hypot(d.x, d.y) > 4 else { return }
            finger = (f.touch, at, f.touch.timestamp, true)
            return
        }
        move(Trackpad.move(d, in: f.touch.timestamp - f.time))
        finger = (f.touch, at, f.touch.timestamp, true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finger = nil }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finger = nil }

    private func move(_ d: CGPoint) {
        var m = Msg("padmove"); m.dx = d.x; m.dy = d.y
        send(m)
    }

    // MARK: taps, touch and hold, two fingers

    private func click(button: Int, count: Int) {
        var m = Msg("padclick"); m.b = button; m.c = count
        send(m)
    }

    @objc private func tapped() {
        let now = CACurrentMediaTime()
        var count = 1
        if let l = lastTap, now - l.at < 0.4 { count = l.count % 3 + 1 }
        lastTap = (now, count)
        click(button: 0, count: count)
    }

    @objc private func rightTapped() { click(button: 1, count: 1) }

    @objc private func held(_ g: UILongPressGestureRecognizer) {
        let at = g.location(in: self)
        switch g.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            dragAt = at
            var m = Msg("paddown"); m.b = 0
            send(m)
        case .changed:
            guard let was = dragAt else { return }
            dragAt = at
            move(CGPoint(x: (at.x - was.x) * 1.2, y: (at.y - was.y) * 1.2))   // a drag is careful work: no speeding up
        case .ended, .cancelled, .failed:
            guard dragAt != nil else { return }
            dragAt = nil
            send(Msg("padup"))
        default: break
        }
    }

    /// Three fingers swiped, once per swipe, as soon as it's clear which way. A scroll the first two began ends
    /// there, cancelled.
    @objc private func swipedThree(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            swiped = false
            if scroll.state == .began || scroll.state == .changed { scroll.isEnabled = false; scroll.isEnabled = true }
        case .changed:
            guard !swiped, let key = Keymap.desktopKey(swiped: g.translation(in: self)) else { return }
            swiped = true
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            var m = Msg("padswipe"); m.k = key
            send(m)
        default: break
        }
    }

    /// A scroll two fingers began doesn't keep the third from starting a swipe.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        g === swipe || other === swipe
    }

    // iPadOS's own three-finger gestures (undo, redo, copy, paste) stay out of it
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    /// Two fingers scroll what's under the pointer, as a finger on the other device scrolls what's under it, with
    /// a scroll's phases (CGScrollPhase), and glide on after a flick.
    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        if g.state == .began { stopGlide() }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let phase = g.state == .began ? 1 : g.state == .changed ? 2 : g.state == .ended ? 4 : 8
        scroll(CGPoint(x: t.x * Self.scrollGain, y: t.y * Self.scrollGain), phase: phase, momentum: 0)
        guard g.state == .ended else { return }
        let v = g.velocity(in: self)
        guard let glide = Glide(velocity: CGPoint(x: v.x * Self.scrollGain, y: v.y * Self.scrollGain), at: CACurrentMediaTime(),
                                minimum: 250, stop: 20, maximum: 8000) else { return }
        self.glide = glide
        scroll(glide.start.delta, phase: 0, momentum: glide.start.phase.rawValue)
        let link = CADisplayLink(target: self, selector: #selector(glideTick(_:)))
        link.add(to: .main, forMode: .common)
        glideLink = link
    }

    private func scroll(_ d: CGPoint, phase: Int, momentum: Int) {
        var m = Msg("padscroll"); m.dx = d.x; m.dy = d.y; m.p = phase; m.mp = momentum
        send(m)
    }

    @objc private func glideTick(_ link: CADisplayLink) {
        guard var g = glide else { return stopGlide() }
        let step = g.step(to: link.targetTimestamp)
        glide = g
        if let step { scroll(step.delta, phase: 0, momentum: step.phase.rawValue) }
        if g.ended { glide = nil; stopGlide() }
    }

    /// Stop gliding, telling the other device the momentum ended unless it has already.
    private func stopGlide() {
        glideLink?.invalidate()
        glideLink = nil
        if var g = glide, let end = g.stop() { scroll(end.delta, phase: 0, momentum: end.phase.rawValue) }
        glide = nil
    }
}
