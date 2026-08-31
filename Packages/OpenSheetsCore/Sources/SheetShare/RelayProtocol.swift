import Foundation
import SheetModel

/// Wire contract A: the messages the Mac and the relay send each other over the agent socket.
///
/// # Why this is a hand-written codec
///
/// The other end of this socket is TypeScript running in a Cloudflare Worker. There is no shared
/// schema, no code generation, and no way to make a change on one side fail to compile on the
/// other — the only thing keeping the two halves honest is that both were written from the same
/// paragraph, and that the bytes this file produces are pinned by a test that spells them out as
/// literals. Synthesised `Codable` would have given us `linkID` on the wire the moment somebody
/// renamed a property, so the keys are written down explicitly instead. The repository already
/// draws this line the same way: OOXML attributes keep their `sheetId` spelling in `CodingKeys`
/// while the Swift property is `sheetID`.
///
/// # The two rules that make it survivable
///
/// **Unknown message types decode, they do not throw.** A relay deployed after this build sends
/// a `type` this enum has never heard of; the honest response is to ignore that message and keep
/// the socket, not to tear down a working connection over a field we do not need. That is what
/// ``RelayMessage/unknown(type:)`` is for. Unknown *fields* inside a known message are ignored by
/// `Decodable` already.
///
/// **A known type with a missing field does throw.** That is not forward compatibility, it is a
/// contract violation, and swallowing it would turn a relay bug into a link that silently never
/// answers. The socket owner logs it and reconnects.
public enum RelayMessage: Sendable, Equatable {
    /// Mandatory first message. Replaces the relay's entire link table for this device, which is
    /// what heals the drift a Time Machine restore introduces.
    case hello(deviceID: String, appVersion: String, links: [RelayLink])

    /// One link created or revoked, sent as it happens so a revoke does not wait for a reconnect.
    case linkUpsert(RelayLink)

    /// The answer to a ``request``, correlated by the relay's own id.
    case response(requestID: String, outcome: RelayResponseOutcome)

    /// The relay accepted ``hello`` and has finished installing the link table.
    case helloAck(version: Int)

    /// The relay applied a ``linkUpsert``.
    case ack(operation: String, linkID: String)

    /// An MCP frame from a client, to be written to that link's subprocess.
    case request(requestID: String, linkID: String, expectsReply: Bool, body: String)

    /// The relay is about to close the socket. `code` is diagnostic text, not an enum, because
    /// the relay may learn new reasons before this build does.
    case failure(code: String)

    /// A message whose `type` this build does not know. Carried rather than discarded so the
    /// socket owner can log what it skipped.
    case unknown(type: String)

    /// The protocol version carried by ``hello`` and ``helloAck``.
    public static let version = 1
}

/// One row of the relay's link table: everything it needs to route, and nothing that would let
/// it mint or widen anything.
///
/// Note what is absent. There is no mode here — `read_only` versus `read_write` is enforced on
/// the Mac by which tools the subprocess is spawned with, so telling the relay would be handing
/// out a decision it has no business making. There is no name, no path, and no token: the relay
/// stores the hash, compares hashes, and cannot recover the credential from what it holds.
public struct RelayLink: Sendable, Equatable, Codable {
    /// The link's local identifier — a ULID's text. The relay treats it as an opaque string it
    /// echoes back on requests.
    public var linkID: String

    /// Lowercase hex of SHA-256 over the whole `os1.…` token. See ``ShareToken/hash``.
    public var tokenHash: String

    /// Revoked links stay in the table so the relay answers 404 rather than "unknown device".
    public var revoked: Bool

    public init(linkID: String, tokenHash: String, revoked: Bool) {
        self.linkID = linkID
        self.tokenHash = tokenHash
        self.revoked = revoked
    }

    private enum CodingKeys: String, CodingKey {
        case linkID = "linkId"
        case tokenHash
        case revoked
    }
}

/// What came back from a link's subprocess.
///
/// The relay does not interpret ``failed``: any error becomes the same JSON-RPC `-32000` body it
/// sends when the Mac is offline, with the caller's id echoed. The string is therefore diagnostic
/// — it exists so a log line on either side says which of the several ways this can go wrong
/// actually happened.
public enum RelayResponseOutcome: Sendable, Equatable {
    case ok(body: String)
    case failed(error: String)

    /// The spellings the app sends, written down so the two agents that produce them and the
    /// relay operator reading logs all use the same words.
    public enum Failure {
        /// The subprocess died, or its pipe closed, while the frame was in flight.
        public static let subprocessFailed = "subprocess_failed"
        /// The local database says this link is revoked. Authoritative — checked per request,
        /// after the relay's own check, because the relay's copy can be stale.
        public static let linkRevoked = "link_revoked"
        /// The frame exceeded the bridge's 32 MB ceiling.
        public static let frameTooLarge = "frame_too_large"
    }
}

// MARK: - Coding

extension RelayMessage: Codable {
    /// Every key that appears anywhere in contract A. One flat set rather than one per case: the
    /// messages share `type`, `requestId` and `linkId`, and three near-identical key enums is
    /// how those three drift apart.
    private enum Key: String, CodingKey {
        case type
        case version = "v"
        case deviceID = "deviceId"
        case appVersion
        case links
        case link
        case requestID = "requestId"
        case status
        case body
        case error
        case operation = "op"
        case linkID = "linkId"
        case expectsReply
        case code
    }

