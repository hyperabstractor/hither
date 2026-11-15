import CoreGraphics
import Foundation

/// The edit menu the iPhone and iPad viewer shows over the picture, where iPadOS would show its own over text: after
/// a touch that likely selected something (touch and hold then drag, a double or triple tap) Cut, Copy and Paste;
/// after a touch and hold in one place (a click there: the cursor's) Paste, Select and Select All. The viewer sees a
/// picture, not what's selected on the Mac, so the menu goes by the touch alone, and each item is what a Mac
/// keyboard would do: ⌘X ⌘C ⌘V ⌘A, and for Select a double click on the spot.
public enum EditMenu {
    public enum Item: Equatable {
        case cut, copy, paste, select, selectAll

        public var title: String {
            switch self {
            case .cut: "Cut"
            case .copy: "Copy"
            case .paste: "Paste"
            case .select: "Select"
            case .selectAll: "Select All"
            }
        }

        /// The Mac key that does it with ⌘ (nil: Select, a double click where the menu is).
        public var key: Int? {
            switch self {
            case .cut: 0x07
            case .copy: 0x08
            case .paste: 0x09
            case .selectAll: 0x00
            case .select: nil
            }
        }

        /// The menu that follows it, on the same spot: selecting leaves something to cut or copy.
        public var next: Context? {
            switch self {
            case .select: .selection
            case .selectAll: .everything
            default: nil
            }
        }
    }

    /// What the touch before it likely left on the Mac: a cursor, a selection, or everything selected.
    public enum Context: Equatable { case cursor, selection, everything }

    public static func items(_ c: Context) -> [Item] {
        switch c {
        case .cursor: [.paste, .select, .selectAll]
        case .selection: [.cut, .copy, .paste, .selectAll]
        case .everything: [.cut, .copy, .paste]
        }
    }

    /// A touch and hold that ended at `to`, having started at `from`: moved, it was a drag (a selection, likely);
    /// let go of in place, a click.
    public static func afterHold(from: CGPoint, to: CGPoint) -> Context {
        hypot(to.x - from.x, to.y - from.y) > 10 ? .selection : .cursor
    }

    /// What the menu keeps clear of: the line of text touched at `a` (a finger lands mid-line), through to `b` for
    /// a drag. The menu goes above it, or below when there's no room.
    public static func target(_ a: CGPoint, _ b: CGPoint? = nil) -> CGRect {
        let b = b ?? a
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -8, dy: -14)
    }
}
