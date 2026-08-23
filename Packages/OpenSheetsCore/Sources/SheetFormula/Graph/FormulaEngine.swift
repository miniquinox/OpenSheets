import Foundation
import SheetModel

/// What happened to one cell in a recalc.
public enum CellOutcome: Sendable, Hashable {
    /// A value we computed. Safe to store.
    case value(CellValue)
    /// We could not compute it. **Keep the cached value**, set ``CellFlags/staleCache``, and
    /// tell the user why — see ``UnsupportedReason/message``.
    case keepCached(UnsupportedReason)
}

/// The result of one recalculation pass.
///
/// Deliberately a *description* of what should change rather than a mutated workbook. A8
/// applies it inside its own undo transaction, and the MCP layer wants to report it before
/// committing. ``apply(to:)`` is there for callers that just want it done.
public struct RecalcResult: Sendable {
    /// New values, for cells we computed.
    public var values: [SheetCell: CellValue] = [:]
    /// Cells we could not compute, and why. Their stored values must be left alone.
    public var stale: [SheetCell: UnsupportedReason] = [:]
    /// Cells that take part in — or sit downstream of — a dependency cycle.
    public var circular: Set<SheetCell> = []
    /// Every formula cell the pass looked at.
    ///
    /// This is the number that proves the recalc was incremental: change one cell with 10,000
    /// dependents in a 1,000,000-cell workbook and this holds 10,000 entries, not 1,000,000.
    public var visited: Set<SheetCell> = []
    /// How many formulas were actually evaluated.
    public var evaluatedCount = 0

    /// Anchors whose result spilled, mapped to the region it now occupies (anchor included).
    ///
    /// ``values`` already holds one entry per cell of the region; this says which anchor owns
    /// them, which is what ``Sheet/arrayFormulaRanges`` needs and what makes the spilled-into
    /// cells refuse an edit.
    public var spills: [SheetCell: CellRange] = [:]

    /// Anchors that owned a region **before** this pass, mapped to that old region.
    ///
    /// A spill that shrinks has to clear what it no longer covers, or `SORT` over a filtered
    /// list leaves the tail of the previous, longer result sitting underneath it looking like
    /// data. Present whether the anchor still spills (region changed) or not (it now returns a
    /// scalar, or `#SPILL!`).
    public var clearedSpills: [SheetCell: CellRange] = [:]

    /// Whether the pass changed nothing.
    public var isEmpty: Bool {
        values.isEmpty && stale.isEmpty && circular.isEmpty && clearedSpills.isEmpty
    }

    /// The outcome for one cell.
    public func outcome(for cell: SheetCell) -> CellOutcome? {
        if let reason = stale[cell] { return .keepCached(reason) }
        if let value = values[cell] { return .value(value) }
        return nil
    }

    /// Folds a later round into this result, and reports the regions that changed shape.
    ///
    /// Two subtleties, both of them the difference between a right answer and a stale one:
    ///
    /// - When an anchor's region shrinks between rounds, the values this result already holds
    ///   for the cells it no longer covers are **wrong** and have to go, or `apply(to:)` will
    ///   clear those cells and then write last round's numbers straight back into them.
    /// - ``clearedSpills`` keeps the *earliest* region seen — the one actually on the sheet —
    ///   while ``spills`` keeps the latest. That pair is what lets `apply(to:)` clear exactly
    ///   "what the sheet has and the result does not".
    mutating func absorb(_ pass: RecalcResult, regions: inout [SheetCell: CellRange]) -> [SheetCell: CellRange] {
        var reshaped: [SheetCell: CellRange] = [:]

        for (anchor, region) in pass.spills where regions[anchor] != region {
            reshaped[anchor] = region
        }
        for (anchor, old) in pass.clearedSpills where pass.spills[anchor] == nil {
            reshaped[anchor] = old
        }

        for (anchor, old) in pass.clearedSpills {
            let survives = pass.spills[anchor]
            for ref in old where SheetCell(sheet: anchor.sheet, ref: ref) != anchor {
                if let survives, survives.contains(ref) { continue }
                values.removeValue(forKey: SheetCell(sheet: anchor.sheet, ref: ref))
            }
        }

        values.merge(pass.values) { _, latest in latest }
        stale.merge(pass.stale) { _, latest in latest }
        circular.formUnion(pass.circular)
        visited.formUnion(pass.visited)
        evaluatedCount += pass.evaluatedCount
        spills.merge(pass.spills) { _, latest in latest }
        // First one wins: the sheet's own region is what has to be cleared.
        clearedSpills.merge(pass.clearedSpills) { existing, _ in existing }

        for (anchor, region) in pass.spills { regions[anchor] = region }
        for anchor in pass.clearedSpills.keys where pass.spills[anchor] == nil {
            regions.removeValue(forKey: anchor)
        }
        // A cell that computed cleanly this round is no longer stale, whatever an earlier round
        // thought — otherwise `apply(to:)` would set the flag on a value we just computed.
        for cell in pass.values.keys where pass.stale[cell] == nil { stale.removeValue(forKey: cell) }
        return reshaped
    }

