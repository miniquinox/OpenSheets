import Foundation
@testable import SheetMCP
import SheetModel
import SheetStore
import TestSupport
import Testing

/// The command line and the tool surface, held against each other.
///
/// # Why this is a test and not a paragraph in the README
///
/// They drifted, silently, and nobody noticed until somebody needed `recalc` from a terminal and
/// had to drive the MCP server over JSON-RPC to get it: `opensheets --help` listed twelve commands
/// while `tools/list` returned twenty. Both lists were hand-maintained, so the only thing keeping
/// them equal was memory.
///
/// ``CLISurface`` is now the one table, and this suite is what makes it binding. Add a tool without
/// giving it a command or a reason, and this fails.
@Suite struct CLISurfaceTests {
    // MARK: - The audit

    @Test func everyToolIsEitherACommandOrDeliberatelyNot() {
        let commanded = Set(CLISurface.commands.compactMap(\.tool))
        let excused = Set(CLISurface.toolsWithoutACommand.keys)

        var missing: [String] = []
        for tool in ToolRegistry.standard.names where !commanded.contains(tool) && !excused.contains(tool) {
            missing.append(tool)
        }
        #expect(
            missing.isEmpty,
            """
            \(missing.joined(separator: ", ")) can be called over MCP but not from a terminal. \
            Add a command to CLISurface.commands, or an entry in CLISurface.toolsWithoutACommand \
            saying why it is MCP-only.
            """
        )
    }

    @Test func noCommandNamesAToolThatDoesNotExist() {
        let known = Set(ToolRegistry.standard.names)
        for command in CLISurface.commands {
            guard let tool = command.tool else { continue }
            #expect(known.contains(tool), "`opensheets \(command.name)` runs `\(tool)`, which is not a tool")
        }
    }

    @Test func excusedToolsAreRealToolsWithRealReasons() {
        let known = Set(ToolRegistry.standard.names)
        for (tool, reason) in CLISurface.toolsWithoutACommand {
            #expect(known.contains(tool), "\(tool) is excused from the CLI but is not a tool")
            #expect(reason.count > 20, "\(tool)'s exemption needs a reason, not a placeholder")
        }
    }

    @Test func commandNamesAreUnique() {
        #expect(Set(CLISurface.names).count == CLISurface.names.count)
    }

    // MARK: - The two ends of the table

    @Test func helpListsEveryCommand() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(arguments: ["help"], console: console.writer)
        #expect(code == ExitCode.success)
        for command in CLISurface.commands {
            #expect(console.text.contains(command.form), "`--help` does not mention \(command.form)")
        }
    }

    /// Every name in the table reaches a real branch of the dispatcher.
    ///
    /// Run with no arguments, so each one either does its job or says what it needed. What none of
    /// them may say is *"unknown command"* — a command in the help that the dispatcher has never
    /// heard of is worse than no command at all.
    @Test func everyCommandIsDispatched() async throws {
        let scratch = Scratch("dispatch")
        let support = scratch.directory("support")
        for command in CLISurface.commands where command.name != "serve" {
            let console = CapturedConsole()
            _ = await OpenSheetsCLI.run(
                arguments: [command.name],
                console: console.writer,
                configuration: SheetStore.Configuration(applicationSupport: support)
            )
            #expect(
                !console.text.contains("unknown command"),
                "`opensheets \(command.name)` is in the help but not in the dispatcher"
            )
        }
    }

    // MARK: - The one that started it

    @Test @MainActor func recalcIsACommand() async throws {
        let harness = try Harness.make("cli-recalc")
        let support = harness.scratch.url.appendingPathComponent("support")
        let workbook = try WorkbookBuilder()
            .sheet("Summary")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [[.number(2)], [.number(3)]])
            .formula("A3", "SUM(A1:A2)", cached: .number(0))
            .build()
        let path = try harness.install(workbook, as: "totals.xlsx")

        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(
            arguments: ["recalc", path],
            console: console.writer,
            configuration: SheetStore.Configuration(applicationSupport: support)
        )
        #expect(code == ExitCode.success)
        #expect(console.text.contains("evaluated"))

        let reloaded = try await harness.reload(path)
        #expect(reloaded.sheets[0].cells[CellRef(a1: "A3")!]?.value == .number(5))
    }

    /// `--preview` on a write command reports without touching the file, the same way the tool's
    /// `preview` argument does. Checked on one command because it is one shared code path.
    @Test @MainActor func previewReachesTheToolsThroughTheCommandLine() async throws {
        let harness = try Harness.make("cli-preview")
        let support = harness.scratch.url.appendingPathComponent("support")
        let path = try harness.install(try Fixtures.reportWithTitle(), as: "report.xlsx")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(
            arguments: ["sort", path, "B:desc", "--preview"],
            console: console.writer,
            configuration: SheetStore.Configuration(applicationSupport: support)
        )
        #expect(code == ExitCode.success)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }

    /// A sort key with an order nobody meant is a usage error, not a silently ascending sort.
    @Test func aMalformedSortKeyIsRefused() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(
            arguments: ["sort", "/nowhere/book.xlsx", "B:sideways"],
            console: console.writer
        )
        #expect(code == ExitCode.usage)
        #expect(console.text.contains("asc or desc"))
    }

    /// `format` takes `key=value`, and says so rather than guessing when it does not get one.
    @Test func aMalformedFormatArgumentIsRefused() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(
            arguments: ["format", "/nowhere/book.xlsx", "A1", "bold"],
            console: console.writer
        )
        #expect(code == ExitCode.usage)
        #expect(console.text.contains("key=value"))
    }
}
