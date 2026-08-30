import Foundation
import SheetModel
import SheetStore

/// One tool result.
///
/// Text, not JSON, and that is a considered choice rather than laziness. The whole point of
/// this server is that an agent can work on a spreadsheet without spending its context on one,
/// and JSON spends roughly 40% more tokens saying the same thing about tabular data — every
/// key repeated on every row, every value quoted. The formats here are line-oriented and
/// documented in `docs/mcp.md`; `read_range` offers `format: "detailed"` for the cases where
/// per-cell structure genuinely earns its cost.
public struct ToolOutput: Sendable, Hashable {
    public var text: String
    /// MCP's `isError`. A tool that refused — a denied path, a range off the sheet — sets this
    /// and explains why in `text`; it is not a protocol-level failure.
    public var isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// What a tool is given.
public struct ToolContext: Sendable {
    public let broker: DocumentBroker
    public let log: MCPLog
    public let handshake: AppHandshake

    /// The store the broker enforces grants through: its database, its grant list, its directory
    /// lister.
    ///
    /// The discovery tools need all three — `list_workspace` reads the app's preferences and the
    /// grant list, `list_files` drives the lister — and none of them is reachable through a
    /// ``DocumentBroker`` alone.
    ///
    /// Computed from the broker rather than stored beside it, deliberately. A second stored `let`
    /// would make it possible to hand a context one store's grant boundary and another store's
    /// database, and this codebase has the rule written down in three other places for the same
    /// reason: *two boundaries can disagree, and the loose one is the one that answers*. Derived,
    /// they cannot.
    public var store: SheetStore { broker.store }

    public init(broker: DocumentBroker, log: MCPLog = MCPLog(destination: .none), handshake: AppHandshake) {
        self.broker = broker
        self.log = log
        self.handshake = handshake
    }
}

/// One invocation.
public struct ToolCall: Sendable {
    public let name: String
    public let arguments: ToolArguments
    public let context: ToolContext

    public init(name: String, arguments: ToolArguments, context: ToolContext) {
        self.name = name
        self.arguments = arguments
        self.context = context
    }

    /// The `preview` flag, uniform across every tool.
    public func isPreview() throws(SheetError) -> Bool {
        try arguments.boolean("preview", default: false)
    }

    /// The broker, for brevity at the call sites.
    public var broker: DocumentBroker { context.broker }
}

/// A tool: its schema and its behaviour, together, so one cannot drift from the other.
public struct ToolDefinition: Sendable {
    public let schema: ToolSchema
    let handler: @Sendable (ToolCall) async throws -> ToolOutput

    public init(
        schema: ToolSchema,
        handler: @escaping @Sendable (ToolCall) async throws -> ToolOutput
    ) {
        self.schema = schema
        self.handler = handler
    }

    /// Runs the tool, after rejecting arguments the schema does not declare.
    ///
    /// The unknown-argument check lives here rather than in each tool for the reason every
    /// cross-cutting check should: a tool added later cannot forget it.
    public func run(_ call: ToolCall) async throws -> ToolOutput {
        try call.arguments.rejectUnknown(schema.properties.map(\.name))
        return try await handler(call)
    }
}

/// Every tool the server exposes.
public struct ToolRegistry: Sendable {
    public let tools: [ToolDefinition]

    public init(tools: [ToolDefinition]) {
        self.tools = tools
    }

    public func definition(named name: String) -> ToolDefinition? {
        tools.first { $0.schema.name == name }
    }

    /// The names, in listing order.
    public var names: [String] { tools.map(\.schema.name) }

    /// The `tools/list` payload.
    public var listing: JSONValue {
        .object(["tools": .array(tools.map(\.schema.listing))])
    }

    /// The full surface, in the order an agent should meet it: find the files, then understand
    /// one, then read, then write, then restructure, then undo.
    ///
    /// Discovery comes first because it is what a session with no prior knowledge needs first:
    /// every other tool takes an absolute path, and until `list_workspace` existed there was no
    /// way to obtain one except to ask the user to paste it.
    public static let standard = ToolRegistry(tools: [
        WorkspaceTools.listWorkspace,
        WorkspaceTools.listFiles,
        DescribeTool.definition,
        ReadRangeTool.definition,
        FindTool.definition,
        FilterTool.definition,
        WriteRangeTool.definition,
        SetFormatTool.definition,
        RecalcTool.definition,
        StructureTools.insertRows,
        StructureTools.deleteRows,
        StructureTools.insertColumns,
        StructureTools.deleteColumns,
        SortTool.definition,
        SheetTools.addSheet,
        SheetTools.renameSheet,
        SheetTools.deleteSheet,
        SnapshotTools.snapshot,
        SnapshotTools.listSnapshots,
        SnapshotTools.restore,
        HandshakeTools.getSelection,
        HandshakeTools.revealRange,
    ])
}
