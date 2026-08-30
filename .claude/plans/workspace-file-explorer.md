# Workspace File Explorer — Master Plan

**Feature:** Make "Grant a folder…" produce something. A granted folder becomes a browsable,
VS Code-style lazy file tree of the spreadsheets inside it and its subfolders — in the launcher,
and in the document window's sidebar — from which a click opens the file.

**Written:** 2026-08-29. **Implementers:** parallel agents who cannot see the conversation that
produced this. Every contract they need is written out below. Follow it literally.

**Repo:** `/Users/quino/Documents/GitHub/OpenSheets` (this is *not* the ExamAi repo; nothing here
touches Supabase, ExamAi, or any web project).

---

## 0. Root cause — why "Grant a folder…" looks broken

This was verified against the live database and the source, not inferred.

**The grant is written.** `~/Library/Application Support/OpenSheets/OpenSheets.sqlite` currently
holds seven active rows in `workspace_grant`, two of them stamped `2026-08-29 19:24` — the user's
own test, minutes before this plan. The button works at the data layer. What is missing is every
visible consequence.

| # | Symptom | Cause | Fixed by |
| --- | --- | --- | --- |
| 1 | Granting shows no files | **Nothing in the repo ever enumerates a granted folder.** A repo-wide search for `contentsOfDirectory` / `enumerator(at:` finds only snapshot GC (`SheetStore/SnapshotStore.swift:204,233,294,318`), temp-file cleanup (`SheetStore/AtomicWriter.swift:164`), and tests. The MCP tool registry (`SheetMCP/Tools/ToolRegistry.swift:104-121`) has no directory-listing tool either. | E2, E4 |
| 2 | The one row it adds reads "granted, contains nothing" | `WorkspaceGrantItem.fileCount` (`GlassUI/Launcher/LauncherWindow.swift:50`) is rendered as a bare number, and the only production construction site hardcodes `fileCount: 0` (`App/LauncherScene.swift:48`). | E5 (row deleted) |
| 3 | Since the 2026-08-29 launcher rework, the grants list is **off-screen** | The "Folders Claude can reach" section moved inside the launcher's `ScrollView` (`GlassUI/Launcher/LauncherWindow.swift:271-289`), below sixteen recent cards. It used to be pinned at the bottom. **This is a regression introduced in the currently uncommitted working tree.** | E5 |
| 4 | From the *sidebar*, "Grant this folder" genuinely never changes state | `App/SidebarColumn.swift:89` computes `isGranted` as `app.store.grants.isAllowed(model.url)`. `store` is `@ObservationIgnored` (`DocumentCore/AppModel.swift:53`) and `WorkspaceGrants` is a plain `final class … Sendable` with a `Mutex`, not `@Observable`. The view never reads `app.grants` (`AppModel.swift:58`), so Observation registers no dependency and the label never flips. | E4 + E6 |
| 5 | A refused grant says nothing | `grantWorkspace` writes `lastError` (`AppModel.swift:284-294`); **no view reads it.** `revokeGrant` uses `try?` and drops the error entirely (`AppModel.swift:296-301`). A deny-listed folder fails in silence. | E4 + E5 |

So the delta this plan builds is: **an enumerator, a tree model, a tree view, two hosts, and an
error that is actually shown.**

### Deliberately NOT in scope

Found during recon, real, and left alone because the user did not ask for them. Listed so nobody
"helpfully" fixes them mid-task and collides with another agent:

- `App/LauncherScene.swift:78-80` — "Remove from recents" discards the id and only reloads. It
  deletes nothing. Needs a new `Database` method; out of scope.
- `RecentItem.sheetCount` is hardcoded `0` (`AppModel.swift:271`), so every recent card reads
  "0 sheets". Out of scope.
- Security-scoped bookmarks are a no-op contract: the `workspace_grant.bookmark` column
  (`SheetStore/Database.swift:81`), the `UserGrantAuthorization.bookmark` field, the
  `SheetError` case and the entitlement comment at `Config/OpenSheets.entitlements:15-17` all
  exist; **no code anywhere calls `bookmarkData` or `startAccessingSecurityScopedResource`.**
  Harmless today because the app is deliberately unsandboxed. Out of scope.
- `CLI/CommandLine.swift:671-681` and `DocumentCore/DocumentModel.swift:1115-1122` both tell the
  user to grant a folder via "File ▸ Grant Folder Access…" or "the Workspace section of
  Settings". **Neither exists.** Out of scope — but see E5's note, which makes the launcher the
  honest answer.

---

## 1. Project rules every agent must follow

There is **no `CLAUDE.md`** in this repo. The contract is `PLAN.md §13.1` plus `README.md:145-165`.
Restated here because agents do not inherit context:

1. **Own your files. Touch nothing else.** Each task below lists exact paths. If you believe you
   must edit a file outside your list, stop and report — do not edit it.
2. **`Packages/OpenSheetsCore/Sources/SheetModel/` is FROZEN.** No task here touches it. Model
   change requests go in `docs/agents/MODEL-CHANGE-REQUESTS.md`. This is why every new constant in
   this plan lives on its own type rather than being added to `Limits`.
3. **Never touch `OpenSheets.xcodeproj/project.pbxproj`.** New package sources need no manifest
   edit (SwiftPM globs the directory — `Package.swift:4-8`). New files under `App/` are picked up
   automatically: the app target is a `PBXFileSystemSynchronizedRootGroup` (`project.pbxproj:18`).
   **No task in this plan adds a new module**, so `Package.swift` is not edited by anyone.
4. **Ship it green.** From `Packages/OpenSheetsCore`:
   `swift build -Xswiftc -warnings-as-errors` and `swift test -Xswiftc -warnings-as-errors` must
   pass. Swift 6 language mode, strict concurrency, `ExistentialAny` (`Package.swift:26-29`) — so
   write `any DirectoryListingSource`, never bare `DirectoryListingSource`. No `TODO` standing in
   for an implementation; an honest `throw SheetError.notImplemented(...)` is fine, a silent wrong
   answer is not.
5. **Test what you build.** Every public function needs a test. Swift Testing only
   (`import Testing`, `@Test`, `@Suite`) — **XCTest appears nowhere in this repo and must not
   start now.** A suite that touches SwiftUI or AppKit is `@MainActor`; a suite that touches the
   filesystem is `@Suite(.serialized)`.
6. **Doc comments say *why*.** Match the house voice — see `App/OpenSheetsApp.swift:8-56` or
   `SheetStore/SelfWriteSuppressor.swift:11-19` for the register. Explain the constraint; be
   honest about what does not work. Cite `PLAN.md §N` where relevant.
7. **Formatting.** `swiftformat .` and `swiftlint lint` must pass (configs pinned at repo root;
   CI runs `--lint` / `--strict`, swiftformat 0.58.6, swiftlint 0.61.0). Gotchas that bite most:
   `--maxwidth 120`, `--wraparguments before-first` (an overflowing call puts *every* argument on
   its own line), `--commas always` (trailing commas required), `--ranges spaced` (`0 ..< n`, not
   `0..<n`), `--self remove`. SwiftLint treats `force_cast`, `force_try`, `force_unwrapping`,
   `fatalError(` and `NSError(` as **errors** (`.swiftlint.yml:77-97`).
8. **One commit per logical unit**, message `E<n>: <what>`, branch `agent/e<n>-<slug>`.
9. **Report at the end**: what you built, what you deliberately left out, what surprised you, and
   what a downstream agent will trip on.

### Three traps specific to this repo

**`swift test --filter` takes a regex over test *IDs*, never a `@Suite` display name.**
`--filter "Glass discipline"` matches nothing, runs zero tests and **exits 0** — a green that
proves nothing. Filter on the type name: `--filter GlassLintTests`, `--filter AppearanceSnapshotTests`,
`--filter DirectoryListerTests`. Confirmed by running both forms; the display-name form printed
`Test run with 0 tests in 0 suites passed`.

**The locally installed formatters are ahead of the versions CI pins** — swiftformat 0.62.1 against
a pinned 0.58.6, swiftlint 0.65.1 against 0.61.0. A bare `swiftformat --lint .` reports ~4,552
errors repo-wide from rules that are not in `.swiftformat` at all (`wrapIfStatementBodies`,
`wrapPropertyBodies`, `wrapFunctionBodies`, `wrapLoopBodies`, `sortImports`,
`blankLinesBetweenImports`), firing on canonical files like `FileTabStrip.swift` and
`WorkspaceGrants.swift`. Two consequences, both binding:
- **Never run bare `swiftformat .`** — it would rewrite ~4,500 lines across files you do not own.
- Use `--lint` only, and **grep the output for your own filenames**. A finding on your file from
  one of the rules listed above is noise; anything else is yours to fix.

### Two traps specific to this repo

- **`.claude/worktrees/agent-*/` contains complete stale copies of the repo**, including `App/`
  and the lint configs. They are not excluded from `swiftformat .`. **Never edit anything under
  `.claude/worktrees/`.** The canonical files are the ones at the repo root.
- **The working tree is currently dirty and uncommitted** (a change-highlight toggle plus a
  launcher layout rework, across `App/DocumentWindow.swift`, `App/DocumentCommands.swift`,
  `App/LauncherScene.swift`, `GlassUI/Launcher/LauncherWindow.swift`,
  `GlassUI/Chrome/WindowChrome.swift`, `DocumentCore/CommandRegistry.swift`,
  `Tests/GlassUITests/AppearanceSnapshotTests.swift`, and the six
  `docs/design/snapshots/*.txt`). **Every line number in this plan is against that dirty tree.**
  Do not `git stash`, do not revert, do not commit other people's changes with yours.

### The GlassUI lint, in full — anything under `Sources/GlassUI/` obeys all of it

Enforced by `Tests/GlassUITests/GlassLintTests.swift` as a text scan over source regions.