    /// Writes the result into a workbook.
    ///
    /// Cells in ``stale`` keep their values and gain ``CellFlags/staleCache``; cells we
    /// computed lose it. A stale flag is never cleared by guessing — only by a later pass that
    /// actually managed to compute the cell.
    ///
    /// Order matters and is not an implementation detail: **old spill regions are cleared
    /// before new values are written.** A region that shrank shares cells with the one that
    /// replaces it, so clearing afterwards would erase the fresh result.
    public func apply(to workbook: inout Workbook) {
        var touched: Set<SheetID> = []
        touched.formUnion(values.keys.map(\.sheet))
        touched.formUnion(stale.keys.map(\.sheet))
        touched.formUnion(circular.map(\.sheet))
        touched.formUnion(spills.keys.map(\.sheet))
        touched.formUnion(clearedSpills.keys.map(\.sheet))

        for sheetID in touched {
            try? workbook.withSheet(sheetID) { sheet in
                clearOldSpills(on: sheetID, in: &sheet)
                writeValues(on: sheetID, in: &sheet)
                markSpills(on: sheetID, in: &sheet)
            }
        }
    }

    /// Empties the cells an anchor used to own and no longer does.
    private func clearOldSpills(on sheetID: SheetID, in sheet: inout Sheet) {
        for (anchor, old) in clearedSpills where anchor.sheet == sheetID {
            sheet.arrayFormulaRanges.removeValue(forKey: anchor.ref)
            let survives = spills[anchor]
            for ref in old where ref != anchor.ref {
                if let survives, survives.contains(ref) { continue }
                guard var cell = sheet.cells[ref],
                      cell.flags.contains(.spilledInto) || cell.flags.contains(.arrayFormula)
                else { continue }
                // The formatting is the user's, not the formula's, so it stays behind. Only a
                // cell that is now indistinguishable from an absent one is actually removed.
                cell.value = .empty
                cell.formula = nil
                cell.flags.subtract([.spilledInto, .arrayFormula, .spillAnchor, .staleCache, .uncomputed])
                if cell.isBlank {
                    sheet.cells.removeCell(at: ref)
                } else {
                    try? sheet.cells.setCell(cell, at: ref)
                }
            }
        }
    }

    private func writeValues(on sheetID: SheetID, in sheet: inout Sheet) {
        for (target, value) in values where target.sheet == sheetID {
            // A spilled-into cell may not exist yet, so this creates rather than skips.
            var cell = sheet.cells[target.ref] ?? Cell()
            cell.value = value
            cell.flags.subtract([.staleCache, .uncomputed])
            try? sheet.cells.setCell(cell, at: target.ref)
        }
        for target in circular where target.sheet == sheetID {
            guard var cell = sheet.cells[target.ref] else { continue }
            cell.value = .error(.circular)
            try? sheet.cells.setCell(cell, at: target.ref)
        }
        for (target, reason) in stale where target.sheet == sheetID {
            guard var cell = sheet.cells[target.ref] else { continue }
            cell.flags.insert(.staleCache)
            switch reason {
            case .function, .syntax: cell.flags.insert(.unsupportedFormula)
            case .externalWorkbook: cell.flags.insert(.externalLink)
            case .threeDimensionalReference, .staleInput: break
            }
            // **The honesty rule with nothing to be honest about.** `staleCache` says "keep
            // the number Excel computed"; when the producer never wrote one, keeping it means
            // showing an empty cell, which reads as "this is blank" rather than "we cannot
            // compute this". Once set, the flag is sticky until a pass actually computes the
            // cell — otherwise the second pass would see a placeholder instead of a blank and
            // conclude there was a cached value after all.
            if cell.value == .empty || cell.flags.contains(.uncomputed) {
                cell.value = .error(reason.placeholderError)
                cell.flags.insert(.uncomputed)
            }
            try? sheet.cells.setCell(cell, at: target.ref)
        }
    }

