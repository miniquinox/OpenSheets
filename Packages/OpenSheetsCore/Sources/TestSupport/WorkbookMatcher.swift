//
//  WorkbookMatcher.swift
//  TestSupport
//
//  Comparisons that say what is wrong, not just that something is.
//

import Foundation
import SheetModel

/// One difference, described well enough to fix without opening a debugger.
///
/// `"not equal"` costs an hour. `"Data!D7 value: expected 42, got 42.0000001 (Δ 1.0e-07,
/// tolerance 1.0e-09)"` costs a minute, and usually names the bug outright — that one, for
/// instance, is a serial-date conversion going through `Float`.
public struct Mismatch: Sendable, Hashable, CustomStringConvertible {
    /// What kind of difference this is, so a report can group and a test can filter.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// The expectation names something the workbook does not have.
        case missing
        /// The workbook has something the expectation does not mention.
        case unexpected
        case value
        case formula
        case numberFormat
        case flags
        case style
        /// Sheet names, order, merges, panes, used range, dimension.
        case structure
        /// Defined names, metadata, passthrough entries.
        case workbook
    }

    public var kind: Kind
    /// Where the difference is, in a form you can paste into a search: `Data!D7`, `Data.merges`,
    /// `workbook.definedNames[Revenue]`.
    public var path: String
    public var expected: String
    public var actual: String
    /// The extra sentence that turns a difference into a diagnosis.
    public var detail: String?

    public init(kind: Kind, path: String, expected: String, actual: String, detail: String? = nil) {
        self.kind = kind
        self.path = path
        self.expected = expected
        self.actual = actual
        self.detail = detail
    }

    public var description: String {
        var text = "\(path) \(kind.rawValue): expected \(expected), got \(actual)"
        if let detail { text += " (\(detail))" }
        return text
    }
}

/// What a comparison checks and how tightly.
public struct MatchOptions: Sendable, Hashable {
    /// Absolute tolerance for numeric equality.
    ///
    /// Not zero by default. An xlsx stores `0.1` as the shortest decimal that round-trips
    /// through IEEE 754 double, and a reader that goes through `Decimal` or through a locale
    /// formatter lands a few ulps away. Zero tolerance would turn that into 400 failures that
    /// all say the same thing, and hide the one that matters.
    public var absoluteTolerance: Double
    /// Relative tolerance, applied for magnitudes above 1.
    public var relativeTolerance: Double
    public var checksFormulas: Bool
    public var checksNumberFormats: Bool
    public var checksFlags: Bool
    public var checksMerges: Bool
    public var checksPanes: Bool
    public var checksUsedRange: Bool
    public var checksDefinedNames: Bool
    /// Whether a cell the workbook has and the sidecar does not is a failure.
    ///
    /// `false` by default: sidecars carry a *sample* of cells for the big fixtures, and
    /// demanding exhaustiveness would make `perf/100k-cells.xlsx` unusable as ground truth.
    public var requiresExhaustiveCells: Bool
    /// How styles are compared when two workbooks are compared to each other.
    public var styleComparison: StyleComparison
    /// How many mismatches ``MatchResult/report`` prints before summarising the rest.
    public var maximumReportedMismatches: Int

    /// How to compare a cell's style across two workbooks.
    public enum StyleComparison: String, Sendable, Hashable, CaseIterable {
        /// Do not compare styles.
        case ignore
        /// Compare ``StyleID`` values. This is the strict xlsx round-trip contract: a save that
        /// renumbers `cellXfs` rewrites every cell's `s=` attribute and loses byte identity.
        case id
        /// Compare the resolved ``CellStyle``. The right check after a format conversion, where
        /// indices legitimately change but appearance must not.
        case resolved
    }

