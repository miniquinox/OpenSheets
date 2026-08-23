//
//  CSVReaderTests.swift
//  SheetFormatTests
//
//  Every dialect in `Fixtures/csv/`, asserted against A7's sidecars.
//

import Foundation
@testable import SheetFormat
import SheetModel
import Testing

/// The `csv/` sidecar.
struct CSVSidecar: Decodable {
    struct Dialect: Decodable {
        var delimiter: String
        var quote: String
        var lineEnding: String
        var encoding: String
        var bom: Bool
    }

    var file: String
    var dialect: Dialect
    var rowCount: Int
    var maxColumns: Int
    var ragged: Bool
    var rows: [[String]]
    var raggedRowCount: Int?
    var mustSurfaceEncodingGuess: Bool?

    static func load(_ name: String) throws -> CSVSidecar {
        try JSONDecoder().decode(CSVSidecar.self, from: try FixtureRoot.data("csv/\(name).expected.json"))
    }
}

@Suite("CSV reader")
struct CSVReaderTests {
    static let fixtures = [
        "bom-utf8.csv", "comma-lf.csv", "cr-only.csv", "doubled-quotes.csv", "empty.csv",
        "formula-injection.csv", "header-only.csv", "no-trailing-newline.csv", "pipe.csv",
        "quoted-newlines.csv", "ragged-rows.csv", "semicolon-crlf.csv", "tab.tsv",
        "utf16be.csv", "utf16le.csv", "windows-1252.csv",
    ]

    @Test("every fixture parses to exactly the rows the sidecar records", arguments: fixtures)
    func rowsMatchTheSidecar(_ name: String) throws {
        let sidecar = try CSVSidecar.load(name)
        var rows: [[String]] = []
        let report = try CSVReader.forEachRow(contentsOf: FixtureRoot.url("csv/\(name)")) { fields, _ in
            rows.append(fields)
            return true
        }

        #expect(rows == sidecar.rows, "rows differ for \(name)")
        #expect(report.rowCount == sidecar.rowCount)
        #expect(report.columnCount == sidecar.maxColumns || sidecar.rows.isEmpty)
        #expect((report.raggedRowCount > 0) == sidecar.ragged)
        if let expected = sidecar.raggedRowCount {
            #expect(report.raggedRowCount == expected)
        }
    }

    @Test("the sniffed dialect matches the sidecar", arguments: fixtures)
    func dialectMatchesTheSidecar(_ name: String) throws {
        let sidecar = try CSVSidecar.load(name)
        let dialect = try CSVReader.detectDialect(contentsOf: FixtureRoot.url("csv/\(name)"))

        // A file with a single column has no delimiter to find; anything else must be exact.
        if sidecar.maxColumns > 1 {
            #expect(String(dialect.delimiter) == sidecar.dialect.delimiter, "delimiter for \(name)")
        }
        #expect(String(dialect.quote) == sidecar.dialect.quote)
        #expect(dialect.encodingName == sidecar.dialect.encoding, "encoding for \(name)")
        #expect(dialect.hasByteOrderMark == sidecar.dialect.bom)
        if sidecar.rowCount > 1 {
            #expect(dialect.lineEnding.characters == sidecar.dialect.lineEnding, "line ending for \(name)")
        }
        if sidecar.mustSurfaceEncodingGuess == true {
            #expect(dialect.encodingWasGuessed, "\(name) fell back to \(dialect.encodingName) without saying so")
        }
    }

    @Test("a decimal comma does not split a semicolon-separated row")
    func europeanDialectIsNotMisread() throws {
        let rows = try readRows("semicolon-crlf.csv")
        #expect(rows[1] == ["1", "Ada", "10,5"])
    }

    @Test("line endings inside quotes are preserved rather than normalised")
    func quotedLineEndingsSurvive() throws {
        let rows = try readRows("quoted-newlines.csv")
        #expect(rows[1][1] == "line one\nline two")
        #expect(rows[2][1] == "has,comma and\r\nCRLF inside")
    }

