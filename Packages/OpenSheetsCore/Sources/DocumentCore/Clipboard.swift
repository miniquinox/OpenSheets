#if canImport(AppKit)
import AppKit
#endif
import Foundation
import SheetModel

/// A rectangle of cells on the pasteboard.
///
/// Written **twice**: once as TSV so it pastes into Excel, Numbers, a terminal and a text field,
/// and once as this type's own JSON so an in-app paste keeps formulas, number formats, fonts and
/// fills. A clipboard that only carries text turns `=SUM(A1:A9)` into `1284905.28` the moment it
/// crosses a window boundary, and that is a data-losing paste that looks like it worked.
public struct ClipboardPayload: Sendable, Codable, Hashable {
    /// The shape of the copied block.
    public var rowCount: Int
    public var columnCount: Int
    /// The top-left of the source, so formulas can be translated on paste.
    public var origin: CellRef
    /// Row-major, `nil` for a blank cell.
    public var cells: [Cell?]
    /// The styles the cells refer to, re-interned into the destination workbook on paste.
    public var styles: [StyleID: CellStyle]
    /// Merges wholly inside the copied block, relative to ``origin``.
    public var merges: [CellRange]
    /// True when the copy was a Cut, so the source is cleared once the paste lands.
    public var wasCut: Bool

    public init(
        rowCount: Int,
        columnCount: Int,
        origin: CellRef,
        cells: [Cell?],
        styles: [StyleID: CellStyle] = [:],
        merges: [CellRange] = [],
        wasCut: Bool = false
    ) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.origin = origin
        self.cells = cells
        self.styles = styles
        self.merges = merges
        self.wasCut = wasCut
    }

    /// The pasteboard type for the rich form. Reverse-DNS, versioned, because a v0.2 that changes
    /// the shape must not be silently decoded by a running v0.1.
    public static let pasteboardType = "com.quino.opensheets.cells.v1"

    public subscript(row: Int, column: Int) -> Cell? {
        guard row >= 0, row < rowCount, column >= 0, column < columnCount else { return nil }
        return cells[row * columnCount + column]
    }

    /// Builds a payload from a range.
    public static func capture(
        _ range: CellRange,
        from sheet: Sheet,
        styles table: SheetModel.StyleTable,
        wasCut: Bool = false
    ) -> ClipboardPayload {
        var cells: [Cell?] = []
        cells.reserveCapacity(range.cellCount)
        var used: [StyleID: CellStyle] = [:]
        for row in range.rows {
            for column in range.columns {
                let cell = sheet.cells[CellRef(row: row, column: column)]
                if let cell, cell.styleID != .default { used[cell.styleID] = table[cell.styleID] }
                cells.append(cell)
            }
        }
        let merges = sheet.merges
            .filter { range.contains($0) }
            .map { $0.offset(rows: -range.start.row, columns: -range.start.column) }
        return ClipboardPayload(
            rowCount: range.rowCount,
            columnCount: range.columnCount,
            origin: range.start,
            cells: cells,
            styles: used,
            merges: merges,
            wasCut: wasCut
        )
    }

    /// Tab-separated text, one line per row, for everything that is not us.
    public func tabSeparatedText(displaying render: (Cell?) -> String) -> String {
        var lines: [String] = []
        lines.reserveCapacity(rowCount)
        for row in 0 ..< rowCount {
            var fields: [String] = []
            fields.reserveCapacity(columnCount)
            for column in 0 ..< columnCount {
                var text = render(self[row, column])
                // A tab or a newline inside a cell would break the row/column structure, so it is
                // quoted the way every TSV consumer expects rather than stripped.
                if text.contains("\t") || text.contains("\n") || text.contains("\"") {
                    text = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                fields.append(text)
            }
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// Parses pasted text into a block of literal cells.
    ///
    /// Values go through ``CellInputParser`` for exactly the same reason a typed cell does: a
    /// pasted `#N/A` is an error value, a pasted `50%` is `0.5`, and a pasted `=A1+1` is a
    /// formula. Anything else would make paste and typing disagree about the same characters.
    public static func parsingText(
        _ text: String,
        at origin: CellRef,
        dateSystem: DateSystem = .excel1900,
        locale: Locale = .autoupdatingCurrent
    ) -> ClipboardPayload? {
        let rows = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing newline is a line terminator, not an empty row.
        var lines = rows.map(String.init)
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        let split = lines.map { $0.components(separatedBy: "\t") }
        let columnCount = split.map(\.count).max() ?? 1
        var cells: [Cell?] = []
        cells.reserveCapacity(lines.count * columnCount)
        for fields in split {
            for column in 0 ..< columnCount {
                guard column < fields.count, !fields[column].isEmpty else {
                    cells.append(nil)
                    continue
                }
                let parsed = CellInputParser.parse(
                    fields[column], dateSystem: dateSystem, locale: locale
                )
                cells.append(Cell(value: parsed.value, formula: parsed.formula))
            }
        }
        return ClipboardPayload(
            rowCount: lines.count, columnCount: columnCount, origin: origin, cells: cells
        )
    }
}

#if canImport(AppKit)
/// Reading and writing the system pasteboard.
@MainActor
public enum Clipboard {
    public static func write(
        _ payload: ClipboardPayload,
        text: String,
        to pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let data = try? JSONEncoder().encode(payload) {
            pasteboard.setData(data, forType: .init(ClipboardPayload.pasteboardType))
        }
    }

    /// The richest form on the pasteboard. Our own type first, then text.
    public static func read(
        at origin: CellRef,
        dateSystem: DateSystem = .excel1900,
        from pasteboard: NSPasteboard = .general
    ) -> ClipboardPayload? {
        if let data = pasteboard.data(forType: .init(ClipboardPayload.pasteboardType)),
           let payload = try? JSONDecoder().decode(ClipboardPayload.self, from: data)
        {
            return payload
        }
        guard let text = pasteboard.string(forType: .string) else { return nil }
        return ClipboardPayload.parsingText(text, at: origin, dateSystem: dateSystem)
    }

    /// Whether a paste would do anything. Drives the toolbar's enabled state.
    public static func hasContent(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.data(forType: .init(ClipboardPayload.pasteboardType)) != nil
            || pasteboard.string(forType: .string) != nil
    }
}
#endif
