# OpenSheets — Architecture & Build Plan

A native macOS spreadsheet that opens `.xlsx` and `.csv`, renders them beautifully in real
Liquid Glass, and treats **Claude Code as a first-class co-editor of the file on disk**.

The loop: you open a file → Claude Code edits it in your terminal → OpenSheets notices,
shows you *exactly what changed*, and lets you accept it. No Microsoft account, no plugin
store, no cloud. The file is the API.

**Owner:** quino · **Type:** open-source macOS app · **Target:** macOS 26.0+ (Tahoe), Apple Silicon + Intel
**Toolchain:** Xcode 26.6 · Swift 6.3 (strict concurrency ON) · SDK macosx26.5

---

## 0. Why this exists (and what we are *not* building)

The premise: people pirate Excel at home because work accounts block AI plugins, then bolt on
weak third-party assistants. But the strongest spreadsheet agent already exists — Claude Code —
it just has no good *surface*. It can already read and write files; what it lacks is a viewer
that stays in sync and a structured way to touch a workbook without corrupting it.

So OpenSheets is deliberately **not** trying to out-feature Excel. It is:

| We build | We deliberately don't |
| --- | --- |
| Fast, gorgeous, native rendering of xlsx/csv | Pivot table *authoring* |
| Editing cells, formulas, formats | Charting engine, drawing tools |
| 203 functions, including dynamic arrays | All 500+ Excel functions |
| File-watch → diff → refresh loop | Real-time multi-user collaboration |
| MCP server so Claude edits *structurally* | VBA / macro execution (never) |
| Byte-preserving round-trip of parts we don't model | Reimplementing OOXML in full |

The bet: **visualisation + sync fidelity is the product.** Depth comes from Claude.

### Three concerns I want stated up front (not blockers, but shape the plan)

1. **xlsx write fidelity is the hardest problem here.** A naive writer silently destroys charts,
   pivots, and conditional formats. §5.2 solves this with surgical ZIP rewriting — we only
   re-emit the XML parts we actually modelled and pass everything else through byte-identical.
   Residual risk: a chart whose source range we edited can go stale. We detect and warn; we do
   not silently "fix" it.
2. **A full formula engine is a multi-month project.** §5.3 sidesteps it for v0.1: xlsx already
   stores the *cached result* next to every formula, so we can display a correct workbook without
   evaluating anything. We only evaluate what the user edits.
3. **"Let Claude touch any file" needs a boundary.** A spreadsheet is untrusted input — a cell
   can contain text aimed at an agent. §7 defines workspace grants so the MCP server physically
   cannot read or write outside folders you explicitly approved in the app.

---

## 1. User flow

### 1.1 First run
Launcher window: a single glass panel over the desktop. Recents grid (empty), a large drop
target, `Open…`, `New Sheet`. Dropping or opening a file **grants its parent folder** as a
workspace (one-click, explained inline) so Claude Code can reach it later.

### 1.2 The core loop — the reason the app exists
1. User opens `~/work/budget.xlsx`. Grid paints in <800 ms.
2. Sidebar shows a **Claude** panel: workspace path, MCP status, `Open terminal here`.
3. User runs `claude` in that folder and says *"add a Q4 column projecting 8% growth"*.
4. Claude Code edits the file — either with plain file tools, or (better) via our MCP tools.
5. OpenSheets' watcher fires. A glass pill rises bottom-right with a pulsing accent dot:
   **"Changed on disk · 1 sheet, 42 cells · Refresh ⌘R"**
6. Click → the pill **morphs** (`glassEffectID`) into a diff panel: per-sheet change counts,
   a scrollable list of changed cells (`D2  120 → 129.6`), `Refresh` / `Show in grid` / `Discard file changes`.
7. On refresh the grid reloads and changed cells **flash accent, then fade over 6 s**. The
   sidebar keeps a session feed of every refresh so you can retrace what the agent did.
8. If it went wrong: `File ▸ Restore snapshot…` — we keep the last 20 gzipped versions of the
   raw bytes, taken before every external refresh and before every one of our own saves.

### 1.3 Editing (bidirectional, so conflicts are real)
Type in a cell → local dirty state. If the file *also* changes on disk while dirty, we do **not**
auto-refresh; the pill turns amber: **"Conflict — you have 3 unsaved edits."** with
`Keep mine` / `Take disk` / `Compare`. Never silently lose either side. (§6.3)

