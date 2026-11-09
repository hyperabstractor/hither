import Shared
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// One Mac window or a Mac's Desktop, full screen.
struct StreamScreen: View {
    @ObservedObject var macs: Macs
    @StateObject private var window: RemoteWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var transferTop: CGFloat?    // the transfer bar's top, in the window, while it shows

    init(macs: Macs, mac: Peer, item: Item) {
        self.macs = macs
        _window = StateObject(wrappedValue: RemoteWindow(mac: mac, item: item, macs: macs))
    }

    var body: some View {
        StreamControls(window: window, macs: macs, transferTop: transferTop) { dismiss() }
            .ignoresSafeArea()
            .overlay {
                if !window.status.isEmpty {
                    Text(window.status)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                }
            }
            .overlay(alignment: .bottom) { TransferBar(macs: macs).environment(\.colorScheme, .dark) }
            .onPreferenceChange(TransferTop.self) { transferTop = $0 }
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onAppear { macs.stream = window }
            .onChange(of: window.closed) { _, closed in if closed { dismiss() } }
            .onChange(of: phase) { _, p in
                if p == .background { window.pause() } else if p == .active { window.resume() }
            }
            .onDisappear {
                window.finish()
                if macs.stream === window { macs.stream = nil }
            }
    }
}

/// The picture fills the whole screen. The controls float over it, collapsed to one round button in a corner (the
/// bottom right unless dragged to another), and open into a row, or a column where a row doesn't fit, or columns side
/// by side where neither does. They keep clear of the transfer bar and the keyboard; the picture never makes room.
struct StreamControls: UIViewControllerRepresentable {
    let window: RemoteWindow
    let macs: Macs
    let transferTop: CGFloat?
    let close: () -> Void

    func makeUIViewController(context: Context) -> StreamController { StreamController(window: window, macs: macs, close: close) }
    func updateUIViewController(_ c: StreamController, context: Context) { c.transferTop = transferTop }
}

/// Where the transfer bar starts, in the window, while it shows.
struct TransferTop: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// Takes touches only on its buttons: between and around them they reach the picture beneath.
private final class PassThroughView: UIView {
    override func hitTest(_ p: CGPoint, with e: UIEvent?) -> UIView? {
        let hit = super.hitTest(p, with: e)
        return hit === self ? nil : hit
    }
}

final class StreamController: UIViewController, UIDocumentPickerDelegate {
    let window: RemoteWindow
    let macs: Macs
    let close: () -> Void
    private var mac: Peer { window.mac }
    private let controls = PassThroughView()
    private var tools: [UIButton] = []           // everything but the handle: shown while open
    private var menusButton: UIButton!, sizeButton: UIButton!, handle: UIButton!
    private var expanded = false
    /// The corner the controls keep to: bit 0 = right, bit 1 = bottom. Remembered.
    private var corner = UserDefaults.standard.object(forKey: "controls.corner") as? Int ?? 3
    private var dragFrom: CGPoint?               // the handle is being dragged: the controls' center when it started
    private var keyboard: CGRect?                // the on-screen keyboard, in screen coordinates
    private let margin: CGFloat = 12, spacing: CGFloat = 10
    /// The transfer bar's top, in the window, while it shows: the controls stay above it.
    var transferTop: CGFloat? {
        didSet {
            guard transferTop != oldValue, isViewLoaded else { return }
            UIView.animate(withDuration: 0.25) { [self] in if dragFrom == nil { placeControls() } }
        }
    }
    /// Window sizes on offer, as Mac points per viewer point.
    private let sizes: [(String, Double)] = [("Larger Text", 0.75), ("Actual Size", 1), ("More Space", 1.5), ("Most Space", 2)]

    init(window: RemoteWindow, macs: Macs, close: @escaping () -> Void) {
        self.window = window
        self.macs = macs
        self.close = close
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let v = window.view
        v.scale = UserDefaults.standard.object(forKey: "scale") as? Double ?? 1
        view.addSubview(v)
        v.onResign = { [weak self] in self?.takeKeys() }

        menusButton = menuButton("menubar.rectangle", label: "App menus") { [weak self] in self?.appMenus() ?? [] }
        sizeButton = menuButton("textformat.size", label: "Window size") { [weak self] in self?.sizeMenu() ?? [] }
        tools = [
            button("keyboard", label: "Keyboard") { [weak self] in
                guard let v = self?.window.view else { return }
                _ = v.isFirstResponder ? v.resignFirstResponder() : v.becomeFirstResponder()
            },
            menusButton,
            menuButton("rectangle.on.rectangle", label: "Windows") { [weak self] in self?.windowsMenu() ?? [] },
            sizeButton,
            menuButton("ellipsis", label: "More") { [weak self] in self?.moreMenu() ?? [] },
            button("xmark", label: "Close stream") { [weak self] in self?.close() },
        ]
        handle = button("slider.horizontal.3", label: "Show controls") { [weak self] in self?.toggle() }
        handle.accessibilityHint = "Drag to move the controls to another corner"
        handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        for b in tools + [handle!] { controls.addSubview(b) }   // laid out by hand: see placeControls
        view.addSubview(controls)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        window.onSwitch = { [weak self] in self?.targetChanged() }
        targetChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        takeKeys()
    }

