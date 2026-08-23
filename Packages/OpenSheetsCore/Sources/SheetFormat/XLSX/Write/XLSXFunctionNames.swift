//
//  XLSXFunctionNames.swift
//  SheetFormat
//
//  Newer functions are *stored* under a different name than they are *displayed* under.
//

import Foundation

/// The `_xlfn.` prefix, applied on the way out.
///
/// OOXML stores functions added after the 2007 schema was frozen with an `_xlfn.` prefix:
/// the file says `_xlfn.XLOOKUP`, the formula bar says `XLOOKUP`. Write the bare name and Excel
/// does not recognise it — the cell shows `#NAME?` and the formula is dead. There is no warning
/// and nothing in the file looks wrong.
///
/// The writer applies this unconditionally rather than trusting whoever handed it the formula,
/// because the text can arrive from three places with three different conventions: the reader
/// (stored form), the formula engine's serialiser (display form), and the MCP server (whatever
/// the agent typed). Prefixing an already-prefixed name is a no-op, so running it over stored
/// form costs nothing.
///
/// The list is deliberately short — exactly the functions Wave 1's addendum §3 verified against
/// `Fixtures/formulas/functions.xlsx`. Prefixing a function that is *not* stored that way breaks
/// it just as thoroughly in the other direction, so a name goes on this list only when a real
/// file has been seen to spell it that way.
public enum XLSXFunctionNames {
    /// Functions whose stored name carries the prefix.
    public static let prefixed: Set<String> = [
        "IFS", "SWITCH", "CONCAT", "TEXTJOIN", "XLOOKUP", "MAXIFS", "MINIFS", "STDEV.P", "STDEV.S",
    ]

    /// The prefix itself.
    public static let prefix = "_xlfn."

    /// `formula` with every bare occurrence of a prefixed function rewritten to its stored form.
    ///
    /// Only identifiers immediately followed by `(` are considered, and the scan skips string
    /// literals and single-quoted sheet names — so `="XLOOKUP is great"` and `='XLOOKUP'!A1`
    /// come out untouched, and a user-defined `MYIFS(` is not mistaken for `IFS(`.
    public static func storedForm(_ formula: String) -> String {
        guard formula.contains("(") else { return formula }
        var result = ""
        result.reserveCapacity(formula.count + 16)

        var characters = Substring(formula)
        while let character = characters.first {
            if character == "\"" || character == "'" {
                // A literal or a quoted name: copy through, honouring the doubled-quote escape.
                let quote = character
                result.append(quote)
                characters = characters.dropFirst()
                while let next = characters.first {
                    result.append(next)
                    characters = characters.dropFirst()
                    if next == quote {
                        if characters.first == quote {
                            result.append(quote)
                            characters = characters.dropFirst()
                        } else {
                            break
                        }
                    }
                }
                continue
            }
            guard isIdentifierStart(character) else {
                result.append(character)
                characters = characters.dropFirst()
                continue
            }
            var identifier = ""
            while let next = characters.first, isIdentifierBody(next) {
                identifier.append(next)
                characters = characters.dropFirst()
            }
            if characters.first == "(", prefixed.contains(identifier.uppercased()),
               !identifier.hasPrefix(prefix) {
                result += prefix + identifier
            } else {
                result += identifier
            }
        }
        return result
    }

    /// `formula` with the prefix removed, for display.
    public static func displayForm(_ formula: String) -> String {
        guard formula.contains(prefix) else { return formula }
        return formula.replacingOccurrences(of: prefix, with: "")
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "."
    }
}
