//
//  ExpectedWorkbook.swift
//  TestSupport
//
//  The typed reading of a `.expected.json` sidecar from the golden corpus.
//

import Foundation
import SheetModel

/// One fixture's `.expected.json` sidecar, decoded.
///
/// The corpus stores ground truth as JSON so that a Python validator and a Swift test suite can
/// read the same file and cannot drift. This is the Swift side of that contract; it decodes
/// leniently — a sidecar carrying a key we have not modelled yet is not an error, because the
/// corpus grows faster than the readers do.
///
/// The schema is documented in `Fixtures/README.md`. Two shapes share it: `kind == "csv"`
/// sidecars describe a dialect and a row grid, everything else describes sheets and cells.
public struct ExpectedWorkbook: Sendable, Codable, Hashable {
    /// What kind of file the sidecar describes.
    public enum Kind: String, Sendable, Codable, Hashable, CaseIterable {
        case xlsx
        case xlsm
        case csv
    }

    /// Path relative to `Fixtures/`, e.g. `formulas/functions.xlsx`.
    public var file: String
    public var kind: Kind
    /// Why this fixture exists — quoted verbatim into a failure message.
    public var proves: String
    /// How the values in this sidecar were established. See `Fixtures/README.md`.
    public var valuesVerifiedBy: String
    public var notes: String?

    /// `1900` or `1904`.
    public var dateSystem: Int?
    public var sheets: [ExpectedSheet]?
    /// Name to `refersTo` text, as stored.
    public var definedNames: [String: String]?

    /// ZIP entries a save must copy through untouched (A2's contract).
    public var passthroughEntries: [String]?
    /// `CT_Worksheet` children that must survive a re-emit (Wave 1 addendum §1).
    public var sheetLevelElementsThatMustSurvive: [String]?
    /// Per-entry digests, so a passthrough test can prove bytes rather than presence.
    public var zipEntries: [String: ExpectedZipEntry]?

    /// Assertions this fixture deliberately exempts, e.g. `cellValue:Volatile!B1`.
    ///
    /// Honoured by ``WorkbookMatcher``: a skipped check is reported as skipped rather than
    /// silently passing, so an exemption cannot quietly hide a regression.
    public var skipChecks: [String]?

    // MARK: - CSV

    public var dialect: ExpectedCSVDialect?
    public var rowCount: Int?
    public var maxColumns: Int?
    public var ragged: Bool?
    public var raggedRowCount: Int?
    /// The decoded grid, row-major, as strings.
    public var rows: [[String]]?

    public init(
        file: String,
        kind: Kind,
        proves: String = "",
        valuesVerifiedBy: String = "",
        notes: String? = nil,
        dateSystem: Int? = nil,
        sheets: [ExpectedSheet]? = nil,
        definedNames: [String: String]? = nil,
        passthroughEntries: [String]? = nil,
        sheetLevelElementsThatMustSurvive: [String]? = nil,
        zipEntries: [String: ExpectedZipEntry]? = nil,
        skipChecks: [String]? = nil,
        dialect: ExpectedCSVDialect? = nil,
        rowCount: Int? = nil,
        maxColumns: Int? = nil,
        ragged: Bool? = nil,
        raggedRowCount: Int? = nil,
        rows: [[String]]? = nil
    ) {
        self.file = file
        self.kind = kind
        self.proves = proves
        self.valuesVerifiedBy = valuesVerifiedBy
        self.notes = notes
        self.dateSystem = dateSystem
        self.sheets = sheets
        self.definedNames = definedNames
        self.passthroughEntries = passthroughEntries
        self.sheetLevelElementsThatMustSurvive = sheetLevelElementsThatMustSurvive
        self.zipEntries = zipEntries
        self.skipChecks = skipChecks
        self.dialect = dialect
        self.rowCount = rowCount
        self.maxColumns = maxColumns
        self.ragged = ragged
        self.raggedRowCount = raggedRowCount
        self.rows = rows
    }

