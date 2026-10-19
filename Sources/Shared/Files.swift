import Foundation
#if os(macOS)
import AppKit
#endif

// Copied Finder files, carried by Send/Get Clipboard on a connection of their own, so a big file never holds up
// input or video on the window's connection. Any size: files stream from disk in 1 MiB chunks, never whole in memory.
// Sender → receiver: "files" (the list), then each regular file's bytes in order as kind-5 frames, then "filesend".
// The receiver builds everything in a hidden folder in ~/Downloads, moves it into Downloads when complete, puts the
// files on its clipboard (so Finder's Paste puts them anywhere), and answers "filesgot" or "fileserr".
// Get Clipboard: the viewer opens the connection and sends "filesget"; the host sends as above.

/// One item of a "files" list: a path inside the copy ("Photos/2024/a.jpg"), with its size, or a folder.
public struct FileEntry: Codable, Equatable {
    public var path: String, size: UInt64, dir: Bool
    public var mode: Int?, mtime: Double?   // permissions (keeps scripts executable) and modification date
    public init(path: String, size: UInt64 = 0, dir: Bool = false, mode: Int? = nil, mtime: Double? = nil) {
        self.path = path; self.size = size; self.dir = dir; self.mode = mode; self.mtime = mtime
    }
}

public struct FileError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Files {
    public static let chunk = 1 << 20
    static let inFlight = 8   // chunks handed to the connection and not yet sent: ~8 MiB covers a 300 ms link at 200 Mbps

    /// What `urls` hold, folders walked (symlinks and special files skipped), and the files to read, in list order.
    public static func list(_ urls: [URL]) throws -> (entries: [FileEntry], sources: [URL]) {
        var entries: [FileEntry] = [], sources: [URL] = []
        let fm = FileManager.default
        func add(_ url: URL, as path: String) throws {
            let a = try fm.attributesOfItem(atPath: url.path)
            let mode = (a[.posixPermissions] as? NSNumber)?.intValue
            let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970
            switch a[.type] as? FileAttributeType {
            case .typeDirectory?:
                entries.append(FileEntry(path: path, dir: true, mode: mode, mtime: mtime))
                for name in try fm.contentsOfDirectory(atPath: url.path).sorted() {
                    try add(url.appending(path: name), as: path + "/" + name)
                }
            case .typeRegular?:
                entries.append(FileEntry(path: path, size: (a[.size] as? NSNumber)?.uint64Value ?? 0, mode: mode, mtime: mtime))
                sources.append(url)
            default: break
            }
        }
        for u in urls { try add(u, as: u.lastPathComponent) }
        guard !entries.isEmpty else { throw FileError("Nothing to copy (only links or special files)") }
        return (entries, sources)
    }

    /// "report.pdf (12 MB)", "Photos (1.2 GB)", "3 items (40 MB)": what a status line says was moved.
    public static func summary(_ entries: [FileEntry]) -> String {
        let top = entries.filter { !$0.path.contains("/") }
        let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: total(entries)), countStyle: .file)
        return top.count == 1 ? "\(top[0].path) (\(size))" : "\(top.count) items (\(size))"
    }

    public static func total(_ entries: [FileEntry]) -> UInt64 { entries.reduce(0) { $0 + $1.size } }

    /// Sends `urls` over `wire`, which is just for this (the caller closes it once the other end answers). Runs on a
    /// thread of its own; `progress` gets bytes sent so far. A send that fails says why with "fileserr".
    public static func send(_ urls: [URL], over wire: Wire, progress: @escaping (UInt64, UInt64) -> Void = { _, _ in }) {
        Thread.detachNewThread {
            do {
                let (entries, sources) = try list(urls)
                var m = Msg("files"); m.files = entries
                wire.send(m)
                let total = total(entries), room = DispatchSemaphore(value: 0)
                for _ in 0..<inFlight { room.signal() }   // not value: inFlight, which traps if freed while below it
                var sent: UInt64 = 0, failed = false
                let lock = NSLock()
                for (url, entry) in zip(sources, entries.filter { !$0.dir }) {
                    let h = try FileHandle(forReadingFrom: url)
                    defer { try? h.close() }
                    var left = entry.size
                    while left > 0 {
                        room.wait()
                        if lock.withLock({ failed }) { throw FileError("Connection lost") }
                        guard let d = try h.read(upToCount: Int(min(UInt64(chunk), left))), !d.isEmpty else {
                            throw FileError("\(url.lastPathComponent) got shorter while it was being sent")
                        }
                        left -= UInt64(d.count)
                        wire.sendFileData(d) { ok in
                            if !ok { lock.withLock { failed = true } }
                            room.signal()
                        }
                        sent += UInt64(d.count)
                        progress(sent, total)
                    }
                }
                for _ in 0..<inFlight { room.wait() }   // all handed over (or failed)
                if lock.withLock({ failed }) { throw FileError("Connection lost") }
                wire.send(Msg("filesend"))
            } catch {
                var e = Msg("fileserr"); e.text = error.localizedDescription
                wire.send(e)
            }
        }
    }
}

