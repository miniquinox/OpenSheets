import SwiftUI

/// A **display-only** formula lexer.
///
/// This is not the formula engine. A3 owns parsing, `_xlfn.` mapping, precedence, and everything
/// that decides what a formula *means*; this decides what colour a run of characters is while the
/// user types it. Two separate jobs with two different failure modes: A3 must be exactly right or
/// the number is wrong, and this must never crash or block the keystroke, on any input, including
/// half-typed nonsense like `=SUM(A1:` .
///
/// So it is a single left-to-right pass, it never throws, and every unrecognised byte becomes
/// ``Token/Kind/plain`` rather than an error. When A3 lands, A8 may pass real diagnostics in
/// through ``FormulaBarState/errorRange`` — this stays as it is.
public enum FormulaSyntax {
    /// One coloured run.
    public struct Token: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable, CaseIterable {
            /// `A1`, `$B$7`, `Sheet1!A1:C9`.
            case reference
            /// A name immediately followed by `(`.
            case function
            /// A double-quoted literal.
            case string
            /// A numeric literal.
            case number
            /// `+ - * / ^ & = < > , : ( )`.
            case oper
            /// `#REF!`, `#DIV/0!`, and the rest.
            case error
            /// A defined name — a bare identifier that is not a function and not a reference.
            case name
            /// Whitespace, and anything we could not classify.
            case plain
        }

        public var kind: Kind
        public var text: String

        public init(kind: Kind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    /// The seven Excel error literals, longest-first so `#DIV/0!` is not truncated at `#D`.
    private static let errorLiterals = [
        "#DIV/0!", "#VALUE!", "#NAME?", "#REF!", "#NULL!", "#NUM!", "#N/A",
    ]

    /// Splits a formula into coloured runs. `text` may or may not include the leading `=`.
    public static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        let scalars = Array(text)
        var index = 0

        func peek(_ offset: Int = 0) -> Character? {
            let target = index + offset
            return target < scalars.count ? scalars[target] : nil
        }

        func append(_ kind: Token.Kind, _ run: String) {
            // Merge adjacent runs of the same kind so the attributed string stays small.
            if var last = tokens.last, last.kind == kind {
                last.text += run
                tokens[tokens.count - 1] = last
            } else {
                tokens.append(Token(kind: kind, text: run))
            }
        }

        while index < scalars.count {
            let char = scalars[index]

            // Errors first: `#` is unambiguous and a prefix of nothing else.
            if char == "#" {
                let remainder = String(scalars[index...])
                if let literal = errorLiterals.first(where: { remainder.hasPrefix($0) }) {
                    append(.error, literal)
                    index += literal.count
                    continue
                }
                append(.error, String(char))
                index += 1
                continue
            }

            // Strings. An unterminated quote runs to the end of the line, which is what the user
            // sees while typing one — colouring it as a string is the honest answer.
            if char == "\"" {
                var run = "\""
                index += 1
                while index < scalars.count {
                    let next = scalars[index]
                    run.append(next)
                    index += 1
                    if next == "\"" {
                        // `""` is an escaped quote inside a string, not the end of it.
                        if peek() == "\"" {
                            run.append("\"")
                            index += 1
                            continue
                        }
                        break
                    }
                }
                append(.string, run)
                continue
            }

            // Sheet-qualified names: `'My Sheet'!A1`. The quoted part belongs to the reference.
            if char == "'" {
                var run = "'"
                index += 1
                while index < scalars.count {
                    let next = scalars[index]
                    run.append(next)
                    index += 1
                    if next == "'" { break }
                }
                if peek() == "!" {
                    run.append("!")
                    index += 1
                    let (identifier, consumed) = readIdentifier(scalars, from: index)
                    run += identifier
                    index += consumed
                    append(.reference, run)
                } else {
                    append(.plain, run)
                }
                continue
            }

            if char.isNumber || (char == "." && (peek(1)?.isNumber ?? false)) {
                var run = ""
                while let next = peek(), next.isNumber || next == "." {
                    run.append(next)
                    index += 1
                }
                // Scientific notation: `1E-3`.
                if let next = peek(), next == "E" || next == "e",
                   let sign = peek(1), sign.isNumber || sign == "-" || sign == "+" {
                    run.append(next)
                    index += 1
                    if let sign = peek(), sign == "-" || sign == "+" {
                        run.append(sign)
                        index += 1
                    }
                    while let digit = peek(), digit.isNumber {
                        run.append(digit)
                        index += 1
                    }
                }
                append(.number, run)
                continue
            }

            if char.isLetter || char == "_" || char == "$" {
                let (identifier, consumed) = readIdentifier(scalars, from: index)
                index += consumed
                // A sheet qualifier keeps going.
                var run = identifier
                if peek() == "!" {
                    run.append("!")
                    index += 1
                    let (tail, tailConsumed) = readIdentifier(scalars, from: index)
                    run += tail
                    index += tailConsumed
                    append(.reference, run)
                    continue
                }
                if peek() == "(" {
                    append(.function, run)
                    continue
                }
                append(isReference(run) ? .reference : .name, run)
                continue
            }

            if "+-*/^&=<>,:()%{}".contains(char) {
                append(.oper, String(char))
                index += 1
                continue
            }

            append(.plain, String(char))
            index += 1
        }

        return tokens
    }

