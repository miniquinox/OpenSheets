# A3 — Formula engine

**Wave 1 · parallel with A1, A2, A4–A7 · blocked by A0.**

## Mission
Lex, parse, and evaluate spreadsheet formulas, with an incremental dependency graph. Read
PLAN.md §5.3 first — **the scope is deliberately smaller than you think**, because xlsx ships
cached results and we only evaluate what someone actually edits.

Your hardest requirement is not function coverage. It is **being honest when you can't compute
something** instead of returning a plausible wrong number.

## Dependencies
A0 merged. Nothing else. You operate on `Workbook`/`Sheet`/`CellStore` values — pure, no I/O.

## Files you own
```
Packages/OpenSheetsCore/Sources/SheetFormula/**
Packages/OpenSheetsCore/Tests/SheetFormulaTests/**
Packages/OpenSheetsCore/Tests/SheetFormulaTests/Resources/functions.tsv   ← the table-test corpus
```

## Files you must NOT touch
Everything else. In particular do not add convenience helpers to `SheetModel` — request them in
`MODEL-CHANGE-REQUESTS.md` and use a local extension in your own target meanwhile.

## Build this

### 1. Lexer + parser → AST
Full Excel expression grammar: numbers (incl. scientific), strings (`""` escaping), booleans,
error literals (`#DIV/0!` …), references (`A1`, `$A$1`, `A1:B9`, `Sheet2!A1`, `'My Sheet'!A1:B2`,
`[1]Ext!A1`, whole-column `A:A`, whole-row `1:1`), defined names, function calls with a locale-aware
argument separator, unary `-`/`+`/`%`, binary `^ * / + - & = <> < > <= >=`, the intersection space
operator and the union `,` operator, and parenthesised subexpressions. **Correct precedence and
associativity**, verified by tests, including `-2^2 == -4` and `2^3^2 == 512`.

Also support R1C1 in and out (needed for shared-formula expansion and for the MCP surface).

### 2. Reference algebra
`ReferenceTransform`: shifting refs when rows/columns are inserted or deleted, absolute vs relative
handling, `#REF!` generation when a target is deleted, and relative-offset translation when a
formula is copied. This is used by A8 (paste, fill-down) and A9 (MCP insert/delete), so it must be
a clean public API and it must be exhaustively tested.

### 3. Dependency graph + incremental recalc
- `precedents(of:)` / `dependents(of:)` built from the parsed ASTs.
- Range dependencies must not explode: a `SUM(A:A)` dependency is stored as a **range**, and
  invalidation is a range-overlap query (use an interval structure, not 1M edges).
- Recalc = dirty set → transitive closure → topological order → evaluate. Cycles detected and
  reported as `#CIRCULAR` on the participating cells; **never hang, never stack-overflow** (iterative
  evaluation, explicit stack — a 50,000-deep chain must work).
- `volatile` functions (`NOW`, `TODAY`, `RAND`, `OFFSET`, `INDIRECT`) recompute every pass and are
  flagged so A8 can avoid recalculating on every keystroke.

### 4. Functions (~120) — the list in PLAN.md §5.3
Implement with Excel's coercion rules, not Swift's: text→number coercion, boolean arithmetic
(`TRUE+1 == 2`), empty-cell-as-zero-but-not-as-empty-string, error propagation (the *first* error
in argument order wins), and `#VALUE!` where Excel gives `#VALUE!`.

Anything outside the list: **parse it, keep the cached value, mark the cell `.unsupportedFormula`.**
Do not approximate. Do not return `0`.

### 5. Number semantics
IEEE 754 double, but match Excel's display rounding at 15 significant digits and its
"cosmetic rounding" near zero (`0.1+0.2-0.3` must display as `0`). Date arithmetic in serial days
honouring the workbook's epoch, passed in — do not assume 1900.

## Acceptance criteria
- [ ] `functions.tsv` table test: ≥ 600 rows of `formula ⇥ expectedValue ⇥ note`, covering every
      implemented function's happy path, at least one error path each, and the coercion cases above.
      All green.
- [ ] Precedence suite green, including `-2^2`, `2^3^2`, `1&2&3`, intersection `A1:B5 B1:C5`.
- [ ] Cycle test: a 3-cell cycle yields `#CIRCULAR` on all three; a 50,000-cell dependency chain
      evaluates without stack overflow in < 200 ms.
- [ ] Incremental recalc benchmark: changing one cell with 10,000 transitive dependents recalcs in
      < 200 ms and touches **only** those dependents (assert the visited-set size).
- [ ] `SUM(A:A)` over a sheet with 1M rows does not build 1M graph edges (assert edge count).
- [ ] Reference-shift suite: insert/delete row and column above/below/inside a range, absolute and
      relative, cross-sheet, `#REF!` generation. ≥ 60 cases.
- [ ] Unsupported functions round-trip: parsed, flagged, cached value preserved, never overwritten.
- [ ] Engine is `Sendable` and evaluates off the main actor. Zero strict-concurrency warnings.

## Report back
The public API A8 will call (`recalc(workbook:dirty:) -> [CellRef: CellValue]` or whatever shape you
land on), the exact function list you shipped, and which Excel behaviours you knowingly diverge from.
