//
//  WorksheetPartScanner.swift
//  SheetFormat
//
//  Splitting an existing XML part into verbatim top-level slices, so the writer can put back
//  everything it did not understand.
//

import Foundation
import SheetModel

/// One top-level child element, kept exactly as it was written.
public struct XMLElementSlice: Sendable, Hashable {
    /// The name without its prefix — `conditionalFormatting`, not `x:conditionalFormatting`.
    public var localName: String
    /// The name as written, prefix included.
    public var qualifiedName: String
    /// The element's own bytes: open tag, content, close tag. Never re-escaped or reformatted.
    public var text: String

    public init(localName: String, qualifiedName: String, text: String) {
        self.localName = localName
        self.qualifiedName = qualifiedName
        self.text = text
    }
}

/// An XML part split into the pieces a surgical rewrite needs.
public struct ScannedXMLPart: Sendable {
    /// Everything before the root element — the declaration, any comments — kept verbatim.
    public var prolog: String
    /// The root element's open tag, verbatim.
    ///
    /// **This is the piece that must not be regenerated.** It carries the namespace
    /// declarations (`xmlns:r`, `xmlns:mc`, `xmlns:x14ac`) and the `mc:Ignorable` list that
    /// every prefixed element deeper in the part resolves against. Emit a tidied-up root tag
    /// and a perfectly preserved `<extLst>` underneath it stops being well-formed.
    public var rootOpenTag: String
    /// The root's local name.
    public var rootName: String
    /// The root's qualified name, so a replacement close tag matches.
    public var rootQualifiedName: String
    /// The top-level children, in document order.
    public var children: [XMLElementSlice]

    public init(
        prolog: String,
        rootOpenTag: String,
        rootName: String,
        rootQualifiedName: String,
        children: [XMLElementSlice]
    ) {
        self.prolog = prolog
        self.rootOpenTag = rootOpenTag
        self.rootName = rootName
        self.rootQualifiedName = rootQualifiedName
        self.children = children
    }

    /// The first child with this local name.
    public func child(named localName: String) -> XMLElementSlice? {
        children.first { $0.localName == localName }
    }

    /// Local names present at the top level.
    public var childNames: Set<String> {
        Set(children.map(\.localName))
    }
}

/// Splits an XML part into verbatim top-level slices.
///
/// # Why a hand-written scanner and not `XMLParser`
///
/// A DOM or event parser gives you *values*: it resolves entities, normalises attribute
/// whitespace, forgets attribute order, and forgets which prefix was used. Re-serialising from
/// that is how a "lossless" writer quietly rewrites half of someone's file. This scanner never
/// interprets anything — it finds element boundaries and hands back the original bytes between
/// them.
///
/// It is only ever pointed at parts we are already rewriting, and it refuses a DTD outright, so
/// the entity-expansion attacks in the hostile corpus have nothing to expand into.
public enum WorksheetPartScanner {
    /// Splits `xml` into prolog, root tag and top-level children.
    ///
    /// Whitespace and comments *between* top-level children are dropped: they carry no
    /// information and keeping them would force the writer to guess where they belong once the
    /// children are re-ordered into schema sequence.
    public static func scan(_ xml: String, part: String) throws(SheetError) -> ScannedXMLPart {
        let bytes = Array(xml.utf8)
        let count = bytes.count
        var cursor = 0

        // --- prolog ------------------------------------------------------------------------
        while cursor < count {
            guard bytes[cursor] == UInt8(ascii: "<") else {
                cursor += 1
                continue
            }
            if matches(bytes, at: cursor, "<!--") {
                guard let end = find(bytes, from: cursor + 4, "-->") else {
                    throw SheetError.xmlMalformed(part: part, line: nil, detail: "unterminated comment")
                }
                cursor = end + 3
                continue
            }
            if matches(bytes, at: cursor, "<?") {
                guard let end = find(bytes, from: cursor + 2, "?>") else {
                    throw SheetError.xmlMalformed(part: part, line: nil, detail: "unterminated processing instruction")
                }
                cursor = end + 2
                continue
            }
            if matches(bytes, at: cursor, "<!") {
                // A DOCTYPE in a part we are about to rewrite. PLAN.md §7.4 says the policy is
                // blanket, and a writer that quietly re-emits one is a bypass of the reader's.
                throw SheetError.xmlDocumentTypeRejected(part: part)
            }
            break
        }
        guard cursor < count else {
            throw SheetError.xmlMalformed(part: part, line: nil, detail: "the part has no root element")
        }
        let prolog = string(bytes, 0 ..< cursor)

        // --- root open tag -----------------------------------------------------------------
        guard let rootTagEnd = endOfTag(bytes, from: cursor) else {
            throw SheetError.xmlMalformed(part: part, line: nil, detail: "unterminated root element tag")
        }
        let rootOpenTag = string(bytes, cursor ..< rootTagEnd)
        let (rootQualified, rootLocal) = elementName(bytes, tagStart: cursor)
        let rootIsSelfClosing = isSelfClosing(bytes, tagEnd: rootTagEnd)
        cursor = rootTagEnd

        var scanned = ScannedXMLPart(
            prolog: prolog,
            rootOpenTag: rootIsSelfClosing ? normalisedOpenTag(rootOpenTag) : rootOpenTag,
            rootName: rootLocal,
            rootQualifiedName: rootQualified,
            children: []
        )
        if rootIsSelfClosing { return scanned }

        // --- top-level children ------------------------------------------------------------
        while cursor < count {
            guard bytes[cursor] == UInt8(ascii: "<") else {
                cursor += 1
                continue
            }
            if matches(bytes, at: cursor, "<!--") {
                guard let end = find(bytes, from: cursor + 4, "-->") else {
                    throw SheetError.xmlMalformed(part: part, line: nil, detail: "unterminated comment")
                }
                cursor = end + 3
                continue
            }
            if matches(bytes, at: cursor, "<![CDATA[") {
                guard let end = find(bytes, from: cursor + 9, "]]>") else {
                    throw SheetError.xmlMalformed(part: part, line: nil, detail: "unterminated CDATA section")
                }
                cursor = end + 3
                continue
            }
            if matches(bytes, at: cursor, "<?") {
                guard let end = find(bytes, from: cursor + 2, "?>") else {
                    throw SheetError.xmlMalformed(part: part, line: nil, detail: "unterminated processing instruction")
                }
                cursor = end + 2
                continue
            }
            if matches(bytes, at: cursor, "</") {
                break // the root's close tag
            }

            let start = cursor
            guard let end = skipElement(bytes, from: cursor, part: part) else {
                throw SheetError.xmlMalformed(part: part, line: nil, detail: "unbalanced element under <\(rootLocal)>")
            }
            let (qualified, local) = elementName(bytes, tagStart: start)
            scanned.children.append(
                XMLElementSlice(localName: local, qualifiedName: qualified, text: string(bytes, start ..< end))
            )
            cursor = end
        }

        return scanned
    }

