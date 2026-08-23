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
    static var signatures: [FunctionSignature] {
        joining + slicing + transforming + searching + conversion + splitting
    }

    // MARK: - Delimiter-based slicing (Excel 365)

    /// `TEXTBEFORE`, `TEXTAFTER` and `TEXTSPLIT`, which share one delimiter scanner.
    ///
    /// Excel's `instance_num` is 1-based and may be negative to count from the end, and `0` is
    /// `#VALUE!` rather than "the whole string" — the sort of edge every one of these gets
    /// wrong if the scanner is written per function instead of once.
    private static let splitting: [FunctionSignature] = [
        FunctionSignature("TEXTBEFORE", 2, 6, prefixed: true) { call in
            try TextFunctions.around(call, wantsPrefix: true)
        },
        FunctionSignature("TEXTAFTER", 2, 6, prefixed: true) { call in
            try TextFunctions.around(call, wantsPrefix: false)
        },
        FunctionSignature("TEXTSPLIT", 2, 6, prefixed: true) { call in
            let text = try call.text(0)
            let columnDelimiters = try TextFunctions.delimiters(call, at: 1)
            let rowDelimiters = call.isPresent(2) ? try TextFunctions.delimiters(call, at: 2) : []
            let ignoreEmpty = try call.boolean(3, default: false)
            let caseSensitive = try call.integer(4, default: 0) == 0
            let pad: ScalarValue = call.isPresent(5) ? try call.scalar(5) : .error(.notAvailable)

            let lines = rowDelimiters.isEmpty
                ? [text]
                : TextFunctions.split(text, on: rowDelimiters, caseSensitive: caseSensitive)
            var grid: [[ScalarValue]] = []
            for line in lines {
                var fields = columnDelimiters.isEmpty
                    ? [line]
                    : TextFunctions.split(line, on: columnDelimiters, caseSensitive: caseSensitive)
                if ignoreEmpty { fields = fields.filter { !$0.isEmpty } }
                if fields.isEmpty, ignoreEmpty { continue }
                grid.append(fields.map { ScalarValue.text($0) })
            }
            guard !grid.isEmpty else { throw FormulaFault.cell(.calculation) }
            let width = grid.map(\.count).max() ?? 1
            let padded = grid.map { row in
                row + Array(repeating: pad, count: width - row.count)
            }
            return .array(ValueArray(rows: padded))
        },
    ]

    /// The text before or after the nth occurrence of a delimiter.
    private static func around(_ call: FunctionCallSite, wantsPrefix: Bool) throws -> FormulaValue {
        let text = try call.text(0)
        let needles = try delimiters(call, at: 1)
        let instance = try call.integer(2, default: 1)
        // `match_mode` is `0` for case-sensitive and `1` for case-insensitive, and `0` is the
        // default — the opposite polarity to `SEARCH`/`FIND`, and the opposite of what the
        // parameter name suggests. Microsoft documents it this way; getting it backwards is a
        // silent wrong answer on any text with mixed case.
        let caseSensitive = try call.integer(3, default: 0) == 0
        let matchEnd = try call.integer(4, default: 0) == 1
        guard instance != 0 else { throw FormulaFault.cell(.wrongType) }

        let hits = occurrences(of: needles, in: text, caseSensitive: caseSensitive)
        guard !hits.isEmpty else {
            // `match_end` treats the ends of the string as delimiters, which is how
            // `TEXTBEFORE("abc","x",1,0,1)` is `"abc"` rather than `#N/A`.
            if matchEnd { return .text(wantsPrefix ? text : "") }
            if call.isPresent(5) { return call.arguments[5] }
            throw FormulaFault.cell(.notAvailable)
        }
        let wanted = instance > 0 ? instance - 1 : hits.count + instance
        guard wanted >= 0, wanted < hits.count else {
            if matchEnd { return .text(wantsPrefix ? text : "") }
            if call.isPresent(5) { return call.arguments[5] }
            throw FormulaFault.cell(.notAvailable)
        }
        let hit = hits[wanted]
        let characters = Array(text)
        return .text(wantsPrefix
            ? String(characters[0 ..< hit.start])
            : String(characters[(hit.start + hit.length)...]))
    }

    /// The delimiter argument, which is one string or an array of them.
    private static func delimiters(_ call: FunctionCallSite, at index: Int) throws -> [String] {
        let table = try call.table(index)
        var result: [String] = []
        for element in table.values {
            if let error = element.errorValue { throw FormulaFault.cell(error) }
            if case .blank = element { continue }
            switch Coercion.text(element) {
            case let .success(text) where !text.isEmpty: result.append(text)
            case .success: continue
            case let .failure(error): throw FormulaFault.cell(error)
            }
        }
        return result
    }

    /// Every position where any delimiter matches, left to right, non-overlapping.
    ///
    /// Longest match wins at a given position, so `TEXTSPLIT(t, {",", ", "})` splits on the
    /// two-character delimiter rather than leaving a stray space behind.
    private static func occurrences(
        of needles: [String], in text: String, caseSensitive: Bool
    ) -> [(start: Int, length: Int)] {
        let characters = Array(text)
        let candidates = needles.map(Array.init).sorted { $0.count > $1.count }
        var result: [(start: Int, length: Int)] = []
        var index = 0
        while index < characters.count {
            var matched = 0
            for needle in candidates where !needle.isEmpty {
                guard index + needle.count <= characters.count else { continue }
                var same = true
                for offset in 0 ..< needle.count {
                    let a = characters[index + offset]
                    let b = needle[offset]
                    if caseSensitive ? a != b : a.lowercased() != b.lowercased() {
                        same = false
                        break
                    }
                }
                if same { matched = needle.count; break }
            }
            if matched > 0 {
                result.append((index, matched))
                index += matched
            } else {
                index += 1
            }
        }
        return result
    }

    /// Splits on any of `needles`, keeping empty fields.
    static func split(_ text: String, on needles: [String], caseSensitive: Bool) -> [String] {
        let characters = Array(text)
        let hits = occurrences(of: needles, in: text, caseSensitive: caseSensitive)
        guard !hits.isEmpty else { return [text] }
        var fields: [String] = []
        var cursor = 0
        for hit in hits {
            fields.append(String(characters[cursor ..< hit.start]))
            cursor = hit.start + hit.length
        }
        fields.append(String(characters[cursor...]))
        return fields
    }

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
