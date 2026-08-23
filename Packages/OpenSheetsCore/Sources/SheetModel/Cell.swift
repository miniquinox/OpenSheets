import Foundation

/// Things worth knowing about a cell that are not its value, its formula, or its style.
///
/// Every flag here exists so something downstream can be **honest with the user** rather than
/// guess. A stale cached value rendered as if it were fresh is worse than one rendered with a
/// dotted underline and a tooltip saying why (PLAN.md §5.3).
public struct CellFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// This cell's inputs changed but we could not recompute it, so ``Cell/value`` is the old
    /// cached result. Rendered with a dotted underline. **Never silently cleared** — clearing
    /// it means claiming a number we did not compute.
    public static let staleCache = CellFlags(rawValue: 1 << 0)

    /// The formula reaches into another workbook (`[1]Sheet1!A1`). We never resolve or fetch
    /// one (PLAN.md §7.3); the flag lets the UI say so.
    public static let externalLink = CellFlags(rawValue: 1 << 1)

    /// The formula parses but uses a function outside our ~120. It round-trips untouched and
    /// keeps its cached value; we do not approximate it.
    public static let unsupportedFormula = CellFlags(rawValue: 1 << 2)

    /// Part of an array formula. The master cell also appears in
    /// ``Sheet/arrayFormulaRanges``. Editing one cell of an array formula is illegal in Excel
    /// and must be refused here too, or the file stops opening.
    public static let arrayFormula = CellFlags(rawValue: 1 << 3)

    /// The formula came from a shared-formula group and was expanded from its master. Purely
    /// informational: the expansion is already in ``Cell/formula``.
    public static let sharedFormulaExpansion = CellFlags(rawValue: 1 << 4)

    /// This cell has an entry in ``Sheet/hyperlinks``.
    public static let hyperlink = CellFlags(rawValue: 1 << 5)

    /// The shared string behind this text had formatting runs (`<r><t>`) that we flattened.
    /// The writer must leave the original string alone rather than re-emit plain text, or
    /// bold-inside-a-cell is silently destroyed.
    public static let richText = CellFlags(rawValue: 1 << 6)

    /// The value was stored as an inline string rather than a shared string. Kept so the
    /// writer can re-emit the producer's choice instead of reshuffling the string table.
    public static let inlineString = CellFlags(rawValue: 1 << 7)

    /// This cell has a comment or threaded note attached, which lives in a part we pass
    /// through rather than model.
    public static let comment = CellFlags(rawValue: 1 << 8)

    /// A data-validation rule covers this cell. We do not enforce it; we mark it so an edit
    /// can warn instead of silently producing a file Excel complains about.
    public static let dataValidation = CellFlags(rawValue: 1 << 9)

    /// Nothing special.
    public static let none: CellFlags = []
}

/// One cell: a value, optionally a formula, a style, and some honesty flags.
///
/// For a formula cell, ``value`` is the **cached result** — the `<v>` Excel wrote next to the
/// `<f>`. That is what makes PLAN.md §5.3 work: a workbook renders correctly with zero
/// evaluation, and the engine only runs on what someone edits.
///
/// About 48 bytes. A million of them is roughly 48 MB, which is the budget PLAN.md §10.6
/// assumes.
public struct Cell: Sendable, Hashable, Codable {
    /// The value, or the cached result of ``formula``.
    public var value: CellValue

    /// Formula source text **without the leading `=`**, or `nil` for a literal cell.
    ///
    /// No `=` because that is how xlsx stores it and how every consumer wants it; the `=` is
    /// a UI affordance that belongs in the formula bar.
    public var formula: String?

    /// Index into the workbook's ``StyleTable``.
    public var styleID: StyleID

    /// See ``CellFlags``.
    public var flags: CellFlags

    public init(
        value: CellValue = .empty,
        formula: String? = nil,
        styleID: StyleID = .default,
        flags: CellFlags = []
    ) {
        self.value = value
        self.formula = formula
        self.styleID = styleID
        self.flags = flags
    }

    /// Whether this cell holds a formula.
    public var isFormula: Bool { formula != nil }

    /// Whether this cell would be indistinguishable from an absent one.
    ///
    /// The store keeps such cells rather than dropping them, because a styled empty cell is
    /// real: a whole column formatted as currency has no values and must still round-trip.
    public var isBlank: Bool {
        value == .empty && formula == nil && styleID == .default && flags.isEmpty
    }

    // MARK: - Shorthands

    /// A literal number.
    public static func number(_ value: Double, styleID: StyleID = .default) -> Cell {
        Cell(value: .number(value), styleID: styleID)
    }

    /// A literal string.
    public static func text(_ value: String, styleID: StyleID = .default) -> Cell {
        Cell(value: .text(value), styleID: styleID)
    }

    /// A literal boolean.
    public static func boolean(_ value: Bool, styleID: StyleID = .default) -> Cell {
        Cell(value: .boolean(value), styleID: styleID)
    }

    /// A cached error.
    public static func error(_ value: CellError, styleID: StyleID = .default) -> Cell {
        Cell(value: .error(value), styleID: styleID)
    }

    /// A formula and its cached result. `source` must not include the leading `=`.
    public static func formula(
        _ source: String,
        cached: CellValue = .empty,
        styleID: StyleID = .default,
        flags: CellFlags = []
    ) -> Cell {
        Cell(value: cached, formula: source, styleID: styleID, flags: flags)
    }

    /// An empty cell carrying only formatting.
    public static func styled(_ styleID: StyleID) -> Cell {
        Cell(value: .empty, styleID: styleID)
    }
}

extension Cell: CustomStringConvertible {
    public var description: String {
        var parts = [value.description]
        if let formula { parts.append("=\(formula)") }
        if styleID != .default { parts.append(styleID.description) }
        if !flags.isEmpty { parts.append("flags:\(flags.rawValue)") }
        return parts.joined(separator: " ")
    }
}
