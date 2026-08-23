import Foundation
import SheetModel

/// Computes what changed between two versions of a workbook (PLAN.md §6.4).
///
/// Drives three surfaces — the refresh pill's counts, the diff panel's list, and the grid's
/// post-refresh flash — plus the `WorkbookDiff` an MCP `write_range` returns so an agent can
/// see what its own edit actually did.
///
/// The one design decision that matters: **structure before cells.** Comparing cell by cell at
/// fixed coordinates is correct and useless. Insert a row at the top of a 10,000-row sheet and
/// every cell below it has "changed", so the panel lists 40,000 changes and the user learns
/// nothing. So each sheet is aligned by row content hash first (``LineAlignment``), and cells
/// are compared only between rows that *correspond*. The 10,000-row insert then reports one
/// structural change and the handful of cells actually in the new row.
public struct WorkbookDiffer: Sendable {
    /// Tuning. The defaults come from ``Limits``.
    public struct Options: Sendable {
        /// Cell changes a single sheet will list before it starts counting instead of
        /// collecting. The panel shows `+N more` from ``SheetDiff/omittedCellChangeCount``.
        public var maximumListedChangesPerSheet: Int
        /// Total cell comparisons before the whole diff gives up and sets
        /// ``WorkbookDiff/wasTruncated``. A guard against pathological input, not a normal path.
        public var comparisonBudget: Int
        /// Detect column inserts and deletes as well as row ones.
        public var detectsColumnStructure: Bool
        /// How different two sheets may be and still be considered the same sheet renamed,
        /// when the ids do not match. Jaccard similarity over row hashes.
        public var renameSimilarityThreshold: Double
        /// Report cells whose only difference is ``Cell/styleID``.
        public var includesStyleOnlyChanges: Bool

        public init(
            maximumListedChangesPerSheet: Int = Limits.maxDiffCellChanges,
            comparisonBudget: Int = 5_000_000,
            detectsColumnStructure: Bool = true,
            renameSimilarityThreshold: Double = 0.5,
            includesStyleOnlyChanges: Bool = true
        ) {
            self.maximumListedChangesPerSheet = maximumListedChangesPerSheet
            self.comparisonBudget = comparisonBudget
            self.detectsColumnStructure = detectsColumnStructure
            self.renameSimilarityThreshold = renameSimilarityThreshold
            self.includesStyleOnlyChanges = includesStyleOnlyChanges
        }

        public static let `default` = Options()
    }

    public var options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    /// What the diff actually did, for tests and for diagnostics.
    ///
    /// Exists because the performance claim in PLAN.md §6.4 is an *algorithmic* one — the diff
    /// is linear in the number of populated cells — and wall-clock cannot check that on a
    /// machine seven agents are building on (WAVE-1-ADDENDUM §8). Counting comparisons can:
    /// a diff that regressed to the O(n·m) LCS this replaced would do millions of them where
    /// this does thousands, whatever else the machine is doing at the time.
    struct Statistics: Sendable, Hashable {
        /// Cell-to-cell comparisons performed.
        var cellComparisons = 0
        /// Whether the second, column-detecting pass ran.
        var columnDetectionRan = false
    }

    /// Diffs two workbooks.
    public func diff(before: Workbook, after: Workbook) -> WorkbookDiff {
        var statistics = Statistics()
        return diff(before: before, after: after, statistics: &statistics)
    }

    /// ``diff(before:after:)``, reporting what it cost. See ``Statistics``.
    func diff(before: Workbook, after: Workbook, statistics: inout Statistics) -> WorkbookDiff {
        let pairing = SheetPairing(before: before, after: after, threshold: options.renameSimilarityThreshold)
        var budget = options.comparisonBudget
        var truncated = false

        var sheetDiffs: [SheetDiff] = []
        sheetDiffs.reserveCapacity(pairing.matched.count)
        for (oldSheet, newSheet) in pairing.matched {
            let before = budget
            let diff = self.diff(before: oldSheet, after: newSheet, budget: &budget, statistics: &statistics)
            statistics.cellComparisons += before - budget
            if budget <= 0 { truncated = true }
            sheetDiffs.append(diff)
        }

        return WorkbookDiff(
            sheetDiffs: sheetDiffs,
            addedSheets: pairing.added.map(WorkbookDiffer.summary),
            removedSheets: pairing.removed.map(WorkbookDiffer.summary),
            renamedSheets: pairing.renames,
            wasTruncated: truncated
        )
    }