    // MARK: - Row attribute salvage

    /// Every `<row>` open tag inside `sheetData`, keyed by its 1-based `r` attribute.
    ///
    /// The value is the raw attribute text — everything between `<row` and the closing `>` —
    /// so a rewrite can re-emit a row's height, style, outline level and custom-format flags
    /// exactly as the producer wrote them, rather than reconstructing them from a model that
    /// normalises heights into points and defaults them to a value Excel never uses.
    ///
    /// `spans` is dropped: it is a hint about which columns a row occupies, and re-emitting a
    /// stale one after an edit is worse than omitting it.
    public static func rowAttributes(inSheetData sheetData: String) -> [Int: String] {
        let bytes = Array(sheetData.utf8)
        var result: [Int: String] = [:]
        var cursor = 0
        while cursor < bytes.count {
            guard bytes[cursor] == UInt8(ascii: "<") else {
                cursor += 1
                continue
            }
            if matches(bytes, at: cursor, "<!--") {
                guard let end = find(bytes, from: cursor + 4, "-->") else { break }
                cursor = end + 3
                continue
            }
            guard let tagEnd = endOfTag(bytes, from: cursor), cursor + 1 < bytes.count else { break }
            let (_, local) = elementName(bytes, tagStart: cursor)
            if local == "row", bytes[cursor + 1] != UInt8(ascii: "/") {
                let tag = string(bytes, cursor ..< tagEnd)
                let attributes = XMLAttributeScanner.attributes(inTag: tag)
                if let reference = attributes.first(where: { $0.name == "r" })?.value, let row = Int(reference) {
                    let kept = attributes
                        .filter { $0.name != "r" && $0.name != "spans" }
                        .map { " \($0.name)=\"\($0.value)\"" }
                        .joined()
                    result[row] = kept
                }
            }
            cursor = tagEnd
        }
        return result
    }

    // MARK: - Byte-level helpers

    /// The index just past the `>` of the tag starting at `start`, respecting quoted attribute
    /// values — a `>` inside `title="a > b"` is legal XML and ends nothing.
    static func endOfTag(_ bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start + 1
        var quote: UInt8?
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if let open = quote {
                if byte == open { quote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return cursor + 1
            }
            cursor += 1
        }
        return nil
    }

    /// The index just past the close tag matching the element that starts at `start`.
    private static func skipElement(_ bytes: [UInt8], from start: Int, part: String) -> Int? {
        var cursor = start
        var depth = 0
        while cursor < bytes.count {
            guard bytes[cursor] == UInt8(ascii: "<") else {
                cursor += 1
                continue
            }
            if matches(bytes, at: cursor, "<!--") {
                guard let end = find(bytes, from: cursor + 4, "-->") else { return nil }
                cursor = end + 3
                continue
            }
            if matches(bytes, at: cursor, "<![CDATA[") {
                guard let end = find(bytes, from: cursor + 9, "]]>") else { return nil }
                cursor = end + 3
                continue
            }
            if matches(bytes, at: cursor, "<?") {
                guard let end = find(bytes, from: cursor + 2, "?>") else { return nil }
                cursor = end + 2
                continue
            }
            guard let tagEnd = endOfTag(bytes, from: cursor) else { return nil }
            if bytes[cursor + 1] == UInt8(ascii: "/") {
                depth -= 1
                if depth <= 0 { return tagEnd }
            } else if isSelfClosing(bytes, tagEnd: tagEnd) {
                if depth == 0 { return tagEnd }
            } else {
                depth += 1
            }
            cursor = tagEnd
        }
        return nil
    }

