import Foundation
import SheetModel
@testable import SheetShare
import Testing

/// The values every case in this suite is built from, at file scope so `@Test(arguments:)` can
/// reach them.
enum RelayProtocolFixtures {
    static let deviceID = ShareTokenVectors.deviceID
    static let tokenHash = ShareTokenVectors.hash

    /// A ULID's text. Opaque to the relay, which only ever echoes it.
    static let linkID = "01HZY6X7QG9F0Z8T3B5N2K4M6P"

    static let requestID = "r-7"

    /// A JSON-RPC frame, with a `/` in it on purpose: `tools/list` is the method the very first
    /// call a client makes uses, and it is what proves the encoder leaves slashes alone.
    static let requestBody = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#

    static let responseBody = #"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#

    static let activeLink = RelayLink(linkID: linkID, tokenHash: tokenHash, revoked: false)
    static let revokedLink = RelayLink(linkID: linkID, tokenHash: tokenHash, revoked: true)

    /// One of every case, including the forward-compatibility one.
    static let everyMessage: [RelayMessage] = [
        .hello(deviceID: deviceID, appVersion: "0.1.0", links: [activeLink]),
        .hello(deviceID: deviceID, appVersion: "0.1.0", links: []),
        .linkUpsert(revokedLink),
        .response(requestID: requestID, outcome: .ok(body: responseBody)),
        .response(requestID: requestID, outcome: .failed(error: RelayResponseOutcome.Failure.subprocessFailed)),
        .helloAck(version: RelayMessage.version),
        .ack(operation: "link_upsert", linkID: linkID),
        .request(requestID: requestID, linkID: linkID, expectsReply: true, body: requestBody),
        .request(requestID: requestID, linkID: linkID, expectsReply: false, body: requestBody),
        .failure(code: "auth_failed"),
        .unknown(type: "something_from_the_future"),
    ]
}

/// **Wire contract A, byte for byte.**
///
/// The expected strings below are literals, not values produced by the encoder. That is the
/// whole point: the other end of this socket is TypeScript, it was written from the same
/// paragraph in the plan, and nothing in either build system would notice the two drifting
/// apart. A test that asserted `decode(encode(x)) == x` would pass just as happily with every
/// key renamed. So the bytes are written out by hand, sorted the way the encoder sorts them, and
/// a rename has to be a deliberate edit here before it can ship.
///
/// The two forward-compatibility rules are asserted as carefully as the bytes are, because they
/// decide whether a relay deploy can ever roll out ahead of an app release: an unknown message
/// type must not close a working socket, while a known type missing a field must not be
/// swallowed into a link that silently never answers.
@Suite("The relay wire contract, byte for byte")
struct RelayProtocolTests {
    // MARK: - App → relay, pinned