| Rule | What it means for you |
| --- | --- |
| Raw glass API is contained | Never write `.glassEffect(`, `.glassEffectID(`, `GlassEffectContainer(`. Only `Surfaces/GlassSurface.swift` may. Use `.glassCard(`, `.glassPill(`, `.glassChrome(`, `.glassSurface(`, `.vibrantChrome(`. |
| Cluster rule | Two or more glass elements in one region need a `GlassCluster { }`, or a `// glass-lint: separated — <reason>` annotation **plus** an entry in `GlassSource.separatedAllowList`. **The explorer draws no surface of its own, so this rule must not become relevant.** |
| Nothing layers on glass | No `.shadow(`, no `.border(`, no `.ultraThinMaterial`/`.regularMaterial`/`Material.` anywhere in the target. |
| Colour literals are centralised | No `Color(`, `RGBA(hex:`, or named hues (`Color.blue`, `.red`, …) outside `Tokens/`. `Color.primary`, `.secondary`, `.accentColor`, `.clear` stay legal. New colours go in `Tokens/Palette.swift`. |
| Accent is never hardcoded | No `007AFF`, no `NSColor.controlAccentColor`. |
| Motion is springs only | No `.easeInOut(`, `.easeOut(`, `.snappy(`. Use `DS.Motion.standard` / `DS.Motion.snappy`. |
| Numbers are tabular | A line mentioning `DS.Text.numeric` must use `.dsNumeric(…)`, not `.font(…)`. |
| Components take values, not singletons | No `@EnvironmentObject`, no `@StateObject`, no `.shared.`. Value in, action closure out. |
| **Spacing comes from the scale** | A bare numeric literal in `.padding(N)`, `.padding(.edge, N)`, `spacing: N` fails — **and this rule scans `App/` as well as `Sources/GlassUI/`.** `0` is legal. `DS.Space` is `hair 2, xs 4, s 8, m 12, l 16, xl 24, xxl 32`. Anything measured goes in `DS.Metrics` or a **named** constant. Expressions (`depth * DS.Space.m`) pass, because they are not literals. |

**Does the explorer need a `ComponentCatalog` entry and six re-recorded goldens?** No — *provided
it applies no glass or material surface of its own*, which is the design here (it is content
hosted inside the launcher's existing card and the sidebar's existing vibrant chrome).
`States/EmptyStates.swift` is the precedent: a real component with no catalog entry, because it
deliberately sits on no surface (`EmptyStates.swift:143-147`). E3's acceptance criteria pin this.
If an agent adds a `.glassCard(`/`.vibrantChrome(` to the explorer, they have created six golden
diffs and a catalog entry they did not plan for — don't.

---

## 2. What already exists (do not rebuild)

| Capability | Where | Use it for |
| --- | --- | --- |
| Grant records, path containment, deny-list | `SheetStore/WorkspaceGrants.swift` — `check(_ path:)` `:264`, `isAllowed(_:)` `:308/:313`, `activeGrants()` `:250`, `Mode` `:173` | **Every directory read goes through `check` first.** Do not re-implement containment. |
| Canonicalisation (realpath-style, 40-hop symlink cap) | `SheetStore/PathCanonicalizer.swift:26-75` | Turning a raw path into the identity everything keys on. |
| Deny-list (`~/.ssh`, `~/.aws`, `~/Library/Keychains`, `*.pem`, `.env*`, …) | `SheetStore/WorkspaceGrants.swift`, `DenyList.standard` `:31-42` | Already consulted inside `check`. Free. |
| Readable file extensions | `DocumentCore/WorkbookIOAdapters.swift:30` `workbookExtensions = ["xlsx","xlsm","xltx","xltm"]`, `:32` `delimitedExtensions = ["csv","tsv","txt","tab"]` | The filter set. Note this is **wider** than the Open panel's `OpenActions.readableTypes` (`App/OpenSheetsApp.swift:537-542`, four types). |
| Key/value preferences | `SheetStore/Database.swift:141` `preference(_:)`, `:149` `setPreference(_:to:)`. Existing key `workspace.tabs` (`App/OpenSheetsApp.swift:269`), namespacing precedent `checkpoint:<path>` (`DocumentCore/BaselineTracker.swift:170-183`) | Persisting which folders are expanded. **No schema change needed.** |
| Opening a file into the workspace | `OpenActions.open(_:consent:)` — `App/OpenSheetsApp.swift:464`; `TabsModel.open(_:consent:)` — `DocumentCore/TabsModel.swift:151` (dedupes on `AppModel.documentKey`) | Clicking a file in the tree. |
| Async-load model pattern | `DocumentCore/DocumentModel.swift:1055-1068` (detached + generation guard), `:1414-1449` (fire-and-forget restore), `:1451-1461` (the `nonisolated async` off-actor read idiom) | `WorkspaceTree` copies this shape exactly. |
| Row component with selection | `GlassUI/Chrome/Sidebar.swift:520` `SidebarRow` | The visual reference. **It has no depth, no chevron, no hover** — the explorer's row is new. |
| Hover idiom, context menu, named graphic sizes | `GlassUI/Chrome/FileTabStrip.swift:296` (hover), `:337-345` (context menu), `:355-364` (named sizes) | Copy these three patterns verbatim. |
| Unbounded-list scroll idiom | `GlassUI/Chrome/ChangeTracking.swift:387`, `Floating/CommandPalette.swift:165` (`LazyVStack(spacing: 0)`, `pinnedViews: [.sectionHeaders]`, `.scrollBounceBehavior(.basedOnSize)`) | The explorer's scroll container. |
| Section header | `GlassUI/Surfaces/Atoms.swift:117` `SectionHeader(_:trailing:)` | Section titles. |
| App-layer reducer namespace | `App/WorkspaceTabsSupport.swift:45` `static func tabStrip(for:asOf:)` | The shape `App/WorkspaceExplorerSupport.swift` must copy. |

**There is no tree, outline, or disclosure UI anywhere in this repo.** Repo-wide search for
`OutlineGroup`, `NSOutlineView`, `List(`, `Table(` returns nothing; the only `DisclosureGroup` is
`States/EmptyStates.swift:203`. The flattened-rows-with-depth approach below is therefore new
construction, and is chosen because the house pattern requires the expansion set to live in an
app-owned `Sendable, Hashable` state struct — which `OutlineGroup` cannot express.

---

## 3. The measurements that decide the architecture

Taken on the user's own machine, against the folders they have actually granted:

| Granted folder | Directories | Total entries | Spreadsheets |
| --- | ---: | ---: | ---: |
| `~/Documents` | 77,024 | **525,127** | 1,592 |
| `~/Documents/GitHub/ExamAi-new` | 4,386 | 45,687 | 138 |
| `~/Downloads` | 3,294 | 23,698 | 322 |

`~/Downloads` holds **3,109 entries in the single top-level directory.**

Three consequences, all binding:

1. **Enumeration is lazy and depth-1.** A folder is listed when it is expanded, never before.
   Nothing walks a tree eagerly. Ever.
2. **Every listing is capped** at `DirectoryLimits.pageSize` entries with an honest
   `omittedCount`, because one directory can hold three thousand things.
3. **"Show me every spreadsheet under here" cannot be the default.** Pruning folders that contain
   no spreadsheet requires knowing the subtree — 525k entries. It is offered as an explicit,
   **budgeted, cancellable search** that reports when it stopped early, in the same register as
   `WorkbookDiff.wasTruncated` and `ChangeTrackingPanelState.HighlightSuppression`.

---

## 4. User flow

There is one persona: the person using the app. No roles, no server, no tenancy.

### 4.1 Happy path — launcher

1. User launches OpenSheets with no file. The launcher window appears, **880 × 560**, two columns:
   a 248pt explorer rail on the left, recents and actions on the right.
2. The rail is headed `FOLDERS`, with a `+` button. Below it, one row per granted folder, each with
   a chevron, collapsed.
3. User clicks `+` (or `Grant a folder…`). `NSOpenPanel` opens, directories only.
4. They pick `~/Documents/GitHub/ExamAi-new`. The panel closes.
5. **The new root appears in the rail immediately, already expanded, with a brief spinner in its
   row**, and the rail scrolls it into view. This is the step that does not exist today.
6. Within ~100 ms the folder's contents replace the spinner: subfolders first (alphabetical,
   case-insensitive), then `.xlsx/.xlsm/.xltx/.xltm/.csv/.tsv/.txt/.tab` files. Everything else
   is not shown.
7. User clicks the chevron on `Outreach`. That folder alone is listed, one level, indented.
8. User clicks `nigeria decissions.xlsx`. The file opens in the workspace window exactly as a
   recent does — `OpenActions.open(url, consent: .fromOutsideTheApp)`.
9. The launcher window closes itself as it does today when a document window takes over.

### 4.2 Happy path — document sidebar

1. A workbook is open. The sidebar (⌘0) shows `FILES` as its first section, above `SHEETS`.
2. It is the same tree, the same roots, the same expansion state — one `WorkspaceTree` per
   process, so expanding a folder in the launcher leaves it expanded in the sidebar.
3. Clicking a file opens it **as a new tab** in the current window (`TabsModel.open`), not a new
   window. The active file's row is selected.
4. The section is height-capped so a deep tree cannot push `SHEETS` and the Claude panel out of
   reach; it scrolls within its cap.

### 4.3 Search

1. User types `budget` into the rail's search field.
2. The tree is replaced by a flat result list, grouped by parent folder, of spreadsheets whose
   name contains the string (case- and diacritic-insensitive).
3. The walk is bounded. If it hits its budget it stops and the list is footed with
   *"Stopped after 20,000 files — narrow the search or open a subfolder."*
4. Clearing the field restores the tree with expansion intact.

### 4.4 States

| State | What the user sees |
| --- | --- |
| No folders granted | Rail shows *"No folders yet."* over a `Grant a folder…` button. The `+` is still in the header. |
| Root expanded, listing in flight | The root row keeps its name and shows a `ProgressView().controlSize(.small)` where its chevron was. Rows do not jump. |
| Folder with no spreadsheets and no subfolders | One dimmed row, *"Nothing to open here."*, `DS.Chrome.tertiary`. |
| Folder listed but capped | A final dimmed row, *"+ 2,609 more"*, using `.dsNumeric(DS.Text.numericCaption)`. Not clickable. |
| Folder we may not read | Row is dimmed with an `exclamationmark.triangle` glyph and `.help("Not readable.")`. Its chevron is gone. **Not an alert, not a crash.** |
| Granted folder deleted or unmounted | Root row dimmed with `questionmark.folder`, and its context menu offers **Remove from list**. Matches how a missing recent renders (`LauncherWindow.swift:212-219`). |
| Grant refused (deny-listed, or not canonicalisable) | The launcher's existing rejection line — `Label(rejection, systemImage: "exclamationmark.circle")` at `LauncherWindow.swift:170-175` — shows the error's message. That field exists and renders today and **is never set**: `App/LauncherScene.swift:18` declares `@State private var rejection: String?` and nothing assigns it. |
| Search returned nothing | *"No spreadsheets match \"budget\"."* |

---

## 5. Design decisions

### 5.1 Layering — who is allowed to know what

```
GlassUI/Chrome/FileExplorer{Model,}.swift   pure SwiftUI. No URL, no FileManager, no DocumentCore.
        ▲ value in / action out
App/WorkspaceExplorerSupport.swift          reducer: [WorkspaceNode] → FileExplorerState
        ▲
DocumentCore/WorkspaceTree.swift            @MainActor @Observable. Expansion, laziness, search.
        ▲ any DirectoryListingSource
SheetStore/DirectoryLister.swift            the only thing that touches the disk. Grant-checked.
```

