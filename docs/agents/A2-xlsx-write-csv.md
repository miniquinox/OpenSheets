# A2 — XLSX surgical writer, ZIP writing, CSV/TSV

**Wave 1 · parallel with A1, A3–A7 · blocked by A0.**

## Mission
Write workbooks back to disk **without destroying anything you didn't understand.** This is the
highest-risk correctness task in the project: a subtle bug here silently eats someone's charts.
Read PLAN.md §5.2 twice before starting.

## Dependencies
A0 merged. **You do not depend on A1** — you write, A1 reads. You consume `OpaqueParts` as a data
contract defined by A0, and you build your own fixtures by hand-authoring small xlsx files (or
unzip/rezip real ones) rather than waiting for A1's reader.

## Files you own
```
Packages/OpenSheetsCore/Sources/MiniZip/Writer.swift          ← ONLY this file in MiniZip
Packages/OpenSheetsCore/Sources/MiniZip/Deflate.swift
Packages/OpenSheetsCore/Sources/SheetFormat/XLSX/Write/**
Packages/OpenSheetsCore/Sources/SheetFormat/CSV/**            ← reader AND writer, all yours
Packages/OpenSheetsCore/Tests/SheetFormatTests/Write/**
Packages/OpenSheetsCore/Tests/SheetFormatTests/CSV/**
```

## Files you must NOT touch
`MiniZip/Types.swift`, `MiniZip/Reader.swift`, `MiniZip/Inflate.swift` (A1's) ·
`SheetFormat/XLSX/Read/**` · `SheetFormat/XML/**` · `SheetModel`.

## Build this

### 1. `MiniZip.Writer`
Build a valid zip from `[ZipEntry]`. **Critical capability: pass through an entry's already-
compressed bytes verbatim** (copy deflated payload + CRC + sizes straight into the new archive,
no re-compress). That is the whole trick — it is both fast and lossless. Also support compressing
fresh bytes via `Compression`. Correct local headers, central directory, and end-of-central-
directory. Zip64 when > 4 GB or > 65,535 entries.

### 2. The surgical write algorithm
```
input:  original OpaqueParts, modified Workbook, set of dirty part paths
output: new .xlsx bytes

for each entry in original archive, in original order:
    if entry.path is dirty  -> emit newly serialised XML (compressed)
    elif entry.path == "xl/calcChain.xml" and anyFormulaChanged -> SKIP (drop it)
    else                    -> emit original compressed bytes verbatim
emit any brand-new parts (new sheet, new sharedStrings entries), and patch
    [Content_Types].xml + rels ONLY if the part set changed
```
Rules:
- Dirty-tracking is per **part**, not per workbook. Editing one cell of `sheet3` must not rewrite
  `sheet1`, `styles.xml`, or anything else.
- On any formula change: drop `calcChain.xml` **and** set `calcPr fullCalcOnLoad="1"`.
- Preserve entry order and the mimetype-ish conventions of the original producer where possible —
  some tools are order-sensitive.
- If `Workbook.meta.readOnlyReason != nil`, **refuse to write** with a clear `SheetError`.

### 3. XML serialisation for the parts you do own
`worksheets/sheetN.xml`, `sharedStrings.xml`, `styles.xml`, `workbook.xml`. Emit rows in ascending
order, cells ascending within a row, correct `r` refs, correct `t` attributes, `<f>` before `<v>`.
Escape `& < > "` and reject/strip the XML-1.0-illegal control characters (a real crash source when
data comes from a CSV). Write shared strings for repeated text, inline for one-offs above a threshold.

### 4. Atomic save (used by A6, but implemented here)
`write to <dir>/.opensheets-<ulid>.tmp` → `fsync` the file → `fsync` the directory →
`FileManager.replaceItemAt(original, withItemAt: tmp)`. Preserve POSIX permissions, ownership where
possible, and extended attributes (Finder tags!). Return the resulting `(inode, mtime, size, hash)`
fingerprint so A6 can suppress the self-write event. Clean up the temp file on every error path.

### 5. CSV / TSV
**Reader:** stream (never slurp — a 2 GB CSV must open). Sniff delimiter (`, ; \t |`) from the first
64 KB, sniff quote char, sniff line ending. Detect encoding: BOM → UTF-8 validity → UTF-16 → fall
back to Windows-1252 **and surface that guess to the user**. RFC 4180 quoting including embedded
newlines and doubled quotes. Ragged rows are padded, not rejected, with a count reported.
**Writer:** RFC 4180. Preserve the source dialect by default; `normalise` option. **Formula-injection
guard (PLAN.md §7.3):** a value starting with `= + - @ \t \r` is prefixed with `'` unless the caller
opts out. Default on.

## Acceptance criteria
- [ ] **Passthrough contract:** for every fixture, after `read → modify one cell in sheet1 → write`,
      every ZIP entry other than `sheet1.xml`, `sharedStrings.xml`, `calcChain.xml` is
      **byte-identical** to the original. Assert per-entry, not with a whole-file hash.
- [ ] A workbook containing a chart, a pivot table, an image, and a `vbaProject.bin` survives a
      round-trip and **still opens in Microsoft Excel and Numbers with all of it intact.** Verify
      by hand at least once and record the result in your report.
- [ ] `parse(write(parse(f)))` equals `parse(f)` over the modelled subset, for the whole corpus.
- [ ] Writing to a read-only path, a full disk, and a path that disappears mid-write all fail
      cleanly with the original file **untouched**. Test with a deliberately failing FS stub.
- [ ] Killing the process between temp-write and replace leaves the original intact (test by
      injecting a fault before `replaceItemAt`).
- [ ] CSV: round-trips all dialect fixtures; 2 GB synthetic file opens with < 200 MB RSS;
      injection guard covered; Windows-1252 fallback covered.
- [ ] Zero strict-concurrency warnings.

## Report back
The dirty-part tracking API you exposed (A8 and A9 both call it), and an honest list of what can
still go stale after an edit — e.g. charts pointing at a range whose values changed.
