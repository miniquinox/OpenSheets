//
//  CSVWriterTests.swift
//  SheetFormatTests
//
//  RFC 4180 out, the source dialect preserved, and the injection guard on by default.
//

import Foundation
@testable import SheetFormat
import SheetModel
import Testing

@Suite("CSV writer")
struct CSVWriterTests {
    @Test("every dialect fixture round-trips to the same rows", arguments: CSVReaderTests.fixtures)
    func roundTrip(_ name: String) throws {
        let source = FixtureRoot.url("csv/\(name)")
        let workbook = try CSVReader.workbook(contentsOf: source)
        let sheet = workbook.sheets[0]

        // The injection guard deliberately changes values, so it is off for the round-trip
        // comparison; `injectionGuardIsOnByDefault` covers it separately.
        var options = CSVWriteOptions()
        options.guardAgainstFormulaInjection = false

        let written = try CSVWriter.data(for: sheet, options: options, sourceDialect: workbook.meta.csvDialect)
        var rewritten: [[String]] = []
        _ = CSVReader.forEachRow(in: written) { fields, _ in
            rewritten.append(fields)
            return true
        }

        var original: [[String]] = []
        _ = try CSVReader.forEachRow(contentsOf: source) { fields, _ in
            original.append(fields)
            return true
        }

        // Trailing empty fields are trimmed on write, so compare row-wise with padding.
        #expect(rewritten.count == original.count, "row count changed for \(name)")
        for (index, expected) in original.enumerated() where index < rewritten.count {
            let actual = rewritten[index] + Array(repeating: "", count: max(0, expected.count - rewritten[index].count))
            #expect(Array(actual.prefix(expected.count)) == expected, "row \(index) of \(name)")
        }
    }

    @Test("the source dialect is preserved by default", arguments: [
        ("semicolon-crlf.csv", ";", "\r\n"),
        ("tab.tsv", "\t", "\n"),
        ("pipe.csv", "|", "\n"),
        ("cr-only.csv", ",", "\r"),
    ])
    func dialectIsPreserved(_ name: String, _ delimiter: String, _ lineEnding: String) throws {
        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/\(name)"))
        let text = CSVWriter.text(
            for: workbook.sheets[0], options: CSVWriteOptions(), sourceDialect: workbook.meta.csvDialect
        )
        #expect(text.unicodeScalars.contains(delimiter.unicodeScalars.first!))
        #expect(text.hasSuffix(lineEnding) || text.hasSuffix(String(lineEnding.reversed())))
    }

    @Test("normalising overrides the source dialect")
    func normalising() throws {
        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/semicolon-crlf.csv"))
        var options = CSVWriteOptions()
        options.normalise = true
        let text = CSVWriter.text(
            for: workbook.sheets[0], options: options, sourceDialect: workbook.meta.csvDialect
        )
        #expect(text.contains("id,name,amount"))
        #expect(!text.unicodeScalars.contains("\r"))
        // A decimal comma has to be quoted once the delimiter is a comma.
        #expect(text.contains("\"10,5\""))
    }

    @Test("a BOM is preserved, and dropped when normalising")
    func byteOrderMarkHandling() throws {
        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/bom-utf8.csv"))
        let preserved = try CSVWriter.data(
            for: workbook.sheets[0], options: CSVWriteOptions(), sourceDialect: workbook.meta.csvDialect
        )
        #expect([UInt8](preserved.prefix(3)) == [0xEF, 0xBB, 0xBF])

        var options = CSVWriteOptions()
        options.normalise = true
        let normalised = try CSVWriter.data(
            for: workbook.sheets[0], options: options, sourceDialect: workbook.meta.csvDialect
        )
        #expect([UInt8](normalised.prefix(3)) != [0xEF, 0xBB, 0xBF])
    }

    @Test("UTF-16 and Windows-1252 sources are written back in their own encoding")
    func encodingIsPreserved() throws {
        for name in ["utf16le.csv", "utf16be.csv", "windows-1252.csv"] {
            let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/\(name)"))
            let written = try CSVWriter.data(
                for: workbook.sheets[0], options: CSVWriteOptions(), sourceDialect: workbook.meta.csvDialect
            )
            var rows: [[String]] = []
            _ = CSVReader.forEachRow(in: written) { fields, _ in
                rows.append(fields)
                return true
            }
            var expected: [[String]] = []
            _ = try CSVReader.forEachRow(contentsOf: FixtureRoot.url("csv/\(name)")) { fields, _ in
                expected.append(fields)
                return true
            }
            #expect(rows == expected, "\(name) did not survive its own encoding")
        }
    }

