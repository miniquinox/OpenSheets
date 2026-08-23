import Foundation

/// Sparse storage for a sheet's cells.
///
/// # The representation is private and will change
///
/// Today it is row-major: a `[Int32: RowRun]` where each `RowRun` holds a sorted `[UInt32]` of
/// column indices and a parallel `[Cell]`. That is cache-friendly, cheap to walk a rectangle,
/// and roughly 48 bytes per populated cell — where a flat `[CellRef: Cell]` would be both
/// slower for range scans and considerably fatter at a million cells.
///
/// It is also an implementation detail. **Use the public API only.** The whole reason this
/// type is opaque is so the layout can be swapped — for a column-major store, an arena, a
/// memory-mapped file — without touching a single call site. If the API is missing something
/// you need, that is a ``SheetError``-shaped gap worth filing in
/// `docs/agents/MODEL-CHANGE-REQUESTS.md`, not a reason to reach around it.
///
/// # Costs you should know about
///
/// - ``subscript(_:)``, ``setCell(_:at:)``, ``removeCell(at:)`` — O(log cells-in-row).
/// - ``cells(in:)``, ``forEachCell(in:_:)``, ``rows(in:)`` — proportional to what is
///   *returned*, not to the size of the rectangle. `cells(in:)` over a 50×50 window of a
///   million cells is microseconds.
/// - ``usedRange`` and ``count`` — O(1), maintained as you write.
/// - ``nextNonEmptyRow(inColumn:after:)`` and its siblings on the row axis — **O(populated
///   rows)**, because rows live in a dictionary with no ordering. Fine for a ⌘↓ keystroke,
///   wrong inside a draw loop. The column-axis versions are O(log n).
/// - ``sortedRowIndices()`` — O(n log n). Sort once and keep it if you are writing a file.
///
/// # What it does not do
///
/// Moving cells is not the same as fixing formulas. ``insertRows(at:count:)`` and friends
/// relocate cells, merges, and sizes — they do **not** rewrite formula text. `=A5*2` still
/// says `A5` after a row insert. Rewriting references is `SheetFormula`'s `ReferenceTransform`,
/// and it has to be, because it needs to parse.
public struct CellStore: Sendable {
    /// One populated row: column indices ascending, values parallel.
    private struct RowRun: Sendable, Equatable {
        var columns: [UInt32]
        var cells: [Cell]

        /// Inserts or replaces one cell, reporting whether the row grew.
        ///
        /// Mutating in place through the dictionary's `_modify` accessor is the difference
        /// between a million cheap appends and a million array copies.
        @inline(__always)
        mutating func set(_ cell: Cell, at column: UInt32) -> Bool {
            let (index, found) = search(column)
            if found {
                cells[index] = cell
                return false
            }
            columns.insert(column, at: index)
            cells.insert(cell, at: index)
            return true
        }

        /// Index of `column` in ``columns``, or the index it would be inserted at.
        @inline(__always)
        func search(_ column: UInt32) -> (index: Int, found: Bool) {
            var low = 0
            var high = columns.count
            while low < high {
                let mid = (low &+ high) >> 1
                if columns[mid] < column { low = mid &+ 1 } else { high = mid }
            }
            return (low, low < columns.count && columns[low] == column)
        }
    }

    private var rows: [Int32: RowRun]

    /// Populated cells. Maintained on write so it is O(1) to read.
    private var populatedCount: Int

    /// The exact bounding box of populated cells, maintained on write.
    ///
    /// Kept exact rather than conservative: an approximate used range shows up as a wrong
    /// `dimension` in a saved file and as phantom empty rows in the grid. Growing it is O(1);
    /// a removal that touches an edge triggers an O(n) recompute, which is why bulk removal
    /// goes through ``removeCells(in:)`` and recomputes once.
    private var bounds: CellRange?

    /// An empty store.
    public init() {
        rows = [:]
        populatedCount = 0
        bounds = nil
    }

    /// A store pre-loaded from a sequence of addressed cells. Later entries win on collision.
    ///
    /// Throws on the first out-of-range reference rather than dropping it silently.
    public init(_ cells: some Sequence<(CellRef, Cell)>) throws(SheetError) {
        self.init()
        for (ref, cell) in cells {
            try setCell(cell, at: ref)
        }
    }

