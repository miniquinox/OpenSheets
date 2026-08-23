import Foundation
import SheetModel

/// What a column holds, in the vocabulary an agent needs to plan an edit.
public enum ColumnType: String, Sendable, Hashable, CaseIterable {
    case empty
    case boolean
    case integer
    case number
    case currency
    case percentage
    case date
    case time
    case dateTime
    case text
    case error
    /// No single type reaches ``SheetProfiler/Options/dominanceThreshold``. Worth saying out
    /// loud: a mixed column is usually a data-quality problem, and an agent that knows it is
    /// mixed will look before it sorts.
    case mixed

    /// The short spelling used in `describe` output.
    public var label: String {
        switch self {
        case .empty: "empty"
        case .boolean: "bool"
        case .integer: "int"
        case .number: "number"
        case .currency: "money"
        case .percentage: "pct"
        case .date: "date"
        case .time: "time"
        case .dateTime: "datetime"
        case .text: "text"
        case .error: "error"
        case .mixed: "mixed"
        }
    }

    var isNumeric: Bool {
        switch self {
        case .integer, .number, .currency, .percentage: true
        default: false
        }
    }

    var isTemporal: Bool {
        switch self {
        case .date, .time, .dateTime: true
        default: false
        }
    }
}

/// One column's shape.
public struct ColumnProfile: Sendable, Hashable {
    public var index: Int
    /// `A`, `B`, … `AA`.
    public var letter: String
    /// The header cell's text, when a header row was found. Untrusted content.
    public var header: String?
    public var type: ColumnType
    /// Body cells that are blank or absent.
    public var nullCount: Int
    /// Body cells that hold something.
    public var populatedCount: Int
    /// Body cells holding a formula.
    public var formulaCount: Int
    /// One representative formula, for a column that is computed.
    public var formulaSample: String?
    /// Body cells holding an error value.
    public var errorCount: Int
    /// Up to three distinct values, formatted. Untrusted content.
    public var samples: [String]
    /// Distinct value count, exact when it stayed under
    /// ``SheetProfiler/Options/distinctCeiling`` and `nil` when it went past.
    public var distinctCount: Int?
    public var minimum: Double?
    public var maximum: Double?
    public var sum: Double?
    public var trueCount: Int
    public var falseCount: Int
    /// The dominant type's share, `0 ... 1`. Below the threshold the type is ``ColumnType/mixed``.
    public var purity: Double
}

/// One sheet's shape.
public struct SheetProfile: Sendable, Hashable {
    public var id: SheetID
    /// Untrusted content: a sheet name comes from the file.
    public var name: String
    public var visibility: SheetVisibility
    public var usedRange: CellRange?
    public var rowCount: Int
    public var columnCount: Int
    public var cellCount: Int
    /// Zero-based. `nil` when no row looked like a header.
    public var headerRow: Int?
    /// `0 ... 1`. Reported so an agent can tell "row 1 is definitely a header" from "probably".
    public var headerConfidence: Double
    public var columns: [ColumnProfile]
    /// Columns past ``SheetProfiler/Options/maximumColumns``, described only by their count.
    public var omittedColumnCount: Int
    public var formulaCount: Int
    public var mergeCount: Int
    public var frozen: FrozenPanes
    /// Whether the counts come from a sample rather than a full scan.
    public var isSampled: Bool
}

/// A whole workbook's shape.
public struct WorkbookProfile: Sendable, Hashable {
    public var fileName: String
    public var path: String
    public var format: WorkbookFormat
    public var sheetCount: Int
    public var cellCount: Int
    public var sheets: [SheetProfile]
    public var definedNameCount: Int
    public var containsMacros: Bool
    public var readOnlyReason: ReadOnlyReason?
    /// Sheets past ``SheetProfiler/Options/maximumSheets``, summarised in one line each.
    public var briefSheets: [(name: String, cellCount: Int, usedRange: String)]

    public static func == (lhs: WorkbookProfile, rhs: WorkbookProfile) -> Bool {
        lhs.path == rhs.path && lhs.sheets == rhs.sheets && lhs.cellCount == rhs.cellCount
            && lhs.briefSheets.map(\.name) == rhs.briefSheets.map(\.name)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(cellCount)
        hasher.combine(sheets)
    }
}

