import Foundation
import SheetModel

/// The dynamic-array family: functions whose result is a rectangle rather than a value.
///
/// Nothing here knows about the grid. A function returns a ``ValueArray`` and `FormulaEngine`
/// decides whether it spills, is consumed by an enclosing function, or collides with something
/// and becomes `#SPILL!`. That split is what makes `COUNT(FILTER(…))` work identically whether
/// or not the sheet has room for the filtered rows.
///
/// # The result-size ceiling
///
/// Every builder here goes through ``checkedSize(rows:columns:call:)``. `SEQUENCE(1e9)` is a
/// formula a user can type, and an engine that tries to honour it allocates until the process
/// dies. `#NUM!` is the honest answer and the one Excel gives.
enum ArrayFunctions {
    static var signatures: [FunctionSignature] {
        generators + filtering + ordering + stacking + reshaping
    }

    /// The most cells one array result may hold.
    ///
    /// A whole column, which is also the most that could ever spill onto a sheet. Anything
    /// larger is a mistake in the formula rather than an intention.
    static let maximumResultCells = Limits.rowCount

    static func checkedSize(rows: Int, columns: Int) throws -> (rows: Int, columns: Int) {
        guard rows > 0, columns > 0 else { throw FormulaFault.cell(.calculation) }
        guard rows <= Limits.rowCount, columns <= Limits.columnCount,
              rows * columns <= maximumResultCells
        else { throw FormulaFault.cell(.invalidNumber) }
        return (rows, columns)
    }

    // MARK: - Generators

    private static let generators: [FunctionSignature] = [
        FunctionSignature("SEQUENCE", 1, 4, prefixed: true) { call in
            let rows = try call.integer(0)
            let columns = try call.integer(1, default: 1)
            let start = try call.number(2, default: 1)
            let step = try call.number(3, default: 1)
            let size = try checkedSize(rows: rows, columns: columns)
            var values: [ScalarValue] = []
            values.reserveCapacity(size.rows * size.columns)
            for index in 0 ..< (size.rows * size.columns) {
                values.append(.number(start + Double(index) * step))
            }
            return .array(ValueArray(rowCount: size.rows, columnCount: size.columns, values: values))
        },
        FunctionSignature("RANDARRAY", 0, 5, volatile: true, prefixed: true) { call in
            let rows = try call.integer(0, default: 1)
            let columns = try call.integer(1, default: 1)
            let minimum = try call.number(2, default: 0)
            let maximum = try call.number(3, default: 1)
            let whole = try call.boolean(4, default: false)
            guard maximum >= minimum else { throw FormulaFault.cell(.wrongType) }
            let size = try checkedSize(rows: rows, columns: columns)
            var values: [ScalarValue] = []
            values.reserveCapacity(size.rows * size.columns)
            for _ in 0 ..< (size.rows * size.columns) {
                let sample = call.scope.nextRandom()
                if whole {
                    let low = minimum.rounded(.up)
                    let high = maximum.rounded(.down)
                    guard high >= low else { throw FormulaFault.cell(.wrongType) }
                    values.append(.number((low + (high - low + 1) * sample).rounded(.down)))
                } else {
                    values.append(.number(minimum + (maximum - minimum) * sample))
                }
            }
            return .array(ValueArray(rowCount: size.rows, columnCount: size.columns, values: values))
        },
    ]

    // MARK: - Filtering and de-duplication

