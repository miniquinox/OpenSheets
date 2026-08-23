//
//  WorksheetReader.swift
//  SheetFormat
//
//  A1 owns this file. `xl/worksheets/sheetN.xml` → a `Sheet`, plus every byte of it we do not
//  model, kept verbatim.
//

import Foundation

import SheetModel

/// Parses one worksheet part.
///
/// # The two things worth knowing before reading the code
///
/// **Order is not guaranteed.** Rows and cells may appear in any order and with gaps, and
/// `<dimension>` is a hint that is wrong often enough to be useless
/// (`Fixtures/structure/out-of-order-rows.xlsx` has neither). Nothing here assumes a monotonic
/// `r`, and the used range is computed from what was actually stored.
///
/// **Anything not modelled is captured verbatim.** Every direct child of `<worksheet>` that this
/// reader does not turn into model state is lifted out byte-for-byte into
/// ``SheetModel/Sheet/sheetLevelFragments``. Dropping the one-line `<drawing r:id="rId1"/>`
/// orphans a chart whose own part survived perfectly, and Excel then calls the workbook damaged.
public enum WorksheetReader {
    /// Worksheet children this reader turns into model state, and therefore does **not** capture
    /// as a fragment — capturing them too would make the writer emit each of them twice.
    ///
    /// **Everything else is captured**, which is deliberately a rule rather than a list. It comes
    /// out as a superset of ``SheetModel/SheetFragment/capturedElements`` whenever that set is
    /// behind the schema, and it needs no edit when a producer emits something nobody has seen:
    /// `legacyDrawing` — the pointer to the VML that positions cell comments, present in
    /// `Fixtures/passthrough/comments.xlsx` and `kitchen-sink.xlsm` — was missing from
    /// `capturedElements` until Wave 1, and a reader driven by that list would have dropped it and
    /// orphaned the comments exactly the way losing `<drawing>` orphans a chart.
    public static let modelledWorksheetChildren: Set<String> = [
        "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData",
        "mergeCells", "hyperlinks", "autoFilter",
    ]

    /// Everything a sheet parse needs from the rest of the workbook.
    public struct Context: Sendable {
        public var sharedStrings: SharedStrings
        public var styles: StyleTable
        public var dateSystem: DateSystem
        public var relationships: OPCRelationships

        public init(
            sharedStrings: SharedStrings = .empty,
            styles: StyleTable = .empty,
            dateSystem: DateSystem = .excel1900,
            relationships: OPCRelationships = .empty
        ) {
            self.sharedStrings = sharedStrings
            self.styles = styles
            self.dateSystem = dateSystem
            self.relationships = relationships
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public static func read(
        _ bytes: [UInt8],
        part: String,
        entry: WorkbookSheetEntry,
        context: Context
    ) throws(SheetError) -> Sheet {
        try XMLParsing.withParser(over: bytes, part: part) { parser throws(SheetError) in
            var builder = SheetBuilder(entry: entry, part: part, context: context)
            var sawRoot = false

            while let event = try parser.next() {
                guard event == .startElement else { continue }
                if !sawRoot {
                    sawRoot = true
                    continue
                }
                guard parser.depth == 2 else { continue }

                let localName = parser.name
                if !modelledWorksheetChildren.contains(localName) {
                    // `sheetPr` is captured like any other unmodelled element, but two things
                    // inside it are also model state — the VBA code name and the tab colour — so
                    // it is walked rather than skipped. The writer must still emit the *fragment*
                    // and not reconstruct it; see A1's handover notes.
                    let range = localName == "sheetPr"
                        ? try builder.readSheetProperties(&parser)
                        : try parser.skipElement()
                    // `schemaOrder` is left to the model, which now lists `legacyDrawing` and
                    // `legacyDrawingHF` in their real `CT_Worksheet` slots. An element the schema
                    // does not name at all — a producer extension — sorts into `extLst`'s slot,
                    // which is where an unrecognised element is least likely to break anything.
                    builder.fragments.append(
                        SheetFragment(elementName: localName, xml: parser.rawText(range))
                    )
                    continue
                }

                switch localName {
                case "dimension": try builder.readDimension(&parser)
                case "sheetViews": try builder.readSheetViews(&parser)
                case "sheetFormatPr": builder.readSheetFormatProperties(&parser)
                case "cols": try builder.readColumns(&parser)
                case "sheetData": try builder.readSheetData(&parser)
                case "mergeCells": try builder.readMerges(&parser)
                case "hyperlinks": try builder.readHyperlinks(&parser)
                case "autoFilter": builder.readAutoFilter(&parser)
                default: continue
                }
            }
            return try builder.finish()
        }
    }

    /// The rectangle a sheet's *content* occupies: populated cells **union every merged region**.
    ///
    /// Neither ``SheetModel/Sheet/usedRange`` (cells only) nor
    /// ``SheetModel/Sheet/formattedExtent`` (cells plus whole-row and whole-column formatting)
    /// covers this, because a merge extends the used range even where the covered cells have no
    /// `<c>` element at all — `Fixtures/structure/merged-cells.xlsx` holds four cells and the
    /// corpus calls its used range `A1:F8`. Pick deliberately per call site; this is the one the
    /// fixtures mean.
    public static func contentExtent(of sheet: Sheet) -> CellRange? {
        var result = sheet.usedRange
        for merge in sheet.merges {
            result = result.map { $0.union(merge) } ?? merge
        }
        return result
    }
}

/// Mutable state for one sheet parse, kept out of ``WorksheetReader`` so the phases read as
/// phases rather than as one 400-line function.
private struct SheetBuilder {
    let entry: WorkbookSheetEntry
    let part: String
    let context: Context

