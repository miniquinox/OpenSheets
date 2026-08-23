import Foundation
import SheetModel

/// Lookups and reference construction.
///
/// `OFFSET` and `INDIRECT` are **volatile**: their precedents are computed rather than
/// written, so no static dependency edge can describe them and the only safe thing is to
/// recompute them every pass. They are also where Excel and LibreOffice part company on error
/// kinds — `OFFSET($Z$1,-100,0)` is `#REF!` in Excel and `#VALUE!` in LibreOffice
/// (WAVE-1-ADDENDUM §4). We follow Excel.
enum LookupFunctions {
    static var signatures: [FunctionSignature] { tables + references }

    // MARK: - Table lookups

    private static let tables: [FunctionSignature] = [
        FunctionSignature("VLOOKUP", 3, 4) { call in
            let table = try call.table(1)
            let column = try call.integer(2)
            guard column >= 1 else { throw FormulaFault.cell(.wrongType) }
            guard column <= table.columnCount else { throw FormulaFault.cell(.invalidReference) }
            let approximate = try call.boolean(3, default: true)
            let keys = (0 ..< table.rowCount).map { table[$0, 0] }
            guard let row = LookupFunctions.find(try call.scalar(0), in: keys, approximate: approximate) else {
                throw FormulaFault.cell(.notAvailable)
            }
            return .scalar(table[row, column - 1])
        },
        FunctionSignature("HLOOKUP", 3, 4) { call in
            let table = try call.table(1)
            let row = try call.integer(2)
            guard row >= 1 else { throw FormulaFault.cell(.wrongType) }
            guard row <= table.rowCount else { throw FormulaFault.cell(.invalidReference) }
            let approximate = try call.boolean(3, default: true)
            let keys = (0 ..< table.columnCount).map { table[0, $0] }
            guard let column = LookupFunctions.find(try call.scalar(0), in: keys, approximate: approximate) else {
                throw FormulaFault.cell(.notAvailable)
            }
            return .scalar(table[row - 1, column])
        },
        FunctionSignature("LOOKUP", 2, 3) { call in
            let source = try call.table(1)
            let keys = LookupFunctions.flatten(source)
            guard let index = LookupFunctions.find(try call.scalar(0), in: keys, approximate: true) else {
                throw FormulaFault.cell(.notAvailable)
            }
            guard call.count > 2 else { return .scalar(keys[index]) }
            let results = LookupFunctions.flatten(try call.table(2))
            guard index < results.count else { throw FormulaFault.cell(.notAvailable) }
            return .scalar(results[index])
        },
        FunctionSignature("XLOOKUP", 3, 6, prefixed: true) { call in
            let keys = LookupFunctions.flatten(try call.table(1))
            let results = LookupFunctions.flatten(try call.table(2))
            let mode = try call.integer(4, default: 0)
            let search = try call.integer(5, default: 1)
            let index = LookupFunctions.extendedMatch(
                try call.scalar(0), in: keys, mode: mode, reversed: search == -1
            )
            guard let index, index < results.count else {
                guard call.isPresent(3) else { throw FormulaFault.cell(.notAvailable) }
                return .scalar(try call.scalar(3))
            }
            return .scalar(results[index])
        },
        FunctionSignature("MATCH", 2, 3) { call in
            let keys = LookupFunctions.flatten(try call.table(1))
            let type = try call.integer(2, default: 1)
            guard let index = LookupFunctions.match(try call.scalar(0), in: keys, type: type) else {
                throw FormulaFault.cell(.notAvailable)
            }
            return .number(Double(index + 1))
        },
        FunctionSignature("XMATCH", 2, 4, prefixed: true) { call in
            let keys = LookupFunctions.flatten(try call.table(1))
            let mode = try call.integer(2, default: 0)
            let search = try call.integer(3, default: 1)
            guard let index = LookupFunctions.extendedMatch(
                try call.scalar(0), in: keys, mode: mode, reversed: search == -1
            ) else { throw FormulaFault.cell(.notAvailable) }
            return .number(Double(index + 1))
        },
    ]

    // MARK: - Reference construction

