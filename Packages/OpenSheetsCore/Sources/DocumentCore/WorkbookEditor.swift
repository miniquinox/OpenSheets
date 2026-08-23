import Foundation
import GridKit
import SheetFormat
import SheetFormula
import SheetModel

/// Every mutation the app can make to a workbook, as pure functions that return a
/// ``DocumentEdit``.
///
/// Split out of ``DocumentModel`` on purpose. The model owns state — the session, the engine, the
/// selection, the undo stack — and every one of those makes a test harder to write. These are
/// `(inout Workbook, arguments) -> DocumentEdit`, so the whole editing surface is testable with a
/// workbook literal and no window, no file, and no actor.
public enum WorkbookEditor {
    // MARK: - Cells

    /// Writes cells, replacing whatever was there. `nil` deletes.
    public static func setCells(
        _ values: [CellRef: Cell?],
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selectionBefore: GridSelection,
        selectionAfter: GridSelection,
        name: String,
        coalescingKey: String? = nil,
        formulasChanged: Bool = false
    ) -> DocumentEdit? {
        guard let sheet = workbook[sheetID], !values.isEmpty else { return nil }

        var before: [CellRef: Cell?] = [:]
        before.reserveCapacity(values.count)
        var after: [CellRef: Cell?] = [:]
        after.reserveCapacity(values.count)
        for (ref, cell) in values {
            let current = sheet.cells[ref]
            // Skip a no-op write so a paste that changes nothing does not become an undo step.
            if current == cell { continue }
            before[ref] = current
            after[ref] = cell
        }
        guard !before.isEmpty else { return nil }

        let edit = DocumentEdit(
            payload: .cells(sheet: sheetID, before: before, after: after),
            regions: .cells,
            formulasChanged: formulasChanged,
            sheetBefore: sheetID,
            sheetAfter: sheetID,
            selectionBefore: selectionBefore,
            selectionAfter: selectionAfter,
            name: name,
            coalescingKey: coalescingKey
        )
        edit.apply(.redo, to: &workbook)
        return edit
    }

    /// Delete / Backspace: clears values and formulas, **keeps** formatting.
    ///
    /// Excel's behaviour, and the one people rely on — clearing a column of currency figures must
    /// not also clear the currency format, or the next entry comes back as a bare number.
    public static func clearContents(
        in ranges: [CellRange],
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection
    ) -> DocumentEdit? {
        guard let sheet = workbook[sheetID] else { return nil }
        var values: [CellRef: Cell?] = [:]
        var hadFormula = false
        for range in ranges {
            sheet.cells.forEachCell(in: range) { ref, cell in
                hadFormula = hadFormula || cell.isFormula
                values[ref] = cell.styleID == .default ? Cell?.none : Cell.styled(cell.styleID)
            }
        }
        return setCells(
            values,
            on: sheetID,
            in: &workbook,
            selectionBefore: selection,
            selectionAfter: selection,
            name: "Clear",
            formulasChanged: hadFormula
        )
    }

    // MARK: - Structure

