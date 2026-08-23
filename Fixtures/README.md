# Fixtures — the golden corpus

**85 fixtures** — 82 committed (2.7 MB total, no Git LFS anywhere) plus 3 large ones generated
on demand. This is the spec in executable form: if a fixture is wrong, six agents ship the same
bug confidently. Each of the 62 non-hostile fixtures has a `<filename>.expected.json` sidecar
describing the correct parse; each of the 23 hostile files has an entry in
[`hostile/expected-errors.json`](hostile/expected-errors.json) naming the `SheetError.code` it
must produce.

```
Scripts/.venv/bin/python Scripts/gen-fixtures.py --all   # rebuild everything
python3 Scripts/validate-fixtures.py                     # check every sidecar (stdlib only)
python3 Scripts/validate-fixtures.py --load-test         # + open each one in LibreOffice (~90 s)
```

`validate-fixtures.py` runs 1,751 assertions. `--load-test` adds one more that nothing else can
give you: a hand-authored OOXML part can satisfy every assertion in the script and still be a
file no spreadsheet will open. All 43 xlsx/xlsm fixtures pass it today, which is how
`passthrough/pivot-table.xlsx` is known to be a *real* pivot table (LibreOffice imports it as a
`data-pilot-table`) rather than plausible-looking XML.

## How the ground truth is established

A sidecar that only restates what the generator wrote proves nothing. So:

| `valuesVerifiedBy` | What it means |
| --- | --- |
| `LibreOffice … recalculation …` | The fixture was written with **no cached values**. Headless LibreOffice had to evaluate every formula to render the sheet and wrote the results back on save. The `<v>` next to each `<f>` is a real engine's answer, not ours. |
| `hand-authored raw OOXML …` | Every byte of the part was written deliberately. The file *is* the expectation; the sidecar restates it in model terms and `validate-fixtures.py` proves they agree. |
| `openpyxl authoring …` | Literal values only — no evaluation was involved, so there is nothing to be wrong about. |

`validate-fixtures.py` never imports the generator, never uses `openpyxl`, and reads each fixture
as a plain ZIP with `xml.etree`. It resolves parts through the relationship graph rather than
assuming `xl/worksheets/sheet1.xml`, which is also how A1 must do it.

### Sidecar schema

```jsonc
{
  "file": "formulas/functions.xlsx",
  "kind": "xlsx",                    // or "csv"
  "proves": "…",                     // why this file exists
  "valuesVerifiedBy": "…",
  "dateSystem": 1900,                // or 1904
  "sheets": [{
    "name": "Calc", "index": 1, "visibility": "visible",
    "dimension": "A1:B69",           // as declared in the file; null when absent
    "usedRange": "A1:B69",           // COMPUTED: union of every cell AND every merge
    "merges": [], "frozen": null, "split": null,
    "columnWidths": {}, "rowHeights": {}, "hyperlinks": {},
    "cells": { "B1": { "type": "number", "value": 210.0,
                       "formula": "SUM(Data!A1:A6)", "numberFormat": "General",
                       "flags": ["externalLink"] } }
  }],
  "definedNames": {},
  "passthroughEntries": [],          // ZIP entries A2 must not touch
  "zipEntries": {},                  // sha256 + crc32 of every entry
  "skipChecks": ["cellValue:Volatile!B1"]
}
```

`"type"` is a `SheetModel.CellValue` case: `number` · `text` · `boolean` · `error` · `empty`.
`"value": null` with a non-`empty` type means *a value must exist, its content is not asserted*
(used for `TODAY()`). `"numberFormat"` is the **resolved** OOXML format code — built-in ids are
already expanded — and is omitted where it is not being asserted.

---

## `basic/` — the floor

