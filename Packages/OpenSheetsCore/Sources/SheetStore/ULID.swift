import Foundation

/// A lexicographically sortable, collision-resistant identifier: 48 bits of millisecond
/// timestamp followed by 80 bits of randomness, in Crockford base32.
///
/// Used for snapshot filenames (PLAN.md §5.5). A UUID would work for uniqueness but sorts
/// randomly, and the snapshot store's whole job is "give me the last 20, oldest first" — with
/// a ULID that is `sorted()` on the filenames, with no `stat` per file and no dependence on an
/// mtime that a backup restore can rewrite.
public struct ULID: Sendable, Hashable, Codable, RawRepresentable, Comparable, CustomStringConvertible {
    /// Crockford base32: no `I`, `L`, `O` or `U`, so a ULID cannot be misread aloud.
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// The 26-character canonical form.
    public let rawValue: String

    /// Accepts only a well-formed 26-character Crockford base32 string, so an id that came
    /// back from the database and an id that came off disk cannot silently disagree.
    public init?(rawValue: String) {
        guard rawValue.count == 26, rawValue.allSatisfy({ ULID.alphabet.contains($0) }) else { return nil }
        self.rawValue = rawValue
    }

    /// A fresh identifier for `date`.
    public init(date: Date = Date()) {
        var characters = [Character]()
        characters.reserveCapacity(26)

        var milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000)) & 0xFFFF_FFFF_FFFF
        var timeCharacters = [Character]()
        for _ in 0 ..< 10 {
            timeCharacters.append(ULID.alphabet[Int(milliseconds & 0x1F)])
            milliseconds >>= 5
        }
        characters.append(contentsOf: timeCharacters.reversed())

        var randomness = [UInt8](repeating: 0, count: 10)
        for index in randomness.indices { randomness[index] = UInt8.random(in: 0 ... 255) }
        // 80 random bits do not divide into 5-bit groups from a byte array cleanly, so walk a
        // bit cursor rather than pretending they do.
        var bitOffset = 0
        for _ in 0 ..< 16 {
            var value = 0
            for _ in 0 ..< 5 {
                let byte = randomness[bitOffset / 8]
                let bit = (Int(byte) >> (7 - (bitOffset % 8))) & 1
                value = (value << 1) | bit
                bitOffset += 1
            }
            characters.append(ULID.alphabet[value])
        }
        rawValue = String(characters)
    }

    /// The millisecond timestamp encoded in the first ten characters.
    public var timestamp: Date {
        var milliseconds: UInt64 = 0
        for character in rawValue.prefix(10) {
            guard let index = ULID.alphabet.firstIndex(of: character) else { return .distantPast }
            milliseconds = (milliseconds << 5) | UInt64(index)
        }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    public var description: String { rawValue }

    public static func < (lhs: ULID, rhs: ULID) -> Bool { lhs.rawValue < rhs.rawValue }
}
