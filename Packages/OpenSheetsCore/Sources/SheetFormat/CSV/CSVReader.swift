//
//  CSVReader.swift
//  SheetFormat
//
//  Streaming RFC 4180, dialect sniffing, and the typing rules for an untyped file.
//

import Foundation
import SheetModel

/// Knobs on a read. Every one of them defaults to "work it out from the file".
public struct CSVReadOptions: Sendable, Hashable {
    /// Force a field separator instead of sniffing one.
    public var delimiter: Character?
    /// Force a quote character instead of sniffing one.
    public var quote: Character?
    /// Force an encoding instead of detecting one.
    public var encoding: CSVEncoding?
    /// Whether to treat the first row as headers. Only recorded, never acted on: the grid shows
    /// row 1 either way, and dropping it would lose data.
    public var hasHeaderRow: Bool
    /// Bytes to look at when sniffing.
    public var sniffBytes: Int
    /// Stop after this many rows. `nil` means the sheet's own limit.
    public var maximumRows: Int?
    /// How to convert a field into a value. See ``CSVValueTyping``.
    public var typing: CSVValueTyping

    public init(
        delimiter: Character? = nil,
        quote: Character? = nil,
        encoding: CSVEncoding? = nil,
        hasHeaderRow: Bool = false,
        sniffBytes: Int = 64 * 1024,
        maximumRows: Int? = nil,
        typing: CSVValueTyping = .standard
    ) {
        self.delimiter = delimiter
        self.quote = quote
        self.encoding = encoding
        self.hasHeaderRow = hasHeaderRow
        self.sniffBytes = sniffBytes
        self.maximumRows = maximumRows
        self.typing = typing
    }

    public static let standard = CSVReadOptions()
}

/// How a field of text becomes a ``CellValue``.
public struct CSVValueTyping: Sendable, Hashable {
    /// Whether `TRUE` and `FALSE` become booleans.
    public var booleans: Bool
    /// Whether `#N/A`, `#DIV/0!` and the rest become error values rather than text.
    ///
    /// On, because that is what Excel does and because the alternative is a workbook that looks
    /// right until it is saved as `.xlsx`, at which point Excel reinterprets the text and the
    /// two disagree. The Wave 1 addendum §4 calls this out specifically.
    public var errorTokens: Bool
    /// Whether digits become numbers.
    public var numbers: Bool
    /// Whether a value with a leading zero (`0012`, `007`) stays text.
    ///
    /// On, and this is a deliberate divergence from Excel, which turns `0012` into `12`. Product
    /// codes, postcodes and account numbers arrive in CSVs constantly, and silently deleting a
    /// leading zero is a data change the user did not ask for and will not notice until it
    /// matters. Turn it off to match Excel exactly.
    public var preserveLeadingZeros: Bool

    public init(
        booleans: Bool = true,
        errorTokens: Bool = true,
        numbers: Bool = true,
        preserveLeadingZeros: Bool = true
    ) {
        self.booleans = booleans
        self.errorTokens = errorTokens
        self.numbers = numbers
        self.preserveLeadingZeros = preserveLeadingZeros
    }

    public static let standard = CSVValueTyping()
    /// Everything stays text. What an import preview uses.
    public static let none = CSVValueTyping(booleans: false, errorTokens: false, numbers: false)
}

/// What a read produced besides the rows.
public struct CSVReadReport: Sendable, Hashable {
    /// The dialect that was used, sniffed or forced.
    public var dialect: CSVDialect
    /// Rows whose field count differed from the first row's.
    public var raggedRowCount: Int
    /// Widest row seen.
    public var columnCount: Int
    /// Rows read.
    public var rowCount: Int
    /// Whether the row limit stopped the read early.
    public var wasTruncated: Bool

    public init(
        dialect: CSVDialect,
        raggedRowCount: Int = 0,
        columnCount: Int = 0,
        rowCount: Int = 0,
        wasTruncated: Bool = false
    ) {
        self.dialect = dialect
        self.raggedRowCount = raggedRowCount
        self.columnCount = columnCount
        self.rowCount = rowCount
        self.wasTruncated = wasTruncated
    }
}