`GlassUI` may depend only on `SheetModel` (`Package.swift:83`). It must never see a `URL`. This
is the same rule that makes `App/SidebarColumn.swift:43-84` do all `FileManager` and `DateFormatter`
work before handing `Sidebar` a `FileInfo` of plain strings.

**The lister lives in `SheetStore`, not `DocumentCore`** — one deviation from "reuse the nearest
thing" worth justifying: grant enforcement lives in `SheetStore` and the check must be inside the
security boundary, not one layer above it where a future caller could skip it. It also leaves the
door open for an MCP `list_directory` tool without moving code.

### 5.2 No schema change

Expansion state and root ordering persist as JSON in the existing `preference` table under the key
`workspace.explorer`, exactly as `workspace.tabs` does (`App/OpenSheetsApp.swift:269`).

**DDL: none. Migration: none. Backfill: none. Rollback: delete the preference row** —
`sqlite3 ~/Library/Application\ Support/OpenSheets/OpenSheets.sqlite "DELETE FROM preference WHERE key='workspace.explorer';"`
A missing or corrupt value must degrade to "nothing expanded", never to an error.

### 5.3 Feature flag

`OSFlagExplorer`, **default `true`**. Every other flag except `sheetStructureEditing` defaults on
(`DocumentCore/AppModel.swift:366-387`), and the state this replaces is broken, so shipping it off
would ship the bug. Off must cost nothing: no tree built, no listing, and both hosts fall back to
exactly today's UI.

### 5.4 Permissions — assume the client is hostile

| Rule | Enforced where | Name of the check |
| --- | --- | --- |
| A directory outside every active grant cannot be listed | `SheetStore/DirectoryLister.list`, first statement | `grants.check(path)` (`WorkspaceGrants.swift:264`) — throws `SheetError.pathOutsideWorkspace` |
| A deny-listed path cannot be listed even inside a grant | same call | `DenyList.standard` inside `check` (`WorkspaceGrants.swift:31-42`) |
| A symlink pointing out of the grant cannot be followed | same call, because `check` canonicalises first | `PathCanonicalizer` (`PathCanonicalizer.swift:26-75`) |
| The UI cannot construct a path the lister will accept | structural: `GlassUI` never sees a `URL`; every id the view emits was minted by the lister from a checked listing | — |
| Opening a file still asks if it is outside a grant | `AppModel.load` `:184-195`, unchanged. The tree passes `consent: .fromOutsideTheApp`, the careful case, exactly as opening a recent does (`App/LauncherScene.swift:63`) | `confirmWorkspaceGrant` |
| The tree cannot widen a grant | structural: `WorkspaceTree` has no reference to `WorkspaceGrants` and no way to call `grant(_:)`; `UserGrantAuthorization`'s only initialiser is `@MainActor` over an `NSOpenPanel` result (`WorkspaceGrants.swift:104-117`) | — |

There is **no client-side-only guard anywhere in this design.** The view has no file access to
guard.

### 5.5 Validation

| Input | Rule | Where | Message on failure |
| --- | --- | --- | --- |
| Folder chosen in `NSOpenPanel` | must canonicalise, must not be deny-listed | `WorkspaceGrants.grant` → `AppModel.grantWorkspace` sets `lastError` | The `SheetError`'s own message, in the launcher's rejection line |
| Directory path to list | non-empty, absolute, passes `check` | `DirectoryLister.list` | throws `SheetError.pathOutsideWorkspace`; the row renders "Not readable." |
| `limit` | `1 ... 5_000`; clamped, never trapped | `DirectoryLister.list` | none — clamping is silent and documented |
| Search text | trimmed; empty ⇒ no filter; > 128 chars truncated | `WorkspaceTree.search` didSet | none |
| Persisted expansion JSON | must decode to `[String]`; each entry re-checked against a live grant on load | `WorkspaceTree` init | silently ignored, tree starts collapsed |
| A node id arriving from the view | must already exist in `nodes` | `WorkspaceTree.toggle/refresh/removeRoot` | ignored, no-op |

### 5.6 Edge cases

| Case | Behaviour |
| --- | --- |
| Same folder expanded twice quickly | Coalesced. `WorkspaceTree` keeps an in-flight `Set<String>`, mirroring `AppModel.opening` (`AppModel.swift:89`). |
| Listing lands after the node was collapsed or its root removed | Dropped by a generation guard, the shape at `DocumentModel.swift:1063-1067`. |
| One granted root is inside another (`~/Documents` and `~/Documents/GitHub/…` are both granted today) | The nested root is **not** shown as a second top-level row; it is reachable by expanding the outer one. Dedupe by path components, never string prefix. |
| A root is revoked while expanded | Its subtree disappears on the next `setRoots`. Any in-flight listing for it is discarded. |
| 3,109 entries in one directory | 500 shown, `omittedCount = 2609`, one "+ 2,609 more" row. |
| Symlink loop | `PathCanonicalizer`'s 40-hop cap (`PathCanonicalizer.swift:29`) refuses; the row renders unreadable. Additionally the tree refuses `depth > DirectoryLimits.maximumDepth`. |
| `.app` / `.rtfd` package directories | Treated as **files** (via the `isPackage` resource key), therefore filtered out by extension, therefore invisible. Never expandable. |
| A file clicked after it was deleted | Existing behaviour: the tab enters `.failed` (`TabsModel.Phase`, `TabsModel.swift:50-53`) and the empty state renders. The explorer does not pre-check. |
| Two windows, one tree | One `WorkspaceTree` on `AppModel`, so launcher and sidebar cannot disagree. |
| Search cancelled mid-walk (user keeps typing) | The previous `Task` is cancelled; `Task.isCancelled` is checked once per directory. |
| Files change on disk | **Not observed.** `FileWatcher` watches one file with two descriptors (`FileWatcher.swift:221-331`); pointing it at 77,024 directories is not viable. v1 refreshes on an explicit action and when the window becomes key. This is a deliberate, stated limit — say it in the doc comment. |

---

## 6. Contracts

These are written out in full because three agents compile against them in the same wave. **E1
writes them verbatim.** Nobody else changes them; if one is wrong, report it rather than editing.

### 6.1 `Packages/OpenSheetsCore/Sources/SheetStore/DirectoryListing.swift`

```swift
public struct DirectoryEntry: Sendable, Hashable, Identifiable {
    public var id: String { path }
    /// Canonical absolute path. The identity everything keys on, produced by the lister — never
    /// by the caller, and never by the view.
    public var path: String
    public var name: String
    public var isDirectory: Bool
    /// `nil` for directories and whenever the stat failed. Never a guess.
    public var byteCount: Int64?
    public var modifiedAt: Date?

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        byteCount: Int64? = nil,
        modifiedAt: Date? = nil
    )
}

public struct DirectoryListing: Sendable, Hashable {
    public var path: String
    /// Directories first, then files; within each, case- and diacritic-insensitive by name.
    public var entries: [DirectoryEntry]
    /// How many entries the page cap dropped. Surfaced, never swallowed — a list that silently
    /// stops at 500 is a list that lies about what is in the folder.
    public var omittedCount: Int
    /// False when the directory could not be read at all. Not an error: a folder inside a grant
    /// that the OS will not open is a normal thing to draw, not a thing to abort on.
    public var isReadable: Bool

    public static let unreadable: (String) -> DirectoryListing
    public init(path: String, entries: [DirectoryEntry], omittedCount: Int = 0, isReadable: Bool = true)
}

/// One directory, one level, already inside the grant boundary.
///
/// A protocol so `DocumentCore` can be tested against a fake without a filesystem, and so the
/// only implementation that touches the disk stays in the module that owns grant enforcement.
public protocol DirectoryListingSource: Sendable {
    /// - Parameter fileExtensions: lowercase, without the dot. Files not matching are omitted;
    ///   directories are always included.
    /// - Throws: `SheetError.pathOutsideWorkspace` when `path` is not inside an active grant or is
    ///   deny-listed. An unreadable-but-permitted directory returns `isReadable: false` instead.
    func list(
        _ path: String,
        fileExtensions: Set<String>,
        limit: Int
    ) throws(SheetError) -> DirectoryListing
}

/// Budgets. Named constants rather than `Limits` entries because `SheetModel` is frozen.
public enum DirectoryLimits {
    /// Entries per directory before `omittedCount` starts counting. `~/Downloads` holds 3,109 in
    /// its top level alone, so this is a real ceiling and not a theoretical one.
    public static let pageSize = 500
    /// Hard clamp on any caller-supplied limit.
    public static let maximumPageSize = 5_000
    /// Files a search may visit before it stops and says so.
    public static let searchEntryBudget = 20_000
    /// Directories a search may open before it stops and says so. `~/Documents` holds 77,024.
    public static let searchDirectoryBudget = 2_000
    /// How deep the tree may go. A symlink loop that survives canonicalisation still terminates.
    public static let maximumDepth = 12
}
```

### 6.2 `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/FileExplorerModel.swift`

```swift
public struct FileExplorerRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable, CaseIterable {
        case root, folder, workbook, delimited, note
        /// `note` is the "+ 2,609 more" / "Nothing to open here." row: not a file, not clickable.

        /// SF Symbol. Pure, and therefore tested — the same reason `FileTabDot` was extracted out
        /// of its view (`Chrome/FileTabStrip.swift:101`).
        public var symbolName: String {
            switch self {
            case .root: "folder.badge.gearshape"
            case .folder: "folder"
            case .workbook: "tablecells"
            case .delimited: "doc.plaintext"
            case .note: "ellipsis"
            }
        }
        public var isExpandable: Bool { self == .root || self == .folder }
        public var isOpenable: Bool { self == .workbook || self == .delimited }
    }

    public enum Load: Sendable, Hashable {
        case idle, loading, unreadable, missing
    }

    /// The canonical path, or `"note:<parent path>"` for a `.note` row.
    public var id: String
    public var name: String
    /// Right-aligned trailing text, already formatted by the app layer: "12 KB", "+ 2,609 more".
    public var detail: String?
    public var depth: Int
    public var kind: Kind
    public var isExpanded: Bool
    public var load: Load
    public var isSelected: Bool

    public init(
        id: String, name: String, detail: String? = nil, depth: Int, kind: Kind,
        isExpanded: Bool = false, load: Load = .idle, isSelected: Bool = false
    )

    public var isInteractive: Bool { kind != .note && load != .missing }
    public var accessibilityLabel: String
}

public struct FileExplorerState: Sendable, Hashable {
    /// Already flattened, in display order. The view does no tree walking.
    public var rows: [FileExplorerRow]
    public var search: String
    public var isSearching: Bool
    /// "Stopped after 20,000 files — narrow the search or open a subfolder."
    public var searchNote: String?
    /// Shown instead of `rows` when it is non-nil and `rows` is empty.
    public var emptyMessage: String?
    /// Whether to draw the `+` in the header. False in the sidebar, where granting lives in the
    /// Claude panel already.
    public var offersAddFolder: Bool

    public init(
        rows: [FileExplorerRow] = [], search: String = "", isSearching: Bool = false,
        searchNote: String? = nil, emptyMessage: String? = nil, offersAddFolder: Bool = true
    )
    public var isEmpty: Bool { rows.isEmpty }
}

public enum FileExplorerAction: Sendable, Hashable {
    case toggle(String)
    case open(String)
    case select(String)
    case refresh(String)
    case revealInFinder(String)
    case removeRoot(String)
    case addFolder
    case search(String)
}
```