    // MARK: - Reading

    /// The cell at `ref`, or `nil` when nothing is stored there.
    ///
    /// Read-only on purpose. A settable subscript would make `store[ref]?.value = x` compile
    /// and quietly do nothing when the cell is absent; ``setCell(_:at:)`` cannot.
    public subscript(ref: CellRef) -> Cell? {
        guard ref.isValid else { return nil }
        guard let run = rows[Int32(ref.row)] else { return nil }
        let (index, found) = run.search(UInt32(ref.column))
        return found ? run.cells[index] : nil
    }

    /// Whether a cell is stored at `ref`.
    public func contains(_ ref: CellRef) -> Bool { self[ref] != nil }

    /// Populated cells. O(1).
    public var count: Int { populatedCount }

    /// Whether nothing is stored.
    public var isEmpty: Bool { populatedCount == 0 }

    /// The exact bounding box of populated cells, or `nil` for an empty store. O(1).
    ///
    /// Computed from what is actually here, never from a file's `dimension` attribute — that
    /// attribute is wrong often enough that trusting it is a bug (PLAN.md §9: a single cell at
    /// `XFD1048576` gives a huge used range and no data, and plenty of producers get it wrong
    /// in the other direction).
    public var usedRange: CellRange? { bounds }

    /// Every populated cell in `range`, in row-major order.
    ///
    /// Allocates an array. In a draw loop use ``forEachCell(in:_:)`` instead.
    public func cells(in range: CellRange) -> [(ref: CellRef, cell: Cell)] {
        var result: [(ref: CellRef, cell: Cell)] = []
        forEachCell(in: range) { ref, cell in result.append((ref, cell)) }
        return result
    }

    /// Visits every populated cell in `range`, row-major, allocating nothing.
    ///
    /// Walks whichever is smaller — the rectangle's rows or the store's populated rows — so
    /// `forEachCell(in: .entireSheet)` on a three-row sheet visits three rows, not a million.
    public func forEachCell(in range: CellRange, _ body: (CellRef, Cell) throws -> Void) rethrows {
        guard let clipped = range.intersection(.entireSheet) else { return }
        for key in rowKeys(in: clipped) {
            guard let run = rows[key] else { continue }
            let row = Int(key)
            let (start, _) = run.search(UInt32(clipped.start.column))
            let upper = UInt32(clipped.end.column)
            var index = start
            while index < run.columns.count, run.columns[index] <= upper {
                try body(CellRef(row: row, column: Int(run.columns[index])), run.cells[index])
                index += 1
            }
        }
    }

    /// A view of one populated row, clipped to a column range.
    ///
    /// Holds slices of the store's own arrays, so building one copies nothing.
    public struct RowSlice: Sendable, Sequence {
        /// The 0-based row index.
        public let row: Int

        private let columns: ArraySlice<UInt32>
        private let cells: ArraySlice<Cell>

        fileprivate init(row: Int, columns: ArraySlice<UInt32>, cells: ArraySlice<Cell>) {
            self.row = row
            self.columns = columns
            self.cells = cells
        }

        /// Populated cells in this slice.
        public var count: Int { columns.count }

        /// Whether this slice holds nothing.
        public var isEmpty: Bool { columns.isEmpty }

        /// The nth populated cell, ascending by column. Not a column index — use ``Iterator``
        /// or this subscript's `column` field for that.
        public subscript(position: Int) -> (column: Int, cell: Cell) {
            let offset = columns.startIndex + position
            return (Int(columns[offset]), cells[cells.startIndex + position])
        }

        /// Yields `(ref, cell)` pairs ascending by column.
        public struct Iterator: IteratorProtocol {
            private let slice: RowSlice
            private var position: Int

            fileprivate init(_ slice: RowSlice) {
                self.slice = slice
                position = 0
            }

            public mutating func next() -> (ref: CellRef, cell: Cell)? {
                guard position < slice.count else { return nil }
                let (column, cell) = slice[position]
                position += 1
                return (CellRef(row: slice.row, column: column), cell)
            }
        }

