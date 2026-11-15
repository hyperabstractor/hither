import CoreGraphics
import Foundation

/// The strip of Mac shortcuts along the bottom of an iPhone that's another device's keyboard (the iOS app's
/// KeyboardScreen): four keys to a page, swiped sideways for the next four, so it holds as many as there are without
/// a key getting smaller. Each is the Mac's own shortcut, by key position, as from a keyboard there.
public enum ShortcutStrip {
    public struct Key: Equatable {
        /// What the key shows: a title (two short lines at most), an SF Symbol, or the symbol with the title small
        /// under it.
        public let title: String?, symbol: String?
        public let label: String
        public let code: Int, flags: UInt64
        /// Touched and held instead: this key code, with the same modifiers (Screenshot: the whole screen).
        public let heldCode: Int?

        init(_ title: String?, symbol: String? = nil, _ label: String, _ code: Int, _ flags: UInt64 = Keymap.command, held: Int? = nil) {
            self.title = title; self.symbol = symbol; self.label = label; self.code = code; self.flags = flags; heldCode = held
        }
    }

    public static let perPage = 4

    public static let keys: [Key] = [
        // ⌘X ⌘C ⌘V ⌘Z
        Key("Cut", "Cut", 0x07), Key("Copy", "Copy", 0x08), Key("Paste", "Paste", 0x09), Key("Undo", "Undo", 0x06),
        // ⇧⌘Z ⌘A ⌘F ⌘S
        Key("Redo", "Redo", 0x06, Keymap.command | Keymap.shift), Key("Select\nAll", "Select All", 0x00),
        Key("Find", "Find", 0x03), Key("Save", "Save", 0x01),
        // ⇧⌘4 (an area, saved; held, ⇧⌘3: the whole screen), the same with ⌃ (copied to the Mac's clipboard
        // instead), ⌘Space, ⌘W
        Key("Save", symbol: "camera.viewfinder", "Screenshot to a file: drag an area. Touch and hold for the whole screen",
            0x15, Keymap.command | Keymap.shift, held: 0x14),
        Key("Copy", symbol: "camera.viewfinder", "Screenshot to the clipboard: drag an area. Touch and hold for the whole screen",
            0x15, Keymap.command | Keymap.shift | Keymap.control, held: 0x14),
        Key(nil, symbol: "magnifyingglass", "Spotlight", 0x31), Key("Close", "Close window or tab", 0x0D),
        // ⌘`
        Key("⌘`", "Next window of the same app", 0x32),
    ]

    /// Where the keys go in a strip `width` wide, and where it comes to rest: on a page, four keys and `peek` of the
    /// next one showing, so it's plain there are more. The last page, full or not, rests with the last key a gap
    /// from the end.
    public struct Layout {
        public let width: CGFloat, gap: CGFloat, peek: CGFloat, count: Int

        public init(width: CGFloat, gap: CGFloat, peek: CGFloat = 18, count: Int = ShortcutStrip.keys.count) {
            self.width = width; self.gap = gap; self.peek = peek; self.count = count
        }

        public var keyWidth: CGFloat { max(0, (width - peek) / CGFloat(perPage) - gap) }
        public var stride: CGFloat { keyWidth + gap }
        public var contentWidth: CGFloat { max(0, CGFloat(count) * stride - gap) }
        public var pages: Int { (count + perPage - 1) / perPage }
        /// As far as it scrolls.
        public var end: CGFloat { max(0, contentWidth + gap - width) }

        public func x(ofKey i: Int) -> CGFloat { CGFloat(i) * stride }
        public func offset(page: Int) -> CGFloat { min(CGFloat(min(max(page, 0), pages - 1) * perPage) * stride, end) }

        /// The page a drag comes to rest on: let go at `offset` moving at `velocity` (points a millisecond, as a
        /// scroll view says), having begun on `page`. A flick goes one page on from there; a slow drag, the nearest.
        public func page(letGoAt offset: CGFloat, velocity: CGFloat, from page: Int) -> Int {
            if abs(velocity) > 0.3 { return min(max(page + (velocity > 0 ? 1 : -1), 0), pages - 1) }
            return (0..<pages).min { abs(self.offset(page: $0) - offset) < abs(self.offset(page: $1) - offset) } ?? 0
        }
    }
}