| File | What it proves |
| --- | --- |
| `basic/minimal.xlsx` | The smallest legal workbook: one sheet, one numeric cell. |
| `basic/multi-sheet.xlsx` | Sheet order, naming and per-sheet used ranges are independent. |
| `basic/empty-workbook.xlsx` | A sheet with zero cells yields `usedRange == nil`, not a crash and not a 1×1 range. |
| `basic/formatting-only.xlsx` | Cells carrying only a style (no `<v>`, no `<f>`) are `.empty` but still occupy the used range — skip them and the dimension is wrong. |
| `basic/types.xlsx` | Every `CellValue` case and every cell type code `t` (absent / `s` / `inlineStr` / `b` / `e`), plus `Double.greatestFiniteMagnitude` in OOXML scientific notation. |

## `formulas/` — evaluation, references, errors

| File | What it proves |
| --- | --- |
| `formulas/functions.xlsx` | All 69 functions from PLAN §5.3 evaluated once each, results cached by LibreOffice. Column A names the function; column B is it. **Formula text carries the `_xlfn.` prefix** for every post-2007 function. |
| `formulas/volatile.xlsx` | `TODAY()`/`NOW()` parse and cache a value that must *not* be asserted against a constant — the corpus cannot pin a clock. |
| `formulas/cross-sheet.xlsx` | References across sheets, including a sheet whose name needs single-quoting (`'Far Away'!A1`). |
| `formulas/defined-names.xlsx` | Workbook-scoped defined names resolve inside formulas and survive as ranges. |
| `formulas/error-formulas.xlsx` | All seven error kinds arising from real evaluation, cached as `t="e"`. The formulas were chosen because Excel and LibreOffice agree on them — they disagree on many others. |
| `formulas/cached-errors.xlsx` | A literal cached error with **no `<f>` at all**. Excel writes these after a delete; a reader that only creates errors from formulas drops them. |
| `formulas/shared-formulas.xlsx` | `<f t="shared" ref="B1:B8" si="0">` plus seven empty followers must expand to per-cell text with refs translated (`B3` is `A3*2`, not `A1*2`). |
| `formulas/array-formulas.xlsx` | CSE array formulas: a `ref="D1:D3"` master whose other cells carry only `<v>`, plus a single-cell array. Writing those back as constants breaks the array on the next Excel open. |
| `formulas/circular-reference.xlsx` | A 2-cell cycle and a self-reference must yield `#CIRCULAR`, never a hang. Reading is unaffected — it is recalc that must detect it. |
| `formulas/external-link.xlsx` | `[1]Sheet1!A1` must set the `.externalLink` flag and must **never** be resolved or fetched. The link target is a `file:///` URL that does not exist. |
| `formulas/operator-precedence.xlsx` | **Excel's grammar is not the mathematical one.** `=-2^2` is `4` (unary minus binds tighter than `^`) and `=2^3^2` is `64` (`^` is left-associative). 31 formulas covering `^`/unary minus/`%`/`&`/comparison/range operators, every one evaluated by LibreOffice and cross-checked against Excel's documented answer. Two comparison cases where the engines genuinely disagree are present in the file but carry **no asserted value** — see `enginesDisagree` in the sidecar. |

## `formats/` — number formats and the two date epochs

| File | What it proves |
| --- | --- |
| `formats/builtin-numfmts.xlsx` | The ~25 **implicit** `numFmtId`s that never appear in `<numFmts>`. Without the hardcoded table every one renders as General. |
| `formats/custom-numfmts.xlsx` | 17 custom codes: negative-in-red, currency, percent, scientific, accounting alignment, conditional sections, elapsed time, `@`. |
| `formats/dates-1900.xlsx` | The 1900 epoch. Column A is the wall-clock date as text, column B the serial. |
| `formats/dates-1904.xlsx` | The 1904 epoch, same wall-clock dates. The two files **must render identically**. The offset between the epochs is **not constant**: −1461 below serial 60 and −1462 at or above it, because serial 60 in the 1900 system is the phantom 1900-02-29. Rows 1–2 sit below the boundary and rows 3–6 above it, so a flat shift fails here in both directions. |
| `formats/serial-60-lotus-bug.xlsx` | Serial 60 is 1900-02-29, a date that never happened. Any conversion that does not special-case serials ≤ 60 is a day out for all of Jan/Feb 1900. |
| `formats/text-format.xlsx` | `numFmt @` forces text: `0012` keeps its leading zeros and `=1+1` stays a string, on read *and* on re-save. |