    /// Inserts or deletes rows or columns, rewriting every formula and defined name that pointed
    /// at what moved.
    ///
    /// The rewrite is the whole job. `Sheet.insertRows` moves cells, merges, sizes, hyperlinks and
    /// array regions — it explicitly does **not** touch formula text, because that needs a parser.
    /// So this walks every formula in every sheet through A3's `ReferenceTransform`, which is also
    /// what turns a reference into `#REF!` when the edit destroyed it rather than quietly clamping
    /// it to the nearest surviving cell.
    public static func structural(
        _ edit: StructuralEdit,
        in workbook: inout Workbook,
        selection: GridSelection
    ) throws(SheetError) -> DocumentEdit? {
        guard workbook[edit.sheet] != nil, edit.count > 0 else { return nil }

        let sheetsBefore = workbook.sheets
        let namesBefore = workbook.definedNames

        try workbook.withSheetTyped(edit.sheet) { sheet throws(SheetError) in
            switch edit.kind {
            case .insertRows: try sheet.insertRows(at: edit.index, count: edit.count)
            case .deleteRows: try sheet.deleteRows(at: edit.index, count: edit.count)
            case .insertColumns: try sheet.insertColumns(at: edit.index, count: edit.count)
            case .deleteColumns: try sheet.deleteColumns(at: edit.index, count: edit.count)
            }
        }

        // Formulas, everywhere. A reference on `Summary` into `Q4` moves too.
        for sheet in workbook.sheets {
            let resolution = SheetResolution(owner: sheet.id, workbook: workbook)
            var rewrites: [CellRef: Cell?] = [:]
            sheet.cells.forEachCell(in: Limits.entireSheet) { ref, cell in
                guard let formula = cell.formula else { return }
                guard let result = try? ReferenceTransform.adjust(
                    formula: formula, for: edit, resolving: resolution
                ), result.didChange else { return }
                var updated = cell
                updated.formula = result.formula
                if result.invalidatedReferences > 0 { updated.value = .error(.invalidReference) }
                rewrites[ref] = updated
            }
            guard !rewrites.isEmpty else { continue }
            try? workbook.withSheet(sheet.id) { target in
                for (ref, cell) in rewrites where cell != nil {
                    try? target.cells.setCell(cell!, at: ref)
                }
            }
        }

        // Defined names. A name whose target the edit destroyed is dropped rather than left
        // pointing at a rectangle that no longer exists.
        for (key, name) in workbook.definedNames {
            guard let target = name.target else { continue }
            let scope = target.sheet ?? name.scope
            guard let scope else { continue }
            if let adjusted = ReferenceTransform.adjust(target.range, on: scope, for: edit) {
                guard adjusted != target.range else { continue }
                var updated = name
                updated.target = RangeReference(sheet: target.sheet, range: adjusted)
                updated.formula = absoluteA1(
                    sheetName: target.sheet.flatMap { workbook[$0]?.name },
                    range: adjusted
                )
                workbook.definedNames[key] = updated
            } else {
                workbook.definedNames.removeValue(forKey: key)
            }
        }

        let changed = zip(sheetsBefore, workbook.sheets)
            .filter { $0.0 != $0.1 }
        guard !changed.isEmpty || namesBefore != workbook.definedNames else { return nil }

        return DocumentEdit(
            payload: .sheets(before: changed.map(\.0), after: changed.map(\.1)),
            definedNames: namesBefore == workbook.definedNames ? nil : (namesBefore, workbook.definedNames),
            // A structural edit moves rows and columns bodily, so their sizes, the merge list and
            // the filter range all move with them — but `<cols>`/`<sheetFormatPr>` are only
            // regenerated for the sheet that was actually restructured.
            regions: [.cells, .rows, .columns, .merges, .hyperlinks, .autoFilter],
            formulasChanged: true,
            metadataChanged: namesBefore != workbook.definedNames,
            sheetBefore: edit.sheet,
            sheetAfter: edit.sheet,
            selectionBefore: selection,
            selectionAfter: selection,
            name: edit.kind.actionName
        )
    }

    // MARK: - Copy, fill, paste

    /// Fill-handle drag, fill-down and fill-right.
    ///
    /// `source` is the block being extended; `target` is the whole region including it. Formulas
    /// are translated with A3's `ReferenceTransform`, so `=B2*$C$1` filled down becomes `=B3*$C$1`
    /// and not `=B3*$C$2`. Literal values continue a detected series — see ``FillSeries``.
    public static func fill(
        from source: CellRange,
        to target: CellRange,
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection
    ) -> DocumentEdit? {
        guard let sheet = workbook[sheetID], target.contains(source) else { return nil }
        var values: [CellRef: Cell?] = [:]
        var formulasChanged = false

        let downwards = target.end.row > source.end.row || target.start.row < source.start.row
        let sourceLength = downwards ? source.rowCount : source.columnCount

        for ref in target where !source.contains(ref) {
            let offset = downwards
                ? ref.row - source.start.row
                : ref.column - source.start.column
            // Modulo, and correct for a fill that runs *backwards* past the source.
            var index = offset % sourceLength
            if index < 0 { index += sourceLength }
            let origin = downwards
                ? CellRef(row: source.start.row + index, column: ref.column)
                : CellRef(row: ref.row, column: source.start.column + index)
            guard let template = sheet.cells[origin] else {
                values[ref] = Cell?.none
                continue
            }
            var produced = template
            if let formula = template.formula {
                formulasChanged = true
                if let result = try? ReferenceTransform.translate(
                    formula: formula, from: origin, to: ref
                ) {
                    produced.formula = result.formula
                    if result.invalidatedReferences > 0 { produced.value = .error(.invalidReference) }
                }
                produced.flags.insert(.staleCache)
            } else if let step = FillSeries.detect(source, in: sheet, alongRows: downwards) {
                let position = downwards
                    ? ref.row - source.start.row
                    : ref.column - source.start.column
                produced = step.value(at: position, template: template)
            }
            values[ref] = produced
        }

        return setCells(
            values,
            on: sheetID,
            in: &workbook,
            selectionBefore: selection,
            selectionAfter: selection,
            name: "Fill",
            formulasChanged: formulasChanged
        )
    }