/// Reads delimited text.
///
/// # Streaming, not slurping
///
/// ``forEachRow(contentsOf:options:_:)`` reads the file in 256 KB chunks and hands each row to a
/// callback. Nothing accumulates: a 2 GB CSV costs one chunk of bytes, one chunk of decoded
/// text, and the longest single row. That is the difference between "opens" and "beachballs and
/// then dies", and PLAN.md §9 lists it as a case the implementation must handle explicitly.
///
/// ``workbook(contentsOf:options:)`` is the convenience on top, and it is *not* streaming in the
/// same sense — it builds a `CellStore`, which is bounded by the sheet's own row limit.
public enum CSVReader {
    /// Bytes per read. Big enough that the syscall overhead disappears, small enough that four
    /// concurrent opens do not matter.
    static let chunkSize = 256 * 1024

    // MARK: - Dialect

    /// Sniffs the dialect from a prefix of the file, without reading the rest.
    public static func detectDialect(
        contentsOf url: URL,
        options: CSVReadOptions = .standard
    ) throws(SheetError) -> CSVDialect {
        let sample = try readSample(url, limit: options.sniffBytes)
        return dialect(forSample: sample, options: options)
    }

    /// Sniffs the dialect from bytes already in hand.
    public static func dialect(forSample sample: [UInt8], options: CSVReadOptions = .standard) -> CSVDialect {
        let detection = options.encoding.map {
            CSVEncodingDetection(encoding: $0, byteOrderMarkLength: prefixLength($0, in: sample), wasGuessed: false)
        } ?? CSVEncodingDetector.detect(sample)

        var decoder = CSVTextDecoder(encoding: detection.encoding)
        var scalars = String.UnicodeScalarView()
        decoder.decode(sample.dropFirst(detection.byteOrderMarkLength), into: &scalars)
        let text = String(scalars)

        let delimiter = options.delimiter ?? CSVDialectSniffer.delimiter(in: text)
        let quote = options.quote ?? CSVDialectSniffer.quote(in: text)
        return CSVDialect(
            delimiter: delimiter,
            quote: quote,
            lineEnding: CSVDialectSniffer.lineEnding(in: text, quote: quote),
            hasByteOrderMark: detection.byteOrderMarkLength > 0,
            encodingName: detection.encoding.rawValue,
            encodingWasGuessed: detection.wasGuessed,
            hasHeaderRow: options.hasHeaderRow,
            endsWithoutNewline: false
        )
    }

    // MARK: - Streaming rows

    /// Reads `url`, calling `body` once per record.
    ///
    /// `body` returns `false` to stop early. Field arrays are handed over, not retained — the
    /// reader keeps no copy, so a caller that only counts rows uses constant memory whatever the
    /// file's size.
    @discardableResult
    public static func forEachRow(
        contentsOf url: URL,
        options: CSVReadOptions = .standard,
        _ body: ([String], Int) -> Bool
    ) throws(SheetError) -> CSVReadReport {
        let sample = try readSample(url, limit: options.sniffBytes)
        var dialect = self.dialect(forSample: sample, options: options)
        let detection = options.encoding.map {
            CSVEncodingDetection(encoding: $0, byteOrderMarkLength: prefixLength($0, in: sample), wasGuessed: false)
        } ?? CSVEncodingDetector.detect(sample)

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SheetError.fileNotReadable(path: url.path, underlying: "\(error)")
        }
        defer { try? handle.close() }

        var decoder = CSVTextDecoder(encoding: detection.encoding)
        var parser = CSVRecordParser(delimiter: dialect.delimiter, quote: dialect.quote)
        var report = CSVReadReport(dialect: dialect)
        var firstRowWidth: Int?
        var stopped = false
        var skipped = 0
        let limit = options.maximumRows ?? Limits.rowCount

        func consume(_ row: [String]) {
            guard !stopped else { return }
            if report.rowCount >= limit {
                report.wasTruncated = true
                stopped = true
                return
            }
            report.rowCount += 1
            report.columnCount = max(report.columnCount, row.count)
            if let width = firstRowWidth {
                if row.count != width { report.raggedRowCount += 1 }
            } else {
                firstRowWidth = row.count
            }
            if !body(row, report.rowCount - 1) { stopped = true }
        }

