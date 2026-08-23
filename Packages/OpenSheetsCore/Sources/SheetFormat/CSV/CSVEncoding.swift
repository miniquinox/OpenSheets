//
//  CSVEncoding.swift
//  SheetFormat
//
//  Working out what bytes a text file is actually made of, and saying so when it is a guess.
//

import Foundation
import SheetModel

/// The text encodings OpenSheets reads and writes for delimited files.
///
/// Four, because those are the four that turn up. UTF-8 is what everything modern writes,
/// UTF-16 is what Excel on Windows writes when you choose "Unicode Text", and Windows-1252 is
/// what a decade of exports from accounting software is still made of.
public enum CSVEncoding: String, Sendable, Hashable, CaseIterable {
    case utf8 = "utf-8"
    case utf16LittleEndian = "utf-16le"
    case utf16BigEndian = "utf-16be"
    case windows1252 = "windows-1252"

    /// The byte-order mark this encoding uses, when it has one.
    public var byteOrderMark: [UInt8] {
        switch self {
        case .utf8: [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: [0xFF, 0xFE]
        case .utf16BigEndian: [0xFE, 0xFF]
        case .windows1252: []
        }
    }
}

/// How an encoding was arrived at.
public struct CSVEncodingDetection: Sendable, Hashable {
    /// What to decode as.
    public var encoding: CSVEncoding
    /// Bytes of byte-order mark to skip before the first character.
    public var byteOrderMarkLength: Int
    /// Whether this was determined or fallen back to.
    ///
    /// **The UI must show this.** Windows-1252 is not detected, it is what is left when nothing
    /// else fits, and a wrong guess renders `café` as `cafÃ©` without any error anywhere.
    public var wasGuessed: Bool

    public init(encoding: CSVEncoding, byteOrderMarkLength: Int, wasGuessed: Bool) {
        self.encoding = encoding
        self.byteOrderMarkLength = byteOrderMarkLength
        self.wasGuessed = wasGuessed
    }
}

/// Detects the encoding of a delimited text file.
///
/// The order is BOM, then UTF-16 heuristics, then UTF-8 validity, then Windows-1252 — cheapest
/// and most certain first. Only the last step is a guess, and it is marked as one.
public enum CSVEncodingDetector {
    /// Examines a prefix of the file.
    public static func detect(_ sample: [UInt8]) -> CSVEncodingDetection {
        if sample.count >= 3, sample[0] == 0xEF, sample[1] == 0xBB, sample[2] == 0xBF {
            return CSVEncodingDetection(encoding: .utf8, byteOrderMarkLength: 3, wasGuessed: false)
        }
        if sample.count >= 2, sample[0] == 0xFF, sample[1] == 0xFE {
            // `FF FE 00 00` is UTF-32LE, which we do not support; treating it as UTF-16LE would
            // produce a string of NULs rather than an error, so it falls through instead.
            let isUTF32 = sample.count >= 4 && sample[2] == 0 && sample[3] == 0
            if !isUTF32 {
                return CSVEncodingDetection(encoding: .utf16LittleEndian, byteOrderMarkLength: 2, wasGuessed: false)
            }
        }
        if sample.count >= 2, sample[0] == 0xFE, sample[1] == 0xFF {
            return CSVEncodingDetection(encoding: .utf16BigEndian, byteOrderMarkLength: 2, wasGuessed: false)
        }

        // No BOM. UTF-16 text that is mostly ASCII is half NUL bytes, and which half says which
        // byte order — a signal nothing else produces.
        if sample.count >= 4 {
            var evenNULs = 0
            var oddNULs = 0
            let window = min(sample.count, 4096)
            for index in 0 ..< window where sample[index] == 0 {
                if index.isMultiple(of: 2) { evenNULs += 1 } else { oddNULs += 1 }
            }
            let threshold = window / 4
            if oddNULs > threshold, evenNULs == 0 {
                return CSVEncodingDetection(encoding: .utf16LittleEndian, byteOrderMarkLength: 0, wasGuessed: true)
            }
            if evenNULs > threshold, oddNULs == 0 {
                return CSVEncodingDetection(encoding: .utf16BigEndian, byteOrderMarkLength: 0, wasGuessed: true)
            }
        }

        if isValidUTF8(sample) {
            return CSVEncodingDetection(encoding: .utf8, byteOrderMarkLength: 0, wasGuessed: false)
        }
        return CSVEncodingDetection(encoding: .windows1252, byteOrderMarkLength: 0, wasGuessed: true)
    }

