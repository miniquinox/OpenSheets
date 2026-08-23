# Wave 1 addendum — corrections to PLAN.md and to your brief

**Every Wave 1 agent must read this.** It records what Wave 0 discovered, and it **overrides**
PLAN.md and your individual brief wherever they disagree.

Wave 0 produced two things: agent A0's frozen `SheetModel`, and agent A7's 85-fixture corpus. A7
built its fixtures by reading the real OOXML spec and cross-checking against two independent
engines, and in doing so found several places where PLAN.md was wrong or underspecified. Those are
fixed below. The model amendment is already implemented and merged — you are coding against the
corrected model, not the one in PLAN.md §5.1.

---

## 1. Passthrough at the ZIP-part level is not enough — `SheetFragment` (AFFECTS A1, A2)

**The bug this prevents:** you edit one cell; the save drops the one-line `<drawing r:id="rId1"/>`
from `sheetN.xml`; `chart1.xml` survives byte-perfect but is now orphaned; Excel declares the
workbook damaged and discards the chart. PLAN.md §5.2's "copy unmodelled ZIP entries through
verbatim" cannot prevent this, because these elements live **inside the one part the writer
re-emits**.

The affected elements — all children of `CT_Worksheet`, all inside `xl/worksheets/sheetN.xml`:
`sheetPr` · `sheetProtection` · `protectedRanges` · `scenarios` · `sortState` · `dataConsolidate` ·
`customSheetViews` · `phoneticPr` · `conditionalFormatting` · `dataValidations` · `printOptions` ·
`pageMargins` · `pageSetup` · `headerFooter` · `rowBreaks` · `colBreaks` · `customProperties` ·
`cellWatches` · `ignoredErrors` · `smartTags` · `drawing` · `drawingHF` · `picture` · `oleObjects` ·
`controls` · `webPublishItems` · `tableParts` · `extLst`

**The fix, already in the model:** `Sheet.sheetLevelFragments: [SheetFragment]`, see
`Sources/SheetModel/SheetFragment.swift`.

- **A1 (reader):** capture each element in `SheetFragment.capturedElements` **verbatim** — original
  prefixes, original attribute order, no re-escaping, no normalisation — into
  `sheet.sheetLevelFragments`. A byte you "cleaned up" is a byte that no longer matches the producer.
- **A2 (writer):** splice them back using `fragments.inSchemaOrder`. `CT_Worksheet` is a *sequence*,
  not a choice: emit these out of order and Excel silently repairs the file by discarding them.
  `SheetFragment.worksheetChildOrder` is the authoritative ordering and includes the elements you
  serialise yourself, so interleave modelled output and fragments against that one list.

A7's `passthrough/` sidecars carry a `sheetLevelElementsThatMustSurvive` list per fixture. Assert
against it.

---

## 2. Do not inflate entries nobody asked for (AFFECTS A1)

`Fixtures/hostile/zip-bomb-nested.xlsx` parks a 1030:1 bomb in `xl/media/payload.zip` while the
workbook itself is perfectly valid. **It must open successfully.**

An eager "cap total decompressed bytes across the archive" check rejects a legitimate file. The
correct behaviour — and the one that makes `OpaqueParts` work anyway — is to keep every entry's
*compressed* bytes and inflate only the parts you actually parse. Caps apply per-entry, at inflate
time, to entries you chose to read.

Related: `hostile/lying-uncompressed-size.xlsx` declares 10 GB in a ZIP64 extra field on a 120-byte
entry. Pre-allocating from a declared size is a denial of service before a single byte is inflated,
so **validate the declared size against the cap too, not just the actual one.** This also means
**ZIP64 parsing is required on the read side** — PLAN.md only mentions it for the writer.

---

## 3. `_xlfn.` — stored function names differ from display names (AFFECTS A1, A2, A3)

OOXML stores newer functions with an `_xlfn.` prefix: `_xlfn.IFS`, `_xlfn.SWITCH`, `_xlfn.CONCAT`,
`_xlfn.TEXTJOIN`, `_xlfn.XLOOKUP`, `_xlfn.MAXIFS`, `_xlfn.MINIFS`, `_xlfn.STDEV.P`, `_xlfn.STDEV.S`.

- **A3:** map the prefix both ways in the lexer/serialiser. The user types `XLOOKUP`; the file says
  `_xlfn.XLOOKUP`.
- **A2:** re-emit the prefix. Write a bare `XLOOKUP` and Excel shows `#NAME?`.
- `Fixtures/formulas/functions.xlsx` contains all nine.

---

## 4. Excel and LibreOffice disagree about error kinds (AFFECTS A3)

Measured divergence: `SQRT(-1)` → `#NUM!` in Excel but `#VALUE!` in LibreOffice;
`OFFSET($Z$1,-100,0)` → `#REF!` in Excel but `#VALUE!` in LibreOffice.