        var readFailure: SheetError?
        var reachedEnd = false
        while !stopped, !reachedEnd {
            // Each chunk must be released before the next one is read. `FileHandle.read` returns
            // a bridged `NSData`, which lands in the enclosing autorelease pool — and a caller
            // that never drains one (a command-line tool, a long-running actor) accumulates the
            // whole file one chunk at a time. That turns "streams a 2 GB CSV" back into
            // "allocates 2 GB", with no allocation in our own code to point at.
            autoreleasepool {
                let chunk: Data?
                do {
                    chunk = try handle.read(upToCount: chunkSize)
                } catch {
                    readFailure = SheetError.fileNotReadable(path: url.path, underlying: "\(error)")
                    return
                }
                guard let chunk, !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }

                var bytes = [UInt8](chunk)
                if skipped < detection.byteOrderMarkLength {
                    let drop = min(detection.byteOrderMarkLength - skipped, bytes.count)
                    bytes.removeFirst(drop)
                    skipped += drop
                }
                var scalars = String.UnicodeScalarView()
                decoder.decode(bytes[...], into: &scalars)
                parser.feed(scalars, consume)
            }
            if let readFailure { throw readFailure }
        }

        var tail = String.UnicodeScalarView()
        decoder.finish(into: &tail)
        parser.feed(tail, consume)
        dialect.endsWithoutNewline = !parser.endedOnLineBreak
        parser.finish(consume)
        report.dialect = dialect
        return report
    }

    /// Reads rows from bytes already in memory. Convenience for tests and for pasted text.
    @discardableResult
    public static func forEachRow(
        in data: Data,
        options: CSVReadOptions = .standard,
        _ body: ([String], Int) -> Bool
    ) -> CSVReadReport {
        let bytes = [UInt8](data)
        var dialect = self.dialect(forSample: Array(bytes.prefix(options.sniffBytes)), options: options)
        let detection = options.encoding.map {
            CSVEncodingDetection(encoding: $0, byteOrderMarkLength: prefixLength($0, in: bytes), wasGuessed: false)
        } ?? CSVEncodingDetector.detect(bytes)

        var decoder = CSVTextDecoder(encoding: detection.encoding)
        var scalars = String.UnicodeScalarView()
        decoder.decode(bytes.dropFirst(detection.byteOrderMarkLength), into: &scalars)
        decoder.finish(into: &scalars)

        var parser = CSVRecordParser(delimiter: dialect.delimiter, quote: dialect.quote)
        var report = CSVReadReport(dialect: dialect)
        var firstRowWidth: Int?
        var stopped = false
        let limit = options.maximumRows ?? Limits.rowCount

        func consume(_ row: [String]) {
            guard !stopped else { return }
            if report.rowCount >= limit {
                report.wasTruncated = true
                stopped = true
                return
            }
            report.rowCount += 1
            report.columnCount = max(report.columnCount, row.count)
            if let width = firstRowWidth {
                if row.count != width { report.raggedRowCount += 1 }
            } else {
                firstRowWidth = row.count
            }
            if !body(row, report.rowCount - 1) { stopped = true }
        }

        parser.feed(scalars, consume)
        dialect.endsWithoutNewline = !parser.endedOnLineBreak
        parser.finish(consume)
        report.dialect = dialect
        return report
    }

    // MARK: - Workbooks

    /// Reads a delimited file into a one-sheet workbook.
    public static func workbook(
        contentsOf url: URL,
        options: CSVReadOptions = .standard
    ) throws(SheetError) -> Workbook {
        var sheet = Sheet(id: SheetID(1), name: sheetName(for: url))
        var failure: SheetError?
        let report = try forEachRow(contentsOf: url, options: options) { fields, row in
            failure = fill(&sheet, row: row, fields: fields, typing: options.typing)
            return failure == nil
        }
        if let failure { throw failure }
        return workbook(sheet: sheet, report: report, url: url)
    }

    /// Reads delimited bytes into a one-sheet workbook.
    public static func workbook(
        from data: Data,
        name: String = "Sheet1",
        options: CSVReadOptions = .standard
    ) throws(SheetError) -> Workbook {
        var sheet = Sheet(id: SheetID(1), name: name)
        var failure: SheetError?
        let report = forEachRow(in: data, options: options) { fields, row in
            failure = fill(&sheet, row: row, fields: fields, typing: options.typing)
            return failure == nil
        }
        if let failure { throw failure }
        return workbook(sheet: sheet, report: report, url: nil)
    }

    private static func workbook(sheet: Sheet, report: CSVReadReport, url: URL?) -> Workbook {
        var meta = WorkbookMeta()
        meta.sourceFormat = report.dialect.delimiter == "\t" ? .tsv : .csv
        meta.csvDialect = report.dialect
        meta.raggedRowCount = report.raggedRowCount
        if let url { meta.title = url.deletingPathExtension().lastPathComponent }
        return Workbook(sheets: [sheet], meta: meta)
    }

    private static func fill(
        _ sheet: inout Sheet,
        row: Int,
        fields: [String],
        typing: CSVValueTyping
    ) -> SheetError? {
        for (column, field) in fields.enumerated() {
            guard column <= Limits.maxColumn else { break }
            let cell = CSVValueParser.cell(for: field, typing: typing)
            guard !cell.isBlank else { continue }
            do {
                try sheet.cells.setCell(cell, at: CellRef(row: row, column: column))
            } catch {
                return error
            }
        }
        return nil
    }

    private static func sheetName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let cleaned = String(stem.prefix(Limits.maxSheetNameLength))
            .filter { !Limits.forbiddenSheetNameCharacters.contains($0) }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        return trimmed.isEmpty ? "Sheet1" : trimmed
    }

    // MARK: - Bytes

    private static func readSample(_ url: URL, limit: Int) throws(SheetError) -> [UInt8] {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SheetError.fileNotReadable(path: url.path, underlying: "\(error)")
        }
        defer { try? handle.close() }
        do {
            return [UInt8](try handle.read(upToCount: limit) ?? Data())
        } catch {
            throw SheetError.fileNotReadable(path: url.path, underlying: "\(error)")
        }
    }

    private static func prefixLength(_ encoding: CSVEncoding, in bytes: [UInt8]) -> Int {
        let mark = encoding.byteOrderMark
        guard !mark.isEmpty, bytes.count >= mark.count else { return 0 }
        return Array(bytes.prefix(mark.count)) == mark ? mark.count : 0
    }
}

