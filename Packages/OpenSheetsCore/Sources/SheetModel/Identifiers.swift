import Foundation

/// A sheet's stable identity within a workbook.
///
/// Wraps the `sheetId` attribute from `xl/workbook.xml`, which Excel keeps stable across
/// renames and reorders. That stability is what lets the diff engine say *"Sheet1 was renamed
/// to Q4"* instead of *"one sheet vanished and another appeared"* (PLAN.md §6.4).
///
/// A CSV has no such concept; the reader assigns `1`.
public struct SheetID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByIntegerLiteral {
    public var rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }
    public init(_ rawValue: Int32) { self.rawValue = rawValue }
    public init(integerLiteral value: Int32) { rawValue = value }
}

extension SheetID: Comparable {
    /// Orders by the underlying id, which is **not** tab order — use ``Workbook/sheets``
    /// for that. This exists so ids can be sorted for stable output.
    public static func < (lhs: SheetID, rhs: SheetID) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension SheetID: CustomStringConvertible {
    public var description: String { "sheet#\(rawValue)" }
}

/// An index into ``StyleTable/styles``.
///
/// For a workbook read from disk this **is** the `cellXfs` index from `xl/styles.xml`, which
/// is what makes byte-identical passthrough of `styles.xml` possible: as long as nobody
/// restyles anything, every cell's `s="…"` attribute round-trips unchanged. Styles created
/// after parsing are appended, so their ids continue the same sequence.
///
/// Do not rely on that outside `SheetFormat`. Everywhere else it is an opaque token.
public struct StyleID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByIntegerLiteral {
    public var rawValue: Int32

    public init(rawValue: Int32) { self.rawValue = rawValue }
    public init(_ rawValue: Int32) { self.rawValue = rawValue }
    public init(integerLiteral value: Int32) { rawValue = value }

    /// Index 0 — the style every cell has unless it says otherwise. Always present in a
    /// ``StyleTable``, including an empty one.
    public static let `default` = StyleID(rawValue: 0)
}

extension StyleID: Comparable {
    /// Orders by index, which for a workbook read from disk is also file order.
    public static func < (lhs: StyleID, rhs: StyleID) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension StyleID: CustomStringConvertible {
    public var description: String { "style#\(rawValue)" }
}