### 6.3 `Packages/OpenSheetsCore/Sources/DocumentCore/WorkspaceNode.swift`

```swift
public struct WorkspaceNode: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case root, folder, file }
    public enum Load: Sendable, Hashable {
        case idle
        case loading
        case loaded(omitted: Int)
        case unreadable
        case missing
    }
    /// Canonical absolute path.
    public var id: String
    public var name: String
    /// 0 for a root.
    public var depth: Int
    public var kind: Kind
    public var load: Load
    public var isExpanded: Bool
    public var byteCount: Int64?

    public init(
        id: String, name: String, depth: Int, kind: Kind,
        load: Load = .idle, isExpanded: Bool = false, byteCount: Int64? = nil
    )
}

/// Where the expansion set is remembered. A protocol so the tree is testable without SQLite.
public protocol WorkspaceTreeStorage: Sendable {
    func expandedPaths() -> [String]
    func setExpandedPaths(_ paths: [String])
}
```

---

## 7. Agent tasks

### Agent E1 — Write the three contracts

**Goal:** the exact type declarations in §6 exist, compile, and are covered by tests for their pure
logic — so three agents in the next wave can build against them without waiting for each other.

**Depends on:** none — can start immediately.

**Files to create:**
- `Packages/OpenSheetsCore/Sources/SheetStore/DirectoryListing.swift`
- `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/FileExplorerModel.swift`
- `Packages/OpenSheetsCore/Sources/DocumentCore/WorkspaceNode.swift`
- `Packages/OpenSheetsCore/Tests/GlassUITests/FileExplorerModelTests.swift`
- `Packages/OpenSheetsCore/Tests/DocumentCoreTests/WorkspaceNodeTests.swift`

**Files to modify:** none.

**Do NOT touch:** `DirectoryLister.swift`, `FileExplorer.swift`, `WorkspaceTree.swift` — they do
not exist yet and belong to E2, E3, E4. Do not add a `ComponentCatalog` entry: these are value
types, not a surface.

**Context it needs:**
- Transcribe §6 of this document **verbatim**, filling in the bodies of the computed properties and
  the memberwise initialisers. Nothing more: no logic, no file access, no views.
- `accessibilityLabel` composes, in this order: the name, then `", folder"` / `", spreadsheet"` /
  `", delimited text"` for the kind, then `", expanded"` / `", collapsed"` for an expandable row,
  then `", not readable"` or `", missing"` when `load` says so, then `detail` if present. Model it
  on `FileTabItem.accessibilityLabel` (`Chrome/FileTabStrip.swift:68`).
- `DirectoryListing.unreadable` returns `DirectoryListing(path: path, entries: [], omittedCount: 0, isReadable: false)`.
- House voice on every public declaration. The `Load.missing` case, the `note` kind and the
  `omittedCount` field each need a sentence saying **why they exist**, not what they are.
- `SheetError` is in `SheetModel` and is **frozen** — use existing cases (`pathOutsideWorkspace`,
  `notImplemented`), never add one.
- Swift 6 + `ExistentialAny`: write `any DirectoryListingSource` at every use site.

**Implementation notes:**
- `FileExplorerModel.swift` goes under `Sources/GlassUI/Chrome/` and is therefore inside the glass
  lint's scan. It contains no view code, so the only rules that can bite are the colour-literal ban
  and the spacing ban — neither applies to a file with no `Color(` and no `.padding(`. Keep it
  that way.
- `Identifiable` + `Hashable` + `Sendable` on all three, because `SidebarState` is `Hashable` and
  will contain a `FileExplorerState` (E6).
- Do **not** give `WorkspaceNode` a `children` array. The tree is published flat, with `depth`.
  A recursive value type would make `Hashable` conformance quadratic and force the view to walk it.

**Acceptance criteria:**
1. `cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors` exits 0.
2. `swift test -Xswiftc -warnings-as-errors --filter FileExplorerModelTests` passes, and asserts:
   every `FileExplorerRow.Kind` returns a non-empty distinct `symbolName`; `isExpandable` is true
   for exactly `.root` and `.folder`; `isOpenable` is true for exactly `.workbook` and `.delimited`;
   `isInteractive` is false for `.note` and for `load == .missing`; `accessibilityLabel` for a
   collapsed folder named "Outreach" contains "Outreach", "folder" and "collapsed".
3. `swift test --filter WorkspaceNodeTests` passes and asserts `WorkspaceNode.Load.loaded(omitted:)`
   round-trips through `Hashable` and that two nodes with the same `id` and different `depth` are
   not equal.
4. `swift test --filter GlassLintTests` passes — no new lint violations.
5. `swiftformat --lint .` reports no error in any of the five new files; `swiftlint lint --strict`
   is clean for them.
6. No file outside the five listed above differs from `git HEAD` plus the pre-existing dirty set.

**Verification commands:**
```bash
cd /Users/quino/Documents/GitHub/OpenSheets/Packages/OpenSheetsCore
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors --filter FileExplorerModelTests
swift test -Xswiftc -warnings-as-errors --filter WorkspaceNodeTests
swift test -Xswiftc -warnings-as-errors --filter GlassLintTests
cd /Users/quino/Documents/GitHub/OpenSheets && swiftformat --lint . ; swiftlint lint --strict
```

---

### Agent E2 — The directory lister

**Goal:** `SheetStore` can list one directory, one level deep, inside the grant boundary, with a
page cap and no way to escape it.

**Depends on:** E1 (uses `DirectoryEntry`, `DirectoryListing`, `DirectoryListingSource`, `DirectoryLimits`).

**Files to create:**
- `Packages/OpenSheetsCore/Sources/SheetStore/DirectoryLister.swift`
- `Packages/OpenSheetsCore/Tests/SheetStoreTests/DirectoryListerTests.swift`

**Files to modify:**
- `Packages/OpenSheetsCore/Sources/SheetStore/SheetStore.swift` — add one stored property
  `public let directories: DirectoryLister` beside `public let grants` (`:53`), and one line in
  `init` (`:57`) constructing it from `grants`. Nothing else in that file.

**Do NOT touch:** `WorkspaceGrants.swift`, `PathCanonicalizer.swift`, `Database.swift`. You consume
them; you do not change them. `DirectoryListing.swift` belongs to E1.

**Context it needs:**
- The type to write:
  ```swift
  public struct DirectoryLister: DirectoryListingSource {
      private let grants: WorkspaceGrants
      public init(grants: WorkspaceGrants)
      public func list(_ path: String, fileExtensions: Set<String>, limit: Int) throws(SheetError) -> DirectoryListing
  }
  ```
  `Sendable` comes free (`WorkspaceGrants` is `Sendable`, `SheetStore/WorkspaceGrants.swift:171`).
- **The first statement of `list` must be `try grants.check(path)`** (`WorkspaceGrants.swift:264`).
  That single call does canonicalisation, path-component containment and the deny-list. **Do not
  re-implement any of it, do not compare paths with `hasPrefix`** — PLAN.md §7.2 forbids it
  explicitly (`/Users/q/work-secret` must not match `/Users/q/work`).
- Enumerate with
  `FileManager.default.contentsOfDirectory(at:includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])`.
  A thrown error from that call is **not** propagated — return `DirectoryListing.unreadable(path)`.
  Only the grant check throws.
- `isPackage == true` means `.app`, `.rtfd`, `.bundle`: treat as a **file**, so it is then dropped
  by the extension filter. A user must never be able to descend into an app bundle from here.
- Each surviving entry's `path` is the canonical path, obtained by resolving the child URL the same
  way `AppModel.documentKey` does: `url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)`
  (`DocumentCore/AppModel.swift:356-358` — copy the expression, do not import DocumentCore).
- Sort: `isDirectory` descending, then
  `name.compare(other, options: [.caseInsensitive, .diacriticInsensitive, .numeric])`.
- Cap: clamp `limit` into `1 ... DirectoryLimits.maximumPageSize`, sort **before** truncating, set
  `omittedCount = max(0, sorted.count - clamped)`.
- `list` is synchronous and `nonisolated`. Callers hop off the main actor themselves — that is the
  house idiom (`DocumentModel.swift:1451-1461`). Say so in the doc comment.
- Tests: `@Suite(.serialized)` because they touch the filesystem — the convention every
  `SheetStoreTests` filesystem suite follows. Build fixture trees under
  `FileManager.default.temporaryDirectory` and grant them through a `WorkspaceGrants` in
  `Mode.app` backed by an in-memory `WorkspaceGrantStoring` fake; `Tests/SheetMCPTests/GrantEscapeTests.swift:30-80`
  shows how a symlink-escape fixture is laid out.

**Implementation notes:**
- No `force_try`, no `try!` — SwiftLint errors on them.
- `throws(SheetError)` typed throws, matching `check`.
- Doc comment must state the three things this deliberately does not do: no recursion, no watching,
  no caching. Each is somebody else's job and saying so stops the next person adding it here.

**Acceptance criteria:**
1. `swift build -Xswiftc -warnings-as-errors` exits 0.
2. Listing a granted temp directory containing `a.xlsx`, `b.csv`, `notes.md`, `.hidden.xlsx`, and
   subdirectory `sub/` with `fileExtensions: ["xlsx","csv"]` returns exactly 3 entries in the order
   `sub`, `a.xlsx`, `b.csv`; `omittedCount == 0`; `isReadable == true`.
3. `list("/etc", …)` throws `SheetError.pathOutsideWorkspace` — no grant covers it.
4. Listing a path under a granted folder but matching the deny-list (create `<grant>/.env`'s parent
   case per `DenyList.standard`) throws rather than returning entries.