/// RFC 4180, as a state machine that never needs to see the whole file.
///
/// Deliberately *not* line-based. A field can hold a line break — `Fixtures/csv/quoted-newlines.csv`
/// holds both an LF and a CRLF inside quotes — and splitting on newlines before parsing quotes
/// corrupts exactly those files. Line endings inside quotes are also preserved byte for byte
/// rather than normalised, because a normalising reader silently rewrites the user's data.
public struct CSVRecordParser: Sendable {
    private let delimiter: Unicode.Scalar
    private let quote: Unicode.Scalar

    private var field = String.UnicodeScalarView()
    private var row: [String] = []
    private var inQuotes = false
    private var quoteJustClosed = false
    private var fieldWasQuoted = false
    private var pendingCarriageReturn = false
    private var startedRow = false

    /// Whether the last character consumed ended a record, which is what `endsWithoutNewline`
    /// records so a save can put the file back the way it found it.
    public private(set) var endedOnLineBreak = true

    public init(delimiter: Character, quote: Character) {
        self.delimiter = delimiter.unicodeScalars.first ?? ","
        self.quote = quote.unicodeScalars.first ?? "\""
    }

    /// Feeds more text, emitting every complete record.
    public mutating func feed(_ scalars: String.UnicodeScalarView, _ emit: ([String]) -> Void) {
        for scalar in scalars {
            if pendingCarriageReturn {
                pendingCarriageReturn = false
                if scalar == "\n" { continue }
            }
            if inQuotes {
                if scalar == quote {
                    inQuotes = false
                    quoteJustClosed = true
                } else {
                    field.append(scalar)
                    startedRow = true
                }
                endedOnLineBreak = false
                continue
            }
            if quoteJustClosed {
                quoteJustClosed = false
                if scalar == quote {
                    field.append(quote)
                    inQuotes = true
                    endedOnLineBreak = false
                    continue
                }
            }
            if scalar == quote, field.isEmpty, !fieldWasQuoted {
                inQuotes = true
                fieldWasQuoted = true
                startedRow = true
                endedOnLineBreak = false
                continue
            }
            if scalar == delimiter {
                endField()
                endedOnLineBreak = false
                continue
            }
            if scalar == "\r" {
                pendingCarriageReturn = true
                endRow(emit)
                endedOnLineBreak = true
                continue
            }
            if scalar == "\n" {
                endRow(emit)
                endedOnLineBreak = true
                continue
            }
            field.append(scalar)
            startedRow = true
            endedOnLineBreak = false
        }
    }

