import Foundation

/// A single cell's address, **0-based on both axes**.
///
/// `CellRef(row: 0, column: 0)` is `A1`. Every index inside OpenSheets is 0-based; A1 strings
/// exist only at boundaries — the file format, the formula bar, the MCP wire, error messages.
/// The one-line rule: **if it has a letter in it, it is a boundary.**
///
/// This is the most-called type in the project. A 1M-cell workbook parses 1M of these out of
/// `<c r="B7">` attributes and writes 1M back out, so both directions avoid allocating:
/// ``init(a1:)`` walks UTF-8 bytes of any `StringProtocol` (a `Substring` straight out of the
/// parser works, no `String` copy), and ``appendA1(to:)-(inout[UInt8])`` writes ASCII into a
/// caller-owned buffer. ``a1String`` exists for convenience and does allocate; do not call it
/// per cell in a loop.
public struct CellRef: Hashable, Sendable, Codable {
    /// 0-based row index. `0` is row 1 in A1 notation.
    public let row: Int

    /// 0-based column index. `0` is column `A`.
    public let column: Int

    /// Builds a reference without checking it is on the sheet.
    ///
    /// Unchecked on purpose: reference arithmetic (shifting a formula down a row, walking a
    /// range) legitimately passes through out-of-range values before clamping, and a
    /// validating initialiser would force every intermediate step to be optional. Use
    /// ``isValid`` or ``validated()`` at the point where the value is committed.
    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    /// `A1`.
    public static let origin = CellRef(row: 0, column: 0)

    /// Whether this address exists on an xlsx sheet — both indices non-negative and within
    /// ``Limits``.
    public var isValid: Bool {
        Limits.isValidRow(row) && Limits.isValidColumn(column)
    }

    /// Self, or a thrown ``SheetError/cellReferenceOutOfRange(row:column:)``.
    ///
    /// The commit-time counterpart to the unchecked initialiser.
    @discardableResult
    public func validated() throws(SheetError) -> CellRef {
        guard isValid else { throw SheetError.cellReferenceOutOfRange(row: row, column: column) }
        return self
    }

    /// This address moved by a signed delta. Does not clamp or validate — see ``validated()``.
    public func offset(rows: Int = 0, columns: Int = 0) -> CellRef {
        CellRef(row: row + rows, column: column + columns)
    }

    /// This address pulled back inside the sheet on both axes.
    public var clamped: CellRef {
        CellRef(
            row: min(max(row, 0), Limits.maxRow),
            column: min(max(column, 0), Limits.maxColumn)
        )
    }

    /// Row-major order: down first, then across. This is the order cells are stored, written
    /// to xlsx, and shown in a diff, so sorting by it is almost always what you want.
    public static func < (lhs: CellRef, rhs: CellRef) -> Bool {
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }

    /// Packs both axes into one 64-bit word before hashing.
    ///
    /// The synthesised conformance would feed two `Int`s to the hasher; `Set<CellRef>` is hot
    /// enough (the flash set, the dirty set, dependency graphs) that one round is worth it.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(UInt64(bitPattern: Int64(row)) &* 0x0100_0000 &+ UInt64(bitPattern: Int64(column)))
    }
}

extension CellRef: Comparable {}

extension CellRef: CustomStringConvertible {
    /// The A1 form, for logs and debugger output.
    public var description: String { a1String }
}

// MARK: - A1 notation