    private func markSpills(on sheetID: SheetID, in sheet: inout Sheet) {
        for (anchor, region) in spills where anchor.sheet == sheetID {
            sheet.arrayFormulaRanges[anchor.ref] = region
            if var cell = sheet.cells[anchor.ref] {
                cell.flags.insert([.spillAnchor, .arrayFormula])
                cell.flags.remove(.spilledInto)
                try? sheet.cells.setCell(cell, at: anchor.ref)
            }
            for ref in region where ref != anchor.ref {
                guard var cell = sheet.cells[ref] else { continue }
                cell.flags.insert([.spilledInto, .arrayFormula])
                cell.flags.remove(.spillAnchor)
                try? sheet.cells.setCell(cell, at: ref)
            }
        }
    }
}

/// Parse, depend, evaluate.
///
/// **The shape A8 calls:**
/// ```swift
/// var engine = FormulaEngine(workbook: workbook)
/// engine.setFormula("SUM(A1:A9)", at: SheetCell(sheet: id, ref: target), in: workbook)
/// let result = engine.recalculate(in: workbook, changed: [SheetCell(sheet: id, ref: edited)])
/// result.apply(to: &workbook)
/// ```
///
/// `Sendable`, with no shared mutable state and no actor: everything a pass needs is created
/// inside ``recalculate(in:changed:)`` and dies with it, so a pass runs happily on a background
/// task while the main actor draws the previous frame.
///
/// The recalc walk is **iterative** end to end — closure, topological sort, and evaluation all
/// use explicit stacks. A 50,000-cell chain is 50,000 array appends, not 50,000 stack frames.
public struct FormulaEngine: Sendable {
    /// Clock, epoch, seed and grammar for this engine.
    public var options: EvaluationOptions

    /// The dependency graph. Exposed so A8 can ask "what does this cell feed?" for the
    /// trace-precedents affordance.
    public private(set) var graph: DependencyGraph

    /// Builds an engine and a graph over every formula in `workbook`.
    public init(workbook: Workbook, options: EvaluationOptions? = nil) {
        let resolved = options ?? EvaluationOptions.forWorkbook(workbook)
        self.options = resolved
        graph = DependencyGraph(workbook: workbook, grammar: resolved.grammar)
    }

    /// An engine with no graph, for one-shot evaluation.
    public init(options: EvaluationOptions = EvaluationOptions()) {
        self.options = options
        graph = DependencyGraph()
    }

    // MARK: - Editing

    /// Records a formula edit so the graph stays in step with the workbook.
    ///
    /// Pass `nil` to say the cell no longer holds a formula. Returns `false` when the formula
    /// does not parse — the caller should refuse the edit, per PLAN.md §8.
    @discardableResult
    public mutating func setFormula(_ source: String?, at cell: SheetCell, in workbook: Workbook) -> Bool {
        guard let source else {
            graph.removeFormula(at: cell)
            return true
        }
        return graph.setFormula(source, at: cell, in: workbook, grammar: options.grammar)
    }

    /// Rebuilds the whole graph, for when a sheet was inserted, deleted, or renamed.
    public mutating func rebuild(from workbook: Workbook) {
        graph = DependencyGraph(workbook: workbook, grammar: options.grammar)
    }

    // MARK: - Evaluation

    /// Evaluates one formula in place, without touching the graph.
    ///
    /// This is the "what would this give?" call: the formula bar's live preview, an MCP dry
    /// run, a test.
    public func evaluate(
        _ source: String, at cell: SheetCell, in workbook: Workbook
    ) -> CellOutcome {
        do {
            let expression = try FormulaParser.parse(source, anchor: cell.ref, grammar: options.grammar)
            return evaluate(expression, at: cell, in: workbook)
        } catch {
            return .value(.error(.unknownName))
        }
    }

    /// Evaluates an already-parsed formula.
    public func evaluate(
        _ expression: FormulaExpression, at cell: SheetCell, in workbook: Workbook
    ) -> CellOutcome {
        let scope = EvaluationScope(workbook: workbook, options: options)
        return FormulaEngine.evaluate(expression, at: cell, scope: scope)
    }

