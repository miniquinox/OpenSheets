import Foundation
import SheetModel

/// Which spelling of references the source text uses.
public enum ReferenceStyle: String, Sendable, Hashable, CaseIterable, Codable {
    /// `A1`, `$B$7`, `Sheet2!A1:B9`.
    case a1
    /// `R1C1`, `R[-1]C`, `R1C1:R3C4`. Needed to expand xlsx shared formulas and offered on the
    /// MCP surface, where an offset is easier for a model to get right than a letter.
    case r1c1
}

/// Turns formula source text into tokens.
///
/// Everything hard about this lexer is references. `Sheet1!$A$1:$B$9` is one atom made of
/// four sub-syntaxes; `'Bob''s Sheet'!A:A` adds quote escaping; `[1]Ext!A1` adds a workbook
/// index. Getting those wrong at the lexical level cannot be fixed later, so the scanner is
/// explicit about each shape rather than reaching for a regular expression that would be
/// unreadable and, for the `LOG10`-versus-`LOG10` case, wrong anyway.
public struct FormulaLexer: Sendable {
    private let characters: [Character]
    private let style: ReferenceStyle
    private let separator: Character
    private var index = 0
    private var pendingWhitespace = false

    /// - Parameters:
    ///   - source: formula text **without** the leading `=`.
    ///   - style: `A1` or `R1C1`.
    ///   - argumentSeparator: `,` everywhere xlsx is involved. A locale that types `;` in the
    ///     formula bar passes `;` here; the file format itself is always `,`.
    public init(_ source: String, style: ReferenceStyle = .a1, argumentSeparator: Character = ",") {
        characters = Array(source)
        self.style = style
        separator = argumentSeparator
    }

    /// Tokenises the whole formula.
    public static func tokenize(
        _ source: String,
        style: ReferenceStyle = .a1,
        argumentSeparator: Character = ","
    ) throws(SheetError) -> [FormulaToken] {
        var lexer = FormulaLexer(source, style: style, argumentSeparator: argumentSeparator)
        return try lexer.run()
    }

    private mutating func run() throws(SheetError) -> [FormulaToken] {
        var tokens: [FormulaToken] = []
        while true {
            skipWhitespace()
            guard index < characters.count else { break }
            let start = index
            guard let kind = try scanToken() else {
                throw SheetError.invalidFormula(
                    text: String(characters),
                    position: start,
                    reason: "unexpected character '\(characters[start])'"
                )
            }
            tokens.append(FormulaToken(kind: kind, position: start, hasLeadingWhitespace: pendingWhitespace))
            pendingWhitespace = false
        }
        return tokens
    }

    // MARK: - Dispatch

    private mutating func scanToken() throws(SheetError) -> FormulaToken.Kind? {
        let character = characters[index]
        switch character {
        case "\"": return try scanString()
        case "#": return scanErrorLiteral()
        case "(": index += 1; return .leftParenthesis
        case ")": index += 1; return .rightParenthesis
        case "{": index += 1; return .leftBrace
        case "}": index += 1; return .rightBrace
        case ":": index += 1; return .colon
        default: break
        }
        if character == separator { index += 1; return .comma }
        if character == ";" { index += 1; return .semicolon }
        if let symbol = scanOperator() { return symbol }
        if character == "$" { return scanReferenceAtom() }
        if character.isNumber { return scanNumberOrRowRange() }
        if character == "'" || character == "[" { return try scanQualifiedReference() }
        if isNameStart(character) { return try scanNameOrReference() }
        return nil
    }

    private mutating func skipWhitespace() {
        while index < characters.count, characters[index].isWhitespace {
            pendingWhitespace = true
            index += 1
        }
    }

    private mutating func scanOperator() -> FormulaToken.Kind? {
        let character = characters[index]
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        switch character {
        case "<":
            if next == ">" { index += 2; return .op(.notEqual) }
            if next == "=" { index += 2; return .op(.lessOrEqual) }
            index += 1
            return .op(.less)
        case ">":
            if next == "=" { index += 2; return .op(.greaterOrEqual) }
            index += 1
            return .op(.greater)
        case "=": index += 1; return .op(.equal)
        case "+": index += 1; return .op(.add)
        case "-": index += 1; return .op(.subtract)
        case "*": index += 1; return .op(.multiply)
        case "/": index += 1; return .op(.divide)
        case "^": index += 1; return .op(.power)
        case "&": index += 1; return .op(.concat)
        case "%": index += 1; return .op(.percent)
        default: return nil
        }
    }

