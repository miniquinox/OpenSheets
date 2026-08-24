import Foundation
import SheetModel

/// One input field of a tool, in the subset of JSON Schema MCP clients actually read.
public struct ToolProperty: Sendable, Hashable {
    /// The JSON types a field may declare.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case string
        case integer
        case number
        case boolean
        case array
        case object
    }

    public var name: String
    public var kind: Kind
    /// One sentence. This is what the agent reads to decide whether to use the field, so it
    /// says what the field *does*, not what type it is.
    public var summary: String
    public var isRequired: Bool
    /// The closed set of values, when there is one.
    public var allowedValues: [String]
    /// Shown in the schema as `default`, and repeated in the summary when it is load-bearing.
    public var defaultValue: JSONValue?
    /// For `array`: what the elements are.
    public var items: JSONValue?

    public init(
        name: String,
        kind: Kind,
        summary: String,
        isRequired: Bool = false,
        allowedValues: [String] = [],
        defaultValue: JSONValue? = nil,
        items: JSONValue? = nil
    ) {
        self.name = name
        self.kind = kind
        self.summary = summary
        self.isRequired = isRequired
        self.allowedValues = allowedValues
        self.defaultValue = defaultValue
        self.items = items
    }

    var schema: JSONValue {
        var members: [String: JSONValue] = [
            "type": .string(kind.rawValue),
            "description": .string(summary),
        ]
        if !allowedValues.isEmpty { members["enum"] = .array(allowedValues.map { .string($0) }) }
        if let defaultValue { members["default"] = defaultValue }
        if let items { members["items"] = items }
        return .object(members)
    }
}

/// Everything `tools/list` says about one tool.
public struct ToolSchema: Sendable, Hashable {
    public var name: String
    /// A human title for a client that shows one.
    public var title: String
    /// The agent-facing description. Long enough to say when *not* to use the tool, because
    /// the expensive mistake is an agent reading 50,000 rows to answer a question `describe`
    /// already answered.
    public var summary: String
    public var properties: [ToolProperty]
    /// MCP's `readOnlyHint`. True for tools that never touch the file.
    public var isReadOnly: Bool
    /// MCP's `destructiveHint`. True for tools that can remove data.
    public var isDestructive: Bool

    public init(
        name: String,
        title: String,
        summary: String,
        properties: [ToolProperty],
        isReadOnly: Bool,
        isDestructive: Bool = false
    ) {
        self.name = name
        self.title = title
        self.summary = summary
        self.properties = properties
        self.isReadOnly = isReadOnly
        self.isDestructive = isDestructive
    }

    /// The `preview` field every writing tool carries.
    ///
    /// A single shared definition so the wording an agent sees is identical on all of them —
    /// an agent learns "preview first" once and it transfers.
    public static let previewProperty = ToolProperty(
        name: "preview",
        kind: .boolean,
        summary: "Dry run. Reports exactly what would change and writes nothing. "
            + "Use it before any destructive edit.",
        defaultValue: .bool(false)
    )

    /// The `path` field every tool carries.
    public static let pathProperty = ToolProperty(
        name: "path",
        kind: .string,
        summary: "Absolute path to the workbook (.xlsx, .xlsm, .xltx, .csv, .tsv). "
            + "Must be inside a folder the user granted in the OpenSheets app.",
        isRequired: true
    )

    /// The `sheet` field, for tools that act on one sheet.
    public static func sheetProperty(required: Bool, summary: String? = nil) -> ToolProperty {
        ToolProperty(
            name: "sheet",
            kind: .string,
            summary: summary ?? "Sheet name. Defaults to the first visible sheet.",
            isRequired: required
        )
    }

    /// The MCP `tools/list` entry.
    public var listing: JSONValue {
        var required: [JSONValue] = []
        var fields: [String: JSONValue] = [:]
        for property in properties {
            fields[property.name] = property.schema
            if property.isRequired { required.append(.string(property.name)) }
        }
        return .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(summary),
            "inputSchema": .object([
                "type": .string("object"),
                "properties": .object(fields),
                "required": .array(required),
                "additionalProperties": .bool(false),
            ]),
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(isReadOnly),
                "destructiveHint": .bool(isDestructive),
                "idempotentHint": .bool(isReadOnly),
                "openWorldHint": .bool(false),
            ]),
        ])
    }
}

/// A tool's arguments, with accessors that fail the way the protocol expects.
///
/// Every getter names the tool in its error, because *"expected an integer for `count`"* with
/// no tool name is the kind of message that costs an agent a whole round trip to locate.
public struct ToolArguments: Sendable {
    public let tool: String
    public let values: [String: JSONValue]

    public init(tool: String, values: [String: JSONValue]) {
        self.tool = tool
        self.values = values
    }

    public init(tool: String, json: JSONValue) {
        self.tool = tool
        values = json.objectValue ?? [:]
    }