        public func makeIterator() -> Iterator { Iterator(self) }
    }

    /// The populated rows overlapping `range`, ascending, each clipped to the range's columns.
    ///
    /// Rows with nothing in them are omitted entirely — a 1,000,000-row range over a
    /// three-row sheet gives three slices.
    public func rows(in range: CellRange) -> [RowSlice] {
        var result: [RowSlice] = []
        forEachRow(in: range) { result.append($0) }
        return result
    }

    /// Visits the populated rows overlapping `range`, ascending, allocating nothing.
    public func forEachRow(in range: CellRange, _ body: (RowSlice) throws -> Void) rethrows {
        guard let clipped = range.intersection(.entireSheet) else { return }
        for key in rowKeys(in: clipped) {
            guard let run = rows[key] else { continue }
            let (start, _) = run.search(UInt32(clipped.start.column))
            var end = start
            let upper = UInt32(clipped.end.column)
            while end < run.columns.count, run.columns[end] <= upper {
                end += 1
            }
            guard end > start else { continue }
            try body(RowSlice(row: Int(key), columns: run.columns[start ..< end], cells: run.cells[start ..< end]))
        }
    }

    /// Every populated row index, ascending. O(n log n) — sort once and hold onto it.
    public func sortedRowIndices() -> [Int] {
        rows.keys.map(Int.init).sorted()
    }

    // MARK: - Navigation

    /// The next populated column at or after `column` in `row`, or `nil`. O(log n).
    public func firstNonEmptyColumn(inRow row: Int, atOrAfter column: Int) -> Int? {
        guard Limits.isValidRow(row), column <= Limits.maxColumn, let run = rows[Int32(row)] else { return nil }
        let (index, _) = run.search(UInt32(max(0, column)))
        return index < run.columns.count ? Int(run.columns[index]) : nil
    }

    /// The last populated column at or before `column` in `row`, or `nil`. O(log n).
    public func lastNonEmptyColumn(inRow row: Int, atOrBefore column: Int) -> Int? {
        guard Limits.isValidRow(row), column >= 0, let run = rows[Int32(row)] else { return nil }
        let (index, found) = run.search(UInt32(min(column, Limits.maxColumn)))
        if found { return Int(run.columns[index]) }
        return index > 0 ? Int(run.columns[index - 1]) : nil
    }

    /// The next populated row at or after `row` that has a cell in `column`, or `nil`.
    ///
    /// **O(populated rows).** Rows are a dictionary, so finding the next one means looking at
    /// all of them. That is the right trade for a keystroke and the wrong one for a frame; if
    /// you need this per frame, build an index from ``sortedRowIndices()``.
    public func firstNonEmptyRow(inColumn column: Int, atOrAfter row: Int) -> Int? {
        guard column >= 0, column <= Limits.maxColumn else { return nil }
        let target = UInt32(column)
        var best: Int?
        for (key, run) in rows {
            let candidate = Int(key)
            guard candidate >= row, best.map({ candidate < $0 }) ?? true else { continue }
            if run.search(target).found { best = candidate }
        }
        return best
    }

    /// The last populated row at or before `row` that has a cell in `column`, or `nil`.
    /// **O(populated rows)** — see ``firstNonEmptyRow(inColumn:atOrAfter:)``.
    public func lastNonEmptyRow(inColumn column: Int, atOrBefore row: Int) -> Int? {
        guard column >= 0, column <= Limits.maxColumn else { return nil }
        let target = UInt32(column)
        var best: Int?
        for (key, run) in rows {
            let candidate = Int(key)
            guard candidate <= row, best.map({ candidate > $0 }) ?? true else { continue }
            if run.search(target).found { best = candidate }
        }
        return best
    }

    // MARK: - Writing

