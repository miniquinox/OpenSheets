import Foundation

/// The `opensheets` command list, and what each command is in terms of the MCP tool surface.
///
/// # Why this is a table and not a help string
///
/// The two front ends drifted. `opensheets --help` listed twelve commands while the server
/// exposed twenty tools, and `recalc` — the one an agent reaches for after writing inputs, and
/// the one a person needs after an agent forgot to — existed only over JSON-RPC. Nothing caught
/// it, because nothing anywhere related the two lists.
///
/// So they are related here, in a value both of them read: ``OpenSheetsCLI/usage`` is generated
/// from ``commands``, the dispatcher's cases are checked against it, and
/// `SheetMCPTests.CLISurfaceTests` asserts that every tool in ``ToolRegistry/standard`` is either
/// a command or is named in ``toolsWithoutACommand`` with a reason. Adding a tool without doing
/// one or the other fails the build's tests, which is the only kind of documentation that stays
/// true.
public enum CLISurface {
    /// One `opensheets` subcommand.
    public struct Command: Sendable, Hashable {
        /// What the user types.
        public let name: String
        /// The MCP tool it runs, or `nil` for the handful of file-level operations that have no
        /// tool because an agent asking for them should be asking for a range instead.
        public let tool: String?
        /// The usage line, e.g. `set <file> <ref> <value>`.
        public let form: String
        /// One line for `--help`.
        public let summary: String

        public init(name: String, tool: String?, form: String, summary: String) {
            self.name = name
            self.tool = tool
            self.form = form
            self.summary = summary
        }
    }

    /// Every command, in the order `--help` lists them: understand, read, write, restructure,
    /// undo, then the things that are about the machine rather than a workbook.
    public static let commands: [Command] = [
        Command(
            name: "workspace", tool: "list_workspace", form: "workspace",
            summary: "Folders in the Files panel, grants, and open tabs"
        ),
        Command(
            name: "ls", tool: "list_files", form: "ls <folder> [--recursive] [--limit N]",
            summary: "List spreadsheet files in a granted folder"
        ),
        Command(
            name: "new", tool: "new_workbook", form: "new <file> [sheet ...]",
            summary: "Create a workbook (never overwrites; sheet names are xlsx-family only)"
        ),
        Command(
            name: "describe", tool: "describe", form: "describe <file>",
            summary: "Summarise every sheet: used range, header row, column types"
        ),
        Command(
            name: "get", tool: "read_range", form: "get <file> [range]",
            summary: "Read cells (default: the used range)"
        ),
        Command(
            name: "find", tool: "find", form: "find <file> <query>",
            summary: "Search values, report cell references"
        ),
        Command(
            name: "filter", tool: "filter", form: "filter <file> <column> <op> [value]",
            summary: "Rows matching a condition; --delete removes them"
        ),
        Command(
            name: "set", tool: "write_range", form: "set <file> <ref> <value>",
            summary: "Write one cell"
        ),
        Command(
            name: "format", tool: "set_format", form: "format <file> <range> <key=value>…",
            summary: "Number format, weight, colour, alignment, width"
        ),
        Command(
            name: "recalc", tool: "recalc", form: "recalc <file>",
            summary: "Recompute every formula and write the results"
        ),
        Command(
            name: "sort", tool: "sort", form: "sort <file> <column>[:desc] …",
            summary: "Sort a range by one or more columns"
        ),
        Command(
            name: "insert-rows", tool: "insert_rows", form: "insert-rows <file> <at> [count]",
            summary: "Insert rows before a 1-based row number"
        ),
        Command(
            name: "delete-rows", tool: "delete_rows", form: "delete-rows <file> <at> [count]",
            summary: "Delete rows from a 1-based row number"
        ),
        Command(
            name: "insert-cols", tool: "insert_columns", form: "insert-cols <file> <column> [count]",
            summary: "Insert columns before a column letter"
        ),
        Command(
            name: "delete-cols", tool: "delete_columns", form: "delete-cols <file> <column> [count]",
            summary: "Delete columns from a column letter"
        ),
        Command(
            name: "add-sheet", tool: "add_sheet", form: "add-sheet <file> <name>",
            summary: "Add a sheet (refused in v0.1; the refusal says what to do instead)"
        ),
        Command(
            name: "rename-sheet", tool: "rename_sheet", form: "rename-sheet <file> <old> <new>",
            summary: "Rename a sheet"
        ),
        Command(
            name: "delete-sheet", tool: "delete_sheet", form: "delete-sheet <file> <name>",
            summary: "Delete a sheet (refused in v0.1; the refusal says what to do instead)"
        ),
        Command(
            name: "snapshot", tool: "snapshot", form: "snapshot <file> [label]",
            summary: "Take a restore point"
        ),
        Command(
            name: "snapshots", tool: "list_snapshots", form: "snapshots <file>",
            summary: "List restore points"
        ),
        Command(
            name: "restore", tool: "restore", form: "restore <file> [id]",
            summary: "Put one back (default: the newest)"
        ),
        Command(
            name: "delete-file", tool: "delete_file", form: "delete-file <file>",
            summary: "Trash a workbook (snapshot first, so restore can undo it)"
        ),
        Command(
            name: "selection", tool: "get_selection", form: "selection <file>",
            summary: "What the OpenSheets app has selected, if it is open on this file"
        ),
        Command(
            name: "reveal", tool: "reveal_range", form: "reveal <file> <range>",
            summary: "Ask the app to scroll to and select a range"
        ),
        Command(
            name: "open", tool: "open_in_app", form: "open <file> [range]",
            summary: "Open the file in the OpenSheets app, launching it if needed"
        ),
        Command(
            name: "convert", tool: nil, form: "convert <in> <out>",
            summary: "Rewrite as .xlsx / .csv / .tsv"
        ),
        Command(
            name: "diff", tool: nil, form: "diff <a> <b>",
            summary: "Compare two workbooks"
        ),
        Command(
            name: "grants", tool: nil, form: "grants",
            summary: "Show which folders this machine has granted"
        ),
        Command(
            name: "grant", tool: nil, form: "grant",
            summary: "Explains why only the app can grant a folder"
        ),
        Command(
            name: "tools", tool: nil, form: "tools",
            summary: "Show the MCP tool surface"
        ),
        Command(
            name: "serve", tool: nil, form: "serve [--read-only]",
            summary: "Run as an MCP server on stdin/stdout; --read-only omits every writing tool"
        ),
        Command(
            name: "help", tool: nil, form: "help",
            summary: "This text"
        ),
        Command(
            name: "version", tool: nil, form: "version",
            summary: "Print the version"
        ),
    ]

    /// Tools deliberately left off the command line, and why.
    ///
    /// Empty, and that is the finding: every tool the server exposes is reachable from a terminal.
    /// The map stays because the next tool may genuinely not belong here, and an explicit entry
    /// with a sentence in it is the difference between a decision and an oversight.
    public static let toolsWithoutACommand: [String: String] = [:]

    /// Command names, for the dispatcher's own audit.
    public static var names: [String] { commands.map(\.name) }

    /// The `COMMANDS` block of `--help`, generated so it cannot fall behind the dispatcher.
    public static var usageBlock: String {
        let width = commands.map(\.form.count).max() ?? 0
        return commands
            .map { "  \($0.form.padding(toLength: max(width, $0.form.count) + 2, withPad: " ", startingAt: 0))\($0.summary)" }
            .joined(separator: "\n")
    }
}
