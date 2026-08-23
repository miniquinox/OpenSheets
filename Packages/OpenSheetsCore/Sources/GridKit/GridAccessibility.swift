import AppKit
import Foundation
import SheetModel

/// # How a canvas-drawn grid talks to VoiceOver
///
/// There are no per-cell views to inspect — that is the entire point of this component — so the
/// accessibility tree is synthesised from `NSAccessibilityElement`s.
///
/// The elements are **passive**. The host fills in role, label, value, frame and index ranges
/// when it builds them, rather than each element calling back into the grid. That is a
/// deliberate isolation decision: `NSAccessibilityElement`'s attribute getters are not
/// `@MainActor` in the SDK, so an override of one cannot be either, and reaching main-actor state
/// from inside such an override means either claiming `@unchecked Sendable` — a lie about an
/// `NSObject` with mutable internals — or sending non-`Sendable` values across an isolation
/// boundary. Pushing values *in* from the main actor avoids the question.
///
/// # Why the tree is windowed, and built only when someone is listening
///
/// A sheet has 1,048,576 rows. Handing VoiceOver a million elements is not a performance problem,
/// it is an out-of-memory crash. The tree covers the **visible rows and columns plus the active
/// cell**, capped, which is what an assistive client actually walks: moving the selection scrolls
/// the grid, so the next thing asked about is inside the window again. ``GridHostView`` still
/// reports the sheet's real row and column counts, so "row 4 of 812" is true.
///
/// It is also only built when `VoiceOver` is running (or a test asks for it). Rebuilding a few
/// thousand elements on every scroll frame for nobody is exactly the kind of invisible cost that
/// turns into a battery complaint.

/// One cell.
public final class GridAccessibilityCell: NSAccessibilityElement {
    /// The cell this element stands for.
    public let ref: CellRef
    /// `GridHostView` is `@MainActor`, and therefore `Sendable`, so reading this from a
    /// nonisolated accessibility callback and handing it to `assumeIsolated` is sound.
    weak var host: GridHostView?
    /// Set while the host pushes values in, so a programmatic focus update is not mistaken for
    /// the user asking to move the selection.
    var isRefreshing = false

    init(ref: CellRef, host: GridHostView?) {
        self.ref = ref
        self.host = host
        super.init()
        setAccessibilityRole(.cell)
        setAccessibilityRoleDescription("cell")
    }

    /// VoiceOver moving focus is a selection change, and the grid scrolls to follow it.
    override public func setAccessibilityFocused(_ focused: Bool) {
        super.setAccessibilityFocused(focused)
        guard focused, !isRefreshing, let host else { return }
        let target = ref
        MainActor.assumeIsolated { host.focusCellFromAccessibility(target) }
    }
}

/// One row, whose children are its in-window cells.
public final class GridAccessibilityRow: NSAccessibilityElement {
    public let row: Int

    init(row: Int) {
        self.row = row
        super.init()
        setAccessibilityRole(.row)
        setAccessibilityRoleDescription("row")
        setAccessibilityIndex(row)
        setAccessibilityLabel("Row \(row + 1)")
    }
}

/// One column.
public final class GridAccessibilityColumn: NSAccessibilityElement {
    public let column: Int

    init(column: Int) {
        self.column = column
        super.init()
        setAccessibilityRole(.column)
        setAccessibilityRoleDescription("column")
        setAccessibilityIndex(column)
        setAccessibilityLabel("Column \(CellRef.columnLetters(column))")
    }
}

/// The built tree, handed whole from the main actor to the accessibility callbacks.
final class GridAccessibilityTree {
    var rows: [GridAccessibilityRow] = []
    var columns: [GridAccessibilityColumn] = []
    var cells: [CellRef: GridAccessibilityCell] = [:]
    var selectedRows: [GridAccessibilityRow] = []
    var selectedColumns: [GridAccessibilityColumn] = []
    var selectedCells: [GridAccessibilityCell] = []
    var focused: GridAccessibilityCell?
    var rowCount = 1
    var columnCount = 1
    var label = ""
}

// MARK: - The table