    /// Stores `cell` at `ref`, replacing whatever was there.
    ///
    /// Blank cells are stored, not dropped: a cell that is empty but styled is real, and a
    /// whole column formatted as currency has to survive a round-trip. Use
    /// ``removeCell(at:)`` to actually remove one.
    public mutating func setCell(_ cell: Cell, at ref: CellRef) throws(SheetError) {
        guard ref.isValid else {
            throw SheetError.cellReferenceOutOfRange(row: ref.row, column: ref.column)
        }
        let key = Int32(ref.row)
        let column = UInt32(ref.column)

        // `_modify` on the defaulted subscript mutates the row in place; going through
        // `rows[key]` and assigning back would copy both arrays on every write.
        let inserted = rows[key, default: RowRun(columns: [], cells: [])].set(cell, at: column)

        if inserted {
            populatedCount += 1
            let single = CellRange(ref)
            bounds = bounds.map { $0.union(single) } ?? single
        }
    }

    /// Removes the cell at `ref` and returns it, or `nil` if there was none.
    ///
    /// Removing a cell on the edge of ``usedRange`` forces an O(n) recompute of the bounds.
    /// Removing many cells at once should go through ``removeCells(in:)``, which recomputes
    /// once instead of once per cell.
    @discardableResult
    public mutating func removeCell(at ref: CellRef) -> Cell? {
        guard ref.isValid, var run = rows[Int32(ref.row)] else { return nil }
        let (index, found) = run.search(UInt32(ref.column))
        guard found else { return nil }

        let removed = run.cells[index]
        run.columns.remove(at: index)
        run.cells.remove(at: index)
        if run.columns.isEmpty {
            rows.removeValue(forKey: Int32(ref.row))
        } else {
            rows[Int32(ref.row)] = run
        }
        populatedCount -= 1
        if touchesBoundary(ref) { recomputeBounds() }
        return removed
    }

    /// Removes every cell in `range`. Recomputes ``usedRange`` once at the end.
    public mutating func removeCells(in range: CellRange) {
        guard let clipped = range.intersection(.entireSheet), !isEmpty else { return }
        var emptiedRows: [Int32] = []

        for key in rowKeys(in: clipped) {
            guard var run = rows[key] else { continue }
            let (start, _) = run.search(UInt32(clipped.start.column))
            var end = start
            let upper = UInt32(clipped.end.column)
            while end < run.columns.count, run.columns[end] <= upper {
                end += 1
            }
            guard end > start else { continue }

            populatedCount -= (end - start)
            run.columns.removeSubrange(start ..< end)
            run.cells.removeSubrange(start ..< end)
            if run.columns.isEmpty { emptiedRows.append(key) } else { rows[key] = run }
        }

        for key in emptiedRows {
            rows.removeValue(forKey: key)
        }
        recomputeBounds()
    }

    /// Removes everything.
    public mutating func removeAll() {
        rows.removeAll(keepingCapacity: false)
        populatedCount = 0
        bounds = nil
    }

    /// Hints how many rows are coming, so bulk loading does not rehash repeatedly.
    public mutating func reserveCapacity(rows count: Int) {
        rows.reserveCapacity(count)
    }

    // MARK: - Structural edits

    /// Opens `count` rows at `row`; every cell from `row` down moves that far down.
    ///
    /// Throws rather than truncating if this would push a populated cell past row 1,048,576.
    /// Silently dropping data at the bottom of a sheet is the kind of loss nobody notices
    /// until much later.
    ///
    /// Does **not** rewrite formula text — see the type's documentation.
    public mutating func insertRows(at row: Int, count: Int) throws(SheetError) {
        try validateStructuralEdit(index: row, count: count, isRow: true)
        if let last = bounds?.end.row, last >= row, last + count > Limits.maxRow {
            throw SheetError.wouldShiftDataOffSheet(
                detail: "inserting \(count) row(s) at row \(row + 1) would push data past row \(Limits.rowCount)"
            )
        }
        remapRows { $0 >= row ? $0 + count : $0 }
    }

    /// Closes `count` rows at `row`; their cells are deleted and everything below moves up.
    public mutating func deleteRows(at row: Int, count: Int) throws(SheetError) {
        try validateStructuralEdit(index: row, count: count, isRow: true)
        let deleted = row ..< (row + count)
        remapRows { deleted.contains($0) ? nil : ($0 >= deleted.upperBound ? $0 - count : $0) }
    }

