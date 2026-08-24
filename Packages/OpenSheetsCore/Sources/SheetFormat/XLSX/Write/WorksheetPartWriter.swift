//
//  WorksheetPartWriter.swift
//  SheetFormat
//
//  Re-emitting `xl/worksheets/sheetN.xml` — the one part passthrough cannot save.
//

import Foundation
import SheetModel

/// Converting between the model's points and the file's "characters of the normal font".
///
/// `<col width>` is measured in widths of the digit `0` in the workbook's default font, plus
/// five pixels of padding. That unit is meaningless without font metrics, so the model
/// normalises to points at parse time — and the writer has to put it back.
///
/// **The reader must use the inverse of this.** Two different approximations on the two sides
/// means every save nudges every column width, and after twenty saves the sheet looks wrong. The
/// conversion is public so `XLSX/Read` can call it rather than re-deriving one.
///
/// # Why there is no dots-per-inch conversion here
///
/// Excel measures a column in *pixels at 96 dpi*, and this conversion used to finish by scaling
/// by `72/96` to turn those into typographic points. That is arithmetically defensible and
/// visually wrong, because it converts the box without converting what goes in it: a cell whose
/// font is 11pt is drawn by `GridKit` at eleven **points**, not at eleven points scaled to a
/// 96 dpi pixel grid. Shrinking every column by a quarter while the glyphs kept their size is
/// what turned every numeric cell in a default-width column into `####`.
///
/// The unit that actually matters is the one both sides of the comparison are in: the width of
/// the digit `0` in the normal font. Excel calls that 7 px; measured on the face `FontResolver`
/// substitutes for Calibri at the same nominal 11pt it is 6.99 pt. So one Excel pixel is one
/// point *here*, and no scaling belongs between them.
///
/// # And why the padding is the renderer's, not Excel's
///
/// A `<col width>` is characters **plus padding**: Excel's five pixels, two either side and one
/// for the gridline. The width this returns is the whole column, and `GridRenderer` then takes
/// its own ``SheetModel/Limits/cellPadding`` back off before asking whether a number fits. So the
/// padding added here has to be the padding taken off there — reserve five and subtract twelve
/// and every column holds a character less than the file said it would, which is `####` in a
/// column Excel shows a number in. ``SheetModel/Limits/cellPadding`` is the one number.
public enum XLSXColumnMetrics {
    /// Width of the digit `0` in the normal font — Excel's "maximum digit width".
    ///
    /// Excel derives 7 from Calibri 11 at 96 dpi; `FontResolver` measures 6.99 pt for the face it
    /// substitutes at the same nominal size. They are the same number, so no scaling separates
    /// the file's unit from the renderer's.
    public static let maximumDigitWidth: Double = 7
    /// Padding a column carries beyond its characters. See the type's note for why this is the
    /// grid's figure rather than Excel's five pixels.
    public static var cellPadding: Double { Limits.cellPadding }

    /// A `baseColWidth` in the units `defaultColWidth` and `<col width>` use.
    ///
    /// They are **not** the same measurement, which is the trap: `baseColWidth` is "the number of
    /// characters required to fit the digits" and explicitly excludes the margin padding, while
    /// `defaultColWidth` includes it. Excel's own conversion adds the padding back and truncates
    /// to a 256th, which turns the near-universal `baseColWidth="8"` into exactly 8.7109375 — the
    /// width `Fixtures/structure/col-widths-row-heights.xlsx` shows Excel writing for an untouched
    /// column. Reading the 8 as if it were a `defaultColWidth` loses most of a character from every
    /// column of every file that writes the older attribute.
    public static func characters(fromBaseColWidth base: Double) -> Double {
        ((base * maximumDigitWidth + 5) / maximumDigitWidth * 256).rounded(.down) / 256
    }

    /// Points for a `<col width>` value.
    public static func points(fromCharacters characters: Double) -> Double {
        characters * maximumDigitWidth + cellPadding
    }

    /// A `<col width>` value for a width in points.
    public static func characters(fromPoints points: Double) -> Double {
        max(0, (points - cellPadding) / maximumDigitWidth)
    }
}

