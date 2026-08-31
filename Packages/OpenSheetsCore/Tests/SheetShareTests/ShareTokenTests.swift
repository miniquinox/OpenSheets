import Foundation
import SheetModel
@testable import SheetShare
import Testing

/// The fixed values this suite and the relay's `test/token.spec.ts` share.
///
/// At file scope rather than nested in the suite because `@Test(arguments:)` needs them in an
/// attribute, and an attribute is not inside the type's member scope.
enum ShareTokenVectors {
    /// Bytes `00…0F` as unpadded base64url.
    static let deviceID = "AAECAwQFBgcICQoLDA0ODw"

    /// Bytes `00…1F` as unpadded base64url.
    static let secret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"

    static let token = "os1.\(deviceID).\(secret)"

    /// SHA-256 of ``token``, lowercase hex. The relay's spec carries this same literal.
    static let hash = "e3363d12c26a578a78211fc86f33a674e1aaa5f0d0b3c640eff9e7f7603845fc"

    /// D5, written the way the relay writes it — deliberately not derived from `ShareToken`'s
    /// own parser, because a parser cannot check itself.
    static let format = #"^os1\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}$"#

    /// Every near miss worth naming. The padded and `+`/`/` variants are what a reimplementation
    /// that reached for plain base64 would produce; the whitespace ones are what a paste out of
    /// a chat client produces.
    static let malformed: [String] = [
        "",
        "os1",
        "os1.",
        "os1.\(deviceID)",
        "os2.\(deviceID).\(secret)",
        "OS1.\(deviceID).\(secret)",
        "\(deviceID).\(secret)",
        "os1.\(deviceID).\(secret).extra",
        "os1.\(deviceID)x.\(secret)",
        "os1.\(deviceID).\(secret)x",
        "os1.\(deviceID).\(String(secret.dropLast()))",
        "os1.AAECAwQFBgcICQoLDA0OD+.\(secret)",
        "os1.AAECAwQFBgcICQoLDA0OD/.\(secret)",
        "os1.AAECAwQFBgcICQoLDA0OD=.\(secret)",
        " os1.\(deviceID).\(secret)",
        "os1.\(deviceID).\(secret) ",
    ]

    static func matchesFormat(_ text: String) throws -> Bool {
        try Regex(format).wholeMatch(in: text) != nil
    }
}

/// **The capability URL, minted and parsed.**
///
/// Everything here is a claim two codebases have to agree on. The relay's `src/token.ts` parses
/// the same strings with a regex written from the same paragraph, and it does so *before* it has
/// authenticated anything — a token this file accepts and that file rejects is a link that 404s
/// with no diagnosis available from either end. So the format is asserted against the regex in
/// ``ShareTokenVectors/format`` rather than against the parser that produced the string, and the
/// hash is asserted against a fixed vector the relay's `token.spec.ts` carries verbatim.
///
/// The vector's segments are the base64url of bytes `00…0F` and `00…1F`, so anyone can
/// regenerate it from first principles in either language rather than trusting a number
/// somebody pasted.
@Suite("Share tokens — the string two codebases have to agree on")
struct ShareTokenTests {
    // MARK: - Minting

    /// A hundred fresh tokens all match D5 exactly — right prefix, right segment lengths, right
    /// alphabet.
    ///
    /// A hundred rather than one because the alphabet is where this goes wrong: `+` and `/`
    /// appear in most random 32-byte base64 encodings, and a single sample can pass happily
    /// while the translation to base64url is missing.
    @Test func everyMintedTokenMatchesTheFormatTheRelayRoutesOn() throws {
        let deviceID = try ShareToken.newDeviceID()
        for _ in 0 ..< 100 {
            let token = try ShareToken.mint(deviceID: deviceID)
            let matches = try ShareTokenVectors.matchesFormat(token.rawValue)
            #expect(matches, "'\(token.rawValue)' is not a D5 token")
            #expect(token.deviceID == deviceID)
            #expect(token.secret.count == ShareToken.secretCharacterCount)
        }
    }