    private static let filtering: [FunctionSignature] = [
        FunctionSignature("FILTER", 2, 3, prefixed: true) { call in
            let source = try call.table(0)
            let mask = try call.table(1)
            // The mask is a column when it selects rows and a row when it selects columns.
            // Excel decides from the mask's shape, not from the source's — so a 1×n mask over
            // an n×1 source filters *columns* and gives `#VALUE!`, which is the right answer.
            let byRow = mask.columnCount == 1
            let expected = byRow ? source.rowCount : source.columnCount
            let actual = byRow ? mask.rowCount : mask.columnCount
            guard actual == expected else { throw FormulaFault.cell(.wrongType) }

            var kept: [Int] = []
            for index in 0 ..< expected {
                let flag = byRow ? mask[index, 0] : mask[0, index]
                if let error = flag.errorValue { throw FormulaFault.cell(error) }
                switch Coercion.boolean(flag) {
                case let .success(value) where value: kept.append(index)
                case .success: continue
                case let .failure(error): throw FormulaFault.cell(error)
                }
            }
            guard !kept.isEmpty else {
                guard call.isPresent(2) else { throw FormulaFault.cell(.calculation) }
                return call.arguments[2]
            }
            if byRow {
                let rows = kept.map { row in (0 ..< source.columnCount).map { source[row, $0] } }
                return .array(ValueArray(rows: rows))
            }
            let rows = (0 ..< source.rowCount).map { row in kept.map { source[row, $0] } }
            return .array(ValueArray(rows: rows))
        },
        FunctionSignature("UNIQUE", 1, 3, prefixed: true) { call in
            let source = try call.table(0)
            let byColumn = try call.boolean(1, default: false)
            let exactlyOnce = try call.boolean(2, default: false)
            let lines = byColumn ? source.columnsOfValues : source.rowsOfValues

            var order: [[ScalarValue]] = []
            var counts: [Int] = []
            for line in lines {
                if let position = order.firstIndex(where: { same($0, line) }) {
                    counts[position] += 1
                } else {
                    order.append(line)
                    counts.append(1)
                }
            }
            let kept = order.indices.filter { !exactlyOnce || counts[$0] == 1 }.map { order[$0] }
            guard !kept.isEmpty else { throw FormulaFault.cell(.calculation) }
            if byColumn {
                let rows = (0 ..< source.rowCount).map { row in kept.map { $0[row] } }
                return .array(ValueArray(rows: rows))
            }
            return .array(ValueArray(rows: kept))
        },
    ]

    /// Whether two rows (or columns) are the same for `UNIQUE`, which compares text without
    /// regard to case exactly as `=` does.
    private static func same(_ lhs: [ScalarValue], _ rhs: [ScalarValue]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices {
            guard case let .success(equal) = Coercion.equals(lhs[index], rhs[index]), equal else {
                return false
            }
        }
        return true
    }

    // MARK: - Ordering

    private static let ordering: [FunctionSignature] = [
        FunctionSignature("SORT", 1, 4, prefixed: true) { call in
            let source = try call.table(0)
            let index = try call.integer(1, default: 1)
            let order = try call.integer(2, default: 1)
            let byColumn = try call.boolean(3, default: false)
            guard order == 1 || order == -1 else { throw FormulaFault.cell(.wrongType) }
            let lines = byColumn ? source.columnsOfValues : source.rowsOfValues
            let width = byColumn ? source.rowCount : source.columnCount
            guard index >= 1, index <= width else { throw FormulaFault.cell(.wrongType) }
            let keys = lines.map { [$0[index - 1]] }
            let sorted = stableOrder(count: lines.count, keys: keys, orders: [order]).map { lines[$0] }
            return .array(assemble(sorted, byColumn: byColumn, otherAxis: source.rowCount))
        },
        FunctionSignature("SORTBY", 3, .max, prefixed: true) { call in
            let source = try call.table(0)
            var keyColumns: [[ScalarValue]] = []
            var orders: [Int] = []
            var argument = 1
            while argument < call.count {
                let by = try call.table(argument)
                guard by.rowCount == source.rowCount || by.columnCount == source.rowCount else {
                    throw FormulaFault.cell(.wrongType)
                }
                keyColumns.append(by.rowCount >= by.columnCount
                    ? (0 ..< by.rowCount).map { by[$0, 0] }
                    : (0 ..< by.columnCount).map { by[0, $0] })
                let order = argument + 1 < call.count ? try call.integer(argument + 1) : 1
                guard order == 1 || order == -1 else { throw FormulaFault.cell(.wrongType) }
                orders.append(order)
                argument += 2
            }
            guard !keyColumns.isEmpty else { throw FormulaFault.cell(.wrongType) }
            let rows = source.rowsOfValues
            let keys = rows.indices.map { row in keyColumns.map { $0[row] } }
            let sorted = stableOrder(count: rows.count, keys: keys, orders: orders).map { rows[$0] }
            return .array(ValueArray(rows: sorted))
        },
    ]

    /// A stable ordering of `count` items by their key tuples.
    ///
    /// Stable on purpose and stated here rather than left to `sorted(by:)`'s implementation:
    /// `SORT` over a column with ties must leave the tied rows in their original order, or two
    /// runs of the same workbook produce two different sheets.
    private static func stableOrder(count: Int, keys: [[ScalarValue]], orders: [Int]) -> [Int] {
        Array(0 ..< count).sorted { left, right in
            for (position, order) in orders.enumerated() {
                let comparison = compare(keys[left][position], keys[right][position]) * order
                if comparison != 0 { return comparison < 0 }
            }
            return left < right
        }
    }

