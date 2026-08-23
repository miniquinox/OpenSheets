import Foundation
import SheetFormula
import SheetModel

/// Whether this workbook's cached values can be trusted, and what to do when they cannot.
///
/// # The failure this exists to prevent
///
/// PLAN.md §5.3 is right: `.xlsx` stores `<f>SUM(B2:B14)</f><v>42</v>`, so a workbook renders
/// correctly with zero evaluation, and evaluating a file somebody else already calculated risks
/// replacing their correct number with our approximation of it.
///
/// It is right *for a file that was calculated*. A file from openpyxl, pandas or xlsxwriter — which
/// is to say the file a Claude Code user is most likely to hand us — stores
/// `<f>SUM(B2:B14)</f><v>0</v>`: the formula is real and the cached value is a placeholder nothing
/// ever evaluated. Rendering that faithfully puts `Total  0, 0, 0, 0, 0` under five columns of real
/// figures. Excel shows the right numbers for the same file, because it recalculates on open when
/// the calculation metadata is absent or stale.
///
/// A confident, plausible, wrong number is the worst thing a spreadsheet can display. It is what A3
/// was forbidden from doing when it wanted to approximate unsupported functions, and it must not
/// arrive at the integration layer by another door.
///
/// # The heuristic
///
/// Recalculate on open only when the workbook itself gives us reason to distrust its cache:
///
/// - `meta.fullCalculationOnLoad` — the file explicitly asks for it; or
/// - the workbook has formulas but **no calculation evidence at all**: no `xl/calcChain.xml` and no
///   `<calcPr>` (``SheetModel/WorkbookMeta/hasCalculationEvidence``). Excel writes both, LibreOffice
///   writes `calcPr`; a package with neither has never been through a calculation engine.
///
/// Anything else keeps its cache untouched. That is deliberately narrow: a LibreOffice file has no
/// `calcChain` but does have `calcPr`, and its values are genuinely computed — recalculating it
/// would be us overwriting a correct number with ours for no reason.
///
/// # The ceiling
///
/// **50,000 formula cells** (``formulaCeiling``). Above it the cache is left exactly as it is and
/// the session feed says so, because a pass that runs for ten seconds on a workbook the user is
/// already scrolling is a worse trade than a stale total they have been told about.
///
/// The number is measured, not guessed: `FormulaEngine.recalculateAll` over a debug build takes
/// 15 ms for 1,000 formulas, 130 ms for 10,000 and 716 ms for 50,000 — so the ceiling is about a
/// second of one background core at its worst, and a release build is faster still. It matches the
/// recalc budget in `docs/perf/budgets.json` (10,000 dependent cells in 0.2 s).
public enum OpenRecalculation {
    /// The most formulas we will recalculate on open. See the type's note.
    public static let formulaCeiling = 50_000

    /// What to do about a freshly-read workbook.
    public enum Decision: Sendable, Equatable {
        /// Somebody calculated this file. Render what it says (PLAN.md §5.3).
        case trustCache
        /// Nothing ever calculated it, and it is small enough to put right.
        case recalculate(formulaCount: Int)
        /// Nothing ever calculated it and it is too big to do off the critical path. The cached
        /// values stand, and the user is told.
        case tooLarge(formulaCount: Int)
    }

    /// Why we distrusted the cache, for the note in the session feed.
    public enum Reason: Sendable, Equatable {
        /// `calcPr/@fullCalcOnLoad` — the producer asked for this explicitly.
        case fileAsksForIt
        /// No `calcChain.xml`, no `calcPr`: nothing has ever evaluated these formulas.
        case neverCalculated
    }

    /// The decision, given a formula count the caller already has.
    ///
    /// Takes the count rather than computing it: ``DocumentModel`` builds a ``FormulaEngine`` on
    /// open regardless, and its dependency graph already knows every formula cell — walking a
    /// million cells a second time to count them would be the most expensive part of this.
    public static func decide(formulaCount: Int, meta: WorkbookMeta) -> Decision {
        guard formulaCount > 0, reason(for: meta) != nil else { return .trustCache }
        guard formulaCount <= formulaCeiling else { return .tooLarge(formulaCount: formulaCount) }
        return .recalculate(formulaCount: formulaCount)
    }

    /// Why this workbook's cache is not to be trusted, or `nil` if it is.
    public static func reason(for meta: WorkbookMeta) -> Reason? {
        if meta.fullCalculationOnLoad { return .fileAsksForIt }
        // A workbook we built ourselves, or read from CSV, has no package and therefore no
        // evidence — and also nothing worth recalculating, which the formula count catches.
        if !meta.hasCalculationEvidence, meta.sourceFormat != .csv, meta.sourceFormat != .tsv {
            return .neverCalculated
        }
        return nil
    }

    /// What one pass actually did, for the note and for the tests.
    public struct Outcome: Sendable, Equatable {
        /// Cells whose displayed value changed.
        public var correctedCount: Int
        /// Cells whose formula we cannot evaluate. They keep the file's cached value and are
        /// marked ``SheetModel/CellFlags/staleCache`` — never replaced with a guess.
        public var keptCachedCount: Int
        /// Formulas the pass looked at.
        public var formulaCount: Int

        public init(correctedCount: Int, keptCachedCount: Int, formulaCount: Int) {
            self.correctedCount = correctedCount
            self.keptCachedCount = keptCachedCount
            self.formulaCount = formulaCount
        }

        public var changedAnything: Bool { correctedCount > 0 }
    }

    /// Runs the pass and reports what it found. **Pure**: it does not touch the workbook.
    ///
    /// Split out so it can run on a background task with two `Sendable` values and nothing else —
    /// the recalculation must never be on the path to the first frame.
    public static func run(engine: FormulaEngine, on workbook: Workbook) -> (RecalcResult, Outcome) {
        let result = engine.recalculateAll(in: workbook)
        var corrected = 0
        for (cell, value) in result.values where workbook[cell.sheet]?.cells[cell.ref]?.value != value {
            corrected += 1
        }
        return (
            result,
            Outcome(
                correctedCount: corrected,
                keptCachedCount: result.stale.count,
                formulaCount: result.visited.count
            )
        )
    }

    /// The line the session feed shows. One sentence, past tense, with the number in it.
    public static func summary(_ outcome: Outcome) -> String {
        var text = "Recalculated \(outcome.correctedCount) "
            + (outcome.correctedCount == 1 ? "value" : "values")
            + " the file had never computed"
        if outcome.keptCachedCount > 0 {
            text += " · \(outcome.keptCachedCount) kept as stale"
        }
        return text
    }

    /// The line for a workbook over the ceiling. It says what was not done and why, because the
    /// totals on screen may be the producer's placeholders and the user has no other way to know.
    public static func ceilingSummary(formulaCount: Int) -> String {
        "\(formulaCount.formatted()) formulas were never calculated by the file's producer — "
            + "too many to recalculate on open, so the stored values are shown as they are"
    }
}
