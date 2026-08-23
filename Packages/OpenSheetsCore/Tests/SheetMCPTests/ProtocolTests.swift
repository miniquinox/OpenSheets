import Darwin
import Foundation
@testable import SheetMCP
import SheetModel
import SheetStore
import Testing

/// The wire: JSON, framing, the handshake, and the one rule that makes stdio usable.
@Suite struct ProtocolTests {
    // MARK: - JSON

    /// Integers survive the round trip as integers.
    ///
    /// A JSON-RPC `id` that arrives as `3` and goes back as `3.0` is unmatched by some clients,
    /// and the failure looks like the server never answered.
    @Test func integersDoNotBecomeFloats() throws {
        let parsed = try JSONValue.parse(#"{"id":3,"ratio":1.5,"big":9007199254740991}"#)
        #expect(parsed["id"] == .integer(3))
        #expect(parsed["ratio"] == .number(1.5))
        #expect(parsed.rendered.contains("\"id\":3"))
        #expect(!parsed.rendered.contains("3.0"))
    }

    /// Object keys are sorted, so a frame is byte-reproducible.
    @Test func renderingIsDeterministic() {
        let value = JSONValue.object(["zulu": 1, "alpha": 2, "mike": 3])
        #expect(value.rendered == #"{"alpha":2,"mike":3,"zulu":1}"#)
    }

    /// Every character that could break the transport is escaped.
    ///
    /// U+2028 is the one worth a test of its own: it is a *line terminator in JavaScript*, and
    /// an MCP client reading newline-delimited frames in JavaScript would see a cell containing
    /// one as the end of a frame. Spreadsheet content deciding where a protocol message ends is
    /// exactly the failure this server must not have.
    @Test func javascriptLineTerminatorsAreEscaped() {
        let value = JSONValue.string("before\u{2028}after\u{2029}end\nreal newline\ttab")
        let rendered = value.rendered
        #expect(!rendered.contains("\u{2028}"))
        #expect(!rendered.contains("\u{2029}"))
        #expect(rendered.contains("\\u2028"))
        #expect(rendered.contains("\\n"))
        // And it still parses back to what went in.
        let round = try? JSONValue.parse("[\(rendered)]")
        #expect(round?.arrayValue?.first == value)
    }

    /// Malformed JSON produces a parse error, not a crash.
    @Test func malformedJSONIsAParseError() async throws {
        let stream = CapturedStream()
        let server = MCPServer(context: try ToolContext.throwaway(), stream: stream.stream)
        await server.handle(Array(#"{"jsonrpc":"2.0","method":"#.utf8))
        let frames = stream.frames()
        #expect(frames.count == 1)
        #expect(frames[0]["error"]?["code"] == .integer(JSONRPC.ErrorCode.parseError.rawValue))
    }

    // MARK: - Framing

    /// Frames split on newlines, tolerate CRLF, and survive a chunk boundary mid-frame.
    @Test func theFrameReaderHandlesSplitsAndCRLF() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let write = descriptors[1]
        let read = descriptors[0]

        let payload = #"{"a":1}"# + "\r\n" + #"{"b":2}"# + "\n\n" + #"{"c":3}"#
        _ = Array(payload.utf8).withUnsafeBufferPointer { Darwin.write(write, $0.baseAddress, $0.count) }
        close(write)

        let reader = FrameReader(descriptor: read)
        var buffer: [UInt8] = []
        var frames: [String] = []
        while let frame = try reader.nextFrame(buffer: &buffer) {
            frames.append(String(decoding: frame, as: UTF8.self))
        }
        close(read)
        #expect(frames == [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#])
    }

    // MARK: - Handshake

    /// `initialize` echoes a version we support and advertises tools.
    @Test func initializeEchoesTheClientsVersion() async throws {
        let stream = CapturedStream()
        let server = MCPServer(context: try ToolContext.throwaway(), stream: stream.stream)
        await server.handle(Array(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#.utf8
        ))
        let result = try #require(stream.frames().first?["result"])
        #expect(result["protocolVersion"] == .string("2024-11-05"))
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["serverInfo"]?["name"] == .string("opensheets"))
        #expect(result["instructions"]?.stringValue?.contains("describe") == true)
    }

    /// An unknown version falls back to ours rather than echoing something we cannot speak.
    @Test func anUnknownVersionFallsBack() async throws {
        let stream = CapturedStream()
        let server = MCPServer(context: try ToolContext.throwaway(), stream: stream.stream)
        await server.handle(Array(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#.utf8
        ))
        #expect(stream.frames().first?["result"]?["protocolVersion"] == .string(MCPServer.preferredProtocolVersion))
    }

    /// A notification gets nothing back.
    @Test func notificationsAreNotAnswered() async throws {
        let stream = CapturedStream()
        let server = MCPServer(context: try ToolContext.throwaway(), stream: stream.stream)
        await server.handle(Array(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        #expect(stream.frames().isEmpty)
    }

    /// An unknown method is a JSON-RPC error with the right code.
    @Test func unknownMethodsAreMethodNotFound() async throws {
        let stream = CapturedStream()
        let server = MCPServer(context: try ToolContext.throwaway(), stream: stream.stream)
        await server.handle(Array(#"{"jsonrpc":"2.0","id":7,"method":"sheets/dance"}"#.utf8))
        let frame = try #require(stream.frames().first)
        #expect(frame["id"] == .integer(7))
        #expect(frame["error"]?["code"] == .integer(JSONRPC.ErrorCode.methodNotFound.rawValue))
    }

    /// An unknown *tool* is a protocol error; a tool that *refuses* is a result.
    ///
    /// The distinction matters to an agent: one means "you called something that does not
    /// exist", the other means "the thing you asked for cannot be done, here is why", and only
    /// the second is worth reading.
    @Test @MainActor func toolFailuresAreResultsNotProtocolErrors() async throws {
        let harness = try Harness.make("protocol-errors")
        let stream = CapturedStream()
        let server = MCPServer(context: harness.context, stream: stream.stream)

        await server.handle(Array(
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope","arguments":{}}}"#.utf8
        ))
        #expect(stream.frames().first?["error"]?["code"] == .integer(JSONRPC.ErrorCode.methodNotFound.rawValue))

        stream.reset()
        let refused = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .integer(2),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string("describe"),
                "arguments": .object(["path": .string("/etc/passwd.csv")]),
            ]),
        ])
        await server.handle(Array(refused.rendered.utf8))
        let frame = try #require(stream.frames().first)
        #expect(frame["error"] == nil, "a refusal is a result, not an error")
        #expect(frame["result"]?["isError"] == .bool(true))
        let text = try #require(frame["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text.contains("grant."))
    }

    /// `tools/list` returns every tool with a schema an MCP client can validate against.
    @Test func everyToolListsAValidSchema() throws {
        let listing = ToolRegistry.standard.listing
        let tools = try #require(listing["tools"]?.arrayValue)
        #expect(tools.count == ToolRegistry.standard.tools.count)
        #expect(tools.count >= 20)

        for tool in tools {
            let name = try #require(tool["name"]?.stringValue)
            #expect(!name.isEmpty)
            #expect(tool["description"]?.stringValue?.isEmpty == false, "\(name) has no description")
            let schema = try #require(tool["inputSchema"], "\(name) has no inputSchema")
            #expect(schema["type"] == .string("object"))
            let properties = try #require(schema["properties"]?.objectValue, "\(name) has no properties")
            #expect(properties["path"] != nil, "\(name) does not take a path")
            #expect(properties["preview"] != nil, "\(name) has no preview flag")
            #expect(schema["additionalProperties"] == .bool(false))
            for required in schema["required"]?.arrayValue ?? [] {
                let key = try #require(required.stringValue)
                #expect(properties[key] != nil, "\(name) requires `\(key)` but does not declare it")
            }
            #expect(tool["annotations"]?["readOnlyHint"] != nil)
        }
    }

    /// Tool names are the snake_case an MCP client expects, and unique.
    @Test func toolNamesAreWellFormedAndUnique() {
        let names = ToolRegistry.standard.names
        #expect(Set(names).count == names.count)
        for name in names {
            #expect(name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" }, "\(name) is not snake_case")
        }
    }

    /// An argument the schema does not declare is rejected rather than ignored.
    ///
    /// `additionalProperties: false` is advisory; a client is free to send anything. A typo'd
    /// argument that is silently dropped produces a call that succeeds and does the wrong thing.
    @Test @MainActor func undeclaredArgumentsAreRejected() async throws {
        let harness = try Harness.make("unknown-arg")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let output = await harness.call("describe", ["path": .string(path), "sheetname": .string("Budget")])
        #expect(output.isError)
        #expect(output.text.contains("sheetname"))
        #expect(output.text.contains("tool.invalidArguments"))
    }

    // MARK: - Stdout purity

    /// **Nothing but JSON-RPC reaches the protocol stream, while every tool runs.**
    ///
    /// Two halves, and both are needed. The first is that the server's own frames are all
    /// valid JSON-RPC — that is a property of the code. The second is that *nothing else in the
    /// process* can reach fd 1, which is a property of ``ProtocolStream/claimStdout()``
    /// redirecting it: a `print` inside a tool, in a dependency, or in a stray debug line lands
    /// on stderr instead. A grep for `print` would only ever prove the first.
    @Test @MainActor func nothingButJSONRPCReachesTheStream() async throws {
        let harness = try Harness.make("stdout-purity")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let stream = CapturedStream()
        let server = MCPServer(context: harness.context, stream: stream.stream)

        await server.handle(Array(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8))
        await server.handle(Array(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        await server.handle(Array(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))

        var identifier = 2
        for tool in ToolRegistry.standard.tools {
            identifier += 1
            let arguments = GrantEscapeTests.arguments(for: tool.schema, path: path)
            let payload = JSONValue.object([
                "jsonrpc": .string("2.0"),
                "id": .integer(identifier),
                "method": .string("tools/call"),
                "params": .object([
                    "name": .string(tool.schema.name),
                    "arguments": .object(arguments.merging(["preview": .bool(true)]) { _, new in new }),
                ]),
            ])
            await server.handle(Array(payload.rendered.utf8))
        }

        let raw = stream.text()
        #expect(!raw.isEmpty)
        var seen = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
            seen += 1
            let frame = try JSONValue.parse(String(line))
            #expect(frame["jsonrpc"] == .string("2.0"), "a frame without the envelope: \(line.prefix(80))")
            #expect(frame["id"] != nil)
            #expect(frame["result"] != nil || frame["error"] != nil)
        }
        // initialize + tools/list + one per tool. The notification is answered by nothing.
        #expect(seen == 2 + ToolRegistry.standard.tools.count)
    }

    /// After `claimStdout()`, a `print` lands on stderr and the protocol stream stays clean.
    ///
    /// Real file descriptors, because this is a `dup2` and there is nothing to test if it is
    /// mocked. The test dups the originals back afterwards so it cannot leave the process's
    /// output pointing at a closed pipe.
    @Test func claimingStdoutRedirectsEveryOtherWriter() throws {
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        defer {
            dup2(savedOut, STDOUT_FILENO)
            dup2(savedErr, STDERR_FILENO)
            close(savedOut)
            close(savedErr)
        }

        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        #expect(pipe(&outPipe) == 0)
        #expect(pipe(&errPipe) == 0)
        dup2(outPipe[1], STDOUT_FILENO)
        dup2(errPipe[1], STDERR_FILENO)
        close(outPipe[1])
        close(errPipe[1])

        let stream = ProtocolStream.claimStdout()
        print("a stray print that would corrupt the stream")
        FileHandle.standardOutput.write(Data("and a direct write to standard output\n".utf8))
        fflush(Darwin.stdout)
        stream.send(.object(["jsonrpc": .string("2.0"), "id": .integer(1)]))

        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)

        let protocolText = ProtocolTests.drain(outPipe[0])
        let stderrText = ProtocolTests.drain(errPipe[0])

        #expect(protocolText == #"{"id":1,"jsonrpc":"2.0"}"# + "\n",
                "something other than a frame reached the protocol stream: \(protocolText)")
        #expect(stderrText.contains("a stray print"))
        #expect(stderrText.contains("direct write to standard output"))
    }

