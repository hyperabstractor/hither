import Foundation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
import UniformTypeIdentifiers
#endif

/// Clipboard contents on the wire (a kind-4 frame), moved only when the user asks: Send Clipboard puts this Mac's
/// clipboard on the other one, Get Clipboard the other way round. Nothing is synced in the background.
/// Encoding: [flags u8][count u8] then per type [name len u16][name][data len u32][data]. Flag 1 = it held files,
/// which aren't carried (yet).
public struct Clip {
    public var parts: [(type: String, data: Data)]
    public var files = false
    public init(_ parts: [(type: String, data: Data)] = [], files: Bool = false) { self.parts = parts; self.files = files }

    /// Most a clipboard may carry: the video shares the connection, and a big image would stall it.
    public static let limit = 8 << 20

    public var size: Int { parts.reduce(0) { $0 + $1.data.count } }

    /// The representations on offer, best first: each type once, and any that would take the clipboard past `limit`
    /// left out (a smaller one later on can still go).
    public init(choosing offered: [(type: String, data: Data)]) {
        self.init()
        for o in offered where !o.data.isEmpty && !parts.contains(where: { $0.type == o.type }) && size + o.data.count <= Clip.limit {
            parts.append(o)
        }
    }

    public func encoded() -> Data {
        var d = Data()
        d.put(UInt8(files ? 1 : 0)); d.put(UInt8(parts.count))
        for p in parts {
            let name = Data(p.type.utf8)
            d.put(UInt16(name.count)); d.append(name)
            d.put(UInt32(p.data.count)); d.append(p.data)
        }
        return d
    }

    public init?(decoding d: Data) {
        var r = Reader(d), parts: [(String, Data)] = []
        func left() -> Int { d.endIndex - r.i }
        guard left() >= 2 else { return nil }
        let flags = r.u8(), n = Int(r.u8())
        for _ in 0..<n {
            guard left() >= 2 else { return nil }
            let nameLen = Int(r.u16())
            guard left() >= nameLen + 4 else { return nil }
            let name = String(decoding: r.bytes(nameLen), as: UTF8.self)
            let len = Int(r.u32())
            guard left() >= len else { return nil }
            parts.append((name, Data(r.bytes(len))))
        }
        self.init(parts, files: flags & 1 != 0)
    }

    /// "text (2.1 KB)", "image (340 KB)": what a status line says was moved.
    public var summary: String {
        let images = ["public.png", "public.tiff", "public.jpeg", "com.adobe.pdf"]
        let kind = parts.contains { images.contains($0.type) } && !parts.contains { $0.type == "public.utf8-plain-text" } ? "image" : "text"
        return "\(kind) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
    }
}

#if os(macOS)
public extension Clip {
    /// What's carried, best first; a part that would go past `limit` is left out.
    static let types: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .png, .pdf, .rtfd, .tiff]

    /// The first item on `pb`. A TIFF with no PNG (screenshots, Preview) goes as PNG instead, often a tenth the size.
    static func read(_ pb: NSPasteboard = .general) -> Clip {
        guard let item = pb.pasteboardItems?.first else { return Clip() }
        if item.types.contains(.fileURL) { return Clip(files: true) }   // a Finder copy: its name and icon aren't the point
        var found: [NSPasteboard.PasteboardType: Data] = [:]
        for t in types { found[t] = item.data(forType: t) }
        if found[.png] == nil, let tiff = found[.tiff], let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            found[.png] = png
            found[.tiff] = nil
        }
        var c = Clip()
        for t in types {
            guard let d = found[t], c.size + d.count <= limit else { continue }
            c.parts.append((t.rawValue, d))
        }
        return c
    }

    /// Replace `pb`'s contents with this clipboard (nothing to put: leave it be).
    func write(_ pb: NSPasteboard = .general) {
        guard !parts.isEmpty else { return }
        let item = NSPasteboardItem()
        for p in parts { item.setData(p.data, forType: NSPasteboard.PasteboardType(p.type)) }
        pb.clearContents()
        pb.writeObjects([item])
    }
}
#endif

#if canImport(UIKit) && !os(macOS)
public extension Clip {
    static let plainText = "public.utf8-plain-text", png = "public.png", jpeg = "public.jpeg"
    /// Carried as they are, after the text and before any image: the types a Mac's clipboard takes back.
    static let richTypes = ["public.rtf", "public.html", "com.apple.flat-rtfd", "com.adobe.pdf"]

    /// The first item on `pb`: its text, rich text, and an image as PNG (as JPEG when PNG would be too big). One
    /// read of the pasteboard, so iOS asks at most once whether Hither may paste.
    static func read(_ pb: UIPasteboard = .general) -> Clip {
        guard let item = pb.items.first, !item.isEmpty else { return Clip() }
        func data(_ v: Any) -> Data? {
            switch v {
            case let d as Data: d
            case let s as String: Data(s.utf8)
            case let u as URL: Data(u.absoluteString.utf8)
            case let a as NSAttributedString: Data(a.string.utf8)
            default: nil
            }
        }
        var offered: [(type: String, data: Data)] = []
        let textTypes = [plainText, "public.plain-text", "public.text", "public.url"]
        if let t = textTypes.first(where: { item[$0] != nil }), let d = data(item[t]!) { offered.append((plainText, d)) }
        for t in richTypes { if let v = item[t], let d = data(v) { offered.append((t, d)) } }
        // an image: PNG as is; any other kind (JPEG, HEIC, a UIImage) made PNG, or JPEG if that's too big
        if let v = item[png] as? Data {
            offered.append((png, v))
        } else if let (_, v) = item.first(where: { UTType($0.key)?.conforms(to: .image) == true }) {
            let image = (v as? UIImage) ?? (v as? Data).flatMap(UIImage.init(data:))
            if let p = image?.pngData(), p.count <= limit { offered.append((png, p)) }
            else if let j = image?.jpegData(compressionQuality: 0.9) { offered.append((jpeg, j)) }
        }
        return Clip(choosing: offered)
    }

    /// Replace `pb`'s contents with this clipboard (nothing to put: leave it be). Text goes as a string, so every
    /// app can paste it; a TIFF as PNG, which iOS apps read.
    func write(_ pb: UIPasteboard = .general) {
        guard !parts.isEmpty else { return }
        var item: [String: Any] = [:]
        for p in parts {
            if p.type == Clip.plainText { item[p.type] = String(decoding: p.data, as: UTF8.self) }
            else if p.type == "public.tiff", item[Clip.png] == nil, let png = UIImage(data: p.data)?.pngData() { item[Clip.png] = png }
            else { item[p.type] = p.data }
        }
        pb.setItems([item])
    }
}
#endif
