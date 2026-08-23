//
//  WrittenFileDumpTests.swift
//  SheetFormatTests
//
//  Writes the corpus out so an *independent* implementation can judge the result.
//

import Foundation
@testable import SheetFormat
import SheetModel
import Testing

/// Writes every `passthrough/` fixture back out, edited, into `$OPENSHEETS_WRITE_DUMP`.
///
/// # Why this is not an assertion
///
/// Every other test in this suite checks the writer against the writer's own idea of what a ZIP
/// and an OOXML part are. That is circular: a consistent misunderstanding of the format passes
/// all of them. This one produces files for `Scripts`-level verification by tools that share no
/// code with us — Python's `zipfile`, which recomputes every CRC, and LibreOffice, which either
/// opens the workbook or does not.
///
/// Disabled unless the environment variable is set, so a normal `swift test` does not scatter
/// files around.
@Suite("Written file dump")
struct WrittenFileDumpTests {
    static var destination: URL? {
        ProcessInfo.processInfo.environment["OPENSHEETS_WRITE_DUMP"].map { URL(fileURLWithPath: $0) }
    }

    @Test(
        "write every corpus fixture out for external verification",
        .enabled(if: destination != nil),
        arguments: CorpusRoundTripTests.fixtures
    )
    func dump(_ fixture: String) throws {
        let destination = try #require(Self.destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let loaded = try FixtureWorkbookLoader.load(fixture)
        var workbook = loaded.workbook
        let sheet = try #require(workbook.sheets.first)

        try workbook.withSheet(sheet.id) { sheet in
            try sheet.cells.setCell(Cell.text("edited by OpenSheets"), at: CellRef(row: 0, column: 0))
            try sheet.cells.setCell(Cell.number(424_242), at: CellRef(row: 1, column: 1))
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[sheet.id]), formulasChanged: true)

        let name = fixture.replacingOccurrences(of: "/", with: "-")
        try XLSXWriter.save(workbook, edits: edits, to: destination.appendingPathComponent(name))
    }

    @Test("write a package built from scratch", .enabled(if: destination != nil))
    func dumpNewPackage() throws {
        let destination = try #require(Self.destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        var workbook = Workbook.blank(sheetName: "Made Here")
        try workbook.withSheet(SheetID(1)) { sheet in
            try sheet.cells.setCell(Cell.text("Region"), at: CellRef(row: 0, column: 0))
            try sheet.cells.setCell(Cell.text("Revenue"), at: CellRef(row: 0, column: 1))
            try sheet.cells.setCell(Cell.text("North"), at: CellRef(row: 1, column: 0))
            try sheet.cells.setCell(Cell.number(1234.5), at: CellRef(row: 1, column: 1))
            try sheet.cells.setCell(Cell.text("South"), at: CellRef(row: 2, column: 0))
            try sheet.cells.setCell(Cell.number(-98), at: CellRef(row: 2, column: 1))
            try sheet.cells.setCell(
                Cell.formula("SUM(B2:B3)", cached: .number(1136.5)), at: CellRef(row: 3, column: 1)
            )
            try sheet.cells.setCell(
                Cell.formula("XLOOKUP(A2,A2:A3,B2:B3)", cached: .number(1234.5)), at: CellRef(row: 4, column: 1)
            )
            try sheet.cells.setCell(Cell.boolean(true), at: CellRef(row: 5, column: 0))
            try sheet.cells.setCell(Cell.error(.notAvailable), at: CellRef(row: 5, column: 1))
            sheet.merges = [CellRange(a1: "A8:C8")!]
        }

        try XLSXWriter.save(
            workbook,
            edits: WorkbookEditTracker(),
            to: destination.appendingPathComponent("built-from-scratch.xlsx")
        )
    }

    @Test("write a CSV round trip", .enabled(if: destination != nil))
    func dumpCSVToXLSX() throws {
        let destination = try #require(Self.destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/formula-injection.csv"))
        try XLSXWriter.save(
            workbook,
            edits: WorkbookEditTracker(),
            to: destination.appendingPathComponent("csv-as-xlsx.xlsx")
        )
        try CSVWriter.save(workbook, to: destination.appendingPathComponent("csv-round-trip.csv"))
    }
}
