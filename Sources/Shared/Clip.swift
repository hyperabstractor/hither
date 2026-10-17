import Foundation
#if os(macOS)
import AppKit
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