    private static let references: [FunctionSignature] = [
        FunctionSignature("INDEX", 2, 3) { call in try LookupFunctions.index(call) },
        FunctionSignature("OFFSET", 3, 5, volatile: true) { call in
            let anchor = try call.range(0)
            let rowShift = try call.integer(1)
            let columnShift = try call.integer(2)
            let height = try call.integer(3, default: anchor.range.rowCount)
            let width = try call.integer(4, default: anchor.range.columnCount)
            guard height != 0, width != 0 else { throw FormulaFault.cell(.invalidReference) }
            let top = anchor.range.start.row + rowShift + (height < 0 ? height + 1 : 0)
            let left = anchor.range.start.column + columnShift + (width < 0 ? width + 1 : 0)
            let bottom = top + abs(height) - 1
            let right = left + abs(width) - 1
            // Excel says `#REF!` for an offset that leaves the sheet; LibreOffice says
            // `#VALUE!`. Excel wins.
            guard top >= 0, left >= 0, bottom <= Limits.maxRow, right <= Limits.maxColumn else {
                throw FormulaFault.cell(.invalidReference)
            }
            return .reference(ReferenceValue(SheetRange(
                sheet: anchor.sheet,
                range: CellRange(rows: top ... bottom, columns: left ... right)
            )))
        },
        FunctionSignature("INDIRECT", 1, 2, volatile: true) { call in
            let text = try call.text(0)
            let useA1 = try call.boolean(1, default: true)
            let reference = useA1
                ? FormulaReference(a1Text: text)
                : FormulaReference(r1c1Text: text, anchor: call.origin.ref)
            guard let reference, reference.isOnSheet, !reference.isDeleted else {
                throw FormulaFault.cell(.invalidReference)
            }
            guard reference.qualifier?.workbook == nil, reference.qualifier?.throughName == nil else {
                throw FormulaFault.cell(.invalidReference)
            }
            var sheet = call.origin.sheet
            if let name = reference.qualifier?.name {
                guard let resolved = call.scope.sheetID(named: name) else {
                    throw FormulaFault.cell(.invalidReference)
                }
                sheet = resolved
            }
            return .reference(ReferenceValue(SheetRange(sheet: sheet, range: reference.range)))
        },
        FunctionSignature("ADDRESS", 2, 5) { call in
            let row = try call.integer(0)
            let column = try call.integer(1)
            guard row >= 1, column >= 1, row <= Limits.rowCount, column <= Limits.columnCount else {
                throw FormulaFault.cell(.wrongType)
            }
            let anchoring = try call.integer(2, default: 1)
            guard (1 ... 4).contains(anchoring) else { throw FormulaFault.cell(.wrongType) }
            let ref = CellRef(row: row - 1, column: column - 1)
            let text = ref.a1String(
                absoluteColumn: anchoring == 1 || anchoring == 3,
                absoluteRow: anchoring == 1 || anchoring == 2
            )
            guard call.count > 4, call.isPresent(4) else { return .text(text) }
            return .text("\(A1Notation.quoteIfNeeded(try call.text(4)))!\(text)")
        },
    ]

    // MARK: - Matching

    /// Flattens a rectangle into a vector, reading across then down. `LOOKUP` and `MATCH` only
    /// accept a single row or column in Excel, so the order only matters for malformed input.
    static func flatten(_ table: ValueArray) -> [ScalarValue] { table.values }

    /// `VLOOKUP`/`HLOOKUP` matching.
    ///
    /// Approximate mode assumes the keys are sorted ascending, as Excel documents. Where Excel
    /// binary-searches — and therefore returns something arbitrary on unsorted data — this
    /// scans and keeps the largest key not greater than the target. On sorted data the two
    /// agree exactly; on unsorted data ours is defensible and Excel's is not defined.
    static func find(_ target: ScalarValue, in keys: [ScalarValue], approximate: Bool) -> Int? {
        guard approximate else { return exactMatch(target, in: keys) }
        var best: Int?
        for (index, key) in keys.enumerated() {
            if key.isError { continue }
            guard case let .success(order) = Coercion.compare(key, target) else { continue }
            if order <= 0 { best = index } else { break }
        }
        return best
    }