    public init(
        absoluteTolerance: Double = 1e-9,
        relativeTolerance: Double = 1e-12,
        checksFormulas: Bool = true,
        checksNumberFormats: Bool = true,
        checksFlags: Bool = true,
        checksMerges: Bool = true,
        checksPanes: Bool = true,
        checksUsedRange: Bool = true,
        checksDefinedNames: Bool = true,
        requiresExhaustiveCells: Bool = false,
        styleComparison: StyleComparison = .id,
        maximumReportedMismatches: Int = 25
    ) {
        self.absoluteTolerance = absoluteTolerance
        self.relativeTolerance = relativeTolerance
        self.checksFormulas = checksFormulas
        self.checksNumberFormats = checksNumberFormats
        self.checksFlags = checksFlags
        self.checksMerges = checksMerges
        self.checksPanes = checksPanes
        self.checksUsedRange = checksUsedRange
        self.checksDefinedNames = checksDefinedNames
        self.requiresExhaustiveCells = requiresExhaustiveCells
        self.styleComparison = styleComparison
        self.maximumReportedMismatches = maximumReportedMismatches
    }

    /// Everything the sidecar states, with a tolerance that forgives the last ulp.
    public static let `default` = MatchOptions()

    /// Exact numbers, exhaustive cells, style indices preserved. The xlsx round-trip contract.
    public static let strict = MatchOptions(
        absoluteTolerance: 0,
        relativeTolerance: 0,
        requiresExhaustiveCells: true,
        styleComparison: .id
    )

    /// Values only — no formulas, formats, flags or structure. For a CSV round trip, which
    /// cannot carry any of those by definition.
    public static let valuesOnly = MatchOptions(
        checksFormulas: false,
        checksNumberFormats: false,
        checksFlags: false,
        checksMerges: false,
        checksPanes: false,
        checksUsedRange: false,
        checksDefinedNames: false,
        styleComparison: .ignore
    )
}

/// The outcome of a comparison.
public struct MatchResult: Sendable {
    /// What is wrong, in the order found: workbook level first, then sheet by sheet, then cells
    /// in row-major order. Deterministic, so two runs produce the same first line.
    public var mismatches: [Mismatch]
    /// Checks the sidecar's `skipChecks` exempted, named so an exemption is visible rather than
    /// invisible.
    public var skipped: [String]
    /// How many individual assertions ran. A green result with `checked == 0` means the
    /// comparison found nothing to compare, which is a failure of the test, not a pass.
    public var checked: Int

    public init(mismatches: [Mismatch] = [], skipped: [String] = [], checked: Int = 0) {
        self.mismatches = mismatches
        self.skipped = skipped
        self.checked = checked
    }

    public var matches: Bool { mismatches.isEmpty }

    /// A report fit to paste into a failure message.
    public func report(limit: Int = 25) -> String {
        // Deduplicated: a per-sheet exemption such as `formulaText:Shared` is appended once per
        // cell it covers, and a report that says so forty times is a report nobody reads.
        let exemptions = Set(skipped).sorted()
        guard !matches else {
            var text = "matched (\(checked) checks)"
            if !exemptions.isEmpty { text += ", skipped: \(exemptions.joined(separator: ", "))" }
            return text
        }
        var lines = ["\(mismatches.count) mismatch(es) out of \(checked) checks:"]
        for mismatch in mismatches.prefix(limit) {
            lines.append("  • \(mismatch)")
        }
        if mismatches.count > limit {
            lines.append("  … and \(mismatches.count - limit) more")
        }
        if !exemptions.isEmpty {
            lines.append("  (skipped: \(exemptions.joined(separator: ", ")))")
        }
        return lines.joined(separator: "\n")
    }

    fileprivate mutating func record(_ mismatch: Mismatch) {
        mismatches.append(mismatch)
    }
}

/// Compares a workbook against a sidecar, or against another workbook.
///
/// Every entry point returns a ``MatchResult`` rather than throwing or asserting, so the caller
/// decides whether a difference is a failure. Round-trip tests want a failure; an
/// exploratory test may want to print and continue.
public enum WorkbookMatcher {
    // MARK: - Against the corpus