**Excel's semantics are the target.** A7's corpus deliberately only uses formulas both engines agree
on, so a green corpus does *not* prove your error kinds are right — cover the divergent cases in
your own `functions.tsv` table tests, following Excel.

Also: writing the literal text `#N/A` or `#DIV/0!` into a cell produces an **error value, not text**.
This affects A2's CSV import and A9's MCP write path. Leading `'` forces text.

---

## 5. `usedRange` is wider than "cells that hold values" (AFFECTS A1, A4)

A merge extends the used range even where the covered cells have no `<c>` element at all
(`Fixtures/structure/merged-cells.xlsx`: 4 cells, used range `A1:F8`). Style-only valueless cells
extend it too — that is how "column D is formatted as currency" survives when column D is empty.

The model gives you both: `Sheet.usedRange` (cells only) and `Sheet.formattedExtent` (including
formatting). Pick deliberately per call site and say which you meant.

`<dimension>` remains untrustworthy — it is wrong or absent on purpose in three fixtures. It is a
capacity hint, nothing more. `Sheet.declaredDimension` keeps it only so a passthrough write can
re-emit it.

---

## 6. Error codes: A0's `SheetError` is the source of truth (AFFECTS A1)

A7 wrote `Fixtures/hostile/expected-errors.json` against a proposed naming scheme before A0's enum
existed, so the two do not match exactly (`zip.entryNameTraversal` vs the real `zip.pathTraversal`,
and so on). **A0's `SheetError` wins** — it is the frozen model.

A1 owns the reconciliation: update `expected-errors.json` to the real `SheetError.code` strings as
part of your work. That file is yours to edit for this purpose only. Every hostile fixture must map
to a real case; if a case is genuinely missing from the enum, log it in
`MODEL-CHANGE-REQUESTS.md` and use the closest existing one meanwhile.

---

## 7. Cell text ceiling is 32,767, not 32,768 (already correct in the model)

`Limits.maxCellTextLength = 32_767`. A7 split the case into an accepted 32,763-char fixture and a
rejected 40,000-char one.

---

## 8. Perf assertions must survive a loaded machine (AFFECTS A7, and anyone writing one)

Seven agents are building on this Mac concurrently. A wall-clock assertion that passes on an idle
machine flakes under that load — I saw exactly one such flake in Wave 0. Give timing tests headroom,
or measure work done rather than seconds elapsed. A flaky perf gate gets ignored, and an ignored
gate is worse than no gate.

---

## 9. Working agreement for Wave 1

- **Do not run any `git` command.** Seven agents share this working directory; the git index is a
  shared resource and concurrent `git add`/`commit` corrupts other agents' work. Write files only.
  The orchestrator commits between waves.
- Stay strictly inside the files your brief lists as yours. A1 and A2 share the `MiniZip` and
  `SheetFormat` targets but own disjoint files — respect that boundary exactly.
- `SheetModel` is frozen. Log needs in `MODEL-CHANGE-REQUESTS.md`, work around them locally, keep going.
- `swift build && swift test` must pass when you finish, with zero warnings.
- Everything you need from Wave 0 is already on disk: read `Sources/SheetModel/` for the real API
  rather than trusting PLAN.md §5.1's sketch, and `Fixtures/README.md` for the corpus.

---

## 10. `legacyDrawing` — added mid-wave (AFFECTS A1, A2)

*Found by A2 during Wave 1; the model is already fixed. Re-read `SheetFragment.swift`.*

`legacyDrawing` and `legacyDrawingHF` were missing from both `worksheetChildOrder` and
`capturedElements`. `CT_Worksheet` places them between `drawing` and `drawingHF`; absent from the
order they fell into the unknown-element slot and sorted after `tableParts`, violating the sequence,
and absent from the capture list a reader would drop them entirely.

`<legacyDrawing r:id="…"/>` is the sheet's pointer to the VML that positions its **comments**, so
losing it orphans every comment in the workbook. It appears in `Fixtures/passthrough/comments.xlsx`
and `Fixtures/passthrough/kitchen-sink.xlsm`.

`SheetModelTests` now asserts that **no** element in `capturedElements` can fall into the
unknown slot, so this class of bug cannot recur silently.

## 11. Column-width units have one owner (AFFECTS A1)

A2 exposed `XLSXColumnMetrics.points(fromCharacters:)` / `.characters(fromPoints:)` publicly in
`Sources/SheetFormat/XLSX/Write/WorksheetPartWriter.swift`. **A1 must call these rather than writing
its own inverse.** Excel's "characters of the normal font" unit is an approximation either way; two
independent approximations means every save nudges every column width, and the drift compounds.
