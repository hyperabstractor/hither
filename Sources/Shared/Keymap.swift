import Foundation

/// A hardware keyboard on an iPad reports USB HID usages (keyboard page 7); the host posts Mac virtual key codes
/// (kVK_*). Both name a key by its position, not its character, so like a Mac viewer the two ends should share a layout.
public enum Keymap {
    /// CGEventFlags bits, the same as NSEvent's and UIKeyModifierFlags'.
    public static let capsLock: UInt64 = 1 << 16, shift: UInt64 = 1 << 17, control: UInt64 = 1 << 18
    public static let option: UInt64 = 1 << 19, command: UInt64 = 1 << 20, numericPad: UInt64 = 1 << 21, function: UInt64 = 1 << 23

    /// Mac key codes for the shortcuts sent on their own.
    public static let leftCommand = 0x37, tab = 0x30

    /// A shortcut exactly as given (⌘⇥: `tab`, [`leftCommand`]), as the key and flags messages a Mac keyboard would
    /// send for it: modifiers down, the key down and up with only those flags (and what a Mac keyboard adds to that
    /// key; caps lock, a toggle, as it is), modifiers up. Modifiers `held` on a hardware keyboard are let go of
    /// first and pressed again after, so they don't join in and the Mac is left as that keyboard is.
    public static func shortcut(_ key: Int, modifiers: [Int], held: [Int] = [], capsLock: Bool = false) -> [Msg] {
        var out: [Msg] = []
        var f = held.reduce(capsLock ? Self.capsLock : 0) { $0 | (modifierFlag($1) ?? 0) }
        func flags(_ k: Int, _ change: (inout UInt64, UInt64) -> Void) {
            change(&f, modifierFlag(k) ?? 0)
            var m = Msg("flags"); m.k = k; m.f = f
            out.append(m)
        }
        let down = { (f: inout UInt64, flag: UInt64) in f |= flag }, up = { (f: inout UInt64, flag: UInt64) in f &= ~flag }
        held.reversed().forEach { flags($0, up) }
        modifiers.forEach { flags($0, down) }
        for pressed in [true, false] {
            var m = Msg("key"); m.k = key; m.down = pressed; m.f = f | implicitFlags(key)
            out.append(m)
        }
        modifiers.reversed().forEach { flags($0, up) }
        held.forEach { flags($0, down) }
        return out
    }

    /// The Mac's app switcher, kept up from a button, as ⌘ held and Tab tapped at the Mac: the first `next()` holds ⌘
    /// and presses Tab (the switcher shows, on the app used before), each one after presses Tab again (the next app),
    /// and `close()` lets go of ⌘, which switches to the app picked. Modifiers held on a hardware keyboard are let go
    /// of while it's up, as for a shortcut, and pressed again after.
    public struct AppSwitcher {
        public private(set) var isOpen = false
        private var held: [Int] = [], caps = false
        public init() {}

        public mutating func next(held: [Int] = [], capsLock: Bool = false) -> [Msg] {
            var out: [Msg] = []
            if !isOpen {
                isOpen = true; self.held = held; caps = capsLock
                let open = Keymap.shortcut(tab, modifiers: [leftCommand], held: held, capsLock: capsLock)
                out = Array(open.prefix(held.count + 1))   // held ones up, ⌘ down
            }
            let f = (caps ? Keymap.capsLock : 0) | Keymap.command
            for pressed in [true, false] { var m = Msg("key"); m.k = tab; m.down = pressed; m.f = f; out.append(m) }
            return out
        }

        public mutating func close() -> [Msg] {
            guard isOpen else { return [] }
            isOpen = false
            return Array(Keymap.shortcut(tab, modifiers: [leftCommand], held: held, capsLock: caps).suffix(held.count + 1))   // ⌘ up, held ones down
        }
    }

