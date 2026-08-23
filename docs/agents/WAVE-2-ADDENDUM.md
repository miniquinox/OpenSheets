# Wave 2 addendum — handoffs and corrections from Wave 1

**A8 and A9 must both read this.** It carries the facts each Wave 1 agent surfaced that a
downstream agent cannot discover on its own, plus corrections that override the briefs.

---

## 1. The chrome must be ANCHORED, not floating (A8 — highest priority)

Look at `docs/design/2x/document-light.png` and `document-dark.png` before you compose anything.
A5's components are excellent individually, and the composite it assembled to demonstrate them is
**not a shippable window layout**. In it:

- the toolbar and formula bar float as islands **on top of grid rows 1–5**, hiding data;
- the sidebar floats **over** the toolbar, clipping its leftmost controls;
- the column-header strip runs behind the sidebar.

That is precisely the failure PLAN.md §3 exists to prevent — *"the failure mode of a glass UI is
that everything floats and nothing is readable."* A5 was briefed to build components, not layout, so
this is not a defect in its work. It is **your** job, and it is the single most likely way this app
ends up looking like a web page wearing a macOS costume.

**What the real window must do:**
- Toolbar and formula bar are **edge-anchored chrome spanning the full window width**, in the
  layout, occupying their own space. The grid's scrollable area begins below them. They are not
  overlays.
- The sidebar is a **sibling in the layout**, not a panel on top. Use `NSSplitViewController` /
  `NavigationSplitView` so the toolbar spans correctly and nothing is occluded.
- `.backgroundExtensionEffect()` is what makes the grid *bleed under* the chrome's translucency for
  depth. That is a rendering effect on an anchored surface — it is not the same thing as floating a
  panel over live data, and the difference is the whole point.
- Only three things genuinely float above the grid: the **selection stats pill**, the
  **refresh pill / diff panel**, and the **command palette**. Everything else is anchored.
- Grid content must never be permanently obscured. A floating element sits in dead space or over
  empty rows, and the grid's scroll insets account for it.

## 2. `SheetRegionChanges` — you must tell the writer what you changed (A8)

A2's writer regenerates only `<sheetData>` and `<dimension>` for a plain cell edit and copies
`<cols>`, `<sheetViews>`, `<sheetFormatPr>`, `<mergeCells>`, `<hyperlinks>`, `<autoFilter>` verbatim
out of the original bytes. So **passing only "this sheet is dirty" is not enough**:

```swift
edits.note(sheet, .columns)   // after a column resize
edits.note(sheet, .views)     // after freezing panes
edits.note(sheet, .merges)    // after a merge
```

Get this wrong in the other direction and it is worse than a missing feature: our
`Limits.defaultRowHeight` is 24 pt (a Retina default), so regenerating `<sheetFormatPr>` from the
model writes `24` into a file that said `15` and makes **every row in the workbook 60% taller in
Excel**. Only mark what you actually touched.

API: `WorkbookEditTracker` in `Sources/SheetFormat/XLSX/Write/DirtyTracking.swift` —
`noteCellsChanged(in:formulasChanged:)`, `note(_:_:)`, `noteSheetReplaced(_:)`,
`noteWorkbookMetadataChanged()`, `noteStylesChanged()`, `notePartStructureChanged()`, `reset()`
(only after a *successful* save).

## 3. Save fingerprints bridge A2 → A6 (A8)

`XLSXWriter.save(...)` returns a `SavedFileFingerprint` (path, inode, deviceID, mtime, size,
SHA-256 `contentHash`). Hand it straight to A6's self-write suppressor. `matches(_:)` deliberately
compares path + size + hash and **not** timestamps, because a CoW clone or a cloud-sync round trip
changes metadata without changing a byte. Forget this wiring and the app refresh-loops after every
save.

## 4. Operations A2 refuses rather than half-doing (A8, A9)

Adding, removing or reordering a sheet throws `SheetError.notImplemented` in v0.1, as does saving a
workbook with `readOnlyReason != nil` or a sheet whose original part cannot be inflated. Gate the
corresponding UI and MCP tools behind `Flags`, and surface the refusal as a designed state (A5 ships
`EmptyStateModel` constructors for exactly this) rather than an alert dump.

## 5. Known staleness — say it in the UI, don't hide it (A8)

A2's honest list of what does not follow an edit. None of these are bugs to fix in v0.1; all of them
are things a user must not discover by surprise:

- **Charts and pivot caches** pointing at ranges whose values changed keep their old cached data.
  Excel re-reads a chart range on open; a pivot only refreshes on explicit refresh.
- **Conditional-format and data-validation `sqref`, table parts, drawing anchors** are copied
  verbatim and do **not** follow row/column insert or delete.
- `docProps` metadata (`modified`, `lastModifiedBy`) passes through untouched by design.
- `<dimension>` is widened, never narrowed.
- Rich text is matched by content, not index — an unedited rich-text cell round-trips exactly, but
  one whose flattened text collides with an earlier *plain* string entry loses its runs.

At minimum: when a workbook contains a chart or pivot and the user edits a cell, the sync chip or a
one-time inline note should say the chart's cached values are now stale. This is a two-line
affordance that prevents a class of "OpenSheets broke my chart" reports that would not be true.

## 6. Appearance is injected, never ambient (A8)

A5's `DS` reads **no** ambient state. Every decision is a function of an `AppearanceContext`
(scheme · reduceTransparency · increaseContrast · reduceMotion · accent). Create one
`AccessibilityAppearance`, observe the workspace notification through it, and inject
`.glassAppearance(appearance.context(for: colorScheme))` at the root. A4's renderer takes
`GridTheme.resolved(context)` — the same context object, so the grid and the chrome can never
disagree about the current appearance.

