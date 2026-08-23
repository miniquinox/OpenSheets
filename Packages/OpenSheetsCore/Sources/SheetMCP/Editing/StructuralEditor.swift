import Foundation
import SheetFormat
import SheetFormula
import SheetModel

/// Row and column inserts and deletes, with the formula rewrite that has to accompany them.
///
/// # Why this is not just `sheet.insertRows`
///
/// `Sheet.insertRows(at:count:)` moves cells, merges, hyperlinks, row sizes and the filter
/// range — everything the model knows about. What it explicitly does not do, because it cannot
/// without a parser, is rewrite *formula text*. Insert a row above `=SUM(A2:A9)` and the model
/// alone leaves a formula that now sums the wrong nine cells: no error, no warning, a wrong
/// number in a total. So this pass runs A3's ``SheetFormula/ReferenceTransform`` over every
/// formula in the **whole workbook** — cross-sheet references break just as quietly — and over
/// every defined name.
///
/// A formula that will not parse is left exactly as written and counted. Rewriting what we
/// could not read would be worse than leaving it, and silently dropping it would be worse
/// still; the tool result says how many there were.
public enum StructuralEditor {
    /// What one structural edit did.
    public struct Report: Sendable, Hashable {
        /// Formulas whose text changed.
        public var rewrittenFormulas = 0
        /// Formulas that now contain `#REF!` because the edit destroyed what they pointed at.
        public var invalidatedReferences = 0
        /// Formulas the parser could not read, left untouched.
        public var unparsedFormulas = 0
        /// Defined names whose target moved.
        public var rewrittenNames = 0
        /// Defined names the edit destroyed.
        public var brokenNames = 0
    }

    /// A contiguous run of rows or columns.
    public struct Band: Sendable, Hashable {
        public var start: Int
        public var count: Int
    }

    /// Groups sorted indices into contiguous bands.
    ///
    /// Deleting 400 scattered rows one at a time means 400 full-workbook formula rewrites.
    /// Coalescing first turns the common case — a filter that matched a contiguous block —
    /// into one.
    public static func bands(rows: [Int]) -> [Band] {
        let sorted = Set(rows).sorted()
        var result: [Band] = []
        for row in sorted {
            if var last = result.last, last.start + last.count == row {
                last.count += 1
                result[result.count - 1] = last
            } else {
                result.append(Band(start: row, count: 1))
            }
        }
        return result
    }

    /// Applies one edit to `workbook`, marking exactly what changed.
    @discardableResult
    public static func apply(
        _ edit: StructuralEdit,
        to workbook: inout Workbook,
        edits: inout WorkbookEditTracker
    ) throws(SheetError) -> Report {
        guard let index = workbook.index(of: edit.sheet) else {
            throw SheetError.sheetNotFound(reference: "\(edit.sheet.rawValue)")
        }
        guard edit.count > 0 else {
            throw SheetError.invalidArgument(name: "count", reason: "it must be 1 or more")
        }
        guard edit.index >= 0 else {
            throw SheetError.invalidArgument(name: "at", reason: "it must be 1 or more")
        }
        let limit = edit.kind.isRowAxis ? Limits.maxRow : Limits.maxColumn
        guard edit.index <= limit else {
            throw SheetError.invalidArgument(
                name: "at", reason: "the sheet stops at \(edit.kind.isRowAxis ? "row" : "column") \(limit + 1)"
            )
        }

        switch edit.kind {
        case .insertRows: try workbook.sheets[index].insertRows(at: edit.index, count: edit.count)
        case .deleteRows: try workbook.sheets[index].deleteRows(at: edit.index, count: edit.count)
        case .insertColumns: try workbook.sheets[index].insertColumns(at: edit.index, count: edit.count)
        case .deleteColumns: try workbook.sheets[index].deleteColumns(at: edit.index, count: edit.count)
        }

        var report = Report()
        rewriteFormulas(in: &workbook, for: edit, report: &report)
        rewriteDefinedNames(in: &workbook, for: edit, report: &report)

        // §2 of the Wave 2 addendum: the writer copies through everything not named here. An
        // insert moves rows, merges, hyperlinks and the filter range, so all four are named —
        // and `.columns` only for a column edit, because regenerating `<cols>` after a *row*
        // insert would rewrite widths the edit never touched.
        var regions: SheetRegionChanges = [.cells, .merges, .hyperlinks, .autoFilter]
        regions.insert(edit.kind.isRowAxis ? .rows : .columns)
        edits.note(workbook.sheets[index], regions)
        if report.rewrittenFormulas > 0 || report.invalidatedReferences > 0 {
            for sheet in workbook.sheets where sheet.id != edit.sheet {
                edits.noteCellsChanged(in: sheet, formulasChanged: true)
            }
        }
        edits.noteCellsChanged(in: workbook.sheets[index], formulasChanged: true)
        if report.rewrittenNames > 0 || report.brokenNames > 0 {
            edits.noteWorkbookMetadataChanged()
        }
        return report
    }

    // MARK: - Formulas

    private static func rewriteFormulas(
        in workbook: inout Workbook,
        for edit: StructuralEdit,
        report: inout Report
    ) {
        let resolutions = workbook.sheets.reduce(into: [SheetID: SheetResolution]()) { map, sheet in
            map[sheet.id] = SheetResolution(owner: sheet.id, workbook: workbook)
        }
        for sheetIndex in workbook.sheets.indices {
            guard let resolution = resolutions[workbook.sheets[sheetIndex].id] else { continue }
            guard let used = workbook.sheets[sheetIndex].cells.usedRange else { continue }
            var replacements: [(CellRef, Cell)] = []
            workbook.sheets[sheetIndex].cells.forEachCell(in: used) { ref, cell in
                guard let source = cell.formula else { return }
                guard let result = try? ReferenceTransform.adjust(
                    formula: source, for: edit, resolving: resolution
                ) else {
                    report.unparsedFormulas += 1
                    return
                }
                report.invalidatedReferences += result.invalidatedReferences
                guard result.didChange else { return }
                report.rewrittenFormulas += 1
                var updated = cell
                updated.formula = result.formula
                // The cached value belongs to the old references. Marking it stale is what
                // makes A4 render it as stale rather than as a number somebody might trust,
                // and `fullCalcOnLoad` is what makes Excel replace it.
                updated.flags.insert(.staleCache)
                replacements.append((ref, updated))
            }
            for (ref, cell) in replacements {
                try? workbook.sheets[sheetIndex].cells.setCell(cell, at: ref)
            }
        }
    }

    private static func rewriteDefinedNames(
        in workbook: inout Workbook,
        for edit: StructuralEdit,
        report: inout Report
    ) {
        guard !workbook.definedNames.isEmpty else { return }
        let resolution = SheetResolution(owner: edit.sheet, workbook: workbook)
        for (key, name) in workbook.definedNames {
            guard let result = try? ReferenceTransform.adjust(
                formula: name.formula, for: edit, resolving: resolution
            ), result.didChange else { continue }
            var updated = name
            updated.formula = result.formula
            if let target = name.target {
                let sheet = target.sheet ?? edit.sheet
                if let moved = ReferenceTransform.adjust(target.range, on: sheet, for: edit) {
                    updated.target = RangeReference(sheet: target.sheet, range: moved)
                } else {
                    updated.target = nil
                    report.brokenNames += 1
                }
            }
            workbook.definedNames[key] = updated
            report.rewrittenNames += 1
        }
    }
}