### 1.4 Empty / error states
No sheets, unreadable file, password-protected xlsx, file deleted while open, file moved,
external app holding a lock — every one has a designed glass state, not an alert dump. (§9)

---

## 2. Architecture

```
┌──────────────────────── OpenSheets.app (Xcode target — THIN) ────────────────────────┐
│  OpenSheetsApp.swift · DocumentWindow · Commands/menus · Assets · entitlements        │
│  Roughly 12 files. Only Wave 2 & 3 touch this — keeps project.pbxproj conflict-free.  │
└───────────────────────────────────────┬──────────────────────────────────────────────┘
                                        │ imports
┌───────────────────────────────────────▼──────────────────────────────────────────────┐
│              Packages/OpenSheetsCore  (SwiftPM — where ~95% of the code lives)        │
│                                                                                       │
│   ┌─────────────┐   THE INTERFACE FREEZE. Pure Sendable value types, zero deps.       │
│   │ SheetModel  │   Workbook · Sheet · Cell · CellRef · CellRange · CellStore ·       │
│   └──────┬──────┘   StyleTable · SheetDiff · errors. Defined in Wave 0, then FROZEN.  │
│          │                                                                            │
│  ┌───────┼───────────┬───────────────┬──────────────┬─────────────┐                   │
│  ▼       ▼           ▼               ▼              ▼             ▼                   │
│ SheetFormat   SheetFormula      GridKit         GlassUI      SheetStore   SheetMCP     │
│ xlsx r/w      lexer/parser      AppKit          DS tokens    watcher      tool surface │
│ csv  r/w      dep graph         virtualised     GlassSurface atomic write JSON-RPC     │
│ zip+hardening 203 funcs         renderer        chrome       SQLite       grants       │
│ (A1, A2)      (A3)              (A4)            (A5)         (A6)         (A9)         │
└───────────────────────────────────────────────────────────────────────────────────────┘
                                        │
                    ┌───────────────────┴────────────────────┐
                    ▼                                        ▼
        CLI/opensheets  (inspect, convert, diff)   CLI/opensheets-mcp  (stdio JSON-RPC)
                                                   ← registered in ~/.claude.json
```

### 2.1 Why SwiftPM-heavy, Xcode-thin — read this before you start
Eleven agents editing one `project.pbxproj` produces unmergeable garbage. **Every new source
file goes in a SwiftPM target**, where adding a file requires editing nothing. The `.xcodeproj`
is created once in Wave 0 with all targets already referenced and is then effectively read-only
until Wave 3. If you think you need to add a file to the app target, you are probably solving the
problem in the wrong layer — ask.

### 2.2 Why AppKit for the grid and SwiftUI for everything else
SwiftUI cannot draw 1,000,000 cells at 120 fps; there is no honest way around that. The grid is a
custom `NSView` inside `NSScrollView`, drawing with Core Graphics, virtualised to the visible
rect, hosted via `NSViewRepresentable`. All *chrome* is SwiftUI so it can use real Liquid Glass.
This split is deliberate and is the single biggest performance decision in the project.

### 2.3 Concurrency model (Swift 6 strict — this WILL be enforced by the compiler)
- Everything in `SheetModel` is a `Sendable` value type. No classes.
- Parsing and writing happen inside `actor WorkbookIO`. Never on main.
- `DocumentModel` is `@MainActor @Observable`. It owns the current `Workbook` snapshot.
- `GridKit` is `@MainActor` (AppKit requirement).
- The formula engine is a pure `Sendable` struct over an immutable snapshot; results are applied
  back on main as a single batch.
- `@unchecked Sendable` requires a comment justifying it, and a reviewer. Default: don't.

---

## 3. Visual design — "Quiet Glass"

The failure mode of a glass UI is that everything floats and nothing is readable. A spreadsheet
is 90% dense text. So the discipline is severe:

> **One opaque plane — the grid. Glass floats above it, never behind data.**

### 3.1 The three glass tiers
| Tier | API | Used for | Rule |
| --- | --- | --- | --- |
| **Chrome** | `.glassEffect(.regular, in:)` | toolbar, formula bar, sheet tabs, sidebar | Edge-anchored. Grid bleeds under via `.backgroundExtensionEffect()` |
| **Floating** | `.regular.interactive()` | stats pill, refresh pill, command palette, inspector | Detached, shadowed, capsule or 24pt continuous |
| **Signal** | `.regular.tint(_)` | conflict banner, error, "Claude changed this" | Tint is *semantic*. Amber = conflict, accent = agent, red = error |

