import Foundation
import SheetModel

/// String handling.
///
/// Positions are 1-based, as they are in Excel, and every one of them is validated: `MID` with
/// a start of `0` is `#VALUE!`, not an off-by-one read of the first character. Counting is by
/// **Swift `Character`** — grapheme clusters — so an emoji is one character. Excel counts
/// UTF-16 code units and reports 2 for the same emoji; ours is the answer a user expects and
/// the divergence is deliberate.
enum TextFunctions {
    static var signatures: [FunctionSignature] { joining + slicing + transforming + searching + conversion }

    // MARK: - Joining

    private static let joining: [FunctionSignature] = [
        FunctionSignature("CONCAT", 1, .max, prefixed: true) { call in
            var result = ""
            for element in try call.allElements(from: 0) {
                if let error = element.value.errorValue { throw FormulaFault.cell(error) }
                result += TextFunctions.plain(element.value)
            }
            return try .text(TextFunctions.checkLength(result))
        },
        FunctionSignature("CONCATENATE", 1, .max) { call in
            var result = ""
            for index in 0 ..< call.count { result += try call.text(index) }
            return try .text(TextFunctions.checkLength(result))
        },
        FunctionSignature("TEXTJOIN", 3, .max, prefixed: true) { call in
            let separator = try call.text(0)
            let skipEmpty = try call.boolean(1, default: true)
            var pieces: [String] = []
            for element in try call.allElements(from: 2) {
                if let error = element.value.errorValue { throw FormulaFault.cell(error) }
                if skipEmpty, case .blank = element.value { continue }
                let piece = TextFunctions.plain(element.value)
                if skipEmpty, piece.isEmpty { continue }
                pieces.append(piece)
            }
            return try .text(TextFunctions.checkLength(pieces.joined(separator: separator)))
        },
        FunctionSignature("REPT", 2, 2) { call in
            let text = try call.text(0)
            let count = try call.integer(1)
            guard count >= 0 else { throw FormulaFault.cell(.wrongType) }
            guard text.count * count <= Limits.maxCellTextLength else { throw FormulaFault.cell(.wrongType) }
            return .text(String(repeating: text, count: count))
        },
    ]

    // MARK: - Slicing

    private static let slicing: [FunctionSignature] = [
        FunctionSignature("LEN", 1, 1) { call in .number(Double(try call.text(0).count)) },
        FunctionSignature("LEFT", 1, 2) { call in
            let text = Array(try call.text(0))
            let count = try call.integer(1, default: 1)
            guard count >= 0 else { throw FormulaFault.cell(.wrongType) }
            return .text(String(text.prefix(count)))
        },
        FunctionSignature("RIGHT", 1, 2) { call in
            let text = Array(try call.text(0))
            let count = try call.integer(1, default: 1)
            guard count >= 0 else { throw FormulaFault.cell(.wrongType) }
            return .text(String(text.suffix(count)))
        },
        FunctionSignature("MID", 3, 3) { call in
            let text = Array(try call.text(0))
            let start = try call.integer(1)
            let count = try call.integer(2)
            guard start >= 1, count >= 0 else { throw FormulaFault.cell(.wrongType) }
            guard start <= text.count else { return .text("") }
            return .text(String(text[(start - 1) ..< min(start - 1 + count, text.count)]))
        },
        FunctionSignature("REPLACE", 4, 4) { call in
            var text = Array(try call.text(0))
            let start = try call.integer(1)
            let count = try call.integer(2)
            let replacement = try call.text(3)
            guard start >= 1, count >= 0 else { throw FormulaFault.cell(.wrongType) }
            let lower = min(start - 1, text.count)
            let upper = min(lower + count, text.count)
            text.replaceSubrange(lower ..< upper, with: Array(replacement))
            return try .text(TextFunctions.checkLength(String(text)))
        },
        FunctionSignature("SUBSTITUTE", 3, 4) { call in
            let text = try call.text(0)
            let target = try call.text(1)
            let replacement = try call.text(2)
            guard !target.isEmpty else { return .text(text) }
            guard call.isPresent(3) else {
                return try .text(TextFunctions.checkLength(
                    text.replacingOccurrences(of: target, with: replacement)
                ))
            }
            let instance = try call.integer(3)
            guard instance >= 1 else { throw FormulaFault.cell(.wrongType) }
            return try .text(TextFunctions.checkLength(
                TextFunctions.substitute(text, target, replacement, instance: instance)
            ))
        },
    ]

