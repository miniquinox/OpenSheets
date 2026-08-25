# T1–T8 — File tabs & change tracking

The feature plan is [`.claude/plans/file-tabs-and-change-tracking.md`](../../.claude/plans/file-tabs-and-change-tracking.md).
Eight agents, three waves; this page is the record of **who owns what**, so the next person to touch
one of these files knows which contract they are standing on.

| Agent | Wave | Brought |
| --- | --- | --- |
| T1 | 1 | `TabsModel`, and the one-workspace-window rules |
| T2 | 1 | the baseline, the checkpoint, and the snapshot reason behind it |
| T3 | 1 | the grid's standing green/amber/red tints |
| T4 | 1 | the tab strip, the changes chip and panel, and their tokens |
| T5 | 1 | `GitFileVersion` — the committed bytes, via a subprocess |
| T6 | 2 | the workspace window, the title-bar strip, the menu commands |
| T7 | 2 | the diff-to-tints mapping, the theme bridge, the git adapter |
| T8 | 3 | integration, the end-to-end walk, and these docs |

## New files, and their owner

| File | Owner |
| --- | --- |
| `Packages/OpenSheetsCore/Sources/DocumentCore/TabsModel.swift` | T1 |
| `Packages/OpenSheetsCore/Sources/DocumentCore/BaselineTracker.swift` | T2 |
| `Packages/OpenSheetsCore/Sources/DocumentCore/ChangeHighlightsMapping.swift` | T7 |
| `Packages/OpenSheetsCore/Sources/DocumentCore/GitBaselineAdapter.swift` | T7 |
| `Packages/OpenSheetsCore/Sources/GridKit/ChangeHighlights.swift` | T3 |
| `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/FileTabStrip.swift` | T4 |
| `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/ChangeTracking.swift` | T4 |
| `Packages/OpenSheetsCore/Sources/SheetStore/GitFileVersion.swift` | T5 |
| `App/WorkspaceTabsSupport.swift` | T6 |
| `Packages/OpenSheetsCore/Tests/DocumentCoreTests/TabsModelTests.swift` | T1 |
| `Packages/OpenSheetsCore/Tests/DocumentCoreTests/BaselineTrackingTests.swift` | T2 |
| `Packages/OpenSheetsCore/Tests/DocumentCoreTests/ChangeHighlightsMappingTests.swift` | T7 |
| `Packages/OpenSheetsCore/Tests/GridKitTests/ChangeHighlightTests.swift` | T3 |
| `Packages/OpenSheetsCore/Tests/SheetStoreTests/GitFileVersionTests.swift` | T5 |

Substantially reshaped rather than created: `App/DocumentWindow.swift` and `App/OpenSheetsApp.swift`
(T6), `DocumentCore/DocumentWindows.swift` (T1), `DocumentCore/DocumentModel.swift` and
`DocumentCore/AppModel.swift` (T2).

## Things worth knowing before you edit any of it

**The typed-throws closure trap.** `TabsModel`'s `open` hook is `throws(SheetError)`, and a closure
literal's *thrown* type is not inferred from the parameter it is passed to — so the short form does
not compile and the error reads like a contract mismatch. Spell the signature out in full; there is
a worked example on `TabsModel.init`.

**`CellChange` is ambiguous** in any file importing both `SheetModel` and `GlassUI`:
`GlassUI/Sync/SyncModels.swift` declares its own, deliberately, because `GlassUI` may not import
`SheetModel`'s diff types. Qualify as `SheetModel.CellChange`.

**The density decision belongs to the mapping, never to the renderer.**
`ChangeHighlightsMapping` returns no tints *plus a reason*, so the shell can say what it did. A
renderer that made that call itself would leave the grid unpainted with nobody able to explain why —
which is the failure the type exists to prevent.

**Two baseline generations, and they are not interchangeable.** `baselineGeneration` counts every
move of the baseline and guards diff results. `baselineChoiceGeneration` counts only the user's own
choices — `setCheckpoint()` and `setBaselineSource(_:)` — and guards the restore of a persisted
checkpoint. Using the first for the second is a bug T8 fixed: recalculation on open moves the
baseline on any workbook with formulas, which silently ate the checkpoint on every relaunch.

**Two preference keys and one UserDefaults pair** carry all of it: `workspace.tabs` and
`checkpoint:<canonical path>` in the SQLite `preference` table, `OSChangeHighlights` and
`OSFlagChangeTracking` in `UserDefaults`. Deleting the two preference rows is a clean slate; unknown
keys are never read, so a rollback leaves them behind harmlessly.