    private static func evaluate(
        _ expression: FormulaExpression, at cell: SheetCell, scope: EvaluationScope
    ) -> CellOutcome {
        switch evaluateRaw(expression, at: cell, scope: scope) {
        case let .unsupported(reason):
            return .keepCached(reason)
        case let .value(value):
            // The one-shot API answers "what would this cell say?", so an array collapses to
            // its top-left the way the anchor of a spill renders. Whether it *spills* is a
            // question about the sheet, and only `recalculate` is in a position to answer it.
            return .value(FormulaEngine.reduced(value, at: cell, scope: scope))
        }
    }

    /// A value collapsed to what a single cell holds.
    ///
    /// The failure carries its own token: a lambda that was never applied is `#CALC!`, and a
    /// multi-cell reference that intersects nothing is `#VALUE!`. Flattening both to `#VALUE!`
    /// would tell the user the wrong thing about which mistake they made.
    private static func reduced(
        _ value: FormulaValue, at cell: SheetCell, scope: EvaluationScope
    ) -> CellValue {
        do {
            return try FunctionCallSite.reduce(value, at: cell, scope: scope).cellValue
        } catch let fault as FormulaFault {
            guard case let .cell(error) = fault else { return .error(.calculation) }
            return .error(error)
        } catch {
            return .error(.wrongType)
        }
    }

    /// What a formula produced, before deciding what to do with it.
    private enum RawOutcome {
        case value(FormulaValue)
        case unsupported(UnsupportedReason)
    }

    private static func evaluateRaw(
        _ expression: FormulaExpression, at cell: SheetCell, scope: EvaluationScope
    ) -> RawOutcome {
        let evaluator = FormulaEvaluator(scope: scope, origin: cell)
        do {
            return .value(try evaluator.evaluate(expression))
        } catch let fault as FormulaFault {
            switch fault {
            case let .cell(error): return .value(.error(error))
            case let .unsupported(reason): return .unsupported(reason)
            }
        } catch {
            return .value(.error(.wrongType))
        }
    }

    /// Recalculates everything downstream of `changed`.
    ///
    /// `changed` is the set of cells whose values the caller has **already** written into
    /// `workbook`. The engine works out the transitive closure, orders it, and evaluates only
    /// that — plus, by default, the volatile cells, which have to run every pass because their
    /// precedents are computed rather than written.
    ///
    /// - Parameter includingVolatile: pass `false` for a keystroke-time preview. `NOW()` and
    ///   `RAND()` genuinely change on every pass, so recomputing them while the user is still
    ///   typing costs work and makes the screen flicker for no benefit. Pass `true` on commit.
    public func recalculate(
        in workbook: Workbook, changed: Set<SheetCell>, includingVolatile: Bool = true
    ) -> RecalcResult {
        converge(from: changed, includingVolatile: includingVolatile, in: workbook)
    }

    /// Recalculates every formula in the workbook, in dependency order.
    public func recalculateAll(in workbook: Workbook) -> RecalcResult {
        converge(from: Set(graph.formulaCells), includingVolatile: true, in: workbook)
    }

    /// How many times a pass may re-run because a spill changed shape.
    ///
    /// Four is generous. One round settles a spill whose region nobody knew yet, a second
    /// settles a spill fed by that one, and a workbook that needs more than that has spills
    /// feeding spills feeding spills — at which point stopping and reporting what we have
    /// beats looping. Excel's own engine iterates for the same reason.
    static let maximumSpillRounds = 4