    /// The date system as the model spells it.
    public var resolvedDateSystem: DateSystem {
        dateSystem == 1904 ? .excel1904 : .excel1900
    }

    /// Whether `check` is exempted for this fixture.
    ///
    /// Matches either the whole token (`cellValue:Volatile!B1`) or its kind (`cellValue`), so a
    /// sidecar can exempt one cell or a whole class of assertion.
    public func skips(_ check: String) -> Bool {
        guard let skipChecks else { return false }
        if skipChecks.contains(check) { return true }
        let kind = check.prefix { $0 != ":" }
        return skipChecks.contains(String(kind))
    }
}

/// One sheet inside a sidecar.
public struct ExpectedSheet: Sendable, Codable, Hashable {
    public var name: String
    /// 0-based tab position.
    public var index: Int
    public var visibility: String?
    /// `<dimension>` **as declared in the file** — deliberately wrong or absent in some
    /// fixtures. Never assert the model's computed extent against this.
    public var dimension: String?
    /// The computed used range: the union of every cell *and every merge*.
    public var usedRange: String?
    public var cells: [String: ExpectedCell]?
    public var merges: [String]?
    public var frozen: ExpectedFrozen?
    public var split: ExpectedSplit?
    /// Column index (1-based, or `"3-10"` for a run) to width in Excel character units.
    public var columnWidths: [String: Double]?
    /// Row index (1-based) to height in points.
    public var rowHeights: [String: Double]?
    /// A1 address to link target.
    public var hyperlinks: [String: String]?

    public init(
        name: String,
        index: Int,
        visibility: String? = nil,
        dimension: String? = nil,
        usedRange: String? = nil,
        cells: [String: ExpectedCell]? = nil,
        merges: [String]? = nil,
        frozen: ExpectedFrozen? = nil,
        split: ExpectedSplit? = nil,
        columnWidths: [String: Double]? = nil,
        rowHeights: [String: Double]? = nil,
        hyperlinks: [String: String]? = nil
    ) {
        self.name = name
        self.index = index
        self.visibility = visibility
        self.dimension = dimension
        self.usedRange = usedRange
        self.cells = cells
        self.merges = merges
        self.frozen = frozen
        self.split = split
        self.columnWidths = columnWidths
        self.rowHeights = rowHeights
        self.hyperlinks = hyperlinks
    }

    /// The visibility as the model spells it, defaulting to `.visible`.
    public var resolvedVisibility: SheetVisibility {
        visibility.flatMap { SheetVisibility(rawValue: $0) } ?? .visible
    }
}

/// One cell inside a sidecar.
public struct ExpectedCell: Sendable, Codable, Hashable {
    /// `number` · `text` · `boolean` · `error` · `empty`.
    public var type: String
    /// The value. `null` with a non-`empty` type means *a value must exist, its content is not
    /// asserted* — that is how `TODAY()` is expressed.
    public var value: ExpectedValue?
    /// The **resolved** OOXML format code; built-in ids are already expanded.
    public var numberFormat: String?
    /// Formula source without the leading `=`.
    public var formula: String?
    /// ``CellFlags`` case names.
    public var flags: [String]?

    public init(
        type: String,
        value: ExpectedValue? = nil,
        numberFormat: String? = nil,
        formula: String? = nil,
        flags: [String]? = nil
    ) {
        self.type = type
        self.value = value
        self.numberFormat = numberFormat
        self.formula = formula
        self.flags = flags
    }

    /// The sidecar's value as a ``CellValue``, or `nil` when the sidecar asserts existence
    /// without asserting content.
    public var expectedValue: CellValue? {
        switch type {
        case "empty": .empty
        case "number": value?.number.map(CellValue.number)
        case "text": value?.string.map(CellValue.text)
        case "boolean": value?.boolean.map(CellValue.boolean)
        case "error": value?.string.flatMap(CellError.init(rawValue:)).map(CellValue.error)
        default: nil
        }
    }

