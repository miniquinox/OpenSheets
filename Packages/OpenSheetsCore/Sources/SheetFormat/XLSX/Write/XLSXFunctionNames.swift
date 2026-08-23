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
    ///
    /// The dynamic-array, `LAMBDA`-helper and modern-text names were confirmed the same way as
    /// the original nine: by feeding both spellings to a second implementation (headless
    /// LibreOffice) reading a real `.xlsx` and seeing which one it resolves. Bare `SEQUENCE(`
    /// is `#NAME?` there and `_xlfn.SEQUENCE(` computes, which is exactly the failure this
    /// list exists to prevent in Excel.
    public static let prefixed: Set<String> = [
        "IFS", "SWITCH", "CONCAT", "TEXTJOIN", "XLOOKUP", "MAXIFS", "MINIFS", "STDEV.P", "STDEV.S",
        // Dynamic arrays.
        "FILTER", "SORT", "SORTBY", "UNIQUE", "SEQUENCE", "RANDARRAY", "TOCOL", "TOROW",
        "VSTACK", "HSTACK", "WRAPROWS", "WRAPCOLS", "TAKE", "DROP", "CHOOSECOLS", "CHOOSEROWS",
        "EXPAND",
        // Modern text.
        "TEXTSPLIT", "TEXTBEFORE", "TEXTAFTER",
        // LAMBDA and its helpers.
        "LAMBDA", "LET", "MAP", "REDUCE", "SCAN", "BYROW", "BYCOL", "MAKEARRAY",
    ]

    /// The two names Excel stores with `_xlfn._xlws.` rather than plain `_xlfn.`.
    ///
    /// `_xlws.` marks a function that only exists on a worksheet. Getting this wrong is the
    /// same `#NAME?` one level down: LibreOffice resolves `_xlfn._xlws.FILTER` and rejects
    /// `_xlfn.FILTER`, and rejects `_xlfn._xlws.UNIQUE` while resolving `_xlfn.UNIQUE`.
    public static let worksheetScoped: Set<String> = ["FILTER", "SORT"]

    /// The prefix itself.
    public static let prefix = "_xlfn."

    /// The extra prefix worksheet-scoped functions carry on top of ``prefix``.
    public static let worksheetPrefix = "_xlws."

    /// The stored spelling of one display name.
    public static func storedName(_ name: String) -> String {
        guard prefixed.contains(name.uppercased()), !name.hasPrefix(prefix) else { return name }
        return worksheetScoped.contains(name.uppercased())
            ? prefix + worksheetPrefix + name
            : prefix + name
    }

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
            if characters.first == "(" {
                result += storedName(identifier)
            } else {
                result += identifier
            }
        }
        return result
    }

    /// `formula` with the prefix removed, for display.
    public static func displayForm(_ formula: String) -> String {
        guard formula.contains(prefix) || formula.contains(worksheetPrefix) else { return formula }
        return formula
            .replacingOccurrences(of: prefix + worksheetPrefix, with: "")
            .replacingOccurrences(of: prefix, with: "")
            .replacingOccurrences(of: worksheetPrefix, with: "")
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character.isLetter || character == "_"
    }

    private static func isIdentifierBody(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "."
    }
}
