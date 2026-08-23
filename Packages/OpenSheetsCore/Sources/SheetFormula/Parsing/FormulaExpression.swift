import Foundation
import SheetModel

/// A defined name as it appears in a formula, possibly scoped to a sheet.
public struct NameReference: Hashable, Sendable {
    /// `Sheet1` in `Sheet1!Total`, or `nil` for a bare `Total`.
    public var qualifier: SheetQualifier?
    /// The name, with the author's capitalisation preserved. Resolution is case-insensitive.
    public var name: String

    public init(qualifier: SheetQualifier? = nil, name: String) {
        self.qualifier = qualifier
        self.name = name
    }

    /// The name as written.
    public var text: String { (qualifier?.text ?? "") + name }
}

/// A function call.
public struct FunctionCall: Hashable, Sendable {
    /// The display name, uppercased and with any `_xlfn.` prefix stripped: `XLOOKUP`.
    public var name: String
    /// Whether the source text carried the `_xlfn.` prefix. Round-tripping this matters: a
    /// bare `XLOOKUP` in a file makes Excel show `#NAME?` (WAVE-1-ADDENDUM §3).
    public var wasPrefixed: Bool
    /// Arguments in source order. An omitted argument — the middle of `IF(A1,,0)` — is
    /// ``FormulaExpression/missing``.
    public var arguments: [FormulaExpression]

    public init(name: String, wasPrefixed: Bool = false, arguments: [FormulaExpression]) {
        self.name = name
        self.wasPrefixed = wasPrefixed
        self.arguments = arguments
    }
}

/// A `{1,2;3,4}` literal.
public struct ArrayLiteral: Hashable, Sendable {
    /// Rows of constants.
    public var rows: [[ScalarValue]]

    public init(rows: [[ScalarValue]]) {
        self.rows = rows
    }

    /// The literal as a ``ValueArray``, padding short rows with `#N/A` the way Excel does.
    public var valueArray: ValueArray {
        let columns = rows.map(\.count).max() ?? 0
        var flat: [ScalarValue] = []
        flat.reserveCapacity(rows.count * columns)
        for row in rows {
            flat += row
            flat += Array(repeating: .error(.notAvailable), count: columns - row.count)
        }
        return ValueArray(rowCount: rows.count, columnCount: columns, values: flat)
    }
}

/// A parsed formula.
///
/// Parenthesisation is preserved as its own case rather than being dropped once precedence has
/// been resolved. That is not redundancy: this tree is written back out as the text a user
/// sees, and silently "simplifying" `=(A1+A2)*2` into `=A1+A2*2` would be a wrong answer, while
/// simplifying `=(A1+A2)+A3` into `=A1+A2+A3` would be a diff the user never asked for.
public indirect enum FormulaExpression: Hashable, Sendable {
    /// `42`, `1.5e3`.
    case number(Double)
    /// `"hello"`.
    case string(String)
    /// `TRUE`, `FALSE`.
    case boolean(Bool)
    /// `#DIV/0!` written literally in the formula.
    case errorLiteral(CellError)
    /// `A1`, `$B$7:$D$9`, `Sheet2!A:A`.
    case reference(FormulaReference)
    /// A defined name.
    case name(NameReference)
    /// `SUM(...)`.
    case call(FunctionCall)
    /// Prefix `-` or `+`.
    case unary(FormulaOperator, FormulaExpression)
    /// Postfix `%`.
    case percent(FormulaExpression)
    /// Any infix operator that is not a reference operator.
    case binary(FormulaOperator, FormulaExpression, FormulaExpression)
    /// The `:` operator applied to something the lexer could not fold into one reference, as
    /// in `INDEX(A:A,2):B5`.
    case rangeOperator(FormulaExpression, FormulaExpression)
    /// The space operator: `A1:B5 B1:C5`.
    case intersection(FormulaExpression, FormulaExpression)
    /// The `,` operator inside parentheses: `SUM((A1:A2,C1:C2))`.
    case union([FormulaExpression])
    /// `( … )`, kept so the formula reads back the way it was written.
    case group(FormulaExpression)
    /// `{1,2;3,4}`.
    case array(ArrayLiteral)
    /// An omitted argument.
    case missing
    /// Syntax we can round-trip but not interpret — structured table references today.
    /// A formula containing one is flagged ``CellFlags/unsupportedFormula``.
    case unsupported(String)
}

// MARK: - Structural walking

extension FormulaExpression {
    /// The direct sub-expressions, in evaluation order.
    public var children: [FormulaExpression] {
        switch self {
        case let .call(call): call.arguments
        case let .unary(_, operand): [operand]
        case let .percent(operand): [operand]
        case let .binary(_, lhs, rhs): [lhs, rhs]
        case let .rangeOperator(lhs, rhs): [lhs, rhs]
        case let .intersection(lhs, rhs): [lhs, rhs]
        case let .union(parts): parts
        case let .group(inner): [inner]
        default: []
        }
    }

    /// This node with its children replaced, positionally.
    ///
    /// The pair (``children``, this) is what lets every tree walk in the module — the writer,
    /// ``ReferenceTransform``, dependency extraction — share one explicit-stack traversal
    /// instead of each writing its own recursion and each risking its own stack overflow.
    public func replacingChildren(_ replacements: [FormulaExpression]) -> FormulaExpression {
        switch self {
        case var .call(call):
            call.arguments = replacements
            return .call(call)
        case let .unary(symbol, _):
            return .unary(symbol, replacements.first ?? .missing)
        case .percent:
            return .percent(replacements.first ?? .missing)
        case let .binary(symbol, _, _):
            return .binary(symbol, replacements.first ?? .missing, replacements.count > 1 ? replacements[1] : .missing)
        case .rangeOperator:
            return .rangeOperator(replacements.first ?? .missing, replacements.count > 1 ? replacements[1] : .missing)
        case .intersection:
            return .intersection(replacements.first ?? .missing, replacements.count > 1 ? replacements[1] : .missing)
        case .union:
            return .union(replacements)
        case .group:
            return .group(replacements.first ?? .missing)
        default:
            return self
        }
    }

    /// Rebuilds the tree bottom-up, applying `transform` to every node after its children have
    /// been rebuilt. Iterative, so a formula that is one long `1+1+1+…` cannot overflow.
    public func rebuilding(_ transform: (FormulaExpression) -> FormulaExpression) -> FormulaExpression {
        enum Step {
            case visit(FormulaExpression)
            case assemble(FormulaExpression, Int)
        }
        var work: [Step] = [.visit(self)]
        var finished: [FormulaExpression] = []

        while let step = work.popLast() {
            switch step {
            case let .visit(node):
                let kids = node.children
                if kids.isEmpty {
                    finished.append(transform(node))
                } else {
                    work.append(.assemble(node, kids.count))
                    for child in kids.reversed() { work.append(.visit(child)) }
                }
            case let .assemble(node, count):
                let replacements = Array(finished.suffix(count))
                finished.removeLast(count)
                finished.append(transform(node.replacingChildren(replacements)))
            }
        }
        return finished.first ?? self
    }

    /// Visits every node, parents before children. Iterative.
    public func forEachNode(_ body: (FormulaExpression) -> Void) {
        var stack: [FormulaExpression] = [self]
        while let node = stack.popLast() {
            body(node)
            stack.append(contentsOf: node.children)
        }
    }

    /// Whether any node is something we can round-trip but not evaluate.
    public var containsUnsupportedSyntax: Bool {
        var found = false
        forEachNode { node in
            if case .unsupported = node { found = true }
        }
        return found
    }
}
