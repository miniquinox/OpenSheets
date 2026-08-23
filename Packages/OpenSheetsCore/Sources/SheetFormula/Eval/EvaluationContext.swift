import Foundation
import SheetModel

/// Everything about an evaluation that is not the workbook itself.
///
/// `now` and `randomSeed` are injected rather than read from the system because a formula
/// engine whose output depends on the wall clock cannot be tested, and because a recalc pass
/// must see *one* value of `NOW()` across every cell it touches — otherwise two cells that
/// both say `=NOW()` disagree, and the diff panel shows a change that nobody made.
public struct EvaluationOptions: Sendable, Hashable {
    /// The workbook's epoch. Passed in, never assumed: a 1904 workbook read as 1900 shifts
    /// every date by four years and a day.
    public var dateSystem: DateSystem

    /// The serial number `NOW()` returns. `TODAY()` is its floor.
    public var now: Double

    /// Seed for `RAND` and `RANDBETWEEN`. Fixed by default so a test suite is reproducible;
    /// the app passes a fresh seed per session.
    public var randomSeed: UInt64

    /// How the parser reads `^` and unary minus. See ``FormulaGrammar``.
    public var grammar: FormulaGrammar

    /// The largest number of cells a single aggregate will walk before giving up with
    /// `#NUM!`. Whole-column references make the *addressable* count 1,048,576 per column;
    /// this caps the *populated* work, so a pathological sheet cannot wedge a recalc.
    public var maxCellsPerAggregate: Int

    public init(
        dateSystem: DateSystem = .excel1900,
        now: Double = 45_000,
        randomSeed: UInt64 = 0x2545_F491_4F6C_DD1D,
        grammar: FormulaGrammar = .default,
        maxCellsPerAggregate: Int = 4_000_000
    ) {
        self.dateSystem = dateSystem
        self.now = now
        self.randomSeed = randomSeed
        self.grammar = grammar
        self.maxCellsPerAggregate = maxCellsPerAggregate
    }

    /// Options for `workbook`, taking its epoch and clock-independent defaults.
    public static func forWorkbook(_ workbook: Workbook, now: Double = 45_000) -> EvaluationOptions {
        EvaluationOptions(dateSystem: workbook.meta.dateSystem, now: now)
    }
}

/// Why a formula could not be computed, as opposed to computing to an error.
///
/// The distinction is the honesty requirement in PLAN.md §5.3: `#DIV/0!` is an *answer*, and
/// "this uses `LAMBDA` and we do not implement `LAMBDA`" is not. The second must never be
/// dressed up as the first, and must never become a plausible-looking number.
public enum UnsupportedReason: Hashable, Sendable {
    /// A real Excel function outside our ~130.
    case function(String)
    /// Syntax we round-trip but do not interpret — structured table references.
    case syntax(String)
    /// `[1]Other.xlsx`. PLAN.md §7.3: we never open another workbook.
    case externalWorkbook(String)
    /// `Sheet1:Sheet3!A1`.
    case threeDimensionalReference(String)
    /// A precedent of this cell was itself unsupported, so this cell's inputs are unknown.
    case staleInput(SheetCell)

    /// A sentence for the tooltip A8 shows under the dotted underline.
    public var message: String {
        switch self {
        case let .function(name):
            "\(name) is not one of the functions OpenSheets evaluates, so the cached value is kept."
        case let .syntax(text):
            "'\(text)' is syntax OpenSheets round-trips but does not evaluate."
        case let .externalWorkbook(text):
            "\(text) points at another workbook, which OpenSheets never opens."
        case let .threeDimensionalReference(text):
            "\(text) spans several sheets, which OpenSheets does not evaluate."
        case let .staleInput(cell):
            "An input (\(cell.ref.a1String)) could not be recomputed, so this value may be out of date."
        }
    }
}

/// What can go wrong inside a function body.
///
/// The two cases are not variations of each other and must never be collapsed. ``cell(_:)`` is
/// an **answer**: `#DIV/0!` is what Excel puts in the cell and what the file will store.
/// ``unsupported(_:)`` is an **admission**: we do not know the answer, the cached value stays,
/// and the cell gets a dotted underline. Turning the second into the first would be exactly the
/// plausible-looking wrong number PLAN.md §5.3 forbids.
enum FormulaFault: Error {
    case cell(CellError)
    case unsupported(UnsupportedReason)
}

