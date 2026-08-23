import Foundation

/// Whether a sheet shows in the tab bar.
public enum SheetVisibility: String, Sendable, Hashable, Codable, CaseIterable {
    case visible
    /// Hidden, but the user can unhide it from the tab bar's context menu.
    case hidden
    /// Hidden and *not* unhideable from the UI — only from the VBA editor. Real files use this
    /// to stash lookup tables. We show it in the sidebar with an affordance rather than
    /// pretending it does not exist.
    case veryHidden
}

/// Frozen and split panes.
///
/// Freezing and splitting are the same xlsx element with a different flag, so they share a
/// type. A sheet can be frozen on one axis, both, or neither, giving up to four quadrants that
/// each scroll independently.
public struct FrozenPanes: Sendable, Hashable, Codable {
    /// Rows locked at the top. `0` means none.
    public var frozenRows: Int
    /// Columns locked at the left. `0` means none.
    public var frozenColumns: Int
    /// The first cell visible in the scrolling quadrant, when the file recorded one.
    public var topLeftVisible: CellRef?
    /// A pixel split position instead of a frozen row count. Split panes scroll on both sides
    /// of the divider; frozen ones do not.
    public var horizontalSplit: Double?
    /// See ``horizontalSplit``.
    public var verticalSplit: Double?

    public init(
        frozenRows: Int = 0,
        frozenColumns: Int = 0,
        topLeftVisible: CellRef? = nil,
        horizontalSplit: Double? = nil,
        verticalSplit: Double? = nil
    ) {
        self.frozenRows = frozenRows
        self.frozenColumns = frozenColumns
        self.topLeftVisible = topLeftVisible
        self.horizontalSplit = horizontalSplit
        self.verticalSplit = verticalSplit
    }

    /// Nothing frozen or split.
    public static let none = FrozenPanes()

    /// Whether anything is frozen.
    public var isFrozen: Bool { frozenRows > 0 || frozenColumns > 0 }

    /// Whether the sheet is split rather than frozen.
    public var isSplit: Bool { horizontalSplit != nil || verticalSplit != nil }

    /// How many independently-scrolling quadrants the renderer has to draw: 1, 2, or 4.
    public var paneCount: Int {
        switch (frozenRows > 0, frozenColumns > 0) {
        case (false, false): 1
        case (true, true): 4
        default: 2
        }
    }
}

/// A link attached to a cell.
///
/// **Inert until clicked.** PLAN.md §7.3: a spreadsheet is untrusted input, so nothing here is
/// ever fetched, resolved, or previewed automatically, and clicking shows the resolved URL
/// before going anywhere.
public struct Hyperlink: Sendable, Hashable, Codable {
    /// The target, exactly as stored. Not resolved, not validated, not normalised.
    public var target: String
    /// Whether the target leaves the workbook. Internal links point at a cell reference.
    public var isExternal: Bool
    /// The `location` fragment — a defined name or cell reference within the target.
    public var location: String?
    /// The tooltip Excel shows on hover.
    public var tooltip: String?
    /// The relationship id, kept so a save can re-emit the rels entry.
    public var relationshipID: String?

    public init(
        target: String,
        isExternal: Bool = true,
        location: String? = nil,
        tooltip: String? = nil,
        relationshipID: String? = nil
    ) {
        self.target = target
        self.isExternal = isExternal
        self.location = location
        self.tooltip = tooltip
        self.relationshipID = relationshipID
    }
}

/// Who owns the value in a cell that did not put it there itself.
///
/// Returned by ``Sheet/spillOwner(of:)``. The distinction between the two kinds is not
/// cosmetic: a legacy array formula's region was chosen by the author and never moves, while a
/// dynamic array's region is part of its *result* and changes size whenever the inputs do — so
/// only the second one has to be cleared and rewritten on every recalculation.
public struct SpillOwner: Sendable, Hashable {
    /// The cell holding the formula. The top-left of ``region``.
    public var anchor: CellRef
    /// Every cell the result occupies, ``anchor`` included.
    public var region: CellRange
    /// `true` for a dynamic array (``CellFlags/spillAnchor``), `false` for a legacy
    /// Ctrl-Shift-Enter array formula.
    public var isDynamic: Bool