### 3.2 The thing that separates real glass from blurry rectangles
`GlassEffectContainer(spacing: 12)` around each toolbar group, so adjacent controls **merge into
one lens** instead of stacking N independent blurs. Stacked glass is the #1 tell of a fake. Every
cluster of ≥2 glass elements must live in a container. Non-negotiable.

Morphing: the refresh pill → diff panel transition uses `glassEffectID(_:in:)` with a shared
`@Namespace`. That single transition is the app's signature moment; it should feel liquid.

### 3.3 Tokens (`DS` enum — one place to touch the look, per house style)
Light and dark from day one, both defined explicitly. Grid surface colours are **custom**
(they must not be materials); chrome colours are **semantic system colours** so the app inherits
the user's accent and looks native.

- Accent: `Color.accentColor` → system `controlAccentColor`. Never hardcode blue.
- Grid canvas: `#FFFFFF` light / `#1C1C1E` dark. Gridlines: `separatorColor` @ 50%.
- Selection: 2pt accent stroke + 6% accent fill; 6pt fill handle bottom-right.
- Header: `.headerView` material light / dark, active col/row header tinted accent @ 12%.
- Radii: `card 24 · pill capsule · control 10 · cellEditor 6`, all `.continuous`.
- Motion: springs only — `response 0.35, damping 0.85`. **The grid scroll is never animated**
  (it must be 1:1 with the trackpad or it feels broken).

### 3.4 Typography
- Chrome: SF Pro Text.
- **Cells: tabular figures, always.** `.monospacedDigit()`. A spreadsheet where numeric columns
  don't align is a broken spreadsheet. This is not a preference.
