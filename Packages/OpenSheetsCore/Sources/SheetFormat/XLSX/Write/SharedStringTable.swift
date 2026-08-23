//
//  SharedStringTable.swift
//  SheetFormat
//
//  `sharedStrings.xml` is append-only. Renumbering it corrupts every sheet we did not rewrite.
//

import Foundation
import SheetModel

/// The interned string table, as the writer manipulates it.
///
/// # Why this is append-only and not regenerated
///
/// A cell says `<c t="s"><v>7</v></c>`. The `7` is an index into `sharedStrings.xml`. Dirty
/// tracking is per part, so a save rewrites `sheet3.xml` and copies `sheet1.xml` through
/// untouched — which means every index `sheet1.xml` holds must still point at the same string
/// afterwards. Rebuilding the table from the strings currently in use renumbers it, and
/// `sheet1` starts displaying other people's text.
///
/// So: the original `<si>` elements are re-emitted **verbatim, in their original order**, new
/// strings are appended at the end, and only the two count attributes on `<sst>` change.
///
/// # Rich text survives by index reuse
///
/// The reader flattens `<si><r><t>Hello</t></r><r><rPr b="1"/><t>World</t></r></si>` to
/// `"HelloWorld"` and sets ``CellFlags/richText``. The model has nowhere to keep the runs. What
/// it does keep is the text, and the text is enough: looking `"HelloWorld"` up finds the
/// original entry's index, the cell re-points at it, and the bold half is still bold because the
/// entry itself was never touched. A cell whose text was actually *edited* finds no match, gets
/// a fresh plain entry, and loses its runs — which is correct, since its content is now
/// different text.
public struct SharedStringTable: Sendable {
    /// Flattened text to the index of the first `<si>` that produces it.
    private var indexByText: [String: Int]

    /// The original part, split so the `<si>` elements can be re-emitted byte for byte.
    private var original: ScannedXMLPart?

    /// Strings appended by this save, in the order they were requested.
    private var appended: [String] = []

    /// `<si>` elements the original part held.
    private var originalCount: Int

    /// The `count` attribute the original `<sst>` carried, which is a usage total rather than a
    /// unique-string total and which nothing can recompute without visiting every sheet.
    private var originalUsageCount: Int

    /// Whether this table is being built from nothing, for a package that has no `sharedStrings`
    /// part yet — a CSV saved as `.xlsx`, or `New Sheet`.
    private var isGenerating = false

    /// A table with no backing part. Text cells are written inline instead.
    ///
    /// Adding a `sharedStrings.xml` where the producer had none means adding an entry to
    /// `[Content_Types].xml` and a relationship to `xl/_rels/workbook.xml.rels`. Writing the
    /// text inline avoids touching the package structure at all, which is strictly safer and is
    /// exactly what a producer that omitted the part was already doing.
    public static let absent = SharedStringTable(indexByText: [:], original: nil, originalCount: 0, originalUsageCount: 0)

    private init(indexByText: [String: Int], original: ScannedXMLPart?, originalCount: Int, originalUsageCount: Int) {
        self.indexByText = indexByText
        self.original = original
        self.originalCount = originalCount
        self.originalUsageCount = originalUsageCount
    }

    /// An empty table that interns everything asked of it, for a package being built from
    /// scratch. The strings it collected come back out through ``generatedStrings``.
    public static var generating: SharedStringTable {
        var table = SharedStringTable(indexByText: [:], original: nil, originalCount: 0, originalUsageCount: 0)
        table.isGenerating = true
        return table
    }

    /// The strings interned by a ``generating`` table, in index order.
    public var generatedStrings: [String] { appended }

    /// Whether there is a table to write indexes into at all.
    public var isPresent: Bool { original != nil || isGenerating }

    /// Whether this save added anything, and the part therefore has to be re-emitted.
    public var hasAdditions: Bool { !appended.isEmpty }

    /// Total `<si>` elements after this save.
    public var count: Int { originalCount + appended.count }