/// Serialises one worksheet part.
///
/// # The rule
///
/// Only `<sheetData>` and `<dimension>` are rebuilt from the model on an ordinary save.
/// Every other top-level child of `CT_Worksheet` is copied out of the original part **verbatim**,
/// unless the caller explicitly said it changed (see ``SheetRegionChanges``).
///
/// That inverts the usual writer design, and deliberately. A writer that regenerates everything
/// it can model is only as good as the reader's coverage of every attribute of every element —
/// and the first `<sheetView>` attribute nobody thought about is the first time somebody's
/// page-break-preview mode quietly disappears. Copying is correct by construction; generating is
/// correct only until the schema surprises you.
///
/// # Salvage
///
/// Elements are taken from the original part's own bytes rather than from
/// ``Sheet/sheetLevelFragments``, when the original is available. The fragments are the fallback.
/// This matters because the reader's captured-element list is finite and the schema is not:
/// `<legacyDrawing>`, the pointer that keeps cell comments attached to their sheet, is in neither
/// `SheetFragment.capturedElements` nor `SheetFragment.worksheetChildOrder`, yet it is in two
/// fixtures. Scanning the bytes finds it anyway.
public enum WorksheetPartWriter {
    /// What the writer needs besides the sheet itself.
    public struct Context {
        /// The original part's text, when the workbook came from a file.
        public var originalXML: String?
        /// The workbook's string table, appended to as text cells are written.
        public var strings: SharedStringTable
        /// Which regions may be rebuilt from the model.
        public var regions: SheetRegionChanges
        /// Write-time policy.
        public var options: XLSXWriteOptions

        public init(
            originalXML: String?,
            strings: SharedStringTable,
            regions: SheetRegionChanges,
            options: XLSXWriteOptions = .standard
        ) {
            self.originalXML = originalXML
            self.strings = strings
            self.regions = regions
            self.options = options
        }
    }

    /// The serialised part, plus the string table as it stands afterwards.
    public struct Output {
        public var xml: String
        public var strings: SharedStringTable
    }

