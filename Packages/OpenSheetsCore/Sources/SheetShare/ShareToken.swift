import CryptoKit
import Foundation
import SheetModel
import Security

/// The credential inside a share link: `os1.<deviceId>.<secret>`.
///
/// # Why the shape is pinned this precisely
///
/// Two programs written in two languages have to agree about this string to the character. The
/// Mac mints it and hands it to a person; the relay reads it out of a URL path, splits it, and
/// routes on the middle segment before it has authenticated anything. If either side is one
/// character off about how long a segment is or which alphabet it uses, the failure is a link
/// that 404s for reasons nobody can see from either end. So the format is spelled out here as
/// constants and a parser rather than as a convention, and the same constants appear in the
/// relay's `src/token.ts`.
///
/// The layout is `os1` (a version marker, so a v2 token can be told apart rather than
/// misparsed), the device's 22-character identifier, and 43 characters of secret. Both segments
/// are unpadded base64url, which is exactly the alphabet a URL path accepts without escaping —
/// the whole token survives copy, paste, and a mail client's link detector unmangled.
///
/// # What the entropy buys
///
/// The secret is 32 random bytes from the system CSPRNG: 256 bits. There is no rate limiting on
/// the relay and there does not need to be, because guessing one is not a thing that happens.
/// The device id is 16 bytes for the same reason — the relay's Durable Object is addressed by
/// it, so an unguessable id is what keeps a stranger from opening a socket to somebody else's
/// hub before that hub has registered its secret.
///
/// # What this type deliberately is not
///
/// Not `Codable`. A token that can be encoded by accident is a token that ends up in a log line,
/// a crash report, or a JSON payload somebody pastes into an issue. The one place the plaintext
/// is stored is the `share_link.url` column, written by the app on purpose, and the reason that
/// column is acceptable is the deny-list entry that keeps the tools out of the directory holding
/// it. ``description`` redacts for the same reason: interpolating a token into a message is a
/// mistake this type refuses to make on your behalf.
public struct ShareToken: Sendable, Equatable, RawRepresentable, CustomStringConvertible {
    /// The version marker. A future format bumps this rather than changing the segments, so an
    /// old client rejects a new token instead of routing it somewhere wrong.
    public static let scheme = "os1"

    /// 16 random bytes, which is 22 unpadded base64url characters.
    public static let deviceIDByteCount = 16
    public static let deviceIDCharacterCount = 22

    /// 32 random bytes, which is 43 unpadded base64url characters.
    public static let secretByteCount = 32
    public static let secretCharacterCount = 43

    /// The routing segment. Identifies the Mac, not the link: every link a device issues carries
    /// the same one, which is what lets the relay pick a hub before authenticating.
    public let deviceID: String

    /// The bearer half. 256 bits, unique per link.
    public let secret: String

    /// The canonical text: `os1.<deviceId>.<secret>`.
    public var rawValue: String { "\(Self.scheme).\(deviceID).\(secret)" }

    /// Redacted on purpose — see the type's note. Prints the routing segment, which is not a
    /// credential, and says the rest is missing rather than pretending the value is short.
    public var description: String { "\(Self.scheme).\(deviceID).<redacted>" }

    /// The identifier the relay stores and compares: lowercase hex of SHA-256 over the whole
    /// ``rawValue``, including the `os1.` prefix and both dots.
    ///
    /// Over the full string rather than the secret alone so that a token is only ever equal to
    /// itself: the same secret minted under a different device id hashes differently, and a
    /// stolen relay database cannot be replayed against another device's hub.
    public var hash: String { Self.sha256Hex(rawValue) }

    /// Accepts only a well-formed pair, so a token that came out of the database and a token
    /// that came off a URL cannot silently disagree.
    public init?(deviceID: String, secret: String) {
        guard Self.isBase64URL(deviceID, count: Self.deviceIDCharacterCount),
              Self.isBase64URL(secret, count: Self.secretCharacterCount)
        else { return nil }
        self.deviceID = deviceID
        self.secret = secret
    }

    /// Parses the canonical text. Exactly three dot-separated segments, exact lengths, exact
    /// alphabet — nothing is trimmed, lowercased, or otherwise repaired first, because a token
    /// that needed repairing is a token somebody mistyped, and routing it would answer the wrong
    /// question.
    public init?(rawValue: String) {
        let segments = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments[0] == Self.scheme else { return nil }
        self.init(deviceID: String(segments[1]), secret: String(segments[2]))
    }

    /// A fresh token for a device.
    ///
    /// Throws rather than trapping when the system CSPRNG refuses: `SecRandomCopyBytes` failing
    /// is not something to paper over with `arc4random`, because the fallback would be a
    /// credential nobody can reason about.
    public static func mint(deviceID: String) throws(SheetError) -> ShareToken {
        guard isBase64URL(deviceID, count: deviceIDCharacterCount) else {
            throw .invalidArgument(
                name: "deviceId",
                reason: "a device id is \(deviceIDCharacterCount) base64url characters, not '\(deviceID)'"
            )
        }
        let secret = base64URL(try randomBytes(secretByteCount))
        guard let token = ShareToken(deviceID: deviceID, secret: secret) else {
            throw .internalInconsistency(detail: "minted a share secret that does not match its own format")
        }
        return token
    }

    /// A fresh device identifier: 16 random bytes as 22 base64url characters.
    public static func newDeviceID() throws(SheetError) -> String {
        base64URL(try randomBytes(deviceIDByteCount))
    }

    // MARK: - Primitives the rest of SheetShare shares

    /// Bytes from the system CSPRNG, or a typed error naming the OSStatus.
    static func randomBytes(_ count: Int) throws(SheetError) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw .internalInconsistency(detail: "the system random number generator refused (OSStatus \(status))")
        }
        return bytes
    }

    /// Unpadded base64url. The `=` padding is dropped because the length is fixed by the byte
    /// count, so the padding carries no information and `=` is the one base64 character a URL
    /// path would rather not see.
    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Lowercase hex of SHA-256 over the string's UTF-8 bytes. Lowercase because that is what
    /// `crypto.subtle.digest` plus the relay's hex loop produces, and a case mismatch would make
    /// every comparison fail in a way that looks like a revoked link.
    static func sha256Hex(_ text: String) -> String {
        let digits = Array("0123456789abcdef")
        let digest = SHA256.hash(data: Data(text.utf8))
        return String(digest.flatMap { byte in
            [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
        })
    }

    /// Exactly `count` characters from the base64url alphabet. ASCII-only by construction: the
    /// unicode scalar test rejects anything a homoglyph attack would reach for.
    static func isBase64URL(_ text: String, count: Int) -> Bool {
        guard text.count == count else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A" ... "Z", "a" ... "z", "0" ... "9", "-", "_": true
            default: false
            }
        }
    }
}
