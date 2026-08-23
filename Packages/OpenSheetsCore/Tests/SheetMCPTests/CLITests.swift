import Foundation
@testable import SheetMCP
import SheetModel
import SheetStore
import Testing

/// The `opensheets` command line.
///
/// Driven in-process through ``OpenSheetsCLI/run(arguments:console:configuration:)``, which is
/// exactly what `CLI/opensheets/main.swift` calls — the executable target is three lines, so
/// running the driver *is* running the binary's behaviour, and unlike the binary it can be
/// pointed at a temporary store.
@Suite struct CLITests {
    private struct Run {
        var code: Int32
        var text: String
    }

    @MainActor
    private func harnessAndRunner() throws -> (Harness, @Sendable ([String]) async -> Run) {
        let harness = try Harness.make("cli")
        let support = harness.scratch.url.appendingPathComponent("support")
        let runner: @Sendable ([String]) async -> Run = { arguments in
            let console = CapturedConsole()
            let code = await OpenSheetsCLI.run(
                arguments: arguments,
                console: console.writer,
                configuration: SheetStore.Configuration(applicationSupport: support)
            )
            return Run(code: code, text: console.text)
        }
        return (harness, runner)
    }

    /// `help` and `version` work without touching the store.
    @Test func helpAndVersionNeedNothing() async {
        let console = CapturedConsole()
        let help = await OpenSheetsCLI.run(arguments: ["help"], console: console.writer)
        #expect(help == ExitCode.success)
        #expect(console.text.contains("Run as an MCP server"))
        #expect(console.text.contains("claude mcp add opensheets"))

        let versionConsole = CapturedConsole()
        let version = await OpenSheetsCLI.run(arguments: ["--version"], console: versionConsole.writer)
        #expect(version == ExitCode.success)
        #expect(versionConsole.text.contains(MCPServer.serverVersion))
    }