    /// What a paste keeps.
    public enum PasteMode: Sendable, Hashable {
        /// Values, formulas and formatting.
        case everything
        /// Values only — a formula becomes its last computed result.
        case valuesOnly
        /// Formatting only.
        case formatsOnly
    }

    /// Pastes a clipboard block at `destination`.
    ///
    /// Two things make this more than a loop. Styles are **re-interned** into the destination
    /// workbook, because a `StyleID` is an index into one file's table and means nothing in
    /// another. And formulas are **translated** by the offset, so a `=B2*2` copied one row down
    /// pastes as `=B3*2` — which is what copy and paste means in a spreadsheet and what makes the
    /// difference between our own pasteboard type and plain text worth carrying.
    ///
    /// A paste larger than the selection tiles it, the way Excel does: copying one cell and
    /// pasting over a block fills the block.
    public static func paste(
        _ payload: ClipboardPayload,
        at destination: CellRange,
        mode: PasteMode = .everything,
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection
    ) -> DocumentEdit? {
        guard let sheet = workbook[sheetID], payload.rowCount > 0, payload.columnCount > 0 else {
            return nil
        }

        // Tile: at least the payload's own size, more when the user selected a bigger block.
        let rows = max(payload.rowCount, destination.rowCount - destination.rowCount % payload.rowCount)
        let columns = max(
            payload.columnCount,
            destination.columnCount - destination.columnCount % payload.columnCount
        )
        let target = CellRange(
            start: destination.start,
            end: CellRef(
                row: min(destination.start.row + rows - 1, Limits.maxRow),
                column: min(destination.start.column + columns - 1, Limits.maxColumn)
            )
        )

        let stylesBefore = workbook.styles
        var styles = workbook.styles
        var remapped: [StyleID: StyleID] = [:]
        var values: [CellRef: Cell?] = [:]
        var formulasChanged = false

        for ref in target {
            let sourceRow = (ref.row - target.start.row) % payload.rowCount
            let sourceColumn = (ref.column - target.start.column) % payload.columnCount
            let source = payload[sourceRow, sourceColumn]

            if mode == .formatsOnly {
                guard let source, source.styleID != .default else { continue }
                var cell = sheet.cells[ref] ?? Cell(value: .empty)
                cell.styleID = intern(source.styleID, payload: payload, into: &styles, cache: &remapped)
                values[ref] = cell
                continue
            }

            guard var cell = source else {
                values[ref] = Cell?.none
                continue
            }
            if cell.styleID != .default {
                cell.styleID = mode == .valuesOnly
                    ? (sheet.cells[ref]?.styleID ?? .default)
                    : intern(cell.styleID, payload: payload, into: &styles, cache: &remapped)
            }
            if let formula = cell.formula {
                if mode == .valuesOnly {
                    cell.formula = nil
                    cell.flags.remove(.staleCache)
                } else {
                    formulasChanged = true
                    let origin = CellRef(
                        row: payload.origin.row + sourceRow,
                        column: payload.origin.column + sourceColumn
                    )
                    if let result = try? ReferenceTransform.translate(
                        formula: formula, from: origin, to: ref
                    ) {
                        cell.formula = result.formula
                        if result.invalidatedReferences > 0 { cell.value = .error(.invalidReference) }
                    }
                    cell.flags.insert(.staleCache)
                }
            }
            values[ref] = cell
        }

        workbook.styles = styles
        var after = selection
        after.select(target, active: target.start)
        guard var edit = setCells(
            values,
            on: sheetID,
            in: &workbook,
            selectionBefore: selection,
            selectionAfter: after,
            name: "Paste",
            formulasChanged: formulasChanged
        ) else {
            workbook.styles = stylesBefore
            return nil
        }
        if stylesBefore != styles {
            edit.styles = (stylesBefore, styles)
            edit.stylesChanged = true
        }
        return edit
    }

    private static func intern(
        _ id: StyleID,
        payload: ClipboardPayload,
        into styles: inout StyleTable,
        cache: inout [StyleID: StyleID]
    ) -> StyleID {
        if let existing = cache[id] { return existing }
        guard let style = payload.styles[id] else { return .default }
        let interned = styles.intern(style)
        cache[id] = interned
        return interned
    }

    // MARK: - Formatting

