# MCP file lifecycle and app takeover

**Goal.** The MCP server can **create** a workbook (`new_workbook`), **delete** one (`delete_file`,
snapshot-first, to the Trash), and **take over the app's display** (`open_in_app`: launch OpenSheets
if needed, open the file, front the window, select a sheet and range). Read/update already exist.
Also: `set_format` learns `freezeRows`/`freezeColumns`. Surface goes 22 → 25 tools.

**Why now.** Two real sessions hit the walls: one had to scaffold a workbook with openpyxl in a venv
because no create tool exists; `reveal_range` answered "the app is not open on this file; nothing was
revealed" because it is deliberately polite. The polite tool stays; the takeover tool is new.

## Verified facts (file:line, checked today)

- `AppHandshake.requestReveal` (`Sources/SheetMCP/Documents/AppHandshake.swift:107-119`) **guards on
  `presence(for:) != nil`** and takes non-optional sheet/range. Correct for polite reveal; wrong for
  takeover — a new `requestOpen(url:sheet:range:)` (optional args, **no presence guard**) is needed.
- The app-side consumer already handles everything: `HandshakeReveal.sheet/range` are optional
  (`Sources/DocumentCore/HandshakeRevealConsumer.swift:14-21`), parsed as optional (`:248-249`),
  sheet-switch at `:275-276`, selection+scroll at `:279-281`; it opens files not yet open through
  `OpenActions.open`, and sweeps the request directory **at startup** with a 90 s staleness cut —
  so a request written just before launching the app is consumed. **No DocumentCore/App changes.**
- `Sheet.frozenRows`/`frozenColumns` are public vars (`Sources/SheetModel/Sheet.swift:21,33-39`);
  describe already reads them and fixtures round-trip them, so the writer encodes them.
- `SheetError` has `fileNotWritable(path:underlying:)` (`SheetError.swift:204`) — reuse for
  "already exists" and every creation refusal. **No SheetModel edits** (frozen module).
- `Workbook` has public inits (`SheetModel/Workbook.swift:53,211`); the writer encodes complete
  packages on every save (`TrackedWorkbookWriter` in `Sources/SheetMCP/Documents/WorkbookFileIO.swift:225+`,
  `WorkbookFormatSupport.writable = xlsx,xlsm,xltx,csv,tsv` at `:13`).
- `FileManager.trashItem(at:resultingItemAt:)` is Foundation — no AppKit, so the compile-time
  grant barrier is untouched.
- App bundle id: `com.quino.opensheets` (pbxproj). `open -b` on a running app activates it and
  delivers the file as a reopen event → the same `OpenActions.open` funnel; on a cold machine it
  launches. Idempotent, so `open_in_app` needs no "is it running" detection.

## Design (locked)

### `new_workbook` — create
- Args: `path` (required; absolute; grant-checked FIRST; extension must be in
  `WorkbookFormatSupport.writable`), `sheets` (optional array of strings, xlsx-family only —
  **refuse with a clear message for csv/tsv**, which are single-sheet by nature; default one sheet
  named `Sheet1`), `preview`.
- **Refuses to overwrite**: existing file at `path` → `fileNotWritable` with "already exists —
  new_workbook never overwrites; write_range edits the file that is there". Creation is the one
  write where "exists" is an error, not a snapshot.
- Builds an empty `Workbook` value (one `Sheet` per name, in order; validate names non-empty,
  distinct case-insensitively — duplicates → `tool.invalidArguments`), encodes through the same
  writer the app uses, writes via the existing atomic path. No snapshot (nothing to lose).
  Sidesteps the v0.1 `add_sheet` refusal entirely: that refusal is about mutating an *existing*
  archive; this generates a fresh one, which is what every save already does.
- Result: `created <path> · N sheets (Name1, Name2, …)` — sheet names are caller-supplied, so echo
  them through `UntrustedContent.inlineCell`. `isReadOnly: false`, `isDestructive: false`.
- Update `SheetTools.addSheet`/`deleteSheet` refusal text to point at `new_workbook` for the
  from-scratch case.

### `delete_file` — delete
- Args: `path` (required), `preview`. `isDestructive: true`.
- Order: grant check via the same chokepoint as every tool (`broker.resolve` — grant + readable
  format, so only spreadsheet files the surface can touch can be deleted), then **snapshot the
  bytes first** (the existing per-write snapshot machinery, reason string "before delete_file"),
  then `FileManager.trashItem`. Result names both safety nets:
  `trashed <path> (recoverable from the Trash) · undo: restore(path, "<snapshot-id>")` —
  `restore` recreates a deleted file because snapshots hold raw bytes and the restore path writes
  atomically whether or not the file exists (verify with a test; if restore refuses a missing
  target, fix the restore path in the same change — that is in-scope integration).
