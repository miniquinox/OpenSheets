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

    /// Whether the pass changed nothing.
    public var isEmpty: Bool { values.isEmpty && stale.isEmpty && circular.isEmpty }

    /// The outcome for one cell.
    public func outcome(for cell: SheetCell) -> CellOutcome? {
        if let reason = stale[cell] { return .keepCached(reason) }
        if let value = values[cell] { return .value(value) }
        return nil
    }

    /// Writes the result into a workbook.
    ///
    /// Cells in ``stale`` keep their values and gain ``CellFlags/staleCache``; cells we
    /// computed lose it. A stale flag is never cleared by guessing — only by a later pass that
    /// actually managed to compute the cell.
    public func apply(to workbook: inout Workbook) {
        var byCellSheet: [SheetID: [(CellRef, CellValue?, UnsupportedReason?)]] = [:]
        for (cell, value) in values {
            byCellSheet[cell.sheet, default: []].append((cell.ref, value, nil))
        }
        for cell in circular {
            byCellSheet[cell.sheet, default: []].append((cell.ref, .error(.circular), nil))
        }
        for (cell, reason) in stale {
            byCellSheet[cell.sheet, default: []].append((cell.ref, nil, reason))
        }
        for (sheet, updates) in byCellSheet {
            try? workbook.withSheet(sheet) { target in
                for (ref, value, reason) in updates {
                    guard var cell = target.cells[ref] else { continue }
                    if let value {
                        cell.value = value
                        cell.flags.remove(.staleCache)
                    }
                    if let reason {
                        cell.flags.insert(.staleCache)
                        if case .function = reason { cell.flags.insert(.unsupportedFormula) }
                        if case .syntax = reason { cell.flags.insert(.unsupportedFormula) }
                        if case .externalWorkbook = reason { cell.flags.insert(.externalLink) }
                    }
                    try? target.cells.setCell(cell, at: ref)
                }
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
        let evaluator = FormulaEvaluator(scope: scope, origin: cell)
        do {
            let value = try evaluator.evaluate(expression)
            return .value(try FunctionCallSite.reduce(value, at: cell, scope: scope).cellValue)
        } catch let fault as FormulaFault {
            switch fault {
            case let .cell(error): return .value(.error(error))
            case let .unsupported(reason): return .keepCached(reason)
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
        let plan = schedule(from: changed, includingVolatile: includingVolatile)
        return run(plan, in: workbook)
    }

    /// Recalculates every formula in the workbook, in dependency order.
    public func recalculateAll(in workbook: Workbook) -> RecalcResult {
        let plan = schedule(from: Set(graph.formulaCells), includingVolatile: true)
        return run(plan, in: workbook)
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
    private func schedule(from seeds: Set<SheetCell>, includingVolatile: Bool) -> Plan {
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
            for dependent in graph.dependents(of: node) where dependent != node {
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

    private func run(_ plan: Plan, in workbook: Workbook) -> RecalcResult {
        let scope = EvaluationScope(workbook: workbook, options: options)
        scope.circular = plan.circular
        var result = RecalcResult()
        result.circular = plan.circular

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
            switch FormulaEngine.evaluate(compiled.expression, at: cell, scope: scope) {
            case let .value(value):
                scope.overlay[cell] = value
                result.values[cell] = value
            case let .keepCached(reason):
                scope.unsupported[cell] = reason
                result.stale[cell] = reason
            }
        }
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
