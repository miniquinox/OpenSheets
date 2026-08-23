//
//  XMLPullParser.swift
//  SheetFormat
//
//  A1 owns this file. A hardened, streaming, allocation-light XML reader.
//

import Foundation

import SheetModel

/// A streaming XML reader for OOXML parts.
///
/// # Why not `XMLParser`
///
/// Three reasons, in order of importance.
///
/// 1. **Byte ranges.** Preserving `<conditionalFormatting>` verbatim (see
///    ``SheetModel/SheetFragment``) means copying the exact bytes the producer wrote, prefixes
///    and attribute order intact. A callback parser hands you a decoded, normalised view and the
///    original offsets are gone.
/// 2. **A blanket DTD refusal.** `XMLParser` can be told not to *resolve* external entities, but
///    it still walks an internal subset. Here `<!DOCTYPE` is refused before it is read, so XXE
///    and billion-laughs are the same one-line rejection.
/// 3. **Speed.** A million-cell `sheet1.xml` is ~30 MB. This does one pass over the bytes and
///    allocates a `String` only where the model actually needs one.
///
/// # What it enforces
///
/// ``SheetModel/Limits/maxXMLDepth``, ``SheetModel/Limits/maxXMLAttributesPerElement``,
/// ``SheetModel/Limits/maxXMLTokenBytes``, mismatched or unclosed elements, undefined entity
/// references (no DTD means no entity can legally be defined), and the characters XML 1.0
/// forbids outright.
///
/// # Lifetime
///
/// It borrows the caller's bytes, so it is only reachable through
/// ``XMLParsing/withParser(over:part:_:)`` and must not be stored anywhere that outlives it.
public struct XMLPullParser {
    /// What ``next()`` just produced.
    public enum Event: Sendable, Hashable {
        /// An element's start tag. A self-closing tag produces this and then a matching
        /// ``endElement`` on the following call, so depth tracking never has to special-case it.
        case startElement
        /// An element's end tag.
        case endElement
        /// A run of character data, up to the next `<`.
        case characters
    }

    private let bytes: UnsafeBufferPointer<UInt8>

    /// The part name, for error messages. `xmlMalformed(part:…)` naming the part is the
    /// difference between a diagnosis and "could not open file".
    public let part: String

    private var cursor = 0
    private var stack: [Range<Int>] = []
    private var selfClosePending = false

    private var qualifiedRange = 0 ..< 0
    private var localRange = 0 ..< 0
    private var attributeLocal: [Range<Int>] = []
    private var attributeValue: [Range<Int>] = []
    private var attributeFlags: [XMLTokenFlags] = []
    private var textRange = 0 ..< 0
    private var textFlags = XMLTokenFlags()

    /// Byte offset of the `<` that opened the current element. Valid after
    /// ``Event/startElement``; this is what makes verbatim fragment capture possible.
    public private(set) var elementStart = 0

    init(_ bytes: UnsafeBufferPointer<UInt8>, part: String) {
        self.bytes = bytes
        self.part = part
        attributeLocal.reserveCapacity(16)
        attributeValue.reserveCapacity(16)
        attributeFlags.reserveCapacity(16)
        stack.reserveCapacity(32)
    }

    // MARK: - Position

    /// Byte offset just past the token ``next()`` last produced.
    public var offset: Int { cursor }

    /// Open elements, counting the one ``Event/startElement`` just reported.
    public var depth: Int { stack.count }