/// The receiving end of one transfer: takes the "files" list, the data frames and "filesend", in that order.
public final class FileInbox {
    public let entries: [FileEntry]
    let dest: URL, staging: URL
    var index = -1, left: UInt64 = 0, handle: FileHandle?
    public private(set) var received: UInt64 = 0
    public var total: UInt64 { Files.total(entries) }

    /// Checks every path and that `dest` has room, and makes the folders and (empty) files in a hidden staging
    /// folder inside it.
    public init(_ entries: [FileEntry], into dest: URL) throws {
        for e in entries {
            let parts = e.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !e.path.hasPrefix("/"), !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                throw FileError("Refused a file named \"\(e.path)\"")
            }
        }
        self.entries = entries
        self.dest = dest
        staging = dest.appending(path: ".hither-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let free = (try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        if Int64(clamping: Files.total(entries)) > free {
            let f = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            throw FileError("Not enough space: needs \(f(Int64(clamping: Files.total(entries)))), \(f(free)) free")
        }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for e in entries {
                let u = staging.appending(path: e.path)
                if e.dir { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
                else {
                    try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard fm.createFile(atPath: u.path, contents: nil) else { throw FileError("Couldn't create \(e.path)") }
                }
            }
            try advance()
        } catch { abort(); throw error }
    }

    /// The next file that still wants bytes.
    func advance() throws {
        try handle?.close()
        handle = nil
        while left == 0 {
            index += 1
            guard index < entries.count else { return }
            let e = entries[index]
            if e.dir || e.size == 0 { continue }
            handle = try FileHandle(forWritingTo: staging.appending(path: e.path))
            left = e.size
        }
    }

    public func take(_ d: Data) throws {
        var d = d[...]
        while !d.isEmpty {
            guard let h = handle, left > 0 else { throw FileError("More data than the files hold") }
            let n = Int(min(UInt64(d.count), left))
            try h.write(contentsOf: d.prefix(n))
            d = d.dropFirst(n)
            left -= UInt64(n)
            received += UInt64(n)
            if left == 0 { try advance() }
        }
    }

    /// All bytes in: dates and permissions set, the top-level items moved into `dest` (renamed "a 2.txt" if taken).
    /// Returns where they ended up.
    public func finish() throws -> [URL] {
        guard received == total, handle == nil else { abort(); throw FileError("The copy ended early") }
        let fm = FileManager.default
        for e in entries.reversed() {   // children before their folder: writing into a folder changes its date
            let u = staging.appending(path: e.path)
            var a: [FileAttributeKey: Any] = [:]
            if let m = e.mode { a[.posixPermissions] = m & 0o7777 }
            if let t = e.mtime { a[.modificationDate] = Date(timeIntervalSince1970: t) }
            if !a.isEmpty { try? fm.setAttributes(a, ofItemAtPath: u.path) }
        }
        var out: [URL] = []
        for e in entries where !e.path.contains("/") {
            let to = Self.free(e.path, in: dest)
            try fm.moveItem(at: staging.appending(path: e.path), to: to)
            out.append(to)
        }
        try? fm.removeItem(at: staging)
        return out
    }

    public func abort() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: staging)
    }

    /// `name` in `dir`, or "name 2.ext", "name 3.ext"… if it's taken (as Finder does).
    public static func free(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default, base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var u = dir.appending(path: name), n = 2
        while fm.fileExists(atPath: u.path) {
            u = dir.appending(path: "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        return u
    }
}

#if os(macOS)
public extension Files {
    /// Where received files go: Downloads, as with AirDrop.
    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    /// The files copied in Finder, if that's what's on the clipboard.
    static func onClipboard(_ pb: NSPasteboard = .general) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Puts `urls` on the clipboard as files: Finder's Paste copies them wherever you are.
    static func putOnClipboard(_ urls: [URL], _ pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }
}
#endif
