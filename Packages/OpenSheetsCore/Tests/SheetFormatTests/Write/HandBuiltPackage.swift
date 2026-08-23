//
//  HandBuiltPackage.swift
//  SheetFormatTests
//
//  A small xlsx assembled byte by byte, for the cases the corpus does not cover.
//

import Foundation
import MiniZip
@testable import SheetFormat
import SheetModel

/// Builds a three-sheet workbook with a `calcChain.xml`, a shared string table holding rich
/// text, and a formula using a `_xlfn.`-prefixed function.
///
/// No fixture in `Fixtures/` has a `calcChain.xml` — A7's generators do not produce one — so the
/// rule that matters most for formula edits ("drop it, and say `fullCalcOnLoad`") has nothing in
/// the corpus to test against. This provides it.
enum HandBuiltPackage {
    static let sheet1Path = "xl/worksheets/sheet1.xml"
    static let sheet2Path = "xl/worksheets/sheet2.xml"
    static let sheet3Path = "xl/worksheets/sheet3.xml"

    static func archiveData() throws -> Data {
        var entries: [ZipEntry] = []
        func add(_ path: String, _ xml: String) {
            entries.append(ZipWriter.entry(path: path, contents: Data(xml.utf8)))
        }

        add(OOXMLPart.contentTypes, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/worksheets/sheet2.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/worksheets/sheet3.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        <Override PartName="/xl/sharedStrings.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\
        <Override PartName="/xl/styles.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        <Override PartName="/xl/calcChain.xml" \
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.calcChain+xml"/>\
        </Types>
        """)

        add(OOXMLPart.rootRelationships, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
        Target="xl/workbook.xml"/></Relationships>
        """)

        add(OOXMLPart.workbook, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\
        <sheet name="One" sheetId="1" r:id="rId1"/>\
        <sheet name="Two" sheetId="2" r:id="rId2"/>\
        <sheet name="Three" sheetId="3" state="hidden" r:id="rId3"/>\
        </sheets>\
        <calcPr calcId="171027"/>\
        </workbook>
        """)

        add(OOXMLPart.workbookRelationships, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet2.xml"/>\
        <Relationship Id="rId3" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" \
        Target="worksheets/sheet3.xml"/>\
        <Relationship Id="rId4" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" \
        Target="sharedStrings.xml"/>\
        <Relationship Id="rId5" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" \
        Target="styles.xml"/>\
        <Relationship Id="rId6" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/calcChain" \
        Target="calcChain.xml"/>\
        </Relationships>
        """)

        // Sheet 1 carries the elements that only survive if they are spliced back: note the
        // `legacyDrawing` between `drawing` and `tableParts`, which the frozen model's ordering
        // list does not know about.
        add(sheet1Path, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" mc:Ignorable="x14ac" \
        xmlns:x14ac="http://schemas.microsoft.com/office/spreadsheetml/2009/9/ac">\
        <sheetPr codeName="Sheet1"/>\
        <dimension ref="A1:C4"/>\
        <sheetViews><sheetView tabSelected="1" zoomScaleNormal="100" workbookViewId="0">\
        <selection activeCell="B2" sqref="B2"/></sheetView></sheetViews>\
        <sheetFormatPr defaultRowHeight="15" x14ac:dyDescent="0.25"/>\
        <cols><col min="1" max="1" width="18.7109375" bestFit="1" customWidth="1"/></cols>\
        <sheetData>\
        <row r="1" spans="1:3" ht="21" customHeight="1"><c r="A1" t="s"><v>0</v></c>\
        <c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c></row>\
        <row r="2" spans="1:3"><c r="A2"><v>1</v></c><c r="B2"><v>2</v></c>\
        <c r="C2"><f>_xlfn.XLOOKUP(A2,A2:A2,B2:B2)</f><v>2</v></c></row>\
        <row r="3" spans="1:3"><c r="A3" t="s"><v>3</v></c></row>\
        </sheetData>\
        <sheetProtection sheet="1" objects="1" scenarios="1"/>\
        <mergeCells count="1"><mergeCell ref="A4:C4"/></mergeCells>\
        <conditionalFormatting sqref="B2:B3"><cfRule type="cellIs" dxfId="0" priority="1" operator="greaterThan">\
        <formula>1</formula></cfRule></conditionalFormatting>\
        <dataValidations count="1"><dataValidation type="list" allowBlank="1" sqref="A2:A3">\
        <formula1>"a,b,c"</formula1></dataValidation></dataValidations>\
        <printOptions horizontalCentered="1"/>\
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>\
        <pageSetup orientation="landscape"/>\
        <headerFooter><oddHeader>&amp;CTop</oddHeader></headerFooter>\
        <drawing r:id="rId10"/>\
        <legacyDrawing r:id="rId11"/>\
        <tableParts count="1"><tablePart r:id="rId12"/></tableParts>\
        <extLst><ext uri="{X}" xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">\
        <x14:conditionalFormattings/></ext></extLst>\
        </worksheet>
        """)

        add(sheet2Path, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <dimension ref="A1"/><sheetData><row r="1"><c r="A1"><v>7</v></c></row></sheetData>\
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>\
        </worksheet>
        """)

        add(sheet3Path, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <dimension ref="A1"/><sheetData><row r="1"><c r="A1" t="s"><v>1</v></c></row></sheetData>\
        <pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>\
        </worksheet>
        """)

        // Index 2 is rich text: two runs, one bold. The model flattens it to `HelloWorld`, and
        // the only way it survives a rewrite is for the writer to find its way back to index 2.
        add(OOXMLPart.sharedStrings, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="4" uniqueCount="4">\
        <si><t>Region</t></si>\
        <si><t>Revenue</t></si>\
        <si><r><t>Hello</t></r><r><rPr><b/></rPr><t>World</t></r></si>\
        <si><t xml:space="preserve">  padded  </t></si>\
        </sst>
        """)

        add(OOXMLPart.styles, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill>\
        <fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        <dxfs count="1"><dxf><font><color rgb="FF9C0006"/></font></dxf></dxfs>\
        </styleSheet>
        """)

        add(OOXMLPart.calcChain, """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <calcChain xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <c r="C2" i="1"/></calcChain>
        """)

        return try ZipWriter.archive(entries)
    }

    static func load() throws -> FixtureWorkbookLoader.Loaded {
        try FixtureWorkbookLoader.load(data: try archiveData())
    }
}