    typealias Context = WorksheetReader.Context

    var cells = CellStore()
    var merges: [CellRange] = []
    var hyperlinks: [CellRef: Hyperlink] = [:]
    var arrayRanges: [CellRef: CellRange] = [:]
    var fragments: [SheetFragment] = []
    var declaredDimension: CellRange?
    var autoFilter: CellRange?
    var frozen = FrozenPanes.none
    var showsGridlines = true
    var isRightToLeft = false
    var zoomScale: Double = 1
    var codeName: String?
    var tabColor: StyleColor?

    var defaultRowHeight = Limits.defaultRowHeight
    var defaultColumnWidth = XLSXColumnMetrics.points(fromCharacters: SheetBuilder.excelDefaultCharacters)

    var columnWidths: RunLengthArray<Double>?
    var rowHeights: RunLengthArray<Double>?
    var hiddenColumns = RunLengthArray(defaultValue: false)
    var hiddenRows = RunLengthArray(defaultValue: false)
    var columnStyles = RunLengthArray(defaultValue: StyleID.default)
    var rowStyles = RunLengthArray(defaultValue: StyleID.default)
    var columnOutlineLevels = RunLengthArray(defaultValue: UInt8(0))
    var rowOutlineLevels = RunLengthArray(defaultValue: UInt8(0))

    /// `si` → the master formula it stands for.
    var sharedMasters: [Int: (anchor: CellRef, text: String)] = [:]
    /// Followers waiting for their master, which the file is free to list afterwards.
    var pendingShared: [(ref: CellRef, si: Int)] = []

    /// Excel's default column width, in "characters of the normal font".
    static let excelDefaultCharacters: Double = 8.43

    init(entry: WorkbookSheetEntry, part: String, context: Context) {
        self.entry = entry
        self.part = part
        self.context = context
    }

    // MARK: - Worksheet children

    mutating func readDimension(_ parser: inout XMLPullParser) throws(SheetError) {
        guard let ref = parser.attribute("ref"), !ref.isEmpty else { return }
        let text = try ref.string()
        if let range = CellRange(a1: text) {
            declaredDimension = range
            return
        }
        // Unparseable is usually harmless — `<dimension>` is a capacity hint and producers get it
        // wrong constantly. Unparseable *because it is bigger than the format allows* is not:
        // `Fixtures/hostile/dimension-4-billion-rows.xlsx` claims 2³² rows, and a reader that
        // sizes anything from that is finished before it starts.
        let claimed = DimensionClaim(text)
        if claimed.rows > Limits.rowCount || claimed.columns > Limits.columnCount {
            throw SheetError.sheetDimensionOutOfRange(
                sheet: entry.name, rows: claimed.rows, columns: claimed.columns
            )
        }
    }