    /// Applies a style transform to every cell in the selection, interning the results.
    ///
    /// The style table is copied into the edit because interning grows it, and an undo that put
    /// the cells back without shrinking the table would leave orphan styles that a later save
    /// writes out. They are harmless but they accumulate, and "harmless but accumulating" is how
    /// a file gains 4,000 unused `<xf>` entries over a month.
    public static func restyle(
        _ ranges: [CellRange],
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection,
        name: String,
        transform: (inout CellStyle) -> Void
    ) -> DocumentEdit? {
        guard let sheet = workbook[sheetID] else { return nil }
        let stylesBefore = workbook.styles
        var styles = workbook.styles
        var values: [CellRef: Cell?] = [:]

        for range in ranges {
            for ref in range {
                let current = sheet.cells[ref]
                let sourceID = current?.styleID ?? sheet.effectiveStyleID(at: ref)
                let derived = styles.derive(sourceID) { transform(&$0) }
                guard derived != sourceID || current == nil else { continue }
                var cell = current ?? Cell(value: .empty)
                cell.styleID = derived
                values[ref] = cell
            }
        }
        guard !values.isEmpty else { return nil }

        workbook.styles = styles
        guard var edit = setCells(
            values,
            on: sheetID,
            in: &workbook,
            selectionBefore: selection,
            selectionAfter: selection,
            name: name
        ) else {
            workbook.styles = stylesBefore
            return nil
        }
        edit.styles = (stylesBefore, styles)
        edit.stylesChanged = true
        return edit
    }

    // MARK: - Geometry

    /// A column resize. ``SheetRegionChanges/columns`` and nothing else — addendum §2.
    public static func resizeColumns(
        _ columns: ClosedRange<Int>,
        to width: Double,
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection
    ) -> DocumentEdit? {
        mutateSheet(sheetID, in: &workbook, selection: selection, name: "Resize columns", regions: .columns) {
            $0.columnWidths.setValue(width, in: columns)
        }
    }

    /// A row resize. ``SheetRegionChanges/rows``.
    public static func resizeRows(
        _ rows: ClosedRange<Int>,
        to height: Double,
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection
    ) -> DocumentEdit? {
        mutateSheet(sheetID, in: &workbook, selection: selection, name: "Resize rows", regions: .rows) {
            $0.rowHeights.setValue(height, in: rows)
        }
    }

    /// Merge or unmerge the selection. ``SheetRegionChanges/merges``.
    public static func toggleMerge(
        _ range: CellRange,
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection
    ) -> DocumentEdit? {
        guard let sheet = workbook[sheetID] else { return nil }
        let existing = sheet.merges.firstIndex { $0 == range || $0.contains(range) }
        return mutateSheet(
            sheetID, in: &workbook, selection: selection,
            name: existing == nil ? "Merge cells" : "Unmerge cells",
            regions: [.merges, .cells]
        ) { target in
            if let existing {
                target.merges.remove(at: existing)
            } else {
                guard !range.isSingleCell else { return }
                target.merges.removeAll { $0.intersects(range) }
                target.merges.append(range)
                // A merge shows only its top-left value, so anything else in the rectangle would
                // be data the user can no longer see. Excel drops it and warns; we drop it and
                // the edit is undoable, which is a better warning.
                for ref in range where ref != range.start {
                    _ = target.cells.removeCell(at: ref)
                }
            }
        }
    }

    /// Freeze or unfreeze panes at the selection. ``SheetRegionChanges/views``.
    public static func setFrozenPanes(
        _ panes: FrozenPanes,
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection
    ) -> DocumentEdit? {
        mutateSheet(sheetID, in: &workbook, selection: selection, name: "Freeze panes", regions: .views) {
            $0.frozen = panes
        }
    }

