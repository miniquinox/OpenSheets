import Foundation

/// Every style a workbook uses, interned so cells can carry a 4-byte id instead of a struct.
///
/// A million-cell sheet typically uses a few dozen distinct styles. Storing the style inline
/// would cost more than the values do; storing an id costs four bytes and makes equality a
/// single comparison.
///
/// # Ids are file positions
///
/// For a workbook read from disk, a ``StyleID``'s raw value **is** its `cellXfs` index in
/// `xl/styles.xml`. That is what lets `styles.xml` pass through byte-identical while every
/// cell's `s="…"` attribute stays correct. Styles created after parsing are appended, so ids
/// stay dense and ordered, and the writer only has to emit the tail.
///
/// # Number formats are still indirect
///
/// ``CellStyle`` flattens fonts, fills, borders, and alignment, but keeps
/// ``CellStyle/numberFormatID`` as an index. Two reasons: ids 0–49 are *implicit* — Excel
/// never writes them into the file and expects every reader to know them — and a workbook's
/// custom formats are shared across styles, so interning them separately is what the file
/// itself does.
public struct StyleTable: Sendable, Hashable, Codable {
    /// Styles by id. `styles[n]` is `StyleID(n)`. Never empty: index 0 is always the default.
    public private(set) var styles: [CellStyle]

    /// Custom format codes from `<numFmts>`, keyed by their `numFmtId`. Built-in ids are not
    /// stored here — they resolve through ``NumberFormat/builtInCode(id:)``.
    public private(set) var customNumberFormats: [Int32: NumberFormat]

    /// The colours a ``StyleColor`` resolves against. Read from `xl/theme/theme1.xml` when the
    /// workbook ships one, otherwise Office's defaults.
    public var palette: ColorPalette

    /// Dedupes styles on ``intern(_:)``. Rebuilt on decode rather than encoded.
    private var lookup: [CellStyle: StyleID]

    /// A table with only the default style.
    public init() {
        styles = [.default]
        customNumberFormats = [:]
        palette = .office
        lookup = [.default: .default]
    }

    /// A table built from a parsed `styles.xml`, preserving index order exactly.
    ///
    /// Pass the `cellXfs` rows in file order. If the list is empty a default style is
    /// inserted, because a cell with no `s` attribute has to resolve to something.
    public init(
        styles: [CellStyle],
        customNumberFormats: [Int32: NumberFormat] = [:],
        palette: ColorPalette = .office
    ) {
        self.styles = styles.isEmpty ? [.default] : styles
        self.customNumberFormats = customNumberFormats
        self.palette = palette
        lookup = [:]
        for (index, style) in self.styles.enumerated() where lookup[style] == nil {
            lookup[style] = StyleID(rawValue: Int32(index))
        }
    }

    /// A table with only the default style.
    public static let empty = StyleTable()

    // MARK: - Reading

    /// The style for `id`, falling back to the default for an id that is not in the table.
    ///
    /// Falls back rather than trapping because a file can reference a style it does not
    /// define, and refusing to open the workbook over that is a worse outcome than rendering
    /// one cell plainly. Use ``style(for:)`` where the caller wants to know.
    public subscript(id: StyleID) -> CellStyle {
        let index = Int(id.rawValue)
        return styles.indices.contains(index) ? styles[index] : .default
    }

    /// The style for `id`, throwing when it is not in the table.
    public func style(for id: StyleID) throws(SheetError) -> CellStyle {
        let index = Int(id.rawValue)
        guard styles.indices.contains(index) else {
            throw SheetError.unknownStyleID(rawValue: id.rawValue)
        }
        return styles[index]
    }

    /// How many distinct styles the workbook has.
    public var count: Int { styles.count }

    /// The format code for a `numFmtId`, custom first, then built-in, then `General`.
    ///
    /// Built-ins are resolved from a table parsed once, not re-parsed per call. This is called
    /// once per visible cell per frame by the renderer, and parsing a format code there cost
    /// GridKit its entire 8.3 ms frame budget until it was found — 9 ms per frame with a third of
    /// frames over budget, from a function that looks like a dictionary lookup.
    public func numberFormat(id: Int32) -> NumberFormat {
        if let custom = customNumberFormats[id] { return custom }
        return NumberFormat.builtIn(id: id) ?? .general
    }

    /// The format a cell with this style renders through.
    public func numberFormat(for id: StyleID) -> NumberFormat {
        numberFormat(id: self[id].numberFormatID)
    }

    /// Whether a cell with this style shows its number as a date.
    ///
    /// The only way to know a cell holds a date, since xlsx stores dates as plain numbers.
    public func isDateTime(_ id: StyleID) -> Bool {
        numberFormat(for: id).isDateTime
    }

    // MARK: - Writing

    /// Returns the id for `style`, adding it if it is new.
    ///
    /// Deduplicating is what keeps `cellXfs` from growing by one row per formatted cell —
    /// which is what naive writers do, and why their files open slowly.
    public mutating func intern(_ style: CellStyle) -> StyleID {
        if let existing = lookup[style] { return existing }
        let id = StyleID(rawValue: Int32(styles.count))
        styles.append(style)
        lookup[style] = id
        return id
    }

    /// Interns `format`, returning its `numFmtId`.
    ///
    /// Built-in codes reuse their reserved id so the file stays compact; anything else gets
    /// the next free id at or above ``NumberFormat/firstCustomFormatID``.
    public mutating func internNumberFormat(_ format: NumberFormat) -> Int32 {
        for id in Int32(0) ... 49 where NumberFormat.builtInCode(id: id) == format.formatCode {
            return id
        }
        if let existing = customNumberFormats.first(where: { $0.value.formatCode == format.formatCode }) {
            return existing.key
        }
        let next = max(NumberFormat.firstCustomFormatID, (customNumberFormats.keys.max() ?? 0) + 1)
        customNumberFormats[next] = format
        return next
    }

    /// Returns the id of `style` with a different number format, interning as needed.
    ///
    /// The shape almost every restyling operation actually wants: change one facet of an
    /// existing style rather than build one from nothing.
    public mutating func derive(_ id: StyleID, _ transform: (inout CellStyle) -> Void) -> StyleID {
        var style = self[id]
        transform(&style)
        return intern(style)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case styles, customNumberFormats, palette
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(styles, forKey: .styles)
        try container.encode(
            customNumberFormats.map { StoredFormat(id: $0.key, format: $0.value) }.sorted { $0.id < $1.id },
            forKey: .customNumberFormats
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFormats = try container.decodeIfPresent([StoredFormat].self, forKey: .customNumberFormats) ?? []
        self.init(
            styles: try container.decodeIfPresent([CellStyle].self, forKey: .styles) ?? [],
            customNumberFormats: Dictionary(uniqueKeysWithValues: decodedFormats.map { ($0.id, $0.format) })
        )
    }

    /// `[Int32: NumberFormat]` would encode as a JSON object with numeric keys, which is legal
    /// but reads badly in a fixture sidecar. A list of pairs is clearer.
    private struct StoredFormat: Codable {
        let id: Int32
        let format: NumberFormat
    }

    // MARK: - Equality

    /// Compares the tables' contents. ``lookup`` is a derived index and is excluded.
    public static func == (lhs: StyleTable, rhs: StyleTable) -> Bool {
        lhs.styles == rhs.styles && lhs.customNumberFormats == rhs.customNumberFormats && lhs.palette == rhs.palette
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(styles)
        hasher.combine(customNumberFormats)
    }
}

extension StyleTable: CustomStringConvertible {
    public var description: String {
        "StyleTable(\(styles.count) styles, \(customNumberFormats.count) custom formats)"
    }
}