    /// Diffs one sheet against another.
    public func diff(before: Sheet, after: Sheet) -> SheetDiff {
        var budget = options.comparisonBudget
        var statistics = Statistics()
        return diff(before: before, after: after, budget: &budget, statistics: &statistics)
    }

    // MARK: - Per-sheet

    private func diff(
        before: Sheet,
        after: Sheet,
        budget: inout Int,
        statistics: inout Statistics
    ) -> SheetDiff {
        let oldRows = WorkbookDiffer.populatedRows(before)
        let newRows = WorkbookDiffer.populatedRows(after)
        let rawAlignment = LineAlignment.align(
            before: oldRows.map { before.cells.rowContentHash($0) ?? 0 },
            after: newRows.map { after.cells.rowContentHash($0) ?? 0 }
        )
        // A row where one cell changed comes back from Myers as delete-plus-insert. Pairing
        // those back up is what turns it into one changed cell rather than a whole row removed
        // and a whole row added — see `LineAlignment.pairingReplacements`.
        let alignment = LineAlignment.Result(
            steps: LineAlignment.pairingReplacements(rawAlignment.steps),
            gaveUp: rawAlignment.gaveUp
        )
        var structural = WorkbookDiffer.structuralChanges(
            from: alignment,
            oldRows: oldRows,
            newRows: newRows,
            insertKind: .insertedRows,
            deleteKind: .deletedRows
        )

        let startingBudget = budget
        var collector = compare(
            before: before, oldRows: oldRows,
            after: after, newRows: newRows,
            alignment: alignment, columnMap: nil, budget: &budget
        )

        // Column detection is expensive — a hash per cell, twice — and only ever *finds*
        // something when most of the sheet appears to have changed, because a column insert
        // shifts everything to its right. So it runs second, and only when the straight
        // comparison came back with enough changes to be suspicious. The ordinary edit of a
        // handful of cells never pays for it.
        //
        // `gaveUp` is not disqualifying: when both sides have the same number of rows the
        // fallback pairs them 1:1, which is exact rather than a guess. That is the ordinary
        // shape of a column insert — every row hash changes, so the row alignment always
        // exceeds its edit-distance cap — and refusing to look there would mean column inserts
        // were never detected at all.
        let rowPairingIsTrustworthy = !alignment.gaveUp || oldRows.count == newRows.count
        let suspicious = collector.total > max(32, before.cells.count / 10)
        if options.detectsColumnStructure, structural.isEmpty, rowPairingIsTrustworthy, suspicious,
           let columns = detectColumnStructure(before: before, after: after) {
            statistics.columnDetectionRan = true
            structural = columns.changes
            budget = startingBudget
            collector = compare(
                before: before, oldRows: oldRows,
                after: after, newRows: newRows,
                alignment: alignment, columnMap: columns.map, budget: &budget
            )
        }

        return SheetDiff(
            sheetID: after.id,
            sheetName: after.name,
            cellChanges: collector.listed,
            structuralChanges: structural,
            omittedCellChangeCount: collector.omitted,
            addedCount: collector.added,
            removedCount: collector.removed,
            changedCount: collector.changed
        )
    }

