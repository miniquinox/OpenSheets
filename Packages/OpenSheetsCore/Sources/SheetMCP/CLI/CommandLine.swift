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
///
/// The two surfaces used to be able to drift apart quietly, and did: twelve commands against
/// twenty tools, with `recalc` reachable only over JSON-RPC. ``CLISurface`` is the single table
/// both `--help` and the tests read, so a tool with no command is now either an entry in
/// ``CLISurface/toolsWithoutACommand`` with a reason, or a failing test.
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
            case "--delete": options.delete = true
            case "--recursive", "-r": options.recursive = true
            case "--no-header": options.hasHeader = false
            case "--header": options.hasHeader = true
            case "--allow-formulas": options.allowFormulas = true
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

    /// Routes one command.
    ///
    /// Split by area rather than kept as one switch because the surface is now the whole tool
    /// list: five smaller routers each stay readable, and `nil` from one simply means "not mine".
    private static func dispatch(
        _ command: String,
        _ arguments: [String],
        options: Options,
        console: ConsoleWriter,
        context: ToolContext,
        store: SheetStore
    ) async throws -> Int32 {
        let routers = [readCommands, writeCommands, structureCommands, snapshotCommands, fileCommands]
        for route in routers {
            if let code = try await route(command, arguments, options, console, context, store) {
                return code
            }
        }
        console.err("unknown command '\(command)'. Try `opensheets help`.")
        return ExitCode.usage
    }

    /// `describe`, `get`, `find`, `filter` — the tools that only look.
    private static func readCommands(
        _ command: String,
        _ arguments: [String],
        options: Options,
        console: ConsoleWriter,
        context: ToolContext,
        store: SheetStore
    ) async throws -> Int32? {
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

        case "find":
            guard arguments.count >= 2 else { return missing("find <file> <query>", console) }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "query": .string(arguments[1]),
            ]
            if let sheet = options.sheet { payload["sheet"] = .string(sheet) }
            if let limit = options.limit { payload["limit"] = .integer(limit) }
            return await invoke("find", arguments: payload, console: console, options: options, context: context)

        case "filter":
            guard arguments.count >= 3 else {
                return missing("filter <file> <column> <op> [value]", console)
            }
            var condition: [String: JSONValue] = [
                "column": .string(arguments[1]),
                "op": .string(arguments[2]),
            ]
            if arguments.count > 3 { condition["value"] = literal(arguments[3]) }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "where": .array([.object(condition)]),
                // `--delete` rather than a positional verb: the destructive reading of this
                // command has to be something you typed on purpose, not something you reached
                // by getting an argument in the wrong order.
                "action": .string(options.delete ? "delete_rows" : "list"),
                "preview": .bool(options.preview),
            ]
            if let limit = options.limit { payload["limit"] = .integer(limit) }
            payload.merge(options.sheetArgument) { _, new in new }
            return await invoke("filter", arguments: payload, console: console, options: options, context: context)
        default: return nil
        }
    }

    /// `set`, `format`, `recalc`, `sort` — the tools that change cells.
    private static func writeCommands(
        _ command: String,
        _ arguments: [String],
        options: Options,
        console: ConsoleWriter,
        context: ToolContext,
        store: SheetStore
    ) async throws -> Int32? {
        switch command {
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

        case "format":
            guard arguments.count >= 3 else {
                return missing("format <file> <range> <key=value>… (e.g. bold=true numberFormat='#,##0.00')", console)
            }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "range": .string(arguments[1]),
                "preview": .bool(options.preview),
            ]
            for pair in arguments.dropFirst(2) {
                guard let separator = pair.firstIndex(of: "=") else {
                    console.err("`\(pair)` is not key=value. Run `opensheets tools` for the keys set_format takes.")
                    return ExitCode.usage
                }
                payload[String(pair[pair.startIndex ..< separator])] = literal(String(pair[pair.index(after: separator)...]))
            }
            payload.merge(options.sheetArgument) { _, new in new }
            return await invoke("set_format", arguments: payload, console: console, options: options, context: context)

        case "recalc":
            guard let path = arguments.first else { return missing("recalc <file>", console) }
            return await invoke(
                "recalc", arguments: ["path": .string(path), "preview": .bool(options.preview)],
                console: console, options: options, context: context
            )

        case "sort":
            guard arguments.count >= 2 else { return missing("sort <file> <column>[:desc] …", console) }
            var keys: [JSONValue] = []
            for key in arguments.dropFirst() {
                let parts = key.split(separator: ":", maxSplits: 1)
                let order = parts.count > 1 ? String(parts[1]) : "asc"
                guard order == "asc" || order == "desc" else {
                    console.err("sort key `\(key)`: the order after `:` must be asc or desc")
                    return ExitCode.usage
                }
                keys.append(.object(["column": .string(String(parts[0])), "order": .string(order)]))
            }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "by": .array(keys),
                "allowFormulas": .bool(options.allowFormulas),
                "preview": .bool(options.preview),
            ]
            if let hasHeader = options.hasHeader { payload["hasHeader"] = .bool(hasHeader) }
            payload.merge(options.sheetArgument) { _, new in new }
            return await invoke("sort", arguments: payload, console: console, options: options, context: context)
        default: return nil
        }
    }

    /// Rows, columns and sheets.
    private static func structureCommands(
        _ command: String,
        _ arguments: [String],
        options: Options,
        console: ConsoleWriter,
        context: ToolContext,
        store: SheetStore
    ) async throws -> Int32? {
        switch command {
        case "insert-rows", "delete-rows":
            let tool = command == "insert-rows" ? "insert_rows" : "delete_rows"
            guard arguments.count >= 2, let at = Int(arguments[1]) else {
                return missing("\(command) <file> <at> [count]", console)
            }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "at": .integer(at),
                "count": .integer(arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1),
                "preview": .bool(options.preview),
            ]
            payload.merge(options.sheetArgument) { _, new in new }
            return await invoke(tool, arguments: payload, console: console, options: options, context: context)

        case "insert-cols", "delete-cols":
            let tool = command == "insert-cols" ? "insert_columns" : "delete_columns"
            guard arguments.count >= 2 else { return missing("\(command) <file> <column> [count]", console) }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "count": .integer(arguments.count > 2 ? Int(arguments[2]) ?? 1 : 1),
                "preview": .bool(options.preview),
            ]
            // A letter is what a person has in front of them; a number is what the tool wants.
            // Both are accepted, and the tool refuses anything that is neither.
            if let number = Int(arguments[1]) {
                payload["at"] = .integer(number)
            } else {
                payload["column"] = .string(arguments[1])
            }
            payload.merge(options.sheetArgument) { _, new in new }
            return await invoke(tool, arguments: payload, console: console, options: options, context: context)

        case "add-sheet":
            guard arguments.count >= 2 else { return missing("add-sheet <file> <name>", console) }
            return await invoke("add_sheet", arguments: [
                "path": .string(arguments[0]),
                "name": .string(arguments[1]),
                "preview": .bool(options.preview),
            ], console: console, options: options, context: context)

        case "rename-sheet":
            guard arguments.count >= 3 else { return missing("rename-sheet <file> <old> <new>", console) }
            return await invoke("rename_sheet", arguments: [
                "path": .string(arguments[0]),
                "sheet": .string(arguments[1]),
                "name": .string(arguments[2]),
                "preview": .bool(options.preview),
            ], console: console, options: options, context: context)

        case "delete-sheet":
            guard arguments.count >= 2 else { return missing("delete-sheet <file> <name>", console) }
            return await invoke("delete_sheet", arguments: [
                "path": .string(arguments[0]),
                "sheet": .string(arguments[1]),
                "preview": .bool(options.preview),
            ], console: console, options: options, context: context)
        default: return nil
        }
    }

    /// Restore points, and the two tools that talk to the running app.
    private static func snapshotCommands(
        _ command: String,
        _ arguments: [String],
        options: Options,
        console: ConsoleWriter,
        context: ToolContext,
        store: SheetStore
    ) async throws -> Int32? {
        switch command {
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

        case "selection":
            guard let path = arguments.first else { return missing("selection <file>", console) }
            return await invoke(
                "get_selection", arguments: ["path": .string(path)],
                console: console, options: options, context: context
            )

        case "reveal":
            guard arguments.count >= 2 else { return missing("reveal <file> <range>", console) }
            var payload: [String: JSONValue] = [
                "path": .string(arguments[0]),
                "range": .string(arguments[1]),
            ]
            payload.merge(options.sheetArgument) { _, new in new }
            return await invoke("reveal_range", arguments: payload, console: console, options: options, context: context)
        default: return nil
        }
    }

    /// Whole-file operations and the grant boundary.
    private static func fileCommands(
        _ command: String,
        _ arguments: [String],
        options: Options,
        console: ConsoleWriter,
        context: ToolContext,
        store: SheetStore
    ) async throws -> Int32? {
        switch command {
        case "workspace":
            // The one command that takes no file: `opensheets workspace` is where somebody who
            // does not know what is granted starts, which is the same place an agent starts.
            var payload: [String: JSONValue] = [:]
            if let folder = arguments.first { payload["path"] = .string(folder) }
            return await invoke(
                "list_workspace", arguments: payload, console: console, options: options, context: context
            )

        case "ls":
            guard let folder = arguments.first else {
                return missing("ls <folder> [--recursive] [--limit N]", console)
            }
            var payload: [String: JSONValue] = [
                "path": .string(folder),
                "recursive": .bool(options.recursive),
            ]
            if let limit = options.limit { payload["limit"] = .integer(limit) }
            return await invoke(
                "list_files", arguments: payload, console: console, options: options, context: context
            )

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
        default: return nil
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
        /// `filter --delete`: run the destructive action instead of listing.
        var delete = false
        /// `ls --recursive`: walk the whole tree instead of one level.
        var recursive = false
        /// `sort`: `nil` means "whatever `describe` would guess", which is the tool's default.
        var hasHeader: Bool?
        var allowFormulas = false

        /// The `sheet` argument every tool takes, when one was given.
        var sheetArgument: [String: JSONValue] {
            sheet.map { ["sheet": JSONValue.string($0)] } ?? [:]
        }
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
      2. Click + in the Files sidebar (or just open a file — its folder is granted with it).
      3. Choose the folder your spreadsheets live in.

    Neither `opensheets` nor `opensheets-mcp` can grant a folder — they do not link AppKit and
    cannot present the panel, which is what stops an agent from granting itself access by
    shelling out to this binary.
    """

    /// Generated from ``CLISurface/commands`` so `--help` cannot list a command the dispatcher
    /// does not have, or miss one it does. See ``CLISurface``.
    static var usage: String {
        """
        opensheets \(MCPServer.serverVersion) — structural spreadsheet editing

        USAGE
          opensheets <command> [options]

        COMMANDS
        \(CLISurface.usageBlock)

        OPTIONS
          --sheet <name>    Act on one sheet
          --range           (positional, e.g. 'Sheet1!A1:D20' or 'A:C')
          --detailed        `get`: one JSON object per cell instead of TSV
          --formulas        `get`: show formulas instead of values
          --limit <n>       Cap rows or matches
          --delete          `filter`: delete the matching rows instead of listing them
          --recursive, -r   `ls`: walk subfolders too
          --header / --no-header
                            `sort`: whether the first row is a header (default: guess)
          --allow-formulas  `sort`: sort a range that holds formulas, translating them
          --preview         Report what would change without writing
          --json            Machine-readable output
          --version, --help

        EXIT CODES
          0 ok · 1 failed · 2 bad usage · 3 path not inside a granted folder

        MCP SETUP
          claude mcp add opensheets -- /usr/local/bin/opensheets-mcp
        """
    }
}
