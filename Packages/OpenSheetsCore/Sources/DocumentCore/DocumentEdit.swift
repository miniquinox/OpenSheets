import Foundation
import GridKit
import SheetFormat
import SheetModel

/// One user action, and exactly enough information to put it back.
///
/// # Why not a workbook snapshot per step
///
/// `Workbook` is a value type with copy-on-write storage, so *taking* a copy is free — but the
/// next mutation pays for the whole `CellStore`. A hundred undo steps over a 100,000-cell sheet
/// would be a hundred full copies of it. So the common case stores a **patch**: the cells that
/// changed, before and after, keyed by reference. A structural edit — insert, delete, sort —
/// rewrites the whole sheet anyway and stores the sheet.
///
/// # Why the region set travels with the edit
///
/// Addendum §2: the writer regenerates only the regions it is told about, and marking too much is
/// worse than marking too little. A row-height change is ``SheetRegionChanges/rows``, a merge is
/// ``SheetRegionChanges/merges``, and a cell edit is ``SheetRegionChanges/cells``. Undo re-marks
/// the *same* regions, because undoing a merge still rewrites `<mergeCells>`.
public struct DocumentEdit: Sendable {
    /// What changed, in the cheapest form that can be reversed exactly.
    public enum Payload: Sendable {
        /// Cells on one sheet. `nil` means the cell did not exist.
        case cells(sheet: SheetID, before: [CellRef: Cell?], after: [CellRef: Cell?])
        /// Whole sheets, for structural edits. Carries every sheet the edit rewrote — an insert
        /// on `Q4` also rewrites the formulas on `Summary` that point into it, and an undo that
        /// restored only `Q4` would leave those pointing one row off.
        case sheets(before: [Sheet], after: [Sheet])
        /// A whole workbook. The escape hatch, for an edit whose reach we cannot enumerate.
        case workbook(before: Workbook, after: Workbook)
    }

    public var payload: Payload
    /// Set when the edit changed defined names. Small enough to copy whole; a workbook with
    /// 65,536 of them is at the model's ceiling and still only a few hundred kilobytes.
    public var definedNames: (before: [String: DefinedName], after: [String: DefinedName])?
    /// Set when the edit interned new styles. Also small — a big workbook has a few thousand.
    public var styles: (before: StyleTable, after: StyleTable)?
    /// What the writer must regenerate. See the type's note.
    public var regions: SheetRegionChanges
    /// Whether a formula was added, changed, or removed. Drops `calcChain.xml`.
    public var formulasChanged: Bool
    /// Whether the style table gained entries.
    public var stylesChanged: Bool
    /// Whether `workbook.xml` changed — a rename, a defined name, a visibility change.
    public var metadataChanged: Bool

    public var sheetBefore: SheetID
    public var sheetAfter: SheetID
    public var selectionBefore: GridSelection
    public var selectionAfter: GridSelection

    /// Shown in Edit ▸ Undo. Sentence case, no trailing punctuation.
    public var name: String
    /// Non-`nil` when two consecutive edits with the same key should read as one action.
    public var coalescingKey: String?
    /// When it happened, for the coalescing window.
    public var recordedAt: ContinuousClock.Instant

    public init(
        payload: Payload,
        definedNames: (before: [String: DefinedName], after: [String: DefinedName])? = nil,
        styles: (before: StyleTable, after: StyleTable)? = nil,
        regions: SheetRegionChanges = .cells,
        formulasChanged: Bool = false,
        stylesChanged: Bool = false,
        metadataChanged: Bool = false,
        sheetBefore: SheetID,
        sheetAfter: SheetID,
        selectionBefore: GridSelection,
        selectionAfter: GridSelection,
        name: String,
        coalescingKey: String? = nil,
        recordedAt: ContinuousClock.Instant = .now
    ) {
        self.payload = payload
        self.definedNames = definedNames
        self.styles = styles
        self.regions = regions
        self.formulasChanged = formulasChanged
        self.stylesChanged = stylesChanged
        self.metadataChanged = metadataChanged
        self.sheetBefore = sheetBefore
        self.sheetAfter = sheetAfter
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
        self.name = name
        self.coalescingKey = coalescingKey
        self.recordedAt = recordedAt
    }

    /// The sheets this edit touches, for marking the writer's dirty set.
    public var affectedSheets: Set<SheetID> {
        switch payload {
        case let .cells(sheet, _, _): [sheet]
        case let .sheets(before, after): Set(before.map(\.id)).union(after.map(\.id))
        case let .workbook(before, after):
            Set(before.sheets.map(\.id)).union(after.sheets.map(\.id))
        }
    }

