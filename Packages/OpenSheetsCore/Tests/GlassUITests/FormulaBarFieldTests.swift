import AppKit
import SwiftUI
import Testing

@testable import GlassUI

/// The formula bar's field, **driven through the real view**.
///
/// # Why not a model test
///
/// Every defect this suite exists for lived in the view and nowhere else. The bar used to render
/// its idle state as a `Button`, and a `Button` cannot take a caret: clicking it fired an action
/// and left the keyboard where it was, which is exactly what *"clicking on the formula box is not
/// letting me edit"* means. And the field prepended `=` to whatever it was handed, which is why
/// its state could only ever describe a formula. Neither shows up in a value type.
///
/// The replacement — a live `TextField` at `opacity(0)` under the coloured `Text` — passed every
/// test in this file while **destroying formulas**, and that is the more useful lesson. These
/// tests drove the *action surface*: focus the field, replace its whole contents, press a key,
/// assert on the action that came out. Not one of them looked at what the field's own editing
/// state was, so none of them could see that focus select-alls, that a single keystroke therefore
/// replaced the cell, or that Escape left the abandoned text on screen. The section
/// **"Editing state"** below is the answer to that: it asserts on selection and content, not on
/// actions.
///
/// So these host a real ``FormulaBar`` in a real `NSWindow`, find the real text view SwiftUI made
/// for it, and send it real `NSEvent`s.
@Suite(.serialized)
@MainActor
struct FormulaBarFieldTests {
    // MARK: - What reaches the field

