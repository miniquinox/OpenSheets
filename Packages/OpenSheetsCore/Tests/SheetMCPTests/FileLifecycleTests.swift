import Foundation
@testable import SheetMCP
import SheetModel
import SheetStore
import Testing

// MARK: - A launcher that records instead of launching

/// The spy behind every `open_in_app` test: no test in this suite may start a GUI, and the only
/// way to *prove* none did is to count.
final class LaunchSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
    }

    var launched: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

/// A harness whose handshake launches into the spy rather than into `/usr/bin/open`.
struct SpiedHarness {
    var harness: Harness
    var spy: LaunchSpy
    var context: ToolContext
    var handshake: AppHandshake

    @MainActor
    static func make(_ name: String) throws -> SpiedHarness {
        let harness = try Harness.make(name)
        let spy = LaunchSpy()
        let handshake = AppHandshake(
            applicationSupport: harness.scratch.url.appendingPathComponent("support"),
            launch: { url in
                spy.record(url)
                return true
            }
        )
        return SpiedHarness(
            harness: harness,
            spy: spy,
            context: ToolContext(broker: harness.broker, handshake: handshake),
            handshake: handshake
        )
    }

    /// The same dispatch path ``Harness/call(_:_:)`` uses, over the spying context.
    func call(_ name: String, _ arguments: [String: JSONValue]) async -> ToolOutput {
        guard let definition = ToolRegistry.standard.definition(named: name) else {
            return ToolOutput("no tool named \(name)", isError: true)
        }
        return await MCPServer.execute(
            definition,
            call: ToolCall(name: name, arguments: ToolArguments(tool: name, values: arguments), context: context),
            log: MCPLog(destination: .none)
        )
    }

    /// Where `open_in_app` writes its request for `url`.
    func requestFile(for url: URL) -> URL {
        handshake.directory.appendingPathComponent("\(AppHandshake.key(url)).request.json")
    }
}

// MARK: - new_workbook

@Suite("new_workbook creates files it will never overwrite")
struct NewWorkbookTests {
    @Test("A created workbook round-trips through describe with its sheets in order")
    @MainActor func createdWorkbookRoundTripsThroughDescribe() async throws {
        let harness = try Harness.make("new-roundtrip")
        let path = harness.workspace.appendingPathComponent("t.xlsx").path(percentEncoded: false)

        let created = await harness.call("new_workbook", [
            "path": .string(path),
            "sheets": .array([.string("Data"), .string("Summary")]),
        ])
        #expect(!created.isError, "\(created.text)")
        #expect(created.text.contains("created"))
        #expect(created.text.contains("2 sheets"))

        let described = await harness.call("describe", ["path": .string(path)])
        #expect(!described.isError, "\(described.text)")
        #expect(described.text.contains("Data"))
        #expect(described.text.contains("Summary"))

        // The file, not the memory: order is a property of the bytes on disk.
        let reloaded = try await harness.reload(path)
        #expect(reloaded.sheets.map(\.name) == ["Data", "Summary"])
    }

    @Test("Omitting sheets yields one sheet named Sheet1")
    @MainActor func omittedSheetsDefaultToSheet1() async throws {
        let harness = try Harness.make("new-default")
        let path = harness.workspace.appendingPathComponent("plain.xlsx").path(percentEncoded: false)

        let created = await harness.call("new_workbook", ["path": .string(path)])
        #expect(!created.isError, "\(created.text)")
        let reloaded = try await harness.reload(path)
        #expect(reloaded.sheets.map(\.name) == ["Sheet1"])
    }

    @Test("An existing file is refused and left byte-identical")
    @MainActor func existingFilesAreNeverOverwritten() async throws {
        let harness = try Harness.make("new-no-overwrite")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let refused = await harness.call("new_workbook", ["path": .string(path)])
        #expect(refused.isError)
        #expect(refused.text.contains("file.notWritable"), "\(refused.text)")
        #expect(refused.text.contains("never overwrites"), "\(refused.text)")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before, "the refusal touched the file")
    }

    @Test("A csv refuses a sheets list, because the format holds exactly one sheet")
    @MainActor func delimitedFormatsRefuseASheetList() async throws {
        let harness = try Harness.make("new-csv-sheets")
        let path = harness.workspace.appendingPathComponent("d.csv").path(percentEncoded: false)

        let refused = await harness.call("new_workbook", [
            "path": .string(path),
            "sheets": .array([.string("A"), .string("B")]),
        ])
        #expect(refused.isError)
        #expect(refused.text.contains("tool.invalidArguments"), "\(refused.text)")
        #expect(refused.text.contains("one sheet"), "\(refused.text)")
        #expect(!FileManager.default.fileExists(atPath: path), "the refusal created the file anyway")
    }