## `structure/` — geometry, panes, sheet identity

| File | What it proves |
| --- | --- |
| `structure/merged-cells.xlsx` | Horizontal, rectangular and vertical merges. Only the anchor carries a value; the covered cells are absent from the XML — yet they still extend `usedRange`. |
| `structure/frozen-panes.xlsx` | `<pane xSplit=2 ySplit=1 state="frozen">`. |
| `structure/split-panes.xlsx` | The **same element**, no `state`, and `xSplit`/`ySplit` are twentieths of a point, not counts. Reading them as counts gives a 2130-column freeze. |
| `structure/merge-across-frozen-boundary.xlsx` | A merge crossing the freeze in both axes — the renderer must clip per pane, not draw it four times. |
| `structure/hidden-sheets.xlsx` | `visible` / `hidden` / `veryHidden`. `veryHidden` is the one most libraries silently drop on save. |
| `structure/col-widths-row-heights.xlsx` | Sparse widths including a run over all 16,384 columns and a hidden column; per-row heights; and a `<dimension>` that is deliberately wider than the real data. |
| `structure/sheet-names-unicode.xlsx` | Emoji, RTL Arabic, exactly 31 chars, `Report` **and** `report`, and a double space. Sheet lookup must be case-sensitive and ordinal. |
| `structure/out-of-order-rows.xlsx` | Rows *and* cells out of order with `<dimension>` absent entirely. Assume monotonic `r` and this is wrong. |
| `structure/rich-text.xlsx` | Multi-run rich text and `xml:space="preserve"`. Runs flatten to plain text; trimming the whitespace is a silent data change that survives every later save. |
| `structure/hyperlinks.xlsx` | External `http`, `file://`, internal-location links and a `HYPERLINK()` formula. All four inert until clicked. |
| `structure/long-cell-32k.xlsx` | A 32,763-character cell — just under Excel's 32,767 limit, so it must be **accepted**. Hostile twin: `hostile/cell-40k-chars.xlsx`. |

## `passthrough/` — the group that keeps the writer honest

These exist purely to prove A2's surgical writer destroys nothing. Each sidecar carries a
`zipEntries` map (sha256 + crc32 of every entry) and a `passthroughEntries` list.

> **Contract.** After `read → modify one cell of the first sheet → write`, every entry in
> `passthroughEntries` must be byte-identical to the original. Only `xl/worksheets/sheet1.xml`,
> `xl/sharedStrings.xml` and `xl/calcChain.xml` may differ. Assert **per entry**, not with a
> whole-file hash.

| File | What it proves |
| --- | --- |
| `passthrough/chart.xlsx` | A real column chart. `xl/charts/chart1.xml`, `xl/drawings/drawing1.xml` and their rels survive byte-identical. |
| `passthrough/image.xlsx` | An embedded PNG. `xl/media/image1.png` must be copied as already-deflated bytes — re-encoding changes the file for no reason. |
| `passthrough/conditional-format.xlsx` | Four rule kinds, including a data bar written **twice** (legacy `<cfRule>` and modern `<x14:conditionalFormatting>` in `<extLst>`). Drop either and the rule disappears in some Excel versions. |
| `passthrough/data-validation.xlsx` | List, integer-range, date and custom-formula validations. Losing them silently removes a guardrail the author put there on purpose. |
| `passthrough/comments.xlsx` | `xl/comments1.xml` + the VML that positions them. Separate parts, but the `<legacyDrawing r:id>` pointer inside the sheet is not — drop it and the comments orphan. |
| `passthrough/macros.xlsm` | `xl/vbaProject.bin` survives byte-identical and is **never executed** (§7.3). Synthetic OLE2/CFB container, not compiled VBA — inert test data. |
| `passthrough/pivot-table.xlsx` | A pivot over `Data!A1:B5` with its cache definition and cached records. All four pivot parts pass through untouched. |
| `passthrough/kitchen-sink.xlsm` | Chart + image + conditional format + data validation + comment + table/autofilter + sheet protection + hyperlink + header/footer + print setup + frozen panes + VBA, on one sheet. Survive this and you survive real workbooks. |
| `passthrough/unknown-extension.xlsx` | An `mc:AlternateContent` block and a vendor `<ext>` inside `<extLst>`, neither of which appears in `SheetFragment.capturedElements` or in any other list. **This one proves the rule rather than the list**: capture every unmodelled direct child of `<worksheet>`, in read order, or Excel calls the file damaged on the next save. A list-driven reader passes every other fixture here and fails this. |