/// The mutable state one evaluation pass shares.
///
/// A reference type on purpose. The overlay of freshly computed values is written once per
/// cell and read by every cell downstream; copying it into each function call would turn a
/// 10,000-cell recalc into 10,000 dictionary copies, which is the difference between 20 ms and
/// several seconds. It never escapes ``FormulaEngine/recalculate(in:changed:options:)``, which
/// is what keeps ``FormulaEngine`` itself `Sendable`.
final class EvaluationScope {
    let workbook: Workbook
    let options: EvaluationOptions
    /// Values computed during this pass, which shadow the workbook's cached ones.
    var overlay: [SheetCell: CellValue] = [:]
    /// Cells whose value we could not recompute, so downstream cells are stale too.
    var unsupported: [SheetCell: UnsupportedReason] = [:]
    /// Cells found to be in a cycle.
    var circular: Set<SheetCell> = []
    private var randomState: UInt64
    private let sheetIndex: [String: SheetID]

    /// Sheet id → position in `workbook.sheets`.
    ///
    /// `workbook[id]` is a linear search that then *copies* the `Sheet` value out, and a
    /// recalc reads cells through it once per evaluated cell. Copying a `Sheet` means
    /// retaining every array it holds, which turned out to be the single most expensive thing
    /// in a 50,000-cell pass. Going through the position lets the store be read in place.
    private let sheetPositions: [SheetID: Int]

    init(workbook: Workbook, options: EvaluationOptions) {
        self.workbook = workbook
        self.options = options
        randomState = options.randomSeed == 0 ? 0x9E37_79B9_7F4A_7C15 : options.randomSeed
        var index: [String: SheetID] = [:]
        var positions: [SheetID: Int] = [:]
        for (position, sheet) in workbook.sheets.enumerated() {
            index[sheet.name.uppercased()] = sheet.id
            positions[sheet.id] = position
        }
        sheetIndex = index
        sheetPositions = positions
    }

    /// A sheet id by name, case-insensitively — Excel's sheet names are not case-sensitive.
    func sheetID(named name: String) -> SheetID? {
        sheetIndex[name.uppercased()]
    }

    /// The name of a sheet, for building an error message or a formatted reference.
    func sheetName(_ id: SheetID) -> String? {
        workbook[id]?.name
    }

    /// The value of a cell, preferring anything computed earlier in this pass.
    func value(at cell: SheetCell) -> ScalarValue {
        if !circular.isEmpty, circular.contains(cell) { return .error(.circular) }
        if !overlay.isEmpty, let fresh = overlay[cell] { return ScalarValue(fresh) }
        guard let position = sheetPositions[cell.sheet],
              let stored = workbook.sheets[position].cells[cell.ref]
        else { return .blank }
        return ScalarValue(stored.value)
    }

    /// The stored cell, for the handful of functions that need more than the value.
    func cell(at cell: SheetCell) -> Cell? {
        guard let position = sheetPositions[cell.sheet] else { return nil }
        return workbook.sheets[position].cells[cell.ref]
    }

    /// Whether a row is hidden, which `SUBTOTAL`'s 101–111 forms care about.
    func isRowHidden(_ cell: SheetCell) -> Bool {
        guard let position = sheetPositions[cell.sheet] else { return false }
        return workbook.sheets[position].hiddenRows[cell.ref.row]
    }

    /// xorshift64*, so `RAND()` is deterministic per seed and identical across machines.
    /// `Double.random(in:)` would use the system generator and make every test a coin flip.
    func nextRandom() -> Double {
        randomState ^= randomState >> 12
        randomState ^= randomState << 25
        randomState ^= randomState >> 27
        let scrambled = randomState &* 0x2545_F491_4F6C_DD1D
        return Double(scrambled >> 11) * 0x1p-53
    }

    /// The populated cells of a range, in row-major order, without materialising the
    /// rectangle. `A:A` is 1,048,576 addresses and usually a handful of values.
    ///
    /// Only cells the store already holds are visited. That is sound because the overlay is
    /// written exclusively for cells that carry a formula, and a cell that carries a formula
    /// is by definition in the store — so there is no "computed but invisible" case to sweep
    /// for. Sweeping anyway would make every range read O(overlay), which turns a 10,000-cell
    /// recalc quadratic.
    func forEachPopulated(in reference: SheetRange, _ body: (SheetCell, ScalarValue) -> Void) {
        guard let position = sheetPositions[reference.sheet] else { return }
        let hasOverlay = !overlay.isEmpty
        let hasCircular = !circular.isEmpty
        workbook.sheets[position].cells.forEachCell(in: reference.range) { ref, cell in
            let key = SheetCell(sheet: reference.sheet, ref: ref)
            if hasOverlay, let fresh = overlay[key] {
                body(key, ScalarValue(fresh))
            } else if hasCircular, circular.contains(key) {
                body(key, .error(.circular))
            } else {
                body(key, ScalarValue(cell.value))
            }
        }
    }
}
