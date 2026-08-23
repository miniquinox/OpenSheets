import Foundation
import SheetModel

/// One lexical atom of a formula.
///
/// Two things here are unusual and both are forced by Excel's grammar.
///
/// **`nameOrReference`.** `LOG10` is a function name *and* a valid cell address (column 8509,
/// row 10). Nothing at the lexical level can tell them apart; only the parser, seeing whether
/// a `(` follows, can. So the lexer refuses to guess and hands both possibilities up.
///
/// **`hasLeadingWhitespace`.** A space between two references is the intersection operator, so
/// whitespace is not skippable. Rather than emit whitespace tokens that every parser rule
/// would have to step over, each token records whether one preceded it.
public struct FormulaToken: Sendable, Hashable {
    /// What kind of atom this is.
    public enum Kind: Sendable, Hashable {
        /// A numeric literal, already parsed.
        case number(Double)
        /// A string literal with `""` escapes already resolved.
        case string(String)
        /// An error literal such as `#DIV/0!`.
        case errorLiteral(CellError)
        /// An identifier that cannot be a cell address: `SUM`, `_xlfn.XLOOKUP`, `Total`.
        case name(String)
        /// An identifier that could be either a function/defined name or a cell address.
        /// The parser decides on the next token.
        case nameOrReference(String)
        /// Text that can only be a reference: it carries `$`, `!`, or a `:`.
        case reference(String)
        /// A structured table reference, `Table1[#Data]`. Captured whole and never
        /// interpreted — see ``FormulaExpression/unsupported(_:)``.
        case structuredReference(String)
        /// `(`
        case leftParenthesis
        /// `)`
        case rightParenthesis
        /// `{`
        case leftBrace
        /// `}`
        case rightBrace
        /// `,` — argument separator *and* the reference-union operator.
        case comma
        /// `;` — array row separator, and the argument separator in some locales.
        case semicolon
        /// `:` appearing where the lexer could not fold it into a reference.
        case colon
        /// One of the infix or prefix operators.
        case op(FormulaOperator)
    }

    /// The atom.
    public var kind: Kind
    /// UTF-8 offset of the atom's first byte in the source text, for error messages.
    public var position: Int
    /// Whether at least one space, tab, or newline preceded this atom. Load-bearing: it is how
    /// the intersection operator is spelled.
    public var hasLeadingWhitespace: Bool

    public init(kind: Kind, position: Int, hasLeadingWhitespace: Bool = false) {
        self.kind = kind
        self.position = position
        self.hasLeadingWhitespace = hasLeadingWhitespace
    }
}

/// Every operator Excel's expression grammar has, prefix and infix alike.
public enum FormulaOperator: String, Sendable, Hashable, CaseIterable {
    /// Addition, and unary plus.
    case add = "+"
    /// Subtraction, and unary negation.
    case subtract = "-"
    case multiply = "*"
    case divide = "/"
    case power = "^"
    /// String concatenation.
    case concat = "&"
    case equal = "="
    case notEqual = "<>"
    case less = "<"
    case greater = ">"
    case lessOrEqual = "<="
    case greaterOrEqual = ">="
    /// Postfix `%`, which divides by 100.
    case percent = "%"

    /// Whether this operator can appear between two operands.
    public var isInfix: Bool { self != .percent }

    /// Whether this operator can appear before an operand.
    public var isPrefix: Bool { self == .add || self == .subtract }
}
