# A7 — Fixture corpus, test infrastructure, performance harness

**Wave 1 · parallel with A1–A6 · blocked by A0.**

## Mission
Build the ground truth everyone else is tested against. You are effectively writing the spec in
executable form — if your fixtures are wrong or thin, six agents will confidently ship bugs.

Start immediately and **land your fixtures early**, ideally before the other Wave 1 agents need
them. Announce partial deliveries rather than holding everything to the end.

## Dependencies
A0 merged. Nothing else. You produce artefacts everyone consumes.

## Files you own
```
Fixtures/**                                              ← the corpus
Packages/OpenSheetsCore/Sources/TestSupport/**           ← fakes, builders, matchers
Packages/OpenSheetsCore/Tests/TestSupportTests/**
Scripts/bench.sh  Scripts/gen-fixtures.swift
.github/workflows/perf.yml
docs/perf/README.md
```

## Files you must NOT touch
Any other agent's source or tests. You provide tools; they write their own assertions.

## Build this

### 1. The corpus — ~40 files, each with a `.expected.json`
Generate what you can with a script (`gen-fixtures.swift`, using Python's `openpyxl`/`xlsxwriter`
via a subprocess is fine and is the pragmatic choice) and hand-author the rest. **Every fixture needs
a sidecar `.expected.json` describing the correct parse** — sheet names, dimensions, and a sample of
cells with value + type + formula + number format.

- `basic/` — minimal, one sheet, one cell; multi-sheet; empty workbook; sheet with only formatting.
- `formulas/` — every implemented function at least once; shared formulas; array formulas; cross-sheet
  refs; defined names; `#REF!`/`#DIV/0!` cached errors; a circular reference; external-workbook links.
- `formats/` — all built-in number formats, custom formats, negative-in-red, currency, percent,
  scientific, text format, dates in **both** the 1900 and 1904 epochs, serial 60 (the Lotus bug).
- `structure/` — merged cells, frozen panes, split panes, a merge straddling a frozen boundary,
  hidden and very-hidden sheets, custom column widths and row heights, sheets named with emoji /
  RTL / 31-char / case-colliding names.
- `passthrough/` — **critical for A2**: workbooks containing a chart, a pivot table, an image, a
  conditional format, a data-validation rule, a comment, and a `vbaProject.bin`. These exist purely
  to prove nothing gets destroyed on save.
- `csv/` — comma, semicolon, tab, pipe; CRLF/LF/CR; quoted newlines; doubled quotes; ragged rows;
  BOM; UTF-16LE/BE; Windows-1252; no trailing newline; a 10M-character single line.
- `perf/` — `100k-cells.xlsx`, `1m-cells.xlsx`, `wide-16384-cols.xlsx`, `single-cell-at-XFD1048576.xlsx`,
  `2gb.csv` (generated at test time, git-ignored, with a checked-in generator).
- `hostile/` — zip bomb, nested zip bomb, XXE (external entity → `/etc/passwd`), billion-laughs,
  path traversal (`../../etc/passwd` as an entry name), duplicate entry names, truncated archive,
  a sheet declaring 4 billion rows, 100k-deep XML nesting, a 32k-character cell, NUL bytes in a
  string, an entry claiming a 10 GB uncompressed size. **Each with the `SheetError` code it must
  produce**, in `hostile/expected-errors.json`.

Keep total repo size sane: generate the big ones, commit the small ones, use Git LFS only if
genuinely needed and say so.

### 2. `TestSupport` — the shared toolkit
- `WorkbookBuilder` — a fluent builder for constructing test workbooks in memory
  (`.sheet("Data").cell("A1", 42).formula("B1", "A1*2")`).
- `SyntheticWorkbook.generate(rows:cols:)` — for A4's and A1's perf work.
- `FakeWorkbookReader` / `FakeWorkbookWriter` conforming to A6's protocols, with programmable
  latency and failure injection.
- `FailingFileSystem` — a stub that fails at a chosen syscall (used by A2 and A6 to prove atomic
  writes are actually atomic).
- Custom matchers: `#expect(workbook, matches: expectedJSON)` with a **useful diff on failure** —
  "cell D7: expected 42, got 42.0000001" beats "not equal".
- A snapshot-testing helper for SwiftUI views (deterministic: fixed size, disabled animation,
  fixed appearance) for A5.

### 3. Performance harness
`Scripts/bench.sh` running every budget in PLAN.md §10.6 and emitting JSON. A GitHub Action
(`perf.yml`) that runs it on a self-hosted or `macos-26` runner, compares to a committed baseline in
`docs/perf/baseline.json`, and **fails the build on a >10% regression**. Include the Instruments
trace capture command in `docs/perf/README.md` so agents can profile the same way.

### 4. CI test matrix
Extend A0's `ci.yml`: unit tests, tests under Thread Sanitizer, tests under Address Sanitizer for
the `hostile/` suite only (it is slow), and a nightly fuzz job over the parser.

## Acceptance criteria
- [ ] ≥ 40 fixtures, each with a validated `.expected.json`. Validate the *sidecars themselves* — a
      script that cross-checks each `.expected.json` against values Excel itself cached in the file,
      so your ground truth isn't just your own assumption.
- [ ] `hostile/expected-errors.json` covers every hostile file with a specific `SheetError` code.
- [ ] `TestSupport` has its own tests (the fakes must behave).
- [ ] `Scripts/bench.sh` runs green on a clean checkout and writes `docs/perf/latest.json`.
- [ ] `perf.yml` fails on an injected 20% regression (prove it once, then revert).
- [ ] `docs/perf/README.md` explains how to profile and how to update the baseline deliberately.
- [ ] Fixtures are documented in `Fixtures/README.md` — one line per file explaining what it proves.

## Report back
The fixture inventory, the `TestSupport` API surface, and anything you found while building fixtures
that you think contradicts an assumption in PLAN.md.