    private static func readIdentifier(_ scalars: [Character], from start: Int) -> (String, Int) {
        var run = ""
        var index = start
        while index < scalars.count {
            let char = scalars[index]
            guard char.isLetter || char.isNumber || char == "_" || char == "$" || char == "." else { break }
            run.append(char)
            index += 1
        }
        return (run, index - start)
    }

    /// `A1`, `$A$1`, `XFD1048576`. Not `SUM`, not `Q4Total`.
    ///
    /// Structural only — it does not check that the row is on the sheet, because a reference that
    /// is out of range is still a reference and should still be coloured as one while you type it.
    static func isReference(_ text: String) -> Bool {
        var index = text.startIndex
        func consume(_ char: Character) -> Bool {
            guard index < text.endIndex, text[index] == char else { return false }
            index = text.index(after: index)
            return true
        }
        _ = consume("$")
        var letters = 0
        while index < text.endIndex, text[index].isLetter {
            letters += 1
            index = text.index(after: index)
        }
        guard letters >= 1, letters <= 3 else { return false }
        _ = consume("$")
        var digits = 0
        while index < text.endIndex, text[index].isNumber {
            digits += 1
            index = text.index(after: index)
        }
        return digits >= 1 && index == text.endIndex
    }

    /// Whether this is source worth colouring — that is, a formula.
    ///
    /// The bar shows whatever the cell holds, and most cells hold prose. Running the lexer over
    /// `Cloud hosting` produces two `name` tokens and underlines both of them, which is a label
    /// that looks like two broken hyperlinks. Excel makes the same distinction: the colours are
    /// for formulas, and a literal is a literal.
    public static func isFormula(_ text: String) -> Bool { text.hasPrefix("=") }

    /// What the bar renders: colour for a formula, plain ink for anything else. See
    /// ``isFormula(_:)``.
    public static func display(_ text: String, context: AppearanceContext) -> AttributedString {
        isFormula(text) ? highlight(text, context: context) : AttributedString(text)
    }

    /// The tokens as an `AttributedString`, ready for a `Text`.
    ///
    /// **Three colours, not seven.** The brief lists six token kinds and the lexer produces all
    /// six, but only references, strings and errors are actually tinted; functions get weight
    /// instead, and numbers and operators stay in the primary and secondary inks. A formula bar
    /// with a six-colour rainbow in it is the loudest object in a "Quiet Glass" app, and the
    /// distinction that matters while you read a formula is *which parts of this point at cells* —
    /// which is one colour, and it is the accent, so it matches the selection rectangle those
    /// references are pointing at.
    public static func highlight(_ text: String, context: AppearanceContext) -> AttributedString {
        var result = AttributedString()
        for token in tokenize(text) {
            var run = AttributedString(token.text)
            switch token.kind {
            case .reference:
                run.foregroundColor = DS.Chrome.accent
            case .function:
                run.foregroundColor = DS.Chrome.primary
                run.font = DS.Text.formula.weight(.semibold)
            case .string:
                run.foregroundColor = DS.Signal.connected(context)
            case .error:
                run.foregroundColor = DS.Signal.errorInk(context)
                run.font = DS.Text.formula.weight(.semibold)
            case .name:
                run.foregroundColor = DS.Chrome.primary
                run.underlineStyle = .single
            case .number, .plain:
                run.foregroundColor = DS.Chrome.primary
            case .oper:
                run.foregroundColor = DS.Chrome.secondary
            }
            result.append(run)
        }
        return result
    }
}