    /// Excel's sort order: numbers, then text, then `FALSE`, then `TRUE`, then errors, with
    /// blanks always last regardless of direction.
    static func compare(_ lhs: ScalarValue, _ rhs: ScalarValue) -> Int {
        if case .blank = lhs { if case .blank = rhs { return 0 } else { return 1 } }
        if case .blank = rhs { return -1 }
        let leftRank = lhs.comparisonRank
        let rightRank = rhs.comparisonRank
        if leftRank != rightRank { return leftRank < rightRank ? -1 : 1 }
        switch (lhs, rhs) {
        case let (.number(a), .number(b)): return a == b ? 0 : (a < b ? -1 : 1)
        case let (.text(a), .text(b)): return Coercion.orderText(a, b)
        case let (.boolean(a), .boolean(b)): return a == b ? 0 : (a ? 1 : -1)
        case let (.error(a), .error(b)): return a == b ? 0 : (a.rawValue < b.rawValue ? -1 : 1)
        default: return 0
        }
    }

    private static func assemble(_ lines: [[ScalarValue]], byColumn: Bool, otherAxis: Int) -> ValueArray {
        guard byColumn else { return ValueArray(rows: lines) }
        let rows = (0 ..< otherAxis).map { row in lines.map { $0[row] } }
        return ValueArray(rows: rows)
    }

    // MARK: - Stacking

    private static let stacking: [FunctionSignature] = [
        FunctionSignature("VSTACK", 1, .max, prefixed: true) { call in
            var blocks: [ValueArray] = []
            for index in 0 ..< call.count { blocks.append(try call.table(index)) }
            let width = blocks.map(\.columnCount).max() ?? 0
            var rows: [[ScalarValue]] = []
            for block in blocks {
                for row in block.rowsOfValues {
                    rows.append(row + Array(repeating: .error(.notAvailable), count: width - row.count))
                }
            }
            _ = try checkedSize(rows: rows.count, columns: width)
            return .array(ValueArray(rows: rows))
        },
        FunctionSignature("HSTACK", 1, .max, prefixed: true) { call in
            var blocks: [ValueArray] = []
            for index in 0 ..< call.count { blocks.append(try call.table(index)) }
            let height = blocks.map(\.rowCount).max() ?? 0
            let width = blocks.reduce(0) { $0 + $1.columnCount }
            _ = try checkedSize(rows: height, columns: width)
            var rows: [[ScalarValue]] = []
            for row in 0 ..< height {
                var line: [ScalarValue] = []
                for block in blocks {
                    if row < block.rowCount {
                        line += (0 ..< block.columnCount).map { block[row, $0] }
                    } else {
                        line += Array(repeating: .error(.notAvailable), count: block.columnCount)
                    }
                }
                rows.append(line)
            }
            return .array(ValueArray(rows: rows))
        },
        FunctionSignature("TRANSPOSE", 1, 1) { call in
            let source = try call.table(0)
            return .array(ValueArray(rows: source.columnsOfValues))
        },
    ]

    // MARK: - Reshaping

    private static let reshaping: [FunctionSignature] = [
        FunctionSignature("TOROW", 1, 3, prefixed: true) { call in
            .array(ValueArray(row: try flatten(call)))
        },
        FunctionSignature("TOCOL", 1, 3, prefixed: true) { call in
            .array(ValueArray(column: try flatten(call)))
        },
        FunctionSignature("TAKE", 2, 3, prefixed: true) { call in
            let source = try call.table(0)
            let rows = try slice(count: source.rowCount, take: try call.integer(1, default: source.rowCount))
            let columns = try slice(
                count: source.columnCount,
                take: call.isPresent(2) ? try call.integer(2) : source.columnCount
            )
            return .array(ValueArray(rows: rows.map { row in columns.map { source[row, $0] } }))
        },
        FunctionSignature("DROP", 2, 3, prefixed: true) { call in
            let source = try call.table(0)
            let rows = try remainder(count: source.rowCount, drop: try call.integer(1, default: 0))
            let columns = try remainder(
                count: source.columnCount, drop: call.isPresent(2) ? try call.integer(2) : 0
            )
            return .array(ValueArray(rows: rows.map { row in columns.map { source[row, $0] } }))
        },
        FunctionSignature("CHOOSEROWS", 2, .max, prefixed: true) { call in
            let source = try call.table(0)
            var rows: [[ScalarValue]] = []
            for index in 1 ..< call.count {
                for element in try call.table(index).values {
                    let position = try axisIndex(element, count: source.rowCount)
                    rows.append((0 ..< source.columnCount).map { source[position, $0] })
                }
            }
            guard !rows.isEmpty else { throw FormulaFault.cell(.wrongType) }
            return .array(ValueArray(rows: rows))
        },
        FunctionSignature("CHOOSECOLS", 2, .max, prefixed: true) { call in
            let source = try call.table(0)
            var chosen: [Int] = []
            for index in 1 ..< call.count {
                for element in try call.table(index).values {
                    chosen.append(try axisIndex(element, count: source.columnCount))
                }
            }
            guard !chosen.isEmpty else { throw FormulaFault.cell(.wrongType) }
            let rows = (0 ..< source.rowCount).map { row in chosen.map { source[row, $0] } }
            return .array(ValueArray(rows: rows))
        },
        FunctionSignature("EXPAND", 2, 4, prefixed: true) { call in
            let source = try call.table(0)
            let rows = call.isPresent(1) ? try call.integer(1) : source.rowCount
            let columns = call.isPresent(2) ? try call.integer(2) : source.columnCount
            let pad: ScalarValue = call.isPresent(3) ? try call.scalar(3) : .error(.notAvailable)
            guard rows >= source.rowCount, columns >= source.columnCount else {
                throw FormulaFault.cell(.wrongType)
            }
            let size = try checkedSize(rows: rows, columns: columns)
            let grid = (0 ..< size.rows).map { row in
                (0 ..< size.columns).map { column in
                    row < source.rowCount && column < source.columnCount ? source[row, column] : pad
                }
            }
            return .array(ValueArray(rows: grid))
        },
        FunctionSignature("WRAPROWS", 2, 3, prefixed: true) { call in
            .array(try wrap(call, byRow: true))
        },
        FunctionSignature("WRAPCOLS", 2, 3, prefixed: true) { call in
            .array(try wrap(call, byRow: false))
        },
    ]