/// Works out what a workbook contains without reading it out.
///
/// # Why this is the most important thing in the server
///
/// The alternative to `describe` is an agent dumping 50,000 rows of CSV into its own context to
/// answer *"which column holds the revenue"*. That is a bad agent: it is slow, it is expensive,
/// and by the time it has read the data it has no room left to reason about it. A profile of
/// the same workbook is a few hundred tokens and answers the question directly.
///
/// So the whole design is a budget. One pass over the cells, per-column tallies rather than
/// per-cell records, a hard cap on columns and sheets described in full, and three sample
/// values rather than a page of them. The 50,000-row acceptance case comes out under 800
/// tokens because the output size depends on the number of *columns*, not the number of rows.
///
/// # Header detection
///
/// Four signals, because no single one survives real files:
///
/// 1. **The row is mostly text.** Necessary, nowhere near sufficient — a sheet of names is
///    mostly text on every row.
/// 2. **It differs in type from what follows.** `Region | Units` over `North | 42` is the
///    classic shape, and it is the strongest signal when it fires.
/// 3. **Its values do not recur below it.** A header is a name; a value repeats. This is what
///    stops an all-text sheet from reporting its first data row as a header.
/// 4. **Its values are distinct from each other.** Two columns headed `Total` happens; a whole
///    row of identical strings is a banner, not a header.
///
/// Rows above the winner — a title, a blank, a "generated on" line — are simply not the header,
/// which is why the scan looks at the first several rows rather than only the first.
public struct SheetProfiler: Sendable {
    /// Tuning. Every one of these trades output size against fidelity.
    public struct Options: Sendable, Hashable {
        /// How many rows from the top may be a header.
        public var headerScanDepth: Int
        /// How many rows below a candidate are compared against it.
        public var headerBodyDepth: Int
        /// Minimum score for a row to be called the header.
        public var headerThreshold: Double
        /// Share the leading type must reach before a column is called that type.
        public var dominanceThreshold: Double
        /// Columns profiled in full per sheet.
        public var maximumColumns: Int
        /// Sheets profiled in full.
        public var maximumSheets: Int
        /// Sample values shown per column.
        public var maximumSamples: Int
        /// Distinct values counted before giving up on an exact count.
        public var distinctCeiling: Int
        /// Above this many populated cells in a sheet, columns are profiled from a strided
        /// sample and the profile says so.
        public var fullScanCellCeiling: Int
        /// Rows sampled per column when sampling.
        public var sampleRowTarget: Int

        public init(
            headerScanDepth: Int = 12,
            headerBodyDepth: Int = 24,
            headerThreshold: Double = 0.55,
            dominanceThreshold: Double = 0.8,
            maximumColumns: Int = 40,
            maximumSheets: Int = 12,
            maximumSamples: Int = 3,
            distinctCeiling: Int = 50,
            fullScanCellCeiling: Int = 2_000_000,
            sampleRowTarget: Int = 2000
        ) {
            self.headerScanDepth = headerScanDepth
            self.headerBodyDepth = headerBodyDepth
            self.headerThreshold = headerThreshold
            self.dominanceThreshold = dominanceThreshold
            self.maximumColumns = maximumColumns
            self.maximumSheets = maximumSheets
            self.maximumSamples = maximumSamples
            self.distinctCeiling = distinctCeiling
            self.fullScanCellCeiling = fullScanCellCeiling
            self.sampleRowTarget = sampleRowTarget
        }

        public static let `default` = Options()
    }

    public var options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    // MARK: - Workbook

    /// Profiles every sheet.
    public func profile(_ workbook: Workbook, path: String) -> WorkbookProfile {
        let described = workbook.sheets.prefix(options.maximumSheets)
        let remainder = workbook.sheets.dropFirst(described.count)
        return WorkbookProfile(
            fileName: (path as NSString).lastPathComponent,
            path: path,
            format: workbook.meta.sourceFormat,
            sheetCount: workbook.sheets.count,
            cellCount: workbook.cellCount,
            sheets: described.map { profile($0, styles: workbook.styles) },
            definedNameCount: workbook.definedNames.count,
            containsMacros: workbook.meta.containsMacros,
            readOnlyReason: workbook.meta.readOnlyReason,
            briefSheets: remainder.map {
                (name: $0.name, cellCount: $0.cells.count, usedRange: $0.usedRange?.a1String ?? "empty")
            }
        )
    }

    // MARK: - Sheet