    static func exactMatch(_ target: ScalarValue, in keys: [ScalarValue]) -> Int? {
        if case let .text(pattern) = target {
            let wildcard = WildcardPattern(pattern)
            if wildcard.hasWildcards {
                return keys.firstIndex(where: { key in
                    guard case let .text(text) = key else { return false }
                    return wildcard.matches(text)
                })
            }
        }
        return keys.firstIndex(where: { key in
            guard case let .success(equal) = Coercion.equals(key, target) else { return false }
            return equal
        })
    }

    /// `MATCH`'s three modes: `1` largest ≤ (ascending), `0` exact, `-1` smallest ≥ (descending).
    static func match(_ target: ScalarValue, in keys: [ScalarValue], type: Int) -> Int? {
        switch type {
        case 0: return exactMatch(target, in: keys)
        case 1: return find(target, in: keys, approximate: true)
        default:
            var best: Int?
            for (index, key) in keys.enumerated() {
                if key.isError { continue }
                guard case let .success(order) = Coercion.compare(key, target) else { continue }
                if order >= 0 { best = index } else { break }
            }
            return best
        }
    }

    /// `XLOOKUP`/`XMATCH` matching: mode `0` exact, `-1` exact-or-next-smaller, `1`
    /// exact-or-next-larger, `2` wildcard.
    static func extendedMatch(_ target: ScalarValue, in keys: [ScalarValue], mode: Int, reversed: Bool) -> Int? {
        let order = reversed ? Array(keys.indices).reversed().map { $0 } : Array(keys.indices)
        if mode == 0 || mode == 2 {
            for index in order {
                if mode == 2, case let .text(pattern) = target, case let .text(text) = keys[index] {
                    if WildcardPattern(pattern).matches(text) { return index }
                    continue
                }
                if case let .success(equal) = Coercion.equals(keys[index], target), equal { return index }
            }
            return nil
        }
        var best: Int?
        var bestValue: ScalarValue?
        for index in order {
            guard case let .success(comparison) = Coercion.compare(keys[index], target) else { continue }
            if comparison == 0 { return index }
            let acceptable = mode < 0 ? comparison < 0 : comparison > 0
            guard acceptable else { continue }
            guard let current = bestValue else {
                best = index
                bestValue = keys[index]
                continue
            }
            guard case let .success(against) = Coercion.compare(keys[index], current) else { continue }
            if mode < 0 ? against > 0 : against < 0 {
                best = index
                bestValue = keys[index]
            }
        }
        return best
    }

    // MARK: - INDEX

    private static func index(_ call: FunctionCallSite) throws -> FormulaValue {
        let rowArgument = try call.integer(1)
        let columnArgument = try call.integer(2, default: 0)
        guard rowArgument >= 0, columnArgument >= 0 else { throw FormulaFault.cell(.wrongType) }

        if case let .reference(reference) = call.arguments[0], let part = reference.singleRange {
            let rectangle = part.range
            let (row, column) = try resolveIndex(
                rowArgument, columnArgument,
                rows: rectangle.rowCount, columns: rectangle.columnCount, hasColumnArgument: call.count > 2
            )
            let target = CellRef(row: rectangle.start.row + row, column: rectangle.start.column + column)
            return .reference(ReferenceValue(SheetRange(sheet: part.sheet, range: CellRange(target))))
        }

        let table = try call.table(0)
        let (row, column) = try resolveIndex(
            rowArgument, columnArgument,
            rows: table.rowCount, columns: table.columnCount, hasColumnArgument: call.count > 2
        )
        return .scalar(table[row, column])
    }

    private static func resolveIndex(
        _ rowArgument: Int, _ columnArgument: Int, rows: Int, columns: Int, hasColumnArgument: Bool
    ) throws -> (row: Int, column: Int) {
        // A one-dimensional range indexes along its long axis with a single argument, which is
        // why `INDEX(A1:A6,3)` is `A3` and `INDEX(A1:F1,3)` is `C1`.
        if !hasColumnArgument, rows == 1, columns > 1 {
            guard rowArgument >= 1, rowArgument <= columns else { throw FormulaFault.cell(.invalidReference) }
            return (0, rowArgument - 1)
        }
        let row = rowArgument == 0 ? 1 : rowArgument
        let column = columnArgument == 0 ? 1 : columnArgument
        guard row >= 1, row <= rows, column >= 1, column <= columns else {
            throw FormulaFault.cell(.invalidReference)
        }
        return (row - 1, column - 1)
    }
}
