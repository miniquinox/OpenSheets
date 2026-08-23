import Foundation
import SheetModel

/// One thing a formula reads.
public enum Dependency: Hashable, Sendable {
    /// A single cell.
    case cell(SheetCell)
    /// A rectangle, stored whole. `SUM(A:A)` is **one** of these, not 1,048,576 of the case
    /// above — see ``IntervalIndex``.
    case range(SheetRange)
    /// A defined name, uppercased.
    case name(String)
}

/// What one formula reads, plus the two facts about it that change how it is scheduled.
public struct FormulaDependencies: Sendable, Hashable {
    /// Single-cell precedents.
    public var cells: Set<SheetCell> = []
    /// Rectangular precedents, never expanded.
    public var ranges: [SheetRange] = []
    /// Defined names, uppercased.
    public var names: Set<String> = []
    /// Whether the formula calls `NOW`, `TODAY`, `RAND`, `RANDBETWEEN`, `OFFSET` or
    /// `INDIRECT`. Volatile formulas recompute on every pass because their real precedents are
    /// computed rather than written, so no edge can describe them.
    public var isVolatile = false
    /// Why this formula cannot be evaluated, when it cannot.
    public var unsupported: UnsupportedReason?

    public init() {}

    /// The precedents as a flat list, for `precedents(of:)`.
    public var all: [Dependency] {
        cells.sorted().map { Dependency.cell($0) }
            + ranges.map { Dependency.range($0) }
            + names.sorted().map { Dependency.name($0) }
    }
}

/// A formula cell as the graph holds it: its parsed tree and what it reads.
///
/// The tree is kept rather than re-parsed on every recalc. A 10,000-cell chain would otherwise
/// pay for 10,000 lexer runs per keystroke, which is the difference between "instant" and
/// "noticeably laggy".
public struct CompiledFormula: Sendable, Hashable {
    /// The formula source, without a leading `=`.
    public var source: String
    /// The parsed tree.
    public var expression: FormulaExpression
    /// What it reads.
    public var dependencies: FormulaDependencies

    public init(source: String, expression: FormulaExpression, dependencies: FormulaDependencies) {
        self.source = source
        self.expression = expression
        self.dependencies = dependencies
    }
}

/// Who depends on whom.
///
/// Two edge kinds, deliberately: single cells go in a dictionary, rectangles go in a
/// per-sheet interval tree. That split is the whole reason a workbook full of `SUM(A:A)`
/// stays small — the alternative, expanding every range into its cells, builds a million edges
/// per formula and is the standard way a spreadsheet engine falls over.
public struct DependencyGraph: Sendable {
    private var formulas: [SheetCell: CompiledFormula] = [:]
    private var cellDependents: [SheetCell: Set<SheetCell>] = [:]
    private var rangeEdges: [SheetID: [RangeEdge]] = [:]
    private var rangeIndex: [SheetID: IntervalIndex<Int>] = [:]
    private var nameDependents: [String: Set<SheetCell>] = [:]
    private var volatile: Set<SheetCell> = []

    private struct RangeEdge: Sendable {
        var range: CellRange
        var dependent: SheetCell
    }

    public init() {}

    /// Builds a graph over every formula in `workbook`.
    ///
    /// Formulas that do not parse are recorded with no precedents rather than throwing: a file
    /// with one broken formula still has to open, and the broken cell keeps its cached value.
    public init(workbook: Workbook, grammar: FormulaGrammar = .default) {
        self.init()
        for sheet in workbook.sheets {
            let resolution = SheetResolution(owner: sheet.id, workbook: workbook)
            sheet.cells.forEachCell(in: .entireSheet) { ref, cell in
                guard let source = cell.formula else { return }
                let target = SheetCell(sheet: sheet.id, ref: ref)
                guard let compiled = DependencyGraph.compile(
                    source, at: target, resolving: resolution, workbook: workbook, grammar: grammar
                ) else { return }
                formulas[target] = compiled
                link(compiled.dependencies, to: target)
            }
        }
        for sheet in rangeEdges.keys { reindex(sheet) }
    }