    /// Walks `<sheetPr>` for the two things in it the model holds, and returns the element's full
    /// byte range so it can still be captured verbatim.
    mutating func readSheetProperties(_ parser: inout XMLPullParser) throws(SheetError) -> Range<Int> {
        let start = parser.elementStart
        let target = parser.depth - 1
        if let code = parser.attribute("codeName") { codeName = try code.string() }
        while let event = try parser.next() {
            if event == .startElement, parser.nameIs("tabColor") {
                tabColor = StylesReader.readColor(&parser)
            } else if event == .endElement, parser.depth == target {
                return start ..< parser.offset
            }
        }
        throw SheetError.xmlMalformed(part: part, line: nil, detail: "<sheetPr> is not closed")
    }

    mutating func readSheetViews(_ parser: inout XMLPullParser) throws(SheetError) {
        let target = parser.depth - 1
        var seenView = false
        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("sheetView"), !seenView {
                    seenView = true
                    showsGridlines = parser.attribute("showGridLines")?.bool ?? true
                    isRightToLeft = parser.attribute("rightToLeft")?.bool ?? false
                    if let zoom = parser.attribute("zoomScale")?.double, zoom > 0 {
                        zoomScale = min(max(zoom / 100, 0.1), 4)
                    }
                } else if parser.nameIs("pane"), seenView {
                    readPane(&parser)
                }
            case .endElement:
                if parser.depth == target { return }
            case .characters:
                continue
            }
        }
    }

    /// `<pane xSplit="2" ySplit="1" topLeftCell="C2" state="frozen"/>`.
    ///
    /// The same element means two different things. With `state="frozen"` the splits are **counts
    /// of columns and rows**; without it they are **positions in twentieths of a point**. Reading
    /// a split position as a count gives `Fixtures/structure/split-panes.xlsx` a 2130-column
    /// freeze, which is the trap that fixture exists to catch.
    private mutating func readPane(_ parser: inout XMLPullParser) {
        let xSplit = parser.attribute("xSplit")?.double ?? 0
        let ySplit = parser.attribute("ySplit")?.double ?? 0
        let state = parser.attribute("state")
        let isFrozen = state?.equals("frozen") == true || state?.equals("frozenSplit") == true
        let topLeft = (try? parser.attribute("topLeftCell")?.string()).flatMap { $0 }
            .flatMap { CellRef(a1: $0) }

        if isFrozen {
            frozen = FrozenPanes(
                frozenRows: max(Int(ySplit), 0),
                frozenColumns: max(Int(xSplit), 0),
                topLeftVisible: topLeft
            )
        } else if xSplit > 0 || ySplit > 0 {
            // Twentieths of a point → points → pixels at 96 dpi, which is the unit
            // ``FrozenPanes/horizontalSplit`` documents. A2 inverts with × 15.
            frozen = FrozenPanes(
                topLeftVisible: topLeft,
                horizontalSplit: ySplit > 0 ? ySplit / 15 : nil,
                verticalSplit: xSplit > 0 ? xSplit / 15 : nil
            )
        }
    }

    /// `<sheetFormatPr defaultRowHeight="15" defaultColWidth="8.43" baseColWidth="8"/>`.
    ///
    /// The row height is already in points. The two column attributes are in characters —
    /// `defaultColWidth` is the modern one, `baseColWidth` the older — and a file that says
    /// neither means Excel's own 8.43.
    mutating func readSheetFormatProperties(_ parser: inout XMLPullParser) {
        if let height = parser.attribute("defaultRowHeight")?.double, height > 0 {
            defaultRowHeight = height
        }
        let characters = [parser.attribute("defaultColWidth")?.double, parser.attribute("baseColWidth")?.double]
            .compactMap { $0 }
            .first { $0 > 0 } ?? SheetBuilder.excelDefaultCharacters
        defaultColumnWidth = XLSXColumnMetrics.points(fromCharacters: characters)
    }

