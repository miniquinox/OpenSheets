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
/// So these host a real ``FormulaBar`` in a real `NSWindow`, find the real `NSTextField` SwiftUI
/// made for it, and send it real `NSEvent`s.
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
        #expect(field.stringValue == "Cloud hosting")
        #expect(field.isEditable, "and it is a field, not a label — that is what takes the caret")
    }

    /// And a formula keeps exactly one `=`: the caller's, not the caller's plus the view's.
    @Test func aFormulaKeepsExactlyOneEqualsSign() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "F2", text: "=SUM(B2:B14)"))
        let field = try #require(bar.field)
        #expect(field.stringValue == "=SUM(B2:B14)")
    }

    @Test func anEmptyCellGivesAnEmptyFieldThatIsStillLive() throws {
        let bar = Bar(FormulaBarState(nameBoxText: "Z40", text: ""))
        let field = try #require(bar.field)
        #expect(field.stringValue.isEmpty)
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

    // MARK: - Harness

    /// A ``FormulaBar`` in a real window, plus the `NSTextField` SwiftUI made for it.
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
        var field: NSTextField? {
            Self.descendants(of: hosting).compactMap { $0 as? NSTextField }.first(where: \.isEditable)
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

        func type(_ text: String) throws {
            let target = try #require(field)
            let editor = try #require(target.currentEditor(), "the field is not being edited")
            editor.selectAll(nil)
            editor.insertText(text)
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
