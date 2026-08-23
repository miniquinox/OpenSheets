import Foundation

/// Sheet-qualified A1 references — `Sheet1!A1:D20`, `'My Sheet'!B7`.
///
/// The syntax is small but has two rules that are easy to get subtly wrong, and four different
/// places need it: the CLI's range argument, the MCP tool surface, the formula bar's name box,
/// and the diff panel's labels. One implementation beats four.
///
/// 1. **Quoting.** A sheet name needs single quotes when it contains anything other than
///    letters, digits, and underscores, or when it starts with a digit — otherwise `Q4 Data!A1`
///    parses as garbage.
/// 2. **Escaping.** Inside quotes, a literal apostrophe is doubled: `'Bob''s Sheet'!A1`.
///
/// This does **not** parse formulas. `[1]Ext!A1`, `$A$1`, and `A:A` belong to `SheetFormula`'s
/// lexer, which has the context to handle them.
public enum A1Notation {
    /// Splits a possibly sheet-qualified reference into its parts.
    ///
    /// Returns `nil` when the range half does not parse. A missing sheet half is fine and
    /// means "the current sheet".
    public static func parse(_ text: some StringProtocol) -> (sheetName: String?, range: CellRange)? {
        guard let (sheetName, rangeText) = split(text) else { return nil }
        guard let range = CellRange(a1: rangeText) else { return nil }
        return (sheetName, range)
    }

    /// Splits off the sheet name without parsing the range, for callers that want to resolve
    /// the sheet first.
    ///
    /// Returns `nil` only for an unterminated quoted name.
    public static func split(_ text: some StringProtocol) -> (sheetName: String?, rangeText: String)? {
        guard let first = text.first else { return (nil, "") }

        if first == "'" {
            var name = ""
            var index = text.index(after: text.startIndex)
            while index < text.endIndex {
                let character = text[index]
                if character == "'" {
                    let next = text.index(after: index)
                    // A doubled apostrophe is one literal apostrophe, not the closing quote.
                    if next < text.endIndex, text[next] == "'" {
                        name.append("'")
                        index = text.index(after: next)
                        continue
                    }
                    // Closing quote: what follows must be `!` and then the range.
                    guard next < text.endIndex, text[next] == "!" else { return nil }
                    return (name, String(text[text.index(after: next)...]))
                }
                name.append(character)
                index = text.index(after: index)
            }
            return nil
        }

        // An unquoted name runs up to the last `!`, so `Sheet1!A1` works and a stray `!` in a
        // range does not silently swallow the reference.
        guard let separator = text.lastIndex(of: "!") else { return (nil, String(text)) }
        let name = String(text[..<separator])
        guard !name.isEmpty else { return (nil, String(text[text.index(after: separator)...])) }
        return (name, String(text[text.index(after: separator)...]))
    }

    /// Formats a reference, quoting the sheet name only when it needs it.
    public static func format(sheetName: String?, range: CellRange, collapseSingleCell: Bool = true) -> String {
        let rangeText = range.a1String(collapseSingleCell: collapseSingleCell)
        guard let sheetName, !sheetName.isEmpty else { return rangeText }
        return "\(quoteIfNeeded(sheetName))!\(rangeText)"
    }

    /// Formats a single cell. See ``format(sheetName:range:collapseSingleCell:)``.
    public static func format(sheetName: String?, ref: CellRef) -> String {
        format(sheetName: sheetName, range: CellRange(ref))
    }

    /// Wraps a sheet name in quotes when the syntax requires it, doubling any apostrophes.
    public static func quoteIfNeeded(_ name: String) -> String {
        guard needsQuoting(name) else { return name }
        return "'\(name.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// Whether `name` must be quoted to appear in a reference.
    ///
    /// Anything but ASCII letters, digits, and underscores needs quotes — including spaces,
    /// punctuation, and emoji, which PLAN.md §9 promises we handle. A leading digit needs them
    /// too, or the parser reads the name as a row number.
    public static func needsQuoting(_ name: String) -> Bool {
        guard let first = name.first else { return true }
        if first.isNumber { return true }
        return name.contains { character in
            !(character.isLetter && character.isASCII) && !(character.isNumber && character.isASCII) && character != "_"
        }
    }
}
