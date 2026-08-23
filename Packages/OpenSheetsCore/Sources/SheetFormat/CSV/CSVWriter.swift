//
//  CSVWriter.swift
//  SheetFormat
//
//  RFC 4180 out, with the formula-injection guard on by default.
//

import Foundation
import SheetModel

/// Knobs on a delimited-text save.
public struct CSVWriteOptions: Sendable, Hashable {
    /// The dialect to write. `nil` means "the one the file arrived in".
    public var dialect: CSVDialect?

    /// Ignore the source dialect and write comma-separated UTF-8 with LF endings.
    ///
    /// Off by default. A file that arrived semicolon-separated in Windows-1252 with CRLF endings
    /// leaves that way, because the script on the other end of it was written against that shape
    /// and "we tidied your file" is not a change anyone asked for (PLAN.md §5.4).
    public var normalise: Bool

    /// Prefix a text value that starts with `=`, `+`, `-`, `@`, tab or carriage return with an
    /// apostrophe.
    ///
    /// **On by default** (PLAN.md §7.3). Not for our benefit — we never execute anything — but
    /// for whoever opens the file in Excel afterwards, where `=cmd|' /C calc'!A0` in a cell is a
    /// remote code execution primitive. The apostrophe is Excel's own "this is text" marker and
    /// is invisible in the cell.
    ///
    /// Applies to text values only. A number that happens to be negative is not an injection
    /// vector, and quoting `-3` into `'-3` would turn a number into a string.
    public var guardAgainstFormulaInjection: Bool

    /// Which encoding to write.
    public var encoding: CSVEncoding?

    /// Write a byte-order mark. `nil` means "whatever the source had".
    public var byteOrderMark: Bool?

    public init(
        dialect: CSVDialect? = nil,
        normalise: Bool = false,
        guardAgainstFormulaInjection: Bool = true,
        encoding: CSVEncoding? = nil,
        byteOrderMark: Bool? = nil
    ) {
        self.dialect = dialect
        self.normalise = normalise
        self.guardAgainstFormulaInjection = guardAgainstFormulaInjection
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
    }

    public static let standard = CSVWriteOptions()
}

/// Writes a sheet as delimited text.
public enum CSVWriter {
    /// The characters that make Excel treat a cell as something to evaluate.
    ///
    /// Tab and carriage return are on the list because Excel strips leading whitespace before
    /// deciding, so `\t=1+1` is `=1+1` by the time it matters.
    public static let dangerousPrefixes: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

    /// The sheet's cells as delimited text.
    public static func text(
        for sheet: Sheet,
        options: CSVWriteOptions = .standard,
        sourceDialect: CSVDialect? = nil
    ) -> String {
        let dialect = resolvedDialect(options: options, source: sourceDialect)
        let terminator = dialect.lineEnding.characters

        guard let extent = sheet.usedRange else { return "" }
        var output = ""

        // Trailing empty cells are trimmed rather than padded. On a rectangular sheet nothing is
        // trimmed, because every row reaches the last column. On `Fixtures/perf/single-cell-at-
        // XFD1048576.xlsx` — one cell, a used range of 17 billion — padding would mean writing
        // 16,383 delimiters on each of a million empty lines, and the export would never finish.
        for row in extent.rows {
            let cells = sheet.cells
                .cells(in: CellRange(rows: row ... row, columns: extent.columns))
                .sorted { $0.ref.column < $1.ref.column }
            var position = 0
            for (ref, cell) in cells {
                let target = ref.column - extent.start.column
                while position < target {
                    if position > 0 { output.append(dialect.delimiter) }
                    position += 1
                }
                if position > 0 { output.append(dialect.delimiter) }
                output += field(for: cell, dialect: dialect, options: options)
                position += 1
            }
            output += terminator
        }

        if dialect.endsWithoutNewline, !options.normalise, output.hasSuffix(terminator) {
            output.removeLast(terminator.count)
        }
        return output
    }