    /// Controls for what's shown: a Desktop has no app menus, and zooms instead of resizing a window.
    private func targetChanged() {
        var c = sizeButton.configuration
        c?.image = symbol(window.isDesktop ? "plus.magnifyingglass" : "textformat.size")
        sizeButton.configuration = c
        sizeButton.accessibilityLabel = window.isDesktop ? "Zoom and screen" : "Window size"
        showTools()
        view.setNeedsLayout()
    }

    private func showTools() {
        for b in tools { b.isHidden = !expanded }
        menusButton.isHidden = !expanded || window.isDesktop
        var c = handle.configuration
        c?.image = symbol(expanded ? "arrow.down.right.and.arrow.up.left" : "slider.horizontal.3")
        handle.configuration = c
        handle.accessibilityLabel = expanded ? "Hide controls" : "Show controls"
    }

    /// Open or close the controls. Only they change: the picture keeps its size, so nothing goes to the Mac.
    private func toggle() {
        expanded.toggle()
        UIView.animate(withDuration: 0.2) { [self] in
            showTools()
            placeControls()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if window.view.frame != view.bounds { window.view.frame = view.bounds }   // all of it, in every orientation
        if dragFrom == nil { placeControls() }
    }

    /// The on-screen keyboard, where it covers this view.
    private var keyboardHere: CGRect? {
        guard let k = keyboard, let screen = view.window?.screen else { return nil }
        let f = view.convert(k, from: screen.coordinateSpace).intersection(view.bounds)
        return f.isNull || f.isEmpty ? nil : f
    }

    /// The keyboard runs along the bottom, across the whole view (not floating or undocked).
    private func docked(_ k: CGRect) -> Bool { k.maxY >= view.bounds.maxY - 1 && k.width >= view.bounds.width - 1 }

    /// Where the controls may go: the safe area with a margin, above a docked keyboard and the transfer bar.
    private var room: CGRect {
        var r = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: margin, dy: margin)
        var floor = r.maxY
        if let k = keyboardHere, docked(k) { floor = min(floor, k.minY - margin) }
        if let t = transferTop { floor = min(floor, view.convert(CGPoint(x: 0, y: t), from: nil).y - margin) }
        r.size.height = max(0, floor - r.minY)
        return r
    }

    /// In their corner, the handle nearest it: a row if it fits across, else a column if it fits down, else columns
    /// side by side, so every button stays reachable. A floating keyboard moves them only if it would cover them.
    private func placeControls() {
        let r = room, right = corner & 1 != 0, bottom = corner & 2 != 0
        let shown = [handle!] + tools.reversed().filter { !$0.isHidden }   // from the corner outwards
        let cell = shown.reduce(CGFloat(44)) { m, b in
            let s = b.intrinsicContentSize
            return max(m, s.width, s.height)
        }
        let step = cell + spacing, n = shown.count
        let perColumn = CGFloat(n) * step - spacing <= r.width ? 1 : max(1, min(n, Int((r.height + spacing) / step)))
        let columns = (n + perColumn - 1) / perColumn, rows = min(n, perColumn)
        let size = CGSize(width: CGFloat(columns) * step - spacing, height: CGFloat(rows) * step - spacing)
        for (k, b) in shown.enumerated() {
            let x = CGFloat(k / perColumn) * step, y = CGFloat(k % perColumn) * step
            b.frame = CGRect(x: right ? size.width - cell - x : x, y: bottom ? size.height - cell - y : y,
                             width: cell, height: cell)
        }
        var f = CGRect(origin: CGPoint(x: right ? r.maxX - size.width : r.minX, y: bottom ? r.maxY - size.height : r.minY),
                       size: size)
        if let k = keyboardHere, !docked(k), f.intersects(k.insetBy(dx: -margin, dy: -margin)) {
            let above = k.minY - margin - size.height, below = k.maxY + margin
            let fitsAbove = above >= r.minY, fitsBelow = below + size.height <= r.maxY
            if fitsAbove, bottom || !fitsBelow { f.origin.y = above } else if fitsBelow { f.origin.y = below }
        }
        controls.frame = f
    }