    /// Opens `count` columns at `column`; every cell from `column` right moves that far right.
    ///
    /// Throws rather than truncating if this would push a populated cell past column `XFD`.
    public mutating func insertColumns(at column: Int, count: Int) throws(SheetError) {
        try validateStructuralEdit(index: column, count: count, isRow: false)
        if let last = bounds?.end.column, last >= column, last + count > Limits.maxColumn {
            throw SheetError.wouldShiftDataOffSheet(
                detail: "inserting \(count) column(s) at \(CellRef.columnLetters(column)) would push data past XFD"
            )
        }
        remapColumns { $0 >= column ? $0 + count : $0 }
    }

    /// Closes `count` columns at `column`; their cells are deleted and everything to the right
    /// moves left.
    public mutating func deleteColumns(at column: Int, count: Int) throws(SheetError) {
        try validateStructuralEdit(index: column, count: count, isRow: false)
        let deleted = column ..< (column + count)
        remapColumns { deleted.contains($0) ? nil : ($0 >= deleted.upperBound ? $0 - count : $0) }
    }

    // MARK: - Diff support

    /// A process-stable hash of one row's contents, or `nil` for an empty row.
    ///
    /// FNV-1a over column indices, values, and formula text — deliberately **not** Swift's
    /// `Hasher`, which is seeded per process and would give different answers in the app and
    /// in `opensheets-mcp`. The sync engine runs an LCS over these to tell *"a row was
    /// inserted at 5"* from *"10,000 cells changed"* (PLAN.md §6.4), and that comparison
    /// spans a reload, so stability is the whole point.
    ///
    /// Styles are excluded: a reformat is not a content change.
    public func rowContentHash(_ row: Int) -> UInt64? {
        guard Limits.isValidRow(row), let run = rows[Int32(row)], !run.columns.isEmpty else { return nil }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for index in run.columns.indices {
            hash.fnv1a(bits: UInt64(run.columns[index]))
            hash.fnv1a(value: run.cells[index].value)
            if let formula = run.cells[index].formula { hash.fnv1a(text: formula) } else { hash.fnv1a(bits: 0) }
        }
        return hash
    }

    // MARK: - Internals

    /// The populated row keys inside `range`, ascending.
    ///
    /// Picks whichever side is smaller: probing the rectangle's rows when it is narrow, or
    /// filtering the store's rows when the rectangle is taller than the sheet is populated.
    private func rowKeys(in range: CellRange) -> [Int32] {
        if range.rowCount <= rows.count {
            var keys: [Int32] = []
            keys.reserveCapacity(min(range.rowCount, rows.count))
            for row in range.rows where rows[Int32(row)] != nil {
                keys.append(Int32(row))
            }
            return keys
        }
        return rows.keys.filter { range.rows.contains(Int($0)) }.sorted()
    }

    private func touchesBoundary(_ ref: CellRef) -> Bool {
        guard let bounds else { return true }
        return ref.row == bounds.start.row || ref.row == bounds.end.row
            || ref.column == bounds.start.column || ref.column == bounds.end.column
    }

    private mutating func recomputeBounds() {
        var minRow = Int.max, maxRow = Int.min, minColumn = Int.max, maxColumn = Int.min
        var total = 0
        for (key, run) in rows where !run.columns.isEmpty {
            let row = Int(key)
            minRow = min(minRow, row)
            maxRow = max(maxRow, row)
            minColumn = min(minColumn, Int(run.columns[0]))
            maxColumn = max(maxColumn, Int(run.columns[run.columns.count - 1]))
            total += run.columns.count
        }
        populatedCount = total
        bounds = total == 0
            ? nil
            : CellRange(start: CellRef(row: minRow, column: minColumn), end: CellRef(row: maxRow, column: maxColumn))
    }

    private func validateStructuralEdit(index: Int, count: Int, isRow: Bool) throws(SheetError) {
        guard count > 0 else {
            throw SheetError.invalidArgument(name: "count", reason: "must be positive, got \(count)")
        }
        let valid = isRow ? Limits.isValidRow(index) : Limits.isValidColumn(index)
        guard valid else {
            throw SheetError.cellReferenceOutOfRange(
                row: isRow ? index : 0,
                column: isRow ? 0 : index
            )
        }
    }