    // MARK: - Transforming

    private static let transforming: [FunctionSignature] = [
        FunctionSignature("UPPER", 1, 1) { call in .text(try call.text(0).uppercased()) },
        FunctionSignature("LOWER", 1, 1) { call in .text(try call.text(0).lowercased()) },
        FunctionSignature("PROPER", 1, 1) { call in .text(TextFunctions.proper(try call.text(0))) },
        FunctionSignature("TRIM", 1, 1) { call in .text(TextFunctions.trim(try call.text(0))) },
        FunctionSignature("CLEAN", 1, 1) { call in
            .text(String(try call.text(0).unicodeScalars.filter { $0.value >= 32 }.map(Character.init)))
        },
        FunctionSignature("EXACT", 2, 2) { call in
            .boolean(try call.text(0) == (try call.text(1)))
        },
    ]

    // MARK: - Searching

    private static let searching: [FunctionSignature] = [
        FunctionSignature("FIND", 2, 3) { call in
            let needle = try call.text(0)
            let haystack = Array(try call.text(1))
            let start = try call.integer(2, default: 1)
            guard start >= 1, start <= max(haystack.count, 1) else { throw FormulaFault.cell(.wrongType) }
            guard let index = TextFunctions.locate(Array(needle), in: haystack, from: start - 1, caseSensitive: true)
            else { throw FormulaFault.cell(.wrongType) }
            return .number(Double(index + 1))
        },
        FunctionSignature("SEARCH", 2, 3) { call in
            let pattern = try call.text(0)
            let haystack = Array(try call.text(1))
            let start = try call.integer(2, default: 1)
            guard start >= 1, start <= max(haystack.count, 1) else { throw FormulaFault.cell(.wrongType) }
            guard let index = TextFunctions.search(pattern, in: haystack, from: start - 1)
            else { throw FormulaFault.cell(.wrongType) }
            return .number(Double(index + 1))
        },
    ]

    // MARK: - Conversion

    private static let conversion: [FunctionSignature] = [
        FunctionSignature("VALUE", 1, 1) { call in
            let text = try call.text(0)
            guard let value = Coercion.number(fromText: text, dateSystem: call.scope.options.dateSystem) else {
                throw FormulaFault.cell(.wrongType)
            }
            return .number(value)
        },
        FunctionSignature("NUMBERVALUE", 1, 3) { call in
            var text = try call.text(0)
            let decimal = try call.text(1)
            let group = try call.text(2)
            if !group.isEmpty { text = text.replacingOccurrences(of: group, with: "") }
            if !decimal.isEmpty, decimal != "." { text = text.replacingOccurrences(of: decimal, with: ".") }
            guard let value = Coercion.plainNumber(fromText: text.trimmingCharacters(in: .whitespaces)) else {
                throw FormulaFault.cell(.wrongType)
            }
            return .number(value)
        },
        FunctionSignature("TEXT", 2, 2) { call in
            let format = NumberFormat(try call.text(1))
            return .text(try ExcelTextFormat.render(
                try call.scalar(0), format: format, dateSystem: call.scope.options.dateSystem
            ))
        },
        FunctionSignature("CHAR", 1, 1) { call in
            let code = try call.integer(0)
            guard code >= 1, code <= 255, let scalar = Unicode.Scalar(UInt32(code)) else {
                throw FormulaFault.cell(.wrongType)
            }
            return .text(String(Character(scalar)))
        },
        FunctionSignature("CODE", 1, 1) { call in
            guard let first = try call.text(0).unicodeScalars.first else { throw FormulaFault.cell(.wrongType) }
            return .number(Double(first.value))
        },
        FunctionSignature("UNICHAR", 1, 1) { call in
            let code = try call.integer(0)
            guard code >= 1, code <= 0x10_FFFF, let scalar = Unicode.Scalar(UInt32(code)) else {
                throw FormulaFault.cell(.wrongType)
            }
            return .text(String(Character(scalar)))
        },
        FunctionSignature("UNICODE", 1, 1) { call in
            guard let first = try call.text(0).unicodeScalars.first else { throw FormulaFault.cell(.wrongType) }
            return .number(Double(first.value))
        },
    ]