    /// `hello` — the mandatory first message, carrying the whole link table.
    @Test func helloEncodesToTheBytesTheRelayParses() throws {
        let message = RelayMessage.hello(
            deviceID: RelayProtocolFixtures.deviceID,
            appVersion: "0.1.0",
            links: [RelayProtocolFixtures.activeLink]
        )
        let expected = #"""
        {"appVersion":"0.1.0","deviceId":"\#(RelayProtocolFixtures.deviceID)","links":[{"linkId":"\#(RelayProtocolFixtures.linkID)","revoked":false,"tokenHash":"\#(RelayProtocolFixtures.tokenHash)"}],"type":"hello","v":1}
        """#
        #expect(try message.encodedJSON() == expected)
    }

    /// A device with no links is a valid `hello`, and the relay clears its table for it. The
    /// empty array has to be present rather than omitted, or "no links" would be
    /// indistinguishable from "field missing" on the other side.
    @Test func helloWithNoLinksStillSendsTheEmptyTable() throws {
        let message = RelayMessage.hello(deviceID: RelayProtocolFixtures.deviceID, appVersion: "0.1.0", links: [])
        let expected = #"""
        {"appVersion":"0.1.0","deviceId":"\#(RelayProtocolFixtures.deviceID)","links":[],"type":"hello","v":1}
        """#
        #expect(try message.encodedJSON() == expected)
    }

    /// `link_upsert` — one revocation, sent the moment it happens rather than at the next
    /// reconnect.
    @Test func linkUpsertEncodesToTheBytesTheRelayParses() throws {
        let message = RelayMessage.linkUpsert(RelayProtocolFixtures.revokedLink)
        let expected = #"""
        {"link":{"linkId":"\#(RelayProtocolFixtures.linkID)","revoked":true,"tokenHash":"\#(RelayProtocolFixtures.tokenHash)"},"type":"link_upsert"}
        """#
        #expect(try message.encodedJSON() == expected)
    }

    /// Both `response` shapes. `status` decides which of `body` and `error` is present, and
    /// exactly one of them ever is.
    @Test func bothResponseShapesEncodeToTheBytesTheRelayParses() throws {
        let ok = RelayMessage.response(
            requestID: RelayProtocolFixtures.requestID,
            outcome: .ok(body: RelayProtocolFixtures.responseBody)
        )
        let okExpected = #"""
        {"body":"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}","requestId":"r-7","status":"ok","type":"response"}
        """#
        #expect(try ok.encodedJSON() == okExpected)

        let failed = RelayMessage.response(
            requestID: RelayProtocolFixtures.requestID,
            outcome: .failed(error: RelayResponseOutcome.Failure.subprocessFailed)
        )
        let failedExpected = #"""
        {"error":"subprocess_failed","requestId":"r-7","status":"error","type":"response"}
        """#
        #expect(try failed.encodedJSON() == failedExpected)
    }

    /// A JSON-RPC frame goes across as a string, and the slashes inside it stay slashes.
    ///
    /// `withoutEscapingSlashes` is not cosmetic: the bodies carry file paths and method names
    /// like `tools/list`, and `"\/Users\/x"` in a relay log is a path nobody can grep for.
    @Test func slashesInsideAFrameAreNotEscaped() throws {
        let message = RelayMessage.response(
            requestID: RelayProtocolFixtures.requestID,
            outcome: .ok(body: RelayProtocolFixtures.requestBody)
        )
        let encoded = try message.encodedJSON()
        #expect(encoded.contains(#"tools/list"#))
        #expect(encoded.contains(#"tools\/list"#) == false)
    }

    // MARK: - Relay → app, from the contract's own samples

    /// The four relay-to-app samples in the contract decode into the cases they name.
    ///
    /// Written as the contract writes them — unsorted keys, exactly as a hand-written TypeScript
    /// `JSON.stringify` emits them — because that is what will actually arrive. The encoder's
    /// sorted output is a property of what we *send*, not a constraint on what we accept.
    @Test func theContractsOwnRelayToAppSamplesDecode() throws {
        #expect(try RelayMessage.decode(#"{"type":"hello_ack","v":1}"#) == .helloAck(version: 1))

        let ack = #"{"type":"ack","op":"link_upsert","linkId":"\#(RelayProtocolFixtures.linkID)"}"#
        #expect(try RelayMessage.decode(ack) == .ack(operation: "link_upsert", linkID: RelayProtocolFixtures.linkID))

        let request = #"""
        {"type":"request","requestId":"r-7","linkId":"\#(RelayProtocolFixtures.linkID)","expectsReply":true,"body":"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}"}
        """#
        #expect(try RelayMessage.decode(request) == .request(
            requestID: "r-7",
            linkID: RelayProtocolFixtures.linkID,
            expectsReply: true,
            body: RelayProtocolFixtures.requestBody
        ))

        #expect(try RelayMessage.decode(#"{"type":"error","code":"auth_failed"}"#) == .failure(code: "auth_failed"))
    }

    /// A notification carries `expectsReply:false`, and the app must be able to tell that from a
    /// missing field — it is the difference between writing a frame and writing a frame *and*
    /// waiting forever for a line the server will never emit.
    @Test func aNotificationRequestSaysSoRatherThanOmittingTheFlag() throws {
        let notification = #"""
        {"type":"request","requestId":"r-7","linkId":"\#(RelayProtocolFixtures.linkID)","expectsReply":false,"body":"{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"}
        """#
        let decoded = try RelayMessage.decode(notification)
        guard case let .request(_, _, expectsReply, _) = decoded else {
            Issue.record("expected a request, got \(decoded)")
            return
        }
        #expect(expectsReply == false)
    }

    // MARK: - Round trip

    /// Every case survives encode → decode unchanged.
    @Test(arguments: RelayProtocolFixtures.everyMessage)
    func everyMessageRoundTrips(message: RelayMessage) throws {
        let encoded = try message.encodedJSON()
        #expect(try RelayMessage.decode(encoded) == message)
    }

    /// Encoding twice produces the same bytes.
    ///
    /// `.sortedKeys` is what makes this true, and it is the property the pinned literals above
    /// are actually resting on: without it those tests would be asserting a dictionary's
    /// iteration order.
    @Test(arguments: RelayProtocolFixtures.everyMessage)
    func encodingIsAFunctionOfTheValue(message: RelayMessage) throws {
        #expect(try message.encodedJSON() == message.encodedJSON())
    }

    // MARK: - Forward compatibility

    /// A type this build has never heard of decodes to ``RelayMessage/unknown(type:)`` instead
    /// of throwing.
    ///
    /// This is the rule that lets the relay deploy ahead of the app. Throwing here would mean a
    /// new relay feature tears down every connected Mac's socket on its first broadcast.
    @Test func anUnknownTypeIsIgnoredRatherThanFatal() throws {
        let decoded = try RelayMessage.decode(#"{"type":"quota_warning","remaining":17}"#)
        #expect(decoded == .unknown(type: "quota_warning"))
    }

    /// A message with no `type` at all is treated the same way, for the same reason: there is
    /// nothing useful to do with it, and the socket is worth more than the complaint.
    @Test func aMessageWithNoTypeIsIgnoredRatherThanFatal() throws {
        #expect(try RelayMessage.decode(#"{"remaining":17}"#) == .unknown(type: ""))
    }

    /// Fields a future relay adds to a message this build *does* know are ignored.
    @Test func unknownFieldsInsideAKnownMessageAreIgnored() throws {
        let decoded = try RelayMessage.decode(#"{"type":"hello_ack","v":1,"region":"iad","hibernating":true}"#)
        #expect(decoded == .helloAck(version: 1))
    }

    /// A known type missing a field it needs throws.
    ///
    /// The opposite of the rule above, and deliberately so. This is not a relay that got ahead
    /// of us, it is a relay that is wrong, and swallowing it would produce a link that accepts
    /// requests and never answers them — the single hardest failure to diagnose from either end.
    @Test(arguments: [
        #"{"type":"request","requestId":"r-7","linkId":"01HZY6X7QG9F0Z8T3B5N2K4M6P"}"#,
        #"{"type":"ack","op":"link_upsert"}"#,
        #"{"type":"error"}"#,
        #"{"type":"hello_ack"}"#,
        #"{"type":"link_upsert","link":{"linkId":"x"}}"#,
    ])
    func aKnownMessageMissingAFieldThrows(text: String) {
        #expect(throws: SheetError.self) { try RelayMessage.decode(text) }
    }

    /// A `response` status that is neither `ok` nor `error` throws rather than guessing which
    /// half of the message to read.
    @Test func anUnrecognisedResponseStatusThrows() {
        #expect(throws: SheetError.self) {
            try RelayMessage.decode(#"{"type":"response","requestId":"r-7","status":"maybe","body":"{}"}"#)
        }
    }

    /// Text that is not JSON throws, with the offending value named.
    @Test func textThatIsNotJSONThrows() {
        #expect(throws: SheetError.self) { try RelayMessage.decode("not json") }
        #expect(throws: SheetError.self) { try RelayMessage.decode("") }
    }

    // MARK: - The link row

    /// `RelayLink` carries the three fields the relay routes on and nothing else — no mode, no
    /// name, no token.
    ///
    /// Asserted on the encoded keys rather than by reading the struct, because the claim is
    /// about what crosses the wire. Mode is the one worth naming: `read_only` versus
    /// `read_write` is enforced by which tools the Mac spawns the subprocess with, so sending it
    /// would hand the relay a decision it has no business making.
    @Test func aLinkRowCarriesNothingTheRelayDoesNotRouteOn() throws {
        let encoded = try RelayMessage.linkUpsert(RelayProtocolFixtures.activeLink).encodedJSON()
        #expect(encoded.contains("read_only") == false)
        #expect(encoded.contains("mode") == false)
        #expect(encoded.contains("name") == false)
        #expect(encoded.contains(ShareTokenVectors.secret) == false)
        #expect(encoded.contains(RelayProtocolFixtures.tokenHash))
    }
}
