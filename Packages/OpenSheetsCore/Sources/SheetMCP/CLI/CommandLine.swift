import Darwin
import Foundation
import SheetFormat
import SheetModel
import SheetStore

/// Exit codes, so a script can branch without parsing English.
public enum ExitCode {
    /// It worked.
    public static let success: Int32 = 0
    /// The operation failed for a reason about the file or the request.
    public static let failure: Int32 = 1
    /// The command line itself was wrong.
    public static let usage: Int32 = 2
    /// A workspace grant or the deny-list refused the path. Separate from ``failure`` because
    /// this is the one a wrapper script should surface differently: it is fixed in the app, not
    /// by retrying.
    public static let denied: Int32 = 3
}

/// Where human output goes. Injected so a test can read what the CLI printed.
public struct ConsoleWriter: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    /// Writes straight to the descriptors, not through `print`.
    ///
    /// `print` targets whatever "standard output" currently is, and in `serve` mode fd 1 has
    /// deliberately been redirected to stderr so nothing can corrupt the protocol stream. Going
    /// through `FileHandle` keeps the two paths from sharing a global that one of them moved.
    public static let standard = ConsoleWriter(
        out: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
        err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    )
}

/// `opensheets` — the human-facing command line, and `opensheets serve`, the MCP server.
///
/// # One implementation, two front ends
///
/// Almost every subcommand runs **the same ``ToolDefinition`` the MCP server exposes** and
/// prints its text. That is not a shortcut: it means the CLI cannot drift from the tool
/// surface, and that `opensheets describe budget.xlsx` shows a person exactly what an agent
/// sees. When the two disagree, one of them is a bug, and this way there is nowhere for the
/// disagreement to hide.
///
/// `convert` and `diff` are the exceptions — they are file-level operations with no tool
/// equivalent, because an agent asking for a whole-file conversion is an agent that should be
/// asking for a range.
public enum OpenSheetsCLI {
    /// Runs one invocation. `arguments` excludes the executable name.
    public static func run(
        arguments: [String],
        console: ConsoleWriter = .standard,
        configuration: SheetStore.Configuration = .standard()
    ) async -> Int32 {
        var options = Options()
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--json": options.json = true
            case "--preview", "--dry-run": options.preview = true
            case "--formulas": options.formulas = true
            case "--detailed": options.format = "detailed"
            case "--sheet":
                guard index < arguments.count else {
                    console.err("--sheet needs a value")
                    return ExitCode.usage
                }
                options.sheet = arguments[index]
                index += 1
            case "--limit":
                guard index < arguments.count, let value = Int(arguments[index]) else {
                    console.err("--limit needs a number")
                    return ExitCode.usage
                }
                options.limit = value
                index += 1
            case "-h", "--help": positional = ["help"] + positional
            case "-v", "--version": positional = ["version"]
            default:
                guard !argument.hasPrefix("--") else {
                    console.err("unknown option \(argument)")
                    return ExitCode.usage
                }
                positional.append(argument)
            }
        }

        guard let command = positional.first else {
            console.out(usage)
            return ExitCode.usage
        }
        let rest = Array(positional.dropFirst())

        switch command {
        case "help": console.out(usage); return ExitCode.success
        case "version": console.out("opensheets \(MCPServer.serverVersion)"); return ExitCode.success
        case "tools": return listTools(console: console, options: options)
        case "serve": return await serve(configuration: configuration, console: console)
        default: break
        }

        do {
            let store = try SheetStore(mode: .mcpServer, configuration: configuration)
            let broker = DocumentBroker(store: store, log: MCPLog.fromEnvironment())
            defer { Task { await broker.closeAll() } }
            let context = ToolContext(
                broker: broker,
                handshake: AppHandshake(applicationSupport: configuration.applicationSupport)
            )
            return try await dispatch(
                command, rest, options: options, console: console, context: context, store: store
            )
        } catch let error as SheetError {
            return report(error, console: console, options: options)
        } catch {
            console.err("\(error)")
            return ExitCode.failure
        }
    }

    // MARK: - Subcommands

    private static func dispatch(
        _ command: String,
        _ arguments: [String],
        options: Options,
        console: ConsoleWriter,
        context: ToolContext,
        store: SheetStore
    ) async throws -> Int32 {
        switch command {
        case "describe":
            guard let path = arguments.first else { return missing("describe <file>", console) }
            return await invoke("describe", arguments: [
                "path": .string(path),
            ].merging(options.sheet.map { ["sheet": JSONValue.string($0)] } ?? [:]) { _, new in new },
            console: console, options: options, context: context)

        case "get":
            guard arguments.count >= 1 else { return missing("get <file> [range]", console) }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "format": .string(options.format),
                "formulas": .bool(options.formulas),
            ]
            if arguments.count > 1 { payload["range"] = .string(arguments[1]) }
            if let sheet = options.sheet { payload["sheet"] = .string(sheet) }
            if let limit = options.limit { payload["maxRows"] = .integer(limit) }
            return await invoke("read_range", arguments: payload, console: console, options: options, context: context)

        case "set":
            guard arguments.count >= 3 else { return missing("set <file> <ref> <value>", console) }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "range": .string(arguments[1]),
                "values": .array([.array([literal(arguments[2])])]),
                "preview": .bool(options.preview),
            ]
            if let sheet = options.sheet { payload["sheet"] = .string(sheet) }
            return await invoke("write_range", arguments: payload, console: console, options: options, context: context)

        case "find":
            guard arguments.count >= 2 else { return missing("find <file> <query>", console) }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "query": .string(arguments[1]),
            ]
            if let sheet = options.sheet { payload["sheet"] = .string(sheet) }
            if let limit = options.limit { payload["limit"] = .integer(limit) }
            return await invoke("find", arguments: payload, console: console, options: options, context: context)

        case "snapshots":
            guard let path = arguments.first else { return missing("snapshots <file>", console) }
            return await invoke(
                "list_snapshots", arguments: ["path": .string(path)],
                console: console, options: options, context: context
            )

        case "restore":
            guard let path = arguments.first else { return missing("restore <file> [id]", console) }
            var payload: [String: JSONValue] = ["path": .string(path), "preview": .bool(options.preview)]
            if arguments.count > 1 { payload["id"] = .string(arguments[1]) }
            return await invoke("restore", arguments: payload, console: console, options: options, context: context)

        case "snapshot":
            guard let path = arguments.first else { return missing("snapshot <file> [label]", console) }
            var payload: [String: JSONValue] = ["path": .string(path)]
            if arguments.count > 1 { payload["label"] = .string(arguments[1]) }
            return await invoke("snapshot", arguments: payload, console: console, options: options, context: context)

        case "convert":
            guard arguments.count >= 2 else { return missing("convert <in> <out>", console) }
            return try await convert(arguments[0], arguments[1], options: options, console: console, context: context)

        case "diff":
            guard arguments.count >= 2 else { return missing("diff <a> <b>", console) }
            return try await diff(arguments[0], arguments[1], console: console, context: context)

        case "grants":
            return grants(store: store, console: console, options: options)

        case "grant":
            console.err(grantRefusal)
            return ExitCode.denied

        default:
            console.err("unknown command '\(command)'. Try `opensheets help`.")
            return ExitCode.usage
        }
    }

    // MARK: - Running a tool

    private static func invoke(
        _ name: String,
        arguments: [String: JSONValue],
        console: ConsoleWriter,
        options: Options,
        context: ToolContext
    ) async -> Int32 {
        guard let definition = ToolRegistry.standard.definition(named: name) else {
            console.err("no tool named \(name)")
            return ExitCode.failure
        }
        let call = ToolCall(
            name: name, arguments: ToolArguments(tool: name, values: arguments), context: context
        )
        let output = await MCPServer.execute(definition, call: call, log: MCPLog(destination: .none))
        if options.json {
            console.out(JSONValue.object([
                "tool": .string(name),
                "isError": .bool(output.isError),
                "text": .string(output.text),
            ]).rendered)
        } else if output.isError {
            console.err(output.text)
        } else {
            console.out(output.text)
        }
        guard output.isError else { return ExitCode.success }
        return output.text.contains("[grant.") ? ExitCode.denied : ExitCode.failure
    }

    // MARK: - File-level commands

    private static func convert(
        _ source: String,
        _ destination: String,
        options: Options,
        console: ConsoleWriter,
        context: ToolContext
    ) async throws -> Int32 {
        // Both ends go through the grant check. Converting *out* of the workspace would be an
        // exfiltration primitive with a friendly name.
        let input = try context.broker.resolve(source)
        let output = try context.broker.resolve(destination)
        let document = try await context.broker.document(at: source)

        let sheet: Sheet
        if let name = options.sheet {
            sheet = try RangeSelector.sheet(in: document.workbook, named: name, tool: "convert").sheet
        } else if let first = document.workbook.sheets.first {
            sheet = first
        } else {
            console.err("the workbook has no sheets")
            return ExitCode.failure
        }

        let extension0 = output.pathExtension.lowercased()
        let bytes: Data
        switch extension0 {
        case "csv", "tsv", "txt":
            var writeOptions = CSVWriteOptions.standard
            writeOptions.normalise = true
            if extension0 == "tsv" { writeOptions.dialect = .tsv }
            bytes = try CSVWriter.data(
                for: sheet, options: writeOptions, sourceDialect: document.workbook.meta.csvDialect
            )
        case "xlsx", "xlsm", "xltx":
            var tracker = WorkbookEditTracker()
            for candidate in document.workbook.sheets { tracker.noteCellsChanged(in: candidate, formulasChanged: true) }
            bytes = try XLSXWriter.data(for: document.workbook, edits: tracker)
        default:
            console.err("cannot write .\(extension0); supported: xlsx, xlsm, xltx, csv, tsv")
            return ExitCode.usage
        }

        // Through the store's atomic writer and the shared suppressor, so a conversion onto a
        // file the app has open does not read as an external change.
        _ = try context.broker.store.suppressor.write(bytes, to: output)
        console.out("wrote \(CellText.count(bytes.count)) bytes to \(output.lastPathComponent) from "
            + "\(input.lastPathComponent) (sheet '\(sheet.name)')")
        return ExitCode.success
    }

    private static func diff(
        _ left: String,
        _ right: String,
        console: ConsoleWriter,
        context: ToolContext
    ) async throws -> Int32 {
        let before = try await context.broker.document(at: left)
        let after = try await context.broker.document(at: right)
        let difference = context.broker.diff(before: before.workbook, after: after.workbook)
        guard !difference.isEmpty else {
            console.out("identical")
            return ExitCode.success
        }
        var lines = [difference.summary]
        if let detail = ResultFormatter.changeDetail(difference, styles: after.workbook.styles, limit: 40) {
            lines.append(detail)
        }
        console.out(UntrustedContent.wrap(lines.joined(separator: "\n"), source: right))
        return ExitCode.success
    }

    private static func grants(store: SheetStore, console: ConsoleWriter, options: Options) -> Int32 {
        let active = store.grants.activeGrants()
        if options.json {
            console.out(JSONValue.object([
                "grants": .array(active.map { .string($0.path) }),
            ]).rendered)
            return ExitCode.success
        }
        guard !active.isEmpty else {
            console.out("No folders are granted.\n\n\(grantRefusal)")
            return ExitCode.success
        }
        console.out("Granted folders:")
        for grant in active { console.out("  \(grant.path)") }
        return ExitCode.success
    }

    private static func listTools(console: ConsoleWriter, options: Options) -> Int32 {
        if options.json {
            console.out(ToolRegistry.standard.listing.rendered)
            return ExitCode.success
        }
        for tool in ToolRegistry.standard.tools {
            let required = tool.schema.properties
                .filter { $0.isRequired }
                .map { $0.name }
                .joined(separator: ", ")
            console.out("\(tool.schema.name)\(tool.schema.isReadOnly ? "" : " (writes)")")
            console.out("  \(tool.schema.title) — required: \(required.isEmpty ? "none" : required)")
        }
        return ExitCode.success
    }

    // MARK: - serve

    private static func serve(configuration: SheetStore.Configuration, console: ConsoleWriter) async -> Int32 {
        // Claim standard output *first*, before anything that could print. From here on, every
        // other writer in the process lands on stderr. See `ProtocolStream`.
        let stream = ProtocolStream.claimStdout()
        let log = MCPLog.fromEnvironment()
        do {
            let store = try SheetStore(mode: .mcpServer, configuration: configuration)
            let broker = DocumentBroker(store: store, log: log)
            let server = MCPServer(
                context: ToolContext(
                    broker: broker,
                    log: log,
                    handshake: AppHandshake(applicationSupport: configuration.applicationSupport)
                ),
                stream: stream,
                log: log
            )
            log.write("opensheets-mcp \(MCPServer.serverVersion) ready; "
                + "\(store.grants.activeGrants().count) granted folders")
            await server.run(readingFrom: STDIN_FILENO)
            await broker.closeAll()
            return ExitCode.success
        } catch {
            // The client is waiting on stdin and will never see stderr as an error, so say it
            // where a human looks and exit non-zero, which the client reports as a failed start.
            console.err("opensheets-mcp could not start: \(error)")
            return ExitCode.failure
        }
    }

    // MARK: - Plumbing

    private struct Options {
        var json = false
        var preview = false
        var formulas = false
        var format = "compact"
        var sheet: String?
        var limit: Int?
    }

    /// Turns a command-line word into a cell value. Numbers stay numbers.
    private static func literal(_ text: String) -> JSONValue {
        if text == "true" || text == "false" { return .bool(text == "true") }
        if let value = Int(text) { return .integer(value) }
        if let value = Double(text), value.isFinite { return .number(value) }
        return .string(text)
    }

    private static func missing(_ form: String, _ console: ConsoleWriter) -> Int32 {
        console.err("usage: opensheets \(form)")
        return ExitCode.usage
    }

    private static func report(_ error: SheetError, console: ConsoleWriter, options: Options) -> Int32 {
        if options.json {
            console.out(JSONValue.object([
                "isError": .bool(true),
                "code": .string(error.code),
                "text": .string(error.message),
            ]).rendered)
        } else {
            console.err(ErrorText.render(error))
        }
        return error.category == .security ? ExitCode.denied : ExitCode.failure
    }

    /// Why neither binary can grant a folder.
    ///
    /// This is the boundary, said out loud. ``SheetStore/UserGrantAuthorization`` can only be
    /// built from an `NSOpenPanel` result on the main actor, and neither of these executables
    /// links AppKit — so *"add a grant from the command line"* is not a feature that was left
    /// out, it is a compile-time impossibility, and that is the property that makes the grant
    /// check worth anything. A CLI that could mint a grant would be a CLI an agent could shell
    /// out to.
    static let grantRefusal = """
    Folder access is granted in the OpenSheets app, and only there:

      1. Open OpenSheets.
      2. File ▸ Grant Folder Access… (or the Workspace section of Settings).
      3. Choose the folder your spreadsheets live in.

    Neither `opensheets` nor `opensheets-mcp` can grant a folder — they do not link AppKit and
    cannot present the panel, which is what stops an agent from granting itself access by
    shelling out to this binary.
    """

    static let usage = """
    opensheets \(MCPServer.serverVersion) — structural spreadsheet editing

    USAGE
      opensheets <command> [options]

    COMMANDS
      describe <file>                Summarise every sheet: used range, header row, column types
      get <file> [range]             Read cells (default: the used range)
      set <file> <ref> <value>       Write one cell
      find <file> <query>            Search values, report cell references
      convert <in> <out>             Rewrite as .xlsx / .csv / .tsv
      diff <a> <b>                   Compare two workbooks
      snapshot <file> [label]        Take a restore point
      snapshots <file>               List restore points
      restore <file> [id]            Put one back (default: the newest)
      grants                         Show which folders this machine has granted
      tools                          Show the MCP tool surface
      serve                          Run as an MCP server on stdin/stdout

    OPTIONS
      --sheet <name>    Act on one sheet
      --range           (positional, e.g. 'Sheet1!A1:D20' or 'A:C')
      --detailed        `get`: one JSON object per cell instead of TSV
      --formulas        `get`: show formulas instead of values
      --limit <n>       Cap rows or matches
      --preview         Report what would change without writing
      --json            Machine-readable output
      --version, --help

    EXIT CODES
      0 ok · 1 failed · 2 bad usage · 3 path not inside a granted folder

    MCP SETUP
      claude mcp add opensheets -- /usr/local/bin/opensheets-mcp
    """
}