    /// Rebuilds the row dictionary under a remapping. `nil` deletes the row.
    private mutating func remapRows(_ transform: (Int) -> Int?) {
        var rebuilt: [Int32: RowRun] = [:]
        rebuilt.reserveCapacity(rows.count)
        for (key, run) in rows {
            guard let mapped = transform(Int(key)), Limits.isValidRow(mapped) else { continue }
            rebuilt[Int32(mapped)] = run
        }
        rows = rebuilt
        recomputeBounds()
    }

    /// Rebuilds every row's column arrays under a remapping. `nil` deletes the cell.
    private mutating func remapColumns(_ transform: (Int) -> Int?) {
        var rebuilt: [Int32: RowRun] = [:]
        rebuilt.reserveCapacity(rows.count)
        for (key, run) in rows {
            var columns: [UInt32] = []
            var cells: [Cell] = []
            columns.reserveCapacity(run.columns.count)
            cells.reserveCapacity(run.cells.count)
            for index in run.columns.indices {
                guard let mapped = transform(Int(run.columns[index])), Limits.isValidColumn(mapped) else { continue }
                columns.append(UInt32(mapped))
                cells.append(run.cells[index])
            }
            // A shift never reorders, so the arrays stay sorted without re-sorting.
            if !columns.isEmpty { rebuilt[key] = RowRun(columns: columns, cells: cells) }
        }
        rows = rebuilt
        recomputeBounds()
    }
}

// MARK: - Deterministic hashing

extension UInt64 {
    /// One FNV-1a round over eight bytes.
    @inline(__always)
    fileprivate mutating func fnv1a(bits value: UInt64) {
        var remaining = value
        for _ in 0 ..< 8 {
            self ^= remaining & 0xFF
            self = self &* 0x0000_0100_0000_01B3
            remaining >>= 8
        }
    }

    @inline(__always)
    fileprivate mutating func fnv1a(text: String) {
        for byte in text.utf8 {
            self ^= UInt64(byte)
            self = self &* 0x0000_0100_0000_01B3
        }
    }

    @inline(__always)
    fileprivate mutating func fnv1a(value: CellValue) {
        switch value {
        case .empty:
            fnv1a(bits: 0)
        case let .number(number):
            fnv1a(bits: 1)
            fnv1a(bits: number.isNaN ? Double.nan.bitPattern : number.bitPattern)
        case let .text(text):
            fnv1a(bits: 2)
            fnv1a(text: text)
        case let .boolean(flag):
            fnv1a(bits: 3)
            fnv1a(bits: flag ? 1 : 0)
        case let .error(error):
            fnv1a(bits: 4)
            fnv1a(text: error.rawValue)
        }
    }
}

// MARK: - Conformances

extension CellStore: Equatable {
    /// Cell-by-cell equality.
    ///
    /// `Hashable` is deliberately absent. Hashing a million cells to put a store in a `Set` is
    /// never the right move, and leaving the conformance off means nobody does it by accident.
    public static func == (lhs: CellStore, rhs: CellStore) -> Bool {
        lhs.populatedCount == rhs.populatedCount && lhs.rows == rhs.rows
    }
}

extension CellStore: Codable {
    /// One JSON object per populated row: `{"r":0,"c":[0,2],"v":[…]}`.
    ///
    /// Compact enough for a fixture sidecar and lossless, which is what
    /// `Fixtures/**/*.expected.json` needs.
    private struct EncodedRow: Codable {
        let r: Int
        let c: [Int]
        let v: [Cell]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for key in sortedRowIndices() {
            guard let run = rows[Int32(key)] else { continue }
            try container.encode(EncodedRow(r: key, c: run.columns.map(Int.init), v: run.cells))
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let row = try container.decode(EncodedRow.self)
            guard row.c.count == row.v.count else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "row \(row.r) has \(row.c.count) columns but \(row.v.count) values"
                )
            }
            for index in row.c.indices {
                do {
                    try setCell(row.v[index], at: CellRef(row: row.r, column: row.c[index]))
                } catch {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: error.message)
                }
            }
        }
    }
}

extension CellStore: CustomStringConvertible {
    public var description: String {
        "CellStore(\(populatedCount) cells in \(rows.count) rows, used: \(bounds?.a1String ?? "—"))"
    }
}