    /// No arguments is a usage error, not a crash and not a silent success.
    @Test func noArgumentsIsAUsageError() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(arguments: [], console: console.writer)
        #expect(code == ExitCode.usage)
    }

    /// An unknown command names the help.
    @Test func unknownCommandsPointAtHelp() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(arguments: ["frobnicate"], console: console.writer)
        #expect(code == ExitCode.usage)
        #expect(console.text.contains("opensheets help"))
    }

    /// `describe` prints the same thing the MCP tool returns.
    @Test @MainActor func describePrintsTheProfile() async throws {
        let (harness, run) = try harnessAndRunner()
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let output = await run(["describe", path])
        #expect(output.code == ExitCode.success)
        #expect(output.text.contains("Budget"))
        #expect(output.text.contains("header=row 1"))
    }

    /// `--json` produces something a script can parse.
    @Test @MainActor func jsonOutputIsParseable() async throws {
        let (harness, run) = try harnessAndRunner()
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let output = await run(["describe", path, "--json"])
        #expect(output.code == ExitCode.success)
        let parsed = try JSONValue.parse(output.text)
        #expect(parsed["tool"] == .string("describe"))
        #expect(parsed["isError"] == .bool(false))
        #expect(parsed["text"]?.stringValue?.contains("Budget") == true)
    }

    /// `get` and `set` do what they say, and `set` writes the file.
    @Test @MainActor func getAndSetRoundTrip() async throws {
        let (harness, run) = try harnessAndRunner()
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let before = await run(["get", path, "A1:B2"])
        #expect(before.code == ExitCode.success)
        #expect(before.text.contains("Rent"))

        let set = await run(["set", path, "B2", "12345"])
        #expect(set.code == ExitCode.success)
        #expect(try await harness.reload(path).sheets[0].cells[try cellRef("B2")]?.value == .number(12345))

        let text = await run(["set", path, "A2", "Renamed"])
        #expect(text.code == ExitCode.success)
        #expect(try await harness.reload(path).sheets[0].cells[try cellRef("A2")]?.value == .text("Renamed"))
    }

    /// `--preview` on `set` writes nothing.
    @Test @MainActor func previewOnTheCommandLineWritesNothing() async throws {
        let (harness, run) = try harnessAndRunner()
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))

        let output = await run(["set", path, "B2", "9999", "--preview"])
        #expect(output.code == ExitCode.success)
        #expect(output.text.contains("preview only"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
    }

    /// `convert` writes the other format, inside the grant.
    @Test @MainActor func convertWritesTheOtherFormat() async throws {
        let (harness, run) = try harnessAndRunner()
        let source = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let destination = harness.workspace.appendingPathComponent("budget.csv").path(percentEncoded: false)

        let output = await run(["convert", source, destination])
        #expect(output.code == ExitCode.success, "\(output.text)")
        let csv = try String(contentsOf: URL(fileURLWithPath: destination), encoding: .utf8)
        #expect(csv.contains("Item,Q1,Q2,Total"))
        #expect(csv.contains("Rent,100,110"))
    }

    /// `diff` says what changed between two files, and says nothing when they match.
    @Test @MainActor func diffComparesTwoWorkbooks() async throws {
        let (harness, run) = try harnessAndRunner()
        let first = try harness.install(try Fixtures.budget(), as: "a.xlsx")
        var changed = try Fixtures.budget()
        try changed.sheets[0].cells.setCell(.number(999), at: try cellRef("B2"))
        let second = try harness.install(changed, as: "b.xlsx")

        let same = await run(["diff", first, first])
        #expect(same.code == ExitCode.success)
        #expect(same.text.contains("identical"))

        let different = await run(["diff", first, second])
        #expect(different.code == ExitCode.success)
        #expect(different.text.contains("100 → 999"), "\(different.text)")
    }

    /// `snapshot`, `snapshots` and `restore` are a working undo from a shell.
    @Test @MainActor func snapshotAndRestoreFromTheCommandLine() async throws {
        let (harness, run) = try harnessAndRunner()
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        #expect(await run(["snapshot", path, "before"]).code == ExitCode.success)
        _ = await run(["set", path, "B2", "1"])

        let listed = await run(["snapshots", path])
        #expect(listed.code == ExitCode.success)
        #expect(listed.text.contains("manual"))

        let restored = await run(["restore", path])
        #expect(restored.code == ExitCode.success, "\(restored.text)")
        #expect(try await harness.reload(path).sheets[0].cells[try cellRef("B2")]?.value == .number(100))
    }

    /// A denied path exits 3, so a wrapper script can tell it from an ordinary failure.
    @Test @MainActor func aDeniedPathHasItsOwnExitCode() async throws {
        let (harness, run) = try harnessAndRunner()
        let outside = harness.scratch.url.appendingPathComponent("elsewhere.xlsx").path(percentEncoded: false)
        _ = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        try FileManager.default.copyItem(
            atPath: harness.workspace.appendingPathComponent("budget.xlsx").path(percentEncoded: false),
            toPath: outside
        )

        let output = await run(["describe", outside])
        #expect(output.code == ExitCode.denied)
        #expect(output.text.contains("grant."))
    }

    /// **The CLI cannot grant a folder, and says where to do it instead.**
    ///
    /// If it could, an agent could shell out to it and grant itself the home directory — which
    /// would make the whole boundary decorative. The refusal explains the actual reason rather
    /// than saying "unsupported".
    @Test @MainActor func theCLICannotGrantAFolder() async throws {
        let (harness, run) = try harnessAndRunner()
        let output = await run(["grant", harness.scratch.url.path(percentEncoded: false)])
        #expect(output.code == ExitCode.denied)
        #expect(output.text.contains("OpenSheets app"))
        #expect(output.text.contains("AppKit"), "the refusal explains why it is not merely missing")
    }

    /// `grants` lists what the app granted.
    @Test @MainActor func grantsListsWhatTheAppGranted() async throws {
        let (harness, run) = try harnessAndRunner()
        let output = await run(["grants"])
        #expect(output.code == ExitCode.success)
        #expect(output.text.contains(harness.workspace.lastPathComponent))
    }

    /// `tools` prints the MCP surface, in both shapes.
    @Test func toolsPrintsTheSurface() async throws {
        let console = CapturedConsole()
        #expect(await OpenSheetsCLI.run(arguments: ["tools"], console: console.writer) == ExitCode.success)
        #expect(console.text.contains("describe"))
        #expect(console.text.contains("write_range (writes)"))

        let jsonConsole = CapturedConsole()
        #expect(await OpenSheetsCLI.run(
            arguments: ["tools", "--json"], console: jsonConsole.writer
        ) == ExitCode.success)
        let parsed = try JSONValue.parse(jsonConsole.text)
        #expect(parsed["tools"]?.arrayValue?.count == ToolRegistry.standard.tools.count)
    }

    /// A subcommand missing its arguments prints the form it wanted.
    @Test func missingArgumentsPrintTheUsageLine() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(arguments: ["set", "only-one-argument"], console: console.writer)
        #expect(code == ExitCode.usage)
        #expect(console.text.contains("set <file> <ref> <value>"))
    }
}