    @Test("a character the target encoding cannot represent is refused, not mangled")
    func unrepresentableCharactersAreRefused() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.text("日本語"), at: .origin)
        var options = CSVWriteOptions()
        options.encoding = .windows1252
        #expect(throws: SheetError.unsupportedTextEncoding(name: "windows-1252")) {
            try CSVWriter.data(for: sheet, options: options)
        }
    }

    // MARK: - RFC 4180

    @Test("fields are quoted exactly when they need to be", arguments: [
        ("plain", "plain"),
        ("has,comma", "\"has,comma\""),
        ("has\"quote", "\"has\"\"quote\""),
        ("has\nnewline", "\"has\nnewline\""),
        ("has\r\ncrlf", "\"has\r\ncrlf\""),
        (" leading", "\" leading\""),
        ("trailing ", "\"trailing \""),
        ("", ""),
    ])
    func quoting(_ input: String, _ expected: String) {
        #expect(CSVWriter.quoted(input, dialect: .standard) == expected)
    }

    // MARK: - Injection guard

    @Test("the injection guard is on by default and only touches text")
    func injectionGuardIsOnByDefault() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.text("=1+1"), at: CellRef(row: 0, column: 0))
        try sheet.cells.setCell(Cell.text("+1+1"), at: CellRef(row: 1, column: 0))
        try sheet.cells.setCell(Cell.text("-1+1"), at: CellRef(row: 2, column: 0))
        try sheet.cells.setCell(Cell.text("@SUM(A1)"), at: CellRef(row: 3, column: 0))
        try sheet.cells.setCell(Cell.text("\t=1+1"), at: CellRef(row: 4, column: 0))
        try sheet.cells.setCell(Cell.text("\r=1+1"), at: CellRef(row: 5, column: 0))
        // A negative *number* is not an injection vector, and quoting it would make it text.
        try sheet.cells.setCell(Cell.number(-3), at: CellRef(row: 6, column: 0))
        try sheet.cells.setCell(Cell.error(.notAvailable), at: CellRef(row: 7, column: 0))

        let text = CSVWriter.text(for: sheet)
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(rows[0] == "'=1+1")
        #expect(rows[1] == "'+1+1")
        #expect(rows[2] == "'-1+1")
        #expect(rows[3] == "'@SUM(A1)")
        #expect(rows[4] == "'\t=1+1")
        #expect(rows[6] == "-3", "a negative number was quoted into text")
        #expect(rows[7] == "#N/A")

        var off = CSVWriteOptions()
        off.guardAgainstFormulaInjection = false
        #expect(CSVWriter.text(for: sheet, options: off).hasPrefix("=1+1"))
    }

    @Test("a guarded value comes back as its original text")
    func guardIsReversible() throws {
        // The apostrophe is a *type* marker, not content: it goes on when the file is written
        // and comes off when it is read, so the values a user sees never change even though the
        // bytes on disk do. Compared as values rather than as raw fields for exactly that reason.
        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/formula-injection.csv"))
        let written = try CSVWriter.data(
            for: workbook.sheets[0], sourceDialect: workbook.meta.csvDialect
        )
        let reloaded = try CSVReader.workbook(from: written)

        #expect(reloaded.sheets[0].cells.count == workbook.sheets[0].cells.count)
        workbook.sheets[0].cells.forEachCell(in: .entireSheet) { ref, cell in
            #expect(reloaded.sheets[0].cells[ref]?.value == cell.value, "\(ref.a1String) changed")
        }
        #expect(reloaded.sheets[0].cells[CellRef(a1: "B6")!]?.value == .text("=cmd|' /C calc'!A0"))
    }

    // MARK: - Cell rendering

    @Test("a formula cell exports its cached value, because a CSV cannot hold a formula")
    func formulasExportTheirValue() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.formula("SUM(A1:A9)", cached: .number(42)), at: .origin)
        #expect(CSVWriter.text(for: sheet).hasPrefix("42"))
    }

    @Test("gaps in a row become empty fields, not missing ones")
    func gapsArePreserved() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.text("a"), at: CellRef(row: 0, column: 0))
        try sheet.cells.setCell(Cell.text("c"), at: CellRef(row: 0, column: 2))
        try sheet.cells.setCell(Cell.text("y"), at: CellRef(row: 1, column: 1))
        let text = CSVWriter.text(for: sheet)
        #expect(text == "a,,c\n,y\n")
    }

    @Test("a sheet with one cell at the far corner does not produce a gigantic file")
    func aSparseSheetDoesNotExplode() throws {
        var sheet = Sheet(id: SheetID(1), name: "S")
        try sheet.cells.setCell(Cell.number(1), at: CellRef(row: 0, column: 0))
        try sheet.cells.setCell(Cell.number(2), at: CellRef(row: 50_000, column: Limits.maxColumn))
        let text = CSVWriter.text(for: sheet)
        // 50,001 line breaks plus two values, not 50,001 × 16,384 delimiters.
        #expect(text.utf8.count < 1_000_000, "the export padded every empty cell")
        #expect(text.hasPrefix("1\n"))
    }

    @Test("a workbook that opened read-only refuses to be written")
    func readOnlyWorkbooksAreRefused() throws {
        var workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/comma-lf.csv"))
        workbook.meta.readOnlyReason = .userRequested
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opensheets-a2-\(UUID().uuidString).csv")
        #expect(throws: SheetError.writeRefused(reason: .userRequested)) {
            try CSVWriter.save(workbook, to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}
