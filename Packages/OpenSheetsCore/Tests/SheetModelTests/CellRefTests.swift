@testable import SheetModel
import Testing

@Suite("CellRef — A1 conversion")
struct CellRefTests {
    // MARK: - The boundaries that matter

    @Test("A1 round-trips through the named boundary cases")
    func namedBoundaries() {
        let cases: [(a1: String, row: Int, column: Int)] = [
            ("A1", 0, 0),
            ("B7", 6, 1),
            ("Z1", 0, 25),
            ("AA1", 0, 26),
            ("AB1", 0, 27),
            ("AZ1", 0, 51),
            ("BA1", 0, 52),
            ("ZZ1", 0, 701),
            ("AAA1", 0, 702),
            ("XFD1", 0, 16_383),
            ("A1048576", 1_048_575, 0),
            ("XFD1048576", 1_048_575, 16_383),
        ]
        for (a1, row, column) in cases {
            let parsed = CellRef(a1: a1)
            #expect(parsed == CellRef(row: row, column: column), "parsing \(a1)")
            #expect(parsed?.a1String == a1, "formatting \(a1)")
        }
    }

    @Test("every column index round-trips through its letters")
    func exhaustiveColumnRoundTrip() {
        for column in 0 ... Limits.maxColumn {
            let letters = CellRef.columnLetters(column)
            #expect(CellRef.columnIndex(letters: letters) == column, "column \(column) → \(letters)")
        }
    }

    @Test("the Z → AA boundary does not skip or repeat")
    func bijectiveBaseTwentySix() {
        #expect(CellRef.columnLetters(25) == "Z")
        #expect(CellRef.columnLetters(26) == "AA")
        #expect(CellRef.columnLetters(51) == "AZ")
        #expect(CellRef.columnLetters(52) == "BA")
        #expect(CellRef.columnLetters(701) == "ZZ")
        #expect(CellRef.columnLetters(702) == "AAA")
    }

    // MARK: - Rejection

    @Test("out-of-range references are rejected, not clamped", arguments: [
        "XFE1", // one column past XFD
        "XFD1048577", // one row past the last
        "A1048577",
        "A0", // rows are 1-based in A1 notation
        "ZZZZ1", // four letters is past the grid
        "1A", // digits before letters
        "A", // no row
        "1", // no column
        "",
        "A1B", // letters after digits
        "$A$1", // formula notation, not a plain reference
        "A 1",
        "A-1",
        "Sheet1!A1", // sheet-qualified belongs to A1Notation
        "A1:B2",
    ])
    func rejectsInvalid(_ text: String) {
        #expect(CellRef(a1: text) == nil, "\(text) should not parse")
    }

    @Test("lowercase parses, because CSV and humans produce it")
    func caseInsensitive() {
        #expect(CellRef(a1: "b7") == CellRef(row: 6, column: 1))
        #expect(CellRef(a1: "xfd1048576") == CellRef(row: 1_048_575, column: 16_383))
    }

    @Test("a Substring parses without needing a String")
    func parsesSubstring() {
        let document = "<c r=\"BC42\" t=\"n\">"
        guard let open = document.firstIndex(of: "\""),
              let close = document.lastIndex(of: "\"")
        else {
            Issue.record("fixture is malformed")
            return
        }
        let slice = document[document.index(after: open) ..< close]
        #expect(CellRef(a1: slice.prefix(4)) == CellRef(row: 41, column: 54))
    }

    // MARK: - Validation

    @Test("isValid and validated agree about the grid")
    func validation() throws {
        #expect(CellRef(row: 0, column: 0).isValid)
        #expect(CellRef(row: Limits.maxRow, column: Limits.maxColumn).isValid)
        #expect(!CellRef(row: -1, column: 0).isValid)
        #expect(!CellRef(row: 0, column: Limits.columnCount).isValid)

        #expect(throws: SheetError.self) { try CellRef(row: -1, column: 0).validated() }
        #expect(try CellRef(row: 5, column: 5).validated() == CellRef(row: 5, column: 5))
    }

