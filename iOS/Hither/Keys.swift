import UIKit

/// Mac virtual key codes (kVK_*) and modifier flags (CGEventFlags): what the host posts.
enum Keys {
    static let shift: UInt64 = 1 << 17, control: UInt64 = 1 << 18, option: UInt64 = 1 << 19, command: UInt64 = 1 << 20
    static let arrowFlags: UInt64 = 1 << 21 | 1 << 23   // numeric pad + fn: what a Mac keyboard sends with arrows
    static let returnKey = 36, tab = 48, delete = 51, escape = 53, left = 123, right = 124, down = 125, up = 126

    /// The US layout by key code, 0…50 (§ and the Return/Tab/Space slots are never looked up as characters).
    private static let us = Array("asdfhgzxcv§bqweryt123465=97-80]ou[ip\rlj'k;\\,/nm.\t `")
    private static let shifted = Array("~!@#$%^&*()_+{}|:\"<>?"), unshifted = Array("`1234567890-=[]\\;',./")

    /// The key that types `c` on a US keyboard, and whether it takes Shift. Only for shortcuts (⌘S, ⌃C): plain
    /// typing goes to the Mac as text, so it doesn't depend on the layout.
    static func code(for c: Character) -> (code: Int, shift: Bool)? {
        if c.isUppercase, c.isASCII, let i = us.firstIndex(of: Character(c.lowercased())) { return (i, true) }
        if let j = shifted.firstIndex(of: c), let i = us.firstIndex(of: unshifted[j]) { return (i, true) }
        guard c != "§", c.isASCII, !c.isWhitespace, let i = us.firstIndex(of: c) else { return nil }
        return (i, false)
    }
}

/// The row above the keyboard: keys the iPhone keyboard lacks. Modifiers latch for the next key or click.
final class KeyBar: UIInputView, UIInputViewAudioFeedback {
    var onKey: (Int) -> Void = { _ in }
    var onHide: () -> Void = {}
    private(set) var latched: UInt64 = 0
    private var modifierButtons: [(flag: UInt64, button: UIButton)] = []
    var enableInputClicksWhenVisible: Bool { true }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        for (title, code) in [("esc", Keys.escape), ("tab", Keys.tab)] {
            row.addArrangedSubview(key(title: title) { [weak self] in self?.onKey(code) })
        }
        for (title, flag) in [("⌃", Keys.control), ("⌥", Keys.option), ("⌘", Keys.command), ("⇧", Keys.shift)] {
            let b = key(title: title) { [weak self] in self?.toggle(flag) }
            modifierButtons.append((flag, b))
            row.addArrangedSubview(b)
        }
        for (symbol, code) in [("arrow.left", Keys.left), ("arrow.up", Keys.up), ("arrow.down", Keys.down), ("arrow.right", Keys.right)] {
            row.addArrangedSubview(key(symbol: symbol) { [weak self] in self?.onKey(code) })
        }
        let hide = key(symbol: "keyboard.chevron.compact.down") { [weak self] in self?.onHide() }

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.addSubview(row)
        for v in [scroll, row, hide] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(scroll)
        addSubview(hide)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            row.heightAnchor.constraint(equalToConstant: 36),
            hide.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            hide.centerYAnchor.constraint(equalTo: centerYAnchor),
            hide.heightAnchor.constraint(equalToConstant: 36),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The latched modifiers, released: they apply to one key or click.
    func take() -> UInt64 {
        defer { if latched != 0 { latched = 0; refresh() } }
        return latched
    }

    private func toggle(_ flag: UInt64) {
        latched ^= flag
        refresh()
    }

    private func refresh() {
        for (flag, b) in modifierButtons { b.isSelected = latched & flag != 0 }
    }

    private func key(title: String? = nil, symbol: String? = nil, _ action: @escaping () -> Void) -> UIButton {
        var c = UIButton.Configuration.gray()
        c.title = title
        c.image = symbol.map { UIImage(systemName: $0) } ?? nil
        c.baseForegroundColor = .label
        c.cornerStyle = .medium
        c.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        let b = UIButton(configuration: c, primaryAction: UIAction { _ in
            UIDevice.current.playInputClick()
            action()
        })
        b.configurationUpdateHandler = { b in   // a latched modifier is filled in
            var c = b.configuration
            c?.baseBackgroundColor = b.isSelected ? .tintColor : nil
            c?.baseForegroundColor = b.isSelected ? .white : .label
            b.configuration = c
        }
        b.changesSelectionAsPrimaryAction = false
        return b
    }
}