    // MARK: - Reading

    /// Every formula cell the graph knows about.
    public var formulaCells: some Collection<SheetCell> { formulas.keys }

    /// The compiled formula at `cell`, if it has one.
    public func formula(at cell: SheetCell) -> CompiledFormula? { formulas[cell] }

    /// What the formula at `cell` reads.
    public func precedents(of cell: SheetCell) -> [Dependency] {
        formulas[cell]?.dependencies.all ?? []
    }

    /// Every formula that reads `cell`, directly.
    public func dependents(of cell: SheetCell) -> Set<SheetCell> {
        var result = cellDependents[cell] ?? []
        if let index = rangeIndex[cell.sheet], let edges = rangeEdges[cell.sheet] {
            for edge in index.payloads(containing: cell.ref.row) where
                edges[edge].range.columns.contains(cell.ref.column) {
                result.insert(edges[edge].dependent)
            }
        }
        return result
    }

    /// Every formula that reads any cell in `range`.
    public func dependents(intersecting range: SheetRange) -> Set<SheetCell> {
        var result: Set<SheetCell> = []
        if let edges = rangeEdges[range.sheet], let index = rangeIndex[range.sheet] {
            for edge in index.payloads(overlapping: range.range.start.row, range.range.end.row)
                where edges[edge].range.intersects(range.range) {
                result.insert(edges[edge].dependent)
            }
        }
        // Single-cell edges are only worth walking when the rectangle is small; a whole-column
        // invalidation is better served by scanning the map once.
        if range.range.cellCount <= 1024 {
            for ref in range.range {
                if let direct = cellDependents[SheetCell(sheet: range.sheet, ref: ref)] {
                    result.formUnion(direct)
                }
            }
        } else {
            for (source, targets) in cellDependents where range.contains(source) {
                result.formUnion(targets)
            }
        }
        return result
    }

    /// Every formula that reads the defined name `name`.
    public func dependents(ofName name: String) -> Set<SheetCell> {
        nameDependents[name.uppercased()] ?? []
    }

    /// Formulas that recompute on every pass.
    public var volatileCells: Set<SheetCell> { volatile }

    /// Total edges. Single-cell precedents count once each, and a rectangle counts **once**
    /// however many cells it covers — which is the property the `SUM(A:A)` test pins.
    public var edgeCount: Int { cellEdgeCount + rangeEdgeCount + nameEdgeCount }

    /// Edges from a single-cell precedent.
    public var cellEdgeCount: Int { cellDependents.values.reduce(0) { $0 + $1.count } }

    /// Edges from a rectangular precedent.
    public var rangeEdgeCount: Int { rangeEdges.values.reduce(0) { $0 + $1.count } }

    /// Edges from a defined name.
    public var nameEdgeCount: Int { nameDependents.values.reduce(0) { $0 + $1.count } }

    // MARK: - Writing

    /// Records the formula at `cell`, replacing whatever was there.
    ///
    /// Returns `false` when the formula does not parse; the cell is then removed from the
    /// graph rather than left with stale edges.
    @discardableResult
    public mutating func setFormula(
        _ source: String, at cell: SheetCell, in workbook: Workbook, grammar: FormulaGrammar = .default
    ) -> Bool {
        let resolution = SheetResolution(owner: cell.sheet, workbook: workbook)
        guard let compiled = DependencyGraph.compile(
            source, at: cell, resolving: resolution, workbook: workbook, grammar: grammar
        ) else {
            removeFormula(at: cell)
            return false
        }
        setCompiled(compiled, at: cell)
        return true
    }

    /// Records an already-parsed formula.
    public mutating func setCompiled(_ compiled: CompiledFormula, at cell: SheetCell) {
        var touched = Set(formulas[cell]?.dependencies.ranges.map(\.sheet) ?? [])
        unlink(at: cell)
        formulas[cell] = compiled
        link(compiled.dependencies, to: cell)
        touched.formUnion(compiled.dependencies.ranges.map(\.sheet))
        for sheet in touched { reindex(sheet) }
    }