    mutating func readColumns(_ parser: inout XMLPullParser) throws(SheetError) {
        let target = parser.depth - 1
        var widths = RunLengthArray(defaultValue: defaultColumnWidth)
        var sawWidth = false

        while let event = try parser.next() {
            switch event {
            case .startElement:
                guard parser.nameIs("col") else { continue }
                guard let first = parser.attribute("min")?.int, let last = parser.attribute("max")?.int,
                      first >= 1, last >= first
                else { continue }
                let low = first - 1
                let high = min(last - 1, Limits.maxColumn)
                guard low <= high, low <= Limits.maxColumn else { continue }
                let span = low ... high

                if let width = parser.attribute("width")?.double {
                    widths.setValue(XLSXColumnMetrics.points(fromCharacters: width), in: span)
                    sawWidth = true
                }
                if parser.attribute("hidden")?.bool == true {
                    hiddenColumns.setValue(true, in: span)
                }
                if let style = parser.attribute("style")?.int32, style != 0 {
                    columnStyles.setValue(StyleID(rawValue: style), in: span)
                }
                if let level = parser.attribute("outlineLevel")?.int, level > 0 {
                    columnOutlineLevels.setValue(UInt8(clamping: level), in: span)
                }
            case .endElement:
                if parser.depth == target {
                    if sawWidth { columnWidths = widths }
                    return
                }
            case .characters:
                continue
            }
        }
    }

    mutating func readMerges(_ parser: inout XMLPullParser) throws(SheetError) {
        let target = parser.depth - 1
        while let event = try parser.next() {
            switch event {
            case .startElement:
                guard parser.nameIs("mergeCell"), let ref = parser.attribute("ref") else { continue }
                let text = try ref.string()
                guard let range = CellRange(a1: text) else {
                    throw SheetError.rangeOutOfRange(range: text, detail: "a merged range is not a valid reference")
                }
                merges.append(range)
            case .endElement:
                if parser.depth == target { return }
            case .characters:
                continue
            }
        }
    }

    mutating func readHyperlinks(_ parser: inout XMLPullParser) throws(SheetError) {
        let target = parser.depth - 1
        while let event = try parser.next() {
            switch event {
            case .startElement:
                guard parser.nameIs("hyperlink"), let refValue = parser.attribute("ref") else { continue }
                let refText = try refValue.string()
                guard let anchor = CellRange(a1: refText)?.start ?? CellRef(a1: refText) else { continue }
                let relationshipID = try parser.attribute("id")?.string()
                let location = try parser.attribute("location")?.string()
                let relationship = relationshipID.flatMap { context.relationships[$0] }
                // Never resolved, never fetched, never previewed (PLAN.md §7.3). The target is
                // recorded exactly as stored and stays inert until somebody clicks it.
                let linkTarget = relationship?.target ?? location.map { "#\($0)" } ?? ""
                hyperlinks[anchor] = Hyperlink(
                    target: linkTarget,
                    isExternal: relationship?.isExternal ?? (relationship != nil),
                    location: location,
                    tooltip: try parser.attribute("tooltip")?.string(),
                    relationshipID: relationshipID
                )
            case .endElement:
                if parser.depth == target { return }
            case .characters:
                continue
            }
        }
    }

    mutating func readAutoFilter(_ parser: inout XMLPullParser) {
        guard let ref = parser.attribute("ref"), let text = try? ref.string() else { return }
        autoFilter = CellRange(a1: text)
    }

    // MARK: - Sheet data

