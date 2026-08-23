# A8 — App shell, document model, and integration

**Wave 2 · parallel with A9 · blocked by ALL of Wave 1 being merged.**

## Mission
Assemble six independently-built components into an application that works. You write comparatively
little new logic; your job is wiring, state ownership, and making the seams invisible.

Read the Wave 1 agents' final reports before you start — they document the exact APIs you consume.

## Dependencies
A1 · A2 · A3 · A4 · A5 · A6 · A7 all merged and green.

## Files you own
```
App/**                                   ← you are the ONLY agent who may add files here
Packages/OpenSheetsCore/Sources/DocumentCore/**    ← new target: document model + commands
Packages/OpenSheetsCore/Tests/DocumentCoreTests/**
```
Adding the one new `DocumentCore` target is the **only** permitted `Package.swift` edit in Wave 2,
and you make it. Coordinate with A9 before touching that file.

## Files you must NOT touch
Any Wave 1 target's sources. If a Wave 1 component is wrong, file it and work around it — or ask the
integrator (A10) to arbitrate. Do not fork someone's component into `App/`.

## Build this

### 1. `DocumentModel` — `@MainActor @Observable`, one per open document
Owns: the current `Workbook`, the selection, the undo stack, the `DocumentSyncState` from A6, the
dirty-part set for A2, and the flash set for A4. Follows the house `@Observable` store pattern from
`SignalToNoise/Shared/Store.swift`, but **per-document, not a singleton** — a singleton store is
wrong for a document app and will bite you at the second window.

`AppModel` (`@Observable`, shared) owns: recents, workspace grants, preferences, MCP status.

### 2. Window + scene
`DocumentGroup` (or an `NSDocument`-backed scene if `DocumentGroup` fights you on the sync model —
choose deliberately and write down why). Compose A5's chrome around A4's `GridView`:
titlebar chip · toolbar · formula bar · sidebar · grid · sheet tabs · floating stats pill.
Multiple windows, multiple documents, the same file open twice (share one `DocumentModel`).

### 3. The core loop — the feature the app exists for
Wire A6's watcher → `DocumentSyncState` → A5's `RefreshPill` → A6's `SheetDiff` → A5's `DiffPanel` →
A1's reader → A4's `flash(refs:)`, plus the sidebar session feed. Then walk PLAN.md §1.2 step by step
and confirm each one behaves as written. **This is the demo; it has to be flawless.**

### 4. Editing
Cell edit → parse per PLAN.md §8 → A3 evaluates → A3 recalcs dependents → apply batch → mark parts
dirty → A4 repaints. Undo/redo via `UndoManager` with coalescing for typing. Copy/paste/cut
(pasteboard as TSV **and** as our own richer type, so an in-app paste keeps formulas and formats),
fill-down/right, fill-handle series detection, delete, insert/delete rows and columns (calling A3's
`ReferenceTransform`), sort, find/replace, and the ⌘K command palette.

**A refresh clears the undo stack** — the on-disk file is the source of truth after an external
change. Tell the user this in the diff panel, once, quietly.

### 5. Save
⌘S → A2's surgical writer with the dirty-part set → A6's `AtomicWriter` → fingerprint back to A6's
suppressor. Auto-save is **off by default** (a background save racing an agent's write is a bad
surprise); make it an explicit preference.

### 6. Menus, shortcuts, and native behaviours
Full menu bar, standard shortcuts, Services, `Open Recent`, `Restore snapshot…`, drag-and-drop onto
the dock icon and the window, Quick Look preview of the selection, printing (basic), and window
restoration. These are what make an app feel native; budget for them.

### 7. The Claude panel
Workspace path + grant state · MCP connected/not with a live tool count · `Open terminal here`
(Terminal or iTerm2 — whichever is the user's default — at the workspace root, with `claude`
**typed but not executed**) · the session change feed with click-to-jump.

## Acceptance criteria
- [ ] Every step of PLAN.md §1.2 works end to end against a real file edited by a real external process.
- [ ] Every edge case in PLAN.md §9 has a defined behaviour and a test or a documented manual check.
      Where behaviour is "show this state", assert the state, not the pixels.
- [ ] Open 5 documents at once, edit each, save each, refresh each — no cross-talk, no leaks
      (assert with a memory-graph check that closing a window deallocates its `DocumentModel`).
- [ ] Conflict flow: edit locally, have an external process write the file, verify the amber banner
      and that all three resolutions do exactly what they say. **No path loses data silently.**
- [ ] Undo/redo across 100 mixed operations returns the workbook to a byte-identical save.
- [ ] Paste 100,000 cells completes in < 2 s without beachballing.
- [ ] App launches to a usable window in < 500 ms cold.
- [ ] Zero strict-concurrency warnings; runs clean under Thread Sanitizer for a 5-minute session.
- [ ] `Flags` gate anything not ready; the app is shippable with flags off.

## Report back
Which Wave 1 APIs needed adaptation and why, anything you had to work around, and a screen recording
of the core loop.