    @Test("A csv without a sheets list is created and readable")
    @MainActor func aPlainCSVIsCreated() async throws {
        let harness = try Harness.make("new-csv")
        let path = harness.workspace.appendingPathComponent("fresh.csv").path(percentEncoded: false)

        let created = await harness.call("new_workbook", ["path": .string(path)])
        #expect(!created.isError, "\(created.text)")
        #expect(FileManager.default.fileExists(atPath: path))

        let write = await harness.call("write_range", [
            "path": .string(path),
            "range": .string("A1"),
            "values": .array([.array([.string("hello")])]),
        ])
        #expect(!write.isError, "\(write.text)")
    }

    @Test("Duplicate sheet names are refused, case-insensitively, the way Excel compares them")
    @MainActor func duplicateSheetNamesAreRefused() async throws {
        let harness = try Harness.make("new-duplicates")
        let path = harness.workspace.appendingPathComponent("dup.xlsx").path(percentEncoded: false)

        let refused = await harness.call("new_workbook", [
            "path": .string(path),
            "sheets": .array([.string("Data"), .string("data")]),
        ])
        #expect(refused.isError)
        #expect(refused.text.contains("tool.invalidArguments"), "\(refused.text)")
        #expect(refused.text.contains("duplicate"), "\(refused.text)")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("An unwritable extension is refused before the filesystem is consulted")
    @MainActor func unwritableExtensionsAreRefused() async throws {
        let harness = try Harness.make("new-txt")
        let path = harness.workspace.appendingPathComponent("notes.txt").path(percentEncoded: false)

        let refused = await harness.call("new_workbook", ["path": .string(path)])
        #expect(refused.isError)
        #expect(refused.text.contains("workbook.unsupportedFormat"), "\(refused.text)")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Preview validates everything and creates nothing")
    @MainActor func previewCreatesNothing() async throws {
        let harness = try Harness.make("new-preview")
        let path = harness.workspace.appendingPathComponent("would-be.xlsx").path(percentEncoded: false)

        let preview = await harness.call("new_workbook", [
            "path": .string(path),
            "sheets": .array([.string("Data")]),
            "preview": .bool(true),
        ])
        #expect(!preview.isError, "\(preview.text)")
        #expect(preview.text.contains("preview only"))
        #expect(!FileManager.default.fileExists(atPath: path), "a preview wrote a file")
    }
}

// MARK: - delete_file

@Suite("delete_file is double-recoverable")
struct DeleteFileTests {
    @Test("Delete snapshots first, trashes, and restore resurrects the file byte-identically")
    @MainActor func deleteThenRestoreIsAFullCycle() async throws {
        let harness = try Harness.make("delete-restore")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let original = try Data(contentsOf: URL(fileURLWithPath: path))

        let deleted = await harness.call("delete_file", ["path": .string(path)])
        #expect(!deleted.isError, "\(deleted.text)")
        #expect(deleted.text.contains("trashed"))
        #expect(deleted.text.contains("restore(path,"), "the undo line is missing: \(deleted.text)")
        #expect(!FileManager.default.fileExists(atPath: path), "the file survived its own deletion")

        // The snapshot outlives the file, and says why it was taken.
        let listed = await harness.call("list_snapshots", ["path": .string(path)])
        #expect(!listed.isError, "\(listed.text)")
        #expect(listed.text.contains("before delete_file"), "\(listed.text)")

        // The documented undo: restore with no id takes the newest snapshot — the one the
        // delete just took — and must work on a target that no longer exists.
        let restored = await harness.call("restore", ["path": .string(path)])
        #expect(!restored.isError, "\(restored.text)")
        #expect(FileManager.default.fileExists(atPath: path), "restore did not resurrect the file")
        #expect(
            try Data(contentsOf: URL(fileURLWithPath: path)) == original,
            "the resurrected file is not byte-identical"
        )
    }

    @Test("Preview reports size and sheet count and touches nothing")
    @MainActor func previewTouchesNothing() async throws {
        let harness = try Harness.make("delete-preview")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let preview = await harness.call("delete_file", ["path": .string(path), "preview": .bool(true)])
        #expect(!preview.isError, "\(preview.text)")
        #expect(preview.text.contains("preview only, nothing trashed"))
        #expect(preview.text.contains("would trash"))
        #expect(preview.text.contains("1 sheet"), "\(preview.text)")
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)

        let listed = await harness.call("list_snapshots", ["path": .string(path)])
        #expect(!listed.text.contains("before delete_file"), "a preview took a snapshot: \(listed.text)")
    }

    @Test("A file that does not exist is a file.notFound, not a trash attempt")
    @MainActor func aMissingFileIsReportedAsMissing() async throws {
        let harness = try Harness.make("delete-missing")
        let path = harness.workspace.appendingPathComponent("ghost.xlsx").path(percentEncoded: false)

        let refused = await harness.call("delete_file", ["path": .string(path)])
        #expect(refused.isError)
        #expect(refused.text.contains("file.notFound"), "\(refused.text)")
    }
}