    /// Profiles one sheet.
    public func profile(_ sheet: Sheet, styles: StyleTable) -> SheetProfile {
        guard let used = sheet.usedRange else {
            return SheetProfile(
                id: sheet.id, name: sheet.name, visibility: sheet.visibility, usedRange: nil,
                rowCount: 0, columnCount: 0, cellCount: 0, headerRow: nil, headerConfidence: 0,
                columns: [], omittedColumnCount: 0, formulaCount: 0,
                mergeCount: sheet.merges.count, frozen: sheet.frozen, isSampled: false
            )
        }

        let detected = detectHeader(sheet, used: used, styles: styles)
        let header = detected.row
        let bodyStart = header.map { $0 + 1 } ?? used.start.row
        let profiledColumns = min(used.columnCount, options.maximumColumns)
        let lastProfiled = used.start.column + profiledColumns - 1
        let sampled = sheet.cells.count > options.fullScanCellCeiling
        let stride = sampled ? max(1, (used.end.row - bodyStart + 1) / options.sampleRowTarget) : 1

        var accumulators: [Int: ColumnAccumulator] = [:]
        for column in used.start.column ... max(used.start.column, lastProfiled) {
            accumulators[column] = ColumnAccumulator(index: column)
        }

        if bodyStart <= used.end.row {
            let body = CellRange(
                rows: bodyStart ... used.end.row,
                columns: used.start.column ... max(used.start.column, lastProfiled)
            )
            sheet.cells.forEachCell(in: body) { ref, cell in
                guard stride == 1 || (ref.row - bodyStart) % stride == 0 else { return }
                accumulators[ref.column]?.add(cell, styles: styles, options: options)
            }
        }

        let bodyRows = max(0, used.end.row - bodyStart + 1)
        let sampledRows = stride == 1 ? bodyRows : (bodyRows + stride - 1) / stride
        let headerTexts = header.map { headerLabels(sheet, row: $0, range: used, styles: styles) } ?? [:]

        var columns: [ColumnProfile] = []
        columns.reserveCapacity(profiledColumns)
        for column in used.start.column ... max(used.start.column, lastProfiled) {
            guard var accumulator = accumulators[column] else { continue }
            accumulator.scaleForSampling(factor: stride, sampledRows: sampledRows, totalRows: bodyRows)
            columns.append(accumulator.finish(
                header: headerTexts[column],
                bodyRowCount: bodyRows,
                options: options
            ))
        }

        return SheetProfile(
            id: sheet.id,
            name: sheet.name,
            visibility: sheet.visibility,
            usedRange: used,
            rowCount: used.rowCount,
            columnCount: used.columnCount,
            cellCount: sheet.cells.count,
            headerRow: header,
            headerConfidence: detected.confidence,
            columns: columns,
            omittedColumnCount: used.columnCount - profiledColumns,
            formulaCount: columns.reduce(0) { $0 + $1.formulaCount },
            mergeCount: sheet.merges.count,
            frozen: sheet.frozen,
            isSampled: sampled
        )
    }

    // MARK: - Header detection

    /// The best header candidate in the first ``Options/headerScanDepth`` rows, or `nil`.
    ///
    /// Returns the confidence too, so `describe` can print *"header=row 1"* for a certain
    /// answer and *"header=row 3?"* for a marginal one, rather than asserting both in the same
    /// voice and letting an agent act on a guess it could not tell was a guess.
    func detectHeader(
        _ sheet: Sheet,
        used: CellRange,
        styles: StyleTable
    ) -> (row: Int?, confidence: Double) {
        let lastCandidate = min(used.end.row, used.start.row + options.headerScanDepth - 1)
        guard used.start.row <= lastCandidate else { return (nil, 0) }
        let columns = used.start.column ... min(used.end.column, used.start.column + options.maximumColumns - 1)

        var best: (row: Int, score: Double)?
        for row in used.start.row ... lastCandidate {
            let score = headerScore(sheet, row: row, columns: columns, used: used, styles: styles)
            guard score >= options.headerThreshold else { continue }
            if score > (best?.score ?? 0) + 0.0001 {
                best = (row, score)
            }
        }
        guard let best else { return (nil, 0) }
        return (best.row, min(1, best.score))
    }

