//
//  WorkbookBuilder.swift
//  TestSupport
//
//  A fluent builder so a test can state the workbook it needs in one breath.
//

import Foundation
import SheetModel

/// Builds a ``Workbook`` from a chain of calls, so a test states its fixture inline instead of
/// assembling one out of `Sheet`, `CellStore`, and `StyleTable` by hand.
///
/// ```swift
/// let workbook = try WorkbookBuilder()
///     .sheet("Data")
///     .cell("A1", 42)
///     .formula("B1", "A1*2", cached: 84)
///     .sheet("Notes")
///     .cell("A1", "hello")
///     .build()
/// ```
///
/// **Errors are deferred to ``build()``.** A chain that threw on every link would need a `try`
/// per call and could not be written as one expression, so a bad A1 string or an out-of-range
/// reference is remembered and rethrown at the end. The *first* failure wins: later calls after
/// a failure are no-ops, which keeps the reported error the one that actually caused the
/// problem rather than a cascade from it.
///
/// The builder is a value type. `let base = WorkbookBuilder().sheet("Data").cell("A1", 1)`
/// followed by two different continuations gives two independent workbooks, which is how a
/// parameterised test shares a common prefix.
public struct WorkbookBuilder: Sendable {
    private var sheets: [Sheet] = []
    private var definedNames: [String: DefinedName] = [:]
    private var styles: StyleTable = .empty
    private var meta = WorkbookMeta()
    private var passthrough: OpaqueParts = .empty
    private var currentIndex: Int?
    private var deferredError: SheetError?

    public init() {}

    // MARK: - Sheets