// MARK: - open_in_app

@Suite("open_in_app writes the request and launches through the seam")
struct OpenInAppTests {
    @Test("The request file has exactly the documented shape, optional fields genuinely absent")
    @MainActor func theRequestMatchesTheDocumentedShape() async throws {
        let spied = try SpiedHarness.make("open-shape")
        let path = try spied.harness.install(try Fixtures.budget(), as: "budget.xlsx")
        let url = URL(fileURLWithPath: path)

        // Bare open: no sheet, no range — and therefore no sheet or range *keys*.
        let bare = await spied.call("open_in_app", ["path": .string(path)])
        #expect(!bare.isError, "\(bare.text)")
        #expect(bare.text.contains("asked OpenSheets to open"))
        let bareRequest = try JSONValue.parse(try Data(contentsOf: spied.requestFile(for: url)))
        let bareKeys = Set(try #require(bareRequest.objectValue).keys)
        #expect(bareKeys == ["path", "requestedAt"],
                "optional fields must be absent, not null: \(bareRequest.rendered)")
        #expect(bareRequest["path"]?.stringValue == url.path(percentEncoded: false))
        #expect(bareRequest["requestedAt"]?.doubleValue != nil)
        #expect(spied.spy.launched == [url], "one open, one launch")

        // Qualified open: both optional fields present and validated against the workbook.
        let qualified = await spied.call("open_in_app", [
            "path": .string(path),
            "sheet": .string("Budget"),
            "range": .string("A1:B2"),
        ])
        #expect(!qualified.isError, "\(qualified.text)")
        let fullRequest = try JSONValue.parse(try Data(contentsOf: spied.requestFile(for: url)))
        #expect(fullRequest["sheet"]?.stringValue == "Budget")
        #expect(fullRequest["range"]?.stringValue == "A1:B2")
        #expect(fullRequest["path"]?.stringValue == url.path(percentEncoded: false))
        #expect(spied.spy.launched.count == 2)
    }

    @Test("A sheet the workbook does not have is refused before anything is written or launched")
    @MainActor func anUnknownSheetIsRefusedBeforeAnySideEffect() async throws {
        let spied = try SpiedHarness.make("open-bad-sheet")
        let path = try spied.harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let refused = await spied.call("open_in_app", [
            "path": .string(path),
            "sheet": .string("Nope"),
        ])
        #expect(refused.isError)
        #expect(spied.spy.launched.isEmpty, "a refused call launched the app")
        #expect(!FileManager.default.fileExists(
            atPath: spied.requestFile(for: URL(fileURLWithPath: path)).path(percentEncoded: false)
        ))
    }

    @Test("Preview writes no request and never reaches the launcher")
    @MainActor func previewIsSideEffectFree() async throws {
        let spied = try SpiedHarness.make("open-preview")
        let path = try spied.harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let preview = await spied.call("open_in_app", [
            "path": .string(path),
            "range": .string("A1:B2"),
            "preview": .bool(true),
        ])
        #expect(!preview.isError, "\(preview.text)")
        #expect(preview.text.contains("preview only"))
        #expect(spied.spy.launched.isEmpty, "a preview launched the app")
        #expect(!FileManager.default.fileExists(
            atPath: spied.requestFile(for: URL(fileURLWithPath: path)).path(percentEncoded: false)
        ), "a preview wrote a request")
    }

    /// The escape suite runs every tool against every hostile path; this pins the part only a
    /// spy can see — that a refused path never reaches the launcher and never writes a request.
    @Test("A path outside the grant is refused before the request write and before the launcher")
    @MainActor func hostilePathsNeverLaunch() async throws {
        let spied = try SpiedHarness.make("open-hostile")
        let hostile = [
            "/etc/hosts.csv",
            spied.harness.workspace.path(percentEncoded: false) + "/../outside/secrets.xlsx",
        ]
        for path in hostile {
            let refused = await spied.call("open_in_app", ["path": .string(path)])
            #expect(refused.isError, "\(path) was not refused")
            #expect(refused.text.contains("[grant."), "\(path): \(refused.text)")
            #expect(!FileManager.default.fileExists(
                atPath: spied.requestFile(for: URL(fileURLWithPath: path)).path(percentEncoded: false)
            ), "\(path) wrote a request")
        }
        #expect(spied.spy.launched.isEmpty, "a hostile path reached the launcher: \(spied.spy.launched)")
    }
}

// MARK: - Freeze panes

