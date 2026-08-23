//
//  SheetFragmentTests.swift
//  SheetModelTests
//

import Foundation
import Testing

@testable import SheetModel

@Suite("SheetFragment")
struct SheetFragmentTests {
    @Test("Schema order follows CT_Worksheet's required sequence")
    func schemaOrderFollowsSchema() {
        // The pairs that actually bite: emitting these the wrong way round makes Excel
        // "repair" the workbook, which means silently discarding them.
        #expect(SheetFragment.schemaOrder(for: "sheetPr") < SheetFragment.schemaOrder(for: "sheetData"))
        #expect(SheetFragment.schemaOrder(for: "sheetData") < SheetFragment.schemaOrder(for: "mergeCells"))
        #expect(SheetFragment.schemaOrder(for: "mergeCells") < SheetFragment.schemaOrder(for: "conditionalFormatting"))
        #expect(SheetFragment.schemaOrder(for: "conditionalFormatting") < SheetFragment.schemaOrder(for: "dataValidations"))
        #expect(SheetFragment.schemaOrder(for: "dataValidations") < SheetFragment.schemaOrder(for: "hyperlinks"))
        #expect(SheetFragment.schemaOrder(for: "hyperlinks") < SheetFragment.schemaOrder(for: "pageSetup"))
        #expect(SheetFragment.schemaOrder(for: "pageSetup") < SheetFragment.schemaOrder(for: "drawing"))
        // legacyDrawing sits between drawing and drawingHF. It is the sheet's pointer to the VML
        // that positions its comments, so mis-sorting it orphans every comment in the workbook.
        #expect(SheetFragment.schemaOrder(for: "drawing") < SheetFragment.schemaOrder(for: "legacyDrawing"))
        #expect(SheetFragment.schemaOrder(for: "legacyDrawing") < SheetFragment.schemaOrder(for: "legacyDrawingHF"))
        #expect(SheetFragment.schemaOrder(for: "legacyDrawingHF") < SheetFragment.schemaOrder(for: "drawingHF"))
        #expect(SheetFragment.schemaOrder(for: "drawingHF") < SheetFragment.schemaOrder(for: "tableParts"))
        #expect(SheetFragment.schemaOrder(for: "tableParts") < SheetFragment.schemaOrder(for: "extLst"))
    }

    @Test("Namespace prefixes are ignored, because producers disagree about them")
    func prefixesIgnored() {
        #expect(SheetFragment.schemaOrder(for: "x:drawing") == SheetFragment.schemaOrder(for: "drawing"))
        #expect(SheetFragment.schemaOrder(for: "mc:extLst") == SheetFragment.schemaOrder(for: "extLst"))
    }

    @Test("An unrecognised element round-trips rather than being rejected")
    func unknownElementSortsLast() {
        let unknown = SheetFragment(elementName: "someVendorExtension", xml: "<someVendorExtension/>")
        #expect(unknown.schemaOrder == SheetFragment.worksheetChildOrder.count - 1)
    }

    @Test("Sorting is stable, so repeated conditionalFormatting blocks keep their order")
    func stableWithinAnOrdinal() {
        let fragments = [
            SheetFragment(elementName: "drawing", xml: #"<drawing r:id="rId1"/>"#),
            SheetFragment(elementName: "conditionalFormatting", xml: "<conditionalFormatting sqref=\"A1\"/>"),
            SheetFragment(elementName: "pageMargins", xml: "<pageMargins left=\"0.7\"/>"),
            SheetFragment(elementName: "conditionalFormatting", xml: "<conditionalFormatting sqref=\"B1\"/>"),
        ]

        let ordered = fragments.inSchemaOrder
        #expect(ordered.map(\.elementName) == [
            "conditionalFormatting", "conditionalFormatting", "pageMargins", "drawing",
        ])
        // Stability: A1's block still precedes B1's.
        #expect(ordered[0].xml.contains("A1"))
        #expect(ordered[1].xml.contains("B1"))
    }

    @Test("Elements we model ourselves are not captured, or they'd be written twice")
    func modelledElementsAreNotCaptured() {
        for modelled in ["sheetData", "cols", "mergeCells", "dimension", "sheetViews", "hyperlinks"] {
            #expect(!SheetFragment.capturedElements.contains(modelled), "\(modelled) must not be captured")
        }
        for passthrough in [
            "conditionalFormatting", "dataValidations", "drawing", "legacyDrawing",
            "legacyDrawingHF", "tableParts", "pageSetup",
        ] {
            #expect(SheetFragment.capturedElements.contains(passthrough), "\(passthrough) must be captured")
        }
    }

    @Test("No captured element falls into the unknown-element slot")
    func everyCapturedElementIsOrdered() {
        // The bug this catches: an element in capturedElements but missing from
        // worksheetChildOrder sorts as "unknown", which violates CT_Worksheet's sequence and
        // makes Excel repair the file by discarding it. legacyDrawing was exactly this.
        let unknownSlot = SheetFragment.worksheetChildOrder.count - 1
        for element in SheetFragment.capturedElements where element != "extLst" {
            #expect(
                SheetFragment.schemaOrder(for: element) != unknownSlot,
                "\(element) is captured but missing from worksheetChildOrder"
            )
        }
    }

    @Test("Fragments survive a Sheet round-trip through Codable")
    func survivesSheetCodableRoundTrip() throws {
        var sheet = Sheet(id: SheetID(rawValue: 1), name: "Data")
        sheet.sheetLevelFragments = [
            SheetFragment(elementName: "drawing", xml: #"<drawing r:id="rId3"/>"#),
        ]

        let data = try JSONEncoder().encode(sheet)
        let decoded = try JSONDecoder().decode(Sheet.self, from: data)

        let fragment = try #require(decoded.sheetLevelFragments.first)
        #expect(decoded.sheetLevelFragments.count == 1)
        #expect(fragment.xml == #"<drawing r:id="rId3"/>"#)
    }
}