    public init(anchor: CellRef, region: CellRange, isDynamic: Bool) {
        self.anchor = anchor
        self.region = region
        self.isDynamic = isDynamic
    }

    /// Whether `ref` is a cell this owner writes into rather than the anchor itself.
    public func owns(_ ref: CellRef) -> Bool { ref != anchor && region.contains(ref) }
}

/// One worksheet.
///
/// Everything here is a value type, so a `Sheet` can be snapshotted for a diff, handed to a
/// background actor for evaluation, and compared against a freshly parsed one — without a lock
/// anywhere (PLAN.md §2.3).
public struct Sheet: Sendable, Equatable, Codable, Identifiable {
    /// Stable across renames and reorders. See ``SheetID``.
    public let id: SheetID

    /// The tab name. At most 31 characters and free of `[]:*?/\` — see
    /// ``Limits/validateSheetName(_:)``. Compared case-insensitively for uniqueness.
    public var name: String

    /// The cells. See ``CellStore`` for what its API does and does not promise.
    public var cells: CellStore

    /// Custom column widths in points. Everything not customised reads as
    /// ``defaultColumnWidth``.
    ///
    /// Points, not Excel's "characters of the normal font" — that unit depends on the
    /// workbook's default font metrics and is meaningless outside a renderer, so the reader
    /// converts once and the writer converts back.
    public var columnWidths: RunLengthArray<Double>

    /// Custom row heights in points.
    public var rowHeights: RunLengthArray<Double>

    /// Which columns are hidden. Separate from a zero width, because Excel distinguishes them
    /// and the UI needs to offer "unhide" for one and not the other.
    public var hiddenColumns: RunLengthArray<Bool>

    /// Which rows are hidden.
    public var hiddenRows: RunLengthArray<Bool>

    /// Styles applied to whole columns, for cells that hold no value.
    ///
    /// This is how "column D is formatted as currency" survives when column D is empty. Without
    /// it, a fixture whose only content is formatting round-trips as a blank sheet.
    public var columnStyles: RunLengthArray<StyleID>

    /// Styles applied to whole rows. See ``columnStyles``.
    public var rowStyles: RunLengthArray<StyleID>

    /// Outline (grouping) depth per column, 0–7. Not rendered in v0.1; kept so a save does not
    /// flatten someone's grouped columns.
    public var columnOutlineLevels: RunLengthArray<UInt8>

    /// See ``columnOutlineLevels``.
    public var rowOutlineLevels: RunLengthArray<UInt8>

    /// Merged regions. Must not overlap — ``validate()`` enforces that.
    public var merges: [CellRange]

    /// Frozen or split panes.
    public var frozen: FrozenPanes

    /// Whether the sheet shows in the tab bar. See ``SheetVisibility/veryHidden``.
    public var visibility: SheetVisibility

    /// Links by cell. The matching cells carry ``CellFlags/hyperlink``.
    public var hyperlinks: [CellRef: Hyperlink]

    /// Array-formula master cells mapped to the region they spill into.
    ///
    /// Needed to write `<f t="array" ref="A1:C3">` back correctly, and to refuse an edit to a
    /// single cell of an array formula — which Excel forbids and which produces a file Excel
    /// will not open.
    ///
    /// Both kinds of region live here: a legacy Ctrl-Shift-Enter array formula, whose region
    /// the author fixed, and a modern **dynamic-array spill**, whose region is a result and
    /// changes size when the inputs do. ``CellFlags/spillAnchor`` on the anchor tells them
    /// apart. Ownership is identical either way — the cells inside the region belong to the
    /// anchor and are not independently editable — which is why one dictionary serves both
    /// rather than the model growing a second one that means the same thing.
    public var arrayFormulaRanges: [CellRef: CellRange]