    /// Compares a parsed workbook against its `.expected.json` sidecar.
    public static func compare(
        _ workbook: Workbook,
        to expected: ExpectedWorkbook,
        options: MatchOptions = .default
    ) -> MatchResult {
        var result = MatchResult()
        compareDateSystem(workbook, expected, into: &result)
        compareSheetRoster(workbook, expected, into: &result)
        for expectedSheet in expected.sheets ?? [] {
            guard let sheet = workbook.sheet(named: expectedSheet.name) else { continue }
            compareSheet(sheet, to: expectedSheet, in: workbook, expected: expected, options: options, into: &result)
        }
        if options.checksDefinedNames {
            compareDefinedNames(workbook, expected, into: &result)
        }
        return result
    }

    private static func compareDateSystem(
        _ workbook: Workbook,
        _ expected: ExpectedWorkbook,
        into result: inout MatchResult
    ) {
        guard expected.dateSystem != nil else { return }
        result.checked += 1
        let wanted = expected.resolvedDateSystem
        if workbook.meta.dateSystem != wanted {
            result.record(Mismatch(
                kind: .workbook,
                path: "workbook.dateSystem",
                expected: wanted.rawValue,
                actual: workbook.meta.dateSystem.rawValue,
                detail: "the 1904 epoch shifts every date by 1,462 days"
            ))
        }
    }

    private static func compareSheetRoster(
        _ workbook: Workbook,
        _ expected: ExpectedWorkbook,
        into result: inout MatchResult
    ) {
        guard let expectedSheets = expected.sheets else { return }
        result.checked += 1
        let wanted = expectedSheets.sorted { $0.index < $1.index }.map(\.name)
        let actual = workbook.sheets.map(\.name)
        if wanted != actual {
            result.record(Mismatch(
                kind: .structure,
                path: "workbook.sheets",
                expected: wanted.joined(separator: ", "),
                actual: actual.joined(separator: ", "),
                detail: "tab order and names must both match"
            ))
        }
        for expectedSheet in expectedSheets {
            result.checked += 1
            guard let sheet = workbook.sheet(named: expectedSheet.name) else {
                result.record(Mismatch(
                    kind: .missing,
                    path: "workbook.sheets[\(expectedSheet.name)]",
                    expected: "present",
                    actual: "absent"
                ))
                continue
            }
            if sheet.visibility != expectedSheet.resolvedVisibility {
                result.record(Mismatch(
                    kind: .structure,
                    path: "\(sheet.name).visibility",
                    expected: expectedSheet.resolvedVisibility.rawValue,
                    actual: sheet.visibility.rawValue
                ))
            }
        }
    }

    private static func compareDefinedNames(
        _ workbook: Workbook,
        _ expected: ExpectedWorkbook,
        into result: inout MatchResult
    ) {
        guard let names = expected.definedNames else { return }
        for (name, refersTo) in names.sorted(by: { $0.key < $1.key }) {
            result.checked += 1
            guard let defined = workbook.definedName(name) else {
                result.record(Mismatch(
                    kind: .missing,
                    path: "workbook.definedNames[\(name)]",
                    expected: refersTo,
                    actual: "absent"
                ))
                continue
            }
            if defined.formula != refersTo {
                result.record(Mismatch(
                    kind: .workbook,
                    path: "workbook.definedNames[\(name)]",
                    expected: refersTo,
                    actual: defined.formula
                ))
            }
        }
    }

    /// Everything ``compareCell(_:to:at:context:into:)`` needs that is not the cell itself.
    ///
    /// A struct rather than five more parameters: nine positional arguments is where a call site
    /// stops being readable and starts being a place to transpose two of them.
    private struct CellContext {
        var styles: StyleTable
        var effectiveStyleID: StyleID
        var sidecar: ExpectedWorkbook
        var sheetName: String
        var options: MatchOptions
    }

