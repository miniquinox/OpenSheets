import Foundation
@testable import SheetMCP
import SheetModel
import SheetStore
import Testing

/// `serve --read-only`: a server that cannot change a workbook, and cannot be asked to.
///
/// # What this suite is defending
///
/// A read-only share link is a promise made to whoever the owner hands it to, and the promise is
/// kept in exactly one place: the registry the subprocess is built with. There is no mode flag
/// consulted at call time, no allow-list checked per request, and deliberately so — a check that
/// exists in two places is a check that can be present in one of them.
///
/// So the assertions here are about the *set*, not about behaviour at the call site. The filter is
/// on each schema's own `isReadOnly` annotation rather than on a list of names, which means the
/// interesting failure is not "someone changed the filter" but "someone added a tool and
/// annotated it wrong". Both directions are asserted below, because a filter that is correct in
/// one direction can be empty in the other.
@Suite struct ReadOnlyServeTests {
    // MARK: - The set

    /// Nothing in the read-only registry can change anything.
    ///
    /// The direction that matters for the promise: whatever is served, every one of them reads.
    @Test func everyToolServedReadOnlyIsAnnotatedReadOnly() {
        let offenders = ToolRegistry.readOnly.tools
            .filter { !$0.schema.isReadOnly }
            .map(\.schema.name)
        #expect(
            offenders.isEmpty,
            "\(offenders.joined(separator: ", ")) are served to a read-only client but are not read-only"
        )
    }

    /// Nothing that reads was left out.
    ///
    /// The other direction, and the one that keeps the filter honest rather than merely safe: an
    /// empty registry would pass the test above and serve nobody. Stated as set equality against
    /// `standard` so that adding a read-only tool needs no edit here — and so that *excluding* one
    /// by hand would fail.
    @Test func theReadOnlyRegistryIsExactlyTheReadOnlyHalfOfStandard() {
        let expected = ToolRegistry.standard.tools.filter(\.schema.isReadOnly).map(\.schema.name)
        #expect(ToolRegistry.readOnly.names == expected)
        #expect(!expected.isEmpty, "a read-only server that serves nothing is not a read-only server")
        // Order is the listing order an agent meets the tools in, not an accident of filtering.
        #expect(ToolRegistry.readOnly.names == ToolRegistry.standard.names.filter(expected.contains))
    }

    /// The tools a reader actually needs are there.
    ///
    /// Canaries, not a second copy of the list: these four are what "read this spreadsheet for me"
    /// bottoms out in, and a filter that dropped any of them would still pass the set assertions
    /// above while making the feature useless.
    @Test func theReadingToolsSurvive() {
        let names = Set(ToolRegistry.readOnly.names)
        for tool in ["list_workspace", "list_files", "describe", "read_range", "find"] {
            #expect(names.contains(tool), "a read-only server cannot \(tool)")
        }
    }

    /// The tools that write are gone.
    ///
    /// `delete_*` is matched by prefix rather than named one at a time so that a deleting tool
    /// added later is covered by this test on the day it lands, without anybody remembering to
    /// come back here.
    @Test func theWritingToolsAreAbsent() {
        let names = Set(ToolRegistry.readOnly.names)
        for tool in ["write_range", "set_format", "recalc", "sort", "restore", "add_sheet"] {
            #expect(!names.contains(tool), "\(tool) is served to a read-only client")
        }
        let deleters = names.filter { $0.hasPrefix("delete_") }
        #expect(deleters.isEmpty, "\(deleters.joined(separator: ", ")) is served to a read-only client")
        #expect(ToolRegistry.readOnly.names.count < ToolRegistry.standard.names.count)
    }

    /// `filter` and `snapshot` are excluded, and that is the annotation being right rather than
    /// the filter being wrong.
    ///
    /// Both read like reading tools and neither is: `filter` takes `action: "delete"`, `snapshot`
    /// writes a restore point. Pinned as a test because the temptation, the first time somebody
    /// notices a read-only link cannot run `filter`, will be to special-case them into the
    /// registry — and that would put a name-based exception back into a filter whose whole value
    /// is that it has none. The fix, if one is wanted, is to split the tool.
    @Test func toolsThatOnlyLookLikeReadersAreExcluded() {
        let names = Set(ToolRegistry.readOnly.names)
        #expect(!names.contains("filter"))
        #expect(!names.contains("snapshot"))
        #expect(Set(ToolRegistry.standard.names).contains("filter"))
    }

    // MARK: - Over the wire

    /// One `tools/call` frame, sent to both registries so the only difference is the registry.
    ///
    /// The path is inside no granted folder, on purpose: this frame is never meant to edit a file.
    /// On the standard registry it reaches `write_range` and is refused by the grant check, which
    /// is precisely the outcome that distinguishes "the tool is here and said no" from "there is
    /// no such tool".
    ///
    /// Concatenated rather than written out whole: a frame is one line by definition, and one line
    /// of this JSON is wider than the file is allowed to be.
    private static let writeCall = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":"#
        + #"{"name":"write_range","arguments":"#
        + #"{"path":"/nowhere/x.xlsx","range":"A1","values":[["hello"]]}}}"#

    /// A read-only server does not advertise a tool it will not run.
    ///
    /// Driven through `handle` rather than through the process, the `ProtocolTests` way: this is a
    /// claim about the frame that goes back to the client, and the transport has nothing to do
    /// with it.
    @Test func toolsListOverTheWireHoldsNoWritingTool() async throws {
        let stream = CapturedStream()
        let server = MCPServer(
            registry: .readOnly, context: try ToolContext.throwaway(), stream: stream.stream
        )
        await server.handle(Array(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))

        let listed = try #require(stream.frames().first?["result"]?["tools"]?.arrayValue)
        let names = listed.compactMap { $0["name"]?.stringValue }
        #expect(names == ToolRegistry.readOnly.names)
        #expect(!names.contains("write_range"))
        // Every advertised tool says `readOnlyHint: true` to the client, so a client that reasons
        // about the annotation reaches the same answer the registry did.
        for tool in listed {
            #expect(tool["annotations"]?["readOnlyHint"] == .bool(true))
        }
    }

    /// Calling a write tool on a read-only server is `methodNotFound`, not a refusal.
    ///
    /// The distinction is the point. A refusal is a fact about this request that an agent may
    /// reasonably retry, rephrase, or argue with; `methodNotFound` is a fact about the server,
    /// and the client's own tool-use machinery handles it without ever putting the question to
    /// the model. The tool does not exist here, and the error says exactly that.
    @Test func callingAWriteToolOnAReadOnlyServerIsMethodNotFound() async throws {
        let stream = CapturedStream()
        let server = MCPServer(
            registry: .readOnly, context: try ToolContext.throwaway(), stream: stream.stream
        )
        await server.handle(Array(Self.writeCall.utf8))

        let frame = try #require(stream.frames().first)
        #expect(frame["id"] == .integer(7))
        #expect(frame["error"]?["code"] == .integer(JSONRPC.ErrorCode.methodNotFound.rawValue))
        // And nothing came back that a client would read as a successful edit.
        #expect(frame["result"] == nil)
    }

    /// The same call on the standard registry is not `methodNotFound`.
    ///
    /// Without this, the test above would pass just as well against a server that had lost
    /// `write_range` for some entirely different reason.
    @Test func theSameCallOnTheStandardRegistryReachesTheTool() async throws {
        let stream = CapturedStream()
        let server = MCPServer(
            registry: .standard, context: try ToolContext.throwaway(), stream: stream.stream
        )
        await server.handle(Array(Self.writeCall.utf8))

        let frame = try #require(stream.frames().first)
        // It fails — the context has no grants — but as a tool result the agent can read, which
        // is a different thing from the method not being there.
        #expect(frame["error"] == nil)
        #expect(frame["result"]?["isError"] == .bool(true))
    }

    // MARK: - The flag

    /// `serve --read-only` selects the read-only registry.
    ///
    /// Asked of the parser rather than of the server, because `serve` claims file descriptor 1 and
    /// then blocks on stdin until the client hangs up: running it in a test would hang the suite
    /// and take the protocol stream with it. `Options.serveRegistry` is the same expression the
    /// dispatcher evaluates, so this is the real path and not a restatement of it.
    @Test func theReadOnlyFlagSelectsTheReadOnlyRegistry() throws {
        let console = CapturedConsole()
        let parsed = try #require(OpenSheetsCLI.parse(["serve", "--read-only"], console: console.writer))
        #expect(parsed.positional == ["serve"])
        #expect(parsed.options.readOnly)
        #expect(parsed.options.serveRegistry.names == ToolRegistry.readOnly.names)
    }

    /// Plain `serve` is unchanged: the whole surface, exactly as before this flag existed.
    @Test func serveWithoutTheFlagServesEverything() throws {
        let console = CapturedConsole()
        let parsed = try #require(OpenSheetsCLI.parse(["serve"], console: console.writer))
        #expect(!parsed.options.readOnly)
        #expect(parsed.options.serveRegistry.names == ToolRegistry.standard.names)
        #expect(console.all.isEmpty)
    }

    /// An unknown flag after `serve` is a usage error, exit 2.
    ///
    /// Safe to run for real: the command line is rejected before `serve` is reached, so nothing
    /// claims stdout and nothing blocks.
    @Test func anUnknownServeFlagExitsTwo() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(arguments: ["serve", "--write-only"], console: console.writer)
        #expect(code == ExitCode.usage)
        #expect(console.text.contains("unknown option --write-only"))
    }

    /// So is an unknown flag alongside a good one — the good flag does not excuse the bad.
    @Test func aGoodServeFlagDoesNotExcuseABadOne() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(
            arguments: ["serve", "--read-only", "--wat"], console: console.writer
        )
        #expect(code == ExitCode.usage)
        #expect(console.text.contains("unknown option --wat"))
    }

    /// A stray word after `serve` is a usage error too, rather than an argument silently ignored.
    ///
    /// `opensheets-mcp` passes its arguments through, so a typo reaches `serve` intact. Ignoring it
    /// would start a full-surface server that the operator believes is something else — and they
    /// would not find out, because `serve` prints nothing and blocks.
    @Test func aStrayWordAfterServeExitsTwo() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(arguments: ["serve", "readonly"], console: console.writer)
        #expect(code == ExitCode.usage)
        #expect(console.text.contains("did not understand readonly"))
    }

    /// The flag is documented where a person would look for it.
    @Test func theFlagIsInTheHelp() async {
        let console = CapturedConsole()
        #expect(await OpenSheetsCLI.run(arguments: ["help"], console: console.writer) == ExitCode.success)
        #expect(console.text.contains("--read-only"))
        #expect(console.text.contains("serve [--read-only]"))
    }
}