    /// `TOROW`/`TOCOL`'s shared body: scan order, then the ignore rule.
    private static func flatten(_ call: FunctionCallSite) throws -> [ScalarValue] {
        let source = try call.table(0)
        let ignore = try call.integer(1, default: 0)
        let byColumn = try call.boolean(2, default: false)
        let scanned = byColumn ? source.columnsOfValues.flatMap { $0 } : source.values
        let result = scanned.filter { element in
            switch ignore {
            case 1: if case .blank = element { return false } else { return true }
            case 2: return element.errorValue == nil
            case 3:
                if case .blank = element { return false }
                return element.errorValue == nil
            default: return true
            }
        }
        guard !result.isEmpty else { throw FormulaFault.cell(.calculation) }
        return result
    }

    private static func wrap(_ call: FunctionCallSite, byRow: Bool) throws -> ValueArray {
        let source = try call.table(0)
        guard source.rowCount == 1 || source.columnCount == 1 else { throw FormulaFault.cell(.wrongType) }
        let width = try call.integer(1)
        guard width >= 1 else { throw FormulaFault.cell(.invalidNumber) }
        let pad: ScalarValue = call.isPresent(2) ? try call.scalar(2) : .error(.notAvailable)
        let values = source.values
        let lineCount = (values.count + width - 1) / width
        let size = try checkedSize(
            rows: byRow ? lineCount : width, columns: byRow ? width : lineCount
        )
        let lines = (0 ..< lineCount).map { line in
            (0 ..< width).map { offset -> ScalarValue in
                let index = line * width + offset
                return index < values.count ? values[index] : pad
            }
        }
        guard byRow else {
            return ValueArray(rows: (0 ..< size.rows).map { row in lines.map { $0[row] } })
        }
        return ValueArray(rows: lines)
    }

    private static func slice(count: Int, take: Int) throws -> [Int] {
        guard take != 0 else { throw FormulaFault.cell(.calculation) }
        if take > 0 { return Array(0 ..< Swift.min(take, count)) }
        return Array(Swift.max(0, count + take) ..< count)
    }

    private static func remainder(count: Int, drop: Int) throws -> [Int] {
        let kept = drop >= 0
            ? Array(Swift.min(drop, count) ..< count)
            : Array(0 ..< Swift.max(0, count + drop))
        guard !kept.isEmpty else { throw FormulaFault.cell(.calculation) }
        return kept
    }

    /// A 1-based index from `CHOOSEROWS`/`CHOOSECOLS`, negative counting from the end.
    private static func axisIndex(_ value: ScalarValue, count: Int) throws -> Int {
        let raw = try FunctionCallSite.number(from: value, dateSystem: .excel1900)
        let index = Int(raw.rounded(.towardZero))
        guard index != 0 else { throw FormulaFault.cell(.wrongType) }
        let resolved = index > 0 ? index - 1 : count + index
        guard resolved >= 0, resolved < count else { throw FormulaFault.cell(.wrongType) }
        return resolved
    }
}
