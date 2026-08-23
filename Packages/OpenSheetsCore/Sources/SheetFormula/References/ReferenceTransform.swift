import Foundation
import SheetModel

/// A row or column insert or delete, as the thing that rewrites formulas sees it.
public struct StructuralEdit: Sendable, Hashable {
    /// Which operation, on which axis.
    public enum Kind: String, Sendable, Hashable, CaseIterable, Codable {
        case insertRows, deleteRows, insertColumns, deleteColumns

        /// Whether this edit adds lines rather than removing them.
        public var isInsert: Bool { self == .insertRows || self == .insertColumns }
        /// Whether this edit works on rows.
        public var isRowAxis: Bool { self == .insertRows || self == .deleteRows }
    }

    /// The operation.
    public var kind: Kind
    /// The sheet being edited. References to other sheets are untouched.
    public var sheet: SheetID
    /// 0-based index of the first row or column inserted or deleted.
    public var index: Int
    /// How many rows or columns.
    public var count: Int

    public init(kind: Kind, sheet: SheetID, index: Int, count: Int) {
        self.kind = kind
        self.sheet = sheet
        self.index = index
        self.count = count
    }

    public static func insertRows(at index: Int, count: Int = 1, on sheet: SheetID) -> StructuralEdit {
        StructuralEdit(kind: .insertRows, sheet: sheet, index: index, count: count)
    }

    public static func deleteRows(at index: Int, count: Int = 1, on sheet: SheetID) -> StructuralEdit {
        StructuralEdit(kind: .deleteRows, sheet: sheet, index: index, count: count)
    }

    public static func insertColumns(at index: Int, count: Int = 1, on sheet: SheetID) -> StructuralEdit {
        StructuralEdit(kind: .insertColumns, sheet: sheet, index: index, count: count)
    }

    public static func deleteColumns(at index: Int, count: Int = 1, on sheet: SheetID) -> StructuralEdit {
        StructuralEdit(kind: .deleteColumns, sheet: sheet, index: index, count: count)
    }
}

/// How to turn a sheet name in a formula into a ``SheetID``.
///
/// A value rather than a closure so the whole transform stays `Sendable` and testable without
/// a workbook. `owner` is the sheet the formula lives on, which is what an unqualified `A1`
/// means.
public struct SheetResolution: Sendable, Hashable {
    /// The sheet the formula being transformed lives on.
    public var owner: SheetID
    /// Uppercased sheet name → id. Names Excel treats case-insensitively, so does this.
    public var identifiers: [String: SheetID]

    public init(owner: SheetID, identifiers: [String: SheetID] = [:]) {
        self.owner = owner
        self.identifiers = identifiers
    }

    /// Every sheet in `workbook`, with `owner` as the formula's home sheet.
    public init(owner: SheetID, workbook: Workbook) {
        self.owner = owner
        var table: [String: SheetID] = [:]
        for sheet in workbook.sheets { table[sheet.name.uppercased()] = sheet.id }
        identifiers = table
    }

    /// The sheet a reference points at, or `nil` when the name is unknown.
    public func resolve(_ qualifier: SheetQualifier?) -> SheetID? {
        guard let qualifier else { return owner }
        guard !qualifier.isExternal, !qualifier.isThreeDimensional else { return nil }
        return identifiers[qualifier.name.uppercased()]
    }
}

/// The outcome of rewriting one formula.
public struct ReferenceTransformResult: Sendable, Hashable {
    /// The rewritten formula, without a leading `=`.
    public var formula: String
    /// The rewritten tree, for callers that want to keep going without re-parsing.
    public var expression: FormulaExpression
    /// How many references the edit destroyed. Non-zero means the formula now contains
    /// `#REF!` and will evaluate to `#REF!` — which is the honest outcome, and the one Excel
    /// produces.
    public var invalidatedReferences: Int
    /// Whether anything changed at all. `false` lets a caller skip a write.
    public var didChange: Bool
}