5. A directory symlink inside the grant pointing at `/etc` is not followed: the resulting entry's
   canonical path is outside the grant, and expanding it throws `pathOutsideWorkspace`.
6. A directory holding 600 matching files with `limit: 500` returns 500 entries and
   `omittedCount == 100`.
7. `limit: 0` and `limit: 99_999` both succeed, clamped to 1 and `DirectoryLimits.maximumPageSize`.
8. A directory made unreadable with `chmod 000` returns `isReadable == false` with zero entries and
   **does not throw**.
9. A `.app` bundle inside the directory is never returned as `isDirectory: true`.
10. `swift test --filter DirectoryListerTests` passes; `swiftformat --lint .` and
    `swiftlint lint --strict` clean for the touched files.

**Verification commands:**
```bash
cd /Users/quino/Documents/GitHub/OpenSheets/Packages/OpenSheetsCore
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors --filter DirectoryListerTests
swift test -Xswiftc -warnings-as-errors --filter SheetStoreTests
cd /Users/quino/Documents/GitHub/OpenSheets && swiftformat --lint . ; swiftlint lint --strict
```

---

### Agent E3 — The explorer view

**Goal:** a `FileExplorer` SwiftUI component that renders `FileExplorerState` as an indented,
hoverable, keyboard-reachable list and emits `FileExplorerAction` — drawing no surface of its own.

**Depends on:** E1 (uses `FileExplorerRow`, `FileExplorerState`, `FileExplorerAction`).

**Files to create:**
- `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/FileExplorer.swift`
- `Packages/OpenSheetsCore/Tests/GlassUITests/FileExplorerTests.swift`

**Files to modify:**
- `Packages/OpenSheetsCore/Sources/GlassUI/Gallery/GlassUIGallery.swift` — add
  `case fileExplorer` to the `Item` enum (`:23-40`), its `title` ("File explorer") and `symbol`
  ("folder"), and a body case rendering the mock.
- `Packages/OpenSheetsCore/Sources/GlassUI/Gallery/MockData.swift` — add
  `static let fileExplorer: FileExplorerState` with a root, two nested folders, three files, one
  loading row, one unreadable row and one `.note` row.
- `Packages/OpenSheetsCore/Sources/GlassUI/Gallery/Previews.swift` — add a `#Preview` for it.

**Do NOT touch:** `FileExplorerModel.swift` (E1 owns it), `Sidebar.swift` (E6), `LauncherWindow.swift`
(E5), `AppearanceSnapshotTests.swift` — **and specifically do not add a `ComponentCatalog` entry**;
see below.

**Context it needs:**
- Public API, fixed:
  ```swift
  public struct FileExplorer: View {
      public init(
          state: FileExplorerState,
          context: AppearanceContext,
          perform: @escaping (FileExplorerAction) -> Void
      )
  }
  ```
- **This component applies no glass and no material.** No `.glassCard(`, no `.vibrantChrome(`, no
  background fill other than the hover/selection row fill. It is content, hosted inside surfaces
  that other agents own. `States/EmptyStates.swift:143-147` is the precedent and states the reason.
  Consequence: **no `ComponentCatalog` entry, no golden re-record.** If you find yourself adding a
  surface, stop and report — you have changed the plan.
- Structure, copying `Chrome/ChangeTracking.swift:387` and `Floating/CommandPalette.swift:165`:
  ```
  VStack(spacing: 0) {
      header            // SectionHeader("Folders", trailing: nil) + optional `+` button
      searchField       // TextField, .textFieldStyle(.plain), DS.Text.control
      ScrollView { LazyVStack(alignment: .leading, spacing: 0) { ForEach(state.rows) { row(…) } } }
          .scrollBounceBehavior(.basedOnSize)
      searchNote        // optional, DS.Text.caption / DS.Chrome.tertiary
  }
  ```
- The row, copying `Chrome/Sidebar.swift:520-597` for structure and `Chrome/FileTabStrip.swift:296`
  for hover:
  - leading indent `Color.clear.frame(width: CGFloat(row.depth) * Self.indentPerLevel)` — an
    **expression**, so the spacing lint passes; `indentPerLevel` is a named `private static let`
    with a comment saying it was measured, in the register of `FileTabStrip.swift:355-364`.
  - chevron: `Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")` in a fixed
    `Self.chevronColumn` width, present only when `row.kind.isExpandable`; replaced by
    `ProgressView().controlSize(.small)` when `row.load == .loading`. The column keeps its width in
    all three states so rows never shift.
  - glyph: `row.kind.symbolName`, `DS.Chrome.accent` for `.workbook`/`.delimited`,
    `DS.Chrome.secondary` otherwise.
  - name: `DS.Text.control`, `.lineLimit(1)`, `.truncationMode(.middle)`.
  - `detail`: `.dsNumeric(DS.Text.numericCaption)`, `DS.Chrome.tertiary`.
  - selection: `DS.Radius.shape(DS.Radius.chip).fill(DS.Chrome.selectedRow)`; hover:
    `.fill(DS.Chrome.separator)`. Selection wins.
  - `.opacity` reduced for `load == .unreadable || load == .missing`, with
    `.help("Not readable.")` / `.help("This folder is no longer where it was.")`.
  - `.contentShape(Rectangle())`, `.buttonStyle(.plain)`,
    `.accessibilityLabel(row.accessibilityLabel)`,
    `.accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)`.
  - Context menu (`FileTabStrip.swift:337-345` is the template): **Open** (openable rows only),
    **Reveal in Finder**, Divider, **Refresh** (expandable only), **Remove from list**
    (`kind == .root` only).
  - `.note` rows are `Text`, not `Button`, and take no hover.
- A single click on an expandable row emits `.toggle(id)`; on an openable row `.select(id)` then
  `.open(id)`. Chevron clicks emit only `.toggle(id)`.
- Empty: when `state.rows.isEmpty && state.emptyMessage != nil`, render the message as one line of
  `DS.Text.control` / `DS.Chrome.tertiary` — **not** an `EmptyStateView`, matching how the sidebar
  handles an empty section (`Sidebar.swift:292-295`).
- Motion: `DS.Motion.snappy` on `state.rows`. No `.easeInOut` — the lint bans it.
- Tests: `@MainActor`. Assert on the pure parts (row construction, action mapping through a
  captured closure). `Tests/GlassUITests/FormulaBarFieldTests.swift:9-25` is worth reading first:
  it explains why asserting only on emitted actions once let a broken field pass.

**Implementation notes:**
- Local `@State private var hovered: String?` only. No `@StateObject`, no `@EnvironmentObject`,
  no `.shared.` — the lint errors on all three.
- Every padding and spacing value from `DS.Space`, or `0`, or a named `private static let`.
- `ForEach(state.rows)` works because `FileExplorerRow` is `Identifiable`.
- Keyboard: the rows are `Button`s, so Full Keyboard Access works for free. Do not add a custom
  focus system.

**Acceptance criteria:**
1. `swift build -Xswiftc -warnings-as-errors` exits 0.
2. `swift test --filter GlassLintTests` passes — this is the one that catches a stray
   `.padding(12)`, a `Color.blue`, or a `.shadow(`.
3. `grep -c "glassCard\|glassPill\|glassChrome\|vibrantChrome\|glassEffect" Sources/GlassUI/Chrome/FileExplorer.swift`
   returns `0`.
4. `swift test --filter AppearanceSnapshotTests` passes **with the six goldens unmodified** —
   `git diff --stat docs/design/snapshots/` shows no new changes attributable to this task.
5. `swift test --filter FileExplorerTests` passes and asserts: clicking an openable row emits
   `.select` then `.open` with the right id; clicking an expandable row emits `.toggle` only;
   a `.note` row emits nothing; a row with `load == .missing` emits nothing.
6. The gallery builds and `GlassUIGallery.Item.allCases` includes `.fileExplorer`.
7. `swiftformat --lint .` and `swiftlint lint --strict` clean for the touched files.

**Verification commands:**
```bash
cd /Users/quino/Documents/GitHub/OpenSheets/Packages/OpenSheetsCore
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors --filter GlassUITests
grep -c "glassCard\|glassPill\|glassChrome\|vibrantChrome\|glassEffect" Sources/GlassUI/Chrome/FileExplorer.swift
cd /Users/quino/Documents/GitHub/OpenSheets && git diff --stat docs/design/snapshots/
swiftformat --lint . ; swiftlint lint --strict
```

---

### Agent E4 — The tree model

**Goal:** one `@Observable` `WorkspaceTree` per process that turns granted roots into a lazily
expanded, persisted, searchable flat list of `WorkspaceNode`s — and an `AppModel` that owns it.

**Depends on:** E1 (`WorkspaceNode`, `WorkspaceTreeStorage`, `DirectoryListingSource`, `DirectoryLimits`).
Does **not** depend on E2: it takes `any DirectoryListingSource` and is tested against a fake.

**Files to create:**
- `Packages/OpenSheetsCore/Sources/DocumentCore/WorkspaceTree.swift`
- `Packages/OpenSheetsCore/Tests/DocumentCoreTests/WorkspaceTreeTests.swift`

**Files to modify:**
- `Packages/OpenSheetsCore/Sources/DocumentCore/AppModel.swift` — four surgical additions, listed
  below. **You are the only agent who may edit this file.**

**Do NOT touch:** `DirectoryLister.swift` (E2 owns it — depend on the protocol, not the type),
`SheetStore.swift`, any GlassUI file, anything under `App/`.

**Context it needs:**

The type:
```swift
@MainActor
@Observable
public final class WorkspaceTree {
    /// Flattened, in display order, roots first. The view does no walking.
    public private(set) var nodes: [WorkspaceNode] = []
    public private(set) var isSearching = false
    /// Non-nil when a search stopped at its budget. Never swallowed.
    public private(set) var searchNote: String?
    public private(set) var searchResults: [WorkspaceNode] = []

    public var search: String = "" { didSet { … } }

    public init(
        source: any DirectoryListingSource,
        fileExtensions: Set<String>,
        storage: (any WorkspaceTreeStorage)?
    )

    /// Called by `AppModel.reloadGrants()`. Idempotent; keeps expansion for surviving roots.
    public func setRoots(_ paths: [String])
    public func toggle(_ id: String)
    public func refresh(_ id: String)
    public func removeRoot(_ id: String)     // collapses and drops; does NOT revoke the grant
}
```

Behaviour, precisely:
- **Roots.** `setRoots` canonicalises, then **drops any root that is a path-component descendant of
  another root** — `~/Documents` and `~/Documents/GitHub/OpenSheets/Demo` are both granted on the
  developer's machine today, and showing both as top-level rows means the same folder appears
  twice. Compare by components; never `hasPrefix`.