    /// The `autoFilter` range, when the sheet has one.
    public var autoFilter: CellRange?

    /// The tab's colour dot.
    public var tabColor: StyleColor?

    /// Whether gridlines are drawn. Off is common in dashboard-style sheets.
    public var showsGridlines: Bool

    /// Whether the sheet reads right-to-left.
    public var isRightToLeft: Bool

    /// The saved zoom, 0.1–4.0. View state, but it lives in the file, so it round-trips here.
    public var zoomScale: Double

    /// Default column width in points, for every column ``columnWidths`` does not customise.
    public var defaultColumnWidth: Double

    /// Default row height in points.
    public var defaultRowHeight: Double

    /// The `dimension` the producer claimed.
    ///
    /// **Do not trust it.** It is frequently wrong or missing; ``usedRange`` is computed from
    /// the cells instead. Kept only so a passthrough write can re-emit what was there.
    public var declaredDimension: CellRange?

    /// The archive path of this sheet's XML part, once known.
    ///
    /// Resolved through `xl/_rels/workbook.xml.rels`, never assumed to be
    /// `xl/worksheets/sheetN.xml` — plenty of producers do not follow that convention. `nil`
    /// for a sheet that has never been written.
    public var partPath: String?

    /// The `r:id` linking this sheet from `workbook.xml`, kept so a save re-emits it unchanged.
    public var relationshipID: String?

    /// The VBA code name, when the workbook has macros. Round-trip only; we never execute
    /// anything (PLAN.md §7.3).
    public var codeName: String?

    /// Unmodelled XML lifted verbatim out of this sheet's part. See ``SheetFragment``.
    ///
    /// Charts, conditional formats, data validation, print setup, protection and table parts all
    /// live inside `sheetN.xml` — the very part a save re-emits — so copying ZIP entries through
    /// untouched does not preserve them. These fragments do.
    public var sheetLevelFragments: [SheetFragment]

    public init(
        id: SheetID,
        name: String,
        cells: CellStore = CellStore(),
        columnWidths: RunLengthArray<Double>? = nil,
        rowHeights: RunLengthArray<Double>? = nil,
        hiddenColumns: RunLengthArray<Bool> = RunLengthArray(defaultValue: false),
        hiddenRows: RunLengthArray<Bool> = RunLengthArray(defaultValue: false),
        columnStyles: RunLengthArray<StyleID> = RunLengthArray(defaultValue: .default),
        rowStyles: RunLengthArray<StyleID> = RunLengthArray(defaultValue: .default),
        columnOutlineLevels: RunLengthArray<UInt8> = RunLengthArray(defaultValue: 0),
        rowOutlineLevels: RunLengthArray<UInt8> = RunLengthArray(defaultValue: 0),
        merges: [CellRange] = [],
        frozen: FrozenPanes = .none,
        visibility: SheetVisibility = .visible,
        hyperlinks: [CellRef: Hyperlink] = [:],
        arrayFormulaRanges: [CellRef: CellRange] = [:],
        autoFilter: CellRange? = nil,
        tabColor: StyleColor? = nil,
        showsGridlines: Bool = true,
        isRightToLeft: Bool = false,
        zoomScale: Double = 1,
        defaultColumnWidth: Double = Limits.defaultColumnWidth,
        defaultRowHeight: Double = Limits.defaultRowHeight,
        declaredDimension: CellRange? = nil,
        partPath: String? = nil,
        relationshipID: String? = nil,
        codeName: String? = nil,
        sheetLevelFragments: [SheetFragment] = []
    ) {
        self.id = id
        self.name = name
        self.cells = cells
        self.columnWidths = columnWidths ?? RunLengthArray(defaultValue: defaultColumnWidth)
        self.rowHeights = rowHeights ?? RunLengthArray(defaultValue: defaultRowHeight)
        self.hiddenColumns = hiddenColumns
        self.hiddenRows = hiddenRows
        self.columnStyles = columnStyles
        self.rowStyles = rowStyles
        self.columnOutlineLevels = columnOutlineLevels
        self.rowOutlineLevels = rowOutlineLevels
        self.merges = merges
        self.frozen = frozen
        self.visibility = visibility
        self.hyperlinks = hyperlinks
        self.arrayFormulaRanges = arrayFormulaRanges
        self.autoFilter = autoFilter
        self.tabColor = tabColor
        self.showsGridlines = showsGridlines
        self.isRightToLeft = isRightToLeft
        self.zoomScale = zoomScale
        self.defaultColumnWidth = defaultColumnWidth
        self.defaultRowHeight = defaultRowHeight
        self.declaredDimension = declaredDimension
        self.partPath = partPath
        self.relationshipID = relationshipID
        self.codeName = codeName
        self.sheetLevelFragments = sheetLevelFragments
    }