/// Reference algebra: what happens to a formula when the grid moves under it.
///
/// Four operations, and they are genuinely different:
///
/// - ``adjust(formula:for:resolving:grammar:)`` — a row or column was inserted or deleted.
///   References to *targets* move. Anchoring is irrelevant here: `$A$5` becomes `$A$6` on an
///   insert exactly as `A5` does, because a `$` means "do not shift when copied", not "do not
///   shift ever". Getting that backwards is the classic reference-algebra bug.
/// - ``translate(formula:from:to:grammar:)`` — the formula was copied or filled. Now anchoring
///   is everything: relative coordinates move by the delta, absolute ones do not.
/// - ``move(formula:movedRange:rowDelta:columnDelta:resolving:grammar:)`` — a block was cut and
///   pasted elsewhere. References *into* the block follow it; everything else stays.
/// - The `#REF!` cases. A reference whose target no longer exists must become `#REF!` and must
///   not be quietly clamped to the nearest surviving cell, which would turn a broken formula
///   into a wrong one.
public enum ReferenceTransform {
    // MARK: - Structural edits

    /// Rewrites a formula for a row or column insert or delete.
    public static func adjust(
        formula source: String,
        for edit: StructuralEdit,
        resolving sheets: SheetResolution,
        grammar: FormulaGrammar = .default
    ) throws(SheetError) -> ReferenceTransformResult {
        try rewrite(source, grammar: grammar) { reference in
            adjust(reference, for: edit, resolving: sheets)
        }
    }

    /// Rewrites one reference for a structural edit, returning a `#REF!` reference when the
    /// edit destroyed it.
    public static func adjust(
        _ reference: FormulaReference, for edit: StructuralEdit, resolving sheets: SheetResolution
    ) -> FormulaReference {
        guard !reference.isDeleted else { return reference }
        guard let target = sheets.resolve(reference.qualifier), target == edit.sheet else { return reference }

        var result = reference
        if edit.kind.isRowAxis {
            // A whole-column reference already spans every row, so inserting or deleting rows
            // cannot change it — and expanding it would push it off the sheet.
            guard reference.shape != .columns else { return reference }
            guard let (start, end) = shift(
                reference.start.row, reference.end.row, edit: edit, limit: Limits.maxRow
            ) else { return .deleted(qualifier: reference.qualifier) }
            result.start.row = start
            result.end.row = end
        } else {
            guard reference.shape != .rows else { return reference }
            guard let (start, end) = shift(
                reference.start.column, reference.end.column, edit: edit, limit: Limits.maxColumn
            ) else { return .deleted(qualifier: reference.qualifier) }
            result.start.column = start
            result.end.column = end
        }
        return result
    }

    /// Rewrites a plain rectangle for a structural edit — for defined names, merges, and the
    /// MCP insert/delete path, none of which go through formula text.
    public static func adjust(_ range: CellRange, on sheet: SheetID, for edit: StructuralEdit) -> CellRange? {
        guard sheet == edit.sheet else { return range }
        if edit.kind.isRowAxis {
            guard let (start, end) = shift(range.start.row, range.end.row, edit: edit, limit: Limits.maxRow) else {
                return nil
            }
            return CellRange(rows: start ... end, columns: range.columns)
        }
        guard let (start, end) = shift(
            range.start.column, range.end.column, edit: edit, limit: Limits.maxColumn
        ) else { return nil }
        return CellRange(rows: range.rows, columns: start ... end)
    }

    /// The core one-axis rule. `nil` means the span was deleted out of existence.
    static func shift(_ start: Int, _ end: Int, edit: StructuralEdit, limit: Int) -> (Int, Int)? {
        guard edit.count > 0 else { return (start, end) }
        if edit.kind.isInsert {
            let newStart = start >= edit.index ? start + edit.count : start
            let newEnd = end >= edit.index ? end + edit.count : end
            // Excel refuses an insert that would push data off the sheet; if a caller does it
            // anyway, the reference is gone rather than silently clamped.
            guard newStart <= limit else { return nil }
            return (newStart, Swift.min(newEnd, limit))
        }
        let last = edit.index + edit.count - 1
        let newStart = start > last ? start - edit.count : (start >= edit.index ? edit.index : start)
        let newEnd = end > last ? end - edit.count : (end >= edit.index ? edit.index - 1 : end)
        guard newEnd >= newStart, newStart >= 0 else { return nil }
        return (newStart, newEnd)
    }

    // MARK: - Copy and fill