- Formula bar & the formula editor: SF Mono 12, with token-coloured syntax highlighting.
- Default row height 24pt @ 100% zoom (Excel's 15pt is cramped on Retina), user-configurable.

### 3.5 Accessibility — hard requirements, not polish
- `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` → **every glass surface swaps
  to a solid token.** Observe the notification; don't just read it at launch.
- `...ShouldIncreaseContrast` → stronger separators, heavier selection stroke, no tint-only signals.
- Cell text ≥ 4.5:1 against grid canvas in both schemes. Chrome text must be legible over *both*
  a white grid and a dark grid scrolling beneath it — test both.
- Full keyboard navigation; every glass control has an accessibility label and is focusable.

---

## 4. Screen inventory
1. **Launcher** — recents, drop target, workspace grants.
2. **Document window** — titlebar (unified, transparent, doc name + live sync chip) · glass toolbar
   · formula bar (name box · fx · field) · grid · sheet tab bar · floating stats pill.
3. **Sidebar** (⌘0) — sheets, named ranges, file info, **Claude panel** (workspace, MCP status,
   `Open terminal here`, session change feed).
4. **Refresh pill / diff panel** — §1.2. The signature interaction.
5. **Conflict banner** — amber signal glass, three actions.
6. **Command palette** (⌘K) — floating glass, fuzzy: go to cell, run function, switch sheet, ask Claude.
7. **Snapshot browser** — restore points with timestamps and change summaries.
8. **Inspector** (⌘⌥1) — number format, font, fill, borders, alignment for the selection.

---

## 5. Data layer

### 5.1 `SheetModel` — the interface freeze
Defined **once** in Wave 0, then frozen. Seven agents compile against it simultaneously; a change
after Wave 0 starts breaks everyone. Changes require going through the integrator (§13).

```swift
struct CellRef: Hashable, Sendable { let row: Int; let col: Int }   // 0-based internally
                                                                    // A1 strings only at boundaries
struct CellRange: Sendable { let start: CellRef; let end: CellRef }

enum CellValue: Sendable, Equatable {
    case empty
    case number(Double)          // dates are serial numbers + a date number-format
    case text(String)
    case boolean(Bool)
    case error(CellError)        // #DIV/0! #REF! #NAME? #VALUE! #N/A #NULL! #NUM!
}

struct Cell: Sendable {
    var value: CellValue         // for a formula cell this is the CACHED result
    var formula: String?         // source text, without leading '='
    var styleID: StyleID
    var flags: CellFlags         // .staleCache, .externalLink, .unsupportedFormula
}

struct Sheet: Sendable {
    let id: SheetID; var name: String
    var cells: CellStore
    var usedRange: CellRange?
    var frozen: FrozenPanes
    var columnWidths: RunLengthArray<Double>
    var rowHeights: RunLengthArray<Double>
    var merges: [CellRange]
    var visibility: SheetVisibility
}

struct Workbook: Sendable {
    var sheets: [Sheet]
    var definedNames: [String: CellRange]
    var styles: StyleTable
    var meta: WorkbookMeta          // app, created, modified, calcMode
    var passthrough: OpaqueParts    // §5.2 — the parts we refuse to touch
}
```

**`CellStore` is opaque on purpose.** A flat `[CellRef: Cell]` dictionary is easy but is both slow
for range scans and memory-hostile at 1M cells. The Wave 0 implementation is row-major sparse:
`[Int32: RowRun]`, where a `RowRun` holds a sorted `[UInt32]` of column indices plus a parallel
`[Cell]` array. Cache-friendly, cheap to iterate a rect, and — critically — the representation can
be swapped later without touching a single call site. **Only use its public API. Never index the
storage directly.**

### 5.2 xlsx: surgical round-trip (the fidelity strategy)
An `.xlsx` is a ZIP of XML parts. We model maybe 30% of them. So:

- **On read**: keep every raw ZIP entry (deflated bytes + metadata) in `OpaqueParts`. Parse only
  what we model: `workbook.xml`, `worksheets/*.xml`, `sharedStrings.xml`, `styles.xml`, rels.
- **On write**: re-emit *only* the parts whose model actually changed. Every other entry — charts,
  drawings, pivot caches, images, `vbaProject.bin`, custom XML — is copied through **byte-identical**.
- Delete `calcChain.xml` on any formula change (Excel rebuilds it; a stale one causes real corruption).
- Set `fullCalcOnLoad="1"` in `calcPr` whenever we wrote a formula we could not evaluate ourselves.
- **Never** write in place. Write to a temp file in the same directory, `fsync`, then
  `FileManager.replaceItemAt` (atomic, preserves inode metadata and extended attributes).
- If we cannot round-trip a file safely (encrypted, `.xlsb`, unknown critical part), open it
  **read-only** with an explicit banner. Refusing to save is always better than corrupting.

**Test contract:** for every fixture, the set of ZIP entries we did not model must be
byte-identical after `read → write`, and `parse(write(parse(f)))` must equal `parse(f)` over the
modelled subset.

### 5.3 Formulas: the engine is load-bearing — CORRECTED 2026-08-23

> **This section originally said the opposite, and it was wrong for the workflow this product is
> actually for.** It read: *"xlsx stores the formula and its last computed value, so v0.1 renders a
> completely correct workbook with zero evaluation."* That is true of files **Excel** wrote. It is
> false of files **Claude Code** writes — openpyxl, xlsxwriter and pandas all emit
> `<f>SUM(A1:A9)</f><v/>` with no cached value at all.
>
> In the real loop the cache is empty and **the formula engine performs 100% of the rendering.**
> Measured on 50 formulas a model would plausibly write, saved openpyxl-style: 36 rendered, 14 came
> back blank. The engine is not a nicety behind a flag; it is the product.
>
> Two consequences that follow from this and are now requirements, not options:
> 1. **Recalculate on open** when the file gives reason to distrust its cache — `fullCalcOnLoad`
>    set, or formulas present with neither `calcChain` nor `calcPr`. Requiring *both* to be absent
>    matters: LibreOffice writes `calcPr` with genuinely correct values, and a looser rule would
>    overwrite them with ours.
> 2. **An uncomputable formula must render as visibly uncomputed**, never as an empty cell. A blank
>    is indistinguishable from a genuinely empty cell, so the user has no reason to suspect anything
>    is missing — the worst available failure for a rendering platform. `#NAME?` is the precedent.
>
> Dynamic arrays and spill ranges were excluded here as out of scope. They are back in scope for
> the same reason: `FILTER`, `SORT`, `UNIQUE`, `SEQUENCE`, `LET` and `LAMBDA` are exactly what a
> model writes for modern Excel.

xlsx stores `<f>SUM(A1:A9)</f><v>42</v>` — the formula *and* its last computed value — so where a
cached value **is** present and trustworthy we still render it without evaluating, and only
recalculate what changes.

- Recalc is incremental over a dependency graph (cell → dependents), topologically ordered, with
  cycle detection → `#CIRCULAR` rather than a hang.
- Cells whose inputs changed but which use a function we don't implement keep their cached value
  and are marked `.staleCache` — rendered with a small dotted underline and an explaining tooltip.
  **Being honest about staleness beats guessing.**
- Function coverage (203 implemented, verified by `FunctionCatalog.implementedCount`): math/agg (SUM, AVERAGE, COUNT/A, MIN, MAX, ROUND family, ABS,
  SQRT, POWER, MOD, SUMPRODUCT, SUBTOTAL), logical (IF, IFS, AND, OR, NOT, IFERROR, SWITCH),
  lookup (VLOOKUP, HLOOKUP, XLOOKUP, INDEX, MATCH, OFFSET, INDIRECT, CHOOSE), text (CONCAT,
  TEXTJOIN, LEFT/RIGHT/MID, LEN, TRIM, UPPER/LOWER/PROPER, SUBSTITUTE, REPLACE, TEXT, VALUE,
  SPLIT-likes), date (TODAY, NOW, DATE, YEAR/MONTH/DAY, EDATE, EOMONTH, DATEDIF, WEEKDAY,
  NETWORKDAYS), stats (MEDIAN, STDEV.P/S, VAR, PERCENTILE, QUARTILE, RANK, CORREL),
  conditional aggregates (SUMIF/S, COUNTIF/S, AVERAGEIF/S, MAXIFS, MINIFS).
- **No longer excluded** (see the correction above): dynamic-array spilling, `LAMBDA`, `LET`, and
  the common financial functions. Still excluded: database functions, cube functions, and the
  locale-specific East Asian formats.

### 5.4 CSV / TSV
Dialect sniffing (delimiter, quote char, line ending), encoding detection (BOM → UTF-8 →
UTF-16 → Windows-1252 fallback with a user-visible notice), RFC 4180 quoting on write, and a
choice on save: preserve the original dialect or normalise. A CSV has no formula storage — typing
a formula stores its **evaluated result** and the app says so once, inline, not in a modal.

### 5.5 Local persistence — `~/Library/Application Support/OpenSheets/`
SQLite via GRDB, WAL mode (the app and the MCP binary are two processes hitting the same DB).

| Table | Purpose |
| --- | --- |
| `workspace_grant` | id, path, security-scoped bookmark, granted_at, revoked_at |
| `recent_file` | path, bookmark, last_opened, sheet/cell of last cursor |
| `doc_view_state` | per file: zoom, frozen panes, column widths not stored in the file, sidebar state |
| `snapshot` | file path, taken_at, reason (pre-refresh / pre-save / manual), gzipped bytes ref, change summary |
| `preference` | key/value app settings |

Snapshots: last 20 per file, evicted oldest-first, hard cap 500 MB total, stored as files in
`Snapshots/<sha256-of-path>/<ulid>.gz` with the row pointing at them.

---

## 6. File sync engine — the heart of the product

### 6.1 Watching
`DispatchSource.makeFileSystemObjectSource` on an open fd (`.write .rename .delete .extend .attrib`),
**plus** an FSEvents stream on the parent directory. The fd source alone misses atomic replaces —
which is exactly how every well-behaved writer, including our own and most Python xlsx libraries,
saves. Watching both is mandatory. On `.rename`/`.delete`, re-resolve the path and **re-arm on the
new fd**; forgetting this is the classic bug where the watcher silently dies after the first save.

Debounce 150 ms — writers produce bursts. Then compare `(size, mtime, inode, first-4KB hash)`
before doing real work.

### 6.2 Self-write suppression
When we save, we record an *expected fingerprint*. The watcher compares and drops matching events.
Without this the app refreshes itself in a loop after every save.

### 6.3 The state machine (implement literally — this is the spec)
```
        ┌──────────┐  external change, no local edits, autoRefresh ON
        │  SYNCED  │ ─────────────────────────────────────────────► RELOADING ──► SYNCED
        └────┬─────┘                                                     │(flash diff)
             │ external change, no local edits, autoRefresh OFF          │
             ├──────────────────────────────────────► STALE ─(⌘R)────────┘
             │ user edits
             ▼
        ┌──────────┐  external change while dirty
        │  DIRTY   │ ────────────────────────────────► CONFLICT
        └────┬─────┘                                       │
             │ save (atomic)                               ├─ Keep mine → save over → SYNCED
             ▼                                             ├─ Take disk → discard → RELOADING
          SYNCED                                           └─ Compare   → diff sheet
```
Plus terminal states: `MISSING` (deleted/moved — offer Save As from memory), `LOCKED`,
`READ_ONLY`, `UNREADABLE`. Every state has a designed glass presentation; none of them is an
`NSAlert` dump.

### 6.4 Diff
`SheetDiff` computed between the pre-reload snapshot and the fresh parse:
sheets added/removed/renamed; per sheet, cells added/removed/changed with before/after; detected
row/column inserts (so a shifted 10k-row sheet reads as *"inserted 1 row at 5"*, not 10,000 changes
— run a cheap LCS over row hashes first). Powers the diff panel, the grid flash, and the feed.

---

## 7. Permissions & security

### 7.1 Distribution & sandbox decision
Ship **non-sandboxed**, Developer ID signed + notarised, hardened runtime, direct download.
A sandboxed app cannot fulfil "let Claude Code touch any file we want" without fighting bookmarks
at every turn, and we are not shipping to the Mac App Store. We still request folder access through
`NSOpenPanel` and persist security-scoped bookmarks, so a future sandboxed build is a small change.

### 7.2 Workspace grants — the boundary that makes this safe
The MCP server is spawned by Claude Code and inherits the *user's full file access*. That is too
much. So: **the MCP server refuses any path that does not resolve inside an active
`workspace_grant`.** Enforcement rules, all of them required:
- Resolve symlinks and `..` **before** the check (`URL.resolvingSymlinksInPath` + `standardized`).
- Compare by path components, not string prefix (`/Users/q/work-secret` must not match `/Users/q/work`).
- Deny-list regardless of grant: `~/.ssh`, `~/.aws`, `~/.config/gh`, `~/Library/Keychains`,
  `~/.claude.json`, anything matching `*.pem|*.key|.env*`.
- Denial returns a message telling the user to grant the folder **in the app** — the server never
  self-grants, and no argument or file content can widen a grant.

### 7.3 Treating spreadsheet content as untrusted
A cell is data, never an instruction — for us and for any agent reading through us.
- **Never execute anything.** No DDE, no `=cmd|`, no VBA. If `vbaProject.bin` exists we pass it
  through on save and show a "contains macros, not executed" chip.
- **Never auto-fetch.** External workbook links and `HYPERLINK()` targets are inert until clicked,
  and clicking shows the full resolved URL first.
- MCP tool output wraps cell text in an explicit *untrusted content* envelope so the agent on the
  other end knows the provenance.
- Formula-injection guard on CSV **export**: a value starting `= + - @ TAB CR` is prefixed with `'`
  unless the user opts out. (Protects whoever opens our CSV in Excel.)

### 7.4 Parser hardening — hostile xlsx is a real attack surface
`XMLParser` with external entity resolution **disabled** (XXE). Zip-bomb defence: cap total
decompressed bytes (500 MB default), per-entry ratio (100:1), entry count (10,000), and path
traversal in entry names (`../`). Cap sheet dimensions at Excel's own limits (1,048,576 × 16,384)
and reject anything claiming more. Fuzz corpus in CI (§10.4).

---

## 8. Validation

**Input parsing order** for a typed cell: formula (`=`) → boolean → number (locale-aware, with
thousands separators, parentheses-negative, trailing %) → currency → date/time (locale + ISO) →
text. Explicit override via number format. Leading `'` forces text.

**Write API validation** (used by both the UI and MCP): range within sheet limits · range shape
matches the value array shape · formula parses before it is committed · sheet name valid
(≤31 chars, no `[]:*?/\`, unique) · defined-name identifier rules · style IDs exist ·
merges don't overlap. All failures return a typed `SheetError` with a human-readable message and
a machine-readable code — never a `fatalError`, never a silent no-op.

---

## 9. Edge cases the implementation must handle explicitly

**File**: deleted while open · moved/renamed while open · replaced by a directory · on an unmounted
network volume · read-only permissions · zero bytes · truncated mid-write (writer still running —
this is why we debounce and hash) · >100 MB · symlink · iCloud/Dropbox placeholder not yet
downloaded · concurrent write from a third app.

**Workbook**: 0 sheets · 1M+ rows · a single cell at XFD1048576 (huge used range, no data) ·
sheet named with emoji or RTL text · duplicate sheet names differing only by case · hidden and
very-hidden sheets · `sharedStrings` with rich-text runs · dates before 1900 and the Lotus 1900
leap-year bug · the 1904 date system · `#REF!` cached values · array formulas ·
merged cells overlapping a frozen pane boundary · a cell with 32k characters.

**CSV**: no trailing newline · CRLF vs LF vs CR · quoted newlines · ragged rows · BOM · UTF-16 ·
a 2 GB file (stream, don't slurp) · a single line of 10M chars.

**Editing**: paste 100k cells · undo across a refresh (refresh clears the undo stack — say so) ·
edit while a recalc is running · typing during a reload.

**Sync**: 200 writes/second from an agent (coalesce) · file changes *while the diff panel is open*
(re-diff and say so) · clock skew making mtime go backwards · same file open in two windows.

---

## 10. Testing strategy

**Swift Testing** (`import Testing`, `@Test`) throughout; XCTest only where UI tests demand it.

1. **Golden corpus** — `Fixtures/` holds ~40 files: minimal, formulas, all number formats, dates
   (both epochs), merged, frozen, hidden sheets, rich text, charts, pivots, macros, conditional
   formats, 1M rows, every CSV dialect, and a `hostile/` folder (zip bomb, XXE, traversal,
   truncated, 4 GB claimed dimensions). Each has a `.expected.json` describing what a correct
   parse yields.
2. **Round-trip property tests** — §5.2's two contracts, run over the whole corpus.
3. **Formula table tests** — a TSV of `formula ⇥ expected` per function including the error cases;
   ~600 rows. Cross-checked against values Excel itself cached in the fixtures.
4. **Fuzzing** — `swift-fuzz`-style corpus over the parser in CI nightly; any crash is a P0.
5. **Snapshot tests** — every `GlassUI` component × {light, dark} × {normal, reduceTransparency,
   increaseContrast}. Deterministic (fixed seed, no animation).
6. **Performance gates in CI** — fail the build on regression:
   | Metric | Budget |
   | --- | --- |
   | Open 100k-cell xlsx → first paint | < 800 ms |
   | Open 1M-cell xlsx | < 4 s, < 600 MB RSS |
   | Scroll frame time (ProMotion) | < 8.3 ms p99, zero drops while flinging |
   | Keystroke → cell repaint | < 16 ms |
   | Recalc 10k dependents | < 200 ms |
   | External change → diff shown | < 1 s @ 100k cells |
7. **E2E** (Wave 3) — a script drives a real `.xlsx` with an external process (mimicking Claude
   Code), asserting the pill appears, the diff is right, refresh applies, and snapshots restore.
8. **Concurrency** — strict-concurrency warnings are errors, and a Thread Sanitizer lane runs in CI.

   That lane is **not** the whole suite, which this line used to claim: `ci.yml` runs
   `--sanitize thread --filter 'SheetModelTests|MiniZipTests'`. TSan multiplies runtime by roughly
   5–15×, and a suite that already takes 80 seconds does not fit a PR lane under it. The two targets
   chosen are the ones with genuinely shared mutable state reachable from several tasks. Widening it
   is worth doing on a nightly schedule; claiming it already happens was worth less than saying so.

---

## 11. Rollout

| Milestone | Contents | Gate |
| --- | --- | --- |
| **v0.1 Viewer** | open xlsx/csv, render, navigate, watch → diff → refresh, snapshots | perf budgets green, corpus parses |
| **v0.2 Editor** | edit, formulas, formats, undo, atomic save, conflicts | round-trip contracts green |
| **v0.3 Claude** | MCP server, workspace grants, activity feed, `Open terminal here` | grant-escape tests green |
| **v0.4 Polish** | sort/filter, find/replace, inspector, charts (view-only), command palette | snapshot tests green |

**Feature flags**: `Flags.swift` reading `UserDefaults` (`OSFlagEditing`, `OSFlagMCP`,
`OSFlagFormulaEngine`, …). Unfinished work ships dark rather than blocking a release.

  **These were specified as defaulting off, and five of the six now default *on*** — `editing`,
  `mcp`, `formulaEngine`, `snapshots` and `autoRefresh` are all shipped features, and a flag whose
  default never flips is a flag nobody removes. Only `OSFlagSheetStructure` still defaults off,
  because add/remove/reorder sheet is genuinely unfinished (§14 of the Wave 2 addendum). The flag
  exists to ship dark code, not to keep finished code hidden.

**Distribution**: notarised, stapled DMG on GitHub Releases; Homebrew cask `opensheets`; Sparkle
for in-app updates in v0.4. Crash reporting is opt-in and local-first. No telemetry by default —
this is an app for people who left the cloud on purpose.

---

## 12. Integrations
- **Claude Code (MCP)** — `opensheets-mcp` over stdio, registered via `claude mcp add`. §7.2 grants.
- **Terminal** — `Open terminal here` opens Terminal or iTerm2 (whichever is default) at the
  workspace root with `claude` pre-typed but **not executed**.
- **Quick Look** — a thumbnail/preview extension for xlsx (v0.4, nice-to-have).
- **Services / Finder** — "Open with OpenSheets", and a `UTType` claim for `.xlsx`/`.csv` that
  does *not* steal the default association without asking.

---

## 13. Work breakdown — 11 agents, 4 waves

Full briefs live in [`docs/agents/`](docs/agents/). One file per agent, each stating scope, files
owned, files forbidden, dependencies, and acceptance criteria.

```
WAVE 0 ── blocking, runs ALONE ────────────────────────────────────────────────
  A0  Foundation & interface freeze
      repo · SwiftPM package w/ all targets · SheetModel + CellStore · MiniZip types
      · Xcode shell · CI · Flags · DS token skeleton
                                   │
      ┌────────────┬───────────────┼───────────────┬────────────┬─────────────┐
      ▼            ▼               ▼               ▼            ▼             ▼
WAVE 1 ── 7 agents fully in parallel, zero shared files ───────────────────────
  A1 xlsx read   A2 xlsx write   A3 formula    A4 GridKit   A5 GlassUI   A6 SheetStore
     + zip read     + csv r/w       engine        renderer     design sys    watcher/db
                                                                            A7 fixtures+test infra
      └────────────┴───────────────┴───────────────┴────────────┴─────────────┘
                                   │
                    ┌──────────────┴──────────────┐
                    ▼                             ▼
WAVE 2 ── 2 agents in parallel ────────────────────────────────────────────────
  A8  App shell & integration            A9  MCP server + CLI
      (needs A1–A6)                          (needs A1, A2, A3, A6)
                    └──────────────┬──────────────┘
                                   ▼
WAVE 3 ── solo ────────────────────────────────────────────────────────────────
  A10 Integration, E2E, perf gate, notarised packaging, docs, v0.1 release
```

### 13.1 Rules of engagement — every agent reads these

1. **Own your files. Touch nothing else.** Each brief lists exact paths. If you believe you must
   edit a file outside your list, stop and report it — do not edit it.
2. **`SheetModel` is frozen after Wave 0.** If you need a change, write it in
   `docs/agents/MODEL-CHANGE-REQUESTS.md` with a rationale and keep working around it. The
   integrator batches these. A unilateral change breaks six other agents' builds.
3. **Never touch `OpenSheets.xcodeproj/project.pbxproj`.** Everything goes in a SwiftPM target.
   Adding a `.swift` file to a SwiftPM target requires editing no manifest.
4. **Ship it green.** `swift build && swift test` from `Packages/OpenSheetsCore` must pass when
   you finish. Strict-concurrency warnings are errors. No `TODO` in place of an implementation —
   an honest `throw SheetError.notImplemented(...)` is fine, a silent wrong answer is not.
5. **Test what you build.** Every public function needs a test. Wave 1 agents must not depend on
   another Wave 1 agent's output — use `A7`'s fakes and fixtures, or your own in-target stubs.
6. **Write doc comments that say *why*.** Match the house voice in `SignalToNoise`: explain the
   constraint, be honest about what doesn't work. See `DesignSystem.swift` for the register.
7. **One commit per logical unit**, message `A<n>: <what>`. Branch `agent/a<n>-<slug>`.
8. **Report at the end**: what you built, what you deliberately left out, what surprised you, and
   anything you think a downstream agent will trip on.

### 13.2 Parallelism summary
| Wave | Agents | Can run together? | Blocked by |
| --- | --- | --- | --- |
| 0 | A0 | — (must be alone) | nothing |
| 1 | A1 A2 A3 A4 A5 A6 A7 | **yes, all 7** | A0 complete + merged |
| 2 | A8 A9 | **yes, both** | all of Wave 1 merged |
| 3 | A10 | — (must be alone) | A8 + A9 merged |