    private static func compareSheet(
        _ sheet: Sheet,
        to expected: ExpectedSheet,
        in workbook: Workbook,
        expected sidecar: ExpectedWorkbook,
        options: MatchOptions,
        into result: inout MatchResult
    ) {
        compareSheetStructure(sheet, to: expected, options: options, into: &result)
        for (address, expectedCell) in (expected.cells ?? [:]).sorted(by: { sortKey($0.key) < sortKey($1.key) }) {
            let check = "cellValue:\(sheet.name)!\(address)"
            if sidecar.skips(check) || sidecar.skips("cellValue") {
                result.skipped.append(check)
                continue
            }
            guard let ref = CellRef(a1: address) else {
                result.record(Mismatch(
                    kind: .structure,
                    path: "\(sheet.name)!\(address)",
                    expected: "a valid A1 address",
                    actual: "unparseable",
                    detail: "the sidecar itself is wrong"
                ))
                continue
            }
            let context = CellContext(
                styles: workbook.styles,
                effectiveStyleID: sheet.effectiveStyleID(at: ref),
                sidecar: sidecar,
                sheetName: sheet.name,
                options: options
            )
            compareCell(
                sheet.cells[ref],
                to: expectedCell,
                at: "\(sheet.name)!\(address)",
                context: context,
                into: &result
            )
        }
        if options.requiresExhaustiveCells, let cells = expected.cells {
            compareForExtraCells(sheet, expectedAddresses: Set(cells.keys), into: &result)
        }
    }

    private static func compareSheetStructure(
        _ sheet: Sheet,
        to expected: ExpectedSheet,
        options: MatchOptions,
        into result: inout MatchResult
    ) {
        if options.checksUsedRange, let wanted = expected.usedRange {
            result.checked += 1
            // The sidecar's usedRange is the union of every cell AND every merge (Wave 1
            // addendum §5), which is `Sheet.usedRange` widened by the merges — not
            // `formattedExtent`, which also swallows whole-column formatting.
            let actual = mergeAwareUsedRange(sheet)
            let actualText = actual?.a1String(collapseSingleCell: false) ?? "nil"
            if actualText != wanted {
                result.record(Mismatch(
                    kind: .structure,
                    path: "\(sheet.name).usedRange",
                    expected: wanted,
                    actual: actualText,
                    detail: "a merge widens the used range even where the covered cells have no <c> element"
                ))
            }
        }
        if options.checksMerges, let wanted = expected.merges {
            result.checked += 1
            let actual = sheet.merges.map { $0.a1String(collapseSingleCell: false) }.sorted()
            if actual != wanted.sorted() {
                result.record(Mismatch(
                    kind: .structure,
                    path: "\(sheet.name).merges",
                    expected: wanted.sorted().joined(separator: " "),
                    actual: actual.joined(separator: " ")
                ))
            }
        }
        if options.checksPanes, let wanted = expected.frozen {
            result.checked += 1
            let wantedRows = wanted.rows ?? 0
            let wantedColumns = wanted.columns ?? 0
            if sheet.frozen.frozenRows != wantedRows || sheet.frozen.frozenColumns != wantedColumns {
                result.record(Mismatch(
                    kind: .structure,
                    path: "\(sheet.name).frozen",
                    expected: "\(wantedRows) rows, \(wantedColumns) columns",
                    actual: "\(sheet.frozen.frozenRows) rows, \(sheet.frozen.frozenColumns) columns"
                ))
            }
        }
        for (address, target) in (expected.hyperlinks ?? [:]).sorted(by: { $0.key < $1.key }) {
            result.checked += 1
            guard let ref = CellRef(a1: address) else { continue }
            let actual = sheet.hyperlinks[ref]?.target
            if actual != target {
                result.record(Mismatch(
                    kind: .structure,
                    path: "\(sheet.name).hyperlinks[\(address)]",
                    expected: target,
                    actual: actual ?? "absent",
                    detail: "a hyperlink target is never fetched, but it must round-trip"
                ))
            }
        }
    }

    private static func compareForExtraCells(
        _ sheet: Sheet,
        expectedAddresses: Set<String>,
        into result: inout MatchResult
    ) {
        guard let used = sheet.usedRange else { return }
        var extras: [String] = []
        sheet.cells.forEachCell(in: used) { ref, cell in
            guard !cell.isBlank else { return }
            let address = ref.a1String
            if !expectedAddresses.contains(address) { extras.append(address) }
        }
        guard !extras.isEmpty else { return }
        result.checked += 1
        result.record(Mismatch(
            kind: .unexpected,
            path: "\(sheet.name).cells",
            expected: "only the \(expectedAddresses.count) cells the sidecar names",
            actual: "\(extras.count) more: \(extras.sorted().prefix(8).joined(separator: " "))"
        ))
    }

