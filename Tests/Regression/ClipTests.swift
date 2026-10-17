import AppKit
import Shared

/// A clipboard survives the wire, a truncated frame is refused, and a big TIFF goes as PNG within the limit.
func testClip() throws {
    let text = Data("héllo".utf8), rtf = Data("{\\rtf1 hi}".utf8)
    let c = Clip([("public.utf8-plain-text", text), ("public.rtf", rtf)])
    let back = try Clip(decoding: c.encoded()).orThrow("clip didn't decode")
    try expectEqual(back.parts.map(\.type), ["public.utf8-plain-text", "public.rtf"])
    try expectEqual(back.parts.map(\.data), [text, rtf])
    try expectFalse(back.files)
    try expectTrue(try Clip(decoding: Clip(files: true).encoded()).orThrow("files didn't decode").files)
    try expectNil(Clip(decoding: c.encoded().dropLast()))
    try expectNil(Clip(decoding: Data([0])))
    try expectEqual(c.summary, "text (16 bytes)")

    // a private pasteboard: the general one is the user's
    let pb = NSPasteboard(name: NSPasteboard.Name("dev.hither.tests.\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    let image = NSImage(size: NSSize(width: 2000, height: 1500), flipped: false) { r in NSColor.systemTeal.setFill(); r.fill(); return true }
    pb.clearContents()
    pb.setData(try image.tiffRepresentation.orThrow("no tiff"), forType: .tiff)
    let read = Clip.read(pb)
    try expectEqual(read.parts.map(\.type), ["public.png"])
    try expectTrue(read.size <= Clip.limit)
    try expectTrue(read.summary.hasPrefix("image"))

    let copy = NSPasteboard(name: NSPasteboard.Name("dev.hither.tests.\(UUID().uuidString)"))
    defer { copy.releaseGlobally() }
    c.write(copy)
    try expectEqual(copy.string(forType: .string), "héllo")
    Clip().write(copy)   // nothing to put: left alone
    try expectEqual(copy.string(forType: .string), "héllo")

    pb.clearContents()
    pb.writeObjects([URL(fileURLWithPath: "/tmp") as NSURL])
    let files = Clip.read(pb)
    try expectTrue(files.files)
    try expectTrue(files.parts.isEmpty)
}

extension Optional {
    func orThrow(_ why: String) throws -> Wrapped {
        guard let v = self else { throw RegressionFailure(message: why) }
        return v
    }
}
