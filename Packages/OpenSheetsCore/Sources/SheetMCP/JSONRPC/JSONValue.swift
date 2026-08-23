import Foundation
import SheetModel

/// A JSON document as a value type.
///
/// Hand-rolled rather than `JSONSerialization`'s `Any`, for three reasons that all matter on
/// this wire:
///
/// 1. **`Sendable`.** Tool arguments cross an actor boundary on every call. `[String: Any]`
///    does not, and `@unchecked Sendable` over a bag of `NSNumber`s is a lie.
/// 2. **Integers stay integers.** A JSON-RPC `id` that arrives as `3` must go back as `3`, not
///    `3.0` — some clients match on the literal. `NSNumber` erases the distinction.
/// 3. **Deterministic output.** ``rendered`` sorts object keys, so a golden test compares two
///    strings instead of two graphs, and a protocol frame is byte-reproducible.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Accessors

    /// The wrapped string, or `nil` for every other kind. Never coerces: a tool argument that
    /// arrived as a number is a caller mistake worth reporting, not something to stringify.
    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The wrapped integer. A whole `number` counts, because JSON has one numeric type and a
    /// client is free to send `2.0` where the schema says integer.
    public var integerValue: Int? {
        switch self {
        case let .integer(value): value
        case let .number(value) where value.rounded() == value && value.magnitude < 9.007e15: Int(value)
        default: nil
        }
    }

    /// The wrapped number, widening an integer.
    public var doubleValue: Double? {
        switch self {
        case let .integer(value): Double(value)
        case let .number(value): value
        default: nil
        }
    }

    /// The wrapped boolean. Never coerces `0`/`1`.
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The wrapped array.
    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The wrapped object.
    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Whether this is `null`. Distinct from "absent", which is what a `nil` subscript means.
    public var isNull: Bool { self == .null }

    /// A member of an object, or `nil` when this is not an object or the key is absent.
    public subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members[key]
    }

    // MARK: - Rendering

    /// The compact JSON text, with object keys in sorted order.
    ///
    /// Sorted rather than insertion-ordered because a dictionary has no insertion order to
    /// preserve, and "whatever the hasher did today" is not a thing a test can assert against.
    public var rendered: String {
        var output = ""
        render(into: &output)
        return output
    }

    private func render(into output: inout String) {
        switch self {
        case .null:
            output += "null"
        case let .bool(value):
            output += value ? "true" : "false"
        case let .integer(value):
            output += String(value)
        case let .number(value):
            output += JSONValue.render(number: value)
        case let .string(value):
            JSONValue.render(string: value, into: &output)
        case let .array(items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                item.render(into: &output)
            }
            output += "]"
        case let .object(members):
            output += "{"
            for (index, key) in members.keys.sorted().enumerated() {
                if index > 0 { output += "," }
                JSONValue.render(string: key, into: &output)
                output += ":"
                members[key]?.render(into: &output)
            }
            output += "}"
        }
    }

    /// JSON has no way to spell a non-finite number, so one becomes `null` rather than
    /// producing a frame the peer cannot parse. Nothing in this server generates one; a
    /// `#DIV/0!` is a ``CellError``, not a `Double.infinity`.
    private static func render(number value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value.rounded() == value, value.magnitude < 9.007e15 {
            return String(Int(value))
        }
        return String(value)
    }

    /// Escapes to the subset of JSON that survives every transport.
    ///
    /// Control characters below 0x20 are escaped because the spec requires it; **U+2028 and
    /// U+2029 are escaped because they are line terminators in JavaScript**, and an MCP frame
    /// is newline-delimited by a JavaScript client. A cell containing one would otherwise
    /// split a frame in two — spreadsheet content deciding where a protocol message ends is
    /// exactly the class of bug this server is supposed to not have.
    static func render(string value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{2028}", "\u{2029}":
                output += String(format: "\\u%04x", scalar.value)
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }

    // MARK: - Parsing

    /// Parses one JSON document.
    ///
    /// - Throws: ``SheetModel/SheetError/invalidToolArguments(tool:detail:)`` with the tool
    ///   named `json`, so a parse failure carries the same shape as every other failure here.
    public static func parse(_ data: Data) throws(SheetError) -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw SheetError.invalidToolArguments(tool: "json", detail: "\(error)")
        }
    }

    /// See ``parse(_:)``.
    public static func parse(_ text: String) throws(SheetError) -> JSONValue {
        try parse(Data(text.utf8))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral _: ()) { self = .null }
}

extension JSONValue: ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { rendered }
}