extension CellRef {
    /// Parses `"B7"` into a reference, or returns `nil`.
    ///
    /// Accepts exactly one form: letters then digits, nothing else. Lowercase letters are
    /// folded (`b7` works, because CSV and hand-typed input do that). Anything outside the
    /// sheet — `XFE1`, `A0`, `A1048577` — is rejected rather than clamped, because a reference
    /// that big in a file means the file is lying about its size.
    ///
    /// Deliberately **rejects `$`**. `$B$7` is formula notation and carries anchoring
    /// information that this type does not model; use ``parseA1(_:)`` for that.
    ///
    /// Takes `some StringProtocol` so the xlsx parser can hand it a `Substring` of the
    /// document buffer without materialising a `String` per cell.
    public init?(a1 text: some StringProtocol) {
        var column = 0
        var row = 0
        var sawLetter = false
        var sawDigit = false

        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"):
                // A digit already means the letters are finished; "A1B" is not a reference.
                if sawDigit { return nil }
                // Bijective base 26: there is no zero digit, so A=1 … Z=26, AA=27.
                column = column * 26 + Int(byte | 0x20) - 96
                if column > Limits.columnCount { return nil }
                sawLetter = true
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                if !sawLetter { return nil }
                row = row * 10 + Int(byte - UInt8(ascii: "0"))
                if row > Limits.rowCount { return nil }
                sawDigit = true
            default:
                return nil
            }
        }

        guard sawLetter, sawDigit, row > 0 else { return nil }
        self.row = row - 1
        self.column = column - 1
    }

    /// Convenience spelling of ``init(a1:)`` so `CellRef("B7")` reads the way it does in the plan.
    public init?(_ a1: some StringProtocol) {
        self.init(a1: a1)
    }

    /// Parses an A1 reference that may carry `$` anchors, reporting where they were.
    ///
    /// This exists for the formula engine: `$B7` and `B$7` behave differently when a formula
    /// is copied or a row is inserted, and that distinction has to survive parsing.
    /// ``CellRef`` itself stays a plain address — anchoring is a property of a *reference in a
    /// formula*, not of a cell.
    public static func parseA1(_ text: some StringProtocol)
        -> (ref: CellRef, absoluteColumn: Bool, absoluteRow: Bool)? {
        var absoluteColumn = false
        var absoluteRow = false
        var column = 0
        var row = 0
        var sawLetter = false
        var sawDigit = false

        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "$"):
                // The first `$` anchors the column, the second the row — position, not order.
                if sawLetter {
                    if sawDigit || absoluteRow { return nil }
                    absoluteRow = true
                } else {
                    if absoluteColumn { return nil }
                    absoluteColumn = true
                }
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"):
                if sawDigit { return nil }
                column = column * 26 + Int(byte | 0x20) - 96
                if column > Limits.columnCount { return nil }
                sawLetter = true
            case UInt8(ascii: "0") ... UInt8(ascii: "9"):
                if !sawLetter { return nil }
                row = row * 10 + Int(byte - UInt8(ascii: "0"))
                if row > Limits.rowCount { return nil }
                sawDigit = true
            default:
                return nil
            }
        }

        guard sawLetter, sawDigit, row > 0 else { return nil }
        return (CellRef(row: row - 1, column: column - 1), absoluteColumn, absoluteRow)
    }

    /// `"B7"`. Allocates a `String`; in a per-cell loop use ``appendA1(to:)-(inout[UInt8])``.
    public var a1String: String {
        var result = CellRef.columnLetters(column)
        result.append(String(row + 1))
        return result
    }

    /// `"$B$7"` and friends, for the formula engine's round-trip.
    public func a1String(absoluteColumn: Bool, absoluteRow: Bool) -> String {
        var result = ""
        if absoluteColumn { result.append("$") }
        result.append(CellRef.columnLetters(column))
        if absoluteRow { result.append("$") }
        result.append(String(row + 1))
        return result
    }

    /// Appends the A1 form as ASCII to a byte buffer, allocating nothing.
    ///
    /// This is what the xlsx writer calls a million times while emitting `r="B7"` attributes.
    public func appendA1(to buffer: inout [UInt8]) {
        CellRef.appendColumnLetters(column, to: &buffer)
        CellRef.appendDecimal(row + 1, to: &buffer)
    }

    /// Appends the A1 form to a string, reusing the string's capacity.
    public func appendA1(to text: inout String) {
        text.append(CellRef.columnLetters(column))
        text.append(String(row + 1))
    }
}

// MARK: - Column letter arithmetic

extension CellRef {
    /// `0` → `"A"`, `25` → `"Z"`, `26` → `"AA"`, `16383` → `"XFD"`.
    ///
    /// Bijective base 26 — there is no zero digit, which is why `Z` is followed by `AA` and
    /// not `BA`. Getting that boundary wrong is the classic spreadsheet bug, so it has its
    /// own tests.
    ///
    /// Does **not** validate: a column past `XFD` still produces letters, because the caller
    /// is usually building an error message about exactly that. Negative input gives `"?"`,
    /// as does anything past four letters (475,254 columns — far beyond any real sheet).
    public static func columnLetters(_ column: Int) -> String {
        guard column >= 0, column < 475_254 else { return "?" }
        return String(unsafeUninitializedCapacity: 4) { buffer in
            var n = column
            var index = 4
            repeat {
                index -= 1
                buffer[index] = UInt8(ascii: "A") + UInt8(n % 26)
                n = n / 26 - 1
            } while n >= 0
            let count = 4 - index
            if index > 0 {
                for offset in 0 ..< count {
                    buffer[offset] = buffer[index + offset]
                }
            }
            return count
        }
    }

    /// `"A"` → `0`, `"XFD"` → `16383`. Case-insensitive. `nil` for anything that is not
    /// letters, or for a column past `XFD`.
    public static func columnIndex(letters: some StringProtocol) -> Int? {
        var column = 0
        var sawLetter = false
        for byte in letters.utf8 {
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"), UInt8(ascii: "a") ... UInt8(ascii: "z"):
                column = column * 26 + Int(byte | 0x20) - 96
                if column > Limits.columnCount { return nil }
                sawLetter = true
            default:
                return nil
            }
        }
        return sawLetter ? column - 1 : nil
    }

    /// Appends column letters as ASCII to a byte buffer, allocating nothing.
    public static func appendColumnLetters(_ column: Int, to buffer: inout [UInt8]) {
        guard column >= 0 else { buffer.append(UInt8(ascii: "?"))
            return
        }
        var scratch = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        var count = 0
        var n = column
        withUnsafeMutableBytes(of: &scratch) { raw in
            repeat {
                raw[count] = UInt8(ascii: "A") + UInt8(n % 26)
                count += 1
                n = n / 26 - 1
            } while n >= 0 && count < 8
            // Written least-significant first, so read back in reverse.
            for index in stride(from: count - 1, through: 0, by: -1) {
                buffer.append(raw[index])
            }
        }
    }

    /// Appends a non-negative integer as ASCII digits, allocating nothing.
    static func appendDecimal(_ value: Int, to buffer: inout [UInt8]) {
        guard value > 0 else { buffer.append(UInt8(ascii: "0"))
            return
        }
        var scratch = (
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0),
            UInt8(0)
        )
        var count = 0
        var n = value
        withUnsafeMutableBytes(of: &scratch) { raw in
            while n > 0, count < 20 {
                raw[count] = UInt8(ascii: "0") + UInt8(n % 10)
                count += 1
                n /= 10
            }
            for index in stride(from: count - 1, through: 0, by: -1) {
                buffer.append(raw[index])
            }
        }
    }
}