    @Test("Windows-1252 falls back and says it guessed")
    func windows1252IsSurfaced() throws {
        let dialect = try CSVReader.detectDialect(contentsOf: FixtureRoot.url("csv/windows-1252.csv"))
        #expect(dialect.encodingName == "windows-1252")
        #expect(dialect.encodingWasGuessed)

        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/windows-1252.csv"))
        #expect(workbook.meta.csvDialect?.encodingWasGuessed == true)
        #expect(workbook.sheets[0].cells[CellRef(a1: "C2")!]?.value == .text("naïve café"))
        #expect(workbook.sheets[0].cells[CellRef(a1: "B3")!]?.value == .text("Smart “quotes” and – dash"))
        #expect(workbook.sheets[0].cells[CellRef(a1: "C3")!]?.value == .text("€99"))
    }

    @Test("a byte-order mark is consumed, not delivered as text")
    func byteOrderMarksAreConsumed() throws {
        for name in ["bom-utf8.csv", "utf16le.csv", "utf16be.csv"] {
            let rows = try readRows(name)
            let first = try #require(rows.first?.first)
            #expect(!first.unicodeScalars.contains("\u{FEFF}"), "\(name) leaked its BOM")
        }
    }

    @Test("an empty file opens as an empty sheet rather than failing")
    func emptyFilesOpen() throws {
        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/empty.csv"))
        #expect(workbook.sheets.count == 1)
        #expect(workbook.sheets[0].cells.isEmpty)
        #expect(workbook.sheets[0].usedRange == nil)
    }

    @Test("ragged rows are padded, counted, and never rejected")
    func raggedRowsArePadded() throws {
        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/ragged-rows.csv"))
        #expect(workbook.meta.raggedRowCount == 3)
        #expect(workbook.sheets[0].usedRange?.a1String == "A1:E5")
        #expect(workbook.sheets[0].cells[CellRef(a1: "C4")!] == nil)
        #expect(workbook.sheets[0].cells[CellRef(a1: "E5")!]?.value == .number(11))
    }

    // MARK: - Typing

    @Test("fields are typed the way Excel types them", arguments: [
        ("42", CellValue.number(42)),
        ("-3", .number(-3)),
        ("10.5", .number(10.5)),
        ("1e3", .number(1000)),
        ("TRUE", .boolean(true)),
        ("false", .boolean(false)),
        ("#N/A", .error(.notAvailable)),
        ("#DIV/0!", .error(.divideByZero)),
        ("#REF!", .error(.invalidReference)),
        ("'#N/A", .text("#N/A")),
        ("'42", .text("42")),
        ("=SUM(A1:A2)", .text("=SUM(A1:A2)")),
        ("=cmd|' /C calc'!A0", .text("=cmd|' /C calc'!A0")),
        ("0012", .text("0012")),
        ("007", .text("007")),
        ("0", .number(0)),
        ("0.5", .number(0.5)),
        ("nan", .text("nan")),
        ("inf", .text("inf")),
        ("1,234", .text("1,234")),
        ("", .empty),
        ("#CIRCULAR", .text("#CIRCULAR")),
    ])
    func typing(_ field: String, _ expected: CellValue) {
        #expect(CSVValueParser.value(for: field).0 == expected, "typing '\(field)'")
    }

    @Test("a CSV formula stays inert text, never a formula")
    func formulasStayInert() throws {
        let workbook = try CSVReader.workbook(contentsOf: FixtureRoot.url("csv/formula-injection.csv"))
        let sheet = workbook.sheets[0]
        sheet.cells.forEachCell(in: .entireSheet) { ref, cell in
            #expect(cell.formula == nil, "\(ref.a1String) became a formula")
        }
        #expect(sheet.cells[CellRef(a1: "B2")!]?.value == .text("=1+1"))
        #expect(sheet.cells[CellRef(a1: "B6")!]?.value == .text("=cmd|' /C calc'!A0"))
    }

    // MARK: - Streaming

