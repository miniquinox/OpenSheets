//
//  XMLValue.swift
//  SheetFormat
//
//  A1 owns this file. An undecoded attribute value or text run, plus the conversions the
//  reader actually needs — each of which avoids allocating a `String` where it can.
//

import Foundation

import SheetModel

/// What a scan noticed about a token, so the expensive work can be skipped when it is not needed.
public struct XMLTokenFlags: OptionSet, Sendable, Hashable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public init() { rawValue = 0 }

    /// Contains `&`, so entity references have to be resolved before this is text.
    public static let hasEntity = XMLTokenFlags(rawValue: 1 << 0)

    /// Contains a byte XML 1.0 forbids: a C0 control other than tab, newline or carriage
    /// return. `Fixtures/hostile/nul-bytes-in-string.xlsx` is exactly this, and truncating at
    /// the NUL and carrying on silently is the outcome it exists to prevent.
    public static let hasIllegalCharacter = XMLTokenFlags(rawValue: 1 << 1)

    /// Came from a CDATA section, where `&` is literal.
    public static let cdata = XMLTokenFlags(rawValue: 1 << 2)

    /// Records what `byte` implies. One branch per byte in the scanner's inner loop.
    public mutating func note(_ byte: UInt8) {
        if byte == UInt8(ascii: "&") { insert(.hasEntity) }
        if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D { insert(.hasIllegalCharacter) }
    }
}

/// A slice of the XML source that has not been turned into a `String` yet.
///
/// The point of the type: `<c r="B7" s="3"><v>42</v></c>` needs a `CellRef`, an `Int32` and a
/// `Double`, and none of them requires an allocation. A reader that builds three `String`s per
/// cell spends more time in the allocator than in the parser at a million cells.
public struct XMLValue {
    let bytes: UnsafeBufferPointer<UInt8>
    let flags: XMLTokenFlags
    let part: String

    /// Whether the token has no bytes at all. Distinct from "is whitespace".
    public var isEmpty: Bool { bytes.isEmpty }

    /// Length in bytes, which is not the length in characters.
    public var byteCount: Int { bytes.count }

    /// Whether the raw bytes are exactly `literal`. No decoding, no allocation.
    public func equals(_ literal: StaticString) -> Bool {
        literal.withUTF8Buffer { needle in
            guard needle.count == bytes.count else { return false }
            var index = 0
            while index < needle.count, bytes[index] == needle[index] { index += 1 }
            return index == needle.count
        }
    }

    // MARK: - Text

    /// The token as text, with entity references resolved.
    ///
    /// Throws ``SheetError/xmlInvalidEncoding(part:detail:)`` for bytes XML 1.0 forbids or for
    /// invalid UTF-8, and ``SheetError/xmlMalformed(part:line:detail:)`` for an entity nothing
    /// defines — which, since DTDs are refused outright, means every entity but the five
    /// built-ins and numeric character references.
    public func string() throws(SheetError) -> String {
        if flags.contains(.hasIllegalCharacter) {
            throw SheetError.xmlInvalidEncoding(
                part: part, detail: "a control character that XML 1.0 forbids appears in the document"
            )
        }
        if !flags.contains(.hasEntity) || flags.contains(.cdata) {
            guard let text = String(bytes: bytes, encoding: .utf8) else {
                throw SheetError.xmlInvalidEncoding(part: part, detail: "the bytes are not valid UTF-8")
            }
            return text
        }
        return try decodeEntities()
    }

    /// The token as cell text: entity references resolved, then OOXML's `_xHHHH_` escapes.
    ///
    /// Excel writes a newline inside a cell as `_x000A_`, and a literal underscore that would
    /// otherwise start such an escape as `_x005F_`. Decoding is therefore what round-trips; the
    /// cost is that a string genuinely containing `_x0041_` reads back as `A`, which is exactly
    /// the ambiguity Excel itself has and resolves the same way.
    ///
    /// A character that is illegal in XML is **dropped** rather than reintroduced — putting a
    /// NUL back into a `String` only moves the problem to whoever writes the file next.
    public func cellText() throws(SheetError) -> String {
        let decoded = try string()
        guard decoded.utf8.contains(UInt8(ascii: "_")) else { return decoded }
        return XMLValue.unescapeOOXML(decoded)
    }

    // MARK: - Numbers