    /// Walks the alignment, comparing every pair of rows it lines up.
    private func compare(
        before: Sheet,
        oldRows: [Int],
        after: Sheet,
        newRows: [Int],
        alignment: LineAlignment.Result,
        columnMap: [Int: Int]?,
        budget: inout Int
    ) -> ChangeCollector {
        var collector = ChangeCollector(limit: options.maximumListedChangesPerSheet)
        for step in alignment.steps {
            guard budget > 0 else { break }
            switch step {
            case let .matched(oldIndex, newIndex):
                compareRows(
                    before: before, oldRow: oldRows[oldIndex],
                    after: after, newRow: newRows[newIndex],
                    columnMap: columnMap,
                    into: &collector, budget: &budget
                )
            case let .inserted(newIndex):
                after.cells.forEachRow(in: WorkbookDiffer.wholeRow(newRows[newIndex])) { slice in
                    for (ref, cell) in slice {
                        budget -= 1
                        collector.add(CellChange(ref: ref, before: nil, after: cell, kind: .added))
                    }
                }
            case let .deleted(oldIndex):
                before.cells.forEachRow(in: WorkbookDiffer.wholeRow(oldRows[oldIndex])) { slice in
                    for (ref, cell) in slice {
                        budget -= 1
                        collector.add(CellChange(ref: ref, before: cell, after: nil, kind: .removed))
                    }
                }
            }
        }
        return collector
    }

    /// Aligns the two sheets' columns, returning the structure and the old-to-new mapping.
    ///
    /// Only a clean run counts — a block containing both inserts and deletes is two columns
    /// whose contents changed, not a column that moved, and pairing those would map old column
    /// 3 onto new column 1 and report everything in between as changed.
    private func detectColumnStructure(
        before: Sheet,
        after: Sheet
    ) -> (changes: [StructuralChange], map: [Int: Int])? {
        let oldColumns = WorkbookDiffer.columnHashes(before)
        let newColumns = WorkbookDiffer.columnHashes(after)
        let alignment = LineAlignment.align(before: oldColumns.map(\.hash), after: newColumns.map(\.hash))
        guard !alignment.gaveUp, WorkbookDiffer.isCleanRun(alignment.steps) else { return nil }

        let changes = WorkbookDiffer.structuralChanges(
            from: alignment,
            oldRows: oldColumns.map(\.index),
            newRows: newColumns.map(\.index),
            insertKind: .insertedColumns,
            deleteKind: .deletedColumns
        )
        guard !changes.isEmpty else { return nil }

        var map: [Int: Int] = [:]
        for (oldIndex, newIndex) in alignment.matches {
            map[oldColumns[oldIndex].index] = newColumns[newIndex].index
        }
        return (changes, map)
    }

    /// Compares the cells of two rows that the alignment says correspond.
    ///
    /// Two paths, and the fast one is the one that runs. Both rows arrive as column-sorted
    /// slices, so with no column alignment in play they can be merge-walked in lockstep — no
    /// dictionary, no set, no allocation per row. On a 100,000-cell workbook that is 100,000
    /// hash insertions this does not do, which is most of the difference between a diff that
    /// feels instant and one that makes the refresh pill visibly lag.
    private func compareRows(
        before: Sheet,
        oldRow: Int,
        after: Sheet,
        newRow: Int,
        columnMap: [Int: Int]?,
        into collector: inout ChangeCollector,
        budget: inout Int
    ) {
        let oldSlice = before.cells.rows(in: WorkbookDiffer.wholeRow(oldRow)).first
        let newSlice = after.cells.rows(in: WorkbookDiffer.wholeRow(newRow)).first
        guard oldSlice != nil || newSlice != nil else { return }

        guard columnMap == nil else {
            compareRemappedRows(
                oldSlice: oldSlice, newSlice: newSlice, newRow: newRow,
                columnMap: columnMap, into: &collector, budget: &budget
            )
            return
        }

        var oldIndex = 0
        var newIndex = 0
        let oldCount = oldSlice?.count ?? 0
        let newCount = newSlice?.count ?? 0

        while oldIndex < oldCount || newIndex < newCount {
            budget -= 1
            let oldEntry = oldIndex < oldCount ? oldSlice?[oldIndex] : nil
            let newEntry = newIndex < newCount ? newSlice?[newIndex] : nil

            switch (oldEntry, newEntry) {
            case let (.some(old), .some(new)) where old.column == new.column:
                oldIndex += 1
                newIndex += 1
                record(ref: CellRef(row: newRow, column: new.column), before: old.cell, after: new.cell, &collector)
            case let (.some(old), .some(new)) where old.column < new.column:
                oldIndex += 1
                record(ref: CellRef(row: newRow, column: old.column), before: old.cell, after: nil, &collector)
            case let (.some, .some(new)):
                newIndex += 1
                record(ref: CellRef(row: newRow, column: new.column), before: nil, after: new.cell, &collector)
            case let (.some(old), nil):
                oldIndex += 1
                record(ref: CellRef(row: newRow, column: old.column), before: old.cell, after: nil, &collector)
            case let (nil, .some(new)):
                newIndex += 1
                record(ref: CellRef(row: newRow, column: new.column), before: nil, after: new.cell, &collector)
            case (nil, nil):
                return
            }
        }
    }