- **Laziness.** `toggle` on a collapsed folder sets `load = .loading`, inserts nothing, and starts
  the listing. Expanding an already-loaded folder re-inserts the cached children with **no**
  listing. `refresh` clears the cache for that id and re-lists.
- **Off the main actor.** Copy `DocumentModel.swift:1055-1068` exactly in shape:
  ```swift
  let generation = self.generation
  let source = self.source
  let extensions = self.fileExtensions
  Task { [weak self] in
      let listing = await Task.detached(priority: .userInitiated) {
          try? source.list(path, fileExtensions: extensions, limit: DirectoryLimits.pageSize)
      }.value
      guard let self, self.generation == generation else { return }
      self.adopt(listing, for: path)
  }
  ```
  `.userInitiated`, not `.utility`: the user is looking at a spinner. Say that in the comment, the
  way `DocumentModel.swift:1060-1062` does.
- **Coalescing.** An `inFlight: Set<String>` guards double-expansion, mirroring `AppModel.opening`
  (`AppModel.swift:89`). A second `toggle` while a listing is in flight collapses instead of
  starting a second one.
- **Generation guard.** A single `private var generation: Int`, bumped by `setRoots`, `removeRoot`
  and `refresh`. A listing that lands against a stale generation is dropped.
- **Depth cap.** Refuse to expand beyond `DirectoryLimits.maximumDepth`; the row keeps its chevron
  but toggling is a no-op with `load = .unreadable`. A stated, honest limit.
- **Persistence.** On any expansion change, write the expanded ids through `storage`. On init, read
  them and expand each **that is still under a live root**, top-down. `storage == nil` means "do not
  persist" and is what tests use.
- **Search.** `search`'s `didSet` cancels the previous task and, after a 250 ms debounce (
  `try? await Task.sleep(for: .milliseconds(250))` — the shape at `DocumentModel.swift:1341-1357`),
  runs a breadth-first walk from every root inside a `Task.detached(priority: .utility)`, visiting
  at most `DirectoryLimits.searchDirectoryBudget` directories and `searchEntryBudget` entries,
  checking `Task.isCancelled` once per directory. Matches are files only, compared with
  `range(of:options: [.caseInsensitive, .diacriticInsensitive])`. On budget exhaustion set
  `searchNote` to `"Stopped after \(n) files — narrow the search or open a subfolder."`
- **The storage adapter**, in the same file:
  ```swift
  /// `workspace.explorer` in the `preference` table — the same place and the same shape as
  /// `workspace.tabs`. Failures are swallowed to "nothing expanded": a tree that refuses to draw
  /// because a preference would not decode is worse than a tree that starts collapsed.
  public struct DatabaseWorkspaceTreeStorage: WorkspaceTreeStorage {
      public static let preferenceKey = "workspace.explorer"
      public init(database: Database)
  }
  ```
  Use `try? database.preference(_:)` / `try? database.setPreference(_:to:)`
  (`SheetStore/Database.swift:141,149`), JSON-encoding `[String]`. `CheckpointStore.storedID`
  (`DocumentCore/BaselineTracker.swift:170-183`) is the precedent for swallowing here.

The four `AppModel.swift` edits, and only these:
1. After `public private(set) var grants: [WorkspaceGrant] = []` (`:58`), add
   `@ObservationIgnored public let explorer: WorkspaceTree`.
2. In `init(store:)` (`:123-127`), construct `explorer` **before** the two reload calls:
   ```swift
   explorer = WorkspaceTree(
       source: store.directories,
       fileExtensions: DocumentWorkbookReader.workbookExtensions
           .union(DocumentWorkbookReader.delimitedExtensions),
       storage: DatabaseWorkspaceTreeStorage(database: store.database)
   )
   ```
   **`store.directories` is E2's addition to `SheetStore`.** If E2 has not landed when you build,
   report it rather than adding the property yourself.
3. At the end of `reloadGrants()` (`:278-281`), add `explorer.setRoots(grants.map(\.path))`.
4. Add two small public methods next to `grantWorkspace` (`:284`):
   ```swift
   /// Whether `url` is inside a live grant — read through `grants` on purpose.
   ///
   /// `store` is `@ObservationIgnored` and `WorkspaceGrants` is not `@Observable`, so a view that
   /// calls `store.grants.isAllowed` alone registers no dependency and never re-renders when a
   /// grant is added. Touching `grants` first is what makes the answer live; the check is what
   /// makes it correct.
   public func isGranted(_ url: URL) -> Bool {
       _ = grants.count
       return store.grants.isAllowed(url)
   }

   /// Clears the last error once a view has shown it. Without this the launcher's rejection line
   /// would be permanent.
   public func clearLastError() { lastError = nil }
   ```
   Also add to the `Flags` enum (`:366`):
   ```swift
   /// The workspace file explorer. **On.** Off must cost nothing: no tree, no listing, and both
   /// hosts fall back to the pre-explorer UI.
   public static var explorerEnabled: Bool { bool("OSFlagExplorer", default: true) }
   ```

**Implementation notes:**
- `nodes` is rebuilt wholesale on every change from an internal `[String: [WorkspaceNode]]` child
  cache plus the expanded set. Simpler than in-place splicing and cheap at these sizes.
- `WorkspaceTree` must not import `SwiftUI` or `GlassUI` types. It publishes `WorkspaceNode`; the
  mapping to `FileExplorerState` is the app layer's job (`App/WorkspaceExplorerSupport.swift`,
  E5) — the same split as `WorkspaceState.tabStrip(for:asOf:)` (`App/WorkspaceTabsSupport.swift:45`).
- Tests use a `FakeDirectorySource: DirectoryListingSource` declared in the test file, returning
  canned listings and counting calls. No filesystem, so no `.serialized` needed.

**Acceptance criteria:**
1. `swift build -Xswiftc -warnings-as-errors` exits 0.
2. `setRoots(["/a", "/a/b"])` produces exactly one root node, `/a`.
3. `toggle` on a collapsed folder sets its `load` to `.loading`, and after the fake returns, the
   children appear with `depth == parent.depth + 1`, directories before files.
4. Calling `toggle` twice in a row on a loading node results in **exactly one** `list` call on the
   fake, and the node ends collapsed.
5. Collapsing then re-expanding a loaded folder makes **no** additional `list` call; `refresh` makes
   exactly one more.
6. A listing that returns `isReadable: false` sets `load = .unreadable` and inserts no children;
   nothing throws.
7. A listing with `omittedCount == 100` is reflected in the node's `load == .loaded(omitted: 100)`.
8. Expanding at `depth == DirectoryLimits.maximumDepth` makes no `list` call.
9. With a fake `WorkspaceTreeStorage`, expanding two folders then constructing a second tree with
   the same storage and roots restores both as expanded.
10. `removeRoot` drops the root and all of its descendants from `nodes` and does **not** call any
    grant API.
11. A search whose fake exceeds `searchDirectoryBudget` sets a non-nil `searchNote`.
12. `AppModel(store:)` still builds and `swift test --filter DocumentCoreTests` passes in full —
    the existing 100+ tests must not regress.
13. `swiftformat --lint .` / `swiftlint lint --strict` clean for the touched files.

**Verification commands:**
```bash
cd /Users/quino/Documents/GitHub/OpenSheets/Packages/OpenSheetsCore
swift build -Xswiftc -warnings-as-errors
swift test -Xswiftc -warnings-as-errors --filter WorkspaceTreeTests
swift test -Xswiftc -warnings-as-errors --filter DocumentCoreTests
cd /Users/quino/Documents/GitHub/OpenSheets && swiftformat --lint . ; swiftlint lint --strict
```

---

### Agent E5 — Host it in the launcher

**Goal:** the launcher becomes a two-column window whose left rail is the explorer; granting a
folder makes it appear, expanded, immediately; a refused grant says why.

**Depends on:** E3 (the view), E4 (`AppModel.explorer`, `isGranted`, `clearLastError`, `Flags.explorerEnabled`).

**Files to create:**
- `App/WorkspaceExplorerSupport.swift`

**Files to modify:** (five, and the `panelSize` change reaches further than it looks — see
"the launcher's window path" under Context)
- `Packages/OpenSheetsCore/Sources/GlassUI/Launcher/LauncherWindow.swift` — the layout, and the
  removal of the grants list.
- `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/WindowChrome.swift` — only the two reads of
  `LauncherWindow.panelSize` inside `configureLauncherWindow`. `configureDocumentWindow` is not
  yours.
- `App/WindowSupport.swift` — only `LauncherWindowConfigurator` (`:24-32`), to forward the flag.
- `App/LauncherScene.swift` — state mapping and action handling.
- `App/Flags.swift` — add `("explorer", explorerEnabled)` to the `summary` array.

**Do NOT touch:** `GlassUI/Chrome/Sidebar.swift` and `App/SidebarColumn.swift` (E6 owns both),
`GlassUI/Chrome/FileExplorer.swift` (E3), `DocumentCore/AppModel.swift` (E4).

**Context it needs:**
- **`App/WorkspaceExplorerSupport.swift`** is a namespace enum of `static func`s, copying the shape
  of `App/WorkspaceTabsSupport.swift:45`:
  ```swift
  @MainActor
  enum WorkspaceExplorerState {
      static func explorer(
          for tree: WorkspaceTree,
          selection: String?,
          offersAddFolder: Bool
      ) -> FileExplorerState
      static func row(_ node: WorkspaceNode, isSelected: Bool) -> FileExplorerRow
      static func kind(_ node: WorkspaceNode) -> FileExplorerRow.Kind
      static func detail(_ node: WorkspaceNode) -> String?
  }
  ```
  - `kind`: `.root`/`.folder` from `node.kind`; for `.file`, `.workbook` if the lowercase extension
    is in `DocumentWorkbookReader.workbookExtensions`, else `.delimited`.
  - `detail`: `ByteCountFormatter`-style size for files (use
    `node.byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }`), and
    `nil` for folders. **All formatting happens here**, never in `GlassUI` — the rule
    `App/SidebarColumn.swift:43-84` follows.
  - After the children of a node whose `load == .loaded(omitted: n)` with `n > 0`, append a `.note`
    row with `id: "note:\(node.id)"` and `name: "+ \(n.formatted()) more"`.
  - After a `.loaded(omitted: 0)` folder with no children, append a `.note` row reading
    `"Nothing to open here."`
  - `emptyMessage` is `"No folders yet."` when the tree has no roots.
