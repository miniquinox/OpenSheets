import Foundation
@testable import SheetMCP
import SheetModel
import SheetStore
import Testing

/// **The boundary, tested through the tools rather than through the check.**
///
/// A6 proved ``SheetStore/WorkspaceGrants`` denies forty escapes. That is necessary and not
/// sufficient: what ships is a *server*, and the question this suite answers is whether every
/// route through it reaches that check. A tool that resolved a path itself, or cached a `URL`
/// across calls, or accepted a second path argument nobody thought about, would pass A6's suite
/// and leak here.
///
/// So every case goes in as a JSON tool argument and comes back as a tool result, and the
/// assertion is on the result. **Any escape is a P0 and blocks release.**
@Suite struct GrantEscapeTests {
    /// The layout every escape case is built against: a granted workspace, an ungranted sibling
    /// with a file in it, and a spread of symlinks planted inside the workspace pointing out.
    private struct Layout {
        var harness: Harness
        var workspacePath: String
        var scratchPath: String
        var secretPath: String
        var home: String
    }

    @MainActor
    private func layout() throws -> Layout {
        let harness = try Harness.make("escape")
        let outside = harness.scratch.directory("outside")
        let secret = outside.appendingPathComponent("secrets.xlsx")
        try Data("secret".utf8).write(to: secret)
        harness.scratch.directory("work-secret")
        try Data("payroll".utf8).write(
            to: harness.scratch.url.appendingPathComponent("work-secret/payroll.xlsx")
        )
        harness.scratch.directory("workspace.old")
        harness.scratch.directory("workspace more")

        let manager = FileManager.default
        try manager.createSymbolicLink(
            at: harness.workspace.appendingPathComponent("escape"), withDestinationURL: outside
        )
        try manager.createSymbolicLink(
            at: harness.workspace.appendingPathComponent("escape.xlsx"), withDestinationURL: secret
        )
        try manager.createSymbolicLink(
            at: harness.workspace.appendingPathComponent("home"),
            withDestinationURL: URL(fileURLWithPath: NSHomeDirectory())
        )
        try manager.createSymbolicLink(
            at: harness.workspace.appendingPathComponent("root"), withDestinationURL: URL(fileURLWithPath: "/")
        )
        try manager.createSymbolicLink(
            at: harness.workspace.appendingPathComponent("inward"), withDestinationURL: harness.workspace
        )
        try manager.createSymbolicLink(
            atPath: harness.workspace.appendingPathComponent("relative").path(percentEncoded: false),
            withDestinationPath: "../outside"
        )
        try manager.createSymbolicLink(
            atPath: harness.workspace.appendingPathComponent("loopA").path(percentEncoded: false),
            withDestinationPath: "loopB"
        )
        try manager.createSymbolicLink(
            atPath: harness.workspace.appendingPathComponent("loopB").path(percentEncoded: false),
            withDestinationPath: "loopA"
        )
        // A real, readable workbook inside the workspace, so the positive cases below prove the
        // suite is not passing because everything fails.
        _ = try harness.install(Fixtures.budget(), as: "budget.xlsx")

        return Layout(
            harness: harness,
            workspacePath: harness.workspace.path(percentEncoded: false),
            scratchPath: harness.scratch.url.path(percentEncoded: false),
            secretPath: secret.path(percentEncoded: false),
            home: NSHomeDirectory()
        )
    }