    mutating func readSheetData(_ parser: inout XMLPullParser) throws(SheetError) {
        let target = parser.depth - 1
        var heights = RunLengthArray(defaultValue: defaultRowHeight)
        var sawHeight = false
        var row = 0
        var nextColumn = 0

        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("row") {
                    if let value = parser.attribute("r") {
                        guard let index = value.int, index >= 1, index <= Limits.rowCount else {
                            let written = (try? value.string()) ?? "?"
                            throw SheetError.invalidCellReference(text: "row r=\"\(written)\"")
                        }
                        row = index - 1
                    }
                    nextColumn = 0
                    if let height = parser.attribute("ht")?.double, height >= 0 {
                        heights.setValue(height, in: row ... row)
                        sawHeight = true
                    }
                    if parser.attribute("hidden")?.bool == true {
                        hiddenRows.setValue(true, in: row ... row)
                    }
                    if parser.attribute("customFormat")?.bool == true,
                       let style = parser.attribute("s")?.int32, style != 0 {
                        rowStyles.setValue(StyleID(rawValue: style), in: row ... row)
                    }
                    if let level = parser.attribute("outlineLevel")?.int, level > 0 {
                        rowOutlineLevels.setValue(UInt8(clamping: level), in: row ... row)
                    }
                } else if parser.nameIs("c") {
                    try readCell(&parser, row: row, nextColumn: &nextColumn)
                }
            case .endElement:
                if parser.nameIs("row") { row += 1 }
                if parser.depth == target {
                    if sawHeight { rowHeights = heights }
                    return
                }
            case .characters:
                continue
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private mutating func readCell(
        _ parser: inout XMLPullParser,
        row: Int,
        nextColumn: inout Int
    ) throws(SheetError) {
        let target = parser.depth - 1
        let reference: CellRef
        if let value = parser.attribute("r") {
            guard let parsed = value.cellRef else {
                throw SheetError.invalidCellReference(text: try value.string())
            }
            reference = parsed
        } else {
            // `r` is optional. Producers that omit it mean "the next column of this row".
            guard Limits.isValidColumn(nextColumn) else {
                throw SheetError.cellReferenceOutOfRange(row: row, column: nextColumn)
            }
            reference = CellRef(row: row, column: nextColumn)
        }
        nextColumn = reference.column + 1

        let styleID = StyleID(rawValue: parser.attribute("s")?.int32 ?? 0)
        let type = CellType(parser.attribute("t"))

        var value = CellValue.empty
        var formula: String?
        var flags = CellFlags()
        var pendingSharedIndex: Int?

        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("v") {
                    value = try readValue(&parser, type: type, at: reference, flags: &flags)
                } else if parser.nameIs("is") {
                    let item = try SharedStringsReader.readStringItem(&parser)
                    if item.hasRuns { flags.insert(.richText) }
                    flags.insert(.inlineString)
                    value = .text(try checkedText(item.text, at: reference))
                } else if parser.nameIs("f") {
                    let outcome = try readFormula(&parser, at: reference)
                    formula = outcome.text
                    flags.formUnion(outcome.flags)
                    pendingSharedIndex = outcome.pendingSharedIndex
                }
            case .endElement:
                if parser.depth == target {
                    if let index = pendingSharedIndex { pendingShared.append((reference, index)) }
                    // A `<c>` that exists is a cell, even when it holds nothing: `<c r="G1" s="0"/>`
                    // is in `Fixtures/basic/types.xlsx` and the corpus expects it in the model.
                    try store(Cell(value: value, formula: formula, styleID: styleID, flags: flags), at: reference)
                    return
                }
            case .characters:
                continue
            }
        }
        throw SheetError.xmlMalformed(part: part, line: nil, detail: "<c> is not closed")
    }

    private mutating func readValue(
        _ parser: inout XMLPullParser,
        type: CellType,
        at reference: CellRef,
        flags: inout CellFlags
    ) throws(SheetError) -> CellValue {
        let target = parser.depth - 1
        var value = CellValue.empty
        var accumulated: String?
        var sawText = false

        while let event = try parser.next() {
            switch event {
            case .characters:
                if type.accumulatesText {
                    accumulated = (accumulated ?? "") + (try parser.text.string())
                } else if !sawText {
                    // The fast path, and the one that runs a million times: straight from bytes
                    // to a `Double`, an index or a flag, with no `String` in between.
                    value = try readScalar(&parser, type: type, at: reference, flags: &flags)
                }
                sawText = true
            case .endElement:
                if parser.depth == target {
                    if let accumulated {
                        value = type == .error
                            ? .error(CellError(rawValue: accumulated) ?? .wrongType)
                            : .text(try checkedText(accumulated, at: reference))
                    }
                    return value
                }
            case .startElement:
                continue
            }
        }
        throw SheetError.xmlMalformed(part: part, line: nil, detail: "<v> is not closed")
    }

    private func readScalar(
        _ parser: inout XMLPullParser,
        type: CellType,
        at reference: CellRef,
        flags: inout CellFlags
    ) throws(SheetError) -> CellValue {
        switch type {
        case .boolean:
            return .boolean(parser.text.bool)
        case .sharedString:
            guard let index = parser.text.int else { return .empty }
            guard let text = context.sharedStrings[index] else {
                // A dangling index is a damaged file, not an attack. An empty cell is a better
                // outcome than refusing to open the workbook over it.
                return .empty
            }
            if context.sharedStrings.isRich(index) { flags.insert(.richText) }
            return .text(try checkedText(text, at: reference))
        case .isoDate:
            let text = try parser.text.string()
            if let serial = ISODate.serial(text, system: context.dateSystem) { return .number(serial) }
            return .text(try checkedText(text, at: reference))
        default:
            guard let number = parser.text.double else { return .empty }
            return .number(number)
        }
    }

    private struct FormulaOutcome {
        var text: String?
        var flags = CellFlags()
        var pendingSharedIndex: Int?
    }

    private mutating func readFormula(
        _ parser: inout XMLPullParser,
        at reference: CellRef
    ) throws(SheetError) -> FormulaOutcome {
        let target = parser.depth - 1
        let kind = parser.attribute("t")
        let sharedIndex = parser.attribute("si")?.int
        let regionText = try parser.attribute("ref")?.string()
        let isShared = kind?.equals("shared") == true
        let isArray = kind?.equals("array") == true
        let isDataTable = kind?.equals("dataTable") == true

        var source = ""
        while let event = try parser.next() {
            if event == .characters {
                source += try parser.text.string()
            } else if event == .endElement, parser.depth == target {
                break
            }
        }

        var outcome = FormulaOutcome()
        if isArray {
            outcome.flags.insert(.arrayFormula)
            if let regionText, let region = CellRange(a1: regionText) {
                arrayRanges[reference] = region
            }
        }
        if isDataTable {
            // `<f t="dataTable">` has no text of its own; the whole table lives in attributes we
            // do not model. Flagged so nothing pretends to understand it, and the original part
            // still round-trips.
            outcome.flags.insert(.unsupportedFormula)
            return outcome
        }

        if source.isEmpty {
            if isShared, let sharedIndex {
                outcome.flags.insert(.sharedFormulaExpansion)
                outcome.pendingSharedIndex = sharedIndex
            }
            return outcome
        }

        guard source.count <= Limits.maxFormulaLength else {
            throw SheetError.formulaTooLong(length: source.count, limit: Limits.maxFormulaLength)
        }
        if isShared, let sharedIndex {
            sharedMasters[sharedIndex] = (reference, source)
        }
        if FormulaReferences.referencesExternalWorkbook(source) {
            outcome.flags.insert(.externalLink)
        }
        outcome.text = source
        return outcome
    }

    // MARK: - Storing

    private mutating func store(_ cell: Cell, at reference: CellRef) throws(SheetError) {
        guard reference.isValid else {
            throw SheetError.cellReferenceOutOfRange(row: reference.row, column: reference.column)
        }
        try cells.setCell(cell, at: reference)
    }

    private func checkedText(_ text: String, at reference: CellRef) throws(SheetError) -> String {
        let length = text.count
        guard length <= Limits.maxCellTextLength else {
            throw SheetError.cellTextTooLong(
                ref: reference.a1String, length: length, limit: Limits.maxCellTextLength
            )
        }
        return text
    }

    // MARK: - Assembly

    mutating func finish() throws(SheetError) -> Sheet {
        try expandSharedFormulas()
        flagArrayFollowers()
        flagHyperlinkedCells()

        return Sheet(
            id: entry.id,
            name: entry.name,
            cells: cells,
            columnWidths: columnWidths,
            rowHeights: rowHeights,
            hiddenColumns: hiddenColumns,
            hiddenRows: hiddenRows,
            columnStyles: columnStyles,
            rowStyles: rowStyles,
            columnOutlineLevels: columnOutlineLevels,
            rowOutlineLevels: rowOutlineLevels,
            merges: merges,
            frozen: frozen,
            visibility: entry.visibility,
            hyperlinks: hyperlinks,
            arrayFormulaRanges: arrayRanges,
            autoFilter: autoFilter,
            tabColor: tabColor,
            showsGridlines: showsGridlines,
            isRightToLeft: isRightToLeft,
            zoomScale: zoomScale,
            defaultColumnWidth: defaultColumnWidth,
            defaultRowHeight: defaultRowHeight,
            declaredDimension: declaredDimension,
            partPath: part,
            relationshipID: entry.relationshipID,
            codeName: codeName,
            sheetLevelFragments: fragments
        )
    }

    /// Gives every follower of a `<f t="shared">` group its own translated formula text.
    ///
    /// Resolved after the whole sheet rather than inline, because nothing in the format requires
    /// the master to appear before its followers.
    private mutating func expandSharedFormulas() throws(SheetError) {
        for pending in pendingShared {
            guard let master = sharedMasters[pending.si], var cell = cells[pending.ref] else { continue }
            cell.formula = FormulaReferences.translate(master.text, from: master.anchor, to: pending.ref)
            cell.flags.insert(.sharedFormulaExpansion)
            if let text = cell.formula, FormulaReferences.referencesExternalWorkbook(text) {
                cell.flags.insert(.externalLink)
            }
            try cells.setCell(cell, at: pending.ref)
        }
    }

    /// Marks the cells an array formula spills into.
    ///
    /// They carry only a `<v>`, so nothing else would say they are not ordinary numbers — and
    /// editing one cell of an array formula is illegal in Excel and produces a file it will not
    /// open, which is a refusal the editor can only make if it knows.
    private mutating func flagArrayFollowers() {
        for (anchor, region) in arrayRanges {
            guard region.cellCount <= 1 << 20 else { continue }
            for ref in region where ref != anchor {
                guard var cell = cells[ref] else { continue }
                cell.flags.insert(.arrayFormula)
                try? cells.setCell(cell, at: ref)
            }
        }
    }

    private mutating func flagHyperlinkedCells() {
        for ref in hyperlinks.keys {
            if var cell = cells[ref] {
                cell.flags.insert(.hyperlink)
                try? cells.setCell(cell, at: ref)
            } else {
                try? cells.setCell(Cell(value: .empty, flags: .hyperlink), at: ref)
            }
        }
    }
}

