# Wave 3 notes — what A10 must close

Accumulated from every wave. **Everything here is either unverified, deliberately deferred, or a
known defect.** Nothing in this list is a surprise; the point is that none of it should be a
surprise to a *user* either.

---

## 1. Release gates that are genuinely open

### 1.1 Nobody has opened our output in Microsoft Excel or Numbers
Neither is installed in the build environment. A2's round-trip fidelity is proven against
`zipfile.testzip()` CRC recomputation and headless LibreOffice only. **PLAN.md §10.7 makes a
by-hand Excel check a release gate and it has never been run.** Dump files with
`OPENSHEETS_WRITE_DUMP=<dir> swift test`. Verify at minimum: `passthrough/kitchen-sink.xlsm`
(chart + pivot + image + macros + conditional formats) opens clean after an edit-and-save, and
`formats/dates-1904.xlsx` shows the same wall-clock dates as its 1900 twin.

If Excel is unavailable to you too, **say so in the release notes** rather than implying it passed.

### 1.2 `claude mcp add` against the live client
A9 drove the shipped `opensheets-mcp` binary over real JSON-RPC as a subprocess (initialize,
version negotiation, notifications, `tools/list`, `tools/call`, malformed-frame recovery, EOF
shutdown) — 6 subprocess tests, and I re-verified the handshake independently. What has **not**
happened is registration with the real Claude Code client: the headless path failed with an expired
OAuth session, and registering persistently means writing `~/.claude.json`, which A9 correctly
declined to do unasked in a non-interactive session.

This is a **user action, not an agent action.** The command is:

```
claude mcp add opensheets -- <abs-path>/opensheets-mcp && claude mcp list
```

### 1.3 No fuzz target
PLAN.md §10.4 wants a nightly fuzz job over the parser. A1's reader exists now, so the target is
buildable, but neither it nor the ASan-over-hostile CI job has been written. `perf.yml` has the
nightly schedule; `ci.yml` needs the jobs.

### 1.4 Cold-launch time is unmeasured
PLAN.md §10.6 says < 500 ms. The window appears immediately and the parse is async, but no number
has been taken.

---

## 2. Known defects, deliberately shipped or deferred

| Thing | Consequence for a user | Where |
| --- | --- | --- |
| **Rich text matched by content, not index** | A rich-text cell whose *flattened* text collides with an earlier plain-string entry loses its formatting runs on save. Narrow but real. Fix needs A1 and A2 changed together. | addendum §14 |
| **Chart / pivot cached values go stale** | Edit a range a chart reads and its cached series are stale until Excel reopens it. Pivots need explicit refresh. | Wave-2 addendum §5 |
| **`sqref` ranges don't follow structural edits** | Conditional formats, data validation, table parts and drawing anchors keep their original ranges after a row/column insert. | Wave-2 addendum §5 |
| **Sheet add/remove/reorder refused** | `Flags.sheetStructureEditing` is off; the tab bar `+` and Delete are inert, and the MCP tools refuse with an alternative. Honest, but incomplete. | Wave-2 addendum §4 |
| **Find and replace does not exist** | ⌘F opens the command palette (go-to-cell, sheets, named ranges). PLAN puts find/replace in v0.4. | A8 report |
| **`New Sheet` demands a save location up front** | An untitled workbook cannot be watched, snapshotted, or reached by Claude Code, so it is saved before it is opened. Defensible; document it. | A8 report |
| **CLI cannot grant a folder** | Neither binary links AppKit, so `UserGrantAuthorization` is unreachable by construction. The CLI depends on the app for its first grant. Deliberate and security-positive; a real UX consequence. | A9 report |
| **Printing, Quick Look, Services, window restoration** | Not built. Menus, shortcuts, Open Recent, and drag-and-drop are. | A8 report |
| **`DocumentSession.performSave` reads the whole file** to build `originalBytes`, which our writer ignores (it works from `workbook.passthrough`). Wasted read on a 100 MB workbook. | A8 report |

---

## 3. Fragilities worth a decision

### 3.1 `CLI/` is reached through symlinks
SwiftPM refuses a target `path:` outside the package root, so
`Packages/OpenSheetsCore/Sources/opensheets` is a symlink to `../../../CLI/opensheets`. It builds,
and git stores symlinks faithfully, so a fresh clone on macOS works. It will break under any
tooling that dereferences or flattens symlinks (some archive extractors, some CI caches).

**Recommendation:** make `CLI/` its own SwiftPM package depending on `../Packages/OpenSheetsCore`.
That is a normal multi-package layout, keeps the plan's directory structure, and removes the
symlink entirely. Low risk, worth doing before the first release.

### 3.2 `SheetError.pathDenyListed`'s recovery text is wrong
It says "grant the folder in the app", which is exactly what a user must *not* be told for a
deny-list hit — `~/.ssh` is never grantable. A9 overrides it locally in `ErrorText` rather than
touching a Wave 1 target. Fix it at the source.

### 3.3 `SheetStore` declares a dependency on `SheetFormat` it does not use
Drop it for faster incremental builds unless A8's wiring needs it.

---

## 4. What could not be driven through the UI
This environment has no assistive access, so A8 could not click. The refresh pill was **captured**;
the morph to the diff panel, ⌘R, and the conflict banner are tested at the model level against a
real out-of-process `mv` but have **never been seen working**. If you also cannot drive the UI, say
so plainly and hand the list to the user as a manual check.

---

## 5. What is genuinely solid, so don't re-litigate it
- 983+ tests green, zero warnings, strict concurrency throughout.
- Grant enforcement: 860 in-process checks + 147 against the shipped binary, **zero escapes**, each
  refusal asserted to happen for the right reason, with positive controls so a vacuously-permissive
  bug fails loudly.
- Per-entry xlsx passthrough verified against all 8 `passthrough/` fixtures, cross-checked with an
  independent CRC recomputation and LibreOffice.
- `describe` measured at 191 estimated tokens for a 50,001-row workbook, and structurally
  row-independent (asserted: 50 rows and 50,000 rows produce identical line counts).
- Grid: p99 4.35 ms against an 8.3 ms budget, zero dropped frames, on a machine at 174% load.
