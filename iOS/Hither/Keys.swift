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

/// The keys the iPhone and iPad keyboards lack, on glass above the on-screen keyboard: one row along the top of a
/// docked one (or at the bottom with a hardware keyboard), two rows above a floating one, the same width, moving
/// with it (`compact`), or folded away to a small tab on its top edge (`collapsed`). Modifiers latch for the next key or click. StreamView places it by the keyboard layout guide:
/// iPadOS shows an input accessory view at the bottom of the screen, with nothing behind it, when the keyboard floats.
final class KeyBar: UIView {
    var onKey: (Int) -> Void = { _ in }
    var onHide: () -> Void = {}
    private(set) var latched: UInt64 = 0
    /// Two rows, rounded: above a floating keyboard.
    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            backdrop.layer.cornerRadius = compact ? 16 : 0
            for b in first + second + [collapse!, hide!] {   // narrow keys in the grid: less padding, so "esc" stays on one line
                b.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: compact ? 2 : 12, bottom: 6, trailing: compact ? 2 : 12)
            }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private var modifierButtons: [(flag: UInt64, button: UIButton)] = []
    private var first: [UIButton] = [], second: [UIButton] = []   // esc tab ⌃ ⌥ ⌘ ⇧ | ← ↑ ↓ →
    private var hide: UIButton!, collapse: UIButton!, expand: UIButton!
    /// Above a floating keyboard, folded away: only a small tab on its top edge, which unfolds them. Remembered.
    private(set) var collapsed = UserDefaults.standard.bool(forKey: "keys.collapsed") {
        didSet {
            UserDefaults.standard.set(collapsed, forKey: "keys.collapsed")
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            superview?.setNeedsLayout()
        }
    }
    var folded: Bool { compact && collapsed }
    private let backdrop: UIVisualEffectView = {
        if #available(iOS 26, *) { return UIVisualEffectView(effect: UIGlassEffect()) }
        return UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    }()
    private let scroll = UIScrollView()
    private static let pad: CGFloat = 6, keyHeight: CGFloat = 36

    init() {
        super.init(frame: .zero)
        backdrop.clipsToBounds = true
        addSubview(backdrop)
        scroll.showsHorizontalScrollIndicator = false
        backdrop.contentView.addSubview(scroll)
        for (title, code) in [("esc", Keys.escape), ("tab", Keys.tab)] {
            first.append(key(title: title) { [weak self] in self?.onKey(code) })
        }
        for (title, flag) in [("⌃", Keys.control), ("⌥", Keys.option), ("⌘", Keys.command), ("⇧", Keys.shift)] {
            let b = key(title: title) { [weak self] in self?.toggle(flag) }
            modifierButtons.append((flag, b))
            first.append(b)
        }
        for (symbol, code) in [("arrow.left", Keys.left), ("arrow.up", Keys.up), ("arrow.down", Keys.down), ("arrow.right", Keys.right)] {
            second.append(key(symbol: symbol) { [weak self] in self?.onKey(code) })
        }
        hide = key(symbol: "keyboard.chevron.compact.down") { [weak self] in self?.onHide() }
        collapse = key(symbol: "chevron.down") { [weak self] in self?.collapsed = true }
        collapse.accessibilityLabel = "Hide these keys"
        (first + second + [collapse]).forEach(scroll.addSubview)
        backdrop.contentView.addSubview(hide)
        var c = UIButton.Configuration.filled()
        c.image = UIImage(systemName: "chevron.compact.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        c.baseBackgroundColor = .tertiarySystemFill
        c.baseForegroundColor = .label
        c.cornerStyle = .small
        c.contentInsets = .zero
        expand = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.collapsed = false
        })
        expand.backgroundColor = .secondarySystemBackground
        expand.layer.cornerRadius = 6
        expand.clipsToBounds = true
        expand.accessibilityLabel = "Show esc, tab, modifier and arrow keys"
        addSubview(expand)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        if folded { return CGSize(width: UIView.noIntrinsicMetric, height: 20) }
        return CGSize(width: UIView.noIntrinsicMetric, height: Self.pad + (compact ? 2 * (Self.keyHeight + Self.pad) : Self.keyHeight + Self.pad) + 6)
    }

    /// Folded, only the tab takes touches: the rest of its width is the picture's.
    override func point(inside p: CGPoint, with event: UIEvent?) -> Bool {
        folded ? expand.frame.insetBy(dx: -8, dy: -6).contains(p) : super.point(inside: p, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.isHidden = folded
        expand.isHidden = !folded
        if folded { expand.frame = CGRect(x: bounds.midX - 32, y: bounds.maxY - 20, width: 64, height: 20); return }
        backdrop.frame = bounds
        let pad = Self.pad, h = Self.keyHeight, w = { (b: UIButton) in max(44, b.intrinsicContentSize.width) }
        if compact {   // a grid as wide as the keyboard: six keys, then the arrows and hide
            scroll.frame = backdrop.bounds
            scroll.contentSize = scroll.bounds.size
            let inner = bounds.insetBy(dx: pad, dy: pad + 3)
            collapse.isHidden = false
            for (row, keys) in ([first, second + [collapse, hide]] as [[UIButton]]).enumerated() {
                let kw = (inner.width - pad * CGFloat(keys.count - 1)) / CGFloat(keys.count)
                for (i, b) in keys.enumerated() {
                    if b === hide, hide.superview !== scroll { scroll.addSubview(hide) }
                    b.frame = CGRect(x: inner.minX + CGFloat(i) * (kw + pad), y: inner.minY + CGFloat(row) * (h + pad), width: kw, height: h)
                }
            }
        } else {   // one row, scrolling if it's too long; hide stays at the end
            if hide.superview !== backdrop.contentView { backdrop.contentView.addSubview(hide) }
            collapse.isHidden = true   // a docked keyboard's one row: nothing to fold
            let y = (bounds.height - h) / 2
            hide.frame = CGRect(x: bounds.maxX - safeAreaInsets.right - pad - w(hide), y: y, width: w(hide), height: h)
            scroll.frame = CGRect(x: safeAreaInsets.left + pad, y: 0, width: max(0, hide.frame.minX - pad - safeAreaInsets.left - pad), height: bounds.height)
            var x: CGFloat = 0
            for b in first + second {
                b.frame = CGRect(x: x, y: y, width: w(b), height: h)
                x += w(b) + pad
            }
            scroll.contentSize = CGSize(width: max(0, x - pad), height: bounds.height)
        }
    }

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
        c.titleLineBreakMode = .byClipping
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