    /// The token as an `Int`, or `nil` if it is not one.
    ///
    /// Accumulates in `Int64` and range-checks, so `r="4294967295"` reads as 4,294,967,295 and
    /// not as −1. `Fixtures/hostile/dimension-4-billion-rows.xlsx` is that exact overflow.
    public var int: Int? {
        var index = 0
        var negative = false
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
            negative = bytes[index] == UInt8(ascii: "-")
            index += 1
        }
        guard index < bytes.count else { return nil }
        var value = 0
        while index < bytes.count {
            let digit = bytes[index]
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
            let (multiplied, overflowA) = value.multipliedReportingOverflow(by: 10)
            guard !overflowA else { return nil }
            let (added, overflowB) = multiplied.addingReportingOverflow(Int(digit - UInt8(ascii: "0")))
            guard !overflowB else { return nil }
            value = added
            index += 1
        }
        return negative ? -value : value
    }

    /// The token as an `Int32`, for a `sheetId` or a style index.
    public var int32: Int32? {
        guard let value = int, value >= Int(Int32.min), value <= Int(Int32.max) else { return nil }
        return Int32(value)
    }

    /// The token as a `Double`.
    ///
    /// Goes through `strtod` on a stack buffer rather than a hand-rolled float parser: OOXML
    /// writes `1.7976931348623157E+308`, and getting the last bits of that right is not
    /// something to reimplement.
    public var double: Double? {
        // Screen the bytes before `strtod` sees them. C's parser accepts `0x10` as a hex float,
        // and `inf` and `nan` as values; OOXML writes none of those, so accepting them would turn
        // a corrupt file into a plausible-looking number.
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "e"), UInt8(ascii: "E"):
                continue
            default:
                return nil
            }
        }
        guard !bytes.isEmpty, bytes.count < 512 else {
            guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
            return Double(text)
        }
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: bytes.count + 1) { scratch in
            for index in 0 ..< bytes.count { scratch[index] = CChar(bitPattern: bytes[index]) }
            scratch[bytes.count] = 0
            var end: UnsafeMutablePointer<CChar>?
            let value = strtod(scratch.baseAddress!, &end)
            // Reject trailing garbage: "42abc" is not a number, and quietly reading 42 out of it
            // is how a corrupt file becomes a plausible-looking spreadsheet.
            guard let end, end != scratch.baseAddress, end.pointee == 0 else { return nil }
            return value
        }
    }

    /// The token as an xlsx boolean: `1`/`true` and `0`/`false`.
    public var bool: Bool {
        if bytes.count == 1 { return bytes[0] == UInt8(ascii: "1") }
        return equals("true") || equals("TRUE")
    }

    // MARK: - References

    /// The token as a cell reference, without allocating a `String`.
    ///
    /// Byte-for-byte the same rules as ``SheetModel/CellRef/init(a1:)`` — letters then digits,
    /// case folded, `$` rejected, anything outside the sheet rejected rather than clamped — and
    /// `Tests/SheetFormatTests/Read/CellReferenceParityTests` proves the two agree. It is here
    /// rather than there because this is the most-called function in the reader and the model's
    /// version needs a `StringProtocol`.
    public var cellRef: CellRef? {
        var column = 0
        var row = 0
        var sawLetter = false
        var sawDigit = false
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"):
                if sawDigit { return nil }
                column = column * 26 + Int(byte | 0x20) - 96
                if column > Limits.columnCount { return nil }
                sawLetter = true
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                if !sawLetter { return nil }
                row = row * 10 + Int(byte - UInt8(ascii: "0"))
                if row > Limits.rowCount { return nil }
                sawDigit = true
            default:
                return nil
            }
        }
        guard sawLetter, sawDigit, row > 0 else { return nil }
        return CellRef(row: row - 1, column: column - 1)
    }

    // MARK: - Entity decoding

    private func decodeEntities() throws(SheetError) -> String {
        var output = [UInt8]()
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "&") else {
                output.append(bytes[index])
                index += 1
                continue
            }
            guard let semicolon = indexOfSemicolon(after: index), semicolon - index <= 12 else {
                throw SheetError.xmlMalformed(part: part, line: nil, detail: "an unterminated '&' entity reference")
            }
            let body = (index + 1) ..< semicolon
            if bytes[index + 1] == UInt8(ascii: "#") {
                guard let scalar = try numericReference(body) else {
                    throw SheetError.xmlInvalidEncoding(
                        part: part, detail: "a numeric character reference names a character XML 1.0 forbids"
                    )
                }
                output.append(contentsOf: Array(String(scalar).utf8))
            } else if let replacement = XMLValue.builtInEntity(bytes, body) {
                output.append(replacement)
            } else {
                let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[body]), as: UTF8.self)
                // A DTD is the only way to define an entity and DTDs are refused, so this is
                // always either a typo or a billion-laughs payload that got this far.
                throw SheetError.xmlMalformed(part: part, line: nil, detail: "undefined entity '&\(name);'")
            }
            index = semicolon + 1
        }
        guard let text = String(bytes: output, encoding: .utf8) else {
            throw SheetError.xmlInvalidEncoding(part: part, detail: "the decoded bytes are not valid UTF-8")
        }
        return text
    }

    private func indexOfSemicolon(after start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: ";") { return index }
            if bytes[index] == UInt8(ascii: "&") || bytes[index] == UInt8(ascii: "<") { return nil }
            index += 1
        }
        return nil
    }

    private func numericReference(_ body: Range<Int>) throws(SheetError) -> Unicode.Scalar? {
        var index = body.lowerBound + 1
        var value: UInt32 = 0
        let hexadecimal = index < body.upperBound
            && (bytes[index] == UInt8(ascii: "x") || bytes[index] == UInt8(ascii: "X"))
        if hexadecimal { index += 1 }
        guard index < body.upperBound else {
            throw SheetError.xmlMalformed(part: part, line: nil, detail: "an empty character reference")
        }
        while index < body.upperBound {
            let digit: UInt32
            switch bytes[index] {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                digit = UInt32(bytes[index] - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f") where hexadecimal:
                digit = UInt32(bytes[index] - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F") where hexadecimal:
                digit = UInt32(bytes[index] - UInt8(ascii: "A")) + 10
            default:
                throw SheetError.xmlMalformed(part: part, line: nil, detail: "a malformed character reference")
            }
            let (scaled, overflow) = value.multipliedReportingOverflow(by: hexadecimal ? 16 : 10)
            guard !overflow else { return nil }
            value = scaled + digit
            if value > 0x10_FFFF { return nil }
            index += 1
        }
        guard XMLValue.isLegalXMLScalar(value), let scalar = Unicode.Scalar(value) else { return nil }
        return scalar
    }

    private static func builtInEntity(_ bytes: UnsafeBufferPointer<UInt8>, _ body: Range<Int>) -> UInt8? {
        func named(_ literal: StaticString) -> Bool {
            literal.withUTF8Buffer { needle in
                guard needle.count == body.count else { return false }
                var index = 0
                while index < needle.count, bytes[body.lowerBound + index] == needle[index] { index += 1 }
                return index == needle.count
            }
        }
        if named("amp") { return UInt8(ascii: "&") }
        if named("lt") { return UInt8(ascii: "<") }
        if named("gt") { return UInt8(ascii: ">") }
        if named("quot") { return UInt8(ascii: "\"") }
        if named("apos") { return UInt8(ascii: "'") }
        return nil
    }

    /// The characters XML 1.0 allows: tab, newline, carriage return, then U+0020 upwards with
    /// the surrogate range and the two non-characters at the end of the BMP removed.
    static func isLegalXMLScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x09, 0x0A, 0x0D: true
        case 0x20 ... 0xD7FF: true
        case 0xE000 ... 0xFFFD: true
        case 0x1_0000 ... 0x10_FFFF: true
        default: false
        }
    }

    /// Resolves OOXML's `_xHHHH_` escapes. See ``cellText()``.
    static func unescapeOOXML(_ text: String) -> String {
        let source = Array(text.utf8)
        var output = [UInt8]()
        output.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            // `_x` + four hex digits + `_` is the only shape that means anything.
            if source[index] == UInt8(ascii: "_"), index + 6 < source.count,
               source[index + 1] == UInt8(ascii: "x") || source[index + 1] == UInt8(ascii: "X"),
               source[index + 6] == UInt8(ascii: "_"),
               let value = hexValue(source, (index + 2) ..< (index + 6)) {
                if isLegalXMLScalar(value), let scalar = Unicode.Scalar(value) {
                    output.append(contentsOf: Array(String(scalar).utf8))
                }
                // An illegal scalar is dropped, not reinserted.
                index += 7
                continue
            }
            output.append(source[index])
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func hexValue(_ source: [UInt8], _ range: Range<Int>) -> UInt32? {
        var value: UInt32 = 0
        for index in range {
            let digit: UInt32
            switch source[index] {
            case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit = UInt32(source[index] - UInt8(ascii: "0"))
            case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit = UInt32(source[index] - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit = UInt32(source[index] - UInt8(ascii: "A")) + 10
            default: return nil
            }
            value = value * 16 + digit
        }
        return value
    }
}