- Preview: `preview only, nothing trashed · would trash <path> (N bytes, M sheets)`.
- If the app has the file open: the app's existing watcher emits `.vanished` and the tab shows its
  designed missing state — no new app work; state it in the result ("the app will show the tab as
  missing").

### `open_in_app` — display takeover
- Args: `path` (required, grant-checked first), `sheet` (optional), `range` (optional; if both
  given and range is sheet-qualified they must agree — reuse the existing range-grammar rule),
  `preview` (declared; preview = validate + report what would be shown, no request written, no
  launch).
- Behaviour: write the request file via new `AppHandshake.requestOpen` (no presence guard —
  the startup sweep is the reader when the app is cold), then launch/activate via
  **`/usr/bin/open -b com.quino.opensheets -- <path>`**. Always both; `open` is idempotent
  (running app → activate + reopen event; cold → launch, and the consumer's startup sweep applies
  the sheet/range). Result is honest about the contract: `asked OpenSheets to open <path>` plus
  `· sheet <s>` / `· range <r>` when given, and "the app fronts within a few seconds; the request
  expires in 90 seconds if it does not".
- **This is the server's first and only subprocess.** Constraints, stated in code and docs: the
  executable is the literal `/usr/bin/open`; the bundle id is a constant; the only variable
  argument is a path that has already passed the grant check; no shell is involved; stdout/stderr
  of the child go to /dev/null (fd 1 is the protocol stream — `claimStdout` protects it, but do
  not rely on that alone; set the child's stdio explicitly). The launcher is an injected closure
  (`(URL) -> Bool` or similar) defaulting to the real `Process` call, so tests never launch a GUI.
  `isReadOnly: true` (it changes what is on screen, not any file), matching `reveal_range`'s
  precedent at `AppHandshake.swift` (readOnly "because it does not touch the workbook").
- `reveal_range` is unchanged (the polite tool; its summary already says the app decides). Its
  summary gains one clause: "use open_in_app to launch the app or force the file open".

### `set_format` freeze panes
- Two new optional integer args on the existing tool: `freezeRows`, `freezeColumns`, each bounded
  `0…<the larger of Excel's pane limits and something sane — use 0…1_048_576 rows / 0…16_384 cols
  via the bounded accessor>`; `0` explicitly unfreezes. Applies to the target sheet (range's sheet
  or default). Add both to `PagingArgumentBoundsTests.pagingArguments`. Result line mentions the
  freeze change in the diff summary.
- CLI: they ride `format`'s existing key=value scheme (`freezeRows=1`) — no new flags.

### CLI parity (CLISurfaceTests enforce it)
- `new <file> [sheet ...]` → `new_workbook`
- `delete-file <file>` → `delete_file` (destructive verbs spell themselves out; `--preview` works)
- `open <file> [range]` → `open_in_app` (`--sheet` flag exists already)

### Error codes
Reuse only: `grant.*` (from the check), `fileNotWritable` (exists/refusals),
`tool.invalidArguments` (bad sheet names, csv+sheets), `workbook.unsupportedFormat` (bad
extension), snapshot codes. **No new SheetError cases; no SheetModel edits.**

### Security posture (docs must state)
- Deny list untouched; every new tool's first act on `path` is the grant check.
- `delete_file` is double-recoverable (snapshot + Trash) and never hard-deletes.
- `open_in_app`'s subprocess is scoped as above; the server still makes no network requests and
  spawns nothing else. The "server never spawns anything" line in older docs becomes "spawns
  exactly one thing: `/usr/bin/open` on the user's own app, for a granted path, when asked".
- `new_workbook` cannot overwrite; `write_range` remains the only mutation path for existing bytes.

### Tests (registry suites extend automatically; every new tool must survive them)
`ProtocolTests.everyToolListsAValidSchema` (path+preview declared), `GrantEscapeTests`
(25+ escape paths × every tool — `open_in_app` and `delete_file` and `new_workbook` must all
refuse with `[grant.`/`[workbook.unsupportedFormat]` BEFORE any side effect: no request file, no
launch-closure call, no snapshot — assert the spy launcher was never invoked on a refused path),
`CLISurfaceTests`, `ShippedBinaryTests` (frame count = 2 + tools.count → 27 frames),
`PagingArgumentBoundsTests` (+freezeRows, +freezeColumns). New suite `FileLifecycleTests` (or fold
into a new `WorkspaceToolsTests`-style file): create/overwrite-refusal/multi-sheet/csv-refusal/
round-trip-describe; delete/snapshot/restore-resurrects; open_in_app writes the request the REAL
consumer parses (round-trip against `HandshakeRevealConsumer` from DocumentCoreTests is the
existing pattern — but SheetMCP cannot import DocumentCore, so assert the written JSON matches the
`{path, sheet?, range?, requestedAt}` shape and add one DocumentCoreTests round-trip only if a
file there is free — otherwise the existing consumer tests already parse this exact shape).

### Waves
1. **A1** — everything above in `Sources/SheetMCP/` + tests (one agent: the three tools share
   `ToolRegistry.swift`/`CLISurface.swift`/`CommandLine.swift`). No DocumentCore/App/SheetModel edits.
2. **A2** — docs truth pass (DOCUMENTATION.md §5 count 22→25, §5.6 Lifecycle subsection, §6 CLI,
   §8/§12 add_sheet story now pointing at new_workbook, §9 subprocess policy, README).
3. **A3** — integration: full build/test, live JSON-RPC against the rebuilt embedded binary
   (create → describe → format freeze → open_in_app spy/real → delete → restore), criteria table.