    /// Dragging the handle moves the controls; let go and they settle in the nearest corner.
    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            dragFrom = controls.center
        case .changed:
            guard let from = dragFrom else { return }
            let t = g.translation(in: view), r = room, half = CGSize(width: controls.bounds.width / 2, height: controls.bounds.height / 2)
            controls.center = CGPoint(x: min(max(from.x + t.x, r.minX + half.width), max(r.minX + half.width, r.maxX - half.width)),
                                      y: min(max(from.y + t.y, r.minY + half.height), max(r.minY + half.height, r.maxY - half.height)))
        case .ended, .cancelled, .failed:
            guard dragFrom != nil else { return }
            dragFrom = nil
            let r = room, c = controls.center
            corner = (c.x > r.midX ? 1 : 0) | (c.y > r.midY ? 2 : 0)
            UserDefaults.standard.set(corner, forKey: "controls.corner")
            UIView.animate(withDuration: 0.25) { [self] in placeControls() }
        default: break
        }
    }

    @objc private func keyboardChanged(_ n: Notification) {
        keyboard = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        let duration = n.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        UIView.animate(withDuration: duration) { [self] in if dragFrom == nil { placeControls() } }
    }

    // MARK: hardware keyboard

    /// Hardware keys go to the Mac without the on-screen keyboard: this controller takes them while the picture
    /// doesn't (the picture takes them itself while the on-screen keyboard is up).
    override var canBecomeFirstResponder: Bool { true }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    private func takeKeys() {
        guard viewIfLoaded?.window != nil, !window.view.isFirstResponder else { return }
        becomeFirstResponder()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !window.view.hardware(presses, down: true) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !window.view.hardware(presses, down: false) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !window.view.hardware(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    // MARK: menus

    /// The Mac app's menu bar, read when opened (so checkmarks and enabled items are current). Choosing an item
    /// chooses it there.
    private func appMenus() -> [UIMenuElement] {
        [UIDeferredMenuElement.uncached { [weak self] done in
            guard let self else { return done([]) }
            window.menu([]) { [weak self] bar in
                guard let self, let bar, bar.count > 1 else {
                    return done([UIAction(title: "No menus to show", attributes: .disabled) { _ in }])
                }
                // the first is the Apple menu, which is about the Mac rather than the app
                done(bar.enumerated().dropFirst().map { i, e in UIMenu(title: e.title, children: [self.remoteMenu([i])]) })
            }
        }]
    }

    private func remoteMenu(_ path: [Int]) -> UIMenuElement {
        UIDeferredMenuElement.uncached { [weak self] done in
            guard let self else { return done([]) }
            window.menu(path) { [weak self] entries in
                guard let self, let entries else { return done([UIAction(title: "Couldn't read this menu", attributes: .disabled) { _ in }]) }
                let items = menuItems(entries, path)
                done(items.isEmpty ? [UIAction(title: "Empty", attributes: .disabled) { _ in }] : items)
            }
        }
    }

    /// Items that would move or hide the window on the Mac: the stream follows it, so they'd only lose it.
    private static let windowItems: Set<String> = ["Minimize", "Minimize All", "Zoom", "Zoom All", "Enter Full Screen",
        "Exit Full Screen", "Toggle Full Screen", "Hide Others", "Show All", "Bring All to Front", "Arrange in Front"]

    private func menuItems(_ entries: [MenuEntry], _ path: [Int]) -> [UIMenuElement] {
        var groups: [[UIMenuElement]] = [[]]
        for (j, e) in entries.enumerated() {
            if e.title.isEmpty { groups.append([]); continue }
            if Self.windowItems.contains(e.title) || (path.count == 1 && path[0] == 1 && e.title.hasPrefix("Hide ")) { continue }
            let p = path + [j]
            if e.sub {
                groups[groups.count - 1].append(e.enabled ? UIMenu(title: e.title, children: [remoteMenu(p)])
                                                          : UIAction(title: e.title, attributes: .disabled) { _ in })
            } else {
                groups[groups.count - 1].append(UIAction(title: e.title, subtitle: shortcut(e), attributes: e.enabled ? [] : .disabled,
                                                         state: e.checked ? .on : .off) { [weak self] _ in self?.window.pressMenu(p) })
            }
        }
        return groups.filter { !$0.isEmpty }.map { UIMenu(options: .displayInline, children: $0) }
    }

    /// "⇧⌘S" for reference; the keys themselves go straight to the Mac app from a hardware keyboard.
    private func shortcut(_ e: MenuEntry) -> String? {
        guard e.key.count == 1, let c = e.key.unicodeScalars.first, c.value >= 0x21, c.value < 0xF700 else { return nil }
        let mods = (e.mods & 4 != 0 ? "⌃" : "") + (e.mods & 2 != 0 ? "⌥" : "") + (e.mods & 1 != 0 ? "⇧" : "") + (e.mods & 8 == 0 ? "⌘" : "")
        return mods + e.key.uppercased()
    }

    /// The Mac's Desktop, its open windows and recent apps: show one instead of what's shown now.
    private func windowsMenu() -> [UIMenuElement] {
        [UIDeferredMenuElement.uncached { [weak self] done in
            guard let self else { return done([]) }
            macs.list(mac) { [weak self] items in
                guard let self else { return done([]) }
                let current = window.item
                let desktop = UIAction(title: "Desktop", image: symbol("display"), state: window.isDesktop ? .on : .off) { [weak self] _ in
                    self?.window.show(Item(id: 0, app: "Desktop", bundle: desktopApp, title: ""))
                }
                let shownID = window.isDesktop ? nil : Optional(window.windowID)
                let icons = macs.icons, small = { (b: String) in icons[b].map(self.icon) }
                let show = { [weak self] (i: Item) in self?.window.show(i) }
                let open = items.map { w in
                    UIAction(title: w.app, subtitle: w.title.isEmpty || w.title == w.app ? nil : w.title, image: small(w.bundle),
                             state: w.id == shownID ? .on : .off) { _ in show(w) }
                }
                let recent = macs.recent(on: mac).filter { r in !items.contains { $0.bundle == r.bundle } && r.bundle != current.bundle }.prefix(5).map { r in
                    UIAction(title: r.app, image: small(r.bundle)) { _ in show(r) }
                }
                var all: [UIMenuElement] = [UIMenu(options: .displayInline, children: [desktop])]
                all.append(UIMenu(title: "Open on \(mac.name)", options: .displayInline,
                                  children: open.isEmpty ? [UIAction(title: "No windows open", attributes: .disabled) { _ in }] : open))
                if !recent.isEmpty { all.append(UIMenu(title: "Recent", options: .displayInline, children: Array(recent))) }
                done(all)
            }
        }]
    }

    private func icon(_ image: UIImage) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 24, height: 24)) }
    }

    private func sizeMenu() -> [UIMenuElement] {
        let info = [window.title, window.latency].filter { !$0.isEmpty }.joined(separator: " · ")
        if window.isDesktop { return desktopMenu(info) }
        let current = window.view.scale
        let items = sizes.map { (title, scale) in
            UIAction(title: title, subtitle: "\(Int(scale * 100))%", state: scale == current ? .on : .off) { [weak self] _ in
                UserDefaults.standard.set(scale, forKey: "scale")
                self?.window.view.scale = scale
            }
        }
        return [UIMenu(title: info, options: .displayInline, children: items)]
    }

    /// Zoom here (Fit, 1:1, in and out; pinch does it too), and what the Mac's screen does: Adaptive has it take the
    /// resolution nearest this screen while Keep Screen Dark is on; Native keeps its own.
    private func desktopMenu(_ info: String) -> [UIMenuElement] {
        let v = window.view, z = v.zoom, pct = Int((v.scaleNow * 100).rounded())
        let zoom = UIMenu(title: "Zoom · \(pct)%", options: .displayInline, children: [
            UIAction(title: "Fit", image: symbol("arrow.up.left.and.down.right.magnifyingglass"), state: z == nil ? .on : .off) { [weak v] _ in v?.setZoom(nil) },
            UIAction(title: "Actual Size", subtitle: "A Mac point is a point here", image: symbol("1.magnifyingglass"),
                     state: abs(v.scaleNow - 1) < 0.005 ? .on : .off) { [weak v] _ in v?.setZoom(1) },
            UIAction(title: "Zoom In", image: symbol("plus.magnifyingglass")) { [weak v] _ in v?.zoomStep(1) },
            UIAction(title: "Zoom Out", image: symbol("minus.magnifyingglass")) { [weak v] _ in v?.zoomStep(-1) },
        ])
        let dark = macs.dark[mac.id] ?? false
        let screen = UIMenu(title: "\(mac.name)'s Screen", options: .displayInline, children: [
            UIAction(title: "Adaptive", subtitle: dark ? "Takes the resolution nearest this screen; its windows rearrange to fit"
                                    : "Only while Keep Screen Dark is on: takes the resolution nearest this screen",
                     state: window.native ? .off : .on) { [weak self] _ in self?.window.native = false },
            UIAction(title: "Native", subtitle: "Keeps its own resolution", state: window.native ? .on : .off) { [weak self] _ in self?.window.native = true },
        ])
        return [UIMenu(title: info, options: .displayInline, children: [zoom, screen])]
    }

    private func moreMenu() -> [UIMenuElement] {
        let name = mac.name, dark = macs.dark[mac.id] ?? false
        let clip = UIMenu(options: .displayInline, children: [
            UIAction(title: "Send Clipboard to \(name)", image: symbol("doc.on.clipboard")) { [weak self] _ in
                guard let self else { return }
                macs.sendClipboard(to: mac)
            },
            UIAction(title: "Get Clipboard from \(name)", image: symbol("clipboard")) { [weak self] _ in
                guard let self else { return }
                macs.getClipboard(from: mac)
            },
            UIAction(title: "Send Files to \(name)…", image: symbol("folder")) { [weak self] _ in self?.pickFiles() },
        ])
        let screen = UIMenu(options: .displayInline, children: [
            UIAction(title: "Keep Screen Dark", subtitle: "\(name)'s own monitors show black while you use it; it locks 2 minutes after you stop",
                     image: symbol("moon"), state: dark ? .on : .off) { [weak self] _ in
                guard let self else { return }
                macs.setDark(!dark, on: mac)
            },
            UIAction(title: "Lock \(name)…", image: symbol("lock")) { [weak self] _ in self?.confirmLock() },
        ])
        return [clip, screen]
    }

    private func confirmLock() {
        let a = UIAlertController(title: "Lock \(mac.name)?", message: "It locks right away. Its Desktop shows the lock screen, where you can type its password.",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        a.addAction(UIAlertAction(title: "Lock", style: .destructive) { [weak self] _ in
            guard let self else { return }
            macs.lock(mac)
        })
        present(a, animated: true)
    }

    private func pickFiles() {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = self
        present(p, animated: true)
    }

    func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        macs.sendFiles(urls, to: mac, cleanup: urls)
    }

    // MARK: buttons

    private func symbol(_ name: String) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
    }

    private func configuration(_ name: String) -> UIButton.Configuration {
        var c = UIButton.Configuration.filled()
        c.image = symbol(name)
        c.baseBackgroundColor = UIColor(white: 0.08, alpha: 0.62)   // over the picture: readable on light and dark alike
        c.baseForegroundColor = .white
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        return c
    }

    private func button(_ name: String, label: String, _ action: @escaping () -> Void) -> UIButton {
        let button = UIButton(configuration: configuration(name), primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = label
        stopsMomentum(button)
        return button
    }

    /// Touching a control stops a glide under it at once (the picture never sees that touch).
    private func stopsMomentum(_ b: UIButton) {
        b.addAction(UIAction { [weak self] _ in self?.window.view.stopMomentum() }, for: .touchDown)
    }

    /// A button whose menu is built each time it opens.
    private func menuButton(_ name: String, label: String, _ items: @escaping () -> [UIMenuElement]) -> UIButton {
        let button = UIButton(configuration: configuration(name))
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            self?.window.view.stopMomentum()   // also when opened without a touch (keyboard, pointer)
            done(items())
        }])
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = label
        stopsMomentum(button)
        return button
    }
}

/// File copies under way, files just received (to share or save), and passing notices: at the bottom of the screen.
struct TransferBar: View {
    @ObservedObject var macs: Macs

    var body: some View {
        if !macs.copies.isEmpty || macs.received != nil || macs.notice != nil { bar }
    }

    private var bar: some View {
        VStack(spacing: 8) {
            ForEach(macs.copies) { CopyRow(copy: $0) }
            if let r = macs.received {
                HStack(spacing: 12) {
                    Text(r.text).font(.callout).lineLimit(3)
                    Spacer(minLength: 0)
                    ShareLink(items: r.urls) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share")
                    Button { macs.received = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss")
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            if let n = macs.notice {
                Text(n)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .onTapGesture { macs.notice = nil }
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.default, value: macs.notice)
        .background(GeometryReader { g in Color.clear.preference(key: TransferTop.self, value: g.frame(in: .global).minY) })
    }
}

struct CopyRow: View {
    @ObservedObject var copy: FileCopy

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.heading).font(.callout).lineLimit(1)
                ProgressView(value: copy.fraction)
                Text(copy.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Cancel", role: .cancel) { copy.cancel() }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
