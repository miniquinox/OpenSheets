# SheetModel change requests

`SheetModel` is frozen after Wave 0 (PLAN.md §13.1). Seven agents compile against it at once.

If you need a change: **append an entry here, work around it in your own target, and keep going.**
The integrator (A10) batches approved changes between waves.

Format:

```
## [A<n>] <short title>
**Needed for:** <what you're building>
**Proposed change:** <exact type/signature>
**Workaround in use:** <what you did instead>
**Breaks:** <who else this affects, if you can tell>
```

---

## [A2] `CT_Worksheet` ordering is missing `legacyDrawing` and `legacyDrawingHF`
**Needed for:** splicing unmodelled sheet-level elements back in schema order (addendum §1).
**Proposed change:** insert `"legacyDrawing", "legacyDrawingHF"` into
`SheetFragment.worksheetChildOrder` between `"drawing"` and `"drawingHF"`, and add both to
`SheetFragment.capturedElements`.
**Why it matters:** `<legacyDrawing r:id="…"/>` is the pointer from a sheet to the VML that
positions its cell comments. It is present in `passthrough/comments.xlsx` and
`passthrough/kitchen-sink.xlsm`, and both sidecars list it under
`sheetLevelElementsThatMustSurvive`. With the current list, `schemaOrder(for: "legacyDrawing")`
falls through to the unknown-element slot, which sorts it **after** `<tableParts>` — a violated
`CT_Worksheet` sequence, which Excel "repairs" by discarding the element. The comments then
survive as a perfectly preserved `xl/comments1.xml` that nothing points at. It is also absent
from `capturedElements`, so a reader that follows that list drops it outright.
**Workaround in use:** `SheetFormat/XLSX/Write/WorksheetChildOrder.swift` derives a corrected
ordering *from* `SheetFragment.worksheetChildOrder` at load time (never a retyped copy) and
inserts the two names. `SurgicalWriteTests.theCorrectionIsActuallyNeeded` fails the moment the
model gains them, which is the signal to delete the local table.
**Breaks:** nobody. A1 should add both to what it captures; the writer's byte-level salvage
covers it either way.

## [A2] A rich-text cell cannot record which `sharedStrings` entry it came from
**Needed for:** re-emitting a `t="s"` cell that points at an `<si>` with formatting runs.
**Proposed change:** `Cell.sharedStringIndex: Int32?`, set by the reader for `t="s"` cells.
**Why it matters:** the reader flattens `<si><r><t>Hello</t></r><r><rPr><b/></rPr><t>World</t></r></si>`
to `"HelloWorld"` and sets `CellFlags.richText`. The model then has no way back to index 2, and
a writer that appends a fresh plain entry silently deletes the bold half.
**Workaround in use:** the writer indexes the existing table by *flattened* text and reuses the
matching index, so an unedited rich-text cell round-trips exactly. A cell whose text was actually
edited finds no match and gets a plain entry, which is correct. The gap is a rich-text cell whose
flattened text collides with a different plain entry earlier in the table — it would re-point at
the plain one and lose its runs.
**Breaks:** nobody; `Cell` grows by 4 bytes.

## [A2] Nowhere to keep `<c>`'s `cm`/`vm` metadata attributes or a shared-formula group
**Needed for:** rewriting a sheet without degrading dynamic-array and shared-formula cells.
**Proposed change:** `Cell.metadataIndex: (cell: Int32, value: Int32)?` and
`Sheet.sharedFormulaGroups: [Int: (master: CellRef, range: CellRange)]`.
**Workaround in use:** `cm`/`vm` are dropped when the sheet they live in is rewritten (they are
untouched on every sheet that is not). Shared formulas are expanded by the reader and re-emitted
as ordinary per-cell `<f>`, which Excel accepts and recalculates identically — the file just gets
larger.
**Breaks:** nobody.