    /// The `type` values on the wire. Snake case, because the relay is TypeScript and this is the
    /// spelling in the contract.
    private enum WireType: String {
        case hello
        case linkUpsert = "link_upsert"
        case response
        case helloAck = "hello_ack"
        case ack
        case request
        case error
    }

    private enum Status {
        static let ok = "ok"
        static let error = "error"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        // A message with no `type` at all is treated like an unknown one rather than an error:
        // the socket should survive a relay that sends something malformed, and there is nothing
        // useful to do with the message either way.
        let rawType = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        guard let wireType = WireType(rawValue: rawType) else {
            self = .unknown(type: rawType)
            return
        }
        switch wireType {
        case .hello:
            self = .hello(
                deviceID: try container.decode(String.self, forKey: .deviceID),
                appVersion: try container.decode(String.self, forKey: .appVersion),
                links: try container.decode([RelayLink].self, forKey: .links)
            )
        case .linkUpsert:
            self = .linkUpsert(try container.decode(RelayLink.self, forKey: .link))
        case .response:
            let requestID = try container.decode(String.self, forKey: .requestID)
            let status = try container.decode(String.self, forKey: .status)
            switch status {
            case Status.ok:
                self = .response(requestID: requestID, outcome: .ok(body: try container.decode(String.self, forKey: .body)))
            case Status.error:
                self = .response(
                    requestID: requestID,
                    outcome: .failed(error: try container.decode(String.self, forKey: .error))
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "a response status is 'ok' or 'error', not '\(status)'"
                )
            }
        case .helloAck:
            self = .helloAck(version: try container.decode(Int.self, forKey: .version))
        case .ack:
            self = .ack(
                operation: try container.decode(String.self, forKey: .operation),
                linkID: try container.decode(String.self, forKey: .linkID)
            )
        case .request:
            self = .request(
                requestID: try container.decode(String.self, forKey: .requestID),
                linkID: try container.decode(String.self, forKey: .linkID),
                expectsReply: try container.decode(Bool.self, forKey: .expectsReply),
                body: try container.decode(String.self, forKey: .body)
            )
        case .error:
            self = .failure(code: try container.decode(String.self, forKey: .code))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .hello(deviceID, appVersion, links):
            try container.encode(WireType.hello.rawValue, forKey: .type)
            try container.encode(RelayMessage.version, forKey: .version)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(appVersion, forKey: .appVersion)
            try container.encode(links, forKey: .links)
        case let .linkUpsert(link):
            try container.encode(WireType.linkUpsert.rawValue, forKey: .type)
            try container.encode(link, forKey: .link)
        case let .response(requestID, outcome):
            try container.encode(WireType.response.rawValue, forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            switch outcome {
            case let .ok(body):
                try container.encode(Status.ok, forKey: .status)
                try container.encode(body, forKey: .body)
            case let .failed(error):
                try container.encode(Status.error, forKey: .status)
                try container.encode(error, forKey: .error)
            }
        case let .helloAck(version):
            try container.encode(WireType.helloAck.rawValue, forKey: .type)
            try container.encode(version, forKey: .version)
        case let .ack(operation, linkID):
            try container.encode(WireType.ack.rawValue, forKey: .type)
            try container.encode(operation, forKey: .operation)
            try container.encode(linkID, forKey: .linkID)
        case let .request(requestID, linkID, expectsReply, body):
            try container.encode(WireType.request.rawValue, forKey: .type)
            try container.encode(requestID, forKey: .requestID)
            try container.encode(linkID, forKey: .linkID)
            try container.encode(expectsReply, forKey: .expectsReply)
            try container.encode(body, forKey: .body)
        case let .failure(code):
            try container.encode(WireType.error.rawValue, forKey: .type)
            try container.encode(code, forKey: .code)
        case let .unknown(type):
            // Re-emitted rather than refused so that round-tripping is total. The app never
            // sends one; a test does, and a total round trip is easier to trust than a
            // documented hole in one.
            try container.encode(type, forKey: .type)
        }
    }
}

extension RelayMessage {
    /// The exact bytes that go on the socket.
    ///
    /// Sorted keys are the whole point: the encoding has to be a function of the value and
    /// nothing else, or the pinned-bytes test is checking `JSONEncoder`'s dictionary ordering
    /// rather than this contract. Slashes are left unescaped because ``body`` carries JSON-RPC
    /// frames full of paths, and `"\/Users\/x"` in a relay log is a path nobody can grep for.
    /// This is the `PersistedWorkspaceTree.encodedJSON()` idiom, for the same reason.
    public func encodedJSON() throws(SheetError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(self)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SheetError.internalInconsistency(detail: "a relay message encoded to bytes that are not UTF-8")
            }
            return text
        } catch let error as SheetError {
            throw error
        } catch {
            throw SheetError.invalidArgument(name: "relay message", reason: "\(error)")
        }
    }

    /// Parses one line off the socket.
    ///
    /// Unknown `type`s land on ``unknown(type:)`` rather than throwing — see the type's note.
    /// What throws is text that is not JSON, and a known message missing a field it needs.
    public static func decode(_ text: String) throws(SheetError) -> RelayMessage {
        try decode(Data(text.utf8))
    }

    public static func decode(_ data: Data) throws(SheetError) -> RelayMessage {
        do {
            return try JSONDecoder().decode(RelayMessage.self, from: data)
        } catch {
            throw SheetError.invalidArgument(name: "relay message", reason: "\(error)")
        }
    }
}