    /// Device ids come out of the same alphabet at their own length.
    @Test func mintedDeviceIdentifiersAreTwentyTwoBase64URLCharacters() throws {
        for _ in 0 ..< 100 {
            let deviceID = try ShareToken.newDeviceID()
            #expect(deviceID.count == ShareToken.deviceIDCharacterCount)
            #expect(ShareToken.isBase64URL(deviceID, count: ShareToken.deviceIDCharacterCount))
        }
    }

    /// A hundred mints against one device produce a hundred different secrets.
    ///
    /// This is the assertion that would catch a seeded or reused generator, which is the failure
    /// that matters: every other property of a token can be wrong and merely break the feature,
    /// but a predictable secret hands out the owner's folders.
    @Test func everyMintIsUnique() throws {
        let deviceID = try ShareToken.newDeviceID()
        var secrets = Set<String>()
        var hashes = Set<String>()
        for _ in 0 ..< 100 {
            let token = try ShareToken.mint(deviceID: deviceID)
            secrets.insert(token.secret)
            hashes.insert(token.hash)
        }
        #expect(secrets.count == 100)
        #expect(hashes.count == 100)
    }

    /// Minting refuses a device id it could not route, rather than producing a token the relay
    /// would drop.
    @Test func mintRefusesADeviceIdentifierItCouldNotRoute() {
        #expect(throws: SheetError.self) { try ShareToken.mint(deviceID: "too-short") }
        #expect(throws: SheetError.self) { try ShareToken.mint(deviceID: String(repeating: "A", count: 23)) }
        // A padded base64 device id: the shape a well-meaning reimplementation produces.
        #expect(throws: SheetError.self) { try ShareToken.mint(deviceID: "AAECAwQFBgcICQoLDA0OD=") }
    }

    // MARK: - Parsing

    /// The canonical text parses back into the token that produced it.
    @Test func theCanonicalTextParsesBackIntoTheSameToken() throws {
        let deviceID = try ShareToken.newDeviceID()
        let minted = try ShareToken.mint(deviceID: deviceID)
        let parsed = ShareToken(rawValue: minted.rawValue)
        #expect(parsed == minted)
        #expect(parsed?.hash == minted.hash)
    }

    /// The shared vector parses into its two segments.
    @Test func theSharedVectorParsesIntoItsSegments() {
        let token = ShareToken(rawValue: ShareTokenVectors.token)
        #expect(token?.deviceID == ShareTokenVectors.deviceID)
        #expect(token?.secret == ShareTokenVectors.secret)
    }

    /// Everything that is not a D5 token is refused, rather than trimmed, padded, or lowercased
    /// into one — and the relay's regex agrees about the same set.
    ///
    /// Repair would be the dangerous kindness here: a token that had to be fixed up is a token
    /// somebody mistyped, and the fixed-up version routes to a link they did not mean.
    @Test(arguments: ShareTokenVectors.malformed)
    func malformedTokensAreRefusedRatherThanRepaired(text: String) throws {
        #expect(ShareToken(rawValue: text) == nil, "'\(text)' should not parse")
        let matches = try ShareTokenVectors.matchesFormat(text)
        #expect(matches == false, "the relay's regex would have accepted '\(text)'")
    }

    // MARK: - Hashing