    // MARK: - Derived

    /// The rectangle that actually contains data, computed from ``cells``.
    ///
    /// Computed rather than stored so it cannot drift from the cells. It does **not** include
    /// columns that are only formatted — see ``formattedExtent`` for that.
    public var usedRange: CellRange? { cells.usedRange }

    /// The used range widened to cover whole-column and whole-row formatting.
    ///
    /// Closer to what Excel calls the used range, and what a save should write as `dimension`.
    public var formattedExtent: CellRange? {
        var result = usedRange
        if let lastColumn = columnStyles.lastCustomisedIndex ?? columnWidths.lastCustomisedIndex {
            let band = CellRange(rows: 0 ... 0, columns: 0 ... lastColumn)
            result = result.map { $0.union(band) } ?? band
        }
        if let lastRow = rowStyles.lastCustomisedIndex ?? rowHeights.lastCustomisedIndex {
            let band = CellRange(rows: 0 ... lastRow, columns: 0 ... 0)
            result = result.map { $0.union(band) } ?? band
        }
        // A merge extends the extent even where the covered cells hold nothing. `A1:F8` merged
        // with four values in it is an eight-row sheet, not a one-row one — the corpus asserts
        // exactly that (`Fixtures/structure/merged-cells.xlsx`), and a selection drawn from a
        // narrower extent would clip the merge it is supposed to contain.
        for merge in merges {
            result = result.map { $0.union(merge) } ?? merge
        }
        return result
    }

    /// The style that applies at `ref`: the cell's own, or the row's, or the column's, in that
    /// order.
    ///
    /// Excel's precedence, which matters for an empty cell in a formatted column.
    public func effectiveStyleID(at ref: CellRef) -> StyleID {
        if let cell = cells[ref], cell.styleID != .default { return cell.styleID }
        let rowStyle = rowStyles[ref.row]
        if rowStyle != .default { return rowStyle }
        return columnStyles[ref.column]
    }

    /// The merged region containing `ref`, if any.
    ///
    /// Linear in ``merges``, which is fine — a sheet with thousands of merges is already
    /// pathological. Build an index if you need this per cell per frame.
    public func merge(containing ref: CellRef) -> CellRange? {
        merges.first { $0.contains(ref) }
    }

    // MARK: - Spill regions

    /// The array formula or dynamic-array spill that owns `ref`, if one does.
    ///
    /// `ref` may be the anchor itself — an anchor owns its own cell — so callers deciding
    /// "may this be edited?" should compare ``SpillOwner/anchor`` against `ref` rather than
    /// treating any non-`nil` answer as a refusal. ``isSpilledInto(_:)`` does exactly that.
    ///
    /// Linear in ``arrayFormulaRanges`` for the same reason ``merge(containing:)`` is linear
    /// in ``merges``: a sheet with thousands of array formulas is already pathological, and
    /// the per-frame path in `GridKit` reads ``CellFlags/spilledInto`` off the cell instead,
    /// which is O(1).
    public func spillOwner(of ref: CellRef) -> SpillOwner? {
        for (anchor, region) in arrayFormulaRanges where region.contains(ref) {
            return SpillOwner(anchor: anchor, region: region, isDynamic: isDynamicSpillAnchor(anchor))
        }
        return nil
    }

