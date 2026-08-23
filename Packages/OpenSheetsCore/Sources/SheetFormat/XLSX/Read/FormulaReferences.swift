//
//  FormulaReferences.swift
//  SheetFormat
//
//  A1 owns this file. Shared-formula expansion and external-link detection — the two things the
//  reader has to understand about formula *text* without owning a parser.
//

import Foundation

import SheetModel

/// Reference arithmetic over raw formula text.
///
/// This is deliberately **not** a formula parser — that is A3's job in `SheetFormula`. It is a
/// scanner that knows just enough to find A1-shaped references outside string literals, which is
/// all shared-formula expansion and external-link flagging need. Keeping it here means the reader
/// does not depend on the formula engine, and the engine does not have to be correct before a
/// workbook can be opened.
public enum FormulaReferences {
    // MARK: - Shared formulas

    /// Rewrites `formula` as if it had been copied from `anchor` to `destination`.
    ///
    /// `<f t="shared" ref="B1:B8" si="0">A1*2</f>` is stored once and left empty in the seven
    /// followers, so `B3` has no formula text at all until it is derived from `B1`'s. Relative
    /// references move with the copy and `$`-anchored ones do not; a reader that just copies the
    /// master's text gives every row `A1*2` and shows eight identical wrong answers.
    ///
    /// A reference that moves off the sheet becomes `#REF!`, which is what Excel stores.
    public static func translate(
        _ formula: String,
        from anchor: CellRef,
        to destination: CellRef
    ) -> String {
        guard anchor != destination else { return formula }
        let deltaRow = destination.row - anchor.row
        let deltaColumn = destination.column - anchor.column

        let source = Array(formula.utf8)
        var output = [UInt8]()
        output.reserveCapacity(source.count + 8)
        var index = 0

        while index < source.count {
            let byte = source[index]

            // String literals and quoted sheet names are copied verbatim: `"A1"` is text, not a
            // reference, and `'My Sheet'!A1` names a tab that does not move.
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                let end = endOfQuoted(source, from: index, quote: byte)
                output.append(contentsOf: source[index ..< end])
                index = end
                continue
            }
            // `[1]` and `[Book.xlsx]` are workbook prefixes; `Table1[Column]` is a structured
            // reference. Neither contains anything that shifts.
            if byte == UInt8(ascii: "[") {
                let end = endOfBracketed(source, from: index)
                output.append(contentsOf: source[index ..< end])
                index = end
                continue
            }

            if let token = matchReference(source, at: index), !isIdentifierByte(previous(source, index)) {
                let movedRow = token.absoluteRow ? token.ref.row : token.ref.row + deltaRow
                let movedColumn = token.absoluteColumn ? token.ref.column : token.ref.column + deltaColumn
                if Limits.isValidRow(movedRow), Limits.isValidColumn(movedColumn) {
                    let moved = CellRef(row: movedRow, column: movedColumn)
                    output.append(
                        contentsOf: Array(
                            moved.a1String(
                                absoluteColumn: token.absoluteColumn, absoluteRow: token.absoluteRow
                            ).utf8
                        )
                    )
                } else {
                    output.append(contentsOf: Array(CellError.invalidReference.rawValue.utf8))
                }
                index = token.end
                continue
            }

            output.append(byte)
            index += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: - External links

    /// Whether `formula` reaches into another workbook.
    ///
    /// The shapes that count are `[1]Sheet1!A1` and `'[1]Sheet1'!A1` — a bracketed workbook
    /// index or filename at the *start* of a reference. `Table1[Amount]` is a structured
    /// reference to a table in this workbook and is emphatically not one; treating it as one puts
    /// a "this file reaches outside" warning on a perfectly local formula.
    ///
    /// Detection only. Nothing is ever resolved or fetched (PLAN.md §7.3).
    public static func referencesExternalWorkbook(_ formula: String) -> Bool {
        let source = Array(formula.utf8)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == UInt8(ascii: "\"") {
                index = endOfQuoted(source, from: index, quote: byte)
                continue
            }
            if byte == UInt8(ascii: "'") {
                // `'[1]Sheet1'!A1` — the bracket hides inside the quoted sheet name.
                if index + 1 < source.count, source[index + 1] == UInt8(ascii: "[") { return true }
                index = endOfQuoted(source, from: index, quote: byte)
                continue
            }
            if byte == UInt8(ascii: "[") {
                // `Table1[[#Headers],[Amount]]` is one structured reference to a table in *this*
                // workbook. Stepping one byte at a time would reach its inner `[`, find a `[`
                // before it rather than an identifier, and call a local formula external.
                if isIdentifierByte(previous(source, index)) || previous(source, index) == UInt8(ascii: "]") {
                    index = endOfBracketed(source, from: index)
                    continue
                }
                return true
            }
            index += 1
        }
        return false
    }