    /// The hash is the fixed vector, in lowercase hex, 64 characters.
    ///
    /// Pinned rather than recomputed: this number is what the relay stores and compares, so a
    /// change to it revokes every link in existence, and that has to be a decision rather than a
    /// diff nobody noticed.
    @Test func theHashIsTheStableHexTheRelayCompares() throws {
        let token = try #require(ShareToken(rawValue: ShareTokenVectors.token))
        #expect(token.hash == ShareTokenVectors.hash)
        #expect(token.hash.count == 64)
        #expect(token.hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// The hash covers the whole token, not just the secret.
    ///
    /// Which is what stops a stolen relay database from being replayed against another device's
    /// hub: the same secret under a different device id is a different stored value.
    @Test func theHashCoversTheWholeTokenNotJustTheSecret() throws {
        let first = try #require(
            ShareToken(deviceID: ShareTokenVectors.deviceID, secret: ShareTokenVectors.secret)
        )
        let second = try #require(
            ShareToken(deviceID: "BBECAwQFBgcICQoLDA0ODw", secret: ShareTokenVectors.secret)
        )
        #expect(first.hash != second.hash)
    }

    // MARK: - Leaking

    /// Interpolating a token prints its device id and nothing else.
    ///
    /// The relay logs ids and never bodies; the app logs link ids and never URLs. That policy
    /// survives exactly as long as nobody writes `"\(token)"` into a log line, so the type makes
    /// that line safe instead of relying on everyone remembering.
    @Test func aTokenNeverPrintsItsSecret() throws {
        let token = try #require(ShareToken(rawValue: ShareTokenVectors.token))
        let printed = "\(token)"
        #expect(printed.contains(ShareTokenVectors.secret) == false)
        #expect(printed.contains(ShareTokenVectors.deviceID))
        #expect(printed.hasSuffix("<redacted>"))
    }

    // MARK: - The URL the owner copies

    /// The link URL is the origin, the `/mcp/` path, and the token — nothing percent-encoded,
    /// nothing normalised.
    @Test func theLinkURLIsTheOriginPlusTheToken() throws {
        let token = try #require(ShareToken(rawValue: ShareTokenVectors.token))
        let configuration = try #require(CloudShareConfiguration(relayOrigin: "https://relay.example.workers.dev"))
        #expect(
            configuration.linkURL(for: token)
                == "https://relay.example.workers.dev/mcp/\(ShareTokenVectors.token)"
        )
    }

    /// A trailing slash on the origin does not become a double slash in the link.
    ///
    /// `OSCloudRelayURL` is typed by a human during development, and `https://host/` is what a
    /// browser's address bar hands you when you copy it.
    @Test func aTrailingSlashOnTheOriginDoesNotDoubleUp() throws {
        let token = try #require(ShareToken(rawValue: ShareTokenVectors.token))
        let configuration = try #require(CloudShareConfiguration(relayOrigin: "https://relay.example.workers.dev/"))
        #expect(
            configuration.linkURL(for: token)
                == "https://relay.example.workers.dev/mcp/\(ShareTokenVectors.token)"
        )
    }

    /// The compiled-in origin parses, which is what makes the `??` in
    /// `CloudShareConfiguration.standard` unreachable rather than merely unlikely — and since
    /// the 2026-08-30 deploy it is the real relay, not the placeholder sentinel.
    @Test func theCompiledRelayOriginParsesAndIsTheDeployedRelay() {
        #expect(
            CloudShareConfiguration.standard.relayOrigin.absoluteString
                == CloudShareConfiguration.standardRelayOrigin
        )
        #expect(!CloudShareConfiguration.standard.isPlaceholder)
        #expect(CloudShareConfiguration.standard.relayOrigin.scheme == "https")
    }

    /// The agent socket URL is the origin as a WebSocket, with the contract's path.
    @Test func theAgentURLIsTheOriginAsAWebSocket() throws {
        let secure = try #require(CloudShareConfiguration(relayOrigin: "https://relay.example.workers.dev"))
        let secureURL = try secure.agentURL()
        #expect(secureURL.absoluteString == "wss://relay.example.workers.dev/agent")
        // `wrangler dev` serves plain HTTP on localhost, and a second knob for that would be a
        // second knob to get wrong.
        let local = try #require(CloudShareConfiguration(relayOrigin: "http://127.0.0.1:8787"))
        let localURL = try local.agentURL()
        #expect(localURL.absoluteString == "ws://127.0.0.1:8787/agent")
    }

    /// An origin that is not http(s) throws rather than producing a URL nobody chose — including
    /// the `file:` sentinel that `standard`'s unreachable branch would use.
    @Test func anOriginThatIsNotHTTPRefusesToBecomeASocket() {
        let sentinel = CloudShareConfiguration(relayOrigin: URL(fileURLWithPath: "/dev/null"))
        #expect(throws: SheetError.self) { try sentinel.agentURL() }
    }

    /// An origin that is not a URL at all is refused at construction.
    @Test func anOriginThatIsNotAURLIsRefusedAtConstruction() {
        #expect(CloudShareConfiguration(relayOrigin: "not a url") == nil)
        #expect(CloudShareConfiguration(relayOrigin: "/just/a/path") == nil)
    }
}