/// Regressions for the four defects Wave 1 found in the frozen model.
@Suite("Wave 1 model corrections")
struct ModelCorrectionTests {
    @Test("Absolute markers parse, because that is how defined names are written")
    func absoluteMarkersParse() throws {
        // The failure this replaces was silent: A1Notation.parse returned nil for every real
        // defined name, and DefinedName.target was simply left empty.
        let plain = try #require(CellRange(a1: "A1:A3"))
        #expect(CellRange(a1: "$A$1:$A$3") == plain)
        #expect(CellRange(a1: "$A1:A$3") == plain)
        #expect(CellRange(a1: "$A$1") == CellRange(a1: "A1"))

        let parsed = try #require(A1Notation.parse("Budget!$A$1:$A$3"))
        #expect(parsed.sheetName == "Budget")
        #expect(parsed.range == plain)

        let quoted = try #require(A1Notation.parse("'My Sheet'!$B$2"))
        #expect(quoted.sheetName == "My Sheet")
        #expect(quoted.range == CellRange(a1: "B2"))

        // A lone $ is still not a reference.
        #expect(CellRange(a1: "$") == nil)
    }

    @Test("Built-ins 39 and 40 have no space before the separator; 37 and 38 do")
    func builtInSpacingMatchesTheSpec() {
        // Looks like a typo in ECMA-376 §18.8.30. It is not.
        #expect(NumberFormat.builtInCode(id: 37) == "#,##0 ;(#,##0)")
        #expect(NumberFormat.builtInCode(id: 38) == "#,##0 ;[Red](#,##0)")
        #expect(NumberFormat.builtInCode(id: 39) == "#,##0.00;(#,##0.00)")
        #expect(NumberFormat.builtInCode(id: 40) == "#,##0.00;[Red](#,##0.00)")
    }

    @Test("Built-in formats are parsed once, not per call")
    func builtInsAreMemoised() {
        // Identity would be ideal, but NumberFormat is a value type. What is assertable is that
        // the table agrees with the parser for every reserved id, and that repeated reads are
        // cheap enough to sit in a draw loop.
        for id in Int32(0) ... 49 {
            #expect(
                NumberFormat.builtIn(id: id) == NumberFormat.builtInCode(id: id).map { NumberFormat($0) },
                "built-in \(id) disagrees with its parsed code"
            )
        }
        #expect(NumberFormat.builtIn(id: 164) == nil)
        #expect(NumberFormat.builtIn(id: -1) == nil)
    }

    @Test("A merge widens the formatted extent past the cells that hold values")
    func mergesWidenTheExtent() throws {
        var sheet = Sheet(id: SheetID(1), name: "Data")
        try sheet.cells.setCell(Cell.number(1), at: CellRef(row: 0, column: 0))
        #expect(sheet.formattedExtent == CellRange(a1: "A1"))

        sheet.merges = [try #require(CellRange(a1: "A1:F8"))]
        // Four values inside an A1:F8 merge is an eight-row sheet, not a one-row one.
        #expect(sheet.formattedExtent == CellRange(a1: "A1:F8"))
        // usedRange is unchanged — it counts cells, and that distinction is the point.
        #expect(sheet.usedRange == CellRange(a1: "A1"))
    }
}