- **Launcher layout.** `LauncherWindow.panelSize` becomes `CGSize(width: 880, height: 560)`.
  The body becomes:
  ```
  HStack(spacing: 0) {
      explorerRail            // width DS.Metrics.sidebarWidth, separator overlay on its trailing edge
      VStack { header; recents (scrolling); actions }   // as today
  }
  .padding(DS.Space.xxl)   // on the right column only — the rail runs to the card's edge
  ```
  The rail must draw **no glass and no material** — the launcher card is already one lens, and a
  second inside it is exactly what the cluster rule and `GlassSurface`'s note forbid. Separate it
  with `Divider().overlay(DS.Chrome.separator(context))`, the way `Sidebar.swift:265` does.
- **`LauncherState` gains `var explorer: FileExplorerState?`** and `LauncherAction` gains
  `case explorer(FileExplorerAction)`. `nil` means the flag is off: render exactly today's
  single-column launcher at 720×520.

  **The launcher's window path — read this before you start.** The window sizes itself from
  `LauncherWindow.panelSize`, a `static let` read twice inside
  `WindowChrome.configureLauncherWindow`. Because the size now varies with the flag, that
  constant becomes `public static func panelSize(explorerEnabled: Bool) -> CGSize` — 880×560
  on, 720×520 off — and **all three** call sites change: the two in `WindowChrome.swift` and
  the one in `App/LauncherScene.swift`. `GlassUI` cannot read `DocumentCore.Flags`, so the
  boolean is passed in from the app layer and never read inside the component; that means
  `LauncherWindowConfigurator` (`App/WindowSupport.swift:24-32`) must forward it, changing
  `view.configure = { WindowChrome.configureLauncherWindow($0) }`. All four files are yours.
- **Delete the grants footer.** `LauncherWindow.swift`'s `grants` view (`:289`) and the
  `WorkspaceGrantItem` type (`:44-58`) go away, along with `App/LauncherScene.swift:43-50`'s
  construction of it. The explorer replaces it, and `fileCount: 0` — the literal "granted, contains
  nothing" lie from §0 — goes with it. Also remove `MockData`'s grant fixtures if they become
  unused; if they are referenced by the gallery, coordinate through E7 rather than editing E3's
  gallery cases.
- **The grant flow**, in `LauncherScene.perform` (`:67`):
  ```swift
  case .grantFolder, .explorer(.addFolder):
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.allowsMultipleSelection = false
      guard panel.runModal() == .OK, let url = panel.url else { return }
      rejection = nil
      app?.clearLastError()
      guard app?.grantWorkspace(url) == true else {
          rejection = app?.lastError?.errorDescription ?? "That folder could not be granted."
          return
      }
      // Land expanded. NOT `AppModel.documentKey(for: url)`: its `path(percentEncoded:)`
      // keeps the trailing slash on a directory, so it yields `/Users/q/Reports/` while every
      // node id the tree mints is `/Users/q/Reports`. `toggle` ignores an id it does not know,
      // so that spelling would silently do nothing — this bug, inside its own fix. Verified.
      app?.explorer.expandNewRoot(url)
  ```
  `rejection` is the `@State` at `App/LauncherScene.swift:18` that nothing currently assigns; the
  view already renders it at `LauncherWindow.swift:170-175`.
- **Opening.** `.explorer(.open(id))` → `OpenActions.open(URL(fileURLWithPath: id))`, i.e. the
  default `.fromOutsideTheApp` consent, exactly as opening a recent does (`LauncherScene.swift:63`).
  Do **not** pass `.userSelectedInPanel`: the click happened in our UI, but the file's folder is
  already granted, so the careful case costs nothing and is the honest one.
- `.explorer(.revealInFinder(id))` → `NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])`.
- `.explorer(.removeRoot(id))` → find the matching `WorkspaceGrant` in `app.grants` by path and call
  `app.revokeGrant(_:)`. Removing a root from the explorer **is** revoking the grant; there is no
  second concept, and pretending otherwise would leave an invisible grant the MCP server still
  honours.

**Implementation notes:**
- The spacing lint scans `App/` too. Every literal you type into a `.padding(` or `spacing:` in
  `LauncherScene.swift` fails the build.
- `LauncherWindow.swift` is currently dirty with an uncommitted rework (`contents` at `:271`,
  `grants` at `:289`, `actions` at `:322`, `panelSize` at `:125`). Read it before editing; do not
  revert those changes.
- There is **no test target for `App/`** anywhere in this repo. Your acceptance is build + lint +
  E7's manual walkthrough. Put any logic worth testing into `WorkspaceExplorerSupport.swift` as
  pure `static func`s so E7 can at least eyeball them, and say in your report what you could not
  test.

**Acceptance criteria:**
1. `Scripts/build.sh` exits 0 (`** BUILD SUCCEEDED **`), including the app target.
2. `swift test -Xswiftc -warnings-as-errors` passes in full, including `GlassLintTests` — this
   is what catches a spacing literal in `App/LauncherScene.swift`.
3. `grep -n "fileCount" App/LauncherScene.swift Packages/OpenSheetsCore/Sources/GlassUI/Launcher/LauncherWindow.swift`
   returns nothing.
4. `grep -n "rejection = " App/LauncherScene.swift` returns at least two assignments.
5. Launching with `defaults write com.quino.opensheets OSFlagExplorer -bool NO` produces the
   single-column launcher at 720×520 with no explorer and no crash.
6. Launching with the flag unset shows the two-column launcher at 880×560.
7. `git diff --stat docs/design/snapshots/` shows no change from this task.
8. `grep -rn "panelSize" Packages/OpenSheetsCore/Sources App | grep -v worktrees` shows the
   declaration plus exactly three call sites, every one passing an explicit `explorerEnabled:`.
9. `swiftformat --lint .` and `swiftlint lint --strict` clean for the touched files.

**Verification commands:**
```bash
cd /Users/quino/Documents/GitHub/OpenSheets
Scripts/build.sh
Scripts/test.sh
grep -rn "panelSize" Packages/OpenSheetsCore/Sources App | grep -v worktrees
grep -n "fileCount" App/LauncherScene.swift Packages/OpenSheetsCore/Sources/GlassUI/Launcher/LauncherWindow.swift
git diff --stat docs/design/snapshots/
swiftformat --lint . ; swiftlint lint --strict
```

---

### Agent E6 — Host it in the document sidebar

**Goal:** the workspace window's sidebar gains a `FILES` section showing the same tree, from which a
click opens a new tab — and the sidebar's "Grant this folder" button finally updates when you press it.

**Depends on:** E3 (the view), E4 (`AppModel.explorer`, `isGranted`), E5 (`WorkspaceExplorerState`).

**Files to create:** none.

**Files to modify:**
- `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/Sidebar.swift` — `SidebarState` gains
  `var files: FileExplorerState?`; `SidebarAction` gains `case explorer(FileExplorerAction)`; a new
  `filesSection` is placed **first** in the scroll column at `:249-253`, above `sheetsSection`.
- `App/SidebarColumn.swift` — the `state` mapping (`:33`), the `claude` mapping (`:86-94`), and the
  action `switch` (`:96-129`).