/// `NSView` already implements the whole `NSAccessibility` surface, so the table is expressed by
/// overriding those methods rather than by conforming to `NSAccessibilityTable`.
///
/// That protocol is declared `NS_PROTOCOL_REQUIRES_EXPLICIT_IMPLEMENTATION` and types its rows as
/// `[any NSAccessibilityRow]`, which cannot be reconciled with the `[Any]?` shape `NSView`
/// inherits without an optionality mismatch on an *optional* member. The accessibility runtime
/// reaches the same selectors either way: the role is `AXTable`, `AXRows` and `AXColumns` answer,
/// and `AXCellForColumnAndRow` resolves.
public extension GridHostView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .table }
    override func accessibilityRoleDescription() -> String? { "spreadsheet grid" }
    override func accessibilityLabel() -> String? { accessibilityTree.label }

    override func accessibilityRows() -> [Any]? { accessibilityTree.rows }
    override func accessibilityVisibleRows() -> [Any]? { accessibilityTree.rows }
    override func accessibilitySelectedRows() -> [Any]? { accessibilityTree.selectedRows }
    override func accessibilityColumns() -> [Any]? { accessibilityTree.columns }
    override func accessibilityVisibleColumns() -> [Any]? { accessibilityTree.columns }
    override func accessibilitySelectedColumns() -> [Any]? { accessibilityTree.selectedColumns }
    override func accessibilityChildren() -> [Any]? { accessibilityTree.rows }
    override func accessibilitySelectedCells() -> [Any]? { accessibilityTree.selectedCells }
    override func accessibilityVisibleCells() -> [Any]? { Array(accessibilityTree.cells.values) }
    override func accessibilityRowCount() -> Int { accessibilityTree.rowCount }
    override func accessibilityColumnCount() -> Int { accessibilityTree.columnCount }

    /// The element for a cell, when it is inside the current window.
    ///
    /// Outside the window this is `nil` rather than a freshly built element: building one would
    /// need main-actor state from a nonisolated callback, and a client asking about a cell three
    /// hundred thousand rows off screen is asking about something the user cannot reach without
    /// scrolling — at which point the window moves and the answer exists.
    override func accessibilityCell(forColumn column: Int, row: Int) -> Any? {
        accessibilityTree.cells[CellRef(row: row, column: column)]
    }

    /// The cell VoiceOver reads when the grid takes focus: the active cell, with its address and
    /// its value.
    func accessibilityFocusedUIElement() -> Any? { accessibilityTree.focused }
}

// MARK: - Building

