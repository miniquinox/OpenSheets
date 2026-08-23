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