    @Test("a big file is read in constant memory")
    func readingIsStreaming() throws {
        // Measures *the second pass*, not the first. A single measurement cannot tell a reader
        // that streams from one that slurps and then hands the memory back to the allocator, and
        // it flakes on warm-up. Reading the same file twice and finding the resident set flat is
        // the property that actually matters, and it is what caught the real bug here: the
        // bridged `NSData` from each `FileHandle.read` was accumulating in the autorelease pool,
        // so a "streaming" reader still held the whole file by the end of it.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opensheets-a2-stream-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(FileManager.default.createFile(atPath: scratch.path, contents: nil))
        let file = try FileHandle(forWritingTo: scratch)
        let block = Data(
            (0 ..< 2000).map { "row\($0),\"quoted, with comma\",\($0).5,ünïcødé\n" }.joined().utf8
        )
        for _ in 0 ..< 200 { try file.write(contentsOf: block) }
        try file.close()
        let fileSize = try #require(FileManager.default.attributesOfItem(atPath: scratch.path)[.size] as? Int)
        #expect(fileSize > 15 * 1024 * 1024)

        var rows = 0
        var lastValue = ""
        func read() throws {
            rows = 0
            let report = try CSVReader.forEachRow(contentsOf: scratch) { fields, _ in
                rows += 1
                lastValue = fields[3]
                return true
            }
            #expect(report.columnCount == 4)
        }

        // The **minimum** growth over several passes, not one measurement. The test suite runs
        // in parallel with everything else in the package, so any single sample includes other
        // suites' allocations; noise can only push a sample up, so the minimum converges on the
        // truth. A reader that holds the file grows by roughly its size on *every* pass and the
        // minimum stays high.
        var growths: [Int] = []
        for _ in 0 ..< 3 {
            let before = residentBytes()
            try read()
            growths.append(residentBytes() - before)
        }
        let quietest = growths.min() ?? 0

        #expect(rows == 400_000)
        #expect(lastValue == "ünïcødé")
        let samples = growths.map { $0 / 1024 / 1024 }
        #expect(
            quietest < fileSize / 4,
            "a \(fileSize / 1024 / 1024) MB file left \(quietest / 1024 / 1024) MB resident (MB per pass: \(samples))"
        )
    }

    @Test("stopping at the first row does not read the whole file")
    func earlyExitDoesNotReadEverything() throws {
        // A ratio rather than a wall-clock budget, so it means the same thing on an idle machine
        // and on one with six agents building. A reader that slurps the file before delivering
        // the first row takes just as long to stop at row 1 as it does to read all 400,000.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opensheets-a2-early-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(FileManager.default.createFile(atPath: scratch.path, contents: nil))
        let file = try FileHandle(forWritingTo: scratch)
        let block = Data((0 ..< 2000).map { "row\($0),value\($0),\($0).5\n" }.joined().utf8)
        for _ in 0 ..< 100 { try file.write(contentsOf: block) }
        try file.close()

        let wholeFile = ContinuousClock().measure {
            _ = try? CSVReader.forEachRow(contentsOf: scratch) { _, _ in true }
        }
        let firstRowOnly = ContinuousClock().measure {
            _ = try? CSVReader.forEachRow(contentsOf: scratch) { _, index in index < 1 }
        }
        #expect(firstRowOnly < wholeFile / 3, "stopping early took \(firstRowOnly) against \(wholeFile) for the lot")
    }

    @Test("a single enormous field does not go quadratic")
    func oneVeryLongField() throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opensheets-a2-long-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let payload = "a," + String(repeating: "x", count: 5_000_000) + "\n"
        try Data(payload.utf8).write(to: scratch)

        let started = ContinuousClock.now
        var width = 0
        var length = 0
        _ = try CSVReader.forEachRow(contentsOf: scratch) { fields, _ in
            width = fields.count
            length = fields[1].count
            return true
        }
        #expect(width == 2)
        #expect(length == 5_000_000)
        #expect(started.duration(to: .now) < .seconds(20))
    }

    @Test("the row callback can stop the read early")
    func earlyExit() throws {
        var seen = 0
        let report = try CSVReader.forEachRow(contentsOf: FixtureRoot.url("csv/comma-lf.csv")) { _, _ in
            seen += 1
            return seen < 2
        }
        #expect(seen == 2)
        #expect(report.rowCount == 2)
    }

    // MARK: - Helpers

    private func readRows(_ name: String) throws -> [[String]] {
        var rows: [[String]] = []
        _ = try CSVReader.forEachRow(contentsOf: FixtureRoot.url("csv/\(name)")) { fields, _ in
            rows.append(fields)
            return true
        }
        return rows
    }

    private func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }
}
