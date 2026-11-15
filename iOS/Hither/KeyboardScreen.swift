import Combine
import Shared
import SwiftUI
import UIKit

/// This device as the keyboard of another showing Hither (KeyLink): its own keyboard along the bottom, with all it
/// brings (other languages, dictation, swipe typing), and the rest of the screen for the keys it lacks, big: esc, tab,
/// Delete, Return, the modifiers, the arrows, and Cut, Copy, Paste, Undo.
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
    private var closeButton: UIButton!
    private var rows: [[UIButton]] = []
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

        let key = { [unowned self] (title: String?, symbol: String?, label: String, code: Int, flags: UInt64, repeats: Bool) in
            plain(title: title, symbol: symbol, label: label, repeats: repeats) { [weak self] in self?.press(code, flags) }
        }
        rows = [
            [key("esc", nil, "Escape", Keys.escape, 0, false), key("tab", nil, "Tab", Keys.tab, 0, false),
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
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showKeyboard)))   // put away: back with a tap

        keys.onScreen = { [weak self] m in
            switch m.t {
            case "kbreset": self?.typing.reset()
            case "kbused": self?.used()
            default: break
            }
        }
        keys.$screen.combineLatest(keys.$typingInto, keys.$paired).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.say() }.store(in: &watching)
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

    @objc private func showKeyboard() {
        guard viewIfLoaded?.window != nil, presentedViewController == nil, !typing.isFirstResponder else { return }
        typing.becomeFirstResponder()
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

    /// The keys fill what the keyboard leaves: four rows of four, or two of eight where that's too low (a phone
    /// on its side).
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.bounds.inset(by: view.safeAreaInsets), pad: CGFloat = 8
        let keyboardTop = min(aboveKeyboard.frame.maxY, safe.maxY)
        closeButton.frame = CGRect(x: safe.minX + pad, y: safe.minY + pad, width: 36, height: 36)
        let low = keyboardTop - safe.minY < 300
        let text = CGRect(x: closeButton.frame.maxX + pad, y: safe.minY + pad, width: safe.width - 2 * (closeButton.frame.maxX - safe.minX + pad), height: 36)
        detail.isHidden = low
        status.frame = low ? text : text.divided(atDistance: 20, from: .minYEdge).slice
        detail.frame = CGRect(x: safe.minX + pad, y: status.frame.maxY + 2, width: safe.width - 2 * pad, height: 34)
        let top = (low ? text.maxY : detail.frame.maxY) + pad
        let area = CGRect(x: safe.minX + pad, y: top, width: safe.width - 2 * pad, height: max(0, keyboardTop - pad - top))
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