    /// Whether `bytes` decode as UTF-8, tolerating a truncated sequence at the very end.
    ///
    /// The tolerance matters: the sample is a prefix of the file, and cutting a three-byte
    /// character in half must not condemn a perfectly good UTF-8 file to Windows-1252.
    static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let width: Int
            switch byte {
            case 0x00 ... 0x7F: width = 1
            case 0xC2 ... 0xDF: width = 2
            case 0xE0 ... 0xEF: width = 3
            case 0xF0 ... 0xF4: width = 4
            default: return false
            }
            if index + width > bytes.count {
                return index + 4 > bytes.count // a truncated tail is acceptable
            }
            for offset in 1 ..< width where (bytes[index + offset] & 0xC0) != 0x80 {
                return false
            }
            index += width
        }
        return true
    }
}

/// Turns a byte stream into text, one chunk at a time.
///
/// Streaming is the whole point: PLAN.md §9 requires a 2 GB CSV to open, and
/// `String(data:encoding:)` on 2 GB of bytes is a 2 GB allocation before the first row is
/// parsed. So the decoder keeps only the few bytes of a character that straddles a chunk
/// boundary — never more than three.
public struct CSVTextDecoder: Sendable {
    /// What to decode as.
    public let encoding: CSVEncoding

    /// Bytes of an incomplete character carried over from the previous chunk.
    private var carry: [UInt8] = []

    /// A high surrogate awaiting its pair, for UTF-16.
    private var pendingSurrogate: UInt16?

    public init(encoding: CSVEncoding) {
        self.encoding = encoding
    }

    /// Decodes `chunk`, appending to `output`.
    public mutating func decode(_ chunk: ArraySlice<UInt8>, into output: inout String.UnicodeScalarView) {
        var bytes = carry
        bytes.append(contentsOf: chunk)
        carry = []

        switch encoding {
        case .windows1252:
            for byte in bytes { output.append(Self.windows1252Scalar(byte)) }
        case .utf8:
            decodeUTF8(bytes, into: &output)
        case .utf16LittleEndian, .utf16BigEndian:
            decodeUTF16(bytes, littleEndian: encoding == .utf16LittleEndian, into: &output)
        }
    }

    /// Flushes anything left over, replacing an incomplete character rather than dropping it.
    public mutating func finish(into output: inout String.UnicodeScalarView) {
        if !carry.isEmpty {
            output.append("\u{FFFD}")
            carry = []
        }
        if pendingSurrogate != nil {
            output.append("\u{FFFD}")
            pendingSurrogate = nil
        }
    }

