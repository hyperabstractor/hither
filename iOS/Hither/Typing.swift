import Shared
import UIKit

/// What the on-screen keyboard types into while it's up: an invisible text view, so iOS has real text to write into
/// and revise (dictation from the keyboard's mic key needs that). Each change goes to the Mac as the difference from
/// what was sent before (`TypingEdit`): Deletes, then text. Plain typing adds one character, which is all that's sent.
///
/// It only ever holds text typed since the Mac's cursor was last known to follow it. `reset` empties it whenever that
/// stops being so (a click, a key that moves the cursor, Return, a shortcut…): nothing typed before can be revised or
/// deleted from here after that, so iOS never deletes text it didn't put there. Delete with it empty is a Mac Delete.
///
/// Text still being composed (marked text: an input method's, or dictation's while it listens) isn't sent; it goes
/// once it's committed.
final class TypingBuffer: UITextView, UITextViewDelegate {
    /// What the text changed by, since what was sent last.
    var onEdit: (TypingEdit) -> Void = { _ in }
    /// About to be typed: true when it was sent as a key instead (Return, Tab, a shortcut), and isn't added.
    var onInsert: (String) -> Bool = { _ in false }
    /// Delete, with nothing (`empty`) or something typed to take back: true when it was sent as a Mac key instead.
    var onDelete: (_ empty: Bool) -> Bool = { _ in false }
    /// Hardware keyboard presses: true when they went to the Mac (they never reach the text).
    var onPresses: (_ presses: Set<UIPress>, _ down: Bool) -> Bool = { _, _ in false }
    /// The keyboard went away.
    var onResign: () -> Void = {}

    /// The text as the Mac has it from us.
    private var sent = ""

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        delegate = self
        // Not hidden (that would keep it from taking the keyboard): one clear point that draws nothing.
        alpha = 0.02
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        clipsToBounds = true
        isScrollEnabled = false
        scrollsToTop = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        textDragInteraction?.isEnabled = false
        // no cut, copy, paste, undo in the keyboard's shortcut bar: those go to the Mac as keys
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        noAssistance()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// No help from iOS: the Mac app does its own completion and correction. (Corrections and predictions, if they're
    /// ever allowed here, are revisions like dictation's and would reach the Mac the same way.)
    private func noAssistance() {
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        if #available(iOS 18, *) {
            writingToolsBehavior = .none
            mathExpressionCompletionType = .no
        }
    }

    /// Forget what's been typed: from here on only what's typed next can be revised or deleted.
    func reset() {
        sent = ""
        if !text.isEmpty || markedTextRange != nil { text = "" }
    }

    /// Send what changed, unless some of it is still being composed.
    private func sync() {
        guard markedTextRange == nil else { return }
        // (an attachment, such as a placeholder while dictation works, isn't text for the Mac)
        let now = text.replacingOccurrences(of: "\u{FFFC}", with: "")
        let edit = TypingEdit(from: sent, to: now)
        sent = now
        if !edit.isEmpty { onEdit(edit) }
    }

    func textViewDidChange(_ textView: UITextView) { sync() }

    override func unmarkText() {
        super.unmarkText()
        sync()   // composing ended: what it left is committed
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        markedTextRange != nil || text.isEmpty || !onInsert(text)
    }

    /// The cursor stays at the end, where the Mac's is: only the newest text is ever changed (the keyboard's
    /// space-bar trackpad moves nothing).
    func textViewDidChangeSelection(_ textView: UITextView) {
        guard markedTextRange == nil else { return }
        let end = NSRange(location: (text as NSString).length, length: 0)
        if selectedRange != end { selectedRange = end }
    }

    // never touched: taps where it sits go to the picture (interaction stays on, so it can always take the keyboard)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override var hasText: Bool { true }   // so Delete always comes through, with nothing typed too

    override func deleteBackward() {
        // composing: the input method's to delete from
        if markedTextRange == nil, onDelete(text.isEmpty) { return }
        super.deleteBackward()
    }

    // no edit menu shortcuts here (⌘C, ⌘V…): they go to the Mac as keys
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }

    override func resignFirstResponder() -> Bool {
        let done = super.resignFirstResponder()
        if done {
            reset()
            onResign()
        }
        return done
    }

    // A hardware keyboard sends Mac keys, as without the on-screen keyboard: they never type into the text here.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !onPresses(presses, true) { super.pressesBegan(presses, with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !onPresses(presses, false) { super.pressesEnded(presses, with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !onPresses(presses, false) { super.pressesCancelled(presses, with: event) }
    }
}