## [A2] `Limits.defaultRowHeight`/`defaultColumnWidth` are display defaults, not Excel's
**Needed for:** deciding whether `<sheetFormatPr>` may be regenerated from the model.
**Proposed change:** either rename these to `displayDefaultRowHeight`/`displayDefaultColumnWidth`,
or add `Sheet.fileDefaultRowHeight`/`fileDefaultColumnWidth` holding what the part actually said.
**Why it matters:** `Limits.defaultRowHeight` is 24 pt because 15 pt is cramped on Retina
(PLAN.md §3.4). `Sheet.defaultRowHeight` defaults to it. A writer that regenerates
`<sheetFormatPr>` from the model therefore writes `defaultRowHeight="24"` into a file that said
`15`, and every row in the workbook gets 60% taller the next time it opens in Excel.
**Workaround in use:** the writer **never** regenerates `<sheetFormatPr>`, `<cols>` or
`<sheetViews>` for a sheet that has an original part unless the caller explicitly says that
region changed (`SheetRegionChanges`). They are copied verbatim instead.
**Breaks:** nobody.

## [A2] `DirtyPartSet` has no per-sheet region granularity
**Needed for:** telling the writer *which elements inside* `sheetN.xml` may be rebuilt.
**Proposed change:** promote `SheetFormat.SheetRegionChanges` and `SheetFormat.WorkbookEditTracker`
into `SheetModel` next to `DirtyPartSet`, since A8 and A9 both hold one and pass it across the
same boundary `DirtyPartSet` already crosses.
**Workaround in use:** both types live in `SheetFormat/XLSX/Write/DirtyTracking.swift` and wrap
`DirtyPartSet` rather than replacing it, so promoting them later is a move, not a rewrite.
**Breaks:** nobody today; A8 and A9 import `SheetFormat` already.

## [A7] `A1Notation.parse` cannot parse a defined name's `refersTo`
**Needed for:** resolving `DefinedName.target` from the text a real xlsx stores, in
`TestSupport.WorkbookBuilder.definedName(_:refersTo:scope:isHidden:)`.
**Proposed change:** route `CellRange.init?(a1:)` through `CellRef.parseA1(_:)` and discard the
anchor flags, or add `A1Notation.parseAllowingAnchors(_:)` that does.
**Why it matters:** `CellRef.init(a1:)` rejects `$` deliberately and documents why — anchoring is
a property of a reference in a formula, not of an address — and that is right. But
`CellRange.init?(a1:)` and therefore `A1Notation.parse(_:)` both go through it, so
`A1Notation.parse("Budget!$A$1:$A$3")` returns `nil`. Every defined name in a real workbook is
written with anchors: `Fixtures/formulas/defined-names.xlsx.expected.json` stores exactly
`"Revenue": "Budget!$A$1:$A$3"`. Any caller resolving a `refersTo` string into a
`RangeReference` — A1 on read, A9 on the MCP `resolve_name` path — hits this immediately, and the
failure mode is silent: `target` stays `nil` and the name looks unresolvable rather than
unparseable.
**Workaround in use:** `WorkbookBuilder` strips `$` before calling `A1Notation.parse` and keeps the
original text in `DefinedName.formula`, which is the field that round-trips.
**Breaks:** nobody. `CellRef.init(a1:)` keeps its current strictness; only the range-level and
sheet-qualified entry points widen.