    private static func isSelfClosing(_ bytes: [UInt8], tagEnd: Int) -> Bool {
        tagEnd >= 2 && bytes[tagEnd - 2] == UInt8(ascii: "/")
    }

    /// Rewrites `<worksheet …/>` as `<worksheet …>` so children can be added under it.
    private static func normalisedOpenTag(_ tag: String) -> String {
        guard tag.hasSuffix("/>") else { return tag }
        return String(tag.dropLast(2)) + ">"
    }

    private static func elementName(_ bytes: [UInt8], tagStart: Int) -> (qualified: String, local: String) {
        var cursor = tagStart + 1
        if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "/") { cursor += 1 }
        let start = cursor
        while cursor < bytes.count {
            let byte = bytes[cursor]
            if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "/") || byte == UInt8(ascii: ">") {
                break
            }
            cursor += 1
        }
        let qualified = string(bytes, start ..< cursor)
        let local = qualified.contains(":") ? String(qualified.split(separator: ":").last ?? "") : qualified
        return (qualified, local)
    }

    private static func matches(_ bytes: [UInt8], at index: Int, _ literal: String) -> Bool {
        let pattern = Array(literal.utf8)
        guard index + pattern.count <= bytes.count else { return false }
        for offset in pattern.indices where bytes[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    private static func find(_ bytes: [UInt8], from index: Int, _ literal: String) -> Int? {
        let pattern = Array(literal.utf8)
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        var cursor = max(0, index)
        while cursor + pattern.count <= bytes.count {
            if matches(bytes, at: cursor, literal) { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }
}

/// Pulls `name="value"` pairs out of a single tag, values left escaped.
///
/// Values stay exactly as written so they can be re-emitted verbatim. Anything that needs the
/// decoded value asks for a specific attribute and unescapes it itself.
public enum XMLAttributeScanner {
    /// One attribute, with its value still in source form.
    public struct Attribute: Sendable, Hashable {
        public var name: String
        public var value: String
    }

    /// The attributes in `tag`, which must include the angle brackets.
    public static func attributes(inTag tag: String) -> [Attribute] {
        let bytes = Array(tag.utf8)
        var result: [Attribute] = []
        var cursor = 1
        // Skip the element name.
        while cursor < bytes.count, !isSpace(bytes[cursor]), bytes[cursor] != UInt8(ascii: ">") {
            cursor += 1
        }
        while cursor < bytes.count {
            while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] != UInt8(ascii: ">"), bytes[cursor] != UInt8(ascii: "/") else {
                break
            }
            let nameStart = cursor
            while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "="), !isSpace(bytes[cursor]),
                  bytes[cursor] != UInt8(ascii: ">") {
                cursor += 1
            }
            guard cursor > nameStart else {
                cursor += 1 // malformed: guarantee progress rather than spin
                continue
            }
            let name = String(decoding: bytes[nameStart ..< cursor], as: UTF8.self)
            while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "=") else {
                result.append(Attribute(name: name, value: ""))
                continue
            }
            cursor += 1
            while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
            guard cursor < bytes.count else { break }
            let quote = bytes[cursor]
            guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { continue }
            cursor += 1
            let valueStart = cursor
            while cursor < bytes.count, bytes[cursor] != quote { cursor += 1 }
            let value = String(decoding: bytes[valueStart ..< min(cursor, bytes.count)], as: UTF8.self)
            cursor = min(cursor + 1, bytes.count)
            result.append(Attribute(name: name, value: value))
        }
        return result
    }

    /// The decoded value of one attribute, or `nil`.
    public static func value(of name: String, inTag tag: String) -> String? {
        guard let raw = attributes(inTag: tag).first(where: { $0.name == name })?.value else { return nil }
        return unescape(raw)
    }

    /// Reverses the five predefined entities plus numeric character references.
    public static func unescape(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        var rest = Substring(value)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex ..< ampersand]
            rest = rest[rest.index(after: ampersand)...]
            guard let semicolon = rest.firstIndex(of: ";") else {
                result += "&" + rest
                return result
            }
            let entity = rest[rest.startIndex ..< semicolon]
            rest = rest[rest.index(after: semicolon)...]
            switch entity {
            case "amp": result += "&"
            case "lt": result += "<"
            case "gt": result += ">"
            case "quot": result += "\""
            case "apos": result += "'"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
                   let code = UInt32(entity.dropFirst(2), radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()),
                          let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += "&\(entity);"
                }
            }
        }
        result += rest
        return result
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r")
    }
}
