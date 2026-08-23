import Foundation
import SheetModel

/// How to spell a formula when writing it back out.
public struct FormulaFormat: Sendable, Hashable {
    /// `A1` or `R1C1`.
    public var style: ReferenceStyle
    /// The cell the formula lives in. Only R1C1 uses it, and it is required there.
    public var anchor: CellRef
    /// Whether newer functions get their `_xlfn.` prefix.
    ///
    /// `true` for anything headed into a file, `false` for the formula bar. Writing a bare
    /// `XLOOKUP` into xlsx makes Excel show `#NAME?` (WAVE-1-ADDENDUM §3), and showing
    /// `_xlfn.XLOOKUP` in the formula bar is gibberish to the user. Same tree, two spellings.
    public var usesStoragePrefixes: Bool
    /// `,` for anything the file format will see.
    public var argumentSeparator: Character

    public init(
        style: ReferenceStyle = .a1,
        anchor: CellRef = .origin,
        usesStoragePrefixes: Bool = false,
        argumentSeparator: Character = ","
    ) {
        self.style = style
        self.anchor = anchor
        self.usesStoragePrefixes = usesStoragePrefixes
        self.argumentSeparator = argumentSeparator
    }

    /// What goes in the formula bar: A1, display names.
    public static let display = FormulaFormat()

    /// What goes in `xl/worksheets/sheetN.xml`: A1, `_xlfn.` prefixes.
    public static let storage = FormulaFormat(usesStoragePrefixes: true)

    /// Storage spelling in R1C1, which is what a shared-formula group needs.
    public static func r1c1(anchor: CellRef) -> FormulaFormat {
        FormulaFormat(style: .r1c1, anchor: anchor, usesStoragePrefixes: true)
    }
}

/// Turns a ``FormulaExpression`` back into text.
///
/// Iterative for the same reason the evaluator is: a formula that is one long `1+1+1+…` has a
/// 4,000-deep left spine, and a recursive writer would be 4,000 stack frames deep on input
/// that Excel accepts without complaint.
public enum FormulaWriter {
    private enum Piece {
        case node(FormulaExpression)
        case text(String)
    }

    /// The formula as text, without a leading `=`.
    public static func write(_ expression: FormulaExpression, format: FormulaFormat = .display) -> String {
        var stack: [Piece] = [.node(expression)]
        var result = ""
        while let piece = stack.popLast() {
            switch piece {
            case let .text(text):
                result += text
            case let .node(node):
                let pieces = expand(node, format: format)
                for element in pieces.reversed() { stack.append(element) }
            }
        }
        return result
    }

    private static func expand(_ node: FormulaExpression, format: FormulaFormat) -> [Piece] {
        switch node {
        case let .number(value):
            return [.text(numberLiteral(value))]
        case let .string(value):
            return [.text(stringLiteral(value))]
        case let .boolean(value):
            return [.text(value ? "TRUE" : "FALSE")]
        case let .errorLiteral(value):
            return [.text(value.xlsxToken)]
        case .missing:
            return []
        case let .unsupported(text):
            return [.text(text)]
        case let .reference(reference):
            return [.text(format.style == .r1c1 ? reference.r1c1Text(anchor: format.anchor) : reference.a1Text)]
        case let .name(name):
            return [.text(name.text)]
        case let .group(inner):
            return [.text("("), .node(inner), .text(")")]
        case let .unary(symbol, operand):
            return [.text(symbol.rawValue), .node(operand)]
        case let .percent(operand):
            return [.node(operand), .text("%")]
        case let .binary(symbol, lhs, rhs):
            return [.node(lhs), .text(symbol.rawValue), .node(rhs)]
        case let .rangeOperator(lhs, rhs):
            return [.node(lhs), .text(":"), .node(rhs)]
        case let .intersection(lhs, rhs):
            return [.node(lhs), .text(" "), .node(rhs)]
        case let .union(parts):
            return join(parts.map { Piece.node($0) }, with: String(format.argumentSeparator))
        case let .array(literal):
            return [.text(arrayLiteral(literal))]
        case let .call(call):
            let name = format.usesStoragePrefixes
                ? FunctionNames.storedName(forDisplay: call.name)
                : call.name
            var pieces: [Piece] = [.text(name + "(")]
            pieces += join(call.arguments.map { Piece.node($0) }, with: String(format.argumentSeparator))
            pieces.append(.text(")"))
            return pieces
        }
    }

    private static func join(_ pieces: [Piece], with separator: String) -> [Piece] {
        guard !pieces.isEmpty else { return [] }
        var result: [Piece] = []
        for (index, piece) in pieces.enumerated() {
            if index > 0 { result.append(.text(separator)) }
            result.append(piece)
        }
        return result
    }

    /// A number the way a formula spells it: no separators, no exponent unless it needs one.
    public static func numberLiteral(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return ExcelNumber.generalText(value)
    }

    /// A string literal with `"` doubled, which is the only escape Excel has.
    public static func stringLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func arrayLiteral(_ literal: ArrayLiteral) -> String {
        literal.rows.map { row in
            row.map(constant).joined(separator: ",")
        }.joined(separator: ";").wrappedInBraces
    }

    private static func constant(_ value: ScalarValue) -> String {
        switch value {
        case .blank: ""
        case let .number(number): numberLiteral(number)
        case let .text(text): stringLiteral(text)
        case let .boolean(flag): flag ? "TRUE" : "FALSE"
        case let .error(error): error.xlsxToken
        }
    }
}

private extension String {
    var wrappedInBraces: String { "{" + self + "}" }
}
