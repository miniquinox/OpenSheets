# A1 — XLSX reader, ZIP reading, parser hardening

**Wave 1 · parallel with A2–A7 · blocked by A0.**

## Mission
Turn a `.xlsx` file on disk into a `SheetModel.Workbook` — correctly, fast, and safely against
hostile input. You are the front door of the whole app; if you are slow or wrong nothing else matters.

## Dependencies
A0 merged (`SheetModel`, `MiniZip.Types`). **You do not depend on any other Wave 1 agent.** If you
need fixtures before A7 lands, generate your own under `Tests/SheetFormatTests/Resources/`.

## Files you own
```
Packages/OpenSheetsCore/Sources/MiniZip/Reader.swift          ← ONLY this file in MiniZip
Packages/OpenSheetsCore/Sources/MiniZip/Inflate.swift
Packages/OpenSheetsCore/Sources/SheetFormat/XLSX/Read/**      ← all yours
Packages/OpenSheetsCore/Sources/SheetFormat/XML/**            ← hardened XML pull-parser
Packages/OpenSheetsCore/Tests/SheetFormatTests/Read/**
```

## Files you must NOT touch
`MiniZip/Types.swift` (A0's) · `MiniZip/Writer.swift` and `Deflate.swift` (**A2 owns those — you
share the `MiniZip` target, so stay strictly in your own files**) · `SheetFormat/XLSX/Write/**` ·
`SheetFormat/CSV/**` · anything in `SheetModel`.

## Build this

### 1. `MiniZip.Reader`
Read the central directory → `[ZipEntry]`; random access to entry bytes; inflate via the
`Compression` framework (raw deflate). Support store + deflate only; reject other methods clearly.
**Hardening (PLAN.md §7.4), all mandatory:** total decompressed cap `Limits.maxDecompressedBytes`,
per-entry compression-ratio cap 100:1, entry-count cap, reject entry names containing `..`,
absolute paths, or NUL, reject duplicate names. Every rejection throws a specific `SheetError`.
**Preserve every entry's raw compressed bytes and metadata into `OpaqueParts`** — this is what makes
A2's surgical writer possible. Do not decompress entries nobody asked for.

### 2. Hardened XML pull-parser
Wrap `XMLParser`, or write a small streaming tokenizer — **measure first**, `XMLParser` is often the
bottleneck on a 100 MB sheet. Requirements: external entity resolution **disabled** (XXE), no DTD
processing, depth cap, attribute-count cap. Streaming, not DOM: a 1M-row `sheet1.xml` must never be
materialised as a tree.

### 3. The parts you parse
- `[Content_Types].xml`, `_rels/.rels`, `xl/_rels/workbook.xml.rels` — resolve part paths properly.
  **Never hardcode `xl/worksheets/sheet1.xml`**; files from other producers don't follow it.
- `xl/workbook.xml` — sheet names, ids, order, visibility (`visible`/`hidden`/`veryHidden`),
  `definedNames`, `calcPr`, and the **1904 date system flag**.
- `xl/sharedStrings.xml` — including rich-text runs (`<r><t>`); flatten to plain text for the model
  but keep the raw part in `OpaqueParts`.
- `xl/styles.xml` — `numFmts`, `cellXfs`, fonts, fills, borders → `StyleTable`. Include the ~50
  built-in implicit number formats (ids 0–49) that never appear in the file.
- `xl/worksheets/sheetN.xml` — cells (`<c r= t= s=><f/><v/>`), **cached values**, formula kinds
  (normal / shared / array — expand shared formulas from their master), inline strings, `mergeCells`,
  `sheetFormatPr`, `cols` (→ `RunLengthArray`), row heights, `pane` (frozen/split), `hyperlinks`,
  `dimension`.

### 4. Correctness details that will bite you
- Cell type `t`: `n` (default, attribute absent), `s` (shared-string index), `str` (formula string
  result), `b`, `e` (error), `inlineStr`, `d` (ISO date — rare but real).
- Dates are numbers plus a date number-format. Handle **both** the 1900 and 1904 epochs, and the
  deliberate Lotus 1-2-3 leap-year bug (serial 60 = the nonexistent 1900-02-29).
- Rows and cells may be sparse and **out of order** in the XML. Never assume monotonic `r`.
- `dimension` is frequently wrong or missing. Compute `usedRange` yourself; treat `dimension` only
  as a capacity hint.
- Namespace prefixes vary by producer (`x:`, none, others). Match on local name.
- Set the `.externalLink` cell flag when a formula references another workbook (`[1]Sheet1!A1`) so
  A5/A8 can warn. **Never resolve or fetch them.**

### 5. Read performance
Target: 1M cells in < 4 s, < 600 MB RSS. Concretely: parse sheets concurrently (one task per sheet)
on a background executor; reuse a byte buffer; avoid allocating a `String` per cell where a
`Substring` or interned index works; intern shared strings once into a `[String]` and store indices.
Add `os_signpost` regions around zip-open, styles, and each sheet.

### 6. Read-only refusals
Encrypted/password-protected (`EncryptedPackage` stream), `.xlsb`, or an unknown *critical* part →
parse what you can, set `Workbook.meta.readOnlyReason`, and make sure A2 can never write it.
Failing to open is fine; corrupting on save is not.

## Acceptance criteria
- [ ] Parses every non-hostile fixture into a `Workbook` matching its `.expected.json`.
- [ ] Every file in `Fixtures/hostile/` is **rejected with a specific `SheetError` — no crash, no
      hang, bounded memory.** Run that suite under ASan with a 2 s per-case timeout.
- [ ] XXE test: an xlsx whose XML declares an external entity pointing at `/etc/passwd` parses
      without reading that file and without expanding the entity.
- [ ] `OpaqueParts` after a read contains **every** entry of the original archive, byte-identical
      (assert with a per-entry checksum).
- [ ] Perf: `Fixtures/perf/1m-cells.xlsx` opens in < 4 s / < 600 MB on Apple Silicon; the test asserts it.
- [ ] Shared and array formulas expand to correct per-cell formula text (fixture-verified).
- [ ] The 1904-epoch fixture yields the same wall-clock dates as its 1900 twin.
- [ ] Zero strict-concurrency warnings.

## Report back
Where the time actually goes (signpost numbers), which OOXML shapes you chose not to model, and
anything A2 must know in order to write these files back safely.