### The trap this group exists to expose

`<conditionalFormatting>`, `<dataValidations>`, `<autoFilter>`, `<sheetProtection>`,
`<pageMargins>`, `<pageSetup>`, `<printOptions>`, `<headerFooter>`, `<drawing>`,
`<legacyDrawing>`, `<hyperlinks>`, `<extLst>`, `<tableParts>` and `<phoneticPr>` all live
**inside `xl/worksheets/sheetN.xml`** — the one part the writer re-emits. They are therefore
*not* passthrough-able. A2 must model them or splice the original fragments back in verbatim.
Each affected sidecar lists the elements it actually contains under
`sheetLevelElementsThatMustSurvive`, and `validate-fixtures.py` asserts they really are there.

## `csv/` — dialects, encodings, injection

| File | What it proves |
| --- | --- |
| `csv/comma-lf.csv` | The baseline: comma, LF, trailing newline, no quoting. |
| `csv/semicolon-crlf.csv` | European dialect — semicolon delimiter, CRLF, **comma as the decimal separator**. Sniffing `,` here splits `10,5` into two columns. |
| `csv/tab.tsv` | Tab-separated; RFC 4180 quoting still applies. |
| `csv/pipe.csv` | Pipe — the fourth delimiter candidate. |
| `csv/cr-only.csv` | Bare CR line endings. Splitting on `\n` yields one giant row. |
| `csv/quoted-newlines.csv` | LF **and** CRLF inside quoted fields. A line-based reader corrupts this. |
| `csv/doubled-quotes.csv` | RFC 4180 `""` escaping, including a fully-quoted field. |
| `csv/ragged-rows.csv` | Rows of 3, 3, 2, 1 and 5 fields. Short rows pad, long rows widen the sheet; neither is an error, but the ragged count is reported. |
| `csv/bom-utf8.csv` | A UTF-8 BOM that must be consumed, not delivered as part of the first field name. |
| `csv/utf16le.csv` | UTF-16LE with BOM — every ASCII char has a NUL second byte. |
| `csv/utf16be.csv` | UTF-16BE with BOM — the byte order the BOM must actually be read for. |
| `csv/windows-1252.csv` | Bytes that are genuinely invalid UTF-8, no BOM. The reader must fall back **and say so**. |
| `csv/no-trailing-newline.csv` | The last line has no terminator; a reader that requires one drops the final row. |
| `csv/formula-injection.csv` | `=`, `+`, `-`, `@`, TAB and CR payloads including `=cmd|…`. Inert on import; prefixed with `'` on export (§7.3). |
| `csv/empty.csv` | Zero bytes. Opens as an empty sheet — no failure, no hang. |
| `csv/header-only.csv` | One row, no data; `usedRange` is `A1:C1`. |

## `perf/` — the budget gates (PLAN §10.6)

| File | Committed? | What it proves |
| --- | --- | --- |
| `perf/100k-cells.xlsx` | yes | 100,000 cells. Open → first paint < 800 ms. |
| `perf/wide-16384-cols.xlsx` | yes | All 16,384 columns × 5 rows. Width/style lookup stays O(1) per cell; `RunLengthArray` must not allocate 16,384 doubles. |
| `perf/single-cell-at-XFD1048576.xlsx` | yes | One cell at the last legal address. `usedRange` is enormous, the sheet holds **one** cell — anything allocating per-cell over the used range dies here. |
| `perf/1m-cells.xlsx` | **no** (git-ignored) | 1,000,000 cells: < 4 s, < 600 MB RSS. |
| `perf/2gb.csv` | **no** (git-ignored) | A 2 GB CSV opening in < 200 MB RSS — proof the reader streams instead of slurping. |
| `perf/single-line-10m.csv` | **no** (git-ignored) | A single 10,000,000-character field. A quadratic string append here takes minutes. |