    /// The slow path, taken only when a column alignment says the columns moved.
    ///
    /// An old column that shifted is compared against where it shifted *to*, which is what
    /// stops a column insert reading as a full-sheet rewrite — the same job the row alignment
    /// does for rows. The remapping destroys the sorted order, so this one needs the dictionary.
    private func compareRemappedRows(
        oldSlice: CellStore.RowSlice?,
        newSlice: CellStore.RowSlice?,
        newRow: Int,
        columnMap: [Int: Int]?,
        into collector: inout ChangeCollector,
        budget: inout Int
    ) {
        var oldCells: [Int: Cell] = [:]
        if let oldSlice {
            oldCells.reserveCapacity(oldSlice.count)
            for index in 0 ..< oldSlice.count {
                let entry = oldSlice[index]
                oldCells[columnMap?[entry.column] ?? entry.column] = entry.cell
            }
        }
        var seen = Set<Int>()
        seen.reserveCapacity(oldCells.count)

        if let newSlice {
            for index in 0 ..< newSlice.count {
                budget -= 1
                let entry = newSlice[index]
                seen.insert(entry.column)
                record(
                    ref: CellRef(row: newRow, column: entry.column),
                    before: oldCells[entry.column],
                    after: entry.cell,
                    &collector
                )
            }
        }
        for (column, oldCell) in oldCells where !seen.contains(column) {
            budget -= 1
            record(ref: CellRef(row: newRow, column: column), before: oldCell, after: nil, &collector)
        }
    }

    /// Classifies one before/after pair and hands it to the collector.
    private func record(ref: CellRef, before: Cell?, after: Cell?, _ collector: inout ChangeCollector) {
        guard let change = CellChange.classify(ref: ref, before: before, after: after) else { return }
        if change.kind == .styleChanged, !options.includesStyleOnlyChanges { return }
        collector.add(change)
    }

    // MARK: - Helpers

    private static func wholeRow(_ row: Int) -> CellRange {
        CellRange(start: CellRef(row: row, column: 0), end: CellRef(row: row, column: Limits.maxColumn))
    }

    /// The row indices to align, densely across the used range where that is affordable.
    ///
    /// Dense matters: an inserted **empty** row is invisible in a list of populated rows, so a
    /// sparse list would report the shift it caused as nothing at all. Empty rows hash to a
    /// sentinel, which is exactly the "line" an insert needs for the alignment to see it.
    ///
    /// The span is bounded relative to how much is actually populated, so a sheet with two
    /// cells half a million rows apart falls back to the sparse list rather than allocating an
    /// array to match.
    private static func populatedRows(_ sheet: Sheet) -> [Int] {
        let populated = sheet.cells.sortedRowIndices()
        guard let first = populated.first, let last = populated.last else { return [] }
        let span = last - first + 1
        guard span <= max(4096, populated.count * 8) else { return populated }
        return Array(first ... last)
    }

    /// Whether an alignment is a run of inserts with no deletes, or the reverse.
    ///
    /// A mixed block means content changed in place; a pure run means something moved.
    private static func isCleanRun(_ steps: [LineAlignment.Step]) -> Bool {
        var inserts = false
        var deletes = false
        for step in steps {
            switch step {
            case .matched: continue
            case .inserted: inserts = true
            case .deleted: deletes = true
            }
        }
        return inserts != deletes
    }

