import Foundation
import SheetModel

/// Excel's three wildcards: `?` for one character, `*` for any run, `~` to escape either.
///
/// Matching is case-insensitive, like every other text comparison in a spreadsheet. The
/// matcher is an iterative backtracker rather than a regex: `*` is the only construct that can
/// backtrack, so one saved position is enough, and it means no dependency on
/// `NSRegularExpression` and no chance of a pattern from a cell becoming a catastrophic
/// backtrack.
struct WildcardPattern {
    private enum Atom: Equatable {
        case literal(Character)
        case any
        case run
    }

    private let atoms: [Atom]
    /// Whether the pattern actually uses `?` or `*`.
    let hasWildcards: Bool

    init(_ pattern: String) {
        var atoms: [Atom] = []
        var wild = false
        var escaping = false
        for character in pattern {
            if escaping {
                atoms.append(.literal(character))
                escaping = false
                continue
            }
            switch character {
            case "~": escaping = true
            case "?": atoms.append(.any); wild = true
            case "*": atoms.append(.run); wild = true
            default: atoms.append(.literal(character))
            }
        }
        if escaping { atoms.append(.literal("~")) }
        self.atoms = atoms
        hasWildcards = wild
    }

    /// Whether the whole of `text` matches.
    func matches(_ text: String) -> Bool {
        match(Array(text), from: 0, anchoredAtEnd: true) != nil
    }

    /// Whether the pattern matches some prefix of `haystack` starting at `start`.
    func matchesPrefix(of haystack: [Character], from start: Int) -> Bool {
        match(haystack, from: start, anchoredAtEnd: false) != nil
    }

    /// Case folding done per character rather than by lowercasing the whole string, because
    /// lowercasing can change a string's length (`İ` becomes two scalars) and every index we
    /// return has to point back into the caller's array.
    private static func sameLetter(_ lhs: Character, _ rhs: Character) -> Bool {
        lhs == rhs || String(lhs).lowercased() == String(rhs).lowercased()
    }

    private func match(_ input: [Character], from start: Int, anchoredAtEnd: Bool) -> Int? {
        var inputIndex = start
        var atomIndex = 0
        var starAtom = -1
        var starInput = start

        while inputIndex < input.count {
            if atomIndex < atoms.count {
                switch atoms[atomIndex] {
                case let .literal(character):
                    if WildcardPattern.sameLetter(character, input[inputIndex]) {
                        atomIndex += 1
                        inputIndex += 1
                        continue
                    }
                case .any:
                    atomIndex += 1
                    inputIndex += 1
                    continue
                case .run:
                    starAtom = atomIndex
                    starInput = inputIndex
                    atomIndex += 1
                    continue
                }
            } else if !anchoredAtEnd {
                return inputIndex
            }
            guard starAtom >= 0 else { return nil }
            atomIndex = starAtom + 1
            starInput += 1
            inputIndex = starInput
        }
        while atomIndex < atoms.count, atoms[atomIndex] == .run { atomIndex += 1 }
        return atomIndex == atoms.count ? inputIndex : nil
    }
}

/// One `COUNTIF`/`SUMIF`-style condition.
///
/// The spelling is a small language of its own: `">10"`, `"<>"`, `"apple"`, `"*ple"`, `">="&A1`.
/// Two details are easy to miss and both are here — a bare text criterion matches
/// **case-insensitively and with wildcards**, and `"<>"` alone means "not blank" rather than
/// "not equal to the empty string".
struct Criterion {
    private enum Test {
        case compare(FormulaOperator, ScalarValue)
        case wildcard(WildcardPattern, negated: Bool)
        case notBlank
        case blank
    }

    private let test: Test

    init(_ value: ScalarValue, dateSystem: DateSystem) {
        guard case let .text(raw) = value else {
            test = .compare(.equal, value)
            return
        }
        var body = Substring(raw)
        var symbol = FormulaOperator.equal
        for candidate in ["<>", "<=", ">=", "<", ">", "="] where body.hasPrefix(candidate) {
            symbol = FormulaOperator(rawValue: candidate) ?? .equal
            body = body.dropFirst(candidate.count)
            break
        }
        if body.isEmpty {
            test = symbol == .notEqual ? .notBlank : .blank
            return
        }
        let text = String(body)
        if symbol == .equal || symbol == .notEqual {
            let pattern = WildcardPattern(text)
            if pattern.hasWildcards {
                test = .wildcard(pattern, negated: symbol == .notEqual)
                return
            }
        }
        if let number = Coercion.number(fromText: text, dateSystem: dateSystem) {
            test = .compare(symbol, .number(number))
            return
        }
        if text.uppercased() == "TRUE" || text.uppercased() == "FALSE" {
            test = .compare(symbol, .boolean(text.uppercased() == "TRUE"))
            return
        }
        test = .compare(symbol, .text(text))
    }

    /// Whether a cell's value satisfies this condition.
    func matches(_ candidate: ScalarValue) -> Bool {
        switch test {
        case .blank:
            if case .blank = candidate { return true }
            if case let .text(text) = candidate { return text.isEmpty }
            return false
        case .notBlank:
            if case .blank = candidate { return false }
            return true
        case let .wildcard(pattern, negated):
            guard case let .text(text) = candidate else { return negated }
            return pattern.matches(text) != negated
        case let .compare(symbol, expected):
            // A blank cell never satisfies an inequality; Excel skips it rather than treating
            // it as zero, which is why `COUNTIF(A:A,">0")` does not count a million blanks.
            if case .blank = candidate, symbol != .equal, symbol != .notEqual { return false }
            if case .blank = candidate, case .blank = expected { return symbol == .equal }
            switch Coercion.compare(candidate, expected) {
            case let .success(order):
                switch symbol {
                case .equal: return order == 0
                case .notEqual: return order != 0
                case .less: return order < 0
                case .lessOrEqual: return order <= 0
                case .greater: return order > 0
                case .greaterOrEqual: return order >= 0
                default: return false
                }
            case .failure:
                return false
            }
        }
    }
}
