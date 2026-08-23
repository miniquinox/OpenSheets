//
//  SharedStringsReader.swift
//  SheetFormat
//
//  A1 owns this file. `xl/sharedStrings.xml`, interned once into a flat array.
//

import Foundation

import SheetModel

/// The workbook's string table.
///
/// Interned once and shared by every sheet task, because that is the whole point of the part:
/// a hundred thousand cells reading `t="s"` should cost a hundred thousand *index lookups*, not
/// a hundred thousand `String` allocations. `SharedStrings` is a `Sendable` value with COW
/// storage, so handing the same one to eight concurrent sheet parsers copies nothing.
public struct SharedStrings: Sendable {
    /// Strings in file order. A cell's `<v>` is an index into this.
    public var values: [String]

    /// Which entries were rich text — `<si>` containing `<r>` runs — flattened to plain text.
    ///
    /// The cells that use them carry ``SheetModel/CellFlags/richText`` so the writer knows to
    /// leave the original `<si>` alone instead of re-emitting plain text and destroying
    /// bold-inside-a-cell.
    public var isRichText: [Bool]

    public init(values: [String] = [], isRichText: [Bool] = []) {
        self.values = values
        self.isRichText = isRichText
    }

    /// The string at `index`, or `nil` when the file references one that is not there.
    public subscript(index: Int) -> String? {
        values.indices.contains(index) ? values[index] : nil
    }

    /// Whether the entry at `index` was rich text.
    public func isRich(_ index: Int) -> Bool {
        isRichText.indices.contains(index) ? isRichText[index] : false
    }

    /// No strings at all — what a workbook with only inline strings has.
    public static let empty = SharedStrings()
}

/// Parses `xl/sharedStrings.xml`.
public enum SharedStringsReader {
    public static func read(_ bytes: [UInt8], part: String) throws(SheetError) -> SharedStrings {
        try XMLParsing.withParser(over: bytes, part: part) { parser throws(SheetError) in
            var values: [String] = []
            var rich: [Bool] = []

            while let event = try parser.next() {
                guard event == .startElement else { continue }
                if parser.nameIs("sst") {
                    // `uniqueCount` is a hint. Trusting it for a reservation is fine; trusting it
                    // for anything else is not, because it is routinely wrong.
                    if let count = parser.attribute("uniqueCount")?.int, count > 0, count < 1 << 22 {
                        values.reserveCapacity(count)
                        rich.reserveCapacity(count)
                    }
                    continue
                }
                guard parser.nameIs("si") else { continue }
                let item = try readStringItem(&parser)
                values.append(item.text)
                rich.append(item.hasRuns)
            }
            return SharedStrings(values: values, isRichText: rich)
        }
    }

    /// Reads one `CT_Rst` — a `<si>` in the string table or an `<is>` inside a cell.
    ///
    /// The parser must be positioned on the container's start tag. Returns the flattened text
    /// and whether it came from formatting runs.
    ///
    /// **`<rPh>` is skipped.** Phonetic guides (furigana) sit inside `<si>` as `<rPh><t>`, and a
    /// reader that concatenates every `<t>` it sees turns a Japanese cell into its text followed
    /// by its own pronunciation.
    static func readStringItem(_ parser: inout XMLPullParser) throws(SheetError) -> (text: String, hasRuns: Bool) {
        let target = parser.depth - 1
        var text = ""
        var hasRuns = false
        var insideText = false

        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("t") {
                    insideText = true
                } else if parser.nameIs("r") {
                    hasRuns = true
                } else if parser.nameIs("rPh") || parser.nameIs("phoneticPr") || parser.nameIs("rPr") {
                    try parser.skipElement()
                }
            case .characters:
                // Never trimmed. `xml:space="preserve"` is common and the whitespace is data;
                // trimming it is a silent edit that survives every later save.
                if insideText { text += try parser.text.cellText() }
            case .endElement:
                if parser.nameIs("t") { insideText = false }
                if parser.depth == target { return (text, hasRuns) }
            }
        }
        throw SheetError.xmlMalformed(part: parser.part, line: nil, detail: "a string item is not closed")
    }
}