    private static func compareCell(
        _ cell: Cell?,
        to expected: ExpectedCell,
        at path: String,
        context: CellContext,
        into result: inout MatchResult
    ) {
        let options = context.options
        result.checked += 1
        let actual = cell ?? Cell()
        if let wanted = expected.expectedValue {
            if !valuesMatch(wanted, actual.value, options: options) {
                result.record(valueMismatch(path: path, expected: wanted, actual: actual.value, options: options))
            }
        } else if expected.type != "empty", actual.value.isEmpty {
            // `"value": null` with a non-empty type means "a value must exist, its content is
            // not asserted" — the TODAY() case.
            result.record(Mismatch(
                kind: .missing,
                path: path,
                expected: "some \(expected.type) value",
                actual: "<empty>",
                detail: "the sidecar asserts existence, not content"
            ))
        }
        if options.checksFormulas, let wantedFormula = expected.formula {
            let check = "formulaText:\(context.sheetName)"
            if context.sidecar.skips(check) || context.sidecar.skips("formulaText") {
                result.skipped.append(check)
            } else {
                result.checked += 1
                if actual.formula != wantedFormula {
                    result.record(Mismatch(
                        kind: .formula,
                        path: path,
                        expected: "=\(wantedFormula)",
                        actual: actual.formula.map { "=\($0)" } ?? "no formula",
                        detail: formulaHint(wanted: wantedFormula, actual: actual.formula)
                    ))
                }
            }
        }
        if options.checksNumberFormats, let wantedFormat = expected.numberFormat {
            result.checked += 1
            let actualFormat = context.styles.numberFormat(for: context.effectiveStyleID).formatCode
            if actualFormat != wantedFormat {
                result.record(Mismatch(
                    kind: .numberFormat,
                    path: path,
                    expected: wantedFormat,
                    actual: actualFormat,
                    detail: "resolved through \(context.effectiveStyleID)"
                ))
            }
        }
        if options.checksFlags, expected.flags != nil {
            result.checked += 1
            let wantedFlags = expected.expectedFlags
            if !actual.flags.isSuperset(of: wantedFlags) {
                result.record(Mismatch(
                    kind: .flags,
                    path: path,
                    expected: describe(flags: wantedFlags),
                    actual: describe(flags: actual.flags)
                ))
            }
        }
    }

    // MARK: - Workbook against workbook

    /// Compares two workbooks — the round-trip contract in PLAN.md §5.2.
    public static func compare(
        _ lhs: Workbook,
        _ rhs: Workbook,
        options: MatchOptions = .default
    ) -> MatchResult {
        var result = MatchResult()
        result.checked += 1
        if lhs.sheets.map(\.name) != rhs.sheets.map(\.name) {
            result.record(Mismatch(
                kind: .structure,
                path: "workbook.sheets",
                expected: lhs.sheets.map(\.name).joined(separator: ", "),
                actual: rhs.sheets.map(\.name).joined(separator: ", ")
            ))
        }
        for sheet in lhs.sheets {
            guard let other = rhs.sheet(named: sheet.name) else { continue }
            compareSheets(sheet, other, lhsStyles: lhs.styles, rhsStyles: rhs.styles, options: options, into: &result)
        }
        comparePassthrough(lhs, rhs, into: &result)
        if options.checksDefinedNames {
            compareDefinedNames(lhs, rhs, into: &result)
        }
        return result
    }

    /// Compares two sheets cell by cell.
    public static func compare(
        _ lhs: Sheet,
        _ rhs: Sheet,
        styles: StyleTable = .empty,
        options: MatchOptions = .default
    ) -> MatchResult {
        var result = MatchResult()
        compareSheets(lhs, rhs, lhsStyles: styles, rhsStyles: styles, options: options, into: &result)
        return result
    }

