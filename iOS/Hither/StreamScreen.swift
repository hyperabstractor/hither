import Shared
import SwiftUI
import UIKit

/// One Mac window, full screen.
struct StreamScreen: View {
    @StateObject private var window: RemoteWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase

    init(mac: Peer, item: Item) {
        _window = StateObject(wrappedValue: RemoteWindow(mac: mac, app: item.bundle, windowID: item.id,
                                                         title: item.title.isEmpty ? item.app : item.title))
    }

    var body: some View {
        StreamControls(window: window) { dismiss() }
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
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)
            .onChange(of: window.closed) { _, closed in if closed { dismiss() } }
            .onChange(of: phase) { _, p in
                if p == .background { window.pause() } else if p == .active { window.resume() }
            }
            .onDisappear { window.finish() }
    }
}

/// The picture fills the safe area. The few controls sit in the strip it leaves free: beside the camera in
/// landscape, above the picture in portrait (over the picture only where there's no such strip, as on iPad).
struct StreamControls: UIViewControllerRepresentable {
    let window: RemoteWindow
    let close: () -> Void

    func makeUIViewController(context: Context) -> StreamController { StreamController(window: window, close: close) }
    func updateUIViewController(_ c: StreamController, context: Context) {}
}

final class StreamController: UIViewController {
    let window: RemoteWindow
    let close: () -> Void
    private let controls = UIStackView()
    /// Window sizes on offer, as Mac points per phone point.
    private let sizes: [(String, Double)] = [("Larger Text", 0.75), ("Actual Size", 1), ("More Space", 1.5), ("Most Space", 2)]

    init(window: RemoteWindow, close: @escaping () -> Void) {
        self.window = window
        self.close = close
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let v = window.view
        v.scale = UserDefaults.standard.object(forKey: "scale") as? Double ?? 1
        v.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(v)
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: safe.leadingAnchor), v.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            v.topAnchor.constraint(equalTo: safe.topAnchor), v.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
        ])

        controls.spacing = 14
        controls.addArrangedSubview(button("keyboard") { [weak self] in
            guard let v = self?.window.view else { return }
            _ = v.isFirstResponder ? v.resignFirstResponder() : v.becomeFirstResponder()
        })
        let size = button("textformat.size") {}
        size.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.sizeMenu() ?? []) }])
        size.showsMenuAsPrimaryAction = true
        controls.addArrangedSubview(size)
        controls.addArrangedSubview(button("xmark") { [weak self] in self?.close() })
        view.addSubview(controls)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds, inset = view.safeAreaInsets, landscape = b.width > b.height
        controls.axis = landscape ? .vertical : .horizontal
        let s = controls.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let strip = landscape ? inset.right : inset.top
        controls.frame.size = s
        if strip >= (landscape ? s.width : s.height) + 8 {   // fits in the strip beside / above the picture
            controls.frame.origin = landscape
                ? CGPoint(x: b.maxX - (inset.right + s.width) / 2, y: (b.height - s.height) / 2)
                : CGPoint(x: b.maxX - s.width - 16, y: (inset.top - s.height) / 2)
        } else {
            controls.frame.origin = CGPoint(x: b.maxX - inset.right - s.width - 12, y: inset.top + 12)
        }
    }

    private func sizeMenu() -> [UIMenuElement] {
        let current = window.view.scale
        let items = sizes.map { (title, scale) in
            UIAction(title: title, subtitle: "\(Int(scale * 100))%", state: scale == current ? .on : .off) { [weak self] _ in
                UserDefaults.standard.set(scale, forKey: "scale")
                self?.window.view.scale = scale
            }
        }
        let info = [window.title, window.latency].filter { !$0.isEmpty }.joined(separator: " · ")
        return [UIMenu(title: info, options: .displayInline, children: items)]
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> UIButton {
        var c = UIButton.Configuration.filled()
        c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        c.baseBackgroundColor = UIColor(white: 1, alpha: 0.16)
        c.baseForegroundColor = .white
        c.cornerStyle = .capsule
        c.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        return UIButton(configuration: c, primaryAction: UIAction { _ in action() })
    }
}