## [A1] `NumberFormat.builtInCode(id:)` spells built-ins 39 and 40 with a space the spec does not
**Needed for:** `Fixtures/formats/builtin-numfmts.xlsx`, whose whole purpose is the implicit table.
**Proposed change:** in `NumberFormat.builtInCode(id:)`, change
`case 39: "#,##0.00 ;(#,##0.00)"` → `"#,##0.00;(#,##0.00)"` and
`case 40: "#,##0.00 ;[Red](#,##0.00)"` → `"#,##0.00;[Red](#,##0.00)"`.
**Why it matters:** ECMA-376 §18.8.30 gives the trailing space to ids **37 and 38 only**; 39 and
40 have none. A7's sidecar encodes the spec exactly, and the corpus disagrees with the model on
those two ids and no others. The space is not cosmetic — it reserves the width of a closing
parenthesis so positives line up with parenthesised negatives — so a column formatted with id 39
renders one character wider than Excel renders it.
**Workaround in use:** none in the reader, deliberately. The obvious workaround — seeding
`StyleTable.customNumberFormats[39]` with the correct code — would hand the writer a *custom*
format carrying a reserved id, which is illegal in the file and a worse bug than the space. The
two cells are recorded as a named waiver in
`SheetFormatTests/Read/XLSXReadFixtureTests.KnownModelDeviation`, which prints them on every run
and will start failing the moment the codes agree, which is the signal to delete it.
**Breaks:** nobody. The `numFmtId` round-trips either way; only the resolved code changes.

## [A1] Nothing exposes "used range including merges", which is what the corpus means by it
**Needed for:** every sidecar's `usedRange` (addendum §5), and for any UI that draws a selection.
**Proposed change:** either widen `Sheet.formattedExtent` to union `merges`, or add
`Sheet.contentExtent` that does.
**Why it matters:** the addendum says a merge extends the used range even where the covered cells
have no `<c>` element, and names `structure/merged-cells.xlsx` — 4 cells, used range `A1:F8`. The
model offers `usedRange` (cells only → `A1:F5`) and `formattedExtent` (cells plus whole-row and
whole-column *formatting* bands → also `A1:F5`, because a merge is neither). Neither answers the
question, so every call site has to remember to fold the merges in by hand, and the one that
forgets is silently wrong in a way nobody notices until a merged block prints clipped.
**Workaround in use:** `SheetFormat.WorksheetReader.contentExtent(of:)`, which is what the read
tests assert against and which agrees with `TestSupport.WorkbookMatcher.mergeAwareUsedRange` —
two independent local copies of the same three lines, which is the smell this entry is about.
**Breaks:** nobody; `formattedExtent` only ever grows.

## [A1] `<autoFilter>`'s filter criteria have nowhere to live
**Needed for:** round-tripping a sheet that has an active filter rather than just a filtered range.
**Proposed change:** add `"autoFilter"` to `SheetFragment.capturedElements` and drop
`Sheet.autoFilter` to a derived read-only value, **or** add
`Sheet.autoFilterCriteria: [SheetFragment]`.
**Why it matters:** `Sheet.autoFilter` is a `CellRange?`, but `<autoFilter>` legally contains
`<filterColumn>` children carrying the actual criteria — which values are hidden, the sort state,
custom predicates. A writer that regenerates `<autoFilter ref="…"/>` from the model keeps the
range and silently clears every filter the author set. The element cannot simply be captured as a
fragment today because it *is* modelled, and emitting both the fragment and the modelled element
produces two `<autoFilter>` children, which Excel repairs by discarding them.
**Workaround in use:** the reader models the `ref` and does **not** capture the element, matching
`SheetFragment.capturedElements` exactly. Nothing is lost *today* because A2's writer salvages
`<autoFilter>` out of the original part's bytes rather than regenerating it from the model — but
that only holds while an original part exists. A sheet built in-app, or one whose autofilter
region is explicitly marked changed, falls back to the model and loses the criteria.
**Breaks:** A2, which would need to prefer the fragment over the modelled range on the paths where
byte salvage is not available.

## [A1] `Hyperlink` cannot carry `<hyperlink>`'s `display` attribute
**Needed for:** re-emitting `<hyperlink ref="A1" r:id="rId1" display="Click here"/>` unchanged.
**Proposed change:** `Hyperlink.display: String?`.
**Why it matters:** `<hyperlinks>` is modelled rather than captured (it has to be — capturing it
as well as modelling it would emit it twice), so everything in the element that is not on
`Hyperlink` is lost on a rewrite. `display` is the only such attribute, and Excel writes it
whenever the visible text differs from the target.
**Workaround in use:** none in the reader. A2's writer copies `<hyperlinks>` verbatim out of the
original bytes, so a workbook read from disk keeps it; a sheet with no original part, or one whose
hyperlinks are explicitly marked changed, drops the attribute. The cell's own text is unaffected,
so the visible result is usually identical.
**Breaks:** nobody.