    private static func drain(_ descriptor: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { pointer -> Int in
            guard let base = pointer.baseAddress else { return 0 }
            // Non-blocking, because the write end is closed and there may be nothing there.
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            let read = Darwin.read(descriptor, base, pointer.count)
            return read > 0 ? read : 0
        }
        close(descriptor)
        return String(decoding: buffer[0 ..< count], as: UTF8.self)
    }
}

// MARK: - Helpers

/// A ``ProtocolStream`` over a pipe, so a test can read exactly what went on the wire.
final class CapturedStream: @unchecked Sendable {
    let stream: ProtocolStream
    private let readEnd: Int32
    private let writeEnd: Int32
    private var consumed = ""

    init() {
        var descriptors: [Int32] = [0, 0]
        _ = pipe(&descriptors)
        readEnd = descriptors[0]
        writeEnd = descriptors[1]
        _ = fcntl(readEnd, F_SETFL, O_NONBLOCK)
        stream = ProtocolStream(descriptor: writeEnd)
    }

    deinit {
        close(readEnd)
        close(writeEnd)
    }

    /// Everything written so far.
    func text() -> String {
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return 0 }
                let read = Darwin.read(readEnd, base, pointer.count)
                return read > 0 ? read : 0
            }
            guard count > 0 else { break }
            consumed += String(decoding: buffer[0 ..< count], as: UTF8.self)
        }
        return consumed
    }

    /// The frames, parsed.
    func frames() -> [JSONValue] {
        text()
            .split(separator: "\n")
            .compactMap { try? JSONValue.parse(String($0)) }
    }

    func reset() {
        _ = text()
        consumed = ""
    }
}

extension ToolContext {
    /// A context over a store with no grants, for the protocol tests that never touch a file.
    static func throwaway() throws -> ToolContext {
        let scratch = Scratch("protocol")
        let support = scratch.directory("support")
        let store = try SheetStore(
            mode: .mcpServer, configuration: SheetStore.Configuration(applicationSupport: support)
        )
        // The scratch directory is kept alive by the closure the handshake holds; without this
        // the temporary directory would be removed while the store still points into it.
        let handshake = AppHandshake(applicationSupport: support, now: { _ = scratch; return Date() })
        return ToolContext(broker: DocumentBroker(store: store), handshake: handshake)
    }
}