    /// HID usage → Mac key code.
    static let table: [Int: Int] = [
        // letters a…z
        0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x07: 0x02, 0x08: 0x0E, 0x09: 0x03, 0x0A: 0x05, 0x0B: 0x04, 0x0C: 0x22,
        0x0D: 0x26, 0x0E: 0x28, 0x0F: 0x25, 0x10: 0x2E, 0x11: 0x2D, 0x12: 0x1F, 0x13: 0x23, 0x14: 0x0C, 0x15: 0x0F,
        0x16: 0x01, 0x17: 0x11, 0x18: 0x20, 0x19: 0x09, 0x1A: 0x0D, 0x1B: 0x07, 0x1C: 0x10, 0x1D: 0x06,
        // 1…9, 0
        0x1E: 0x12, 0x1F: 0x13, 0x20: 0x14, 0x21: 0x15, 0x22: 0x17, 0x23: 0x16, 0x24: 0x1A, 0x25: 0x1C, 0x26: 0x19, 0x27: 0x1D,
        // return, escape, delete, tab, space, - = [ ] \ (ISO #) ; ' ` , . / caps lock
        0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31, 0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E,
        0x31: 0x2A, 0x32: 0x2A, 0x33: 0x29, 0x34: 0x27, 0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C, 0x39: 0x39,
        // F1…F12
        0x3A: 0x7A, 0x3B: 0x78, 0x3C: 0x63, 0x3D: 0x76, 0x3E: 0x60, 0x3F: 0x61, 0x40: 0x62, 0x41: 0x64, 0x42: 0x65,
        0x43: 0x6D, 0x44: 0x67, 0x45: 0x6F,
        // print screen, scroll lock, pause (F13…F15 on a Mac keyboard), insert (help), home, page up, forward delete,
        // end, page down, → ← ↓ ↑
        0x46: 0x69, 0x47: 0x6B, 0x48: 0x71, 0x49: 0x72, 0x4A: 0x73, 0x4B: 0x74, 0x4C: 0x75, 0x4D: 0x77, 0x4E: 0x79,
        0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,
        // keypad: clear / * - + enter 1…9 0 . =
        0x53: 0x47, 0x54: 0x4B, 0x55: 0x43, 0x56: 0x4E, 0x57: 0x45, 0x58: 0x4C, 0x59: 0x53, 0x5A: 0x54, 0x5B: 0x55,
        0x5C: 0x56, 0x5D: 0x57, 0x5E: 0x58, 0x5F: 0x59, 0x60: 0x5B, 0x61: 0x5C, 0x62: 0x52, 0x63: 0x41, 0x67: 0x51,
        // ISO § (left of 1), context menu, F13…F20, help, mute, volume up/down
        0x64: 0x0A, 0x65: 0x6E, 0x68: 0x69, 0x69: 0x6B, 0x6A: 0x71, 0x6B: 0x6A, 0x6C: 0x40, 0x6D: 0x4F, 0x6E: 0x50,
        0x6F: 0x5A, 0x75: 0x72, 0x7F: 0x4A, 0x80: 0x48, 0x81: 0x49,
        // JIS: keypad comma, ろ, ¥, かな, 英数
        0x85: 0x5F, 0x87: 0x5E, 0x89: 0x5D, 0x90: 0x68, 0x91: 0x66,
        // left ⌃ ⇧ ⌥ ⌘, right ⌃ ⇧ ⌥ ⌘
        0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37, 0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x36,
    ]

    /// The Mac key at the position of HID usage `hid`, or nil for a key a Mac keyboard doesn't have.
    public static func macKey(hid: Int) -> Int? { table[hid] }

    /// The modifier flag a Mac modifier key holds down (caps lock: its own, toggled), or nil for any other key.
    public static func modifierFlag(_ mac: Int) -> UInt64? {
        switch mac {
        case 0x38, 0x3C: shift
        case 0x3B, 0x3E: control
        case 0x3A, 0x3D: option
        case 0x37, 0x36: command
        case 0x39: capsLock
        default: nil
        }
    }

    /// Flags a Mac keyboard adds by itself for key `mac`: arrows count as keypad and fn keys, the navigation keys and
    /// F-keys as fn keys, the keypad as keypad. Some apps look at these (arrows in text fields, for one).
    public static func implicitFlags(_ mac: Int) -> UInt64 {
        switch mac {
        case 0x7B...0x7E: numericPad | function
        case 0x72, 0x73, 0x74, 0x75, 0x77, 0x79, 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
             0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A: function
        case 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51, 0x52...0x59, 0x5B, 0x5C: numericPad
        default: 0
        }
    }
}