## [A4] `StyleTable.numberFormat(id:)` re-parses a built-in format on every call
**Needed for:** drawing a screenful of cells inside an 8.3 ms frame budget.
**Proposed change:** memoise the built-in codes — `NumberFormat.builtIn(id:)` returning a cached
`NumberFormat` rather than `NumberFormat(builtInCode(id:))` — or have `StyleTable` intern the
resolved format per `numFmtId` on first use.
**Why it matters:** ids 0–49 are implicit in xlsx and are stored as *strings*, so
`numberFormat(id:)` constructs `NumberFormat(code)` and runs `FormatScanner` every time it is
asked. That is the correct answer and a surprising cost: the renderer asks once per visible cell
per frame, which was six hundred runs of a format parser at 120 Hz. It was the single largest item
in the draw loop, and nothing in the API's documentation hints that the call is expensive — the
neighbouring `subscript(id:)` is an array index.
**Workaround in use:** `GridRenderer` caches a `ResolvedStyle` per `StyleID` holding the
`CellStyle`, the `NumberFormat` and the resolved font key, invalidated when the style table, the
theme or the zoom changes. Measured 9 ms → 4 ms p99 with this and three smaller changes.
**Breaks:** nobody — memoising is behaviour-preserving. Every other consumer that formats in a
loop (A9's MCP `describe`, A2's writer, the inspector) has the same trap waiting for it.

## [A4] `CellStore`'s row-axis navigation cannot be used for `⌘`-arrow
**Needed for:** Excel's `⌘↓` semantics on a million-cell sheet.
**Proposed change:** either a cached `sortedRowIndices()` on `CellStore` (invalidated on write),
or a column-axis walker — `func rows(inColumn:)` returning the populated rows ascending.
**Why it matters:** `firstNonEmptyRow(inColumn:atOrAfter:)` is documented as O(populated rows),
with the note that it is "the right trade for a keystroke and the wrong one for a frame". The
trouble is that one keystroke is not one call. `⌘↓` from inside a contiguous block has to find the
far end of that block, which by that API means one O(n) call per row, so a single keystroke is
O(rows²) — minutes on a sheet with 20,000 populated rows, not milliseconds.
**Workaround in use:** `GridKit.DataBlockIndex` builds the ascending row list for a column once,
via `forEachCell(in: .entireColumn(c))` — which *is* efficient, because it walks populated rows —
and caches the last sixteen axes. Every `⌘`-arrow after that is a binary search
(`DataBlockNavigator`). The index is invalidated wholesale on any cell change.
**Breaks:** nobody. Worth noting that the efficient primitive already exists (`forEachCell`); what
is missing is the documentation pointing at it, since the obviously-named method is the trap.

## [A4] No model type for a multi-range selection
**Needed for:** `⌘`-click multi-range selection, and for handing a selection to A3, A8 and A9.
**Proposed change:** promote something like `GridKit.GridSelection` — ranges, active cell, anchor —
into `SheetModel`, or at least a `MultiRange` value type.
**Why it matters:** a spreadsheet selection is not a `CellRange`. Formatting, delete, copy and
"apply this formula" all operate on a list of ranges plus an active cell, and every layer that
touches a selection needs the same three fields. Today `GridKit` owns the only definition, so A8
and A9 either import `GridKit` — which drags AppKit into the MCP server — or invent their own.
**Workaround in use:** `GridSelection` lives in `GridKit` and is a plain `Sendable` value type with
no AppKit in its signature, so it can move to `SheetModel` unchanged if this is accepted.
**Breaks:** nobody today; it is additive.