    /// Serialises `sheet`.
    public static func serialise(_ sheet: Sheet, context: Context) throws(SheetError) -> Output {
        var context = context
        try refuseToDegradeDynamicArrays(on: sheet, policy: context.options.dynamicArrayMetadata)
        var original: ScannedXMLPart?
        if let xml = context.originalXML {
            original = try WorksheetPartScanner.scan(xml, part: sheet.partPath ?? sheet.name)
        }

        // With no original to copy from there is nothing to preserve, so everything the model
        // represents has to be generated.
        let regions: SheetRegionChanges = original == nil ? .all : context.regions

        // The elements this save is allowed to replace. Anything outside it is copied verbatim,
        // and an authorised element that turns out to be empty is *removed* rather than copied —
        // that is what makes "the user deleted every merge" work.
        var authorised: Set<String> = ["dimension", "sheetData"]
        if regions.contains(.views) { authorised.insert("sheetViews") }
        if regions.contains(.columns) { authorised.insert("cols") }
        if regions.contains(.merges) { authorised.insert("mergeCells") }
        if regions.contains(.hyperlinks) { authorised.insert("hyperlinks") }
        if regions.contains(.autoFilter) { authorised.insert("autoFilter") }
        if original == nil { authorised.formUnion(modelledElements) }

        var children: [XMLElementSlice] = []

        // --- generated ---------------------------------------------------------------------
        if let dimension = writtenDimension(of: sheet) {
            children.append(slice("dimension", "<dimension ref=\"\(dimension.a1String(collapseSingleCell: false))\"/>"))
        }
        if regions.contains(.views), let views = sheetViews(of: sheet) {
            children.append(slice("sheetViews", views))
        }
        if original == nil, let format = sheetFormatPr(of: sheet) {
            children.append(slice("sheetFormatPr", format))
        }
        if regions.contains(.columns), let cols = columns(of: sheet) {
            children.append(slice("cols", cols))
        }

        let salvagedRowAttributes = original
            .flatMap { $0.child(named: "sheetData") }
            .map { WorksheetPartScanner.rowAttributes(inSheetData: $0.text) } ?? [:]
        let sheetData = try self.sheetData(
            of: sheet,
            salvagedRowAttributes: regions.contains(.rows) ? [:] : salvagedRowAttributes,
            strings: &context.strings,
            options: context.options
        )
        children.append(slice("sheetData", sheetData))

        if regions.contains(.autoFilter), let filter = sheet.autoFilter {
            children.append(slice("autoFilter", "<autoFilter ref=\"\(filter.a1String)\"/>"))
        }
        if regions.contains(.merges), let merges = mergeCells(of: sheet) {
            children.append(slice("mergeCells", merges))
        }
        if regions.contains(.hyperlinks), let links = hyperlinks(of: sheet) {
            children.append(slice("hyperlinks", links))
        }

        // --- copied verbatim ---------------------------------------------------------------
        if let original, context.options.salvageUnmodelledSheetElements {
            for child in original.children where !authorised.contains(child.localName) {
                children.append(child)
            }
        } else {
            for fragment in WorksheetChildOrder.sorted(sheet.sheetLevelFragments)
                where !authorised.contains(fragment.elementName) {
                children.append(slice(fragment.elementName, fragment.xml))
            }
        }

        // --- assemble ----------------------------------------------------------------------
        var output = original?.prolog ?? (#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\r\n")
        output += original?.rootOpenTag ?? defaultRootTag
        for child in WorksheetChildOrder.sorted(children) {
            output += child.text
        }
        output += "</\(original?.rootQualifiedName ?? "worksheet")>"

        return Output(xml: output, strings: context.strings)
    }

    /// Element names the writer generates from the model, so a caller can tell which of a
    /// sheet's elements are at risk from a model gap and which are copied.
    public static let modelledElements: Set<String> = [
        "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData",
        "autoFilter", "mergeCells", "hyperlinks",
    ]

    private static let defaultRootTag =
        "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
            + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"

    private static func slice(_ name: String, _ text: String) -> XMLElementSlice {
        XMLElementSlice(localName: name, qualifiedName: name, text: text)
    }

    // MARK: - dimension

    /// The rectangle to declare.
    ///
    /// The union of what the producer declared, what the cells occupy, what is formatted, and
    /// what is merged. Union rather than recompute, because `<dimension>` is a capacity hint and
    /// a producer that deliberately declared a wider one (an empty formatted region, a range a
    /// chart points at) had a reason. Narrowing it gains nothing and can lose something.
    static func writtenDimension(of sheet: Sheet) -> CellRange? {
        var result = sheet.declaredDimension
        if let extent = sheet.formattedExtent {
            result = result.map { $0.union(extent) } ?? extent
        }
        for merge in sheet.merges {
            result = result.map { $0.union(merge) } ?? merge
        }
        return result
    }

    // MARK: - sheetViews

    private static func sheetViews(of sheet: Sheet) -> String? {
        var attributes = ""
        if !sheet.showsGridlines { attributes += " showGridLines=\"0\"" }
        if sheet.isRightToLeft { attributes += " rightToLeft=\"1\"" }
        if sheet.zoomScale != 1 { attributes += " zoomScale=\"\(Int((sheet.zoomScale * 100).rounded()))\"" }
        attributes += " workbookViewId=\"0\""

        var pane = ""
        let frozen = sheet.frozen
        if frozen.isFrozen || frozen.isSplit {
            var paneAttributes = ""
            if let split = frozen.verticalSplit {
                paneAttributes += " xSplit=\"\(XLSXEscape.number(split))\""
            } else if frozen.frozenColumns > 0 {
                paneAttributes += " xSplit=\"\(frozen.frozenColumns)\""
            }
            if let split = frozen.horizontalSplit {
                paneAttributes += " ySplit=\"\(XLSXEscape.number(split))\""
            } else if frozen.frozenRows > 0 {
                paneAttributes += " ySplit=\"\(frozen.frozenRows)\""
            }
            let topLeft = frozen.topLeftVisible
                ?? CellRef(row: frozen.frozenRows, column: frozen.frozenColumns)
            paneAttributes += " topLeftCell=\"\(topLeft.a1String)\""
            paneAttributes += " activePane=\"bottomRight\""
            if frozen.isFrozen, !frozen.isSplit { paneAttributes += " state=\"frozen\"" }
            pane = "<pane\(paneAttributes)/>"
        }

        guard !pane.isEmpty || !sheet.showsGridlines || sheet.isRightToLeft || sheet.zoomScale != 1 else {
            return nil
        }
        return "<sheetViews><sheetView\(attributes)>\(pane)</sheetView></sheetViews>"
    }

    // MARK: - sheetFormatPr

    private static func sheetFormatPr(of sheet: Sheet) -> String? {
        var attributes = ""
        if sheet.defaultRowHeight != Limits.defaultRowHeight {
            attributes += " defaultRowHeight=\"\(XLSXEscape.number(sheet.defaultRowHeight))\""
        }
        if sheet.defaultColumnWidth != Limits.defaultColumnWidth {
            let characters = XLSXColumnMetrics.characters(fromPoints: sheet.defaultColumnWidth)
            attributes += " defaultColWidth=\"\(XLSXEscape.number((characters * 100).rounded() / 100))\""
        }
        guard !attributes.isEmpty else { return nil }
        return "<sheetFormatPr\(attributes)/>"
    }

    // MARK: - cols

    private static func columns(of sheet: Sheet) -> String? {
        struct Band {
            var range: ClosedRange<Int>
            var width: Double?
            var hidden: Bool
            var style: StyleID
            var outline: UInt8
        }

        var boundaries: Set<Int> = []
        for run in sheet.columnWidths.runs { boundaries.insert(run.range.lowerBound); boundaries
            .insert(run.range.upperBound + 1)
        }
        for run in sheet.hiddenColumns.runs { boundaries.insert(run.range.lowerBound); boundaries
            .insert(run.range.upperBound + 1)
        }
        for run in sheet.columnStyles.runs { boundaries.insert(run.range.lowerBound); boundaries
            .insert(run.range.upperBound + 1)
        }
        for run in sheet.columnOutlineLevels.runs { boundaries.insert(run.range.lowerBound); boundaries
            .insert(run.range.upperBound + 1)
        }
        let starts = boundaries.filter { $0 >= 0 && $0 <= Limits.maxColumn }.sorted()
        guard !starts.isEmpty else { return nil }

        var bands: [Band] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] - 1 : start
            guard end >= start else { continue }
            let width = sheet.columnWidths.runs(in: start ... start).first.map { _ in sheet.columnWidths[start] }
            let band = Band(
                range: start ... end,
                width: width,
                hidden: sheet.hiddenColumns[start],
                style: sheet.columnStyles[start],
                outline: sheet.columnOutlineLevels[start]
            )
            if band.width == nil, !band.hidden, band.style == .default, band.outline == 0 { continue }
            if var last = bands.last,
               last.width == band.width, last.hidden == band.hidden,
               last.style == band.style, last.outline == band.outline,
               last.range.upperBound + 1 == band.range.lowerBound {
                last.range = last.range.lowerBound ... band.range.upperBound
                bands[bands.count - 1] = last
            } else {
                bands.append(band)
            }
        }
        guard !bands.isEmpty else { return nil }

