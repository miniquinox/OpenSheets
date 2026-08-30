# Workspace file explorer — verification

Against `.claude/plans/workspace-file-explorer.md`. Seven tasks, four waves. Everything below was
measured on the machine, not taken from an agent's report — two of the defects found here were
things an agent reported as passing.

**Result: shipped.** Full suite green apart from one pre-existing flake, both surfaces verified
running, both flag states verified running, four defects found and fixed during integration.

---

## 1. The gate

| Command | Result |
| --- | --- |
| `Scripts/build.sh` | `** BUILD SUCCEEDED **`, package + app target |
| `Scripts/build.sh --release` | `** BUILD SUCCEEDED **` |
| `swift test -Xswiftc -warnings-as-errors` | **1575 tests / 134 suites**, 8 pre-existing `withKnownIssue` |
| `swiftlint lint --strict` | clean on every file this plan touched |
| `swiftformat --lint` | clean on every touched file, once the six version-drift rules are excluded (see §5) |

**One failure is not ours.** `CoreLoopTests.autoRefreshAppliesWithoutBeingAsked` fails
intermittently — 1 in 3 runs of the single test in isolation, in 0.25 s, so it is a race and not a
load effect. Proven pre-existing by running it in a clean `git worktree` at `HEAD`, with none of
this work present: **2 failures in 5 runs.** Untouched, and out of scope.

## 2. The user flow (§4), walked in the running app

Verified against `/Applications/OpenSheets.app`, release build, ad-hoc signed as
`com.quino.opensheets`. Screenshots were taken with `screencapture -l <windowID>` against a window
id resolved from the app's own pid, so nothing outside the app's window was ever captured.

| § | Step | Result |
| --- | --- | --- |
| 4.1 | Launcher is two columns, 880×560, explorer rail on the left | **PASS** — window measured 880×592 (560 content + titlebar) |
| 4.1 | Rail headed `FOLDERS` with a `+`, one row per granted folder, collapsed, chevrons | **PASS** |
| 4.1 | Recents grid and pinned actions unchanged on the right | **PASS** |
| 4.1 | Expanding lists subfolders first, then spreadsheets, indented | **PASS** — `_s`, `_x`, `lo_out`, then `showcase.xlsx` |
| 4.1 | Non-spreadsheets are absent | **PASS** |
| 4.1 | File rows carry a size | **PASS** — `7 KB` |
| 4.2 | Sidebar `FILES` section, first, above `SHEETS` | **PASS** |
| 4.2 | Same roots, same tree, one model per process | **PASS** — identical root list in both surfaces |
| 4.2 | Section is height-capped and scrolls; `SHEETS` stays reachable | **PASS** |
| 4.4 | Root list dedupes nested grants | **PASS** — 7 active grants render as **5** roots; `…/OpenSheets/Demo` and `…/ExamAi-new` are inside `~/Documents` and correctly appear only under it |
| 5.3 | Flag off ⇒ pre-explorer launcher at 720×520 | **PASS** — window measured 720×552, single column, no rail |
| 5.3 | Flag off costs nothing at the model layer | **PASS** — see §3, defect 3 |

**Not verified by machine:** anything requiring a click. This session had no accessibility grant,
so expansion was exercised through the persistence path (seed `workspace.explorer`, relaunch,
observe the restored expansion and its listing) rather than by clicking a chevron. Hover, the
context menu, drag, and the search field's live behaviour are unverified. The click→action rule
itself is covered by `FileExplorerTests`.

### Amended 2026-08-29: one open folder, not every grant

The tree above showed **every granted folder**, and that was wrong. A grant is a standing
permission — *Claude may read here* — and there can be many; an open folder is *what I am working
in*, and there is one. Showing the first in a file tree meant the folder you had just opened was a
row among fifteen, and a folder granted inside one you already had (which is the common case —
four of four real attempts) appeared nowhere new at all.