extension GridHostView {
    /// Rebuilds the element window. Cheap when VoiceOver is not running, because it does nothing.
    func refreshAccessibilityTree() {
        guard buildsAccessibilityTree else {
            if !accessibilityTree.rows.isEmpty { accessibilityTree = GridAccessibilityTree() }
            return
        }

        let tree = GridAccessibilityTree()
        tree.label = model.sheet.name
        tree.rowCount = (model.sheet.usedRange?.end.row ?? 0) + 1
        tree.columnCount = (model.sheet.usedRange?.end.column ?? 0) + 1

        let window = accessibilityWindow
        let formatter = renderer.displayFormatter
        let origin = model.geometry.sheetPoint(fromDocument: scrollOrigin)
        let insets = accessibilityContentInsets

        func screenRect(_ rect: CGRect) -> NSRect {
            NSAccessibility.screenRect(fromView: self, rect: CGRect(
                x: rect.minX - origin.x + insets.width,
                y: rect.minY - origin.y + insets.height,
                width: rect.width,
                height: rect.height
            ))
        }

        for column in window.columns {
            let element = GridAccessibilityColumn(column: column)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrame(screenRect(model.geometry.sheetRect(
                of: CellRange(rows: window.rows, columns: column ... column)
            )))
            let selected = model.selection.intersectsColumn(column)
            element.setAccessibilitySelected(selected)
            tree.columns.append(element)
            if selected { tree.selectedColumns.append(element) }
        }

        for row in window.rows {
            let rowElement = GridAccessibilityRow(row: row)
            rowElement.setAccessibilityParent(self)
            rowElement.setAccessibilityFrame(screenRect(model.geometry.sheetRect(
                of: CellRange(rows: row ... row, columns: window.columns)
            )))
            let rowSelected = model.selection.intersectsRow(row)
            rowElement.setAccessibilitySelected(rowSelected)

            var children: [GridAccessibilityCell] = []
            children.reserveCapacity(window.columns.count)
            for column in window.columns {
                let ref = CellRef(row: row, column: column)
                let element = GridAccessibilityCell(ref: ref, host: self)
                element.isRefreshing = true
                let cell = model.sheet.cells[ref]
                let span = model.merges.span(of: ref)
                element.setAccessibilityParent(rowElement)
                element.setAccessibilityLabel(ref.a1String)
                element.setAccessibilityValue(
                    formatter.display(of: cell, styleID: model.effectiveStyleID(at: ref, cell: cell)).text
                )
                element.setAccessibilityHelp(Self.accessibilityHelp(for: cell, merged: span != CellRange(ref)))
                element.setAccessibilityRowIndexRange(NSRange(location: span.start.row, length: span.rowCount))
                element.setAccessibilityColumnIndexRange(
                    NSRange(location: span.start.column, length: span.columnCount)
                )
                element.setAccessibilityFrame(screenRect(model.geometry.sheetRect(of: span)))
                let selected = model.selection.contains(ref)
                element.setAccessibilitySelected(selected)
                if model.selection.active == ref {
                    element.setAccessibilityFocused(true)
                    tree.focused = element
                }
                element.isRefreshing = false

                children.append(element)
                tree.cells[ref] = element
                if selected { tree.selectedCells.append(element) }
            }
            rowElement.setAccessibilityChildren(children)
            tree.rows.append(rowElement)
            if rowSelected { tree.selectedRows.append(rowElement) }
        }

        // The active cell may sit outside the visible window for one frame after a jump; VoiceOver
        // asks for the focused element immediately, so synthesise it rather than answer `nil`.
        if tree.focused == nil {
            let ref = model.selection.active
            let element = GridAccessibilityCell(ref: ref, host: self)
            element.isRefreshing = true
            let cell = model.sheet.cells[ref]
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(ref.a1String)
            element.setAccessibilityValue(
                formatter.display(of: cell, styleID: model.effectiveStyleID(at: ref, cell: cell)).text
            )
            element.setAccessibilityFrame(screenRect(model.geometry.sheetRect(of: ref)))
            element.setAccessibilityFocused(true)
            element.isRefreshing = false
            tree.cells[ref] = element
            tree.focused = element
        }

        accessibilityTree = tree
    }

    private static func accessibilityHelp(for cell: Cell?, merged: Bool) -> String? {
        var parts: [String] = []
        if let cell {
            if let formula = cell.formula { parts.append("formula = \(formula)") }
            if cell.flags.contains(.staleCache) { parts.append("value not recalculated") }
            if cell.flags.contains(.uncomputed) { parts.append("not computed") }
            if cell.flags.contains(.spilledInto) { parts.append("filled in by a formula, read only") }
            if cell.flags.contains(.externalLink) { parts.append("links to another workbook") }
        }
        if merged { parts.append("merged cell") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The rows and columns the element tree covers.
    public var accessibilityWindow: (rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        let visible = visibleRange
        let active = model.selection.active
        let firstRow = min(visible.start.row, active.row)
        let lastRow = min(max(visible.end.row, active.row), firstRow + 200)
        let firstColumn = min(visible.start.column, active.column)
        let lastColumn = min(max(visible.end.column, active.column), firstColumn + 64)
        return (firstRow ... lastRow, firstColumn ... lastColumn)
    }

    /// The header and frozen-band offset, in the host's own coordinates.
    var accessibilityContentInsets: CGSize {
        CGSize(width: scrollViewContentInsets.left, height: scrollViewContentInsets.top)
    }

    /// Moves the selection because an assistive client asked for it.
    func focusCellFromAccessibility(_ ref: CellRef) {
        var selection = model.selection
        selection.select(ref, span: model.merges.merge(containing: ref))
        setSelection(selection)
        scroll(to: ref)
    }

    /// Tells VoiceOver the selection moved. Called whenever the active cell changes, which is
    /// what makes arrow-key navigation audible.
    func postAccessibilitySelectionChange() {
        refreshAccessibilityTree()
        guard buildsAccessibilityTree else { return }
        NSAccessibility.post(element: self, notification: .selectedCellsChanged)
        if let focused = accessibilityTree.focused {
            NSAccessibility.post(element: focused, notification: .focusedUIElementChanged)
        }
    }
}