    /// Selects the sheet called `name`, creating it at the end of the tab order if it is new.
    ///
    /// Every subsequent cell call lands on this sheet until the next ``sheet(_:id:visibility:)``.
    /// Selecting an existing sheet does not reset it, so a test can come back and add more.
    public func sheet(_ name: String, id: SheetID? = nil, visibility: SheetVisibility = .visible) -> Self {
        modifying { builder in
            if let existing = builder.sheets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                builder.currentIndex = existing
                return
            }
            do {
                try Limits.validateSheetName(name)
            } catch {
                builder.record(error)
                return
            }
            let assigned = id ?? SheetID(Int32(builder.sheets.count + 1))
            builder.sheets.append(Sheet(id: assigned, name: name, visibility: visibility))
            builder.currentIndex = builder.sheets.count - 1
        }
    }

    /// Changes the current sheet's visibility.
    public func visibility(_ visibility: SheetVisibility) -> Self {
        onSheet { $0.visibility = visibility }
    }

    /// Freezes `rows` rows and `columns` columns on the current sheet.
    public func freeze(rows: Int = 0, columns: Int = 0) -> Self {
        onSheet { $0.frozen = FrozenPanes(frozenRows: rows, frozenColumns: columns) }
    }

    /// Splits the current sheet's panes at the given point sizes, without freezing.
    public func split(horizontal: Double? = nil, vertical: Double? = nil) -> Self {
        onSheet { $0.frozen = FrozenPanes(horizontalSplit: horizontal, verticalSplit: vertical) }
    }

    /// Adds a merged region, written in A1 range notation: `merge("A1:D1")`.
    public func merge(_ a1: String) -> Self {
        withRange(a1) { sheet, range in sheet.merges.append(range) }
    }

    /// Sets a width in points across a closed range of **0-based** column indices.
    public func columnWidth(_ width: Double, columns: ClosedRange<Int>) -> Self {
        onSheet { $0.columnWidths.setValue(width, in: columns) }
    }

    /// Sets a height in points across a closed range of **0-based** row indices.
    public func rowHeight(_ height: Double, rows: ClosedRange<Int>) -> Self {
        onSheet { $0.rowHeights.setValue(height, in: rows) }
    }

    /// Hides a closed range of 0-based column indices.
    public func hideColumns(_ columns: ClosedRange<Int>) -> Self {
        onSheet { $0.hiddenColumns.setValue(true, in: columns) }
    }

    /// Hides a closed range of 0-based row indices.
    public func hideRows(_ rows: ClosedRange<Int>) -> Self {
        onSheet { $0.hiddenRows.setValue(true, in: rows) }
    }

    /// Applies a style to whole columns, the way "format column D as currency" does.
    ///
    /// This is what makes ``Sheet/formattedExtent`` wider than ``Sheet/usedRange``, so it is the
    /// call to reach for when testing that distinction (Wave 1 addendum §5).
    public func columnStyle(_ style: CellStyle, columns: ClosedRange<Int>) -> Self {
        modifying { builder in
            let id = builder.styles.intern(style)
            builder.mutateSheet { $0.columnStyles.setValue(id, in: columns) }
        }
    }

    /// Applies a style to whole rows.
    public func rowStyle(_ style: CellStyle, rows: ClosedRange<Int>) -> Self {
        modifying { builder in
            let id = builder.styles.intern(style)
            builder.mutateSheet { $0.rowStyles.setValue(id, in: rows) }
        }
    }

    /// Attaches a hyperlink to a cell and sets ``CellFlags/hyperlink`` on it.
    public func hyperlink(
        _ a1: String,
        target: String,
        isExternal: Bool = true,
        location: String? = nil,
        tooltip: String? = nil
    ) -> Self {
        withRef(a1) { sheet, ref in
            sheet.hyperlinks[ref] = Hyperlink(
                target: target, isExternal: isExternal, location: location, tooltip: tooltip
            )
            var cell = sheet.cells[ref] ?? Cell()
            cell.flags.insert(.hyperlink)
            try sheet.cells.setCell(cell, at: ref)
        }
    }

    /// Records an array-formula region anchored at `a1`.
    public func arrayFormula(_ a1: String, over range: String) -> Self {
        withRef(a1) { sheet, ref in
            guard let region = CellRange(a1: range) else {
                throw SheetError.invalidCellReference(text: range)
            }
            sheet.arrayFormulaRanges[ref] = region
        }
    }

    /// Attaches a verbatim ``SheetFragment`` to the current sheet.
    ///
    /// This is the hook for the Wave 1 addendum §1 contract: A1 captures these, A2 splices them
    /// back, and a test proves the round trip without needing a real xlsx on disk.
    public func fragment(_ elementName: String, xml: String) -> Self {
        onSheet { $0.sheetLevelFragments.append(SheetFragment(elementName: elementName, xml: xml)) }
    }

    /// Sets the current sheet's tab colour.
    public func tabColor(_ color: StyleColor) -> Self {
        onSheet { $0.tabColor = color }
    }

    /// Turns the current sheet's gridlines on or off.
    public func gridlines(_ shown: Bool) -> Self {
        onSheet { $0.showsGridlines = shown }
    }

    /// Marks the current sheet right-to-left.
    public func rightToLeft(_ enabled: Bool = true) -> Self {
        onSheet { $0.isRightToLeft = enabled }
    }

    /// Sets the `<dimension>` the file *claims*, which is allowed to disagree with the truth.
    ///
    /// Wave 1 addendum §5: `dimension` is a capacity hint and three fixtures get it wrong on
    /// purpose. Use this to build the in-memory equivalent.
    public func declaredDimension(_ a1: String?) -> Self {
        guard let a1 else { return onSheet { $0.declaredDimension = nil } }
        return withRange(a1) { sheet, range in sheet.declaredDimension = range }
    }

    /// Sets the current sheet's part path, as the reader would from the relationship graph.
    public func partPath(_ path: String, relationshipID: String? = nil) -> Self {
        onSheet {
            $0.partPath = path
            if let relationshipID { $0.relationshipID = relationshipID }
        }
    }

    // MARK: - Cells

    /// Writes a literal value. Integer, floating-point, string and boolean literals all work
    /// directly: `.cell("A1", 42)`, `.cell("B1", "text")`, `.cell("C1", true)`.
    public func cell(_ a1: String, _ value: CellValue) -> Self {
        withRef(a1) { sheet, ref in
            var cell = sheet.cells[ref] ?? Cell()
            cell.value = value
            try sheet.cells.setCell(cell, at: ref)
        }
    }

    /// Writes a fully-formed ``Cell``, replacing anything already there.
    ///
    /// Named `put` rather than `cell` on purpose: `.cell("A1", .number(42))` would be ambiguous
    /// between ``CellValue/number(_:)`` and ``Cell/number(_:styleID:)``, and an ambiguity that
    /// only shows up in the caller's file is a bad thing to ship to six agents.
    public func put(_ a1: String, _ cell: Cell) -> Self {
        withRef(a1) { sheet, ref in try sheet.cells.setCell(cell, at: ref) }
    }

    /// Writes a formula and its cached result. `source` must not include the leading `=`.
    ///
    /// `cached` defaults to ``CellValue/empty``, which models a file written by a producer that
    /// did not evaluate — exactly what `Fixtures/formulas/` mostly contains.
    public func formula(
        _ a1: String,
        _ source: String,
        cached: CellValue = .empty,
        flags: CellFlags = []
    ) -> Self {
        withRef(a1) { sheet, ref in
            var cell = sheet.cells[ref] ?? Cell()
            cell.formula = source
            cell.value = cached
            cell.flags.formUnion(flags)
            try sheet.cells.setCell(cell, at: ref)
        }
    }

    /// Interns `style` into the workbook's ``StyleTable`` and applies it to one cell.
    public func style(_ a1: String, _ style: CellStyle) -> Self {
        modifying { builder in
            let id = builder.styles.intern(style)
            builder.mutateCell(a1) { $0.styleID = id }
        }
    }

    /// Applies an already-known style index to one cell.
    public func styleID(_ a1: String, _ id: StyleID) -> Self {
        modifying { $0.mutateCell(a1) { $0.styleID = id } }
    }

    /// Adds flags to a cell, leaving the ones already set alone.
    public func flags(_ a1: String, _ flags: CellFlags) -> Self {
        modifying { $0.mutateCell(a1) { $0.flags.formUnion(flags) } }
    }

    /// Writes consecutive values along a row, starting at `a1`.
    ///
    /// `.row("A1", [1, 2, 3])` fills `A1`, `B1`, `C1`.
    public func row(_ a1: String, _ values: [CellValue]) -> Self {
        withRef(a1) { sheet, ref in
            for (offset, value) in values.enumerated() {
                let target = ref.offset(columns: offset)
                var cell = sheet.cells[target] ?? Cell()
                cell.value = value
                try sheet.cells.setCell(cell, at: target)
            }
        }
    }

    /// Writes a rectangle of values, row-major, with `a1` as the top-left corner.
    public func rows(_ a1: String, _ values: [[CellValue]]) -> Self {
        withRef(a1) { sheet, ref in
            for (rowOffset, line) in values.enumerated() {
                for (columnOffset, value) in line.enumerated() {
                    let target = ref.offset(rows: rowOffset, columns: columnOffset)
                    var cell = sheet.cells[target] ?? Cell()
                    cell.value = value
                    try sheet.cells.setCell(cell, at: target)
                }
            }
        }
    }

    /// Writes the same value across an A1 range: `.fill("A1:C3", 0)`.
    public func fill(_ a1: String, with value: CellValue) -> Self {
        withRange(a1) { sheet, range in
            for ref in range {
                var cell = sheet.cells[ref] ?? Cell()
                cell.value = value
                try sheet.cells.setCell(cell, at: ref)
            }
        }
    }

    /// Removes a cell entirely, which is not the same as writing ``CellValue/empty``.
    public func clear(_ a1: String) -> Self {
        withRef(a1) { sheet, ref in _ = sheet.cells.removeCell(at: ref) }
    }

    // MARK: - Workbook level

    /// Adds a defined name pointing at an A1 range, optionally scoped to the current sheet.
    ///
    /// `refersTo` is stored verbatim in ``DefinedName/formula`` and, when it parses as a range,
    /// also resolved into ``DefinedName/target``.
    public func definedName(_ name: String, refersTo: String, scope: SheetID? = nil, isHidden: Bool = false) -> Self {
        modifying { builder in
            do {
                try DefinedName.validate(name: name)
            } catch {
                builder.record(error)
                return
            }
            var target: RangeReference?
            // `$` is stripped before parsing because `CellRef.init(a1:)` rejects it by design and
            // `A1Notation.parse` routes through it, so `Budget!$A$1:$A$3` — which is what every
            // real defined name looks like — does not parse. `formula` keeps the original text;
            // only the resolved `target` needs the anchors gone. Logged in
            // `docs/agents/MODEL-CHANGE-REQUESTS.md`.
            if let parsed = A1Notation.parse(refersTo.replacingOccurrences(of: "$", with: "")) {
                let sheetID = parsed.sheetName.flatMap { candidate in
                    builder.sheets.first { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }?.id
                }
                target = RangeReference(sheet: sheetID, range: parsed.range)
            }
            let definedName = DefinedName(
                name: name, scope: scope, target: target, formula: refersTo, isHidden: isHidden
            )
            builder.definedNames[definedName.storageKey] = definedName
        }
    }

    /// Switches the workbook between the 1900 and 1904 date epochs.
    public func dateSystem(_ system: DateSystem) -> Self {
        modifying { $0.meta.dateSystem = system }
    }

    /// Sets the recalculation mode recorded in the workbook.
    public func calculationMode(_ mode: CalculationMode) -> Self {
        modifying { $0.meta.calculationMode = mode }
    }

    /// Marks the workbook read-only for the given reason, so a test can prove a write is refused.
    public func readOnly(_ reason: ReadOnlyReason?) -> Self {
        modifying { $0.meta.readOnlyReason = reason }
    }

    /// Escape hatch for any other ``WorkbookMeta`` field.
    public func meta(_ transform: @Sendable (inout WorkbookMeta) -> Void) -> Self {
        modifying { transform(&$0.meta) }
    }

    /// Adds an unmodelled ZIP entry that a save must copy through untouched.
    public func passthroughEntry(_ entry: ZipEntry) -> Self {
        modifying { $0.passthrough.upsert(entry) }
    }

    /// Adds an unmodelled part from raw bytes, stored uncompressed.
    ///
    /// Uncompressed because a test that cares about passthrough cares about the *bytes*, and a
    /// stored entry is the one case where `compressedData` and the real contents are the same
    /// thing — no deflate implementation needed inside `TestSupport`.
    public func passthroughPart(path: String, contents: Data) -> Self {
        passthroughEntry(ZipEntry(
            path: path,
            compressedData: contents,
            compressionMethod: .store,
            uncompressedSize: UInt64(contents.count)
        ))
    }

    /// Interns a style up front and hands back its index, for tests that reuse one style a lot.
    public func withStyle(_ style: CellStyle, _ body: (StyleID, Self) -> Self) -> Self {
        var copy = self
        let id = copy.styles.intern(style)
        return body(id, copy)
    }

    // MARK: - Finishing

    /// The assembled workbook, or the first error the chain deferred.
    ///
    /// Runs ``Workbook/validate()`` so a builder chain cannot hand a test a workbook that the
    /// model itself considers malformed — a test failing on a bad fixture is a wasted hour.
    public func build() throws(SheetError) -> Workbook {
        if let deferredError { throw deferredError }
        let workbook = Workbook(
            sheets: sheets.isEmpty ? [Sheet(id: SheetID(1), name: "Sheet1")] : sheets,
            definedNames: definedNames,
            styles: styles,
            meta: meta,
            passthrough: passthrough
        )
        try workbook.validate()
        return workbook
    }

    /// The assembled workbook with validation skipped.
    ///
    /// For the handful of tests whose whole point is a workbook the model rejects — an
    /// overlapping merge, a duplicate sheet name — where ``build()`` would throw before the
    /// assertion could run.
    public func buildWithoutValidating() throws(SheetError) -> Workbook {
        if let deferredError { throw deferredError }
        return Workbook(
            sheets: sheets.isEmpty ? [Sheet(id: SheetID(1), name: "Sheet1")] : sheets,
            definedNames: definedNames,
            styles: styles,
            meta: meta,
            passthrough: passthrough
        )
    }

    /// The single sheet this builder describes, for the common case of a one-sheet fixture.
    public func buildSheet() throws(SheetError) -> Sheet {
        let workbook = try build()
        guard let sheet = workbook.sheets.first else {
            throw SheetError.internalInconsistency(detail: "WorkbookBuilder produced no sheets")
        }
        return sheet
    }

    /// The first error the chain hit, if any. Useful for asserting that a chain *did* fail.
    public var pendingError: SheetError? { deferredError }

    // MARK: - Plumbing

    /// Remembers the first failure, narrowing whatever was thrown to a ``SheetError``.
    ///
    /// Takes `any Error` rather than `SheetError` deliberately: a `do`/`catch` inside a
    /// non-throwing closure widens a typed throw back to `any Error`, and a helper that insisted
    /// on the narrow type would have to be spelled out at every call site.
    private mutating func record(_ error: any Error) {
        guard deferredError == nil else { return }
        deferredError = (error as? SheetError) ?? .internalInconsistency(detail: "\(error)")
    }

    private func modifying(_ transform: (inout Self) -> Void) -> Self {
        var copy = self
        guard copy.deferredError == nil else { return copy }
        transform(&copy)
        return copy
    }

    private func onSheet(_ transform: @escaping (inout Sheet) -> Void) -> Self {
        modifying { $0.mutateSheet(transform) }
    }

    private mutating func mutateSheet(_ transform: (inout Sheet) -> Void) {
        guard let index = resolvedSheetIndex() else { return }
        transform(&sheets[index])
    }

    private mutating func mutateCell(_ a1: String, _ transform: (inout Cell) -> Void) {
        guard let ref = CellRef(a1: a1) else {
            deferredError = .invalidCellReference(text: a1)
            return
        }
        guard let index = resolvedSheetIndex() else { return }
        var cell = sheets[index].cells[ref] ?? Cell()
        transform(&cell)
        do {
            try sheets[index].cells.setCell(cell, at: ref)
        } catch {
            record(error)
        }
    }

    private func withRef(_ a1: String, _ body: @escaping (inout Sheet, CellRef) throws -> Void) -> Self {
        modifying { builder in
            guard let ref = CellRef(a1: a1) else {
                builder.deferredError = .invalidCellReference(text: a1)
                return
            }
            builder.apply { sheet in try body(&sheet, ref) }
        }
    }

    private func withRange(_ a1: String, _ body: @escaping (inout Sheet, CellRange) throws -> Void) -> Self {
        modifying { builder in
            guard let range = CellRange(a1: a1) else {
                builder.deferredError = .invalidCellReference(text: a1)
                return
            }
            builder.apply { sheet in try body(&sheet, range) }
        }
    }

    private mutating func apply(_ body: (inout Sheet) throws -> Void) {
        guard let index = resolvedSheetIndex() else { return }
        do {
            try body(&sheets[index])
        } catch {
            record(error)
        }
    }

    /// The index of the sheet cell calls land on, creating a default `Sheet1` if the chain
    /// never named one. Writing `.cell("A1", 1)` with no `.sheet(…)` in front of it is the
    /// commonest one-liner in a test and should not have to say `Sheet1` out loud.
    private mutating func resolvedSheetIndex() -> Int? {
        if let currentIndex, sheets.indices.contains(currentIndex) { return currentIndex }
        if sheets.isEmpty {
            sheets.append(Sheet(id: SheetID(1), name: "Sheet1"))
        }
        currentIndex = sheets.count - 1
        return currentIndex
    }
}