Now: `WorkspaceTree.pinnedRoot` is the open folder, the tree shows that subtree and nothing else,
and with none open the section reads *"No folder open."* over an **Open Folder…** button.
Granting from the launcher opens the folder as a workspace — the window comes up with the tree on
the left and the empty state in the middle. Opening a folder from the sidebar's `+` changes the
tree and **nothing else**: the workbook in front stays in front and every tab stays open.

Verified in the running app: with a folder open the sidebar lists only that folder's contents
while the open tab is untouched; with none open it shows the button. The grant → new-window
transition still needs a click on an `NSOpenPanel` and is unverified by machine.

## 3. Defects found during integration, and fixed

Each of these was reported as passing by the agent that owned it. They are recorded because the
next plan should expect them.

**1. `WorkspaceTreeTests` was green alone and red together.** `--filter WorkspaceTreeTests` passed
27 tests in 0.5 s; the full 1575-test run failed 20 of them at ~14 s each. The suite polled a
five-second wall clock (`until(timeout:)`), and under 134 parallel suites the tree's detached
listing simply was not scheduled inside it — the test was measuring the machine's load. Fixed by
deleting the clock, not lengthening it: `WorkspaceTree.settled()` now exposes quiescence the way
`FileWatcher.poll()` does, and all 34 wait sites await it. *E4's file; E4 reported it passing
because it had only ever run the filtered form.*

**2. `Remove from List` silently did nothing on 2 of 5 roots.** Both hosts resolved a root row to
its grant with `grants.first { $0.path == id }`. A grant is stored as the open panel spelled it; a
node id is canonical, and `resolvingSymlinksInPath` rewrites `/private/tmp/x` as `/tmp/x`. Two of
the seven live grants differ exactly that way, so the match found nothing — a silent no-op on the
one control whose purpose is to undo a grant, which is the failure this whole feature exists to
delete. Fixed with `AppModel.grant(forRootID:)`, which compares canonically; both hosts route
through it. *Neither host owner could see it: E5 and E6 each owned one half of a mismatch whose
other half was in `DocumentCore`.*

**3. The flag did not cost nothing when off.** `Flags.explorerEnabled`'s doc comment promised "no
tree, no listing"; `AppModel` built the tree and called `setRoots` unconditionally, and restoring
last session's expansion would have started real directory listings with the UI hidden. Fixed by
withholding both the storage and the roots, and by making the doc comment describe what the code
does. Confirmed running: with the flag off the saved expansion is **not** overwritten. *Flagged by
E5, in E4's file — neither owned both sides.*

**4. Two plan defects of my own, caught by agents.**
- The plan told E5 to expand a new grant via `explorer.toggle(AppModel.documentKey(for: url))`.
  `documentKey` keeps a directory's trailing slash, so it yields `/Users/q/Reports/` against a node
  id of `/Users/q/Reports`, and `toggle` ignores unknown ids **silently** — this bug, reintroduced
  inside its own fix. Caught by E4, verified independently, replaced with `expandNewRoot(_:)`.
- Five acceptance criteria used `swift test --filter "Glass discipline"`. Swift Testing filters on
  test **IDs**, not `@Suite` display names: that form matches nothing, runs zero tests and **exits
  0**. Caught by E1. Every gate that was supposed to catch a stray spacing literal would have
  passed without running. Now `--filter GlassLintTests` throughout.

## 4. Permissions (§5.4), enforced where claimed

| Rule | Enforced | Evidence |
| --- | --- | --- |
| No listing outside an active grant | `DirectoryLister.list`, first statement | `DirectoryListerTests` — `/etc` throws `pathOutsideWorkspace` |
| Deny-list overrides a grant | same call | a `.env` folder inside a grant throws `grant.denyListed` |
| Symlinks cannot escape | same call, canonicalises first | a link to `/etc` inside a grant is refused |
| The UI cannot forge a path | structural | `grep -rn "FileManager\|URL(fileURLWithPath" Sources/GlassUI` (excluding `Gallery/`) → **no matches** |
| The tree cannot widen a grant | structural | `WorkspaceTree` holds a listing source and nothing else |