    /// Forgets the formula at `cell`.
    public mutating func removeFormula(at cell: SheetCell) {
        guard let existing = formulas[cell] else { return }
        let touched = Set(existing.dependencies.ranges.map(\.sheet))
        unlink(at: cell)
        for sheet in touched { reindex(sheet) }
    }

    // MARK: - Compilation

    /// Parses a formula and works out what it reads. `nil` when it does not parse.
    public static func compile(
        _ source: String,
        at cell: SheetCell,
        resolving sheets: SheetResolution,
        workbook: Workbook,
        grammar: FormulaGrammar = .default
    ) -> CompiledFormula? {
        guard let expression = try? FormulaParser.parse(source, anchor: cell.ref, grammar: grammar) else {
            return nil
        }
        return CompiledFormula(
            source: source,
            expression: expression,
            dependencies: dependencies(of: expression, at: cell, resolving: sheets, workbook: workbook)
        )
    }

    /// What an expression reads.
    public static func dependencies(
        of expression: FormulaExpression,
        at cell: SheetCell,
        resolving sheets: SheetResolution,
        workbook: Workbook
    ) -> FormulaDependencies {
        var result = FormulaDependencies()
        result.unsupported = FormulaSyntax.unsupportedReason(in: expression)
        expression.forEachNode { node in
            switch node {
            case let .reference(reference):
                guard !reference.isDeleted, let sheet = sheets.resolve(reference.qualifier) else { return }
                let range = reference.range
                if reference.shape == .cells, range.isSingleCell {
                    result.cells.insert(SheetCell(sheet: sheet, ref: range.start))
                } else {
                    result.ranges.append(SheetRange(sheet: sheet, range: range))
                }
            case let .name(name):
                result.names.insert(name.name.uppercased())
                // A name that points at a range also depends on that range, so editing the
                // cells behind `Total` invalidates everything that uses it.
                if let defined = workbook.definedName(name.name, scope: sheets.owner)
                    ?? workbook.definedName(name.name), let target = defined.target {
                    result.ranges.append(SheetRange(sheet: target.sheet ?? sheets.owner, range: target.range))
                }
            case let .call(call):
                if FunctionCatalog.signature(for: call.name)?.isVolatile == true { result.isVolatile = true }
            default:
                break
            }
        }
        return result
    }

    // MARK: - Edge bookkeeping

    private mutating func link(_ dependencies: FormulaDependencies, to cell: SheetCell) {
        for precedent in dependencies.cells {
            cellDependents[precedent, default: []].insert(cell)
        }
        for range in dependencies.ranges {
            rangeEdges[range.sheet, default: []].append(RangeEdge(range: range.range, dependent: cell))
        }
        for name in dependencies.names {
            nameDependents[name, default: []].insert(cell)
        }
        if dependencies.isVolatile { volatile.insert(cell) }
    }

    private mutating func unlink(at cell: SheetCell) {
        guard let existing = formulas.removeValue(forKey: cell) else { return }
        for precedent in existing.dependencies.cells {
            cellDependents[precedent]?.remove(cell)
            if cellDependents[precedent]?.isEmpty == true { cellDependents.removeValue(forKey: precedent) }
        }
        for name in existing.dependencies.names {
            nameDependents[name]?.remove(cell)
            if nameDependents[name]?.isEmpty == true { nameDependents.removeValue(forKey: name) }
        }
        for sheet in Set(existing.dependencies.ranges.map(\.sheet)) {
            rangeEdges[sheet]?.removeAll { $0.dependent == cell }
        }
        volatile.remove(cell)
    }

    private mutating func reindex(_ sheet: SheetID) {
        let edges = rangeEdges[sheet] ?? []
        guard !edges.isEmpty else {
            rangeEdges.removeValue(forKey: sheet)
            rangeIndex.removeValue(forKey: sheet)
            return
        }
        rangeIndex[sheet] = IntervalIndex(edges.enumerated().map { offset, edge in
            IntervalIndex<Int>.Entry(lower: edge.range.start.row, upper: edge.range.end.row, payload: offset)
        })
    }
}