    // MARK: - Loading

    /// Reads an existing `sharedStrings.xml`.
    public static func parsing(_ xml: String) throws(SheetError) -> SharedStringTable {
        let scanned = try WorksheetPartScanner.scan(xml, part: OOXMLPart.sharedStrings)
        var lookup: [String: Int] = [:]
        lookup.reserveCapacity(scanned.children.count)
        var index = 0
        for child in scanned.children where child.localName == "si" {
            let flattened = flatten(child.text)
            if lookup[flattened] == nil { lookup[flattened] = index }
            index += 1
        }
        let usage = XMLAttributeScanner.value(of: "count", inTag: scanned.rootOpenTag).flatMap { Int($0) } ?? index
        return SharedStringTable(
            indexByText: lookup,
            original: scanned,
            originalCount: index,
            originalUsageCount: usage
        )
    }

    // MARK: - Using

    /// The index for `text`, appending a new entry if the table does not already hold it.
    ///
    /// Returns `nil` when there is no table, which is the caller's signal to write the value as
    /// an inline string instead.
    public mutating func index(for text: String) -> Int? {
        guard isPresent else { return nil }
        if let existing = indexByText[text] { return existing }
        let index = count
        indexByText[text] = index
        appended.append(text)
        return index
    }

    // MARK: - Writing

    /// The part's new bytes, or `nil` when nothing was appended and it can be passed through.
    public func serialised(options: XLSXWriteOptions) throws(SheetError) -> String? {
        guard let original, hasAdditions else { return nil }

        var output = original.prolog
        output += patchedRootTag(original.rootOpenTag)
        for child in original.children {
            output += child.text
        }
        for (offset, text) in appended.enumerated() {
            let safe = try XLSXEscape.sanitiseCellText(
                text,
                policy: options.controlCharacters,
                ref: "sharedStrings.xml si[\(originalCount + offset)]"
            )
            output += "<si><t xml:space=\"preserve\">\(XLSXEscape.text(safe))</t></si>"
        }
        output += "</\(original.rootQualifiedName)>"
        return output
    }

    /// A brand-new `sharedStrings.xml` holding `strings` in order.
    ///
    /// Only for a workbook that had no such part and is being written from scratch — a CSV saved
    /// as `.xlsx`, or `New Sheet`.
    public static func newPart(strings: [String], options: XLSXWriteOptions) throws(SheetError) -> String {
        var output = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\r\n"
        output += "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" "
        output += "count=\"\(strings.count)\" uniqueCount=\"\(strings.count)\">"
        for (index, text) in strings.enumerated() {
            let safe = try XLSXEscape.sanitiseCellText(
                text, policy: options.controlCharacters, ref: "sharedStrings.xml si[\(index)]"
            )
            output += "<si><t xml:space=\"preserve\">\(XLSXEscape.text(safe))</t></si>"
        }
        output += "</sst>"
        return output
    }

    /// Rewrites `count` and `uniqueCount` on the `<sst>` tag, leaving every other attribute —
    /// including the namespace declarations — exactly where it was.
    private func patchedRootTag(_ tag: String) -> String {
        var result = tag
        result = XLSXAttributePatch.set("uniqueCount", to: "\(count)", in: result)
        // `count` is how many *cells* reference the table, which no single part knows. Growing
        // it by the number of strings we added keeps it monotonic and plausible; Excel treats it
        // as a hint and recomputes on save.
        result = XLSXAttributePatch.set("count", to: "\(originalUsageCount + appended.count)", in: result)
        return result
    }

    // MARK: - Flattening