    /// Whether `ref` holds a value owned by an anchor somewhere else — the cells an edit must
    /// be refused on.
    public func isSpilledInto(_ ref: CellRef) -> Bool {
        if let cell = cells[ref], cell.flags.contains(.spilledInto) { return true }
        guard let owner = spillOwner(of: ref) else { return false }
        return owner.anchor != ref
    }

    private func isDynamicSpillAnchor(_ anchor: CellRef) -> Bool {
        cells[anchor]?.flags.contains(.spillAnchor) ?? false
    }

    // MARK: - Structural edits

    /// Inserts rows, moving cells, merges, sizes, hyperlinks, and array regions together.
    ///
    /// The reason this is on `Sheet` and not on ``CellStore``: a row insert that moves the
    /// cells but forgets the merges leaves a merged region pointing at the wrong place, and
    /// that bug is invisible until someone scrolls to it.
    ///
    /// Still does **not** rewrite formula text — call `SheetFormula`'s `ReferenceTransform`
    /// for that, which needs a parser and therefore cannot live here.
    public mutating func insertRows(at row: Int, count: Int) throws(SheetError) {
        try cells.insertRows(at: row, count: count)
        rowHeights.insert(at: row, count: count)
        hiddenRows.insert(at: row, count: count)
        rowStyles.insert(at: row, count: count)
        rowOutlineLevels.insert(at: row, count: count)
        merges = merges.map { shift($0, byRows: count, from: row) }
        hyperlinks = remapKeys(hyperlinks) { $0.row >= row ? $0.offset(rows: count) : $0 }
        arrayFormulaRanges = remapArrayRegions { $0.row >= row ? $0.offset(rows: count) : $0 }
        autoFilter = autoFilter.map { shift($0, byRows: count, from: row) }
    }

    /// Deletes rows, moving everything below up. Merges and array regions that fall entirely
    /// inside the deleted band are removed.
    public mutating func deleteRows(at row: Int, count: Int) throws(SheetError) {
        try cells.deleteRows(at: row, count: count)
        rowHeights.remove(at: row, count: count)
        hiddenRows.remove(at: row, count: count)
        rowStyles.remove(at: row, count: count)
        rowOutlineLevels.remove(at: row, count: count)
        merges = merges.compactMap { collapse($0, byRows: count, from: row) }
        hyperlinks = remapKeys(hyperlinks) { ref in
            if ref.row >= row, ref.row < row + count { return nil }
            return ref.row >= row + count ? ref.offset(rows: -count) : ref
        }
        arrayFormulaRanges = remapArrayRegions { ref in
            if ref.row >= row, ref.row < row + count { return nil }
            return ref.row >= row + count ? ref.offset(rows: -count) : ref
        }
        autoFilter = autoFilter.flatMap { collapse($0, byRows: count, from: row) }
    }

    /// Inserts columns. See ``insertRows(at:count:)``.
    public mutating func insertColumns(at column: Int, count: Int) throws(SheetError) {
        try cells.insertColumns(at: column, count: count)
        columnWidths.insert(at: column, count: count)
        hiddenColumns.insert(at: column, count: count)
        columnStyles.insert(at: column, count: count)
        columnOutlineLevels.insert(at: column, count: count)
        merges = merges.map { shift($0, byColumns: count, from: column) }
        hyperlinks = remapKeys(hyperlinks) { $0.column >= column ? $0.offset(columns: count) : $0 }
        arrayFormulaRanges = remapArrayRegions { $0.column >= column ? $0.offset(columns: count) : $0 }
        autoFilter = autoFilter.map { shift($0, byColumns: count, from: column) }
    }