    private func headerScore(
        _ sheet: Sheet,
        row: Int,
        columns: ClosedRange<Int>,
        used: CellRange,
        styles: StyleTable
    ) -> Double {
        var labels: [String] = []
        var textCells = 0
        var populated = 0
        for column in columns {
            guard let cell = sheet.cells[CellRef(row: row, column: column)], !cell.isBlank else { continue }
            populated += 1
            if case let .text(value) = cell.value {
                textCells += 1
                labels.append(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
        guard populated > 0 else { return 0 }
        let textShare = Double(textCells) / Double(populated)
        guard textShare >= 0.6 else { return 0 }

        // A header spans the columns the data spans. A one-cell title over eight columns of
        // data is a banner.
        let coverage = Double(populated) / Double(columns.count)
        guard coverage >= 0.5 else { return 0 }

        // **A header begins its table.** Either nothing is populated above it, or what is
        // covers strictly fewer columns — a title, a "generated on" line, a note. This is what
        // stops row 4 of an all-text sheet from scoring well merely because its particular
        // values happen not to recur further down: it is in the middle of a table, and a row in
        // the middle of a table is not that table's header no matter what it contains.
        if let above = nearestPopulatedRow(sheet, above: row, within: used, columns: columns),
           above.populated >= populated {
            return 0
        }

        var differing = 0
        var recurring = 0
        var compared = 0
        let bodyEnd = min(used.end.row, row + options.headerBodyDepth)
        guard row < bodyEnd else { return 0 }

        for column in columns {
            guard let candidate = sheet.cells[CellRef(row: row, column: column)], !candidate.isBlank else { continue }
            var sawValue = false
            var sawDifferentType = false
            var bodyPopulated = 0
            for bodyRow in (row + 1) ... bodyEnd {
                guard let cell = sheet.cells[CellRef(row: bodyRow, column: column)], !cell.isBlank else { continue }
                bodyPopulated += 1
                if !SheetProfiler.sameKind(candidate, cell, styles: styles) { sawDifferentType = true }
                if candidate.value == cell.value { sawValue = true }
            }
            guard bodyPopulated > 0 else { continue }
            compared += 1
            if sawDifferentType { differing += 1 }
            if sawValue { recurring += 1 }
        }
        guard compared > 0 else { return 0 }

        let differenceShare = Double(differing) / Double(compared)
        let recurrenceShare = Double(recurring) / Double(compared)
        let uniqueLabels = Set(labels).count
        let labelUniqueness = labels.isEmpty ? 0 : Double(uniqueLabels) / Double(labels.count)

        // Weights, and why: type difference is the signal that is almost never wrong when it
        // fires, so it carries the most. Recurrence is the veto — a value that reappears below
        // is not a name — so it subtracts rather than adds.
        var score = 0.30 * textShare
            + 0.40 * differenceShare
            + 0.15 * labelUniqueness
            + 0.15 * coverage
        score -= 0.55 * recurrenceShare
        return max(0, score)
    }

    /// The closest row above `row` that holds anything, and how many columns it fills.
    private func nearestPopulatedRow(
        _ sheet: Sheet,
        above row: Int,
        within used: CellRange,
        columns: ClosedRange<Int>
    ) -> (row: Int, populated: Int)? {
        guard row > used.start.row else { return nil }
        for candidate in stride(from: row - 1, through: used.start.row, by: -1) {
            let populated = columns.count { column in
                sheet.cells[CellRef(row: candidate, column: column)].map { !$0.isBlank } ?? false
            }
            if populated > 0 { return (candidate, populated) }
        }
        return nil
    }

    /// Whether two cells would be described by the same ``ColumnType``.
    private static func sameKind(_ lhs: Cell, _ rhs: Cell, styles: StyleTable) -> Bool {
        classify(lhs, styles: styles) == classify(rhs, styles: styles)
    }

    /// One cell's type, using the style's number format to separate a date from the number it
    /// is stored as — which is the whole reason a serial date is not simply "number".
    static func classify(_ cell: Cell, styles: StyleTable) -> ColumnType {
        switch cell.value {
        case .empty: return .empty
        case .boolean: return .boolean
        case .error: return .error
        case .text: return .text
        case let .number(value):
            let format = styles.numberFormat(for: cell.styleID)
            switch format.kind {
            case .date: return .date
            case .time: return .time
            case .dateTime: return .dateTime
            case .percentage: return .percentage
            case .currency, .accounting: return .currency
            default:
                return value.rounded() == value && value.magnitude < 1e15 ? .integer : .number
            }
        }
    }

    private func headerLabels(
        _ sheet: Sheet,
        row: Int,
        range: CellRange,
        styles: StyleTable
    ) -> [Int: String] {
        var labels: [Int: String] = [:]
        let last = min(range.end.column, range.start.column + options.maximumColumns - 1)
        for column in range.start.column ... max(range.start.column, last) {
            guard let cell = sheet.cells[CellRef(row: row, column: column)], !cell.isBlank else { continue }
            labels[column] = CellText.plain(cell, styles: styles)
        }
        return labels
    }
}

// MARK: - Per-column tally

/// Accumulates one column in a single pass.
///
/// Counters rather than a list of values: a 50,000-row column produces a fixed-size struct,
/// which is what makes the profile's cost proportional to the number of columns instead of the
/// number of cells.
private struct ColumnAccumulator {
    let index: Int
    var counts: [ColumnType: Int] = [:]
    var populated = 0
    var formulas = 0
    var errors = 0
    var trueCount = 0
    var falseCount = 0
    var minimum: Double?
    var maximum: Double?
    var sum: Double = 0
    var numericCount = 0
    var samples: [String] = []
    var seen: Set<String> = []
    var distinctOverflowed = false
    var formulaSample: String?
    var dominantIsTemporal = false

    mutating func add(_ cell: Cell, styles: StyleTable, options: SheetProfiler.Options) {
        guard !cell.isBlank else { return }
        populated += 1
        if let formula = cell.formula {
            formulas += 1
            if formulaSample == nil { formulaSample = formula }
        }
        let type = SheetProfiler.classify(cell, styles: styles)
        counts[type, default: 0] += 1
        if type.isTemporal { dominantIsTemporal = true }

        switch cell.value {
        case let .number(value):
            numericCount += 1
            sum += value
            minimum = min(minimum ?? value, value)
            maximum = max(maximum ?? value, value)
        case let .boolean(value):
            if value { trueCount += 1 } else { falseCount += 1 }
        case .error:
            errors += 1
        default:
            break
        }

        let rendered = CellText.plain(cell, styles: styles)
        if !distinctOverflowed, !rendered.isEmpty {
            if seen.count >= options.distinctCeiling {
                distinctOverflowed = true
                seen.removeAll(keepingCapacity: false)
            } else if seen.insert(rendered).inserted, samples.count < options.maximumSamples {
                samples.append(rendered)
            }
        }
    }

    /// Scales counts taken from a strided sample up to the whole column.
    ///
    /// Marked approximate in the output rather than presented as exact — a null count that is
    /// off by three is useful, a null count that is off by three and claims to be exact is a
    /// bug report.
    mutating func scaleForSampling(factor: Int, sampledRows: Int, totalRows: Int) {
        guard factor > 1, sampledRows > 0 else { return }
        let scale = Double(totalRows) / Double(sampledRows)
        populated = Int((Double(populated) * scale).rounded())
        formulas = Int((Double(formulas) * scale).rounded())
        errors = Int((Double(errors) * scale).rounded())
        trueCount = Int((Double(trueCount) * scale).rounded())
        falseCount = Int((Double(falseCount) * scale).rounded())
        sum *= scale
        for (key, value) in counts { counts[key] = Int((Double(value) * scale).rounded()) }
    }

    func finish(header: String?, bodyRowCount: Int, options: SheetProfiler.Options) -> ColumnProfile {
        // `12.5, 25, 37.5` is a number column, not a mixed one. `.integer` is a *refinement* of
        // `.number` rather than a rival to it, so the two are folded together before dominance
        // is measured and split apart again afterwards — otherwise a column that happens to
        // contain one round figure among its decimals gets reported as a data-quality problem.
        var folded: [ColumnType: Int] = [:]
        for (candidate, count) in counts {
            folded[candidate == .integer ? .number : candidate, default: 0] += count
        }
        let leader = folded.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue > rhs.key.rawValue : lhs.value < rhs.value
        }
        let purity = populated > 0 ? Double(leader?.value ?? 0) / Double(populated) : 0
        let type: ColumnType
        if populated == 0 {
            type = .empty
        } else if purity >= options.dominanceThreshold {
            let dominant = leader?.key ?? .mixed
            type = dominant == .number && counts[.integer] == populated ? .integer : dominant
        } else {
            type = .mixed
        }
        return ColumnProfile(
            index: index,
            letter: CellRef.columnLetters(index),
            header: header,
            type: type,
            nullCount: max(0, bodyRowCount - populated),
            populatedCount: populated,
            formulaCount: formulas,
            formulaSample: formulaSample,
            errorCount: errors,
            samples: samples,
            distinctCount: distinctOverflowed ? nil : seen.count,
            minimum: numericCount > 0 ? minimum : nil,
            maximum: numericCount > 0 ? maximum : nil,
            sum: numericCount > 0 ? sum : nil,
            trueCount: trueCount,
            falseCount: falseCount,
            purity: purity
        )
    }
}
