import CoreGraphics
import Foundation
import SheetModel

/// Everything the grid asks the outside world to do.
///
/// The grid **never mutates a workbook**. It draws one, and it emits these. That is what keeps it
/// previewable with a synthetic sheet and testable without a document, and it is what lets the
/// app shell put every change through undo, the formula engine, and the file writer in one place
/// instead of three.
///
/// A8 handles all of these. Anything not handled is a feature that silently does nothing, so the
/// list is deliberately small enough to read in one go.
public enum GridEvent: Sendable {
    /// The selection changed — click, drag, keyboard, or header click.
    case selectionChanged(GridSelection)

    /// The user wants to start editing. `seed` is the character that started a type-to-edit, or
    /// `nil` for F2 and double-click, which begin with the cell's existing text.
    case beginEdit(ref: CellRef, seed: String?)

    /// The editor was committed. `text` is raw user input — **unparsed**: whether `=A1+1` is a
    /// formula, whether `#N/A` is an error value, and whether `00123` is a number are all
    /// decisions for `SheetFormula` and the model, not for a renderer.
    case commitEdit(ref: CellRef, text: String, advance: AdvanceDirection?)

    /// Editing was abandoned.
    case cancelEdit(ref: CellRef)

    /// Delete or Backspace over the selection: clear values, keep formatting.
    case clearContents([CellRange])

    /// The fill handle was dragged from `source` to `target`. The grid does not know how to
    /// extend a series; it knows where the mouse went.
    case fillHandleDragged(source: CellRange, target: CellRange)

    /// A column divider was dragged. Applies to every selected column when the dragged one is
    /// part of the selection, which is what Excel does.
    case columnsResized(columns: ClosedRange<Int>, width: Double)

    /// A row divider was dragged.
    case rowsResized(rows: ClosedRange<Int>, height: Double)

    /// A column divider was double-clicked: size to fit the widest visible content.
    /// ``GridAutoFit`` computes the width; applying it is a document edit.
    case autoFitColumns(columns: ClosedRange<Int>, suggested: [Int: Double])

    /// A row divider was double-clicked.
    case autoFitRows(rows: ClosedRange<Int>, suggested: [Int: Double])

    /// Right-click. The grid does not build menus — it says where and on what.
    case contextMenu(ref: CellRef, selection: GridSelection, screenPoint: CGPoint)

    /// A hyperlink cell was activated. **Nothing is fetched**: PLAN.md §7.3 requires the URL be
    /// shown before anything goes anywhere, and that decision belongs to the shell.
    case activateHyperlink(ref: CellRef, link: Hyperlink)

    /// The visible rectangle changed. Useful for prefetching and for the status bar.
    case visibleRangeChanged(CellRange)

    /// Pinch-zoom or `⌘+`/`⌘-`.
    case zoomChanged(Double)

    /// A cell was double-clicked somewhere that does not start an edit — a merged cell's body,
    /// for instance. Lets the shell decide.
    case doubleClicked(ref: CellRef)
}

/// A closure the grid calls with events. `@MainActor` because everything in AppKit is.
public typealias GridEventHandler = @MainActor (GridEvent) -> Void