    /// Runs passes until no spill changes shape.
    ///
    /// # Why one pass is not enough
    ///
    /// A formula that reads `C3` depends on whichever anchor spills into `C3` — but on the
    /// first pass over a freshly opened workbook *nothing* has spilled yet, so there is no
    /// region to look the anchor up in, no edge, and no ordering constraint. The reader can be
    /// scheduled before the anchor and see a blank.
    ///
    /// The fix is not to guess the shape in advance — it is a result, and guessing it is how
    /// you get a wrong number. It is to notice that a region appeared or changed, and re-run
    /// the formulas that read it. Rounds after the first are seeded only with those readers,
    /// so the common case (no spills at all) costs one comparison and stops.
    private func converge(
        from seeds: Set<SheetCell>, includingVolatile: Bool, in workbook: Workbook
    ) -> RecalcResult {
        var regions = knownRegions(in: workbook)
        var accumulated = RecalcResult()
        var nextSeeds = seeds
        var volatile = includingVolatile

        for round in 0 ..< FormulaEngine.maximumSpillRounds {
            guard !nextSeeds.isEmpty else { break }
            let plan = schedule(from: nextSeeds, includingVolatile: volatile, regions: regions)
            let pass = run(plan, in: workbook, carrying: accumulated, regions: regions)
            let reshaped = accumulated.absorb(pass, regions: &regions)
            guard round + 1 < FormulaEngine.maximumSpillRounds, !reshaped.isEmpty else { break }
            nextSeeds = readers(of: reshaped)
            volatile = false
        }
        return accumulated
    }

    /// The spill and array regions the workbook already records.
    private func knownRegions(in workbook: Workbook) -> [SheetCell: CellRange] {
        var result: [SheetCell: CellRange] = [:]
        for sheet in workbook.sheets {
            for (anchor, region) in sheet.arrayFormulaRanges {
                result[SheetCell(sheet: sheet.id, ref: anchor)] = region
            }
        }
        return result
    }

    /// Every formula that reads any cell of a region that just changed shape.
    private func readers(of reshaped: [SheetCell: CellRange]) -> Set<SheetCell> {
        var result: Set<SheetCell> = []
        for (anchor, region) in reshaped {
            result.formUnion(graph.dependents(intersecting: SheetRange(sheet: anchor.sheet, range: region)))
            result.formUnion(graph.dependents(of: anchor))
        }
        return result
    }

    /// What the formula at `cell` reads.
    public func precedents(of cell: SheetCell) -> [Dependency] { graph.precedents(of: cell) }

    /// Every formula that reads `cell` directly.
    public func dependents(of cell: SheetCell) -> Set<SheetCell> { graph.dependents(of: cell) }

    /// Whether the formula at `cell` recomputes on every pass.
    public func isVolatile(at cell: SheetCell) -> Bool { graph.volatileCells.contains(cell) }

    /// Every cell that recomputes on every pass.
    public var volatileCells: Set<SheetCell> { graph.volatileCells }

    // MARK: - Scheduling

    private struct Plan {
        var order: [SheetCell] = []
        var circular: Set<SheetCell> = []
        var dirty: Set<SheetCell> = []
    }

    /// Dirty closure, then Kahn's algorithm over the induced subgraph.
    ///
    /// Building the edge list *during* the closure is what keeps this linear in the size of the
    /// dirty set rather than in the size of the graph: we never look at a node that is not
    /// downstream of the change.
    private func schedule(
        from seeds: Set<SheetCell>, includingVolatile: Bool, regions: [SheetCell: CellRange]
    ) -> Plan {
        var plan = Plan()
        var edges: [SheetCell: [SheetCell]] = [:]
        var inDegree: [SheetCell: Int] = [:]
        var expanded: Set<SheetCell> = []
        var frontier: [SheetCell] = []

        for seed in seeds where plan.dirty.insert(seed).inserted {
            frontier.append(seed)
        }
        if includingVolatile {
            for cell in graph.volatileCells where plan.dirty.insert(cell).inserted {
                frontier.append(cell)
            }
        }

        while let node = frontier.popLast() {
            guard expanded.insert(node).inserted else { continue }
            for dependent in dependents(of: node, regions: regions) where dependent != node {
                edges[node, default: []].append(dependent)
                inDegree[dependent, default: 0] += 1
                if plan.dirty.insert(dependent).inserted { frontier.append(dependent) }
            }
        }

        // A self-referential cell (`A1: =A1+1`) has no edge to itself above, so catch it here.
        for cell in plan.dirty where graph.formula(at: cell)?.dependencies.cells.contains(cell) == true {
            plan.circular.insert(cell)
        }

        var ready = plan.dirty
            .filter { inDegree[$0, default: 0] == 0 && !plan.circular.contains($0) }
            .sorted()
        var cursor = 0
        while cursor < ready.count {
            let node = ready[cursor]
            cursor += 1
            plan.order.append(node)
            for dependent in edges[node] ?? [] {
                guard let remaining = inDegree[dependent] else { continue }
                inDegree[dependent] = remaining - 1
                if remaining - 1 == 0, !plan.circular.contains(dependent) { ready.append(dependent) }
            }
        }

        // Anything Kahn could not reach is in a cycle or downstream of one. Both are cells
        // whose value we cannot know, and saying so beats Excel's silent `0`.
        let scheduled = Set(plan.order)
        for cell in plan.dirty where !scheduled.contains(cell) {
            plan.circular.insert(cell)
        }
        return plan
    }

