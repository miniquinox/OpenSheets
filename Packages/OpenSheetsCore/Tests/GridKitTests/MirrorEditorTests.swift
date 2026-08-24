import AppKit
import SheetModel
import Testing

@testable import GridKit

/// The in-cell editor as a **mirror** of an edit happening in the formula bar.
///
/// # The problem this shape solves
///
/// Excel shows what you type in the formula bar inside the cell as you type it. The obvious way to
/// get that — open the in-cell editor — steals the keyboard: `CellEditor.begin` ends by making its
/// field first responder, which both moves the caret off the character the user clicked in the bar
/// and tears down the field editor session they had just started. So the editor grew a mode that
/// shows and does not take.
///
/// Driven through the real views in a real window, because "did the keyboard move" is a question
/// only a window can answer.
@Suite(.serialized)
@MainActor
struct MirrorEditorTests {
    @Test("A mirrored edit shows in the cell without taking the keyboard")
    func mirroringDoesNotTakeFocus() throws {
        let grid = try Grid()
        grid.window.makeFirstResponder(grid.host.firstResponderTarget)
        let before = grid.window.firstResponder

        grid.host.beginEdit(at: CellRef(a1: "B2")!, seed: "=1+", takingFocus: false)

        #expect(grid.host.editor.isEditing, "the cell has to show the text")
        #expect(grid.host.editor.text == "=1+")
        #expect(grid.window.firstResponder === before, "and it must not move the caret")
    }

    @Test("An ordinary edit still takes the keyboard")
    func anOrdinaryEditStillTakesFocus() throws {
        let grid = try Grid()
        grid.window.makeFirstResponder(grid.host.firstResponderTarget)

        grid.host.beginEdit(at: CellRef(a1: "B2")!, seed: nil)

        #expect(grid.host.editor.isEditing)
        #expect(grid.window.firstResponder is NSText, "F2 and double-click put the caret in the cell")
    }

    @Test("Mirroring new text into an open editor replaces what it shows")
    func mirrorReplacesTheText() throws {
        let grid = try Grid()
        grid.controller.beginEdit(at: CellRef(a1: "B2")!, seed: "=1", takingFocus: false)

        grid.controller.editorText = "=1+2"
        #expect(grid.controller.editorText == "=1+2")
        #expect(grid.host.editor.field.stringValue == "=1+2")
    }

    /// The other half of the mirror. Setting the text must **not** fire the change callback, or
    /// the bar and the cell would echo each other forever; typing must.
    @Test("Typing in the cell reports, mirroring does not")
    func onlyTypingReportsAChange() throws {
        let grid = try Grid()
        var reported: [String] = []
        grid.controller.onEditorTextChanged = { reported.append($0) }

        grid.controller.beginEdit(at: CellRef(a1: "B2")!, seed: "=1", takingFocus: false)
        grid.controller.editorText = "=1+2"
        #expect(reported.isEmpty, "a mirrored write must not come back as a keystroke")

        // And now a real keystroke, into the real field editor.
        grid.controller.dismissEdit()
        grid.controller.beginEdit(at: CellRef(a1: "B2")!, seed: "=1")
        let editor = try #require(grid.host.editor.field.currentEditor(), "the editor has the caret")
        editor.selectedRange = NSRange(location: 2, length: 0)
        editor.insertText("+2")

        #expect(reported == ["=1+2"], "got \(reported)")
    }

    /// A shell that committed the text itself needs the editor gone without a second commit and
    /// without a cancel for an edit that did land.
    @Test("Dismissing an editor emits nothing")
    func dismissingEmitsNothing() throws {
        let grid = try Grid()
        var events: [GridEvent] = []
        grid.controller.beginEdit(at: CellRef(a1: "B2")!, seed: "typed", takingFocus: false)
        grid.host.onEvent = { events.append($0) }

        grid.controller.dismissEdit()
        #expect(!grid.controller.isEditing)
        #expect(events.isEmpty, "got \(events)")
    }

    /// The refusal reaches the shell, so a formula bar can say *why* rather than leaving a
    /// keystroke that did nothing.
    @Test("A refused edit is reported to the shell as well as beeped")
    func refusalsReachTheShell() throws {
        let grid = try Grid(spilled: true)
        var refusals: [(CellRef, SheetError)] = []
        grid.controller.onEditRefused = { refusals.append(($0, $1)) }

        grid.host.beginEdit(at: CellRef(a1: "E2")!, seed: nil)

        #expect(!grid.host.editor.isEditing, "refused, so no editor")
        #expect(refusals.count == 1)
        #expect(refusals.first?.1.code == "cell.notIndependentlyEditable")
        #expect(refusals.first?.0 == CellRef(a1: "E2"))
    }

    // MARK: - The advance a shell-side commit needs

    /// Return from the formula bar has to land where Return from the cell lands, so it goes
    /// through the same navigator rather than through arithmetic on the caret.
    @Test("A shell-driven advance uses the grid's navigator and skips hidden rows")
    func advanceSkipsHiddenRows() throws {
        let grid = try Grid(hidingRow: 2)
        grid.controller.advance(.down, from: GridSelection(active: CellRef(a1: "A2")!))
        #expect(grid.host.model.selection.active == CellRef(a1: "A4"), "row 3 is hidden")
    }

    /// The shell's selection is the authoritative one; the render model's copy only catches up on
    /// the next SwiftUI pass. A commit in the same turn as a name-box jump has to advance from
    /// where the caret actually is.
    @Test("The advance starts from the selection it is given, not the grid's stale copy")
    func advanceUsesTheGivenSelection() throws {
        let grid = try Grid()
        #expect(grid.host.model.selection.active == .origin, "the grid still thinks the caret is at A1")

        grid.controller.advance(.forward, from: GridSelection(active: CellRef(a1: "D7")!))
        #expect(grid.host.model.selection.active == CellRef(a1: "E7"))
    }

    // MARK: - Harness

    @MainActor
    private struct Grid {
        let host: GridHostView
        let window: NSWindow
        let controller = GridController()

        nonisolated(unsafe) static var retained: [NSWindow] = []

        init(spilled: Bool = false, hidingRow: Int? = nil) throws {
            var store = CellStore()
            for row in 0 ..< 12 {
                for column in 0 ..< 8 {
                    try store.setCell(.number(Double(row * 8 + column)), at: CellRef(row: row, column: column))
                }
            }
            var sheet = Sheet(id: 1, name: "Report", cells: store)
            if spilled {
                try sheet.cells.setCell(
                    Cell(value: .number(1), formula: "TRANSPOSE(A2:A4)", flags: [.spillAnchor, .arrayFormula]),
                    at: CellRef(a1: "E1")!
                )
                try sheet.cells.setCell(
                    Cell(value: .number(2), flags: [.spilledInto, .arrayFormula]), at: CellRef(a1: "E2")!
                )
                sheet.arrayFormulaRanges[CellRef(a1: "E1")!] = CellRange(a1: "E1:E3")!
            }
            if let hidingRow { sheet.hiddenRows.setValue(true, in: hidingRow ... hidingRow) }

            let view = GridHostView(
                model: GridRenderModel(
                    sheet: sheet, styles: StyleTable(), geometry: GridGeometry(sheet: sheet)
                )
            )
            controller.host = view
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = view
            view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            Self.retained.append(window)
            host = view
        }
    }
}
