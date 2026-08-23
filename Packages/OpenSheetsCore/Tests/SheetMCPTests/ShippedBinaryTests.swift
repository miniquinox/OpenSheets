import Foundation
@testable import SheetMCP
import SheetModel
import SheetStore
import Testing

/// **The `opensheets-mcp` binary, spawned as a subprocess and driven over stdio.**
///
/// # Why this exists on top of everything else
///
/// Every other suite runs the server's *code*. This one runs the **executable that ships**, in
/// its own process, over a real pipe, speaking real JSON-RPC. That is the only way to observe
/// three things that are properties of the binary rather than of the code:
///
/// - `main.swift` actually reaches `OpenSheetsCLI.run(["serve"])` and the process stays up;
/// - the `dup2` in ``ProtocolStream/claimStdout()`` happens early enough that nothing during
///   start-up has already written to descriptor 1;
/// - **the grant boundary holds in the shipped artefact**, which is the acceptance criterion
///   this suite exists for and the one where a difference between "the code" and "the binary"
///   would be a P0.
///
/// The subprocess gets its own `HOME`, so it reads a store this test built rather than the
/// user's. That is Foundation's own resolution of the application-support directory, not a
/// switch in our code: there is deliberately no argument or environment variable that relocates
/// the grant database, because that would be a way to hand the server a grant it was not given.
///
/// If the binary has not been built, the suite says so and skips rather than passing quietly.
@Suite struct ShippedBinaryTests {
    /// Anchors ``binaryURL`` to *this* bundle.
    ///
    /// `Bundle.main` under `swift test` is the `xctest` host in the toolchain, not the test
    /// bundle, so it points nowhere near the build products. `Bundle(for:)` on a class defined
    /// here resolves to `…/debug/OpenSheetsCorePackageTests.xctest`, whose parent is the
    /// products directory the executables were written to.
    private final class BundleAnchor: NSObject {}