    /// Column content hashes, built in one row-major pass.
    ///
    /// The store is row-major, so asking it for a column at a time would be a scan per column.
    /// Folding every cell into a per-column accumulator as the rows go past is one pass over
    /// the populated cells regardless of shape. FNV-1a for the same reason ``CellStore`` uses
    /// it: the value has to mean the same thing in the app and in `opensheets-mcp`.
    private static func columnHashes(_ sheet: Sheet) -> [(index: Int, hash: UInt64)] {
        var hashes: [Int: UInt64] = [:]
        guard let used = sheet.cells.usedRange else { return [] }
        sheet.cells.forEachRow(in: used) { slice in
            for (ref, cell) in slice {
                var hash = hashes[ref.column] ?? 0xCBF2_9CE4_8422_2325
                hash = WorkbookDiffer.fold(hash, UInt64(bitPattern: Int64(ref.row)))
                hash = WorkbookDiffer.fold(hash, cell.value.diffHash)
                hash = WorkbookDiffer.fold(hash, WorkbookDiffer.textHash(cell.formula))
                hashes[ref.column] = hash
            }
        }
        // Dense, for the same reason rows are: an inserted empty column has to be a line in
        // the sequence or the alignment cannot see it. Columns top out at 16,384, so density
        // costs nothing worth measuring.
        return (used.start.column ... used.end.column).map { (index: $0, hash: hashes[$0] ?? 0) }
    }

    /// Mixes one 64-bit value into a running hash.
    ///
    /// A splitmix64 finaliser rather than eight rounds of byte-wise FNV: this hash is computed
    /// fresh for both sides inside a single diff and never persisted or compared across
    /// processes, so it needs to be well-distributed rather than stable — and doing three
    /// operations per value instead of twenty-four is the difference between column detection
    /// being free and it being the most expensive part of the diff.
    private static func fold(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        var mixed = hash ^ (value &+ 0x9E37_79B9_7F4A_7C15)
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    private static func textHash(_ text: String?) -> UInt64 {
        guard let text else { return 0 }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Turns an alignment into runs of inserts and deletes.
    ///
    /// The indices reported are the *sheet's* row or column numbers, not positions in the
    /// sparse list — `inserted 1 row at 5` has to mean row 5 of the sheet or the message is a
    /// lie the user cannot check.
    private static func structuralChanges(
        from alignment: LineAlignment.Result,
        oldRows: [Int],
        newRows: [Int],
        insertKind: StructuralChange.Kind,
        deleteKind: StructuralChange.Kind
    ) -> [StructuralChange] {
        guard !alignment.gaveUp else { return [] }
        var changes: [StructuralChange] = []
        var runKind: StructuralChange.Kind?
        var runStart = 0
        var runCount = 0
        var runPrevious = -1

        func flush() {
            if let kind = runKind, runCount > 0 {
                changes.append(StructuralChange(kind: kind, index: runStart, count: runCount))
            }
            runKind = nil
            runCount = 0
            runPrevious = -1
        }

        for step in alignment.steps {
            switch step {
            case .matched:
                flush()
            case let .inserted(index):
                let line = newRows[index]
                if runKind == insertKind, line == runPrevious + 1 {
                    runCount += 1
                } else {
                    flush()
                    runKind = insertKind
                    runStart = line
                    runCount = 1
                }
                runPrevious = line
            case let .deleted(index):
                let line = oldRows[index]
                if runKind == deleteKind, line == runPrevious + 1 {
                    runCount += 1
                } else {
                    flush()
                    runKind = deleteKind
                    runStart = line
                    runCount = 1
                }
                runPrevious = line
            }
        }
        flush()
        return changes
    }

    private static func summary(_ sheet: Sheet) -> SheetSummary {
        SheetSummary(id: sheet.id, name: sheet.name, cellCount: sheet.cells.count)
    }

    /// Collects cell changes without ever growing past the cap.
    ///
    /// The counts are kept separately from the list on purpose: `"+18,412 more"` has to be
    /// accurate even though only 5,000 changes were retained, and deriving it from the array
    /// after the fact would make it a guess.
    private struct ChangeCollector {
        let limit: Int
        var listed: [CellChange] = []
        var omitted = 0
        var added = 0
        var removed = 0
        var changed = 0

        /// Every change counted, listed or not.
        var total: Int { added + removed + changed }

        init(limit: Int) {
            self.limit = limit
            listed.reserveCapacity(min(limit, 256))
        }

        mutating func add(_ change: CellChange) {
            switch change.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .valueChanged, .formulaChanged, .styleChanged: changed += 1
            }
            if listed.count < limit { listed.append(change) } else { omitted += 1 }
        }
    }
}

// MARK: - Sheet pairing

/// Matches sheets across two versions: by id, then by name, then by content similarity
/// (PLAN.md §6.4).
///
/// Three passes because each catches something the next cannot. Ids survive renames and
/// reorders and are the only trustworthy identity, so they go first. Names catch a sheet
/// rewritten by a producer that renumbers ids — which openpyxl does. Content similarity
/// catches the rest, and it is worth the extra pass: reporting *"Sheet1 was renamed to Q4 and
/// three cells changed"* is the difference between a useful panel and *"a sheet vanished, an
/// unrelated one appeared"*.
private struct SheetPairing {
    var matched: [(Sheet, Sheet)] = []
    var added: [Sheet] = []
    var removed: [Sheet] = []
    var renames: [SheetRename] = []

