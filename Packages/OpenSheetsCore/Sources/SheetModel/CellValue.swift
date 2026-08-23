import Foundation

/// One of the seven values Excel can put in a cell, plus our own `#CIRCULAR`.
///
/// The raw value is the token Excel displays and stores, so parsing a cached error out of
/// `<c t="e"><v>#DIV/0!</v></c>` is just `CellError(rawValue:)`.
public enum CellError: String, Sendable, Hashable, CaseIterable, Codable {
    /// Division by zero, or by an empty cell.
    case divideByZero = "#DIV/0!"
    /// A reference to a cell that no longer exists, usually after a delete.
    case invalidReference = "#REF!"
    /// An unrecognised function or defined name.
    case unknownName = "#NAME?"
    /// An argument of the wrong type.
    case wrongType = "#VALUE!"
    /// A lookup found nothing.
    case notAvailable = "#N/A"
    /// An empty intersection between two ranges.
    case nullIntersection = "#NULL!"
    /// A numeric result that is not representable — overflow, or a root of a negative.
    case invalidNumber = "#NUM!"
    /// A dynamic-array result with nowhere to spill. We never produce one; we can read one.
    case spill = "#SPILL!"
    /// Excel 365's catch-all for a calculation engine refusal. Read-only for us.
    case calculation = "#CALC!"

    /// A dependency cycle, reported per participating cell.
    ///
    /// **This is ours, not Excel's.** Excel shows `0` and a status-bar warning; we would
    /// rather say so in the cell (PLAN.md §5.3). It has no xlsx spelling, which means the
    /// writer must not emit it — see ``xlsxToken``.
    case circular = "#CIRCULAR"

    /// Whether Excel itself knows this token. `false` only for ``circular``.
    public var isExcelNative: Bool { self != .circular }

    /// What to write into an xlsx file for this error.
    ///
    /// Everything maps to itself except ``circular``, which becomes `#VALUE!` because Excel
    /// would refuse to open a file containing `#CIRCULAR`. The writer should prefer keeping
    /// the cell's previous cached value over emitting this at all — a circular reference is
    /// our diagnosis of the user's edit, not a fact about the file.
    public var xlsxToken: String { self == .circular ? "#VALUE!" : rawValue }
}

/// The value in a cell.
///
/// For a formula cell this is the **cached result**, not the formula — see ``Cell/formula``.
/// That split is the whole reason OpenSheets can render a correct workbook without evaluating
/// anything (PLAN.md §5.3).
///
/// There is deliberately **no `date` case**. Excel has no date type: a date is a `number`
/// holding a serial day count, interpreted by the cell's number format. Modelling it any other
/// way means inventing a conversion Excel does not do, and then disagreeing with Excel about
/// what `=A1+1` means. Use ``SerialDate`` to convert at the display boundary.
public enum CellValue: Sendable, Hashable {
    /// No value. Distinct from `.text("")`: an empty cell is skipped by `COUNT`, an empty
    /// string is not.
    case empty
    /// A number. Dates, times, currency, and percentages are all numbers plus a format.
    case number(Double)
    /// Text. Rich-text runs from `sharedStrings.xml` are flattened; see ``CellFlags/richText``.
    case text(String)
    /// `TRUE` or `FALSE`.
    case boolean(Bool)
    /// An error token, cached or computed.
    case error(CellError)

    /// Whether this is ``empty``.
    public var isEmpty: Bool { self == .empty }

    /// Whether this is an ``error(_:)``.
    public var isError: Bool { if case .error = self { true } else { false } }

    /// The number, with **no coercion**. `.text("42")` gives `nil`, not `42`.
    ///
    /// Excel's text-to-number coercion is context-dependent and belongs in the formula
    /// engine, where the rules for `"42"+1` versus `SUM("42")` differ. A plain accessor that
    /// quietly coerced would produce wrong answers somewhere else.
    public var number: Double? { if case let .number(value) = self { value } else { nil } }

    /// The text, with no coercion.
    public var text: String? { if case let .text(value) = self { value } else { nil } }

    /// The boolean, with no coercion.
    public var boolean: Bool? { if case let .boolean(value) = self { value } else { nil } }

    /// The error token, if this is one.
    public var error: CellError? { if case let .error(value) = self { value } else { nil } }

    /// Two values are equal when they are the same case with the same payload — except that
    /// two NaNs count as equal.
    ///
    /// IEEE says `NaN != NaN`. That is right for arithmetic and wrong here: it would make an
    /// untouched cell show up in every diff and defeat the self-write suppressor. Excel never
    /// stores NaN, so this only matters for damaged files, but "damaged file causes an
    /// infinite refresh loop" is a bug we can just not have.
    public static func == (lhs: CellValue, rhs: CellValue) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): true
        case let (.number(a), .number(b)): a == b || (a.isNaN && b.isNaN)
        case let (.text(a), .text(b)): a == b
        case let (.boolean(a), .boolean(b)): a == b
        case let (.error(a), .error(b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .empty:
            hasher.combine(0 as UInt8)
        case let .number(value):
            hasher.combine(1 as UInt8)
            hasher.combine(value.isNaN ? Double.nan.bitPattern : value.bitPattern)
        case let .text(value):
            hasher.combine(2 as UInt8)
            hasher.combine(value)
        case let .boolean(value):
            hasher.combine(3 as UInt8)
            hasher.combine(value)
        case let .error(value):
            hasher.combine(4 as UInt8)
            hasher.combine(value)
        }
    }
}

extension CellValue: CustomStringConvertible {
    /// A debug spelling, **not** a display spelling. Formatting a value for the grid needs the
    /// cell's ``NumberFormat`` and is A4's job; this is what shows up in a test failure.
    public var description: String {
        switch self {
        case .empty: "<empty>"
        case let .number(value): String(value)
        case let .text(value): "\"\(value)\""
        case let .boolean(value): value ? "TRUE" : "FALSE"
        case let .error(value): value.rawValue
        }
    }
}

// MARK: - JSON

extension CellValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type = "t"
        case value = "v"
    }

    /// Tagged with the same letters xlsx uses for `<c t="…">`, so a fixture sidecar reads the
    /// way the file does: `{"t":"n","v":42}`, `{"t":"s","v":"hi"}`, `{"t":"z"}` for empty.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            try container.encode("z", forKey: .type)
        case let .number(value):
            try container.encode("n", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .text(value):
            try container.encode("s", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .boolean(value):
            try container.encode("b", forKey: .type)
            try container.encode(value, forKey: .value)
        case let .error(value):
            try container.encode("e", forKey: .type)
            try container.encode(value.rawValue, forKey: .value)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "z":
            self = .empty
        case "n":
            self = .number(try container.decode(Double.self, forKey: .value))
        case "s":
            self = .text(try container.decode(String.self, forKey: .value))
        case "b":
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        case "e":
            let token = try container.decode(String.self, forKey: .value)
            guard let error = CellError(rawValue: token) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "'\(token)' is not a cell error token"
                )
            }
            self = .error(error)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "'\(other)' is not a cell value type"
            )
        }
    }
}

// MARK: - Literals

extension CellValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}