    /// Forty-three paths out of the granted folder, every one of them refused by the tool
    /// surface.
    private func escapeCases(_ layout: Layout) -> [(name: String, path: String)] {
        let workspace = layout.workspacePath
        let scratch = layout.scratchPath
        let home = layout.home
        return [
            // -- traversal ---------------------------------------------------------------
            ("plain ..", "\(workspace)/../outside/secrets.xlsx"),
            ("doubled ..", "\(workspace)/a/../../outside/secrets.xlsx"),
            ("many ..", "\(workspace)/../../../../../../../../etc/hosts.csv"),
            (".. mixed with .", "\(workspace)/./../outside/./secrets.xlsx"),
            ("// separators", "\(workspace)//..//outside//secrets.xlsx"),
            ("/./ noise", "\(scratch)/./outside/./secrets.xlsx"),
            ("the parent itself", "\(scratch)/outside/secrets.xlsx"),
            ("trailing dot-dot file", "\(workspace)/../secrets.xlsx"),

            // -- symlinks ----------------------------------------------------------------
            ("symlinked directory out", "\(workspace)/escape/secrets.xlsx"),
            ("symlinked file out", "\(workspace)/escape.xlsx"),
            ("symlink to home", "\(workspace)/home/Documents/anything.xlsx"),
            ("symlink to root", "\(workspace)/root/etc/hosts.csv"),
            ("symlink then ..", "\(workspace)/escape/../outside/secrets.xlsx"),
            ("inward symlink then ..", "\(workspace)/inward/../outside/secrets.xlsx"),
            ("relative symlink out", "\(workspace)/relative/secrets.xlsx"),
            ("symlink loop", "\(workspace)/loopA/x.xlsx"),

            // -- neighbours that merely share a prefix ------------------------------------
            ("work-secret sibling", "\(scratch)/work-secret/payroll.xlsx"),
            ("workspace.old sibling", "\(scratch)/workspace.old/x.xlsx"),
            ("workspace more sibling", "\(scratch)/workspace more/x.xlsx"),
            ("workspace path with a suffix", "\(workspace)x/inner.xlsx"),
            ("support directory, which we own but never granted", "\(scratch)/support/x.xlsx"),

            // -- deny-list, which overrides any grant -------------------------------------
            ("~/.ssh", "\(home)/.ssh/id_rsa.csv"),
            ("~/.aws", "\(home)/.aws/credentials.csv"),
            ("~/.config/gh", "\(home)/.config/gh/hosts.csv"),
            ("~/Library/Keychains", "\(home)/Library/Keychains/login.keychain-db"),
            ("~/.claude.json", "\(home)/.claude.json"),
            ("tilde-expanded .ssh", "~/.ssh/known_hosts.csv"),
            ("uppercase .SSH", "\(home)/.SSH/id_rsa.csv"),
            ("*.pem inside the workspace", "\(workspace)/server.pem"),
            ("*.key inside the workspace", "\(workspace)/private.key"),
            (".env inside the workspace", "\(workspace)/.env"),
            (".env.local inside the workspace", "\(workspace)/.env.local"),
            ("uppercase .PEM inside the workspace", "\(workspace)/CERT.PEM"),
            ("~/.gnupg", "\(home)/.gnupg/secring.csv"),
            ("~/.netrc", "\(home)/.netrc"),

            // -- encodings and spellings ---------------------------------------------------
            ("percent-encoded traversal", "\(workspace)/%2e%2e/outside/secrets.xlsx"),
            ("file URL with traversal", "file://\(workspace)/../outside/secrets.xlsx"),
            ("file URL outright", "file://\(scratch)/outside/secrets.xlsx"),
            ("separator noise around ..", "\(workspace)/../outside//./secrets.xlsx"),

            // -- unrelated absolute paths ---------------------------------------------------
            ("/etc/hosts", "/etc/hosts.csv"),
            ("home directory itself", "\(home)/anything.xlsx"),
            ("root", "/x.xlsx"),
            ("relative path from the process's cwd", "../../../etc/hosts.csv"),
        ]
    }

    /// **P0.** Every escape, through every tool that takes a path.
    ///
    /// Not one tool: *all* of them. The check lives in ``DocumentBroker/resolve(_:)`` and every
    /// tool is supposed to go through it, and the only way to know that a tool added later did
    /// is to run the suite against the registry rather than against a list somebody maintains.
    @Test @MainActor func noToolLetsAPathOutOfTheWorkspace() async throws {
        let layout = try layout()
        let cases = escapeCases(layout)
        #expect(cases.count >= 25, "the escape suite must carry at least 25 cases, it has \(cases.count)")

        var escapes: [String] = []
        for tool in ToolRegistry.standard.tools {
            for testCase in cases {
                let output = await layout.harness.call(
                    tool.schema.name, GrantEscapeTests.arguments(for: tool.schema, path: testCase.path)
                )
                guard output.isError else {
                    escapes.append("\(tool.schema.name) ← \(testCase.name): \(testCase.path)")
                    continue
                }
                // Refused, but for the right reason? A tool that happened to fail on a missing
                // argument would look identical here and would be hiding a hole.
                let denied = output.text.contains("[grant.")
                    || output.text.contains("[core.notImplemented]")
                    || output.text.contains("[workbook.unsupportedFormat]")
                guard denied else {
                    escapes.append(
                        "\(tool.schema.name) ← \(testCase.name): refused for the wrong reason: "
                            + output.text.prefix(120)
                    )
                    continue
                }
            }
        }
        #expect(escapes.isEmpty, "GRANT ESCAPES (P0):\n\(escapes.joined(separator: "\n"))")
    }

    /// The suite is not vacuous: the same tools succeed on a path inside the grant.
    ///
    /// Without this, a bug that denied everything would turn the suite above green.
    @Test @MainActor func theSamePathInsideTheGrantIsAllowed() async throws {
        let layout = try layout()
        let path = layout.workspacePath + "/budget.xlsx"

        let describe = await layout.harness.call("describe", ["path": .string(path)])
        #expect(!describe.isError, "\(describe.text)")
        #expect(describe.text.contains("Budget"))

        let read = await layout.harness.call("read_range", ["path": .string(path), "range": .string("A1:D2")])
        #expect(!read.isError, "\(read.text)")

        let find = await layout.harness.call("find", ["path": .string(path), "query": .string("Rent")])
        #expect(!find.isError, "\(find.text)")
        #expect(find.text.contains("A2"))
    }

    /// The denial says what to do about it, and says it is the *app* that does it.
    @Test @MainActor func denialTellsTheUserWhereToGrant() async throws {
        let layout = try layout()
        let output = await layout.harness.call(
            "describe", ["path": .string("\(layout.scratchPath)/outside/secrets.xlsx")]
        )
        #expect(output.isError)
        #expect(output.text.contains("grant.outsideWorkspace"))
        #expect(output.text.lowercased().contains("opensheets"), "\(output.text)")
    }