    private static func compareSheets(
        _ lhs: Sheet,
        _ rhs: Sheet,
        lhsStyles: StyleTable,
        rhsStyles: StyleTable,
        options: MatchOptions,
        into result: inout MatchResult
    ) {
        if options.checksMerges {
            result.checked += 1
            let left = lhs.merges.map(\.a1String).sorted()
            let right = rhs.merges.map(\.a1String).sorted()
            if left != right {
                result.record(Mismatch(
                    kind: .structure,
                    path: "\(lhs.name).merges",
                    expected: left.joined(separator: " "),
                    actual: right.joined(separator: " ")
                ))
            }
        }
        if options.checksPanes {
            result.checked += 1
            if lhs.frozen != rhs.frozen {
                result.record(Mismatch(
                    kind: .structure,
                    path: "\(lhs.name).frozen",
                    expected: "\(lhs.frozen.frozenRows)×\(lhs.frozen.frozenColumns)",
                    actual: "\(rhs.frozen.frozenRows)×\(rhs.frozen.frozenColumns)"
                ))
            }
        }
        compareFragments(lhs, rhs, into: &result)
        compareCells(lhs, rhs, lhsStyles: lhsStyles, rhsStyles: rhsStyles, options: options, into: &result)
    }

    private static func compareFragments(_ lhs: Sheet, _ rhs: Sheet, into result: inout MatchResult) {
        result.checked += 1
        let left = lhs.sheetLevelFragments.map(\.elementName).sorted()
        let right = rhs.sheetLevelFragments.map(\.elementName).sorted()
        if left != right {
            result.record(Mismatch(
                kind: .structure,
                path: "\(lhs.name).sheetLevelFragments",
                expected: left.joined(separator: " "),
                actual: right.joined(separator: " "),
                detail: "dropping one of these orphans the part it points at and Excel calls the file damaged"
            ))
            return
        }
        for (index, fragment) in lhs.sheetLevelFragments.enumerated() where
            rhs.sheetLevelFragments[index].xml != fragment.xml {
            result.checked += 1
            result.record(Mismatch(
                kind: .structure,
                path: "\(lhs.name).sheetLevelFragments[\(fragment.elementName)]",
                expected: truncate(fragment.xml),
                actual: truncate(rhs.sheetLevelFragments[index].xml),
                detail: "fragments are kept byte-for-byte; a byte you cleaned up no longer matches the producer"
            ))
        }
    }

    private static func compareCells(
        _ lhs: Sheet,
        _ rhs: Sheet,
        lhsStyles: StyleTable,
        rhsStyles: StyleTable,
        options: MatchOptions,
        into result: inout MatchResult
    ) {
        var union = lhs.usedRange
        if let right = rhs.usedRange { union = union.map { $0.union(right) } ?? right }
        guard let union else { return }
        var refs = Set<CellRef>()
        lhs.cells.forEachCell(in: union) { ref, _ in refs.insert(ref) }
        rhs.cells.forEachCell(in: union) { ref, _ in refs.insert(ref) }
        for ref in refs.sorted() {
            result.checked += 1
            let left = lhs.cells[ref]
            let right = rhs.cells[ref]
            let path = "\(lhs.name)!\(ref.a1String)"
            guard let left else {
                result.record(Mismatch(kind: .unexpected, path: path, expected: "absent", actual: "\(right ?? Cell())"))
                continue
            }
            guard let right else {
                result.record(Mismatch(kind: .missing, path: path, expected: "\(left)", actual: "absent"))
                continue
            }
            if !valuesMatch(left.value, right.value, options: options) {
                result.record(valueMismatch(path: path, expected: left.value, actual: right.value, options: options))
            }
            if options.checksFormulas, left.formula != right.formula {
                result.record(Mismatch(
                    kind: .formula,
                    path: path,
                    expected: left.formula.map { "=\($0)" } ?? "no formula",
                    actual: right.formula.map { "=\($0)" } ?? "no formula",
                    detail: formulaHint(wanted: left.formula ?? "", actual: right.formula)
                ))
            }
            if options.checksFlags, left.flags != right.flags {
                result.record(Mismatch(
                    kind: .flags,
                    path: path,
                    expected: describe(flags: left.flags),
                    actual: describe(flags: right.flags)
                ))
            }
            compareStyle(
                left, right, path: path, lhsStyles: lhsStyles, rhsStyles: rhsStyles, options: options, into: &result
            )
        }
    }

