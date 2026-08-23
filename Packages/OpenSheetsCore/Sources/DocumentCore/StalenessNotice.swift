import Foundation
import SheetModel

/// What an edit to this workbook silently will not update.
///
/// Wave 2 addendum §5, verbatim: *"none of these are bugs to fix in v0.1; all of them are things a
/// user must not discover by surprise."* A chart keeps the values it cached when it was last
/// opened in Excel, a pivot only refreshes on demand, and a conditional format's `sqref` does not
/// follow a row insert. We do not fix any of that in v0.1. What we do is **say so, once, at the
/// moment it starts being true** — the first time the user edits a workbook that contains one of
/// these — rather than letting them find out in Excel next week.
///
/// The detection is on the passthrough part list, which is the honest place: those parts exist in
/// the file whether or not we model them, and their presence is exactly the condition under which
/// the caveat applies.
public struct StalenessNotice: Sendable, Hashable {
    /// One clause per affected feature, already ordered by how much it matters.
    public var reasons: [Reason]

    public enum Reason: String, Sendable, Hashable, CaseIterable {
        case charts
        case pivotTables
        case conditionalFormatting
        case tables
        case macros

        public var headline: String {
            switch self {
            case .charts: "Charts keep their cached values"
            case .pivotTables: "Pivot tables keep their cached data"
            case .conditionalFormatting: "Conditional formats do not follow inserts"
            case .tables: "Table ranges do not follow inserts"
            case .macros: "Macros are preserved and never run"
            }
        }

        public var detail: String {
            switch self {
            case .charts:
                "A chart re-reads its source range when Excel opens the file, so it will catch up "
                    + "then — but the numbers stored inside it are the old ones until it does."
            case .pivotTables:
                "A pivot table shows its cached data until someone refreshes it in Excel."
            case .conditionalFormatting:
                "The rules are preserved exactly, but the ranges they apply to are not moved by "
                    + "inserting or deleting rows and columns."
            case .tables:
                "Table parts and drawing anchors are preserved exactly, and are not moved by "
                    + "inserting or deleting rows and columns."
            case .macros:
                "`vbaProject.bin` is written back byte for byte. OpenSheets never executes it."
            }
        }
    }

    public init(reasons: [Reason]) {
        self.reasons = reasons
    }

    public var isEmpty: Bool { reasons.isEmpty }

    /// One sentence for the sync chip or an inline note.
    public var summary: String {
        guard let first = reasons.first else { return "" }
        if reasons.count == 1 { return first.headline + "." }
        return "\(first.headline), and \(reasons.count - 1) more thing\(reasons.count == 2 ? "" : "s") "
            + "this edit does not update."
    }

    /// Reads the workbook's own parts.
    public static func detect(in workbook: Workbook) -> StalenessNotice {
        var reasons: [Reason] = []
        let paths = workbook.passthrough.paths

        if paths.contains(where: { $0.hasPrefix("xl/charts/") || $0.contains("/charts/chart") }) {
            reasons.append(.charts)
        }
        if paths.contains(where: { $0.hasPrefix("xl/pivotCache/") || $0.hasPrefix("xl/pivotTables/") }) {
            reasons.append(.pivotTables)
        }
        if workbook.sheets.contains(where: { sheet in
            sheet.sheetLevelFragments.contains { $0.elementName == "conditionalFormatting" }
        }) {
            reasons.append(.conditionalFormatting)
        }
        if paths.contains(where: { $0.hasPrefix("xl/tables/") }) {
            reasons.append(.tables)
        }
        if workbook.meta.containsMacros {
            reasons.append(.macros)
        }
        return StalenessNotice(reasons: reasons)
    }

    /// The subset worth raising for a *structural* edit specifically.
    ///
    /// Editing a cell cannot break a conditional format's `sqref`; inserting a row can. Splitting
    /// this keeps the warning proportionate — a notice the user sees on every keystroke is a
    /// notice they stop reading, and then it is not a warning at all.
    public func forStructuralEdit() -> StalenessNotice {
        StalenessNotice(reasons: reasons)
    }

    /// The subset worth raising for a plain cell edit.
    public func forCellEdit() -> StalenessNotice {
        StalenessNotice(reasons: reasons.filter { $0 == .charts || $0 == .pivotTables })
    }
}
