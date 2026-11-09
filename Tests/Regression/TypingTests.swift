import Shared

/// The viewer's keyboard (typing, and dictation revising what it wrote) reaches the Mac as Deletes and text: just
/// enough Deletes to take back what changed, one per character as the Mac counts them.
func testTyping() throws {
    let edit = { (old: String, new: String) in TypingEdit(from: old, to: new) }
    // plain typing: one character more is that character, nothing deleted
    try expectEqual(edit("", "h"), TypingEdit(deletes: 0, insert: "h"))
    try expectEqual(edit("hell", "hello"), TypingEdit(deletes: 0, insert: "o"))
    try expectEqual(edit("hello", "hello world"), TypingEdit(deletes: 0, insert: " world"))
    // a revision mid-word takes back only what differs
    try expectEqual(edit("their", "they're"), TypingEdit(deletes: 2, insert: "y're"))
    try expectEqual(edit("I scream for", "ice cream for"), TypingEdit(deletes: 12, insert: "ice cream for"))
    try expectEqual(edit("send it to Mark", "send it to Mark."), TypingEdit(deletes: 0, insert: "."))
    // replaced outright
    try expectEqual(edit("cat", "dog"), TypingEdit(deletes: 3, insert: "dog"))
    // deleting
    try expectEqual(edit("hello", "hell"), TypingEdit(deletes: 1, insert: ""))
    try expectEqual(edit("hello", ""), TypingEdit(deletes: 5, insert: ""))
    // a character Swift sees as one is one Delete: emoji (ZWJ family, skin tone), accents, flags
    try expectEqual(edit("hi 👨‍👩‍👧‍👦", "hi "), TypingEdit(deletes: 1, insert: ""))
    try expectEqual(edit("ok 👍🏽", "ok 👍"), TypingEdit(deletes: 1, insert: "👍"))
    try expectEqual(edit("cafe\u{301}", "caf"), TypingEdit(deletes: 1, insert: ""))
    try expectEqual(edit("e\u{301}\u{328}", ""), TypingEdit(deletes: 1, insert: ""))
    try expectEqual(edit("🇬🇧🇫🇷", "🇬🇧"), TypingEdit(deletes: 1, insert: ""))
    try expectEqual(edit("🇬🇧", "🇬🇧🇫🇷"), TypingEdit(deletes: 0, insert: "🇫🇷"))
    // an accent joining the letter before it changes that letter: it goes and comes back with its accent
    try expectEqual(edit("cafe", "cafe\u{301}"), TypingEdit(deletes: 1, insert: "e\u{301}"))
    // a lone regional indicator that becomes a flag the same way
    try expectEqual(edit("🇬", "🇬🇧"), TypingEdit(deletes: 1, insert: "🇬🇧"))
    // the same text composed or decomposed is no change
    try expectTrue(edit("caf\u{E9}", "cafe\u{301}").isEmpty)
    // nothing to do
    try expectTrue(edit("", "").isEmpty)
    try expectTrue(edit("same", "same").isEmpty)
    try expectEqual(edit("", "dictated text"), TypingEdit(deletes: 0, insert: "dictated text"))
}