    /// The plain text an `<si>` renders as: every `<t>` outside a `<rPh>`, concatenated.
    ///
    /// Phonetic runs are excluded deliberately. `<rPh>` holds the furigana above Japanese text,
    /// not the text itself, and folding it in would produce a string that matches nothing and
    /// silently appends a duplicate entry on every save.
    static func flatten(_ si: String) -> String {
        let bytes = Array(si.utf8)
        var result = ""
        var cursor = 0
        var phoneticDepth = 0

        while cursor < bytes.count {
            guard bytes[cursor] == UInt8(ascii: "<") else {
                cursor += 1
                continue
            }
            guard let tagEnd = WorksheetPartScanner.endOfTag(bytes, from: cursor) else { break }
            let tag = String(decoding: bytes[cursor ..< tagEnd], as: UTF8.self)
            let selfClosing = tag.hasSuffix("/>")
            let closing = tag.hasPrefix("</")
            let name = localName(of: tag)

            if name == "rPh" {
                if closing {
                    phoneticDepth = max(0, phoneticDepth - 1)
                } else if !selfClosing {
                    phoneticDepth += 1
                }
                cursor = tagEnd
                continue
            }
            if name == "t", !closing, !selfClosing, phoneticDepth == 0 {
                var scan = tagEnd
                while scan < bytes.count {
                    guard bytes[scan] == UInt8(ascii: "<") else {
                        scan += 1
                        continue
                    }
                    if scan + 4 <= bytes.count, bytes[scan + 1] == UInt8(ascii: "/") {
                        break
                    }
                    scan += 1
                }
                let raw = String(decoding: bytes[tagEnd ..< min(scan, bytes.count)], as: UTF8.self)
                result += XMLAttributeScanner.unescape(raw)
                cursor = scan
                continue
            }
            cursor = tagEnd
        }
        return result
    }

    private static func localName(of tag: String) -> String {
        var name = tag.dropFirst()
        if name.hasPrefix("/") { name = name.dropFirst() }
        let end = name.firstIndex { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "/" || $0 == ">" }
        let qualified = String(name[name.startIndex ..< (end ?? name.endIndex)])
        return qualified.contains(":") ? String(qualified.split(separator: ":").last ?? "") : qualified
    }
}

/// Setting one attribute on an existing open tag without disturbing the rest of it.
///
/// Used wherever the writer has to change a single value in a part it is otherwise copying —
/// `<sst count>`, `<calcPr fullCalcOnLoad>`, `<sheet name>`. Regenerating the whole tag would
/// mean regenerating its namespace declarations, and those are the one thing in an OOXML part
/// that absolutely must not change.
public enum XLSXAttributePatch {
    /// Replaces `name`'s value, or adds the attribute when it is absent.
    public static func set(_ name: String, to value: String, in tag: String) -> String {
        let escaped = XLSXEscape.attribute(value)
        let existing = XMLAttributeScanner.attributes(inTag: tag)
        guard existing.contains(where: { $0.name == name }) else {
            let selfClosing = tag.hasSuffix("/>")
            let body = String(tag.dropLast(selfClosing ? 2 : 1))
            return body + " \(name)=\"\(escaped)\"" + (selfClosing ? "/>" : ">")
        }
        // Rebuild by walking the original attribute list so ordering and spelling survive.
        var result = "<" + qualifiedName(of: tag)
        for attribute in existing {
            let text = attribute.name == name ? escaped : attribute.value
            result += " \(attribute.name)=\"\(text)\""
        }
        result += tag.hasSuffix("/>") ? "/>" : ">"
        return result
    }

    /// Removes an attribute if present.
    public static func remove(_ name: String, from tag: String) -> String {
        let existing = XMLAttributeScanner.attributes(inTag: tag)
        guard existing.contains(where: { $0.name == name }) else { return tag }
        var result = "<" + qualifiedName(of: tag)
        for attribute in existing where attribute.name != name {
            result += " \(attribute.name)=\"\(attribute.value)\""
        }
        result += tag.hasSuffix("/>") ? "/>" : ">"
        return result
    }

    private static func qualifiedName(of tag: String) -> String {
        let body = tag.dropFirst()
        let end = body.firstIndex { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "/" || $0 == ">" }
        return String(body[body.startIndex ..< (end ?? body.endIndex)])
    }
}