        var output = "<cols>"
        for band in bands {
            output += "<col min=\"\(band.range.lowerBound + 1)\" max=\"\(band.range.upperBound + 1)\""
            if let width = band.width {
                let characters = (XLSXColumnMetrics.characters(fromPoints: width) * 100).rounded() / 100
                output += " width=\"\(XLSXEscape.number(characters))\" customWidth=\"1\""
            }
            if band.hidden { output += " hidden=\"1\"" }
            if band.style != .default { output += " style=\"\(band.style.rawValue)\"" }
            if band.outline > 0 { output += " outlineLevel=\"\(band.outline)\"" }
            output += "/>"
        }
        return output + "</cols>"
    }

    // MARK: - sheetData

    private static func sheetData(
        of sheet: Sheet,
        salvagedRowAttributes: [Int: String],
        strings: inout SharedStringTable,
        options: XLSXWriteOptions
    ) throws(SheetError) -> String {
        var rowIndices = Set(sheet.cells.sortedRowIndices())
        rowIndices.formUnion(salvagedRowAttributes.keys.compactMap { $0 >= 1 ? $0 - 1 : nil })
        if salvagedRowAttributes.isEmpty {
            addMetricOnlyRows(of: sheet, to: &rowIndices)
        }
        guard !rowIndices.isEmpty else { return "<sheetData/>" }

        var output = "<sheetData>"
        for row in rowIndices.sorted() {
            let cells = sheet.cells
                .cells(in: CellRange(rows: row ... row, columns: 0 ... Limits.maxColumn))
                .sorted { $0.ref.column < $1.ref.column }
            let attributes = salvagedRowAttributes[row + 1] ?? modelRowAttributes(of: sheet, row: row)
            let spans = cells.isEmpty
                ? ""
                : " spans=\"\(cells[0].ref.column + 1):\(cells[cells.count - 1].ref.column + 1)\""

            if cells.isEmpty {
                output += "<row r=\"\(row + 1)\"\(attributes)/>"
                continue
            }
            output += "<row r=\"\(row + 1)\"\(spans)\(attributes)>"
            for (ref, cell) in cells {
                output += try self.cell(cell, at: ref, in: sheet, strings: &strings, options: options)
            }
            output += "</row>"
        }
        return output + "</sheetData>"
    }

    /// Rows that hold no cells but do hold formatting.
    ///
    /// Skips runs wider than a sane window: `RunLengthArray` can legitimately describe a value
    /// over all 1,048,576 rows in a single run, and emitting a `<row>` element for each of them
    /// would turn a 4 KB sheet into a 40 MB one.
    private static func addMetricOnlyRows(of sheet: Sheet, to rows: inout Set<Int>) {
        let budget = 65_536
        var added = 0
        func absorb(_ ranges: [ClosedRange<Int>]) {
            for range in ranges where range.count <= budget {
                guard added + range.count <= budget else { return }
                for index in range where index >= 0 && index <= Limits.maxRow {
                    rows.insert(index)
                }
                added += range.count
            }
        }
        absorb(sheet.rowHeights.runs.map(\.range))
        absorb(sheet.hiddenRows.runs.map(\.range))
        absorb(sheet.rowStyles.runs.map(\.range))
        absorb(sheet.rowOutlineLevels.runs.map(\.range))
    }

    private static func modelRowAttributes(of sheet: Sheet, row: Int) -> String {
        var attributes = ""
        if !sheet.rowHeights.runs(in: row ... row).isEmpty {
            attributes += " ht=\"\(XLSXEscape.number(sheet.rowHeights[row]))\" customHeight=\"1\""
        }
        if sheet.hiddenRows[row] { attributes += " hidden=\"1\"" }
        let style = sheet.rowStyles[row]
        if style != .default { attributes += " s=\"\(style.rawValue)\" customFormat=\"1\"" }
        let outline = sheet.rowOutlineLevels[row]
        if outline > 0 { attributes += " outlineLevel=\"\(outline)\"" }
        return attributes
    }

    /// Refuses to regenerate a sheet whose dynamic-array metadata we would silently drop.
    ///
    /// The alternative is what OpenSheets did before: rewrite the sheet, lose the `cm`/`vm`
    /// indices, and hand back a file whose `FILTER` no longer resizes. That is a change the
    /// user did not ask for, cannot see, and cannot undo — which is the definition of the
    /// corruption this project refuses to ship. Saying so and stopping is worse for one save
    /// and better for the file.
    private static func refuseToDegradeDynamicArrays(
        on sheet: Sheet, policy: XLSXWriteOptions.DynamicArrayMetadataPolicy
    ) throws(SheetError) {
        guard policy == .refuse else { return }
        var offender: CellRef?
        sheet.cells.forEachCell(in: .entireSheet) { ref, cell in
            if offender == nil, cell.flags.contains(.hasCellMetadata) { offender = ref }
        }
        guard let offender else { return }
        throw SheetError.notImplemented(
            feature: """
            rewriting sheet '\(sheet.name)': \(offender.a1String) is part of a dynamic array whose \
            xl/metadata.xml entry OpenSheets cannot reproduce, and saving would downgrade it to a \
            fixed-size array formula
            """
        )
    }

    // MARK: - cells

    private static func cell(
        _ cell: Cell,
        at ref: CellRef,
        in sheet: Sheet,
        strings: inout SharedStringTable,
        options: XLSXWriteOptions
    ) throws(SheetError) -> String {
        var attributes = " r=\"\(ref.a1String)\""
        if cell.styleID != .default { attributes += " s=\"\(cell.styleID.rawValue)\"" }

        var typeAttribute = ""
        var body = ""

        // An empty formula is not a formula. It arrives from a shared-formula follower whose
        // master was never expanded, and `<f></f>` is a cell Excel reports as damaged — worse
        // than the literal value we already have cached for it.
        // A cell we could not compute has no value of its own: the placeholder in
        // `cell.value` exists so the *screen* says "uncomputed" rather than showing a blank.
        // Writing it would turn our admission into the producer's error, in their file.
        if cell.flags.contains(.uncomputed) {
            let source = (cell.formula?.isEmpty ?? true) ? nil : cell.formula
            guard let source else { return "<c\(attributes)/>" }
            let stored = XLSXFunctionNames.storedForm(source)
            let safe = try XLSXEscape.sanitiseCellText(stored, policy: options.controlCharacters, ref: ref.a1String)
            var arrayAttributes = ""
            if let region = sheet.arrayFormulaRanges[ref] {
                arrayAttributes = " t=\"array\" ref=\"\(region.a1String(collapseSingleCell: false))\""
            }
            return "<c\(attributes)><f\(arrayAttributes)>\(XLSXEscape.text(safe))</f></c>"
        }

        let formula = (cell.formula?.isEmpty ?? true) ? nil : cell.formula
        if let formula {
            var formulaAttributes = ""
            if let region = sheet.arrayFormulaRanges[ref] {
                formulaAttributes = " t=\"array\" ref=\"\(region.a1String(collapseSingleCell: false))\""
            }
            let stored = XLSXFunctionNames.storedForm(formula)
            let safe = try XLSXEscape.sanitiseCellText(stored, policy: options.controlCharacters, ref: ref.a1String)
            body += "<f\(formulaAttributes)>\(XLSXEscape.text(safe))</f>"
        }

        switch cell.value {
        case .empty:
            break
        case let .number(value):
            guard value.isFinite else {
                // Neither infinity nor NaN has an xlsx spelling. Excel stores the error it would
                // have produced, and so do we, rather than writing a token no reader accepts.
                typeAttribute = " t=\"e\""
                body += "<v>\(CellError.invalidNumber.xlsxToken)</v>"
                return "<c\(attributes)\(typeAttribute)>\(body)</c>"
            }
            body += "<v>\(XLSXEscape.number(value))</v>"
        case let .boolean(value):
            typeAttribute = " t=\"b\""
            body += "<v>\(value ? 1 : 0)</v>"
        case let .error(value):
            typeAttribute = " t=\"e\""
            body += "<v>\(value.xlsxToken)</v>"
        case let .text(value):
            guard value.count <= Limits.maxCellTextLength else {
                throw SheetError.cellTextTooLong(
                    ref: ref.a1String, length: value.count, limit: Limits.maxCellTextLength
                )
            }
            let safe = try XLSXEscape.sanitiseCellText(value, policy: options.controlCharacters, ref: ref.a1String)
            if formula != nil {
                // A formula whose cached result is text. `t="str"` puts the text in `<v>`
                // directly; it never goes through the shared string table.
                typeAttribute = " t=\"str\""
                body += "<v>\(XLSXEscape.text(safe))</v>"
            } else if !cell.flags.contains(.inlineString), let index = strings.index(for: value) {
                typeAttribute = " t=\"s\""
                body += "<v>\(index)</v>"
            } else {
                typeAttribute = " t=\"inlineStr\""
                body += "<is><t xml:space=\"preserve\">\(XLSXEscape.text(safe))</t></is>"
            }
        }

        guard !body.isEmpty else { return "<c\(attributes)\(typeAttribute)/>" }
        return "<c\(attributes)\(typeAttribute)>\(body)</c>"
    }

    // MARK: - mergeCells, hyperlinks

    private static func mergeCells(of sheet: Sheet) -> String? {
        guard !sheet.merges.isEmpty else { return nil }
        var output = "<mergeCells count=\"\(sheet.merges.count)\">"
        for merge in sheet.merges {
            output += "<mergeCell ref=\"\(merge.a1String(collapseSingleCell: false))\"/>"
        }
        return output + "</mergeCells>"
    }

    private static func hyperlinks(of sheet: Sheet) -> String? {
        guard !sheet.hyperlinks.isEmpty else { return nil }
        var entries: [String] = []
        for (ref, link) in sheet.hyperlinks.sorted(by: { $0.key < $1.key }) {
            var attributes = " ref=\"\(ref.a1String)\""
            if let identifier = link.relationshipID {
                attributes += " r:id=\"\(XLSXEscape.attribute(identifier))\""
            } else if link.isExternal {
                // An external link with no relationship needs a new entry in the sheet's rels
                // part, which v0.1 does not create. Emitting `<hyperlink>` without a target
                // would produce a link that goes nowhere, so it is left out rather than broken.
                continue
            }
            if let location = link.location {
                attributes += " location=\"\(XLSXEscape.attribute(location))\""
            } else if !link.isExternal {
                attributes += " location=\"\(XLSXEscape.attribute(link.target))\""
            }
            if let tooltip = link.tooltip {
                attributes += " tooltip=\"\(XLSXEscape.attribute(tooltip))\""
            }
            entries.append("<hyperlink\(attributes)/>")
        }
        guard !entries.isEmpty else { return nil }
        return "<hyperlinks>" + entries.joined() + "</hyperlinks>"
    }
}