    /// The deny-list beats the grant, and names the rule that fired.
    @Test @MainActor func denyListOverridesTheGrantAndNamesTheRule() async throws {
        let layout = try layout()
        let output = await layout.harness.call(
            "describe", ["path": .string("\(layout.workspacePath)/server.pem")]
        )
        #expect(output.isError)
        #expect(output.text.contains("grant.denyListed"))
        #expect(output.text.contains("*.pem"), "\(output.text)")
    }

    /// The server cannot create a grant, whatever it is handed.
    ///
    /// Two independent barriers, and this asserts the second: even holding an authorisation
    /// token, a store in ``SheetStore/SheetStore/Mode/mcpServer`` refuses. The first barrier —
    /// that the token's only public initialiser is `@MainActor` over an `NSOpenPanel` result,
    /// and neither shipped binary links AppKit — is a compile-time property and has no runtime
    /// test by construction.
    @Test @MainActor func theServerCannotGrantItselfAnything() throws {
        let scratch = Scratch("no-self-grant")
        let support = scratch.directory("support")
        let target = scratch.directory("target")
        let store = try SheetStore(
            mode: .mcpServer, configuration: SheetStore.Configuration(applicationSupport: support)
        )
        #expect(throws: SheetError.self) {
            try store.grantWorkspace(UserGrantAuthorization(userSelectedDirectory: target))
        }
        #expect(store.activeGrantCount == 0)
        #expect(!store.grants.isAllowed(target.path(percentEncoded: false)))
    }

    /// Revoking in the app stops the server immediately — no restart, no cache to go stale.
    @Test @MainActor func revokingInTheAppStopsTheServer() async throws {
        let scratch = Scratch("revoke")
        let support = scratch.directory("support")
        let workspace = scratch.directory("workspace")
        let configuration = SheetStore.Configuration(applicationSupport: support)

        let app = try SheetStore(mode: .app, configuration: configuration)
        let grant = try app.grantWorkspace(UserGrantAuthorization(userSelectedDirectory: workspace))

        let server = try SheetStore(mode: .mcpServer, configuration: configuration)
        let harness = Harness(
            scratch: scratch,
            workspace: workspace,
            store: server,
            broker: DocumentBroker(store: server),
            context: ToolContext(
                broker: DocumentBroker(store: server), handshake: AppHandshake(applicationSupport: support)
            )
        )
        _ = try harness.install(Fixtures.budget(), as: "budget.xlsx")
        let path = workspace.appendingPathComponent("budget.xlsx").path(percentEncoded: false)
        #expect(server.grants.isAllowed(path))

        try app.grants.revoke(id: try #require(grant.id))
        server.grants.invalidateCache()
        #expect(!server.grants.isAllowed(path))

        let output = await harness.call("describe", ["path": .string(path)])
        #expect(output.isError)
        #expect(output.text.contains("grant."))
    }

    /// A second path argument is checked too.
    ///
    /// `convert` is the only place a tool call names two files, and it is exactly the shape of
    /// hole a suite that only ever passes one path would miss: reading from inside the grant and
    /// writing outside it is an exfiltration primitive with a friendly name.
    @Test @MainActor func convertChecksBothEnds() async throws {
        let layout = try layout()
        let inside = layout.workspacePath + "/budget.xlsx"
        let outside = layout.scratchPath + "/outside/exfiltrated.csv"

        let captured = CapturedConsole()
        let console = captured.writer
        let code = await OpenSheetsCLI.run(
            arguments: ["convert", inside, outside],
            console: console,
            configuration: SheetStore.Configuration(
                applicationSupport: layout.harness.scratch.url.appendingPathComponent("support")
            )
        )
        #expect(code == ExitCode.denied)
        #expect(!FileManager.default.fileExists(atPath: outside))
        #expect(captured.text.contains("grant."), "\(captured.text)")
    }

    /// Arguments for a tool, filling every required field so the call reaches the path check
    /// rather than failing on a missing argument.
    static func arguments(for schema: ToolSchema, path: String) -> [String: JSONValue] {
        var values: [String: JSONValue] = ["path": .string(path)]
        for property in schema.properties where property.isRequired && property.name != "path" {
            values[property.name] = placeholder(property)
        }
        // A few tools need a well-formed optional to get past parsing.
        if schema.name == "sort" {
            values["by"] = .array([.object(["column": .string("A"), "order": .string("asc")])])
        }
        if schema.name == "filter" {
            values["where"] = .array([.object([
                "column": .string("A"), "op": .string("notEmpty"),
            ])])
        }
        return values
    }

    private static func placeholder(_ property: ToolProperty) -> JSONValue {
        switch property.kind {
        case .string: property.name == "range" ? .string("A1") : .string("A")
        case .integer: .integer(1)
        case .number: .number(1)
        case .boolean: .bool(false)
        case .array: .array([.array([.integer(1)])])
        case .object: .object([:])
        }
    }
}

extension SheetStore {
    /// Convenience for the assertions above.
    var activeGrantCount: Int { grants.activeGrants().count }
}
