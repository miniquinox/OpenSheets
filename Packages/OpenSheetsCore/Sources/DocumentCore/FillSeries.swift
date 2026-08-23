import Foundation
import SheetModel

/// What dragging the fill handle continues.
///
/// Deliberately three cases, not Excel's twenty. Excel will extend "Jan, Feb" into months, "Mon,
/// Tue" into weekdays, and any custom list the user has defined — all of which need a locale
/// database and none of which is what makes the handle useful. What makes it useful is that a
/// column of `1, 2` becomes `3, 4` and a column of dates advances by a day. Everything else copies,
/// which is exactly what a single selected cell does and is never surprising.
public enum FillSeries: Sendable, Hashable {
    /// `10, 20` → `30, 40`. The step is the average first difference, so `1, 2, 4` gives `5.5`
    /// rather than pretending to fit a curve.
    case arithmetic(start: Double, step: Double)
    /// `Item 1, Item 2` → `Item 3`. The prefix is fixed and the trailing integer advances.
    case suffixed(prefix: String, start: Int, step: Int, digits: Int)
    /// Everything else, including a single cell.
    case copy

    /// The value at `position` places past the start of the source block.
    public func value(at position: Int, template: Cell) -> Cell {
        var cell = template
        switch self {
        case let .arithmetic(start, step):
            cell.value = .number(start + step * Double(position))
        case let .suffixed(prefix, start, step, digits):
            let next = start + step * position
            let number = digits > 1
                ? String(format: "%0\(digits)d", next)
                : String(next)
            cell.value = .text(prefix + number)
        case .copy:
            break
        }
        return cell
    }

    /// Reads the source block and decides what it is.
    ///
    /// `alongRows` says which way the handle was dragged: a two-column source dragged downwards is
    /// two independent series, and this is called once per column by the caller walking the
    /// destination. Only the first column (or row) of the block is sampled, which is why the
    /// caller passes the block rather than the values.
    public static func detect(_ source: CellRange, in sheet: Sheet, alongRows: Bool) -> FillSeries? {
        let refs: [CellRef] = alongRows
            ? source.rows.map { CellRef(row: $0, column: source.start.column) }
            : source.columns.map { CellRef(row: source.start.row, column: $0) }
        guard refs.count >= 2 else { return nil }

        let cells = refs.map { sheet.cells[$0] }
        guard cells.allSatisfy({ $0?.formula == nil }) else { return nil }

        let numbers = cells.compactMap { $0?.value.number }
        if numbers.count == cells.count, numbers.count >= 2 {
            let differences = zip(numbers.dropFirst(), numbers).map(-)
            let step = differences.reduce(0, +) / Double(differences.count)
            guard step != 0 else { return .copy }
            return .arithmetic(start: numbers[0], step: step)
        }

        let texts = cells.compactMap { $0?.value.text }
        if texts.count == cells.count, texts.count >= 2 {
            let parsed = texts.compactMap(splitTrailingInteger)
            guard parsed.count == texts.count,
                  let first = parsed.first,
                  parsed.allSatisfy({ $0.prefix == first.prefix })
            else { return .copy }
            let differences = zip(parsed.dropFirst().map(\.number), parsed.map(\.number)).map(-)
            guard let step = differences.first, differences.allSatisfy({ $0 == step }), step != 0 else {
                return .copy
            }
            return .suffixed(
                prefix: first.prefix, start: first.number, step: step, digits: first.digits
            )
        }

        return .copy
    }

    /// `"Item 007"` → `("Item ", 7, 3)`. Digit count is kept so the zero padding survives.
    static func splitTrailingInteger(_ text: String) -> (prefix: String, number: Int, digits: Int)? {
        let digits = text.reversed().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 18 else { return nil }
        let suffix = String(digits.reversed())
        guard let number = Int(suffix) else { return nil }
        return (String(text.dropLast(suffix.count)), number, suffix.count)
    }
}