    // MARK: - Helpers

    /// A value's text form for `CONCAT`-style joining, where an error has already been
    /// filtered out by the caller.
    static func plain(_ value: ScalarValue) -> String {
        switch Coercion.text(value) {
        case let .success(text): text
        case .failure: ""
        }
    }

    static func checkLength(_ text: String) throws -> String {
        guard text.count <= Limits.maxCellTextLength else { throw FormulaFault.cell(.wrongType) }
        return text
    }

    /// Excel's `TRIM`: strip leading and trailing spaces, and collapse internal runs to one.
    /// Only U+0020 — a tab survives, which is why `CLEAN` exists separately.
    static func trim(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        var sawContent = false
        for character in text {
            if character == " " {
                pendingSpace = sawContent
                continue
            }
            if pendingSpace { result.append(" ") }
            pendingSpace = false
            sawContent = true
            result.append(character)
        }
        return result
    }

    /// Excel's `PROPER`: uppercase every letter that does not follow another letter.
    static func proper(_ text: String) -> String {
        var result = ""
        var previousWasLetter = false
        for character in text {
            if character.isLetter {
                result += previousWasLetter ? character.lowercased() : character.uppercased()
                previousWasLetter = true
            } else {
                result.append(character)
                previousWasLetter = false
            }
        }
        return result
    }

    static func substitute(_ text: String, _ target: String, _ replacement: String, instance: Int) -> String {
        let source = Array(text)
        let needle = Array(target)
        var result = ""
        var index = 0
        var seen = 0
        while index < source.count {
            if index + needle.count <= source.count, Array(source[index ..< index + needle.count]) == needle {
                seen += 1
                if seen == instance {
                    result += replacement
                    index += needle.count
                    result += String(source[index...])
                    return result
                }
                result += String(source[index ..< index + needle.count])
                index += needle.count
                continue
            }
            result.append(source[index])
            index += 1
        }
        return result
    }

    static func locate(
        _ needle: [Character], in haystack: [Character], from start: Int, caseSensitive: Bool
    ) -> Int? {
        guard !needle.isEmpty else { return start }
        guard needle.count <= haystack.count else { return nil }
        for index in start ... max(haystack.count - needle.count, start) where index + needle.count <= haystack.count {
            var matched = true
            for offset in 0 ..< needle.count {
                let a = haystack[index + offset]
                let b = needle[offset]
                if caseSensitive ? a != b : a.lowercased() != b.lowercased() {
                    matched = false
                    break
                }
            }
            if matched { return index }
        }
        return nil
    }

    /// `SEARCH` is case-insensitive and understands `?` (any one character), `*` (any run),
    /// and `~` to escape either.
    ///
    /// Always goes through the compiled pattern, even when it holds no wildcards: `SEARCH("~*",…)`
    /// is looking for a literal `*`, and matching the raw two-character text `~*` would find
    /// nothing.
    static func search(_ pattern: String, in haystack: [Character], from start: Int) -> Int? {
        let compiled = WildcardPattern(pattern)
        var index = start
        while index <= haystack.count {
            if compiled.matchesPrefix(of: haystack, from: index) { return index }
            index += 1
        }
        return nil
    }
}
