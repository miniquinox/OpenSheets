import Foundation
import SheetModel

/// The JSON-RPC 2.0 frames MCP is carried in.
///
/// Only the three shapes the protocol actually uses: a request (has an `id`, expects a
/// response), a notification (no `id`, expects nothing back), and a response. Batches are
/// deliberately unimplemented — MCP's stdio transport removed them in the 2025-06-18 revision,
/// and accepting one would mean deciding what a partially failed batch looks like on a
/// transport where nobody sends them.
public enum JSONRPC {
    /// `"2.0"`, always.
    public static let version = "2.0"

    /// The reserved error codes, plus the one range MCP servers get to define.
    public enum ErrorCode: Int, Sendable, Hashable, CaseIterable {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
        /// Everything this server refuses for its own reasons — a denied path, a malformed
        /// range. Inside the `-32000 … -32099` implementation-defined band.
        case toolError = -32000
    }

    /// One inbound frame.
    public struct Request: Sendable, Hashable {
        /// Absent for a notification. Kept as a ``JSONValue`` because the spec allows a string
        /// or a number and the response must echo the same spelling.
        public var id: JSONValue?
        public var method: String
        public var params: JSONValue

        public init(id: JSONValue?, method: String, params: JSONValue = .object([:])) {
            self.id = id
            self.method = method
            self.params = params
        }

        /// Whether this frame expects a response.
        public var isNotification: Bool { id == nil }

        /// Reads a frame, checking the envelope this server relies on.
        public static func decode(_ value: JSONValue) throws(SheetError) -> Request {
            guard case let .object(members) = value else {
                throw SheetError.invalidToolArguments(tool: "jsonrpc", detail: "the frame is not an object")
            }
            guard let method = members["method"]?.stringValue else {
                throw SheetError.invalidToolArguments(tool: "jsonrpc", detail: "no `method`")
            }
            // A `null` id is legal JSON but means "notification" nowhere: the spec reserves it
            // for a response to an unparseable request. Treating it as a notification is the
            // reading that never leaves a client waiting.
            let id = members["id"].flatMap { $0.isNull ? nil : $0 }
            return Request(id: id, method: method, params: members["params"] ?? .object([:]))
        }
    }

    /// One outbound frame.
    public struct Response: Sendable, Hashable {
        public var id: JSONValue
        public var result: JSONValue?
        public var error: Failure?

        public static func success(id: JSONValue, result: JSONValue) -> Response {
            Response(id: id, result: result, error: nil)
        }

        public static func failure(id: JSONValue, _ failure: Failure) -> Response {
            Response(id: id, result: nil, error: failure)
        }

        /// The frame as it goes on the wire.
        public var payload: JSONValue {
            var members: [String: JSONValue] = ["jsonrpc": .string(JSONRPC.version), "id": id]
            if let error {
                members["error"] = error.payload
            } else {
                members["result"] = result ?? .object([:])
            }
            return .object(members)
        }
    }

    /// A JSON-RPC error object.
    public struct Failure: Sendable, Hashable {
        public var code: Int
        public var message: String
        /// The ``SheetModel/SheetError/code`` and category, so a client can branch on the
        /// failure without parsing English.
        public var data: JSONValue?

        public init(code: ErrorCode, message: String, data: JSONValue? = nil) {
            self.code = code.rawValue
            self.message = message
            self.data = data
        }

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        /// Wraps a ``SheetModel/SheetError``, preserving its stable dotted code.
        public init(_ error: SheetError, code: ErrorCode = .toolError) {
            self.code = code.rawValue
            message = error.message
            data = .object([
                "code": .string(error.code),
                "category": .string(error.category.rawValue),
            ])
        }

        var payload: JSONValue {
            var members: [String: JSONValue] = ["code": .integer(code), "message": .string(message)]
            if let data { members["data"] = data }
            return .object(members)
        }
    }
}