**Do NOT touch:** `App/LauncherScene.swift`, `GlassUI/Launcher/LauncherWindow.swift`,
`App/WorkspaceExplorerSupport.swift` (all E5's), `GlassUI/Chrome/FileExplorer.swift` (E3),
`DocumentCore/AppModel.swift` (E4).

**Context it needs:**
- `filesSection` renders `FileExplorer(state:context:perform:)` wrapped in
  `.frame(maxHeight: Self.filesSectionMaxHeight)` — a named `private static let` with a comment
  saying why (a deep tree must not push `SHEETS`, `NAMED RANGES` and the Claude panel out of a
  248pt column). ~220pt is the right order; `ChangeTrackingPanel.listMaxHeight = 280`
  (`Chrome/ChangeTracking.swift`) is the precedent for this kind of constant.
- `offersAddFolder: false` for the sidebar — granting already lives in the Claude panel
  (`Sidebar.swift:415-417`), and two `+` buttons for one action in one column is one too many.
- `nil` `files` renders nothing at all — that is the flag-off and no-roots path.
- Action wiring in `SidebarColumn.perform`:
  - `.explorer(.open(id))` → **`OpenActions.open(URL(fileURLWithPath: id))`**. That routes through
    `TabsModel.open` when a workspace is installed (`App/OpenSheetsApp.swift:464-478`), so the file
    lands as a **tab in this window**, deduped on `AppModel.documentKey`. Do not call `TabsModel`
    directly; `OpenActions` is the single funnel and it also records consent and the recent.
  - `.explorer(.toggle/.refresh/.removeRoot/.search)` → the matching `app.explorer` method. For
    `.removeRoot`, resolve to the `WorkspaceGrant` and call `app.revokeGrant(_:)`, the same as E5.
  - `.explorer(.select(id))` → store it in a `@State private var explorerSelection: String?` on
    `SidebarColumn` and pass it into `WorkspaceExplorerState.explorer(for:selection:offersAddFolder:)`.
    Seed it from `model.url` so the file you are looking at is the row that is highlighted.
- **The observability fix.** Change `App/SidebarColumn.swift:89` from
  `isGranted: app.store.grants.isAllowed(model.url)` to `isGranted: app.isGranted(model.url)`
  (E4's method). That is the whole of root cause #4 in §0: the button's label will now flip the
  moment the grant lands. Leave a one-line comment pointing at the reason.

**Implementation notes:**
- `SidebarState` is `Sendable, Hashable`; `FileExplorerState` is too, so the conformance is free.
- Adding a case to `SidebarAction` is source-breaking for every `switch` over it. There is exactly
  one — `App/SidebarColumn.swift:96` — and you own it. Confirm with
  `grep -rn "SidebarAction" --include=*.swift . | grep -v .claude/worktrees`.
- `Sidebar.swift` has no `@State` today and should keep none; the explorer's hover state is local to
  `FileExplorer` and does not leak.
- The spacing lint scans this file. Use `DS.Space` or named constants.

**Acceptance criteria:**
1. `Scripts/build.sh` exits 0.
2. `swift test -Xswiftc -warnings-as-errors` passes in full, including `GlassLintTests` and
   `AppearanceSnapshotTests` — the latter must pass **with the six goldens unmodified**, because
   `Sidebar` already has a `ComponentCatalog` entry (`AppearanceSnapshotTests.swift:300-304`,
   `vibrantChrome`, `shape: .none`) and adding a section must not change its surface.
3. `grep -n "app.store.grants.isAllowed" App/SidebarColumn.swift` returns nothing.
4. `grep -rn "SidebarAction" --include=*.swift App Packages | grep -v worktrees` shows exactly one
   `switch`, in `App/SidebarColumn.swift`.
5. With the explorer flag off, the sidebar renders exactly as it does today (no `FILES` header).
6. `git diff --stat docs/design/snapshots/` shows no change from this task.
7. `swiftformat --lint .` and `swiftlint lint --strict` clean for the touched files.

**Verification commands:**
```bash
cd /Users/quino/Documents/GitHub/OpenSheets
Scripts/build.sh
Scripts/test.sh
grep -n "app.store.grants.isAllowed" App/SidebarColumn.swift
grep -rn "SidebarAction" --include=*.swift App Packages | grep -v worktrees
git diff --stat docs/design/snapshots/
swiftformat --lint . ; swiftlint lint --strict
```

---

### Agent E7 — Integration and verification

**Goal:** the seams hold, the full suite is green, and every numbered step of §4 has been walked in
the running app — with a pass/fail line against every acceptance criterion above.

**Depends on:** E1, E2, E3, E4, E5, E6 — all of them, merged.

**Files to create:** `docs/design/explorer-verification.md` (the report).

**Files to modify:** only what a defect requires. **Every fix must name which agent's file it is in
and why that agent could not have caught it**, so the next plan is better.

**Do NOT touch:** `OpenSheets.xcodeproj/project.pbxproj`, `Packages/OpenSheetsCore/Package.swift`,
`Packages/OpenSheetsCore/Sources/SheetModel/`, anything under `.claude/worktrees/`.

**Context it needs:**
- The app is installed to `/Applications/OpenSheets.app` and must be reinstalled to test the real
  build. The install recipe: `Scripts/build.sh --release`, then
  `codesign --force --sign - --entitlements Config/OpenSheets.entitlements <staged app>` (the build
  script passes `CODE_SIGNING_ALLOWED=NO`, so the bundle is only linker-signed and reports
  `Identifier=OpenSheets` instead of `com.quino.opensheets`, which sends `UserDefaults` — including
  `OSFlagExplorer` — to the wrong domain), then `ditto` it into `/Applications`.
- The live grants to test against: `~/Documents` (525,127 entries), `~/Downloads` (3,109 entries in
  its top level), `~/Documents/GitHub/ExamAi-new`. These are the real stress cases.

**What it must do:**

1. **Seams.** Every import resolves; no type is declared twice; `WorkspaceGrantItem` and every
   reference to it is gone; no `notImplemented` stub survives; no `TODO` was added.
   `grep -rn "TODO\|FIXME" App Packages/OpenSheetsCore/Sources | grep -v worktrees` shows nothing
   new versus `git HEAD`.
2. **Full suite**, literally:
   ```bash
   cd /Users/quino/Documents/GitHub/OpenSheets
   Scripts/build.sh
   Scripts/test.sh
   Scripts/build.sh --release && Scripts/test.sh --release
   swiftformat --lint . ; swiftlint lint --strict
   ```
   The release test run is where the performance budgets live and it is load-sensitive: a failure in
   `CellStore performance` or `CoreLoopTests.autoRefreshAppliesWithoutBeingAsked` under load is a
   known flake — **re-run those two suites in isolation before reporting them as regressions.**
3. **Walk §4 in the running app** and record each numbered step pass/fail, including §4.4's eight
   states. Specifically prove:
   - Granting `~/Downloads` shows 500 entries and a `+ N more` row, not 3,109 rows.
   - Granting `~/Documents` does **not** hang the UI, and expanding it lists in under a second.
   - Expanding a folder issues exactly one listing (add temporary `os_signpost` or count via a
     debug build if needed; remove anything you add).
   - A refused grant (`~/.ssh`) shows the rejection line rather than doing nothing.
   - Both roots survive a relaunch expanded.
   - The sidebar's "Grant this folder" label flips **immediately** on click — root cause #4.
4. **Confirm each permission rule in §5.4 is enforced at the layer claimed**, by test not by reading:
   run `swift test --filter DirectoryListerTests`, and additionally confirm by hand that no
   `FileManager` call exists anywhere in `Sources/GlassUI` —
   `grep -rn "FileManager\|URL(fileURLWithPath" Packages/OpenSheetsCore/Sources/GlassUI | grep -v Gallery`
   must return nothing.
5. **Confirm rollout prerequisites**: no migration was added
   (`grep -n "registerMigration" Packages/OpenSheetsCore/Sources/SheetStore/Database.swift` still
   shows exactly `v1-tables` and `v2-recent-file-sequence`); the flag reads correctly in both
   states; no environment variable or secret was introduced.
6. **Report** in `docs/design/explorer-verification.md`: a table of every acceptance criterion from
   E1–E6 with pass/fail, every §4 step with pass/fail, anything unmet stated plainly, and the list
   of §0 "not in scope" items confirmed still unfixed so nobody thinks they were forgotten.
   **Do not declare success while anything is unmet — list it.**

**Acceptance criteria:**
1. `Scripts/build.sh` and `Scripts/test.sh` both exit 0, output pasted into the report.
2. `swiftformat --lint .` and `swiftlint lint --strict` exit 0 for every file this plan touched.
3. `git diff --stat docs/design/snapshots/` shows no change attributable to this plan.
4. `docs/design/explorer-verification.md` exists and contains one line per acceptance criterion
   from E1–E6 and one per numbered step of §4.
5. The `/Applications/OpenSheets.app` build has `Identifier=com.quino.opensheets` under
   `codesign -dv`.
6. Any criterion that failed is listed as failed, with the file and the reason.

**Verification commands:**
```bash
cd /Users/quino/Documents/GitHub/OpenSheets
Scripts/build.sh && Scripts/test.sh
Scripts/build.sh --release && Scripts/test.sh --release
swiftformat --lint . ; swiftlint lint --strict
grep -rn "FileManager\|URL(fileURLWithPath" Packages/OpenSheetsCore/Sources/GlassUI | grep -v Gallery
grep -n "registerMigration" Packages/OpenSheetsCore/Sources/SheetStore/Database.swift
git diff --stat docs/design/snapshots/
codesign -dv /Applications/OpenSheets.app
```

---

## 8. Execution graph

| Wave | Agents | Parallel? | Why the boundary exists |
| --- | --- | --- | --- |
| **1** | E1 | alone | Three modules compile against the same three contracts. Nothing else can start until the type names, cases and signatures are fixed — that is the whole reason this wave exists rather than E2/E3/E4 each inventing their own. |
| **2** | E2, E3, E4 | **yes, all three** | Disjoint modules (`SheetStore`, `GlassUI`, `DocumentCore`), disjoint files, no shared edit. E4 depends on E2 only through `DirectoryListingSource`, which E1 already wrote — so it builds against a fake and does not wait. |
| **3** | E5, E6 | **yes, both** | Both need a working view *and* a working model. They touch disjoint files: E5 owns the launcher pair plus `WorkspaceExplorerSupport.swift`; E6 owns the sidebar pair. E6 *reads* E5's `WorkspaceExplorerState` — a one-way dependency on a file that exists the moment E5 commits, so run E5 first within the wave if you are serialising, but they do not conflict. |
| **4** | E7 | alone | Integration must see everything merged. |

**Strictly sequential:** E1 → {E2, E3, E4} → {E5, E6} → E7.

**Shared-file hazards, and how they are resolved:**

| File | Sole owner | Note |
| --- | --- | --- |
| `DocumentCore/AppModel.swift` | **E4** | E5 and E6 need `explorer`, `isGranted`, `clearLastError`, `Flags.explorerEnabled` — all of them arrive from E4 in wave 2. Nobody else opens this file. |
| `SheetStore/SheetStore.swift` | **E2** | One property, one init line. |
| `GlassUI/Gallery/{GlassUIGallery,MockData,Previews}.swift` | **E3** | E5 may find a now-unused grant fixture in `MockData`; it must **report** rather than edit. |
| `GlassUI/Launcher/LauncherWindow.swift` + `App/LauncherScene.swift` | **E5** | |
| `GlassUI/Chrome/Sidebar.swift` + `App/SidebarColumn.swift` | **E6** | |
| `GlassUI/Chrome/WindowChrome.swift` + `App/WindowSupport.swift` | **E5** | Both read or forward `LauncherWindow.panelSize`, which becomes flag-dependent. E5 owns the launcher's whole window path; nobody else opens either file. |
| `docs/design/snapshots/*.txt` | **nobody** | No new glass surface ⇒ no golden churn. Any diff here means somebody added a surface they did not plan. |

**Critical path:** 4 waves, 7 agents. It cannot honestly be 3: the contracts must precede the three
implementations, the two hosts need both a view and a model, and integration needs everything.

---

## 9. Rollout

- **Order:** ship all of it together. There is no migration, so there is no deploy-versus-migrate
  ordering, and no intermediate state to keep working.
- **Flag:** `OSFlagExplorer`, default on. Kill switch:
  `defaults write com.quino.opensheets OSFlagExplorer -bool NO`. Flags are read fresh on every
  access (`AppModel.swift:361-365`), so it takes effect at the next check, not the next launch.
- **Verify in production:** there is no production. This is a locally built, ad-hoc-signed Mac app
  installed to `/Applications`. E7's walkthrough is the verification.
- **Roll back:** flip the flag, or `git revert` the seven commits. Optionally clear the preference:
  `DELETE FROM preference WHERE key='workspace.explorer'`.
- **Integrations, environment variables, secrets, third-party services, other environments:**
  **none.** This repo has no fleet, no server, no tenancy, no i18n layer, no analytics, no billing.
  Every user-facing string in this plan is an English literal in the source, which is how every
  other string in this app already works.

---

## 10. Known limits, stated on purpose

Each of these is a decision, not an omission. Say so in the doc comments so the next person does not
"fix" it by accident.

1. **The tree does not watch the filesystem.** `FileWatcher` costs two descriptors and an FSEvents
   stream per *file* (`SheetStore/FileWatcher.swift:221-331`); `~/Documents` has 77,024 directories.
   Refresh is explicit.
2. **"Every spreadsheet under here" is a search, not a view.** Pruning folders with no spreadsheets
   requires walking the subtree. The budgeted search is the honest version of that feature.
3. **No drag-to-reorder roots, no drag-out-to-Finder.** The drop *into* the launcher already works
   (`LauncherWindow.swift:148`) and is untouched.
4. **No rename, delete, or new-folder.** This is a reader. A file manager is a different product.
5. **`App/` has no test target anywhere in this repo**, so E5 and E6 are covered by build, lint and
   E7's manual walkthrough only. Any logic worth asserting belongs in `WorkspaceExplorerSupport.swift`
   or, better, in `WorkspaceTree`.