    private static func compareStyle(
        _ left: Cell,
        _ right: Cell,
        path: String,
        lhsStyles: StyleTable,
        rhsStyles: StyleTable,
        options: MatchOptions,
        into result: inout MatchResult
    ) {
        switch options.styleComparison {
        case .ignore:
            return
        case .id:
            if left.styleID != right.styleID {
                result.record(Mismatch(
                    kind: .style,
                    path: path,
                    expected: left.styleID.description,
                    actual: right.styleID.description,
                    detail: "renumbering cellXfs rewrites every cell's s= attribute and loses byte identity"
                ))
            }
        case .resolved:
            let leftStyle = lhsStyles[left.styleID]
            let rightStyle = rhsStyles[right.styleID]
            if leftStyle != rightStyle {
                result.record(Mismatch(
                    kind: .style,
                    path: path,
                    expected: describe(style: leftStyle, in: lhsStyles),
                    actual: describe(style: rightStyle, in: rhsStyles)
                ))
            }
        }
    }

    private static func comparePassthrough(_ lhs: Workbook, _ rhs: Workbook, into result: inout MatchResult) {
        let left = Set(lhs.passthrough.paths)
        let right = Set(rhs.passthrough.paths)
        result.checked += 1
        let lost = left.subtracting(right).sorted()
        if !lost.isEmpty {
            result.record(Mismatch(
                kind: .missing,
                path: "workbook.passthrough",
                expected: "\(left.count) entries",
                actual: "\(right.count) entries",
                detail: "dropped: \(lost.prefix(8).joined(separator: ", "))"
            ))
        }
        for path in left.intersection(right).sorted() {
            guard let leftEntry = lhs.passthrough[path], let rightEntry = rhs.passthrough[path] else { continue }
            result.checked += 1
            if leftEntry.compressedData != rightEntry.compressedData {
                result.record(Mismatch(
                    kind: .workbook,
                    path: "workbook.passthrough[\(path)]",
                    expected: "\(leftEntry.compressedData.count) bytes, crc \(leftEntry.crc32)",
                    actual: "\(rightEntry.compressedData.count) bytes, crc \(rightEntry.crc32)",
                    detail: "an unmodelled part must be copied through, not re-encoded"
                ))
            }
        }
    }

    private static func compareDefinedNames(_ lhs: Workbook, _ rhs: Workbook, into result: inout MatchResult) {
        for key in Set(lhs.definedNames.keys).union(rhs.definedNames.keys).sorted() {
            result.checked += 1
            let left = lhs.definedNames[key]
            let right = rhs.definedNames[key]
            if left?.formula != right?.formula {
                result.record(Mismatch(
                    kind: .workbook,
                    path: "workbook.definedNames[\(key)]",
                    expected: left?.formula ?? "absent",
                    actual: right?.formula ?? "absent"
                ))
            }
        }
    }

    // MARK: - Value comparison

    /// Whether two values are equal within the options' tolerance.
    public static func valuesMatch(_ lhs: CellValue, _ rhs: CellValue, options: MatchOptions = .default) -> Bool {
        guard case let .number(left) = lhs, case let .number(right) = rhs else { return lhs == rhs }
        if left == right { return true }
        if left.isNaN, right.isNaN { return true }
        let delta = abs(left - right)
        if delta <= options.absoluteTolerance { return true }
        let scale = max(abs(left), abs(right))
        return scale > 1 && delta <= scale * options.relativeTolerance
    }