    /// Where `swift build` put the executable, or `nil`.
    static var binaryURL: URL? {
        var roots = [Bundle(for: BundleAnchor.self).bundleURL, Bundle.main.bundleURL]
        roots.append(contentsOf: Bundle.allBundles.map(\.bundleURL))
        for root in roots {
            var directory = root
            for _ in 0 ..< 4 {
                let candidate = directory.appendingPathComponent("opensheets-mcp")
                if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
                    return candidate
                }
                directory = directory.deletingLastPathComponent()
            }
        }
        return nil
    }

    /// The subprocess's environment, with its home relocated.
    ///
    /// **`CFFIXED_USER_HOME`, not just `HOME`.** Foundation resolves
    /// `.applicationSupportDirectory` through `NSHomeDirectory()`, which on macOS reads the
    /// password database and ignores `HOME` — set only `HOME` and the subprocess reads the
    /// developer's real grant store, which is both wrong and dangerous for a test that plants
    /// grants. `CFFIXED_USER_HOME` is CoreFoundation's own override and moves everything
    /// together: the store, the snapshots, and the `~` the deny-list expands, so a case about
    /// `~/.ssh` is a case about *this* home.
    ///
    /// It is a Foundation variable rather than a switch in our code, and it cannot mint a
    /// grant — anyone able to plant a grant database somewhere already has the filesystem
    /// access a grant would give them.
    static func environment(home: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = home.path(percentEncoded: false)
        environment["HOME"] = path
        environment["CFFIXED_USER_HOME"] = path
        environment["OPENSHEETS_MCP_LOG"] = "0"
        return environment
    }

    /// One conversation with the subprocess.
    private struct Session {
        var frames: [JSONValue]
        var stderrText: String
        var exitCode: Int32

        func result(id: Int) -> JSONValue? {
            frames.first { $0["id"] == .integer(id) }
        }

        func toolText(id: Int) -> String? {
            result(id: id)?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        }

        func isToolError(id: Int) -> Bool {
            result(id: id)?["result"]?["isError"] == .bool(true)
                || result(id: id)?["error"] != nil
        }
    }

    /// Spawns the binary, writes `requests`, closes stdin, and collects what came back.
    private func converse(
        _ requests: [JSONValue],
        home: URL,
        binary: URL
    ) throws -> Session {
        let process = Process()
        process.executableURL = binary
        process.environment = ShippedBinaryTests.environment(home: home)

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()

        let payload = requests.map(\.rendered).joined(separator: "\n") + "\n"
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()

        let outData = output.fileHandleForReading.readDataToEndOfFile()
        let errData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: outData, as: UTF8.self)
        var frames: [JSONValue] = []
        for line in text.split(separator: "\n") where !line.isEmpty {
            // A line that does not parse is exactly the corruption this whole design exists to
            // prevent, so it fails loudly rather than being filtered out.
            frames.append(try JSONValue.parse(String(line)))
        }
        return Session(
            frames: frames,
            stderrText: String(decoding: errData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// A `HOME` with an OpenSheets store in it, granting `<home>/workspace`.
    @MainActor
    private func stagedHome(_ name: String) throws -> (scratch: Scratch, home: URL, workspace: URL) {
        let scratch = Scratch(name)
        let home = scratch.directory("home")
        let workspace = scratch.directory("home/workspace")
        let support = home
            .appendingPathComponent("Library/Application Support/OpenSheets")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let app = try SheetStore(
            mode: .app, configuration: SheetStore.Configuration(applicationSupport: support)
        )
        try app.grantWorkspace(UserGrantAuthorization(userSelectedDirectory: workspace))
        return (scratch, home, workspace)
    }

    private func request(_ id: Int, _ method: String, _ params: JSONValue = .object([:])) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": .integer(id),
            "method": .string(method),
            "params": params,
        ])
    }

    private func toolCall(_ id: Int, _ name: String, _ arguments: [String: JSONValue]) -> JSONValue {
        request(id, "tools/call", .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ]))
    }

    // MARK: - The handshake, end to end

    /// The binary starts, completes the MCP handshake, lists its tools, and exits at EOF.
    @Test @MainActor func theBinarySpeaksMCP() async throws {
        guard let binary = ShippedBinaryTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = try stagedHome("binary-handshake")
        let session = try converse([
            request(1, "initialize", .object(["protocolVersion": .string("2025-06-18")])),
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]),
            request(2, "tools/list"),
            request(3, "ping"),
        ], home: staged.home, binary: binary)

        #expect(session.exitCode == 0, "the server exited \(session.exitCode): \(session.stderrText)")
        #expect(session.frames.count == 3, "one response per request, and none for the notification")

        let initialize = try #require(session.result(id: 1)?["result"])
        #expect(initialize["protocolVersion"] == .string("2025-06-18"))
        #expect(initialize["serverInfo"]?["name"] == .string("opensheets"))
        #expect(initialize["capabilities"]?["tools"] != nil)

        let tools = try #require(session.result(id: 2)?["result"]?["tools"]?.arrayValue)
        #expect(tools.count == ToolRegistry.standard.tools.count)
        #expect(tools.contains { $0["name"] == .string("describe") })
    }

    /// Every frame the binary emits is well-formed JSON-RPC, while every tool is exercised.
    ///
    /// This is the stdout-purity acceptance criterion, observed on the real descriptor of the
    /// real process. `converse` throws on any line that does not parse, so a stray `print`
    /// anywhere in the binary fails this test rather than producing a mysterious client error.
    @Test @MainActor func theBinaryEmitsNothingButJSONRPC() async throws {
        guard let binary = ShippedBinaryTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = try stagedHome("binary-purity")
        let path = staged.workspace.appendingPathComponent("budget.xlsx").path(percentEncoded: false)
        let harness = try Harness.make("binary-purity-fixture")
        try Data(contentsOf: URL(fileURLWithPath: try harness.install(try Fixtures.budget(), as: "b.xlsx")))
            .write(to: URL(fileURLWithPath: path))

        var requests: [JSONValue] = [request(1, "initialize")]
        var identifier = 1
        for tool in ToolRegistry.standard.tools {
            identifier += 1
            var arguments = GrantEscapeTests.arguments(for: tool.schema, path: path)
            arguments["preview"] = .bool(true)
            requests.append(toolCall(identifier, tool.schema.name, arguments))
        }
        let session = try converse(requests, home: staged.home, binary: binary)

        #expect(session.frames.count == requests.count)
        for frame in session.frames {
            #expect(frame["jsonrpc"] == .string("2.0"))
            #expect(frame["result"] != nil || frame["error"] != nil)
        }
        // The file is still what it was: every call was a preview.
        #expect(FileManager.default.fileExists(atPath: path))
    }

    // MARK: - The boundary, in the shipped artefact

    /// **P0: the escape suite, run against the binary.**
    ///
    /// The same shapes as ``GrantEscapeTests``, re-expressed against the subprocess's own
    /// `HOME` — the deny-list expands `~` per user, so a case about `~/.ssh` has to be a case
    /// about *this* home to be testing anything. A positive case runs alongside them, so a
    /// binary that denied everything could not pass.
    @Test @MainActor func theBinaryDeniesEveryEscape() async throws {
        guard let binary = ShippedBinaryTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = try stagedHome("binary-escape")
        let home = staged.home.path(percentEncoded: false)
        let workspace = staged.workspace.path(percentEncoded: false)

        let outside = staged.scratch.directory("home/private")
        let secret = outside.appendingPathComponent("secrets.xlsx")
        try Data("secret".utf8).write(to: secret)
        staged.scratch.directory("home/workspace-old")
        try FileManager.default.createDirectory(
            at: staged.home.appendingPathComponent(".ssh"), withIntermediateDirectories: true
        )
        try Data("PRIVATE KEY".utf8).write(
            to: staged.home.appendingPathComponent(".ssh/id_rsa.csv")
        )
        try FileManager.default.createSymbolicLink(
            at: staged.workspace.appendingPathComponent("escape"), withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: staged.workspace.appendingPathComponent("up"),
            withDestinationURL: staged.home
        )

        // The file that *should* be readable, so the suite cannot pass vacuously.
        let harness = try Harness.make("binary-escape-fixture")
        let allowed = staged.workspace.appendingPathComponent("budget.xlsx").path(percentEncoded: false)
        try Data(contentsOf: URL(fileURLWithPath: try harness.install(try Fixtures.budget(), as: "b.xlsx")))
            .write(to: URL(fileURLWithPath: allowed))

        let escapes: [(name: String, path: String)] = [
            ("plain ..", "\(workspace)/../private/secrets.xlsx"),
            ("doubled ..", "\(workspace)/a/../../private/secrets.xlsx"),
            ("many ..", "\(workspace)/../../../../../../etc/hosts.csv"),
            (".. mixed with .", "\(workspace)/./../private/./secrets.xlsx"),
            ("// separators", "\(workspace)//..//private//secrets.xlsx"),
            ("symlinked directory out", "\(workspace)/escape/secrets.xlsx"),
            ("symlink then ..", "\(workspace)/escape/../private/secrets.xlsx"),
            ("symlink to the home directory", "\(workspace)/up/private/secrets.xlsx"),
            ("prefix neighbour", "\(home)/workspace-old/x.xlsx"),
            ("workspace path with a suffix", "\(workspace)x/inner.xlsx"),
            ("the home directory itself", "\(home)/anything.xlsx"),
            ("~/.ssh", "\(home)/.ssh/id_rsa.csv"),
            ("tilde-expanded ~/.ssh", "~/.ssh/id_rsa.csv"),
            ("~/.claude.json", "\(home)/.claude.json"),
            ("*.pem inside the workspace", "\(workspace)/server.pem"),
            (".env inside the workspace", "\(workspace)/.env"),
            ("percent-encoded traversal", "\(workspace)/%2e%2e/private/secrets.xlsx"),
            ("file URL with traversal", "file://\(workspace)/../private/secrets.xlsx"),
            ("/etc/hosts", "/etc/hosts.csv"),
            ("root", "/x.xlsx"),
            ("relative from the cwd", "../../../etc/hosts.csv"),
        ]

        var requests: [JSONValue] = [request(1, "initialize")]
        var identifier = 1
        var expectations: [Int: String] = [:]
        for tool in ["describe", "read_range", "find", "write_range", "delete_rows", "restore", "snapshot"] {
            guard let schema = ToolRegistry.standard.definition(named: tool)?.schema else { continue }
            for testCase in escapes {
                identifier += 1
                expectations[identifier] = "\(tool) ← \(testCase.name)"
                requests.append(toolCall(
                    identifier, tool, GrantEscapeTests.arguments(for: schema, path: testCase.path)
                ))
            }
        }
        let allowedIdentifier = identifier + 1
        requests.append(toolCall(allowedIdentifier, "describe", ["path": .string(allowed)]))

        let session = try converse(requests, home: staged.home, binary: binary)
        #expect(session.exitCode == 0, "\(session.stderrText)")

        var leaks: [String] = []
        for (identifier, label) in expectations.sorted(by: { $0.key < $1.key }) {
            guard session.isToolError(id: identifier) else {
                leaks.append("\(label) SUCCEEDED")
                continue
            }
            let text = session.toolText(id: identifier) ?? ""
            let refused = text.contains("[grant.")
                || text.contains("[core.notImplemented]")
                || text.contains("[workbook.unsupportedFormat]")
            if !refused { leaks.append("\(label) refused for the wrong reason: \(text.prefix(90))") }
        }
        #expect(leaks.isEmpty, "GRANT ESCAPES IN THE SHIPPED BINARY (P0):\n\(leaks.joined(separator: "\n"))")

        // And the allowed path worked, so none of the above passed because everything failed.
        #expect(!session.isToolError(id: allowedIdentifier),
                "\(session.toolText(id: allowedIdentifier) ?? "no answer")")
        #expect(session.toolText(id: allowedIdentifier)?.contains("Budget") == true)
    }

    /// With no grants at all, the binary refuses everything and says where to fix it.
    @Test @MainActor func aBinaryWithNoGrantsRefusesAndExplains() async throws {
        guard let binary = ShippedBinaryTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let scratch = Scratch("binary-no-grants")
        let home = scratch.directory("home")
        let file = scratch.write("a,b\n1,2\n", to: "home/data.csv")

        let session = try converse([
            request(1, "initialize"),
            toolCall(2, "describe", ["path": .string(file.path(percentEncoded: false))]),
        ], home: home, binary: binary)

        #expect(session.isToolError(id: 2))
        let text = try #require(session.toolText(id: 2))
        #expect(text.contains("grant.outsideWorkspace"))
        #expect(text.lowercased().contains("opensheets"))
    }

    /// A real edit, made by the shipped binary, lands in the file.
    @Test @MainActor func theBinaryActuallyEditsAFile() async throws {
        guard let binary = ShippedBinaryTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = try stagedHome("binary-edit")
        let path = staged.workspace.appendingPathComponent("data.csv").path(percentEncoded: false)
        try Data("name,score\nAda,10\nGrace,20\n".utf8).write(to: URL(fileURLWithPath: path))

        let session = try converse([
            request(1, "initialize"),
            toolCall(2, "write_range", [
                "path": .string(path),
                "range": .string("B2"),
                "values": .array([.array([.integer(99)])]),
            ]),
        ], home: staged.home, binary: binary)

        #expect(!session.isToolError(id: 2), "\(session.toolText(id: 2) ?? session.stderrText)")
        let contents = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        #expect(contents.contains("Ada,99"), "\(contents)")

        // And a snapshot was taken first, in the store under the staged home.
        let snapshotRoot = staged.home
            .appendingPathComponent("Library/Application Support/OpenSheets/Snapshots")
        let stored = FileManager.default.enumerator(atPath: snapshotRoot.path(percentEncoded: false))?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".gz") } ?? []
        #expect(!stored.isEmpty, "the write was not snapshotted")
    }

    /// A malformed frame does not take the server down; the next request still works.
    @Test @MainActor func aBadFrameDoesNotKillTheServer() async throws {
        guard let binary = ShippedBinaryTests.binaryURL else {
            Issue.record("opensheets-mcp is not built; run `swift build` before this suite")
            return
        }
        let staged = try stagedHome("binary-recovery")
        let process = Process()
        process.executableURL = binary
        process.environment = ShippedBinaryTests.environment(home: staged.home)
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        let payload = "{not json at all\n"
            + request(1, "initialize").rendered + "\n"
            + "\n"
            + request(2, "tools/list").rendered + "\n"
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let frames = text.split(separator: "\n").compactMap { try? JSONValue.parse(String($0)) }
        #expect(frames.count == 3, "a parse error, then two working responses")
        #expect(frames.first?["error"]?["code"] == .integer(JSONRPC.ErrorCode.parseError.rawValue))
        #expect(frames.last?["result"]?["tools"] != nil, "the server kept working after the bad frame")
    }
}