    /// Sorts a range by one of its columns. Row-wise, so a row's cells stay together.
    public static func sort(
        _ range: CellRange,
        by column: Int,
        ascending: Bool,
        hasHeaderRow: Bool,
        on sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection
    ) -> DocumentEdit? {
        guard let sheet = workbook[sheetID], range.rowCount > 1 else { return nil }
        let firstRow = hasHeaderRow ? range.start.row + 1 : range.start.row
        guard firstRow < range.end.row else { return nil }

        let rows = (firstRow ... range.end.row).map { row in
            (row: row, key: sheet.cells[CellRef(row: row, column: column)]?.value ?? .empty)
        }
        let ordered = rows.enumerated().sorted { left, right in
            let comparison = SortKey.compare(left.element.key, right.element.key)
            if comparison == 0 { return left.offset < right.offset }
            return ascending ? comparison < 0 : comparison > 0
        }
        guard ordered.map(\.element.row) != rows.map(\.row) else { return nil }

        var values: [CellRef: Cell?] = [:]
        var formulasChanged = false
        for (destinationIndex, entry) in ordered.enumerated() {
            let destinationRow = firstRow + destinationIndex
            guard destinationRow != entry.element.row else { continue }
            for column in range.columns {
                let source = CellRef(row: entry.element.row, column: column)
                let destination = CellRef(row: destinationRow, column: column)
                let cell = sheet.cells[source]
                formulasChanged = formulasChanged || cell?.isFormula == true
                values[destination] = cell
            }
        }

        return setCells(
            values,
            on: sheetID,
            in: &workbook,
            selectionBefore: selection,
            selectionAfter: selection,
            name: ascending ? "Sort ascending" : "Sort descending",
            formulasChanged: formulasChanged
        )
    }

    // MARK: - Helpers

    /// `'Q4 sales'!$A$1:$D$20` — the spelling a defined name's `formula` uses.
    ///
    /// `A1Notation.format` writes relative references, which is right for a formula and wrong
    /// here: a defined name that is not anchored moves when it is used from a different cell.
    static func absoluteA1(sheetName: String?, range: CellRange) -> String {
        let body = range.start == range.end
            ? range.start.a1String(absoluteColumn: true, absoluteRow: true)
            : range.start.a1String(absoluteColumn: true, absoluteRow: true)
            + ":" + range.end.a1String(absoluteColumn: true, absoluteRow: true)
        guard let sheetName else { return body }
        let needsQuotes = sheetName.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        let qualifier = needsQuotes
            ? "'" + sheetName.replacingOccurrences(of: "'", with: "''") + "'"
            : sheetName
        return qualifier + "!" + body
    }

    private static func mutateSheet(
        _ sheetID: SheetID,
        in workbook: inout Workbook,
        selection: GridSelection,
        name: String,
        regions: SheetRegionChanges,
        _ body: (inout Sheet) -> Void
    ) -> DocumentEdit? {
        guard let before = workbook[sheetID] else { return nil }
        var after = before
        body(&after)
        guard after != before else { return nil }
        workbook.update(after)
        return DocumentEdit(
            payload: .sheets(before: [before], after: [after]),
            regions: regions,
            sheetBefore: sheetID,
            sheetAfter: sheetID,
            selectionBefore: selection,
            selectionAfter: selection,
            name: name
        )
    }
}

extension StructuralEdit.Kind {
    var actionName: String {
        switch self {
        case .insertRows: "Insert rows"
        case .deleteRows: "Delete rows"
        case .insertColumns: "Insert columns"
        case .deleteColumns: "Delete columns"
        }
    }
}

private extension Workbook {
    /// ``withSheet(_:_:)`` with the thrown type spelled out, so a caller in a `throws(SheetError)`
    /// function does not have to launder an `any Error`.
    mutating func withSheetTyped(
        _ id: SheetID,
        _ body: (inout Sheet) throws(SheetError) -> Void
    ) throws(SheetError) {
        guard let position = index(of: id) else {
            throw SheetError.sheetNotFound(reference: id.description)
        }
        try body(&sheets[position])
    }
}

/// Excel's cross-type ordering for a sort: numbers, then text, then booleans, then errors, then
/// blanks — blanks always last regardless of direction, which is the one part people notice.
enum SortKey {
    static func compare(_ left: CellValue, _ right: CellValue) -> Int {
        let leftRank = rank(left)
        let rightRank = rank(right)
        if leftRank != rightRank { return leftRank < rightRank ? -1 : 1 }
        switch (left, right) {
        case let (.number(a), .number(b)):
            return a == b ? 0 : (a < b ? -1 : 1)
        case let (.text(a), .text(b)):
            let order = a.localizedStandardCompare(b)
            return order == .orderedSame ? 0 : (order == .orderedAscending ? -1 : 1)
        case let (.boolean(a), .boolean(b)):
            return a == b ? 0 : (b ? -1 : 1)
        case let (.error(a), .error(b)):
            return a == b ? 0 : (a.rawValue < b.rawValue ? -1 : 1)
        default:
            return 0
        }
    }

    private static func rank(_ value: CellValue) -> Int {
        switch value {
        case .number: 0
        case .text: 1
        case .boolean: 2
        case .error: 3
        case .empty: 4
        }
    }
}