    /// Deletes columns. See ``deleteRows(at:count:)``.
    public mutating func deleteColumns(at column: Int, count: Int) throws(SheetError) {
        try cells.deleteColumns(at: column, count: count)
        columnWidths.remove(at: column, count: count)
        hiddenColumns.remove(at: column, count: count)
        columnStyles.remove(at: column, count: count)
        columnOutlineLevels.remove(at: column, count: count)
        merges = merges.compactMap { collapse($0, byColumns: count, from: column) }
        hyperlinks = remapKeys(hyperlinks) { ref in
            if ref.column >= column, ref.column < column + count { return nil }
            return ref.column >= column + count ? ref.offset(columns: -count) : ref
        }
        arrayFormulaRanges = remapArrayRegions { ref in
            if ref.column >= column, ref.column < column + count { return nil }
            return ref.column >= column + count ? ref.offset(columns: -count) : ref
        }
        autoFilter = autoFilter.flatMap { collapse($0, byColumns: count, from: column) }
    }

    // MARK: - Validation

    /// Checks everything PLAN.md §8 says a sheet must satisfy, apart from name uniqueness,
    /// which needs the workbook.
    public func validate() throws(SheetError) {
        try Limits.validateSheetName(name)

        if let used = usedRange, !used.isValid {
            throw SheetError.sheetDimensionOutOfRange(sheet: name, rows: used.rowCount, columns: used.columnCount)
        }
        for merge in merges where !merge.isValid {
            throw SheetError.rangeOutOfRange(range: merge.a1String, detail: "merged range is outside the sheet")
        }
        for (outer, first) in merges.enumerated() {
            for second in merges[(outer + 1)...] where first.intersects(second) {
                throw SheetError.overlappingMerges(first: first.a1String, second: second.a1String)
            }
        }
        guard frozen.frozenRows >= 0, frozen.frozenRows <= Limits.maxRow,
              frozen.frozenColumns >= 0, frozen.frozenColumns <= Limits.maxColumn
        else {
            throw SheetError.invalidArgument(name: "frozen", reason: "frozen pane counts are outside the sheet")
        }
    }

    // MARK: - Shifting helpers

    private func shift(_ range: CellRange, byRows count: Int, from row: Int) -> CellRange {
        CellRange(
            start: range.start.row >= row ? range.start.offset(rows: count) : range.start,
            end: range.end.row >= row ? range.end.offset(rows: count) : range.end
        )
    }

    private func shift(_ range: CellRange, byColumns count: Int, from column: Int) -> CellRange {
        CellRange(
            start: range.start.column >= column ? range.start.offset(columns: count) : range.start,
            end: range.end.column >= column ? range.end.offset(columns: count) : range.end
        )
    }

    /// Shrinks a range around a deleted band, or removes it when nothing survives.
    private func collapse(_ range: CellRange, byRows count: Int, from row: Int) -> CellRange? {
        let deleted = row ..< (row + count)
        if range.start.row >= deleted.lowerBound, range.end.row < deleted.upperBound { return nil }
        func move(_ value: Int) -> Int {
            value >= deleted.upperBound ? value - count : min(value, max(deleted.lowerBound, 0))
        }
        let start = CellRef(row: move(range.start.row), column: range.start.column)
        let end = CellRef(row: move(range.end.row), column: range.end.column)
        return CellRange(start: start, end: end)
    }

    private func collapse(_ range: CellRange, byColumns count: Int, from column: Int) -> CellRange? {
        let deleted = column ..< (column + count)
        if range.start.column >= deleted.lowerBound, range.end.column < deleted.upperBound { return nil }
        func move(_ value: Int) -> Int {
            value >= deleted.upperBound ? value - count : min(value, max(deleted.lowerBound, 0))
        }
        let start = CellRef(row: range.start.row, column: move(range.start.column))
        let end = CellRef(row: range.end.row, column: move(range.end.column))
        return CellRange(start: start, end: end)
    }