    private static func valueMismatch(
        path: String,
        expected: CellValue,
        actual: CellValue,
        options: MatchOptions
    ) -> Mismatch {
        var detail: String?
        if case let .number(left) = expected, case let .number(right) = actual {
            let delta = abs(left - right)
            var text = "Δ \(format(scientific: delta)), tolerance \(format(scientific: options.absoluteTolerance))"
            if abs(delta - 1462) < 1 {
                // The single commonest wrong number in a spreadsheet reader.
                text += "; 1462 days is exactly the 1900↔1904 epoch shift"
            } else if left != 0, abs(delta / left) > 0.9, abs(delta / left) < 1.1 {
                text += "; off by ~100%, check for a sign or an off-by-one row"
            }
            detail = text
        }
        if expected.isError, actual.isError {
            detail = "Excel's error kinds are the target; LibreOffice disagrees on SQRT(-1) and OFFSET"
        }
        return Mismatch(
            kind: .value,
            path: path,
            expected: describe(value: expected),
            actual: describe(value: actual),
            detail: detail
        )
    }

    // MARK: - Formatting

    /// A value spelled the way a human reads it: `42`, not `42.0`; `"text"` with the quotes.
    public static func describe(value: CellValue) -> String {
        guard case let .number(number) = value else { return value.description }
        return format(number: number)
    }

    /// A double without a trailing `.0` when it is integral, and in full precision when it is not.
    public static func format(number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number < 0 ? "-∞" : "∞" }
        if number == number.rounded(), abs(number) < 1e15 {
            return String(Int64(number))
        }
        return String(number)
    }

    private static func format(scientific value: Double) -> String {
        String(format: "%.3g", value)
    }

    private static func describe(flags: CellFlags) -> String {
        guard !flags.isEmpty else { return "none" }
        let names: [(CellFlags, String)] = [
            (.staleCache, "staleCache"), (.externalLink, "externalLink"),
            (.unsupportedFormula, "unsupportedFormula"), (.arrayFormula, "arrayFormula"),
            (.sharedFormulaExpansion, "sharedFormulaExpansion"), (.hyperlink, "hyperlink"),
            (.richText, "richText"), (.inlineString, "inlineString"),
            (.comment, "comment"), (.dataValidation, "dataValidation"),
        ]
        return names.filter { flags.contains($0.0) }.map(\.1).joined(separator: "|")
    }

    private static func describe(style: CellStyle, in table: StyleTable) -> String {
        let format = table.numberFormat(id: style.numberFormatID).formatCode
        var parts = ["fmt:\(format)"]
        if style.font != .default { parts.append("font:\(style.font.name)@\(style.font.size)") }
        if style.fill != .none { parts.append("fill:\(style.fill.pattern.rawValue)") }
        if style.border.isVisible { parts.append("border") }
        if style.alignment != .default { parts.append("align:\(style.alignment.horizontal.rawValue)") }
        return parts.joined(separator: " ")
    }

    private static func formulaHint(wanted: String, actual: String?) -> String? {
        guard let actual else { return nil }
        if wanted.hasPrefix("_xlfn."), !actual.hasPrefix("_xlfn.") {
            return "the file stores newer functions with an _xlfn. prefix; a bare name shows #NAME? in Excel"
        }
        if actual.hasPrefix("=") {
            return "the leading = is a formula-bar affordance and is not stored in the model"
        }
        return nil
    }

    private static func truncate(_ text: String, limit: Int = 120) -> String {
        text.count <= limit ? text : "\(text.prefix(limit))… (\(text.count) chars)"
    }

    /// The used range widened by the sheet's merges, which is what the sidecars record.
    public static func mergeAwareUsedRange(_ sheet: Sheet) -> CellRange? {
        sheet.merges.reduce(sheet.usedRange) { partial, merge in
            partial.map { $0.union(merge) } ?? merge
        }
    }

    /// Row-major sort key for an A1 address, so a report reads top-to-bottom rather than
    /// alphabetically (which would put `A10` before `A2`).
    private static func sortKey(_ address: String) -> (Int, Int) {
        guard let ref = CellRef(a1: address) else { return (Int.max, Int.max) }
        return (ref.row, ref.column)
    }
}