    init(before: Workbook, after: Workbook, threshold: Double) {
        var pairedOld = Set<Int>()
        var pairedNew = Set<Int>()

        func take(_ oldIndex: Int, _ newIndex: Int) {
            let old = before.sheets[oldIndex]
            let new = after.sheets[newIndex]
            pairedOld.insert(oldIndex)
            pairedNew.insert(newIndex)
            matched.append((old, new))
            if old.name != new.name {
                // The id reported is the *new* one. When the match came from content
                // similarity the ids differ, and every consumer keys off the workbook it is
                // showing now — so the new id is the one that can be looked up.
                renames.append(SheetRename(id: new.id, before: old.name, after: new.name))
            }
        }

        for (oldIndex, old) in before.sheets.enumerated() {
            guard let newIndex = after.sheets.firstIndex(where: { $0.id == old.id }) else { continue }
            guard !pairedNew.contains(newIndex) else { continue }
            take(oldIndex, newIndex)
        }
        for (oldIndex, old) in before.sheets.enumerated() where !pairedOld.contains(oldIndex) {
            guard let newIndex = after.sheets.firstIndex(where: { candidate in
                candidate.name.caseInsensitiveCompare(old.name) == .orderedSame
            }), !pairedNew.contains(newIndex) else { continue }
            take(oldIndex, newIndex)
        }
        for (oldIndex, old) in before.sheets.enumerated() where !pairedOld.contains(oldIndex) {
            let oldHashes = SheetPairing.hashes(old)
            guard !oldHashes.isEmpty else { continue }
            var best: (index: Int, score: Double)?
            for (newIndex, new) in after.sheets.enumerated() where !pairedNew.contains(newIndex) {
                let score = SheetPairing.similarity(oldHashes, SheetPairing.hashes(new))
                if score >= threshold, score > (best?.score ?? 0) { best = (newIndex, score) }
            }
            if let best { take(oldIndex, best.index) }
        }

        added = after.sheets.enumerated().filter { !pairedNew.contains($0.offset) }.map(\.element)
        removed = before.sheets.enumerated().filter { !pairedOld.contains($0.offset) }.map(\.element)
    }

    private static func hashes(_ sheet: Sheet) -> Set<UInt64> {
        var result = Set<UInt64>()
        for row in sheet.cells.sortedRowIndices() {
            if let hash = sheet.cells.rowContentHash(row) { result.insert(hash) }
        }
        return result
    }

    private static func similarity(_ lhs: Set<UInt64>, _ rhs: Set<UInt64>) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }
}

extension CellValue {
    /// A process-stable hash of a value, matching what ``CellStore/rowContentHash(_:)`` folds
    /// in — so a row hash and a column hash disagree about a cell only if the cell differs.
    var diffHash: UInt64 {
        switch self {
        case .empty:
            0x1
        case let .number(value):
            0x2 ^ value.bitPattern
        case let .text(value):
            0x3 ^ WorkbookDifferTextHash.hash(value)
        case let .boolean(value):
            value ? 0x4 : 0x5
        case let .error(kind):
            0x6 ^ WorkbookDifferTextHash.hash(kind.rawValue)
        }
    }
}

private enum WorkbookDifferTextHash {
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