    private func remapKeys<Value>(
        _ source: [CellRef: Value],
        _ transform: (CellRef) -> CellRef?
    ) -> [CellRef: Value] {
        var result: [CellRef: Value] = [:]
        result.reserveCapacity(source.count)
        for (ref, value) in source {
            guard let moved = transform(ref), moved.isValid else { continue }
            result[moved] = value
        }
        return result
    }

    private func remapArrayRegions(_ transform: (CellRef) -> CellRef?) -> [CellRef: CellRange] {
        var result: [CellRef: CellRange] = [:]
        for (anchor, region) in arrayFormulaRanges {
            guard let moved = transform(anchor), moved.isValid,
                  let movedStart = transform(region.start), let movedEnd = transform(region.end)
            else { continue }
            result[moved] = CellRange(start: movedStart, end: movedEnd)
        }
        return result
    }
}

// MARK: - Codable for CellRef-keyed dictionaries

/// `[CellRef: T]` cannot encode as a JSON object — `CellRef` is not a `String` key — so the
/// sheet's two ref-keyed dictionaries encode as arrays of pairs. Explicit rather than clever,
/// because the fixture sidecars are meant to be read by humans.
extension Sheet {
    private enum CodingKeys: String, CodingKey {
        case id, name, cells, columnWidths, rowHeights, hiddenColumns, hiddenRows
        case columnStyles, rowStyles, columnOutlineLevels, rowOutlineLevels
        case merges, frozen, visibility, hyperlinks, arrayFormulaRanges, autoFilter
        case tabColor, showsGridlines, isRightToLeft, zoomScale
        case defaultColumnWidth, defaultRowHeight, declaredDimension
        case partPath, relationshipID, codeName, sheetLevelFragments
    }

    private struct HyperlinkEntry: Codable {
        let ref: CellRef
        let link: Hyperlink
    }

