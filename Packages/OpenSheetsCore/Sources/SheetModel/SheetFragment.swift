//
//  SheetFragment.swift
//  SheetModel
//
//  Verbatim XML from a worksheet part that we deliberately do not model.
//

import Foundation

/// A raw XML element lifted out of a worksheet part and kept byte-for-byte.
///
/// PLAN.md §5.2 promises that anything we did not model survives a save untouched, and the
/// mechanism described there — copy the ZIP entry through verbatim — is not sufficient on its
/// own. `<conditionalFormatting>`, `<dataValidations>`, `<autoFilter>`, `<sheetProtection>`,
/// `<pageSetup>`, `<pageMargins>`, `<printOptions>`, `<headerFooter>`, `<tableParts>`,
/// `<drawing>`, `<legacyDrawing>` and `<extLst>` all live *inside* `xl/worksheets/sheetN.xml`,
/// which is precisely the part the writer re-emits. Passthrough cannot save them.
///
/// The consequence is worse than losing formatting: dropping the one-line `<drawing r:id="rId1"/>`
/// orphans a chart whose own `chart1.xml` survived perfectly, and Excel then reports the file as
/// damaged. So the reader captures each unmodelled element verbatim, and the writer splices it
/// back at the right place.
///
/// "The right place" is not negotiable. `CT_Worksheet` is a sequence, not a choice: emit these
/// out of order and Excel silently "repairs" the workbook by discarding them. ``schemaOrder``
/// carries the ordinal so the reader and the writer cannot disagree about it.
public struct SheetFragment: Sendable, Hashable, Codable {
    /// The element's local name, without any namespace prefix — `conditionalFormatting`, not
    /// `x:conditionalFormatting`. Producers differ on prefixes; the name does not.
    public var elementName: String

    /// The element exactly as it appeared, including its own open and close tags.
    ///
    /// Stored as read, with the original prefixes and attribute order intact. Do not
    /// pretty-print it, re-escape it, or normalise its namespaces: a byte you "cleaned up" is a
    /// byte that no longer matches what the producer wrote.
    public var xml: String

    /// This element's position in `CT_Worksheet`'s required child sequence.
    ///
    /// Derived from ``schemaOrder(for:)``. Sorting fragments by this value and merging them with
    /// the elements we *do* model reproduces a schema-valid worksheet.
    public var schemaOrder: Int

    public init(elementName: String, xml: String, schemaOrder: Int? = nil) {
        self.elementName = elementName
        self.xml = xml
        self.schemaOrder = schemaOrder ?? Self.schemaOrder(for: elementName)
    }

    // MARK: - Schema order

    /// `CT_Worksheet`'s child elements in the order ECMA-376 requires them.
    ///
    /// The elements we model ourselves are included, so a writer can interleave modelled output
    /// and passthrough fragments against one shared ordering rather than two that drift apart.
    public static let worksheetChildOrder: [String] = [
        "sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData",
        "sheetCalcPr", "sheetProtection", "protectedRanges", "scenarios", "autoFilter",
        "sortState", "dataConsolidate", "customSheetViews", "mergeCells", "phoneticPr",
        "conditionalFormatting", "dataValidations", "hyperlinks", "printOptions",
        "pageMargins", "pageSetup", "headerFooter", "rowBreaks", "colBreaks",
        "customProperties", "cellWatches", "ignoredErrors", "smartTags", "drawing",
        "legacyDrawing", "legacyDrawingHF", "drawingHF", "picture", "oleObjects", "controls",
        "webPublishItems", "tableParts", "extLst",
    ]

    /// Where `elementName` belongs in ``worksheetChildOrder``.
    ///
    /// An element the schema does not list sorts last, just before `extLst`, which is where a
    /// producer extension is least likely to break anything. Unknown is not an error: OOXML is
    /// extended in the wild and refusing to round-trip something we merely failed to recognise
    /// would defeat the whole point of keeping it.
    public static func schemaOrder(for elementName: String) -> Int {
        let name = elementName.contains(":")
            ? String(elementName[elementName.lastIndex(of: ":")!...].dropFirst())
            : elementName
        return worksheetChildOrder.firstIndex(of: name) ?? (worksheetChildOrder.count - 1)
    }

    /// Element names the reader must capture rather than discard.
    ///
    /// This is the working list for v0.1 — everything in `CT_Worksheet` that carries user intent
    /// and that we do not otherwise model. `sheetData`, `cols`, `mergeCells`, `dimension`,
    /// `sheetViews` and `hyperlinks` are absent on purpose: those we do model, and capturing them
    /// too would emit each of them twice.
    public static let capturedElements: Set<String> = [
        "sheetPr", "sheetCalcPr", "sheetProtection", "protectedRanges", "scenarios",
        "sortState", "dataConsolidate", "customSheetViews", "phoneticPr",
        "conditionalFormatting", "dataValidations", "printOptions", "pageMargins",
        "pageSetup", "headerFooter", "rowBreaks", "colBreaks", "customProperties",
        "cellWatches", "ignoredErrors", "smartTags", "drawing", "legacyDrawing",
        "legacyDrawingHF", "drawingHF", "picture", "oleObjects", "controls",
        "webPublishItems", "tableParts", "extLst",
    ]
}

extension [SheetFragment] {
    /// The fragments in the order `CT_Worksheet` requires, ready to splice into a written sheet.
    ///
    /// Stable within an ordinal, so two fragments that share a slot — several
    /// `<conditionalFormatting>` blocks, which is legal and common — keep the order they were
    /// read in.
    public var inSchemaOrder: [SheetFragment] {
        enumerated()
            .sorted { ($0.element.schemaOrder, $0.offset) < ($1.element.schemaOrder, $1.offset) }
            .map(\.element)
    }

    /// The single fragment for `elementName`, when there is one.
    public func first(named elementName: String) -> SheetFragment? {
        first { $0.elementName == elementName }
    }
}