    /// Whether a field was supplied at all. A JSON `null` counts as absent, because that is
    /// what a client that serialises optionals sends.
    public func has(_ name: String) -> Bool {
        guard let value = values[name] else { return false }
        return !value.isNull
    }

    public func string(_ name: String) throws(SheetError) -> String {
        guard let value = values[name], !value.isNull else { throw missing(name) }
        guard let text = value.stringValue else { throw wrongType(name, "a string") }
        return text
    }

    public func string(_ name: String, default fallback: String) -> String {
        values[name]?.stringValue ?? fallback
    }

    public func optionalString(_ name: String) -> String? {
        guard let value = values[name], !value.isNull else { return nil }
        return value.stringValue
    }

    public func integer(_ name: String) throws(SheetError) -> Int {
        guard let value = values[name], !value.isNull else { throw missing(name) }
        guard let number = value.integerValue else { throw wrongType(name, "an integer") }
        return number
    }

    public func integer(_ name: String, default fallback: Int) throws(SheetError) -> Int {
        guard let value = values[name], !value.isNull else { return fallback }
        guard let number = value.integerValue else { throw wrongType(name, "an integer") }
        return number
    }

    /// An integer argument that must fall inside a range, rejected with a typed error when it does
    /// not.
    ///
    /// **Use this for every paging or count argument.** The unbounded ``integer(_:default:)`` reads
    /// whatever the caller sent, and Swift's collection operations *trap* on a negative count
    /// rather than throwing — `Collection.prefix(-1)` is a precondition failure, not an error. A
    /// trap cannot be caught, so a single bad argument took the whole MCP server down mid-session
    /// instead of returning `tool.invalidArguments`. The caller here is a language model choosing
    /// arguments, so out-of-range values are an ordinary occurrence rather than an attack.
    public func integer(
        _ name: String,
        default fallback: Int,
        atLeast minimum: Int,
        atMost maximum: Int = .max
    ) throws(SheetError) -> Int {
        let number = try integer(name, default: fallback)
        guard number >= minimum, number <= maximum else {
            let bound = maximum == .max
                ? "at least \(minimum)"
                : "between \(minimum) and \(maximum)"
            throw SheetError.invalidToolArguments(
                tool: tool,
                detail: "`\(name)` must be \(bound) — got \(number)"
            )
        }
        return number
    }

    public func boolean(_ name: String, default fallback: Bool) throws(SheetError) -> Bool {
        guard let value = values[name], !value.isNull else { return fallback }
        guard let flag = value.boolValue else { throw wrongType(name, "true or false") }
        return flag
    }

    public func array(_ name: String) throws(SheetError) -> [JSONValue] {
        guard let value = values[name], !value.isNull else { throw missing(name) }
        guard let items = value.arrayValue else { throw wrongType(name, "an array") }
        return items
    }

    public func optionalArray(_ name: String) throws(SheetError) -> [JSONValue]? {
        guard let value = values[name], !value.isNull else { return nil }
        guard let items = value.arrayValue else { throw wrongType(name, "an array") }
        return items
    }

    /// A field restricted to a closed set. Reports the allowed values, so a wrong one costs
    /// one round trip rather than a guess.
    public func choice(_ name: String, allowed: [String], default fallback: String) throws(SheetError) -> String {
        guard let value = values[name], !value.isNull else { return fallback }
        guard let text = value.stringValue else { throw wrongType(name, "a string") }
        guard allowed.contains(text) else {
            throw SheetError.invalidToolArguments(
                tool: tool,
                detail: "`\(name)` must be one of \(allowed.joined(separator: ", ")); got '\(text)'"
            )
        }
        return text
    }

    /// Rejects fields the schema does not declare.
    ///
    /// `additionalProperties: false` is advisory — a client is free to ignore it — so the
    /// server enforces it. A typo'd argument that is silently dropped produces a tool call
    /// that succeeds and does the wrong thing, which is worse than an error.
    public func rejectUnknown(_ known: [String]) throws(SheetError) {
        let allowed = Set(known)
        let unexpected = values.keys.filter { !allowed.contains($0) }.sorted()
        guard unexpected.isEmpty else {
            throw SheetError.invalidToolArguments(
                tool: tool,
                detail: "unknown argument\(unexpected.count == 1 ? "" : "s") "
                    + unexpected.map { "`\($0)`" }.joined(separator: ", ")
                    + "; this tool takes \(allowed.sorted().map { "`\($0)`" }.joined(separator: ", "))"
            )
        }
    }

    private func missing(_ name: String) -> SheetError {
        SheetError.invalidToolArguments(tool: tool, detail: "`\(name)` is required")
    }

    private func wrongType(_ name: String, _ expected: String) -> SheetError {
        SheetError.invalidToolArguments(tool: tool, detail: "`\(name)` must be \(expected)")
    }
}