    /// The source bytes over `range`, decoded but otherwise untouched.
    ///
    /// This is the verbatim path: no re-escaping, no prefix rewriting, no normalisation.
    public func rawText(_ range: Range<Int>) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[range]), as: UTF8.self)
    }

    // MARK: - Pulling

    /// Advances to the next event, or returns `nil` at the end of the document.
    public mutating func next() throws(SheetError) -> Event? {
        if selfClosePending {
            selfClosePending = false
            let popped = stack.removeLast()
            qualifiedRange = popped
            localRange = Self.localPart(of: popped, in: bytes)
            return .endElement
        }

        while true {
            guard cursor < bytes.count else {
                if let unclosed = stack.last {
                    throw SheetError.xmlMalformed(
                        part: part, line: nil,
                        detail: "the document ends with <\(rawText(unclosed))> still open"
                    )
                }
                return nil
            }

            if bytes[cursor] != UInt8(ascii: "<") {
                try scanText()
                return .characters
            }

            guard cursor + 1 < bytes.count else {
                throw SheetError.xmlMalformed(part: part, line: nil, detail: "the document ends inside a tag")
            }

            switch bytes[cursor + 1] {
            case UInt8(ascii: "?"):
                cursor = try seek(past: "?>", from: cursor + 2, what: "a processing instruction")
            case UInt8(ascii: "!"):
                if Self.matches(bytes, cursor + 2, "--") {
                    cursor = try seek(past: "-->", from: cursor + 4, what: "a comment")
                } else if Self.matches(bytes, cursor + 2, "[CDATA[") {
                    try scanCDATA()
                    return .characters
                } else {
                    // Blanket refusal. No legitimate xlsx producer emits a DOCTYPE, and a
                    // heuristic that greps for SYSTEM is one `<!ENTITY>` away from useless — so
                    // XXE, billion-laughs and a harmless DOCTYPE are all this one rejection.
                    throw SheetError.xmlDocumentTypeRejected(part: part)
                }
            case UInt8(ascii: "/"):
                try scanEndTag()
                return .endElement
            default:
                try scanStartTag()
                return .startElement
            }
        }
    }

    /// Consumes everything up to and including the end tag matching the element
    /// ``Event/startElement`` just reported, and returns its full byte range.
    ///
    /// The range starts at the `<` of the open tag and ends just past the `>` of the close, so
    /// ``rawText(_:)`` over it is the element exactly as the producer wrote it.
    @discardableResult
    public mutating func skipElement() throws(SheetError) -> Range<Int> {
        let start = elementStart
        let target = stack.count - 1
        while let event = try next() {
            if event == .endElement, stack.count == target { return start ..< cursor }
        }
        throw SheetError.xmlMalformed(part: part, line: nil, detail: "an element is not closed")
    }

    // MARK: - The current element

    /// Whether the current element's local name is `name`.
    ///
    /// Prefixes are ignored on purpose: producers disagree about them (`x:worksheet`,
    /// `worksheet`, `ss:worksheet`) and the local name does not.
    public func nameIs(_ name: StaticString) -> Bool {
        Self.equal(bytes, localRange, name)
    }

    /// The current element's local name.
    public var name: String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[localRange]), as: UTF8.self)
    }

    /// The current element's name including any prefix, exactly as written.
    public var qualifiedName: String {
        String(decoding: UnsafeBufferPointer(rebasing: bytes[qualifiedRange]), as: UTF8.self)
    }

    /// Attributes on the current start tag.
    public var attributeCount: Int { attributeLocal.count }

    /// The value of the attribute whose local name is `name`, or `nil`.
    ///
    /// Linear over the element's attributes, which is right: a `<c>` has three, and hashing
    /// would cost more than the scan.
    public func attribute(_ name: StaticString) -> XMLValue? {
        for index in attributeLocal.indices where Self.equal(bytes, attributeLocal[index], name) {
            return XMLValue(
                bytes: UnsafeBufferPointer(rebasing: bytes[attributeValue[index]]),
                flags: attributeFlags[index],
                part: part
            )
        }
        return nil
    }

    /// The character data ``Event/characters`` just reported.
    public var text: XMLValue {
        XMLValue(bytes: UnsafeBufferPointer(rebasing: bytes[textRange]), flags: textFlags, part: part)
    }

    // MARK: - Scanning

    private mutating func scanStartTag() throws(SheetError) {
        elementStart = cursor
        cursor += 1
        let nameStart = cursor
        while cursor < bytes.count, !Self.isNameTerminator(bytes[cursor]) { cursor += 1 }
        guard cursor > nameStart else {
            throw SheetError.xmlMalformed(part: part, line: nil, detail: "an element has no name")
        }
        qualifiedRange = nameStart ..< cursor
        localRange = Self.localPart(of: qualifiedRange, in: bytes)

        attributeLocal.removeAll(keepingCapacity: true)
        attributeValue.removeAll(keepingCapacity: true)
        attributeFlags.removeAll(keepingCapacity: true)

        var isSelfClosing = false
        while true {
            skipWhitespace()
            guard cursor < bytes.count else {
                throw SheetError.xmlMalformed(part: part, line: nil, detail: "the document ends inside a start tag")
            }
            if bytes[cursor] == UInt8(ascii: ">") {
                cursor += 1
                break
            }
            if bytes[cursor] == UInt8(ascii: "/") {
                guard cursor + 1 < bytes.count, bytes[cursor + 1] == UInt8(ascii: ">") else {
                    throw SheetError.xmlMalformed(part: part, line: nil, detail: "a '/' is not followed by '>'")
                }
                cursor += 2
                isSelfClosing = true
                break
            }
            try scanAttribute()
        }

        guard stack.count < Limits.maxXMLDepth else {
            throw SheetError.xmlDepthExceeded(part: part, depth: stack.count + 1, limit: Limits.maxXMLDepth)
        }
        stack.append(qualifiedRange)
        selfClosePending = isSelfClosing
    }

    private mutating func scanAttribute() throws(SheetError) {
        guard attributeLocal.count < Limits.maxXMLAttributesPerElement else {
            throw SheetError.xmlTooManyAttributes(
                part: part, count: attributeLocal.count + 1, limit: Limits.maxXMLAttributesPerElement
            )
        }
        let nameStart = cursor
        while cursor < bytes.count, !Self.isNameTerminator(bytes[cursor]), bytes[cursor] != UInt8(ascii: "=") {
            cursor += 1
        }
        let nameRange = nameStart ..< cursor
        guard !nameRange.isEmpty else {
            throw SheetError.xmlMalformed(part: part, line: nil, detail: "an attribute has no name")
        }
        skipWhitespace()
        guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "=") else {
            throw SheetError.xmlMalformed(
                part: part, line: nil, detail: "attribute '\(rawText(nameRange))' has no value"
            )
        }
        cursor += 1
        skipWhitespace()
        guard cursor < bytes.count, bytes[cursor] == UInt8(ascii: "\"") || bytes[cursor] == UInt8(ascii: "'") else {
            throw SheetError.xmlMalformed(
                part: part, line: nil, detail: "attribute '\(rawText(nameRange))' has an unquoted value"
            )
        }
        let quote = bytes[cursor]
        cursor += 1
        let valueStart = cursor
        var flags = XMLTokenFlags()
        while cursor < bytes.count, bytes[cursor] != quote {
            flags.note(bytes[cursor])
            cursor += 1
        }
        guard cursor < bytes.count else {
            throw SheetError.xmlMalformed(part: part, line: nil, detail: "an attribute value is not closed")
        }
        let valueRange = valueStart ..< cursor
        cursor += 1
        guard valueRange.count <= Limits.maxXMLTokenBytes else {
            throw SheetError.xmlTokenTooLong(part: part, bytes: valueRange.count, limit: Limits.maxXMLTokenBytes)
        }
        attributeLocal.append(Self.localPart(of: nameRange, in: bytes))
        attributeValue.append(valueRange)
        attributeFlags.append(flags)
    }

    private mutating func scanEndTag() throws(SheetError) {
        cursor += 2
        let nameStart = cursor
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: ">") { cursor += 1 }
        guard cursor < bytes.count else {
            throw SheetError.xmlMalformed(part: part, line: nil, detail: "the document ends inside an end tag")
        }
        var nameEnd = cursor
        while nameEnd > nameStart, Self.isWhitespace(bytes[nameEnd - 1]) { nameEnd -= 1 }
        let nameRange = nameStart ..< nameEnd
        cursor += 1

        guard let open = stack.last else {
            throw SheetError.xmlMalformed(
                part: part, line: nil, detail: "</\(rawText(nameRange))> closes an element that was never opened"
            )
        }
        guard Self.equal(bytes, open, nameRange) else {
            throw SheetError.xmlMalformed(
                part: part, line: nil, detail: "</\(rawText(nameRange))> does not close <\(rawText(open))>"
            )
        }
        stack.removeLast()
        qualifiedRange = nameRange
        localRange = Self.localPart(of: nameRange, in: bytes)
    }

    private mutating func scanText() throws(SheetError) {
        let start = cursor
        var flags = XMLTokenFlags()
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "<") {
            flags.note(bytes[cursor])
            cursor += 1
        }
        textRange = start ..< cursor
        textFlags = flags
        guard textRange.count <= Limits.maxXMLTokenBytes else {
            throw SheetError.xmlTokenTooLong(part: part, bytes: textRange.count, limit: Limits.maxXMLTokenBytes)
        }
    }

    private mutating func scanCDATA() throws(SheetError) {
        let start = cursor + 9
        let end = try seek(past: "]]>", from: start, what: "a CDATA section")
        textRange = start ..< (end - 3)
        textFlags = .cdata
        for index in textRange { textFlags.note(bytes[index]) }
        textFlags.remove(.hasEntity)
        cursor = end
        guard textRange.count <= Limits.maxXMLTokenBytes else {
            throw SheetError.xmlTokenTooLong(part: part, bytes: textRange.count, limit: Limits.maxXMLTokenBytes)
        }
    }

    /// The offset just past the next occurrence of `terminator` at or after `from`.
    private func seek(past terminator: StaticString, from: Int, what: String) throws(SheetError) -> Int {
        guard let found = Self.find(bytes, terminator, from: from) else {
            throw SheetError.xmlMalformed(part: part, line: nil, detail: "\(what) is not closed")
        }
        return found
    }

    private mutating func skipWhitespace() {
        while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) { cursor += 1 }
    }

    // MARK: - Byte helpers
    //
    // Static and parameterised rather than methods, so nothing captures `self` in the closures
    // `StaticString.withUTF8Buffer` needs.

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isNameTerminator(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/")
    }

    private static func localPart(of range: Range<Int>, in bytes: UnsafeBufferPointer<UInt8>) -> Range<Int> {
        var index = range.upperBound - 1
        while index >= range.lowerBound {
            if bytes[index] == UInt8(ascii: ":") { return (index + 1) ..< range.upperBound }
            index -= 1
        }
        return range
    }

    private static func matches(
        _ bytes: UnsafeBufferPointer<UInt8>, _ offset: Int, _ literal: StaticString
    ) -> Bool {
        literal.withUTF8Buffer { needle in
            guard offset >= 0, offset + needle.count <= bytes.count else { return false }
            var index = 0
            while index < needle.count, bytes[offset + index] == needle[index] { index += 1 }
            return index == needle.count
        }
    }

    /// The offset just past `needle`, searching forward from `from`.
    private static func find(
        _ bytes: UnsafeBufferPointer<UInt8>, _ needle: StaticString, from: Int
    ) -> Int? {
        needle.withUTF8Buffer { pattern -> Int? in
            guard !pattern.isEmpty else { return from }
            var scan = max(from, 0)
            let last = bytes.count - pattern.count
            while scan <= last {
                if bytes[scan] == pattern[0] {
                    var index = 1
                    while index < pattern.count, bytes[scan + index] == pattern[index] { index += 1 }
                    if index == pattern.count { return scan + pattern.count }
                }
                scan += 1
            }
            return nil
        }
    }

    private static func equal(
        _ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, _ literal: StaticString
    ) -> Bool {
        literal.withUTF8Buffer { needle in
            guard needle.count == range.count else { return false }
            var index = 0
            while index < needle.count, bytes[range.lowerBound + index] == needle[index] { index += 1 }
            return index == needle.count
        }
    }

    private static func equal(
        _ bytes: UnsafeBufferPointer<UInt8>, _ left: Range<Int>, _ right: Range<Int>
    ) -> Bool {
        guard left.count == right.count else { return false }
        var index = 0
        while index < left.count {
            guard bytes[left.lowerBound + index] == bytes[right.lowerBound + index] else { return false }
            index += 1
        }
        return true
    }
}

/// Runs `body` against a parser over `bytes`.
///
/// ``XMLPullParser`` borrows its input, so this is the only way to get one: the closure is
/// synchronous and non-escaping, which is what makes the borrow safe.
public enum XMLParsing {
    public static func withParser<Result>(
        over bytes: [UInt8],
        part: String,
        _ body: (inout XMLPullParser) throws(SheetError) -> Result
    ) throws(SheetError) -> Result {
        var outcome: Swift.Result<Result, SheetError>?
        bytes.withUnsafeBufferPointer { buffer in
            var parser = XMLPullParser(buffer, part: part)
            do {
                outcome = .success(try body(&parser))
            } catch {
                // The closure is not typed-throwing, so the binding widens to `any Error`.
                outcome = .failure(error as? SheetError ?? .internalInconsistency(detail: "\(error)"))
            }
        }
        switch outcome {
        case let .success(value): return value
        case let .failure(error): throw error
        case .none:
            throw SheetError.internalInconsistency(detail: "the XML parser produced no result for '\(part)'")
        }
    }
}