    /// The contract change, asserted where it is observable: a literal reaches the field
    /// **verbatim**. Under the old contract `text` was formula source and the view rendered
    /// `"=" + text`, so this string could only have arrived as `=Cloud hosting`.
    @Test func aLiteralReachesTheFieldWithNothingPrepended() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: "Cloud hosting"))
        let field = try #require(bar.field)
        #expect(field.string == "Cloud hosting")
        #expect(field.isEditable, "and it is a field, not a label — that is what takes the caret")
    }

    /// And a formula keeps exactly one `=`: the caller's, not the caller's plus the view's.
    @Test func aFormulaKeepsExactlyOneEqualsSign() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "F2", text: "=SUM(B2:B14)"))
        let field = try #require(bar.field)
        #expect(field.string == "=SUM(B2:B14)")
    }

    @Test func anEmptyCellGivesAnEmptyFieldThatIsStillLive() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "Z40", text: ""))
        let field = try #require(bar.field)
        #expect(field.string.isEmpty)
        #expect(field.isEditable)
    }

    // MARK: - Taking the caret

    /// The whole bug in one assertion: putting the caret in the field tells the shell an edit is
    /// starting. The old view could not do this at all — its idle state was a `Button`.
    @Test func focusingTheFieldAsksTheShellToBeginEditing() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: "Cloud hosting"))
        // Explicitly given up first: a window whose only focusable view is this field hands it
        // the caret on its own, and a test that asserted *that* would be asserting an artefact of
        // being hosted alone. The claim is about the transition.
        bar.blur()
        bar.clearActions()
        try bar.focusField()
        #expect(bar.actions.contains(.beginEditing))
    }

    /// A cell whose value is written by a formula somewhere else — and a read-only workbook —
    /// leave **no editable field at all**, so there is nowhere for a keystroke to land. The text
    /// is still drawn, and the click still reaches the shell, which answers with a diagnostic.
    @Test func aRefusedCellHasNoFieldToTypeInto() {
        let bar = Bar(FormulaBarState(nameBoxText: "B3", text: "=SORT(A2:A20)", isEditable: false))
        #expect(bar.field == nil)
        #expect(!(bar.window.firstResponder is NSText), "nothing in the bar grabbed the caret")
    }

    // MARK: - Editing state

    /// **The data-loss bug, pinned.**
    ///
    /// An `NSTextField` selects its whole contents when it takes focus. Behind an invisible field
    /// that select-all was invisible too, so the first character typed replaced `=SUM(B2:B14)`
    /// with `9` and looked, from the user's side, like the formula bar had deleted the cell.
    /// Nothing in this file could see it, because a selection is not an action.
    @Test func focusingDoesNotSelectTheWholeFormula() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "B15", text: "=SUM(B2:B14)"))
        bar.blur()
        let field = try #require(bar.field)
        try bar.focusField()

        #expect(field.selectedRange().length == 0, "focus places a caret, it does not select all")
        #expect(field.string == "=SUM(B2:B14)", "and it changes nothing")
    }

    /// The consequence of the above, stated the way the user met it: one keystroke after clicking
    /// in must leave the formula standing.
    @Test func aSingleKeystrokeAfterFocusingLeavesTheFormulaIntact() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "B15", text: "=SUM(B2:B14)"))
        bar.blur()
        let field = try #require(bar.field)
        try bar.focusField()

        field.insertText("9", replacementRange: field.selectedRange())

        #expect(field.string == "=SUM(B2:B14)9")
        #expect(field.string.contains("SUM(B2:B14)"), "the formula is still in there")
    }

    /// And a click lands the caret *where it was clicked*, so typing goes into the middle of a
    /// formula rather than over it.
    @Test func typingGoesInAtTheCaretRatherThanOverEverything() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "B15", text: "=SUM(B2:B14)"))
        bar.blur()
        let field = try #require(bar.field)
        try bar.focusField()

        // Where a click just inside the closing bracket would put it.
        field.setSelectedRange(NSRange(location: 11, length: 0))
        field.insertText("*2", replacementRange: field.selectedRange())

        #expect(field.string == "=SUM(B2:B14*2)")
    }

    /// A selection the user made themselves is still honoured — this is not a rule against
    /// replacing text, it is a rule against replacing text nobody asked to replace.
    @Test func aDeliberateSelectAllIsStillReplaced() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "B15", text: "=SUM(B2:B14)"))
        bar.blur()
        let field = try #require(bar.field)
        try bar.focusField()

        field.selectAll(nil)
        field.insertText("9", replacementRange: field.selectedRange())
        #expect(field.string == "9")
    }

    /// **Escape restores the formula exactly, and nothing was ever written.**
    ///
    /// The previous version emitted `.cancel` — this file asserted that, and it passed — but the
    /// characters on screen were never put back, because the resync was gated on a focus flag
    /// that had not settled yet. The bar went on showing `9`, the user typed `X`, and `9X` was
    /// what eventually reached the cell.
    @Test func escapeRestoresTheFormulaOnScreenAndCommitsNothing() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "B15", text: "=SUM(B2:B14)"))
        bar.blur()
        let field = try #require(bar.field)
        try bar.focusField()
        field.insertText("9", replacementRange: field.selectedRange())
        bar.clearActions()

        bar.press(.escape)

        #expect(field.string == "=SUM(B2:B14)", "the formula is back, character for character")
        #expect(bar.actions == [.cancel], "and nothing was committed on the way out")
    }

    /// The cross does what Escape does, through the same restore.
    ///
    /// It is a `Button`, and a button click is not a focus change — so a cross that left the
    /// resync to one would cancel the document's edit while the bar went on showing the abandoned
    /// text. Driven here through ``FormulaFieldHandle``, which is the only thing the tick and the
    /// cross touch, because a `.plain` SwiftUI button is not an `NSControl` a headless suite can
    /// click.
    @Test func theCancelButtonsRestoreIsTheSameRestoreEscapeUses() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "B15", text: "=SUM(B2:B14)"))
        bar.blur()
        let field = try #require(bar.field)
        try bar.focusField()
        field.insertText("9", replacementRange: field.selectedRange())
        #expect(field.string == "=SUM(B2:B14)9")

        let handle = FormulaFieldHandle()
        handle.field = field
        #expect(handle.restore() == "=SUM(B2:B14)")
        #expect(field.string == "=SUM(B2:B14)")
        #expect(bar.window.firstResponder !== field, "and the caret goes back to the grid")
    }

    /// **One click, one edit.**
    ///
    /// `beginEditing` used to be emitted from a SwiftUI focus *transition*. A field that already
    /// held the caret produced no transition, so every click after the first told the document
    /// nothing: AppKit had the caret, the document's edit session was closed, and the user —
    /// clicking a bar that never visibly did anything — reported that clicking it did not let
    /// them edit.
    ///
    /// The structural guarantee that closes it: **every way of ending an edit gives the caret
    /// back**, so the next click is necessarily a fresh `becomeFirstResponder`, which announces.
    /// A click on a field that somehow kept the caret announces too — see
    /// ``FormulaTextView/mouseDown(with:)`` — but that path needs a modal mouse-tracking loop to
    /// exercise, which a headless suite cannot supply.
    @Test func everyEndingGivesTheCaretBackSoTheNextClickIsAFreshEdit() throws {
        for ending in [Bar.Key.escape, .return, .tab] {
            let bar = Bar(FormulaBarState(nameBoxText: "B15", text: "=SUM(B2:B14)"))
            let field = try #require(bar.field)
            bar.blur()
            try bar.focusField()
            bar.press(ending)
            #expect(bar.window.firstResponder !== field, "\(ending) left the caret in the field")

            bar.clearActions()
            try bar.focusField()
            #expect(bar.actions.contains(.beginEditing), "the next click is a new edit")
        }
    }

    /// The caret is a real caret, and a formula is coloured **while it is being edited** rather
    /// than only while it is being read — the colouring is applied to the storage the caret is in.
    @Test func theEditableFieldIsTheColouredOne() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "B15", text: "=SUM(B2:B14)"))
        let field = try #require(bar.field)
        let storage = try #require(field.textStorage)

        var range = NSRange(location: 0, length: 0)
        let reference = storage.attributes(at: 5, effectiveRange: &range)[.foregroundColor]
        let bracket = storage.attributes(at: 4, effectiveRange: &range)[.foregroundColor]
        #expect(reference as? NSColor != bracket as? NSColor, "`B2:B14` is not inked as `(`")
        #expect(field.isEditable, "and it is the field itself, not a label over one")
    }

    /// A literal is not run through the formula lexer, which would underline every word of it as
    /// a defined name.
    @Test func aLiteralIsNotColouredLikeAFormula() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: "Cloud hosting"))
        let field = try #require(bar.field)
        let storage = try #require(field.textStorage)
        var range = NSRange(location: 0, length: 0)
        #expect(storage.attributes(at: 0, effectiveRange: &range)[.underlineStyle] == nil)
    }

    // MARK: - The keys that end an edit

    @Test func returnCommitsAndAsksToMoveDown() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: "before"))
        try bar.focusField()
        try bar.type("after")
        bar.clearActions()

        bar.press(.return)
        #expect(bar.actions == [.commit("after", advance: .down)])
    }

    /// Tab never reaches `onSubmit` — AppKit's key view loop takes it first — so the view claims
    /// it explicitly. Without that it moved focus to the next control and abandoned the edit.
    @Test func tabCommitsAndAsksToMoveRight() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: "before"))
        try bar.focusField()
        try bar.type("after")
        bar.clearActions()

        bar.press(.tab)
        #expect(bar.actions == [.commit("after", advance: .forward)])
    }

    @Test func shiftTabCommitsAndAsksToMoveLeft() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "B2", text: "before"))
        try bar.focusField()
        try bar.type("after")
        bar.clearActions()

        bar.press(.tab, flags: .shift)
        #expect(bar.actions == [.commit("after", advance: .backward)])
    }

    @Test func escapeCancels() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: "before"))
        try bar.focusField()
        try bar.type("after")
        bar.clearActions()

        bar.press(.escape)
        #expect(bar.actions == [.cancel])
    }

    /// Committing gives the caret back before the shell is told, so the grid can take it. A field
    /// that resigned afterwards would pull it straight back out of the grid again.
    @Test func committingReleasesTheCaretBeforeTheShellHearsAboutIt() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: "before"))
        let field = try #require(bar.field)
        try bar.focusField()
        try bar.type("after")

        bar.press(.return)
        #expect(bar.window.firstResponder !== field)
    }

    /// What is committed is what was **typed**, not what the state was seeded with — the third of
    /// the three defects: `.textChanged` used to be dropped, so a commit could only ever hand the
    /// original string back.
    @Test func whatIsCommittedIsWhatWasTyped() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: "=SUM(B2:B14)"))
        try bar.focusField()
        try bar.type("=SUM(B2:B14)*2")
        bar.clearActions()

        bar.press(.return)
        guard case let .commit(text, _)? = bar.actions.first else {
            Issue.record("expected a commit, got \(bar.actions)")
            return
        }
        #expect(text == "=SUM(B2:B14)*2")
    }

    /// Every keystroke is reported, which is what lets the grid highlight the ranges a formula
    /// names while it is being typed.
    @Test func everyKeystrokeIsReported() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "A2", text: ""))
        let field = try #require(bar.field)
        try bar.focusField()
        bar.clearActions()

        field.insertText("=A", replacementRange: field.selectedRange())
        field.insertText("1", replacementRange: field.selectedRange())

        #expect(bar.actions == [.textChanged("=A"), .textChanged("=A1")])
    }

    // MARK: - Harness

    /// A ``FormulaBar`` in a real window, plus the text view SwiftUI made for it.
    ///
    /// The window is ordered **back** rather than made key: a suite that stole the keyboard from
    /// whoever ran it would be a worse citizen than the bug it tests, and SwiftUI runs its update
    /// pass off `displayIfNeeded` regardless.
    @MainActor
    private final class Bar {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>

        /// Actions land in a box because the closure is captured before `self` exists.
        private let sink = Sink()
        private final class Sink: @unchecked Sendable { var actions: [FormulaBarAction] = [] }

        nonisolated(unsafe) static var retained: [NSWindow] = []

        init(_ state: FormulaBarState) {
            let sink = sink
            let view = FormulaBar(state: state, context: .light) { sink.actions.append($0) }
            hosting = NSHostingView(rootView: AnyView(view.frame(width: 600)))
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 700, height: 120),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = hosting
            hosting.frame = CGRect(x: 0, y: 0, width: 700, height: 120)
            hosting.layoutSubtreeIfNeeded()
            window.orderBack(nil)
            window.displayIfNeeded()
            Self.retained.append(window)
        }

        var actions: [FormulaBarAction] { sink.actions }
        func clearActions() { sink.actions.removeAll() }

        /// The one field a keystroke can land in, or `nil` when the bar is not editable.
        var field: FormulaTextView? {
            Self.descendants(of: hosting).compactMap { $0 as? FormulaTextView }.first
        }

        func blur() {
            window.makeFirstResponder(nil)
            window.displayIfNeeded()
        }

        func focusField() throws {
            let target = try #require(field)
            window.makeFirstResponder(target)
            window.displayIfNeeded()
        }

        /// Replaces the whole contents, the way a user who selected all of it would.
        ///
        /// **Deliberately explicit.** The version of this helper that select-all'd *silently*, as
        /// a convenience, is why this file could not see the select-on-focus bug: every test
        /// arranged the very state the bug produced, so the bug looked like the arrangement.
        func type(_ text: String) throws {
            let target = try #require(field)
            target.selectAll(nil)
            target.insertText(text, replacementRange: target.selectedRange())
            window.displayIfNeeded()
        }

        /// A real left click in the middle of the field.
        ///
        /// The mouse-up is queued **first**: `NSTextView.mouseDown` runs its own tracking loop and
        /// will sit there until it finds one.
        func clickField() throws {
            let target = try #require(field)
            let middle = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
            let inWindow = target.convert(middle, to: nil)
            guard let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 0
            ), let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1
            ) else {
                Issue.record("could not synthesise a click")
                return
            }
            NSApplication.shared.postEvent(up, atStart: false)
            target.mouseDown(with: down)
            window.displayIfNeeded()
        }

        func press(_ key: Key, flags: NSEvent.ModifierFlags = []) {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: key.characters, charactersIgnoringModifiers: key.characters,
                isARepeat: false, keyCode: key.code
            ) else { return }
            window.sendEvent(event)
            window.displayIfNeeded()
        }

        enum Key {
            case `return`, tab, escape

            var code: UInt16 {
                switch self {
                case .return: 36
                case .tab: 48
                case .escape: 53
                }
            }

            var characters: String {
                switch self {
                case .return: "\r"
                case .tab: "\t"
                case .escape: "\u{1b}"
                }
            }
        }

        static func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }
    }
}