    /// The sheet's cells as bytes, encoded and with a byte-order mark if one is wanted.
    public static func data(
        for sheet: Sheet,
        options: CSVWriteOptions = .standard,
        sourceDialect: CSVDialect? = nil
    ) throws(SheetError) -> Data {
        let dialect = resolvedDialect(options: options, source: sourceDialect)
        let encoding = options.encoding
            ?? (options.normalise ? .utf8 : CSVEncoding(rawValue: dialect.encodingName) ?? .utf8)
        let body = text(for: sheet, options: options, sourceDialect: sourceDialect)

        guard let encoded = CSVTextDecoder.encode(body, as: encoding) else {
            throw SheetError.unsupportedTextEncoding(name: encoding.rawValue)
        }
        let wantsMark = options.byteOrderMark ?? (options.normalise ? false : dialect.hasByteOrderMark)
        guard wantsMark, !encoding.byteOrderMark.isEmpty else { return encoded }
        return Data(encoding.byteOrderMark) + encoded
    }

    /// Writes a sheet to `url` atomically, returning the fingerprint A6 uses to recognise the
    /// write as our own.
    @discardableResult
    public static func save(
        _ workbook: Workbook,
        sheet: SheetID? = nil,
        to url: URL,
        options: CSVWriteOptions = .standard,
        interrupt: ((AtomicFileWriter.Phase) throws -> Void)? = nil
    ) throws(SheetError) -> SavedFileFingerprint {
        if let reason = workbook.meta.readOnlyReason {
            throw SheetError.writeRefused(reason: reason)
        }
        let target: Sheet
        if let sheet {
            target = try workbook.requireSheet(id: sheet)
        } else if let first = workbook.sheets.first {
            target = first
        } else {
            throw SheetError.invalidArgument(name: "workbook", reason: "there is no sheet to write")
        }
        let bytes = try data(for: target, options: options, sourceDialect: workbook.meta.csvDialect)
        return try AtomicFileWriter.write(bytes, to: url, interrupt: interrupt)
    }

    // MARK: - Fields

    /// One field, quoted per RFC 4180 and guarded against injection.
    static func field(for cell: Cell, dialect: CSVDialect, options: CSVWriteOptions) -> String {
        var text = CSVValueParser.text(for: cell)
        if options.guardAgainstFormulaInjection, cell.value.text != nil,
           let first = text.first, dangerousPrefixes.contains(first) {
            text = "'" + text
        }
        return quoted(text, dialect: dialect)
    }

    /// RFC 4180 quoting: wrap when the field holds a delimiter, a quote or a line break, and
    /// double any quote inside.
    ///
    /// Leading and trailing spaces are quoted too. They are legal unquoted, but half the readers
    /// in the world trim them, and a value that loses its padding on the way through is a value
    /// that changed.
    static func quoted(_ text: String, dialect: CSVDialect) -> String {
        // Scalar-level, not character-level: Swift folds `\r\n` into one grapheme cluster, so
        // `text.contains("\n")` is *false* for a field holding a CRLF and the field goes out
        // unquoted — splitting one record into two on the way back in.
        let scalars = text.unicodeScalars
        let needsQuoting = scalars.contains(dialect.delimiter.unicodeScalars.first ?? ",")
            || scalars.contains(dialect.quote.unicodeScalars.first ?? "\"")
            || scalars.contains("\n")
            || scalars.contains("\r")
            || scalars.first == " "
            || scalars.last == " "
        guard needsQuoting else { return text }
        let escaped = text.replacingOccurrences(
            of: String(dialect.quote), with: String(repeating: String(dialect.quote), count: 2)
        )
        return String(dialect.quote) + escaped + String(dialect.quote)
    }

    private static func resolvedDialect(options: CSVWriteOptions, source: CSVDialect?) -> CSVDialect {
        if options.normalise { return .standard }
        return options.dialect ?? source ?? .standard
    }
}