    private struct ArrayRegionEntry: Codable {
        let ref: CellRef
        let range: CellRange
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(cells, forKey: .cells)
        try container.encode(columnWidths, forKey: .columnWidths)
        try container.encode(rowHeights, forKey: .rowHeights)
        try container.encode(hiddenColumns, forKey: .hiddenColumns)
        try container.encode(hiddenRows, forKey: .hiddenRows)
        try container.encode(columnStyles, forKey: .columnStyles)
        try container.encode(rowStyles, forKey: .rowStyles)
        try container.encode(columnOutlineLevels, forKey: .columnOutlineLevels)
        try container.encode(rowOutlineLevels, forKey: .rowOutlineLevels)
        try container.encode(merges, forKey: .merges)
        try container.encode(frozen, forKey: .frozen)
        try container.encode(visibility, forKey: .visibility)
        try container.encode(
            hyperlinks.map { HyperlinkEntry(ref: $0.key, link: $0.value) }.sorted { $0.ref < $1.ref },
            forKey: .hyperlinks
        )
        try container.encode(
            arrayFormulaRanges.map { ArrayRegionEntry(ref: $0.key, range: $0.value) }.sorted { $0.ref < $1.ref },
            forKey: .arrayFormulaRanges
        )
        try container.encodeIfPresent(autoFilter, forKey: .autoFilter)
        try container.encodeIfPresent(tabColor, forKey: .tabColor)
        try container.encode(showsGridlines, forKey: .showsGridlines)
        try container.encode(isRightToLeft, forKey: .isRightToLeft)
        try container.encode(zoomScale, forKey: .zoomScale)
        try container.encode(defaultColumnWidth, forKey: .defaultColumnWidth)
        try container.encode(defaultRowHeight, forKey: .defaultRowHeight)
        try container.encodeIfPresent(declaredDimension, forKey: .declaredDimension)
        try container.encodeIfPresent(partPath, forKey: .partPath)
        try container.encodeIfPresent(relationshipID, forKey: .relationshipID)
        try container.encodeIfPresent(codeName, forKey: .codeName)
        if !sheetLevelFragments.isEmpty {
            try container.encode(sheetLevelFragments, forKey: .sheetLevelFragments)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaultWidth = try container.decodeIfPresent(Double.self, forKey: .defaultColumnWidth) ?? Limits
            .defaultColumnWidth
        let defaultHeight = try container.decodeIfPresent(Double.self, forKey: .defaultRowHeight) ?? Limits
            .defaultRowHeight
        let links = try container.decodeIfPresent([HyperlinkEntry].self, forKey: .hyperlinks) ?? []
        let regions = try container.decodeIfPresent([ArrayRegionEntry].self, forKey: .arrayFormulaRanges) ?? []

        self.init(
            id: try container.decode(SheetID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            cells: try container.decodeIfPresent(CellStore.self, forKey: .cells) ?? CellStore(),
            columnWidths: try container.decodeIfPresent(RunLengthArray<Double>.self, forKey: .columnWidths),
            rowHeights: try container.decodeIfPresent(RunLengthArray<Double>.self, forKey: .rowHeights),
            hiddenColumns: try container.decodeIfPresent(RunLengthArray<Bool>.self, forKey: .hiddenColumns)
                ?? RunLengthArray(defaultValue: false),
            hiddenRows: try container.decodeIfPresent(RunLengthArray<Bool>.self, forKey: .hiddenRows)
                ?? RunLengthArray(defaultValue: false),
            columnStyles: try container.decodeIfPresent(RunLengthArray<StyleID>.self, forKey: .columnStyles)
                ?? RunLengthArray(defaultValue: .default),
            rowStyles: try container.decodeIfPresent(RunLengthArray<StyleID>.self, forKey: .rowStyles)
                ?? RunLengthArray(defaultValue: .default),
            columnOutlineLevels: try container.decodeIfPresent(RunLengthArray<UInt8>.self, forKey: .columnOutlineLevels)
                ?? RunLengthArray(defaultValue: 0),
            rowOutlineLevels: try container.decodeIfPresent(RunLengthArray<UInt8>.self, forKey: .rowOutlineLevels)
                ?? RunLengthArray(defaultValue: 0),
            merges: try container.decodeIfPresent([CellRange].self, forKey: .merges) ?? [],
            frozen: try container.decodeIfPresent(FrozenPanes.self, forKey: .frozen) ?? .none,
            visibility: try container.decodeIfPresent(SheetVisibility.self, forKey: .visibility) ?? .visible,
            hyperlinks: Dictionary(uniqueKeysWithValues: links.map { ($0.ref, $0.link) }),
            arrayFormulaRanges: Dictionary(uniqueKeysWithValues: regions.map { ($0.ref, $0.range) }),
            autoFilter: try container.decodeIfPresent(CellRange.self, forKey: .autoFilter),
            tabColor: try container.decodeIfPresent(StyleColor.self, forKey: .tabColor),
            showsGridlines: try container.decodeIfPresent(Bool.self, forKey: .showsGridlines) ?? true,
            isRightToLeft: try container.decodeIfPresent(Bool.self, forKey: .isRightToLeft) ?? false,
            zoomScale: try container.decodeIfPresent(Double.self, forKey: .zoomScale) ?? 1,
            defaultColumnWidth: defaultWidth,
            defaultRowHeight: defaultHeight,
            declaredDimension: try container.decodeIfPresent(CellRange.self, forKey: .declaredDimension),
            partPath: try container.decodeIfPresent(String.self, forKey: .partPath),
            relationshipID: try container.decodeIfPresent(String.self, forKey: .relationshipID),
            codeName: try container.decodeIfPresent(String.self, forKey: .codeName),
            sheetLevelFragments: try container.decodeIfPresent(
                [SheetFragment].self, forKey: .sheetLevelFragments
            ) ?? []
        )
    }
}

extension Sheet: CustomStringConvertible {
    public var description: String {
        "Sheet(\"\(name)\", \(cells.count) cells, used: \(usedRange?.a1String ?? "—"))"
    }
}