    private mutating func decodeUTF8(_ bytes: [UInt8], into output: inout String.UnicodeScalarView) {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            let width: Int
            switch byte {
            case 0x00 ... 0x7F: width = 1
            case 0xC2 ... 0xDF: width = 2
            case 0xE0 ... 0xEF: width = 3
            case 0xF0 ... 0xF4: width = 4
            default:
                output.append("\u{FFFD}")
                index += 1
                continue
            }
            guard index + width <= bytes.count else {
                carry = Array(bytes[index...])
                return
            }
            let slice = Array(bytes[index ..< index + width])
            if let scalar = Self.utf8Scalar(slice) {
                output.append(scalar)
            } else {
                output.append("\u{FFFD}")
            }
            index += width
        }
    }

    private mutating func decodeUTF16(
        _ bytes: [UInt8],
        littleEndian: Bool,
        into output: inout String.UnicodeScalarView
    ) {
        var index = 0
        while index + 1 < bytes.count {
            let unit = littleEndian
                ? UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                : (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
            index += 2

            if let high = pendingSurrogate {
                pendingSurrogate = nil
                if (0xDC00 ... 0xDFFF).contains(unit) {
                    let value = 0x1_0000 + (UInt32(high - 0xD800) << 10) + UInt32(unit - 0xDC00)
                    output.append(Unicode.Scalar(value) ?? "\u{FFFD}")
                    continue
                }
                output.append("\u{FFFD}")
            }
            if (0xD800 ... 0xDBFF).contains(unit) {
                pendingSurrogate = unit
                continue
            }
            output.append(Unicode.Scalar(unit) ?? "\u{FFFD}")
        }
        if index < bytes.count { carry = [bytes[index]] }
    }

    private static func utf8Scalar(_ bytes: [UInt8]) -> Unicode.Scalar? {
        var value: UInt32
        switch bytes.count {
        case 1: value = UInt32(bytes[0])
        case 2: value = UInt32(bytes[0] & 0x1F)
        case 3: value = UInt32(bytes[0] & 0x0F)
        default: value = UInt32(bytes[0] & 0x07)
        }
        for byte in bytes.dropFirst() {
            guard (byte & 0xC0) == 0x80 else { return nil }
            value = (value << 6) | UInt32(byte & 0x3F)
        }
        return Unicode.Scalar(value)
    }

    /// Windows-1252 differs from Latin-1 only in `0x80`–`0x9F`, where Latin-1 has unused control
    /// codes and Windows put the smart quotes, the em dash and the euro sign. Those 27
    /// characters are exactly the ones that turn up in a mis-decoded export, so the table has to
    /// be right rather than approximated by Latin-1.
    static func windows1252Scalar(_ byte: UInt8) -> Unicode.Scalar {
        guard (0x80 ... 0x9F).contains(byte) else { return Unicode.Scalar(byte) }
        return windows1252HighRange[Int(byte - 0x80)]
    }

    private static let windows1252HighRange: [Unicode.Scalar] = [
        "\u{20AC}", "\u{FFFD}", "\u{201A}", "\u{0192}", "\u{201E}", "\u{2026}", "\u{2020}", "\u{2021}",
        "\u{02C6}", "\u{2030}", "\u{0160}", "\u{2039}", "\u{0152}", "\u{FFFD}", "\u{017D}", "\u{FFFD}",
        "\u{FFFD}", "\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2022}", "\u{2013}", "\u{2014}",
        "\u{02DC}", "\u{2122}", "\u{0161}", "\u{203A}", "\u{0153}", "\u{FFFD}", "\u{017E}", "\u{0178}",
    ]

    /// Encodes `text` for writing, or `nil` when the encoding cannot represent all of it.
    public static func encode(_ text: String, as encoding: CSVEncoding) -> Data? {
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf16LittleEndian, .utf16BigEndian:
            var bytes = [UInt8]()
            bytes.reserveCapacity(text.utf16.count * 2)
            for unit in text.utf16 {
                if encoding == .utf16LittleEndian {
                    bytes.append(UInt8(unit & 0xFF))
                    bytes.append(UInt8(unit >> 8))
                } else {
                    bytes.append(UInt8(unit >> 8))
                    bytes.append(UInt8(unit & 0xFF))
                }
            }
            return Data(bytes)
        case .windows1252:
            var bytes = [UInt8]()
            bytes.reserveCapacity(text.unicodeScalars.count)
            for scalar in text.unicodeScalars {
                if scalar.value < 0x80 || (0xA0 ... 0xFF).contains(scalar.value) {
                    bytes.append(UInt8(scalar.value))
                } else if let index = windows1252HighRange.firstIndex(of: scalar), scalar != "\u{FFFD}" {
                    bytes.append(UInt8(0x80 + index))
                } else {
                    return nil
                }
            }
            return Data(bytes)
        }
    }
}