Regenerate the three large ones with:

```
Scripts/.venv/bin/python Scripts/gen-fixtures.py perf --with-huge
```

They are deliberately not committed (`.gitignore`), which keeps the whole corpus at ~2.6 MB and
means **no Git LFS is needed anywhere in this repo.**

## `hostile/` — deliberately malformed input

Every file here is broken on purpose, none of it is ever executed, and each one must be rejected
with a specific `SheetError` — no crash, no hang, bounded memory. Ground truth and the exact
codes live in [`hostile/expected-errors.json`](hostile/expected-errors.json); run this suite
under ASan with a 2 s per-case timeout.

<!-- BEGIN hostile-table: generated from hostile/expected-errors.json by
     `Scripts/gen-fixtures.py --sync-readme`. Do not edit the code column by hand —
     Scripts/validate-fixtures.py fails if it drifts from the JSON. -->

| File | Expected `SheetError.code` | What it proves |
| --- | --- | --- |
| `hostile/zip-bomb.xlsx` | `zip.bomb.ratio` <br>or `zip.bomb.entry` / `zip.bomb.total` | `sheet1.xml` inflates ~1030:1 to 200 MB. The ratio cap must fire **during** inflation. |
| `hostile/zip-bomb-nested.xlsx` | *(none — must succeed)* | A two-level bomb parked in `xl/media/`. The workbook is valid, so the correct behaviour is to open it and **never inflate that entry**. |
| `hostile/xxe-external-entity.xlsx` | `xml.doctype` <br>or `xml.externalEntity` | External entities pointing at `/etc/passwd` and at localhost. Neither may be resolved. |
| `hostile/billion-laughs.xlsx` | `xml.doctype` <br>or `xml.malformed` | Nine levels of 10× entity expansion — `&lol9;` is 10⁹ characters. |
| `hostile/dtd-doctype.xlsx` | `xml.doctype` | A harmless DOCTYPE. The policy must be blanket, not a heuristic that greps for `SYSTEM`. |
| `hostile/path-traversal.xlsx` | `zip.pathTraversal` | `../../../../etc/passwd` and the Windows `\..\` form as entry names. |
| `hostile/absolute-path-entry.xlsx` | `zip.pathTraversal` | `/etc/passwd` and `C:\Windows\…` as entry names. |
| `hostile/nul-in-entry-name.xlsx` | `zip.pathTraversal` | An embedded NUL so a C-string API sees a different name than the zip index does. |
| `hostile/duplicate-entries.xlsx` | `zip.duplicateEntry` | Two `sheet1.xml` entries with different content. Whichever you pick, another tool picks the other. |
| `hostile/truncated.xlsx` | `zip.truncated` <br>or `zip.malformed` | The first 55% of a valid xlsx — what a file caught mid-write looks like (§9). Must be a clean, retryable error. |
| `hostile/not-a-zip.xlsx` | `zip.malformed` <br>or `zip.truncated` | A PDF renamed `.xlsx`. Trust the magic bytes, never the extension. |
| `hostile/encrypted.xlsx` | `workbook.encrypted` <br>or `workbook.unsupportedFormat` | An OLE2/CFB container advertising `EncryptedPackage` — must read as "password protected", not "corrupt". |
| `hostile/entry-count-bomb.xlsx` | `zip.entryCount` | 12,004 entries. Enforce while reading the central directory, not after building the table. |
| `hostile/lying-uncompressed-size.xlsx` | `zip.bomb.entry` <br>or `zip.truncated` / `zip.bomb.ratio` | A ~120-byte entry whose ZIP64 header declares 10 GB. Reject on the declared size *before* allocating, then verify the actual length. |
| `hostile/crc-mismatch.xlsx` | `zip.checksumMismatch` | A wrong stored CRC32 on a modelled part — otherwise the writer copies the bad bytes straight back out. |
| `hostile/unsupported-compression-method.xlsx` | `zip.unsupportedCompression` | Method 99 (AES). Only store (0) and deflate (8) occur in OOXML. |
| `hostile/dimension-4-billion-rows.xlsx` | `workbook.dimensionOutOfRange` <br>or `ref.outOfRange` / `ref.invalid` | `<dimension>` claims 2³² rows and a row sits at `r=4294967295` — which also overflows a signed 32-bit parse to −1. |
| `hostile/deep-nesting-100k.xlsx` | `xml.depth` | 100,000 levels of nesting: stack overflow for a recursive parser, 100k nodes for a DOM one. |
| `hostile/cell-40k-chars.xlsx` | `cell.textTooLong` | 40,000 characters, past Excel's 32,767 ceiling. Accepted twin: `structure/long-cell-32k.xlsx`. |
| `hostile/nul-bytes-in-string.xlsx` | `xml.invalidEncoding` <br>or `xml.malformed` | Raw NUL, BEL and vertical tab inside `<t>` — all illegal in XML 1.0 — plus the legal `_x0000_` escaped form. |
| `hostile/missing-workbook-part.xlsx` | `workbook.criticalPartMissing` | A valid ZIP whose rels target a `xl/workbook.xml` that is not there. |
| `hostile/invalid-cell-reference.xlsx` | `ref.invalid` <br>or `ref.outOfRange` | `r="0"`, `r=""`, a 5-letter column past XFD, a column with no row, a row with no column, a negative row. |
| `hostile/malformed-xml.xlsx` | `xml.malformed` | Unclosed elements and mismatched nesting — the baseline garbage-in case. The error must name the part. |

<!-- END hostile-table -->

---

## `snapshots/` — recorded SwiftUI renders

Empty until A5 records into it. `TestSupport.ViewSnapshot` writes reference PNGs here, named
`<component>.<appearance>.png` where appearance is one of the six PLAN.md §10.5 combinations —
`light-normal`, `dark-increaseContrast`, and so on.

They are recorded, never hand-made: `OPENSHEETS_RECORD_SNAPSHOTS=1 swift test --filter GlassUI`.
A failing comparison writes the actual render to `$TMPDIR/opensheets-snapshot-failures/` so it can
be opened next to the reference.

Two things worth knowing before trusting one:

- **Compare pixels, not bytes.** Two renders of the same view in the same process are
  pixel-identical (measured: 0% of pixels differ, max channel Δ 0) but produce PNGs of different
  lengths, because the encoder is free to pick different filters. `ViewSnapshot.verify` decodes
  both and compares channels; nothing should ever diff the files.
- **A reference is tied to an OS version.** Text rasterisation changes between macOS releases, so
  a reference recorded on one and compared on another will differ for reasons that are not bugs.
  Re-record on a toolchain bump, in its own commit.

---

## Regenerating

```
python3 -m venv Scripts/.venv && Scripts/.venv/bin/pip install openpyxl xlsxwriter
Scripts/.venv/bin/python Scripts/gen-fixtures.py --all
Scripts/.venv/bin/python Scripts/gen-fixtures.py perf --with-huge   # the git-ignored large ones
python3 Scripts/validate-fixtures.py
```

```
Scripts/.venv/bin/python Scripts/gen-fixtures.py --sync-readme   # rebuild the hostile table
```

`formulas/` requires LibreOffice at `/Applications/LibreOffice.app/Contents/MacOS/soffice` —
it is the recalculation engine that supplies the cached values. `formulas/operator-precedence.xlsx`
goes further: the generator **asserts** that LibreOffice's answer equals Excel's documented one for
every case and refuses to build if it ever stops doing so, so the corpus cannot silently adopt one
engine's grammar. Everything else is generated
from `openpyxl`, `xlsxwriter`, or hand-written OOXML with no external tooling.

`validate-fixtures.py` needs **only the Python standard library**, so CI can run it without the
venv.
