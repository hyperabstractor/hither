/// Text typed on the Mac from a buffer the viewer's keyboard writes into (typing, dictation and its revisions): what
/// to send so the Mac's text goes from reading `old` to reading `new`. Delete presses take back what's after the part
/// both share, then the rest of `new` is typed. Counted in Characters, as a Mac's Delete removes one: an emoji, a
/// letter with its accents or a flag is one Delete. Plain typing (one character added) is just that character.
public struct TypingEdit: Equatable, Sendable, CustomStringConvertible {
    public var deletes: Int
    public var insert: String
    public init(deletes: Int, insert: String) {
        self.deletes = deletes
        self.insert = insert
    }
    public var isEmpty: Bool { deletes == 0 && insert.isEmpty }
    public var description: String { "(deletes: \(deletes), insert: \(insert.debugDescription))" }

    public init(from old: String, to new: String) {
        var o = old.startIndex, n = new.startIndex
        while o < old.endIndex, n < new.endIndex, old[o] == new[n] {
            old.formIndex(after: &o)
            new.formIndex(after: &n)
        }
        self.init(deletes: old[o...].count, insert: String(new[n...]))
    }
}