/// A cell's `t` attribute.
private enum CellType {
    /// `t` absent, or `t="n"`.
    case number
    /// `t="s"` — an index into the shared string table.
    case sharedString
    /// `t="str"` — a formula whose cached result is text.
    case formulaString
    /// `t="b"`.
    case boolean
    /// `t="e"`.
    case error
    /// `t="inlineStr"`.
    case inlineString
    /// `t="d"` — an ISO 8601 date. Rare, but real, and in the format since 2009.
    case isoDate

    /// Whether the `<v>` needs entity decoding and multi-run accumulation rather than the
    /// allocation-free scalar path.
    var accumulatesText: Bool {
        self == .formulaString || self == .error || self == .inlineString
    }

    init(_ value: XMLValue?) {
        guard let value else {
            self = .number
            return
        }
        if value.equals("s") { self = .sharedString } else if value.equals("str") {
            self = .formulaString
        } else if value.equals("b") {
            self = .boolean
        } else if value.equals("e") {
            self = .error
        } else if value.equals("inlineStr") {
            self = .inlineString
        } else if value.equals("d") {
            self = .isoDate
        } else {
            self = .number
        }
    }
}

/// What a malformed `<dimension ref>` claims, extracted leniently so the claim can be rejected
/// on its own terms.
private struct DimensionClaim {
    var rows = 0
    var columns = 0

