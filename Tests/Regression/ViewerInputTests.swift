import Foundation
import Shared

/// An iPad's hardware keyboard reaches the host as the Mac keys at the same positions, with the flags a Mac keyboard
/// would add, and its modifiers as modifiers.
func testKeymap() throws {
    // a s d, 1 0, return escape delete tab space, ← → ↓ ↑
    let hid = [0x04, 0x16, 0x07, 0x1E, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x50, 0x4F, 0x51, 0x52]
    try expectEqual(hid.compactMap(Keymap.macKey(hid:)), [0x00, 0x01, 0x02, 0x12, 0x1D, 0x24, 0x35, 0x33, 0x30, 0x31, 0x7B, 0x7C, 0x7D, 0x7E])
    try expectEqual(Keymap.macKey(hid: 0x35), 0x32)   // ` beside 1
    try expectEqual(Keymap.macKey(hid: 0x64), 0x0A)   // ISO § beside left shift
    try expectNil(Keymap.macKey(hid: 0x66))           // power: not a key a Mac keyboard sends
    // every Mac key appears once, apart from \ (also the ISO # in its place), help (also insert) and F13…F15 (also
    // print screen, scroll lock and pause, where a PC keyboard has them)
    let codes = (0..<256).compactMap(Keymap.macKey(hid:))
    try expectEqual(Dictionary(grouping: codes) { $0 }.filter { $0.value.count > 1 }.keys.sorted(), [0x2A, 0x69, 0x6B, 0x71, 0x72])

    // ⌃ ⇧ ⌥ ⌘ on both sides
    try expectEqual([0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7].map { Keymap.modifierFlag(Keymap.macKey(hid: $0)!) },
                    [Keymap.control, Keymap.shift, Keymap.option, Keymap.command, Keymap.control, Keymap.shift, Keymap.option, Keymap.command])
    try expectEqual(Keymap.modifierFlag(Keymap.macKey(hid: 0x39)!), Keymap.capsLock)
    try expectNil(Keymap.modifierFlag(0x00))
    try expectEqual(Keymap.implicitFlags(0x7E), Keymap.numericPad | Keymap.function)   // ↑
    try expectEqual(Keymap.implicitFlags(0x75), Keymap.function)                         // forward delete
    try expectEqual(Keymap.implicitFlags(0x4C), Keymap.numericPad)                       // keypad enter
    try expectEqual(Keymap.implicitFlags(0x00), 0)
}

/// Zooming a Desktop around a point keeps what's under it in place, and clicks land where they look like they land.
func testDesktopZoom() throws {
    let view = CGSize(width: 1000, height: 600), screen = CGSize(width: 2000, height: 1000)
    let fit = pictureRect(view: view, remote: screen, zoom: nil, pan: .zero).rect
    try expectEqual(fit, CGRect(x: 0, y: 50, width: 1000, height: 500))   // half size, letterboxed
    let anchor = CGPoint(x: 700, y: 200), spot = remotePoint(anchor, in: fit, remote: screen)
    try expectEqual(spot, CGPoint(x: 1400, y: 300))
    // 1:1 around that point: it stays under the fingers
    let one = pictureRect(view: view, remote: screen, zoom: 1, pan: pan(keeping: spot, at: anchor, zoom: 1))
    try expectEqual(remotePoint(anchor, in: one.rect, remote: screen), spot)
    // with the picture drawn 120 pt higher for the on-screen keyboard, zooming around a spot still keeps it under
    // the fingers, as input (which maps through the lifted picture) sees it
    let lift: CGFloat = 120, lifted = fit.offsetBy(dx: 0, dy: -lift), under = remotePoint(anchor, in: lifted, remote: screen)
    let zoomed = pictureRect(view: view, remote: screen, zoom: 1.5, pan: pan(keeping: under, at: anchor, zoom: 1.5, lift: lift))
    try expectEqual(remotePoint(anchor, in: zoomed.rect.offsetBy(dx: 0, dy: -lift), remote: screen), under)
    // …which ignoring the lift would miss by the lift itself
    let naive = pictureRect(view: view, remote: screen, zoom: 1.5, pan: pan(keeping: under, at: anchor, zoom: 1.5))
    try expectEqual(remotePoint(anchor, in: naive.rect.offsetBy(dx: 0, dy: -lift), remote: screen).y, under.y + lift / 1.5)
    // near an edge the picture stops at the edge instead of showing black beyond it
    let corner = pictureRect(view: view, remote: screen, zoom: 1, pan: pan(keeping: CGPoint(x: 1990, y: 990), at: CGPoint(x: 100, y: 100), zoom: 1))
    try expectEqual(corner.rect, CGRect(x: -1000, y: -400, width: 2000, height: 1000))
    // an Adaptive Desktop smaller than the view stays pixel for pixel, centered
    let small = pictureRect(view: view, remote: CGSize(width: 800, height: 500), zoom: nil, pan: .zero, maxFit: 1).rect
    try expectEqual(small, CGRect(x: 100, y: 50, width: 800, height: 500))
}

/// What an iPad offers from its clipboard: the best representations first, each type once, within the limit.
func testClipChoosing() throws {
    let text = Data("hi".utf8), big = Data(count: Clip.limit - 1), png = Data([1, 2, 3])
    let c = Clip(choosing: [("public.utf8-plain-text", text), ("public.utf8-plain-text", Data("again".utf8)),
                            ("public.rtf", Data()), ("public.png", big), ("public.jpeg", png)])
    try expectEqual(c.parts.map(\.type), ["public.utf8-plain-text", "public.jpeg"])   // empty RTF skipped, PNG too big
    try expectTrue(c.size <= Clip.limit)
    try expectTrue(Clip(choosing: []).parts.isEmpty)
}