    private func run(
        _ plan: Plan,
        in workbook: Workbook,
        carrying accumulated: RecalcResult,
        regions: [SheetCell: CellRange]
    ) -> RecalcResult {
        let scope = EvaluationScope(workbook: workbook, options: options)
        scope.circular = plan.circular
        // Earlier rounds' values shadow the workbook, so a re-run reader sees the spill that
        // caused the re-run rather than the blank that was there before it.
        scope.overlay = accumulated.values
        scope.unsupported = accumulated.stale
        var result = RecalcResult()
        result.circular = plan.circular
        var placed: [PlacedRegion] = []
        for (anchor, region) in regions where accumulated.spills[anchor] == region {
            placed.append(PlacedRegion(anchor: anchor, region: region))
        }

        for cell in plan.circular where graph.formula(at: cell) != nil {
            result.visited.insert(cell)
        }

        for cell in plan.order {
            guard let compiled = graph.formula(at: cell) else { continue }
            result.visited.insert(cell)

            if let reason = compiled.dependencies.unsupported {
                scope.unsupported[cell] = reason
                result.stale[cell] = reason
                continue
            }
            if let blocker = firstUnsupportedPrecedent(of: compiled.dependencies, in: scope) {
                let reason = UnsupportedReason.staleInput(blocker)
                scope.unsupported[cell] = reason
                result.stale[cell] = reason
                continue
            }

            result.evaluatedCount += 1
            switch FormulaEngine.evaluateRaw(compiled.expression, at: cell, scope: scope) {
            case let .value(value):
                place(
                    value, at: cell, scope: scope, regions: regions,
                    in: workbook, result: &result, placed: &placed
                )
            case let .unsupported(reason):
                // **The old region stays.** We could not compute this formula, so we do not
                // know what shape its result is — and clearing the region would delete the
                // cached values of a legacy array formula we merely failed to re-evaluate.
                // Keeping them is the same promise `staleCache` makes for a single cell.
                scope.unsupported[cell] = reason
                result.stale[cell] = reason
            }
        }
        return result
    }

    // MARK: - Spilling

    /// A region already claimed during this pass, which blocks anything that overlaps it.
    private struct PlacedRegion {
        var anchor: SheetCell
        var region: CellRange
    }

    /// Writes one formula's result, spilling it when it is an array of more than one cell.
    ///
    /// # Why a *reference* does not spill
    ///
    /// `=A1:A10` written in a cell spills in Excel 365 and reduces by implicit intersection in
    /// every version before it. OpenSheets keeps implicit intersection for a bare reference and
    /// spills computed arrays. That is a deliberate divergence, and this is the reasoning: the
    /// files that contain a bare multi-cell reference in a cell are old ones, written when
    /// intersection was the only meaning, and their cached values say so. Spilling them would
    /// overwrite the neighbours of every such cell in a file we merely opened.
    private func place(
        _ value: FormulaValue,
        at cell: SheetCell,
        scope: EvaluationScope,
        regions: [SheetCell: CellRange],
        in workbook: Workbook,
        result: inout RecalcResult,
        placed: inout [PlacedRegion]
    ) {
        let previous = regions[cell]
        guard case let .array(array) = value, !array.isSingle else {
            let stored = FormulaEngine.reduced(value, at: cell, scope: scope)
            scope.overlay[cell] = stored
            result.values[cell] = stored
            if let previous { result.clearedSpills[cell] = previous }
            return
        }

        guard let region = spillRegion(from: cell.ref, rows: array.rowCount, columns: array.columnCount),
              !isBlocked(region, anchor: cell, previous: previous, scope: scope, in: workbook, placed: placed)
        else {
            scope.overlay[cell] = .error(.spill)
            result.values[cell] = .error(.spill)
            if let previous { result.clearedSpills[cell] = previous }
            return
        }

        for row in 0 ..< array.rowCount {
            for column in 0 ..< array.columnCount {
                let target = SheetCell(
                    sheet: cell.sheet,
                    row: cell.ref.row + row,
                    column: cell.ref.column + column
                )
                let stored = array[row, column].cellValue
                scope.overlay[target] = stored
                result.values[target] = stored
            }
        }
        result.spills[cell] = region
        if let previous, previous != region { result.clearedSpills[cell] = previous }
        placed.removeAll { $0.anchor == cell }
        placed.append(PlacedRegion(anchor: cell, region: region))
    }