## 7. Still unverified: Microsoft Excel and Numbers (A10)

Neither is installed in this environment, so A2's round-trip fidelity is proven only against
`zipfile.testzip()` CRC recomputation and headless LibreOffice. **The by-hand Excel check in
PLAN.md §10.7 remains outstanding and is a release gate.** Files can be dumped for inspection with
`OPENSHEETS_WRITE_DUMP=<dir> swift test`.

---

## 8. ARBITRATION: there are two atomic writers and two fingerprints. A6's wins. (A8)

A2 and A6 each built an `AtomicWriter` and a fingerprint type. The plan told them to coordinate
through the integrator rather than duplicate; both landed one anyway, which is the predictable cost
of true parallelism and is cheaper to resolve now than to have prevented.

**Decision: `SheetStore` owns the write. `SheetFormat` owns the bytes.**

- **Use `SheetStore.AtomicWriter` and `SheetStore.FileFingerprint`.** Retire A2's
  `SavedFileFingerprint` and its URL-writing path.
- **Adapt A2's writer to return `Data`**, matching A6's `WorkbookWriting.encodeWorkbook(_:for:originalBytes:) -> Data`.

This is not a coin flip; A6's is the more careful design and owns the semantics that depend on it:

| | A2 `SavedFileFingerprint` | A6 `FileFingerprint` ✅ |
| --- | --- | --- |
| Volume identity | inode + path | **inode + `deviceID`** — inodes are only unique per volume, so an inode-only match can suppress a genuine external write |
| Timestamp | `Date` (a `Double`) | **`(seconds, nanoseconds)` integers** — `Date` is lossy at 2026-era epoch values, and suppression should not depend on float resolution |
| Hash | full-file SHA-256 | first 4 KB — cheap on a 100 MB workbook, and sufficient combined with size + ns-mtime + inode + device |
| Race window | fingerprint only | **`beginWrite`/`endWrite` bracket + fingerprint** — closes the window where the watcher sees the new file before the writer returns |

The structural reason matters more than the table: SheetStore owns the atomic write, the fingerprint
**and** the pre-save snapshot, so a format writer physically *cannot* bypass any of the three. Let
A2's writer write to a URL and "snapshot before every save" degrades from a structural guarantee
into a rule someone remembers at each call site.

## 9. `WorkbookIO` is the seam you wire (A8)

`SheetStore(mode:configuration:)` → `store.openDocument(at:io:options:)` where
`io = WorkbookIO(reader:writer:)`. Conform A1's reader to `WorkbookReading` and A2's writer to
`WorkbookWriting`. `DocumentSession` is an actor exposing `state`, `workbook`, `pendingDiff`,
`hasUnsavedEdits`, an `AsyncStream<DocumentSessionEvent>`, and the verbs `edit {}` / `save()` /
`refresh()` / `resolveConflict(_:)` / `saveAs(to:)` / `snapshotHistory()` / `restore(_:)` /
`setAutoRefresh(_:)`. **The app and the MCP server must share one `SelfWriteSuppressor`.**

## 10. The state machine names its I/O — don't re-implement it (A8)

`DocumentSyncState.transition(on:context:)` is a pure total function returning `[SyncEffect]`. It
does no I/O; it *names* the I/O to perform. Execute the effects it returns rather than deciding for
yourself when to snapshot or reload — that is exactly what makes "snapshot before every refresh and
every save" structural. Three invariants are asserted across the whole 9 × 19 table: only
`conflictResolved(.takeDisk)` ever discards local edits; no reload starts over unsaved edits; no
`saveFailed` ever lands in `SYNCED` (disk-full stays `DIRTY` and complains).

Two edges beyond PLAN.md §6.3's diagram, both correct: `STALE + userEdited → CONFLICT` (so ⌘S
can't clobber), and `LOCKED`/`READ_ONLY` persist across a reload rather than being replaced by
`RELOADING` — the lock is a fact about the file, the reload is an activity.

## 11. Formula engine handoff (A8, A9)

```swift
var engine = FormulaEngine(workbook: workbook)
engine.setFormula("SUM(A1:A9)", at: SheetCell, in: workbook)   // false = refuse the edit
let result = engine.recalculate(in: workbook, changed: Set<SheetCell>, includingVolatile: true)
result.apply(to: &workbook)
```

- **`includingVolatile: false` is the keystroke path** — skips `NOW`/`RAND`/`OFFSET`/`INDIRECT`.
  Use it while typing; use `true` on commit.
- `result.outcome(for:)` returns `.value` or `.keepCached(reason)`. **Render `.keepCached` as stale
  (dotted underline) — never as a computed value.** Staleness propagates to dependents by design.
- `ReferenceTransform.translate(formula:from:to:)` for copy and fill-down;
  `.adjust(formula:for:resolving:)` for row/column insert and delete;
  `.adjust(_ range:on:for:)` for defined names and merges; `.cycleAnchoring(_:)` for F4.
- `FormulaGrammar.default` is **Excel's** semantics (`-2^2 == 4`, `2^3^2 == 64`). Do not change it;
  see the doc comment for the data-corruption scenario it prevents.

## 12. Two smaller things

- `SheetStore` declares a dependency on `SheetFormat` in `Package.swift` but imports nothing from
  it. Drop it for faster incremental builds unless A8's wiring needs it.
- A2's writer throws `SheetError.notImplemented` for add/remove/reorder sheet in v0.1 (see §4).
