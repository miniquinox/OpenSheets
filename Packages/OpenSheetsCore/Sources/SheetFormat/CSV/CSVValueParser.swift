//
//  CSVValueParser.swift
//  SheetFormat
//
//  A CSV field is a string. A cell is not. This is where the guessing happens, on purpose.
//

import Foundation
import SheetModel

/// Turns one field of delimited text into a ``Cell``.
///
/// # Why `=SUM(A1)` does not become a formula
///
/// PLAN.md §7.3: a cell is data, never an instruction. A CSV is the most common way for
/// attacker-controlled text to reach a spreadsheet, and `Fixtures/csv/formula-injection.csv`
/// exists to pin the behaviour — `=cmd|' /C calc'!A0` imports as the eight characters it is.
/// Excel's own default is the opposite and it is a known, exploited problem.
///
/// # Why `#N/A` *does* become an error
///
/// Because Excel does, and the disagreement is worse than the conversion. Wave 1's addendum §4
/// spells it out: typing `#N/A` into a cell produces an error value, not text. If we imported it
/// as text and then wrote the workbook as `.xlsx`, Excel would reinterpret it on open and the
/// file would stop matching what OpenSheets shows. A leading apostrophe forces text, exactly as
/// it does in Excel.
public enum CSVValueParser {
    /// The cell for one field.
    ///
    /// A leading apostrophe is consumed rather than stored: it is an instruction about the
    /// field's type, not part of its text, and keeping it would mean every round trip grew
    /// another one.
    public static func cell(for field: String, typing: CSVValueTyping = .standard) -> Cell {
        Cell(value: value(for: field, typing: typing).0)
    }

    /// The value for one field, and whether a leading apostrophe forced it to text.
    public static func value(for field: String, typing: CSVValueTyping = .standard) -> (CellValue, forcedText: Bool) {
        guard !field.isEmpty else { return (.empty, false) }

        if field.hasPrefix("'") {
            return (.text(String(field.dropFirst())), true)
        }
        if typing.errorTokens, let error = CellError(rawValue: field), error.isExcelNative {
            return (.error(error), false)
        }
        if typing.booleans {
            if field.caseInsensitiveCompare("TRUE") == .orderedSame { return (.boolean(true), false) }
            if field.caseInsensitiveCompare("FALSE") == .orderedSame { return (.boolean(false), false) }
        }
        if typing.numbers, let number = self.number(field, preserveLeadingZeros: typing.preserveLeadingZeros) {
            return (.number(number), false)
        }
        return (.text(field), false)
    }

    /// The number a field denotes, or `nil` when it is not one.
    ///
    /// Strict on purpose. `Double(_:)` alone accepts `"inf"`, `"nan"`, `"0x1p3"` and a leading
    /// `+`, none of which a spreadsheet should turn into a number, and `nan` in particular then
    /// propagates into a file no reader can represent.
    public static func number(_ field: String, preserveLeadingZeros: Bool = true) -> Double? {
        let scalars = Array(field.unicodeScalars)
        var index = 0
        if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
        let digitsStart = index

        var sawDigit = false
        var sawDot = false
        var sawExponent = false
        while index < scalars.count {
            let scalar = scalars[index]
            if (0x30 ... 0x39).contains(scalar.value) {
                sawDigit = true
            } else if scalar == ".", !sawDot, !sawExponent {
                sawDot = true
            } else if (scalar == "e" || scalar == "E"), sawDigit, !sawExponent {
                sawExponent = true
                if index + 1 < scalars.count, scalars[index + 1] == "+" || scalars[index + 1] == "-" {
                    index += 1
                }
            } else {
                return nil
            }
            index += 1
        }
        guard sawDigit else { return nil }

        if preserveLeadingZeros, !sawDot, !sawExponent, digitsStart + 1 < scalars.count,
           scalars[digitsStart] == "0" {
            // `0012`, `007` — an identifier that happens to be made of digits. Turning it into a
            // number deletes the zeros, and the deletion survives every later save.
            return nil
        }
        guard let value = Double(field), value.isFinite else { return nil }
        return value
    }

    /// The text a cell shows when it is written back out to a delimited file.
    ///
    /// Formula cells export their **cached value**, because a CSV has nowhere to keep a formula
    /// (PLAN.md §5.4). Numbers use the shortest round-tripping form rather than a display format:
    /// a CSV is a data interchange file, and rounding `1234.5678` to the two decimal places the
    /// cell happens to show would be a silent loss.
    public static func text(for cell: Cell) -> String {
        switch cell.value {
        case .empty: ""
        case let .number(value): XLSXEscape.number(value)
        case let .text(value): value
        case let .boolean(value): value ? "TRUE" : "FALSE"
        case let .error(value): value.rawValue
        }
    }
}