    init(_ text: String) {
        for part in text.split(separator: ":") {
            var column = 0
            var row = 0
            for byte in part.utf8 {
                switch byte {
                case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"):
                    column = min(column * 26 + Int(byte | 0x20) - 96, Int.max / 32)
                case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                    row = min(row * 10 + Int(byte - UInt8(ascii: "0")), Int.max / 16)
                default:
                    continue
                }
            }
            rows = max(rows, row)
            columns = max(columns, column)
        }
    }
}

/// `t="d"` cells store an ISO 8601 date; the model stores a serial number, because Excel has no
/// date type and inventing one means disagreeing with Excel about what `=A1+1` does.
enum ISODate {
    static func serial(_ text: String, system: DateSystem) -> Double? {
        let bytes = Array(text.utf8)
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= bytes.count else { return nil }
            var value = 0
            for index in range {
                guard bytes[index] >= UInt8(ascii: "0"), bytes[index] <= UInt8(ascii: "9") else { return nil }
                value = value * 10 + Int(bytes[index] - UInt8(ascii: "0"))
            }
            return value
        }
        guard bytes.count >= 10, let year = number(0 ..< 4), let month = number(5 ..< 7),
              let day = number(8 ..< 10)
        else { return nil }

        var hour = 0
        var minute = 0
        var second = 0
        var millisecond = 0
        if bytes.count >= 19 {
            hour = number(11 ..< 13) ?? 0
            minute = number(14 ..< 16) ?? 0
            second = number(17 ..< 19) ?? 0
            if bytes.count >= 23, bytes[19] == UInt8(ascii: ".") {
                millisecond = number(20 ..< 23) ?? 0
            }
        }
        return SerialDate.serial(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second, millisecond: millisecond,
            system: system
        )
    }
}