@Suite("set_format freezes and unfreezes panes")
struct FreezePaneTests {
    @Test("freezeRows and freezeColumns land in describe and on disk")
    @MainActor func freezingShowsInDescribeAndSurvivesTheFile() async throws {
        let harness = try Harness.make("freeze")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let frozen = await harness.call("set_format", [
            "path": .string(path),
            "range": .string("A1"),
            "freezeRows": .integer(1),
        ])
        #expect(!frozen.isError, "\(frozen.text)")
        #expect(frozen.text.contains("froze the top 1 row"), "\(frozen.text)")

        let described = await harness.call("describe", ["path": .string(path)])
        #expect(described.text.contains("frozen 1r/0c"), "\(described.text)")

        // The file, not the session: the writer must re-emit `<sheetViews>` for this sheet.
        let onDisk = try await harness.reload(path)
        #expect(onDisk.sheets[0].frozen.frozenRows == 1)

        let both = await harness.call("set_format", [
            "path": .string(path),
            "range": .string("A1"),
            "freezeColumns": .integer(2),
        ])
        #expect(!both.isError, "\(both.text)")
        let redescribed = await harness.call("describe", ["path": .string(path)])
        #expect(redescribed.text.contains("frozen 1r/2c"), "\(redescribed.text)")
    }

    @Test("Zero unfreezes, on screen and on disk")
    @MainActor func zeroUnfreezes() async throws {
        let harness = try Harness.make("unfreeze")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        _ = await harness.call("set_format", [
            "path": .string(path), "range": .string("A1"), "freezeRows": .integer(1),
        ])
        let unfrozen = await harness.call("set_format", [
            "path": .string(path), "range": .string("A1"), "freezeRows": .integer(0),
        ])
        #expect(!unfrozen.isError, "\(unfrozen.text)")
        #expect(unfrozen.text.contains("unfroze rows"), "\(unfrozen.text)")

        let described = await harness.call("describe", ["path": .string(path)])
        #expect(!described.text.contains("frozen"), "\(described.text)")
        let onDisk = try await harness.reload(path)
        #expect(onDisk.sheets[0].frozen.isFrozen == false)
    }

    @Test("A negative freeze is a tool.invalidArguments, never a trap")
    @MainActor func negativeFreezesAreRefused() async throws {
        let harness = try Harness.make("freeze-negative")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let refused = await harness.call("set_format", [
            "path": .string(path), "range": .string("A1"), "freezeRows": .integer(-1),
        ])
        #expect(refused.isError)
        #expect(refused.text.contains("tool.invalidArguments"), "\(refused.text)")
        #expect(refused.text.contains("freezeRows"), "\(refused.text)")
    }
}

// MARK: - CLI parity

@Suite("The lifecycle commands work from a terminal")
struct FileLifecycleCLITests {
    private struct Run {
        var code: Int32
        var text: String
    }

    @MainActor
    private func harnessAndRunner(_ name: String) throws -> (Harness, @Sendable ([String]) async -> Run) {
        let harness = try Harness.make(name)
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

    @Test("`opensheets new` creates the workbook and describe shows both sheets")
    @MainActor func newCreatesFromTheCommandLine() async throws {
        let (harness, run) = try harnessAndRunner("cli-new")
        let path = harness.workspace.appendingPathComponent("t.xlsx").path(percentEncoded: false)

        let created = await run(["new", path, "Data", "Summary"])
        #expect(created.code == ExitCode.success, "\(created.text)")

        let described = await run(["describe", path])
        #expect(described.code == ExitCode.success, "\(described.text)")
        #expect(described.text.contains("Data"))
        #expect(described.text.contains("Summary"))
        let reloaded = try await harness.reload(path)
        #expect(reloaded.sheets.count == 2)
    }

    @Test("`opensheets new` outside the grant exits 3")
    @MainActor func newOutsideTheGrantExitsDenied() async throws {
        let (_, run) = try harnessAndRunner("cli-new-denied")
        let denied = await run(["new", "/etc/x.xlsx"])
        #expect(denied.code == ExitCode.denied, "\(denied.text)")
        #expect(denied.text.contains("grant."), "\(denied.text)")
    }

    @Test("`opensheets delete-file` trashes the file")
    @MainActor func deleteFileFromTheCommandLine() async throws {
        let (harness, run) = try harnessAndRunner("cli-delete")
        let path = try harness.install(try Fixtures.budget(), as: "budget.xlsx")

        let deleted = await run(["delete-file", path])
        #expect(deleted.code == ExitCode.success, "\(deleted.text)")
        #expect(deleted.text.contains("trashed"))
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Help lists all three lifecycle commands")
    func helpListsTheLifecycleCommands() async {
        let console = CapturedConsole()
        let code = await OpenSheetsCLI.run(arguments: ["help"], console: console.writer)
        #expect(code == ExitCode.success)
        #expect(console.text.contains("new <file> [sheet ...]"))
        #expect(console.text.contains("delete-file <file>"))
        #expect(console.text.contains("open <file> [range]"))
    }
}