    /// Applies this edit forwards or backwards to `workbook`.
    ///
    /// Total and exact in both directions: `apply(.undo)` after `apply(.redo)` restores the same
    /// `Workbook` **value**, which is what makes the byte-identical-save guarantee hold — the
    /// writer is a pure function of the workbook and the dirty set.
    public func apply(_ direction: Direction, to workbook: inout Workbook) {
        switch payload {
        case let .cells(sheet, before, after):
            let target = direction == .undo ? before : after
            try? workbook.withSheet(sheet) { current in
                for (ref, cell) in target {
                    if let cell {
                        try? current.cells.setCell(cell, at: ref)
                    } else {
                        _ = current.cells.removeCell(at: ref)
                    }
                }
            }
        case let .sheets(before, after):
            for sheet in direction == .undo ? before : after { workbook.update(sheet) }
        case let .workbook(before, after):
            workbook = direction == .undo ? before : after
        }
        if let definedNames {
            workbook.definedNames = direction == .undo ? definedNames.before : definedNames.after
        }
        if let styles {
            workbook.styles = direction == .undo ? styles.before : styles.after
        }
    }

    public enum Direction: Sendable, Hashable { case undo, redo }
}

/// Undo and redo for one document.
///
/// A plain value type with no `UndoManager` in it. That is deliberate: `UndoManager` is a
/// registration API whose state lives in AppKit, and mirroring a second copy of the stack next to
/// it is how undo ends up disagreeing with itself after a refresh. The Edit menu binds to this
/// directly, and ``clear()`` — which a refresh calls, because the file on disk is the source of
/// truth after an external change — is a single line that cannot get out of step.
public struct DocumentUndoStack: Sendable {
    /// How long two edits with the same key stay one action. Roughly a typing pause.
    public static let coalescingWindow: Duration = .milliseconds(900)
    /// Steps kept. Beyond this the oldest is dropped, because an undo stack that grows without
    /// bound over an eight-hour session is a memory leak with a friendly name.
    public static let depth = 200

    public private(set) var undoable: [DocumentEdit] = []
    public private(set) var redoable: [DocumentEdit] = []

    public init() {}

    public var canUndo: Bool { !undoable.isEmpty }
    public var canRedo: Bool { !redoable.isEmpty }
    public var undoName: String? { undoable.last?.name }
    public var redoName: String? { redoable.last?.name }
    /// Steps recorded and not undone. Drives "3 unsaved edits" in the conflict banner.
    public var depthUsed: Int { undoable.count }

    public mutating func record(_ edit: DocumentEdit) {
        redoable.removeAll()
        if var previous = undoable.last,
           let key = edit.coalescingKey,
           previous.coalescingKey == key,
           edit.recordedAt - previous.recordedAt < Self.coalescingWindow,
           case let .cells(sheet, _, previousAfter) = previous.payload,
           case let .cells(editSheet, editBefore, editAfter) = edit.payload,
           sheet == editSheet
        {
            // Keep the oldest `before` and the newest `after`, so one undo returns the cell to
            // what it held before the user started typing into it.
            var before = editBefore
            if case let .cells(_, previousBefore, _) = previous.payload {
                for (ref, cell) in previousBefore { before[ref] = cell }
            }
            var after = previousAfter
            for (ref, cell) in editAfter { after[ref] = cell }
            previous.payload = .cells(sheet: sheet, before: before, after: after)
            previous.regions.formUnion(edit.regions)
            previous.formulasChanged = previous.formulasChanged || edit.formulasChanged
            previous.stylesChanged = previous.stylesChanged || edit.stylesChanged
            previous.metadataChanged = previous.metadataChanged || edit.metadataChanged
            previous.selectionAfter = edit.selectionAfter
            previous.sheetAfter = edit.sheetAfter
            previous.recordedAt = edit.recordedAt
            undoable[undoable.count - 1] = previous
            return
        }
        undoable.append(edit)
        if undoable.count > Self.depth { undoable.removeFirst(undoable.count - Self.depth) }
    }

    public mutating func undo() -> DocumentEdit? {
        guard let edit = undoable.popLast() else { return nil }
        redoable.append(edit)
        return edit
    }

    public mutating func redo() -> DocumentEdit? {
        guard let edit = redoable.popLast() else { return nil }
        undoable.append(edit)
        return edit
    }

    /// Throws the whole history away.
    ///
    /// PLAN.md §1.2 step 7 and §9: **a refresh clears the undo stack.** After an external change
    /// the file on disk is the source of truth, and an undo step recorded against the version we
    /// replaced would put back cells that no longer mean anything. The diff panel says so, once.
    public mutating func clear() {
        undoable.removeAll()
        redoable.removeAll()
    }
}