    /// The rectangle a result of this shape would occupy, or `nil` when it runs off the sheet.
    private func spillRegion(from anchor: CellRef, rows: Int, columns: Int) -> CellRange? {
        let lastRow = anchor.row + rows - 1
        let lastColumn = anchor.column + columns - 1
        guard Limits.isValidRow(lastRow), Limits.isValidColumn(lastColumn) else { return nil }
        return CellRange(start: anchor, end: CellRef(row: lastRow, column: lastColumn))
    }

    /// Excel's `#SPILL!` rules, in the order Excel applies them.
    ///
    /// A cell blocks if it holds **anything** — a value, a formula, or a merge — with three
    /// exceptions that are not exceptions at all once stated: the anchor itself, the cells this
    /// same anchor spilled into last time (they are about to be overwritten), and a cell whose
    /// only content is formatting. A blank-but-styled cell is not content, and treating it as
    /// content would make `#SPILL!` fire on every sheet with a formatted column.
    private func isBlocked(
        _ region: CellRange,
        anchor: SheetCell,
        previous: CellRange?,
        scope: EvaluationScope,
        in workbook: Workbook,
        placed: [PlacedRegion]
    ) -> Bool {
        guard let sheet = workbook[anchor.sheet] else { return true }
        guard region.cellCount <= ArrayFunctions.maximumResultCells else { return true }

        // A merge inside the region has no single cell to write into, and Excel refuses too.
        if sheet.merges.contains(where: { $0.intersects(region) && $0.cellCount > 1 }) { return true }

        // Another anchor got there first. Its cells may not be in the store yet — it may have
        // spilled in this very pass — so this cannot be found by looking at the sheet.
        for other in placed
            where other.anchor != anchor && other.anchor.sheet == anchor.sheet
            && other.region.intersects(region) {
            return true
        }

        var blocked = false
        sheet.cells.forEachCell(in: region) { ref, stored in
            guard !blocked, ref != anchor.ref else { return }
            if let previous, previous.contains(ref) { return }
            let target = SheetCell(sheet: anchor.sheet, ref: ref)
            let value = scope.overlay[target] ?? stored.value
            if stored.formula != nil || value != .empty { blocked = true }
        }
        return blocked
    }

    /// Everything a change at `node` invalidates, **including through a spill**.
    ///
    /// A formula that reads `B3` where `B3` is a cell some anchor spilled into does not depend
    /// on `B3` in any way the graph can see: nothing wrote a formula there. It depends on the
    /// anchor, because the anchor is what puts a value in `B3` and what decides whether `B3` is
    /// still inside the region at all. So a change at an anchor invalidates every reader of
    /// every cell the anchor owns — which is also what puts the anchor *before* those readers
    /// in the topological order, so they read the fresh values rather than last pass's.
    private func dependents(of node: SheetCell, regions: [SheetCell: CellRange]) -> Set<SheetCell> {
        var result = graph.dependents(of: node)
        guard let region = regions[node] else { return result }
        result.formUnion(graph.dependents(intersecting: SheetRange(sheet: node.sheet, range: region)))
        return result
    }

    /// The first precedent we already gave up on, if any.
    ///
    /// This is the honesty rule propagating: if an input could not be recomputed, this cell's
    /// inputs are unknown, so its own value is unknown too. Computing it anyway from the stale
    /// cached input would produce a number that looks fresh and is not.
    private func firstUnsupportedPrecedent(
        of dependencies: FormulaDependencies, in scope: EvaluationScope
    ) -> SheetCell? {
        guard !scope.unsupported.isEmpty else { return nil }
        for (cell, _) in scope.unsupported.sorted(by: { $0.key < $1.key }) {
            if dependencies.cells.contains(cell) { return cell }
            if dependencies.ranges.contains(where: { $0.contains(cell) }) { return cell }
        }
        return nil
    }
}