    /// Emits a final record that was not terminated by a line break.
    public mutating func finish(_ emit: ([String]) -> Void) {
        guard startedRow || !row.isEmpty || !field.isEmpty || fieldWasQuoted else { return }
        endRow(emit)
    }

    private mutating func endField() {
        row.append(String(field))
        field = String.UnicodeScalarView()
        fieldWasQuoted = false
        startedRow = true
    }

    private mutating func endRow(_ emit: ([String]) -> Void) {
        endField()
        emit(row)
        row = []
        startedRow = false
    }
}

/// Sniffing the delimiter, quote and line ending from a sample.
public enum CSVDialectSniffer {
    /// The separators worth guessing between.
    public static let candidates: [Character] = [",", ";", "\t", "|"]

    /// The delimiter that produces the most consistent row shape.
    ///
    /// Consistency rather than frequency, because frequency picks the comma out of a
    /// semicolon-separated European file where `10,5` is a decimal number — one comma per row,
    /// perfectly consistent, and completely wrong. The tie-break is that a candidate must
    /// produce more than one field per row before its consistency counts for anything.
    public static func delimiter(in sample: String) -> Character {
        var best: (delimiter: Character, score: Double, width: Int) = (",", 0, 1)
        for candidate in candidates {
            var parser = CSVRecordParser(delimiter: candidate, quote: "\"")
            var widths: [Int] = []
            parser.feed(sample.unicodeScalars) { widths.append($0.count) }
            // The last record may have been cut in half by the sampling window.
            if widths.count > 1 { widths.removeLast() }
            guard !widths.isEmpty else { continue }

            var histogram: [Int: Int] = [:]
            for width in widths { histogram[width, default: 0] += 1 }
            guard let (modal, occurrences) = histogram.max(by: { $0.value < $1.value }), modal > 1 else { continue }
            let score = Double(occurrences) / Double(widths.count)
            if score > best.score || (score == best.score && modal > best.width) {
                best = (candidate, score, modal)
            }
        }
        return best.score > 0 ? best.delimiter : ","
    }

    /// The quote character. Almost always `"`.
    ///
    /// A single quote is only accepted when the sample holds no double quotes at all *and* some
    /// field is wrapped in single quotes — otherwise every apostrophe in every English word turns
    /// into a quote character and the file parses as one enormous field.
    public static func quote(in sample: String) -> Character {
        guard !sample.unicodeScalars.contains("\"") else { return "\"" }
        guard sample.unicodeScalars.contains("'") else { return "\"" }
        let lines = sample.unicodeScalars
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String(String.UnicodeScalarView($0)) }
        for line in lines {
            for field in line.split(separator: ",", omittingEmptySubsequences: false)
                where field.count >= 2 && field.hasPrefix("'") && field.hasSuffix("'") {
                return "'"
            }
        }
        return "\""
    }

    /// The line ending, from the first one that appears outside a quoted field.
    ///
    /// Iterates **unicode scalars**, not characters. Swift treats `\r\n` as a single grapheme
    /// cluster, so a `Character`-level scan finds neither a `\r` nor an `\n` in a CRLF file and
    /// concludes it has LF endings — which is then what a "preserve the source dialect" save
    /// writes back, rewriting every line of somebody's Windows export.
    public static func lineEnding(in sample: String, quote: Character) -> CSVDialect.LineEnding {
        let quoteScalar = quote.unicodeScalars.first ?? "\""
        var inQuotes = false
        var previous: Unicode.Scalar?
        for scalar in sample.unicodeScalars {
            if scalar == quoteScalar {
                inQuotes.toggle()
                previous = scalar
                continue
            }
            guard !inQuotes else {
                previous = scalar
                continue
            }
            if scalar == "\n" { return previous == "\r" ? .crlf : .lf }
            if previous == "\r" { return .cr }
            previous = scalar
        }
        return previous == "\r" ? .cr : .lf
    }
}