    @Test("clamping pulls a reference back onto the sheet")
    func clamping() {
        #expect(CellRef(row: -5, column: -5).clamped == .origin)
        #expect(CellRef(row: 9_999_999, column: 99_999).clamped
            == CellRef(row: Limits.maxRow, column: Limits.maxColumn))
    }

    // MARK: - Anchored references

    @Test("parseA1 reports where the dollar signs were")
    func absoluteMarkers() throws {
        let plain = try #require(CellRef.parseA1("B7"))
        #expect(plain.ref == CellRef(row: 6, column: 1))
        #expect(!plain.absoluteColumn && !plain.absoluteRow)

        let both = try #require(CellRef.parseA1("$B$7"))
        #expect(both.ref == CellRef(row: 6, column: 1))
        #expect(both.absoluteColumn && both.absoluteRow)

        let columnOnly = try #require(CellRef.parseA1("$B7"))
        #expect(columnOnly.absoluteColumn && !columnOnly.absoluteRow)

        let rowOnly = try #require(CellRef.parseA1("B$7"))
        #expect(!rowOnly.absoluteColumn && rowOnly.absoluteRow)

        #expect(CellRef.parseA1("$$B7") == nil)
        #expect(CellRef.parseA1("B$$7") == nil)
        #expect(CellRef.parseA1("B7$") == nil)
    }

    @Test("anchored formatting matches what a formula expects")
    func absoluteFormatting() {
        let ref = CellRef(row: 6, column: 1)
        #expect(ref.a1String(absoluteColumn: true, absoluteRow: true) == "$B$7")
        #expect(ref.a1String(absoluteColumn: true, absoluteRow: false) == "$B7")
        #expect(ref.a1String(absoluteColumn: false, absoluteRow: true) == "B$7")
        #expect(ref.a1String(absoluteColumn: false, absoluteRow: false) == "B7")
    }

    // MARK: - Allocation-free emission

    @Test("appendA1 into a byte buffer matches a1String")
    func byteBufferEmission() {
        var buffer: [UInt8] = []
        for ref in [CellRef.origin,
                    CellRef(row: 6, column: 1),
                    CellRef(row: 0, column: 25),
                    CellRef(row: 0, column: 26),
                    CellRef(row: 1_048_575, column: 16_383)] {
            buffer.removeAll(keepingCapacity: true)
            ref.appendA1(to: &buffer)
            #expect(String(decoding: buffer, as: UTF8.self) == ref.a1String)
        }
    }

    @Test("appendA1 into a String matches a1String")
    func stringEmission() {
        var text = "r=\""
        CellRef(row: 41, column: 54).appendA1(to: &text)
        text += "\""
        #expect(text == "r=\"BC42\"")
    }

    // MARK: - Ordering and identity

    @Test("ordering is row-major")
    func ordering() {
        #expect(CellRef(row: 0, column: 5) < CellRef(row: 1, column: 0))
        #expect(CellRef(row: 3, column: 1) < CellRef(row: 3, column: 2))
        #expect(!(CellRef(row: 3, column: 2) < CellRef(row: 3, column: 2)))
    }

    @Test("distinct references hash distinctly across a wide sample")
    func hashing() {
        var seen = Set<CellRef>()
        for row in stride(from: 0, to: 100_000, by: 997) {
            for column in stride(from: 0, to: 16_384, by: 331) {
                #expect(seen.insert(CellRef(row: row, column: column)).inserted)
            }
        }
    }

    @Test("column letters refuse to invent an answer for nonsense input")
    func columnLetterEdges() {
        #expect(CellRef.columnLetters(-1) == "?")
        #expect(CellRef.columnLetters(475_254) == "?")
        #expect(CellRef.columnIndex(letters: "") == nil)
        #expect(CellRef.columnIndex(letters: "A1") == nil)
        #expect(CellRef.columnIndex(letters: "XFE") == nil)
        #expect(CellRef.columnIndex(letters: "xfd") == 16_383)
    }
}