    // MARK: - Scanning

    struct ReferenceToken {
        var ref: CellRef
        var absoluteColumn: Bool
        var absoluteRow: Bool
        var end: Int
    }

    /// Matches `$?[A-Za-z]{1,3}$?[0-9]{1,7}` at `index`, when it really is a reference.
    ///
    /// The two rejections that matter: `LOG10(` would otherwise read as column `LOG` row `10`,
    /// and `A1B2` would read as `A1` followed by junk. Both are caught by requiring the character
    /// after the token to end an identifier.
    static func matchReference(_ source: [UInt8], at index: Int) -> ReferenceToken? {
        var scan = index
        var absoluteColumn = false
        if scan < source.count, source[scan] == UInt8(ascii: "$") {
            absoluteColumn = true
            scan += 1
        }
        var column = 0
        var letters = 0
        while scan < source.count, isLetter(source[scan]) {
            column = column * 26 + Int(source[scan] | 0x20) - 96
            letters += 1
            scan += 1
            if letters > 3 { return nil }
        }
        guard letters > 0 else { return nil }

        var absoluteRow = false
        if scan < source.count, source[scan] == UInt8(ascii: "$") {
            absoluteRow = true
            scan += 1
        }
        var row = 0
        var digits = 0
        while scan < source.count, isDigit(source[scan]) {
            row = row * 10 + Int(source[scan] - UInt8(ascii: "0"))
            digits += 1
            scan += 1
            if digits > 7 { return nil }
        }
        guard digits > 0, row >= 1 else { return nil }
        guard column <= Limits.columnCount, row <= Limits.rowCount else { return nil }

        // `LOG10(` is a function call, and `A1_b` is part of a name.
        if scan < source.count {
            let next = source[scan]
            if next == UInt8(ascii: "(") || isIdentifierByte(next) { return nil }
        }
        return ReferenceToken(
            ref: CellRef(row: row - 1, column: column - 1),
            absoluteColumn: absoluteColumn,
            absoluteRow: absoluteRow,
            end: scan
        )
    }

    private static func endOfQuoted(_ source: [UInt8], from start: Int, quote: UInt8) -> Int {
        var scan = start + 1
        while scan < source.count {
            if source[scan] == quote {
                // A doubled quote is an escaped one and does not close the literal.
                if scan + 1 < source.count, source[scan + 1] == quote {
                    scan += 2
                    continue
                }
                return scan + 1
            }
            scan += 1
        }
        return source.count
    }

    private static func endOfBracketed(_ source: [UInt8], from start: Int) -> Int {
        var scan = start + 1
        var depth = 1
        while scan < source.count {
            if source[scan] == UInt8(ascii: "[") { depth += 1 }
            if source[scan] == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return scan + 1 }
            }
            scan += 1
        }
        return source.count
    }

    private static func previous(_ source: [UInt8], _ index: Int) -> UInt8 {
        index > 0 ? source[index - 1] : 0
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        let lower = byte | 0x20
        return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isIdentifierByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "\\") || byte >= 0x80
    }
}