    /// Rewrites a formula that has been copied from `origin` to `destination`.
    ///
    /// This is fill-down, fill-right, and paste. Relative coordinates move by the delta;
    /// `$`-anchored ones do not; a relative coordinate that would land off the grid becomes
    /// `#REF!`.
    public static func translate(
        formula source: String,
        from origin: CellRef,
        to destination: CellRef,
        grammar: FormulaGrammar = .default
    ) throws(SheetError) -> ReferenceTransformResult {
        let rows = destination.row - origin.row
        let columns = destination.column - origin.column
        return try rewrite(source, anchor: origin, grammar: grammar) { reference in
            translate(reference, rows: rows, columns: columns)
        }
    }

    /// Moves one reference's relative coordinates by a delta.
    public static func translate(_ reference: FormulaReference, rows: Int, columns: Int) -> FormulaReference {
        guard !reference.isDeleted else { return reference }
        var result = reference
        if reference.shape != .columns {
            if !reference.start.rowIsAbsolute { result.start.row += rows }
            if !reference.end.rowIsAbsolute { result.end.row += rows }
        }
        if reference.shape != .rows {
            if !reference.start.columnIsAbsolute { result.start.column += columns }
            if !reference.end.columnIsAbsolute { result.end.column += columns }
        }
        guard result.isOnSheet else { return .deleted(qualifier: reference.qualifier) }
        return result
    }

    // MARK: - Cut and paste

    /// Rewrites a formula after a block of cells was moved.
    ///
    /// A reference that lies **entirely inside** the moved block follows it; anything else is
    /// left alone. Excel also rewrites references that partially overlap the block, in a way
    /// that depends on the direction of the move; we do not, and a partially overlapping
    /// reference keeps pointing where it pointed. That is a knowing divergence, and it is the
    /// conservative half of it: we never move a reference the user did not move.
    public static func move(
        formula source: String,
        movedRange: SheetRange,
        rowDelta: Int,
        columnDelta: Int,
        resolving sheets: SheetResolution,
        grammar: FormulaGrammar = .default
    ) throws(SheetError) -> ReferenceTransformResult {
        try rewrite(source, grammar: grammar) { reference in
            guard !reference.isDeleted,
                  let target = sheets.resolve(reference.qualifier), target == movedRange.sheet,
                  reference.shape == .cells,
                  movedRange.range.contains(reference.range)
            else { return reference }
            var result = reference
            result.start.row += rowDelta
            result.end.row += rowDelta
            result.start.column += columnDelta
            result.end.column += columnDelta
            guard result.isOnSheet else { return .deleted(qualifier: reference.qualifier) }
            return result
        }
    }

    // MARK: - Anchoring

    /// Cycles a reference through Excel's four anchoring states, which is what F4 does.
    public static func cycleAnchoring(_ reference: FormulaReference) -> FormulaReference {
        var result = reference
        let both = reference.start.rowIsAbsolute && reference.start.columnIsAbsolute
        let rowOnly = reference.start.rowIsAbsolute && !reference.start.columnIsAbsolute
        let columnOnly = !reference.start.rowIsAbsolute && reference.start.columnIsAbsolute
        let next: (row: Bool, column: Bool)
        if both {
            next = (true, false)
        } else if rowOnly {
            next = (false, true)
        } else if columnOnly {
            next = (false, false)
        } else {
            next = (true, true)
        }
        result.start.rowIsAbsolute = next.row
        result.start.columnIsAbsolute = next.column
        result.end.rowIsAbsolute = next.row
        result.end.columnIsAbsolute = next.column
        return result
    }

    // MARK: - Plumbing

    /// Parses, maps every reference node, and writes back — the shared body of all three
    /// transforms. Uses the iterative rebuild so a 4,000-term formula cannot overflow.
    static func rewrite(
        _ source: String,
        anchor: CellRef = .origin,
        grammar: FormulaGrammar = .default,
        _ transform: (FormulaReference) -> FormulaReference
    ) throws(SheetError) -> ReferenceTransformResult {
        let expression = try FormulaParser.parse(source, anchor: anchor, grammar: grammar)
        var invalidated = 0
        let rewritten = expression.rebuilding { node in
            guard case let .reference(reference) = node else { return node }
            let mapped = transform(reference)
            if mapped.isDeleted, !reference.isDeleted { invalidated += 1 }
            return .reference(mapped)
        }
        let text = FormulaWriter.write(rewritten, format: FormulaFormat(anchor: anchor, usesStoragePrefixes: true))
        return ReferenceTransformResult(
            formula: text,
            expression: rewritten,
            invalidatedReferences: invalidated,
            didChange: rewritten != expression
        )
    }
}