    // MARK: - Literals

    private mutating func scanString() throws(SheetError) -> FormulaToken.Kind {
        let start = index
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                // A doubled quote is one literal quote, not the terminator.
                if index + 1 < characters.count, characters[index + 1] == "\"" {
                    value.append("\"")
                    index += 2
                    continue
                }
                index += 1
                return .string(value)
            }
            value.append(character)
            index += 1
        }
        throw SheetError.invalidFormula(
            text: String(characters), position: start, reason: "unterminated string literal"
        )
    }

    private mutating func scanErrorLiteral() -> FormulaToken.Kind? {
        // Longest first so `#N/A` is not shadowed by a prefix of it.
        let tokens = CellError.allCases
            .filter(\.isExcelNative)
            .map(\.rawValue)
            .sorted { $0.count > $1.count }
        for token in tokens where matches(token) {
            index += token.count
            // `CellError(rawValue:)` cannot fail here — `token` came from `allCases`.
            return .errorLiteral(CellError(rawValue: token) ?? .wrongType)
        }
        // Excel's "still fetching" placeholder is not a `CellError`; treat it as `#N/A`,
        // which is what it becomes once the fetch fails.
        if matches("#GETTING_DATA") {
            index += "#GETTING_DATA".count
            return .errorLiteral(.notAvailable)
        }
        return nil
    }

    private func matches(_ text: String) -> Bool {
        let target = Array(text)
        guard index + target.count <= characters.count else { return false }
        for offset in 0 ..< target.count where characters[index + offset].uppercased() != target[offset].uppercased() {
            return false
        }
        return true
    }

    /// A number, unless the digits turn out to be the start of a whole-row range like `1:1`.
    private mutating func scanNumberOrRowRange() -> FormulaToken.Kind? {
        if style == .a1, let reference = lookaheadRowRange() { return reference }
        var text = ""
        while index < characters.count, characters[index].isNumber {
            text.append(characters[index])
            index += 1
        }
        if index < characters.count, characters[index] == "." {
            text.append(".")
            index += 1
            while index < characters.count, characters[index].isNumber {
                text.append(characters[index])
                index += 1
            }
        }
        if index < characters.count, characters[index] == "e" || characters[index] == "E" {
            var probe = index + 1
            var exponent = "e"
            if probe < characters.count, characters[probe] == "+" || characters[probe] == "-" {
                exponent.append(characters[probe])
                probe += 1
            }
            if probe < characters.count, characters[probe].isNumber {
                while probe < characters.count, characters[probe].isNumber {
                    exponent.append(characters[probe])
                    probe += 1
                }
                text += exponent
                index = probe
            }
        }
        guard let value = Double(text) else { return nil }
        return .number(value)
    }

    /// `1:1`, `12:20` — a whole-row reference, which starts with digits like a number does.
    private mutating func lookaheadRowRange() -> FormulaToken.Kind? {
        var probe = index
        while probe < characters.count, characters[probe].isNumber { probe += 1 }
        guard probe < characters.count, characters[probe] == ":" else { return nil }
        var after = probe + 1
        if after < characters.count, characters[after] == "$" { after += 1 }
        guard after < characters.count, characters[after].isNumber else { return nil }
        while after < characters.count, characters[after].isNumber { after += 1 }
        // `1:1x` is not a reference; the character after must not continue an identifier.
        if after < characters.count, isNameContinuation(characters[after]) { return nil }
        let text = String(characters[index ..< after])
        index = after
        return .reference(text)
    }

    // MARK: - References

    private func isNameStart(_ character: Character) -> Bool {
        character.isLetter || character == "_" || character == "\\"
    }

    private func isNameContinuation(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "." || character == "\\"
            || character == "?"
    }

    /// A reference that begins with `$` or, in R1C1 mode, with `R`/`C`.
    private mutating func scanReferenceAtom() -> FormulaToken.Kind? {
        let start = index
        guard let body = scanReferenceBody() else {
            index = start
            return nil
        }
        return .reference(body)
    }

    /// `'My Sheet'!A1`, `[1]Sheet1!A1`, `[1]!Name`.
    private mutating func scanQualifiedReference() throws(SheetError) -> FormulaToken.Kind {
        let start = index
        var prefix = ""

        if characters[index] == "[" {
            var depth = 0
            while index < characters.count {
                let character = characters[index]
                prefix.append(character)
                index += 1
                if character == "[" { depth += 1 }
                if character == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            guard depth == 0 else {
                throw SheetError.invalidFormula(
                    text: String(characters), position: start, reason: "unterminated workbook reference"
                )
            }
        }

        if index < characters.count, characters[index] == "'" {
            guard let quoted = scanQuotedName() else {
                throw SheetError.invalidFormula(
                    text: String(characters), position: start, reason: "unterminated quoted sheet name"
                )
            }
            prefix += quoted
        } else {
            while index < characters.count, isNameContinuation(characters[index]) {
                prefix.append(characters[index])
                index += 1
            }
        }

        // A sheet span, `Sheet1:Sheet3!A1`.
        if index < characters.count, characters[index] == ":" {
            let mark = index
            var span = ":"
            index += 1
            if index < characters.count, characters[index] == "'" , let quoted = scanQuotedName() {
                span += quoted
            } else {
                while index < characters.count, isNameContinuation(characters[index]) {
                    span.append(characters[index])
                    index += 1
                }
            }
            if index < characters.count, characters[index] == "!" {
                prefix += span
            } else {
                index = mark
            }
        }

        guard index < characters.count, characters[index] == "!" else {
            throw SheetError.invalidFormula(
                text: String(characters), position: start, reason: "expected '!' after a sheet name"
            )
        }
        prefix.append("!")
        index += 1

        // The sheet half is spelled the same in both styles; the address half is not.
        if let body = style == .r1c1 ? scanR1C1Reference() : scanReferenceBody() {
            return .reference(prefix + body)
        }
        var name = ""
        while index < characters.count, isNameContinuation(characters[index]) {
            name.append(characters[index])
            index += 1
        }
        guard !name.isEmpty else {
            throw SheetError.invalidFormula(
                text: String(characters), position: start, reason: "expected a reference after '!'"
            )
        }
        return .name(prefix + name)
    }

    private mutating func scanQuotedName() -> String? {
        guard index < characters.count, characters[index] == "'" else { return nil }
        var text = "'"
        index += 1
        while index < characters.count {
            let character = characters[index]
            if character == "'" {
                if index + 1 < characters.count, characters[index + 1] == "'" {
                    text += "''"
                    index += 2
                    continue
                }
                text.append("'")
                index += 1
                return text
            }
            text.append(character)
            index += 1
        }
        return nil
    }

    /// An identifier, which may turn out to be a function name, a defined name, a cell
    /// address, a sheet-qualified reference, or a structured table reference.
    private mutating func scanNameOrReference() throws(SheetError) -> FormulaToken.Kind {
        if style == .r1c1, let reference = scanR1C1Reference() { return .reference(reference) }

        let start = index
        if style == .a1, let body = scanReferenceBody(), body.contains(":") || body.contains("$") {
            return .reference(body)
        }
        index = start

        var text = ""
        while index < characters.count, isNameContinuation(characters[index]) {
            text.append(characters[index])
            index += 1
        }

        if index < characters.count, characters[index] == "!" || characters[index] == "'" {
            index = start
            return try scanQualifiedReference()
        }
        if index < characters.count, characters[index] == ":" {
            // `Sheet1:Sheet3!A1` — only a sheet span if a `!` follows the second name.
            let mark = index
            index = start
            if case let .reference(body) = try scanQualifiedReference() { return .reference(body) }
            index = mark
        }
        if index < characters.count, characters[index] == "[" {
            var depth = 0
            var table = text
            while index < characters.count {
                let character = characters[index]
                table.append(character)
                index += 1
                if character == "[" { depth += 1 }
                if character == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
            }
            return .structuredReference(table)
        }

        if style == .a1, CellRef(a1: text) != nil { return .nameOrReference(text) }
        return .name(text)
    }

    /// `$A$1`, `A1`, `A:A`, `#REF!`, and the `:`-joined pairs of those.
    private mutating func scanReferenceBody() -> String? {
        let start = index
        guard let first = scanReferencePart() else {
            index = start
            return nil
        }
        guard index < characters.count, characters[index] == ":" else {
            // A lone part must be a full address; `A` on its own is a name, not a reference.
            if first.hasLetters, first.hasDigits { return first.text }
            if first.isErrorMarker { return first.text }
            index = start
            return nil
        }
        let mark = index
        index += 1
        guard let second = scanReferencePart() else {
            index = mark
            if first.hasLetters, first.hasDigits { return first.text }
            index = start
            return nil
        }
        // `A:A` (columns), `1:1` (rows), `A1:B2` (cells) — but not `A:B2`.
        let compatible = (first.hasLetters == second.hasLetters) && (first.hasDigits == second.hasDigits)
        guard compatible || first.isErrorMarker || second.isErrorMarker else {
            index = start
            return nil
        }
        if index < characters.count, isNameContinuation(characters[index]) {
            index = start
            return nil
        }
        return first.text + ":" + second.text
    }

    private struct ReferencePart {
        var text: String
        var hasLetters: Bool
        var hasDigits: Bool
        var isErrorMarker: Bool
    }

    private mutating func scanReferencePart() -> ReferencePart? {
        if matches("#REF!") {
            index += 5
            return ReferencePart(text: "#REF!", hasLetters: true, hasDigits: true, isErrorMarker: true)
        }
        let start = index
        var text = ""
        if index < characters.count, characters[index] == "$" {
            text.append("$")
            index += 1
        }
        var letters = ""
        while index < characters.count, characters[index].isLetter, characters[index].isASCII, letters.count < 4 {
            letters.append(characters[index])
            index += 1
        }
        text += letters
        var dollarRow = false
        if index < characters.count, characters[index] == "$" {
            dollarRow = true
            text.append("$")
            index += 1
        }
        var digits = ""
        while index < characters.count, characters[index].isNumber, digits.count < 8 {
            digits.append(characters[index])
            index += 1
        }
        text += digits

        guard !letters.isEmpty || !digits.isEmpty else {
            index = start
            return nil
        }
        if dollarRow, digits.isEmpty {
            index = start
            return nil
        }
        if !letters.isEmpty, !digits.isEmpty, CellRef.parseA1(text) == nil {
            index = start
            return nil
        }
        if !letters.isEmpty, digits.isEmpty, CellRef.columnIndex(letters: letters) == nil {
            index = start
            return nil
        }
        if letters.isEmpty, !digits.isEmpty, let row = Int(digits), row < 1 || row > Limits.rowCount {
            index = start
            return nil
        }
        return ReferencePart(text: text, hasLetters: !letters.isEmpty, hasDigits: !digits.isEmpty, isErrorMarker: false)
    }

    // MARK: - R1C1

    /// `R`, `C`, `RC`, `R1C1`, `R[-1]C[2]`, and `:`-joined pairs of those.
    private mutating func scanR1C1Reference() -> String? {
        let start = index
        guard let first = scanR1C1Part() else {
            index = start
            return nil
        }
        var text = first
        if index < characters.count, characters[index] == ":" {
            let mark = index
            index += 1
            if let second = scanR1C1Part() {
                text += ":" + second
            } else {
                index = mark
            }
        }
        if index < characters.count, isNameContinuation(characters[index]) {
            index = start
            return nil
        }
        return text
    }

    private mutating func scanR1C1Part() -> String? {
        let start = index
        var text = ""
        var sawAxis = false
        for axis in ["R", "C"] {
            guard index < characters.count, String(characters[index]).uppercased() == axis else { continue }
            text.append(characters[index])
            index += 1
            sawAxis = true
            if index < characters.count, characters[index] == "[" {
                var body = "["
                index += 1
                if index < characters.count, characters[index] == "-" || characters[index] == "+" {
                    body.append(characters[index])
                    index += 1
                }
                var digits = ""
                while index < characters.count, characters[index].isNumber {
                    digits.append(characters[index])
                    index += 1
                }
                guard !digits.isEmpty, index < characters.count, characters[index] == "]" else {
                    index = start
                    return nil
                }
                body += digits + "]"
                index += 1
                text += body
            } else {
                var digits = ""
                while index < characters.count, characters[index].isNumber {
                    digits.append(characters[index])
                    index += 1
                }
                text += digits
            }
        }
        guard sawAxis else {
            index = start
            return nil
        }
        return text
    }
}