## 5. Rollout prerequisites

- **No migration.** `grep -n registerMigration Database.swift` still shows exactly `v1-tables` and
  `v2-recent-file-sequence`. State lives in the existing `preference` table under
  `workspace.explorer`. Rollback is `DELETE FROM preference WHERE key='workspace.explorer'`.
- **No environment variables, no secrets, no third-party services, one environment.**
- **`OSFlagExplorer`**, default on. Kill switch:
  `defaults write com.quino.opensheets OSFlagExplorer -bool NO`, effective at the next check.
- **The six design goldens are byte-identical.** The explorer draws no surface of its own
  (`grep -c 'glassCard\|glassPill\|glassChrome\|vibrantChrome\|glassEffect' FileExplorer.swift` → `0`),
  so it needs no `ComponentCatalog` entry.
- **Formatter drift.** Local swiftformat is 0.62.1 against a pinned 0.58.6, swiftlint 0.65.1
  against 0.61.0. A bare `swiftformat --lint .` reports ~4,552 repo-wide errors from rules absent
  from `.swiftformat` (`wrapIfStatementBodies`, `wrapPropertyBodies`, `wrapFunctionBodies`,
  `wrapLoopBodies`, `sortImports`, `blankLinesBetweenImports`). **Never run bare `swiftformat .`** —
  it rewrites ~4,500 lines across the repo. Grep the `--lint` output for your own filenames.

## 6. Known limits, by design

Stated in the source with their reasons. None is an omission.

1. **The tree does not watch the filesystem.** `FileWatcher` costs two descriptors and an FSEvents
   stream per *file*; `~/Documents` holds 77,024 directories. Refresh is explicit, plus one on
   `NSApplication.didBecomeActiveNotification`.
2. **"Every spreadsheet underneath" is a budgeted search, not a view.** Pruning empty folders means
   walking the subtree — 525,127 entries under one granted folder. The search stops at its budget
   and says so.
3. **Search results are sorted by (parent, name), not grouped under headers.** A real group header
   would be a folder row the tree does not know, whose chevron would emit a `.toggle` for an
   unknown id — a silent no-op, i.e. the thing being deleted.
4. **No rename, delete, or new-folder.** This is a reader.
5. **`App/` has no test target anywhere in this repo**, so `WorkspaceExplorerSupport.swift`,
   `LauncherScene.swift` and `SidebarColumn.swift` are covered by build, lint and the walkthrough
   above only.

## 7. Deliberately still unfixed

Found during recon, real, out of scope, and left alone so nobody thinks they were forgotten:

- `App/LauncherScene.swift` — "Remove from recents" discards the id and only reloads. It deletes
  nothing.
- `RecentItem.sheetCount` is hardcoded `0`, so every recent card reads "0 sheets".
- Security-scoped bookmarks are a no-op contract: the `workspace_grant.bookmark` column, the
  `UserGrantAuthorization` field, a `SheetError` case and the entitlement comment all exist;
  nothing calls `bookmarkData`. Harmless while the app is unsandboxed.
- `CLI/CommandLine.swift` and `DocumentModel.noteWorkspaceGranted` still point the user at a
  "File ▸ Grant Folder Access…" menu item and a Settings section that do not exist. The launcher's
  `+` is now the honest answer; the strings were not updated.

## 8. Cosmetic, worth a look

- The `FILES` header sits 8pt right of `SHEETS` in the sidebar: `FileExplorer` carries its own
  horizontal padding while the sidebar applies its own inset. The *rows* align correctly. Fixing it
  properly is a change inside `FileExplorer.swift`.
- `filesSectionMaxHeight = 220` is a first guess. `.frame(maxHeight:)` on a `ScrollView` nested in
  the sidebar's own `ScrollView` may reserve the full height even for a short tree.