    /// The flag set the sidecar names.
    public var expectedFlags: CellFlags {
        var result: CellFlags = []
        for name in flags ?? [] {
            switch name {
            case "staleCache": result.insert(.staleCache)
            case "externalLink": result.insert(.externalLink)
            case "unsupportedFormula": result.insert(.unsupportedFormula)
            case "arrayFormula": result.insert(.arrayFormula)
            case "sharedFormulaExpansion": result.insert(.sharedFormulaExpansion)
            case "hyperlink": result.insert(.hyperlink)
            case "richText": result.insert(.richText)
            case "inlineString": result.insert(.inlineString)
            case "comment": result.insert(.comment)
            case "dataValidation": result.insert(.dataValidation)
            default: break
            }
        }
        return result
    }
}

/// A JSON scalar, because a sidecar's `value` is a number, a string, a boolean, or `null`.
public enum ExpectedValue: Sendable, Codable, Hashable {
    case number(Double)
    case string(String)
    case boolean(Bool)

    public var number: Double? { if case let .number(value) = self { value } else { nil } }
    public var string: String? { if case let .string(value) = self { value } else { nil } }
    public var boolean: Bool? { if case let .boolean(value) = self { value } else { nil } }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool before Double: JSONDecoder happily reads `true` as `1.0`, and a fixture asserting
        // TRUE would then be compared against a number.
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        }
    }
}

/// A sidecar's frozen-pane description.
public struct ExpectedFrozen: Sendable, Codable, Hashable {
    public var rows: Int?
    public var columns: Int?
    public var topLeftCell: String?
    public var state: String?

    public init(rows: Int? = nil, columns: Int? = nil, topLeftCell: String? = nil, state: String? = nil) {
        self.rows = rows
        self.columns = columns
        self.topLeftCell = topLeftCell
        self.state = state
    }
}

/// A sidecar's split-pane description, in twips as the file stores them.
public struct ExpectedSplit: Sendable, Codable, Hashable {
    public var xSplitTwips: Double?
    public var ySplitTwips: Double?
    public var topLeftCell: String?

    public init(xSplitTwips: Double? = nil, ySplitTwips: Double? = nil, topLeftCell: String? = nil) {
        self.xSplitTwips = xSplitTwips
        self.ySplitTwips = ySplitTwips
        self.topLeftCell = topLeftCell
    }
}

/// A sidecar's per-ZIP-entry digest.
public struct ExpectedZipEntry: Sendable, Codable, Hashable {
    public var sha256: String
    public var crc32: UInt32
    public var uncompressedSize: Int
    /// The ZIP compression method: `0` stored, `8` deflate.
    public var method: UInt16

    public init(sha256: String, crc32: UInt32, uncompressedSize: Int, method: UInt16) {
        self.sha256 = sha256
        self.crc32 = crc32
        self.uncompressedSize = uncompressedSize
        self.method = method
    }
}

/// A CSV sidecar's dialect.
public struct ExpectedCSVDialect: Sendable, Codable, Hashable {
    public var delimiter: String
    public var quote: String
    public var lineEnding: String
    public var encoding: String
    public var bom: Bool

    public init(delimiter: String, quote: String = "\"", lineEnding: String = "\n", encoding: String = "utf-8",
                bom: Bool = false) {
        self.delimiter = delimiter
        self.quote = quote
        self.lineEnding = lineEnding
        self.encoding = encoding
        self.bom = bom
    }

    /// The dialect as the model spells it, for the fields the model carries.
    public var resolved: CSVDialect {
        let ending: CSVDialect.LineEnding = switch lineEnding {
        case "\r\n": .crlf
        case "\r": .cr
        default: .lf
        }
        return CSVDialect(
            delimiter: delimiter.first ?? ",",
            quote: quote.first ?? "\"",
            lineEnding: ending,
            hasByteOrderMark: bom,
            encodingName: encoding
        )
    }
}
