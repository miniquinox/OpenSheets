# File Tabs & Change Tracking — Master Plan

**Feature:** Turn the one-window-per-file app into a single VS Code-style workspace window with
file tabs (CSV/XLSX from any granted folder), per-tab provenance and live status, and git-style
change tracking: green/amber/red cell highlights against a user-settable baseline ("checkpoint"),
with the checkpoint control living in the title bar beside the traffic lights.

**Written:** 2026-08-24. **Implementers:** parallel agents (Opus 5) who cannot see this
conversation. Every contract they need is written out below — follow it literally.

---

## 0. What already exists (do not rebuild)

Recon confirmed the product already has most of the machinery this feature composes:

| Capability | Where | Status |
| --- | --- | --- |
| File watching (fd source + FSEvents), 150 ms debounce | `Packages/OpenSheetsCore/Sources/SheetStore/FileWatcher.swift:230,302` | done |
| Auto-refresh on external change, per document | `SheetStore/DocumentSession.swift:35` (`Options.autoRefresh`), flag `OSFlagAutoRefresh` default true (`DocumentCore/AppModel.swift:343`) | done |
| Nine-state sync machine (synced/stale/dirty/conflict/…) | `SheetStore/DocumentSyncState.swift:9-55` | done |
| Workbook diffing with structural (row/col insert) detection | `SheetStore/WorkbookDiffer.swift:16` (`diff(before:after:)` at `:71`, `Options` at `:18-47`) | done |
| Diff model types | `SheetModel/SheetDiff.swift` — `CellChange:4` (Kind: added/removed/valueChanged/formulaChanged/styleChanged), `StructuralChange:70`, `SheetDiff:105`, `WorkbookDiff:199` | done — **SheetModel is frozen; these types are used as-is, never modified** |
| Byte snapshots, gzipped, 20/file, ULID-named | `SheetStore/SnapshotStore.swift:88` (`capture:145`, `restore:250`, `SnapshotReason:7`) | done |
| Post-refresh cell flash (decaying tint) | `GridKit/FlashController.swift:160`, drawn in `GridKit/GridRenderer.swift:282` | done |
| Per-document model with sync surface, feed, per-sheet pending counts | `DocumentCore/DocumentModel.swift:42` (`pendingChangesBySheet:77`, `applyRefresh:242`, `present:292`) | done |
| One `DocumentModel` per file regardless of caller timing | `DocumentCore/AppModel.swift:135-158` (`open` registry `:75`, in-flight `opening` `:89`) | done — **this invariant is what makes tabs cheap: a tab holds a `DocumentModel`; the model layer needs no change for tabs** |
| Custom title bar row inline with traffic lights, measured metrics | `App/DocumentWindow.swift:560-637` (`TitleBarRow`), `App/WindowSupport.swift:76-190` (`TitleBarMetrics`/`Reader`) | done |
| Sheet tab bar (the component pattern to copy for file tabs) | `GlassUI/Chrome/SheetTabBar.swift:89` (state `:43`, action enum `:66`, one-lens rule `:80-88`) | done |
| SQLite `preference` key/value store | `SheetStore/Database.swift:142` (`preference(_:)`), `:149` (`setPreference(_:to:)`) | done |
| Design tokens, colour literals only in `Palette.swift`, lint-enforced | `GlassUI/Tokens/DS.swift:20`, `GlassUI/Tokens/Palette.swift:19`, `Tests/GlassUITests/GlassLintTests.swift` | done |

**Not present anywhere:** file tabs (window model is strictly one window per file —
`DocumentCore/DocumentWindows.swift:41-148`, test `Tests/DocumentCoreTests/OpenDocumentTests.swift:155`
`twoFilesKeepTwoWindows`), any git integration, any persistent (non-decaying) change highlight,
any baseline/checkpoint concept. That is the delta this plan builds.

### Project rules every agent must follow (from README.md:145-160 and PLAN.md §13.1 — there is no CLAUDE.md)

1. **Own your files; touch nothing else.** Each task below lists exact paths.
2. **`Packages/OpenSheetsCore/Sources/SheetModel/` is FROZEN.** No task below touches it. If you
   believe you need to, stop and report; do not edit. Model change requests go in
   `docs/agents/MODEL-CHANGE-REQUESTS.md`.
3. **Never touch `OpenSheets.xcodeproj/project.pbxproj`.** New package sources need no manifest
   edit. New files under `App/` are picked up automatically (the app target is a
   `PBXFileSystemSynchronizedRootGroup`, `project.pbxproj:18`).
4. **Ship it green.** From `Packages/OpenSheetsCore`: `swift build -Xswiftc -warnings-as-errors`
   and `swift test -Xswiftc -warnings-as-errors` must pass. Swift 6 language mode, strict
   concurrency; warnings are errors in CI. No `TODO` in place of an implementation — an honest
   `throw SheetError.notImplemented(...)` is fine, a silent wrong answer is not.
5. **Doc comments say *why***, in the house voice (see `App/OpenSheetsApp.swift:8-56` for the
   register). Cite `PLAN.md §N` where relevant.
6. **Formatting:** `swiftformat .` and `swiftlint lint` (configs pinned at repo root) must pass;
   CI runs `--lint`/`--strict`. Colour literals outside `GlassUI/Tokens/Palette.swift` and raw
   spacing numbers fail `GlassLintTests`.
7. Tests are **Swift Testing** (`import Testing`, `@Test`, `@Suite`) — never XCTest.
8. Commit per logical unit, message `T<n>: <what>` (T for this plan's tasks), branch
   `agent/t<n>-<slug>` unless the orchestrator dictates otherwise.

---

## 1. Locked design

### 1.1 The shape: one workspace window, many tabs

Today: `WindowGroup(for: DocumentWindowRequest.self)` makes one window per file
(`App/OpenSheetsApp.swift:64`), with `OpenActions`/`DocumentWindows` policing "one window per
file, one launcher" (`App/OpenSheetsApp.swift:242-464`, `DocumentCore/DocumentWindows.swift`).

After: **exactly one workspace window** (plus the launcher as today's `nil` case). Every open —
menu, Finder, drag-drop, argv, recents — lands as a **tab** in that window. A tab owns a
`DocumentModel` exactly as a window does today; nothing about `DocumentModel`, `DocumentSession`,
the watcher, or the sync machine changes for tabs. Background tabs keep their watchers running,
so they auto-refresh (or go STALE/CONFLICT) while not frontmost, and their tab shows a status dot.

Explicitly **out of scope for v1** (say so in code comments where relevant): dragging a tab out
into its own window; multiple workspace windows; native `NSWindow` tabbing (we draw our own strip
— native tabs cannot carry status dots or provenance and would stack a second bar under the
custom title row).

### 1.2 User flow (happy path)

1. User launches the app with no arguments. Previously open tabs are restored from the
   `workspace.tabs` preference (see §1.7); if there are none, the launcher shows as today.
2. User opens `~/work/budget.xlsx` (any entry point). The workspace window appears with one tab:
   **budget.xlsx**. The title bar row reads: traffic lights · sidebar toggle · tab strip ·
   changes chip (hidden — no changes yet) · sync chip · inspector toggle.
3. User opens `~/models/forecast.csv`. A second tab appears and becomes active. First tab keeps
   watching in the background.
4. Two files named `data.csv` from different folders are open → both tabs show a quiet
   disambiguator: `data.csv — work` / `data.csv — models` (parent folder name, VS Code style).
   Hovering any tab shows the full path (`.help`).
5. Claude Code edits `budget.xlsx` while its tab is in the background. The watcher fires; with
   auto-refresh on, the document reloads silently and the **tab shows an accent dot** (agent
   activity, same semantics as the sheet-tab dot at `GlassUI/Chrome/SheetTabBar.swift:212-217`).
   The changes chip for that document counts up.
6. User clicks the budget tab. The grid shows **persistent tints**: green fill on cells added
   since baseline, amber on cells whose value/formula changed, red on cells removed; whole
   inserted rows/columns get a light green band. The changed cells from the *most recent* refresh
   additionally flash and fade as today — flash is transient news, tints are standing state.
7. The title-bar **changes chip** reads `+12 ~5 −3` (green/amber/red). Clicking it opens a glass
   popover: baseline label ("Since opened · 09:41"), per-sheet change list (`D2 120 → 129.6`,
   click → jump to cell), a **Set Checkpoint** button, a baseline-source picker (Since opened /
   Since checkpoint / Since last git commit — git only offered when the file is in a repo), and a
   "Highlight changes in grid" toggle.
8. User clicks **Set Checkpoint**. A byte snapshot (reason `checkpoint`) is captured, the baseline
   becomes the current workbook, all tints clear, the chip disappears until the next change. The
   chip label becomes "Since checkpoint · 12:03". The checkpoint survives relaunch.
9. User closes a tab (✕ on hover, or ⌘W). With unsaved edits, a confirm sheet offers
   Save / Discard / Cancel. Closing the last tab closes the window.

**Empty/loading/error states per tab:** while a tab's document loads, its content area shows the
small `ProgressView` exactly as `RootView` does today (`App/OpenSheetsApp.swift:176-181`); a
failed open shows `EmptyStateView(.unreadable…)` (`:167-172`) with the tab marked with a red dot;
the tab remains closable. Sync states (MISSING, LOCKED, …) render exactly as today via
`SyncPresentation.emptyState` (`App/DocumentWindow.swift:310-317`) inside the tab's content.

### 1.3 Baseline & change-tracking semantics

- **Baseline source** (per document): `asOpened` (default — the workbook value captured at open;
  zero setup, answers "what has changed since I've been looking"), `checkpoint` (set by the user;
  backed by a byte snapshot so it survives relaunch), `gitHEAD` (the committed bytes of the file,
  offered only when the file resolves inside a git work tree).
- **The diff** is `WorkbookDiffer` (existing) between the baseline `Workbook` and the current
  `workbook`, recomputed **off the main actor** (both are `Sendable` values): after every external
  refresh, after every save, after local edits (debounced 500 ms), and on baseline change.
  Superseded computations are cancelled. `WorkbookDiff.wasTruncated` and per-sheet
  `omittedCellChangeCount` are surfaced honestly in the chip/panel ("500+ changes").
- **Colour semantics** (one mapping, everywhere): green = added, amber = value/formula changed,
  red = removed. Style-only changes (`CellChange.Kind.styleChanged`) are **not** tinted and not
  counted in the chip (same reasoning as the flash: `SheetModel/SheetDiff.swift:7-9`), but do
  appear at the bottom of the panel list as a quiet count.
- **Structural changes**: inserted rows/columns render as a light green band across the visible
  row/column; deleted rows/columns are **panel-only** in v1 (a marker between rows is fiddly and
  not worth the risk — note this in the panel row: "deleted 2 rows at 14").
- Checkpoint eviction: checkpoint snapshots live in the same 20-per-file budget
  (`SheetStore/SnapshotStore.swift:287`). If the checkpoint snapshot has been evicted or fails to
  parse at relaunch, the baseline silently falls back to `asOpened` and the chip label says so.
  Honest fallback beats a stale baseline.
- A refresh does **not** reset the baseline (that is the point: tracking accumulates across many
  agent writes until the user checkpoints). Undo-stack clearing on refresh is unchanged.

### 1.4 Contracts (write these exactly; they are the seams between tasks)

**C1 — `TabsModel` (DocumentCore, new).** Owner: T1. Consumers: T6.

```swift
/// The workspace's open tabs. One per file, in user order. Owns document lifecycle
/// through injected hooks so it can be tested without AppModel or windows.
@MainActor @Observable
public final class TabsModel {
    public struct Tab: Identifiable {
        /// AppModel.documentKey(for: url) — the same identity the model layer uses.
        public let id: String
        public let url: URL
        public var phase: Phase
    }
    public enum Phase { case loading, ready(DocumentModel), failed(SheetError) }

    public private(set) var tabs: [Tab] = []
    public var activeTabID: String?
    public var activeDocument: DocumentModel? { get }   // ready phase of active tab, else nil
    public var isEmpty: Bool { get }

    /// Injected by the app target. `open` is AppModel.openDocument; `close` is
    /// AppModel.closeDocument; `persist` receives the paths + active index to store.
    public init(
        open: @escaping @MainActor (URL, WorkspaceConsent) async throws(SheetError) -> DocumentModel,
        close: @escaping @MainActor (DocumentModel) -> Void,
        persist: @escaping @MainActor (PersistedTabs) -> Void
    )

    public struct PersistedTabs: Codable, Sendable, Equatable {
        public var paths: [String]
        public var activeIndex: Int?
    }

    /// Opens a tab (or activates the existing one — dedupe by id). Appends after the
    /// active tab. Loading/failure land in the tab's phase, never in an alert.
    public func open(_ url: URL, consent: WorkspaceConsent) async
    /// Closes the tab; calls `close` on its model if ready; activates the neighbour
    /// (the tab to the right, else left). Does NOT confirm unsaved edits — the app
    /// layer asks first (it owns panels), then calls this.
    public func close(_ id: String)
    public func activate(_ id: String)
    public func activateNext()
    public func activatePrevious()
    /// 0-based; ignores out-of-range. ⌘1…⌘9 land here.
    public func activate(index: Int)
    /// Restore: opens each path in order with .fromOutsideTheApp consent.
    public func restore(_ persisted: PersistedTabs) async
    public var persisted: PersistedTabs { get }
}
```

Every mutation that changes `tabs`/`activeTabID` calls `persist(persisted)`.

**C2 — DocumentModel baseline API (DocumentCore, additions).** Owner: T2. Consumers: T6, T7.
All plain data — no GlassUI or GridKit types, so wave-1 tasks never depend on each other's code.

```swift
// On DocumentModel:
public enum BaselineSource: Sendable, Equatable { case asOpened, checkpoint, gitHEAD }
public private(set) var baselineSource: BaselineSource   // starts .asOpened
public private(set) var baselineDate: Date               // when the baseline was taken
/// nil while computing or when tracking is off; .empty when nothing changed.
public private(set) var baselineDiff: WorkbookDiff?
public var isChangeHighlightingEnabled: Bool             // default true; observable
/// Captures a .checkpoint snapshot, sets baseline = current workbook, persists the
/// snapshot id so the checkpoint survives relaunch. No-op when a save is impossible
/// AND the file is unreadable (nothing to snapshot).
public func setCheckpoint() async
public func setBaselineSource(_ source: BaselineSource) async
/// Aggregate counts for the chip. Zero-filled when baselineDiff is nil.
public struct BaselineCounts: Sendable, Equatable {
    public var added: Int; public var modified: Int; public var removed: Int
    public var styleOnly: Int; public var isTruncated: Bool
}
public var baselineCounts: BaselineCounts { get }
/// Providers the app layer can register (wave 2 wires git; nil ⇒ source not offered).
public var gitBaselineProvider: (@Sendable (URL) async -> Workbook?)?
public var isGitBaselineAvailable: Bool                  // set async at open by the provider probe
```

**C3 — `ChangeHighlights` (GridKit, new).** Owner: T3. Consumers: T7.

```swift
/// Persistent per-sheet change tints, drawn under selection and flash. Unlike
/// FlashState this does not decay; it is standing state until the baseline moves.
public struct ChangeHighlights: Sendable, Equatable {
    public var added: Set<CellRef>
    public var modified: Set<CellRef>
    public var removed: Set<CellRef>
    public var insertedRows: Set<Int>      // 0-based indices, whole-row band
    public var insertedColumns: Set<Int>
    public init(added: Set<CellRef> = [], modified: Set<CellRef> = [],
                removed: Set<CellRef> = [], insertedRows: Set<Int> = [],
                insertedColumns: Set<Int> = [])
    public static let none = ChangeHighlights()
    public var isEmpty: Bool { get }
}
```

`GridView` gains `highlights: ChangeHighlights = .none` (after `options`, before `controller`
in the init). `GridTheme` (GridKit form, `GridKit/GridTheme.swift`) gains:

```swift
public var changeAddedTint: RGBAColor      // defaults: a quiet green
public var changeModifiedTint: RGBAColor   // a quiet amber
public var changeRemovedTint: RGBAColor    // a quiet red
public var changeTintOpacity: Double       // default 0.14
public var changeBandOpacity: Double       // default 0.07 (row/column bands)
```

**C4 — GlassUI components (new).** Owner: T4. Consumers: T6.
GlassUI must not import DocumentCore/GridKit (it depends only on SheetModel —
`Package.swift:81`). All state is plain values, mapped inline by the app layer exactly as
`DocumentWindow` builds `snapshotState` today (`App/DocumentWindow.swift:320-338`).

```swift
// GlassUI/Chrome/FileTabStrip.swift
public struct FileTabItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String           // file name with extension
    public var disambiguator: String?  // parent folder name; only when titles collide
    public var fullPath: String        // .help tooltip — the provenance answer
    public var status: Status
    public enum Status: Sendable, Hashable {
        case none          // synced, no edits
        case loading
        case unsaved       // grey dot (secondary), same as today's title dirty dot
        case agentChanged  // accent dot — changed on disk / refreshed by an agent
        case conflict      // amber dot (DS.Signal conflict ink)
        case problem       // red dot — missing/locked/unreadable/failed open
    }
}
public struct FileTabStripState: Sendable, Hashable {
    public var tabs: [FileTabItem]
    public var activeID: String?
}
public enum FileTabAction: Sendable, Hashable {
    case select(String), close(String), closeOthers(String)
    case revealInFinder(String), copyPath(String)   // context menu
}
public struct FileTabStrip: View {
    public init(state: FileTabStripState, context: AppearanceContext,
                perform: @escaping (FileTabAction) -> Void)
}

// GlassUI/Chrome/ChangeTracking.swift
public struct ChangeTrackingChipState: Sendable, Hashable {
    public var added: Int; public var modified: Int; public var removed: Int
    public var isTruncated: Bool
}
public struct ChangeTrackingPanelState: Sendable, Hashable {
    public var chip: ChangeTrackingChipState
    public var baselineLabel: String              // "Since opened · 09:41"
    public var styleOnlyCount: Int
    public var highlightsEnabled: Bool
    public var sources: [SourceChoice]            // in offer order
    public var activeSource: SourceChoice
    public enum SourceChoice: Sendable, Hashable { case asOpened, checkpoint, gitHEAD }
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String                     // "<sheetName>!<a1>" or "structural-…"
        public var sheetName: String
        public var refA1: String?                 // nil for structural rows
        public var summary: String                // "120 → 129.6" / "inserted 1 row at 5"
        public var kind: Kind
        public enum Kind: Sendable, Hashable { case added, modified, removed, structural }
    }
    public var sections: [Section]
    public struct Section: Sendable, Hashable, Identifiable {
        public var id: String; public var sheetName: String; public var rows: [Row]
        public var omittedCount: Int
    }
}
public enum ChangeTrackingAction: Sendable, Hashable {
    case setCheckpoint
    case choose(ChangeTrackingPanelState.SourceChoice)
    case toggleHighlights
    case reveal(sheetName: String, refA1: String)
    case dismiss
}
public struct ChangeTrackingChip: View {       // the title-bar control
    public init(state: ChangeTrackingChipState, context: AppearanceContext,
                action: @escaping () -> Void)  // tap opens the panel (popover, app-owned)
}
public struct ChangeTrackingPanel: View {      // popover content
    public init(state: ChangeTrackingPanelState, context: AppearanceContext,
                perform: @escaping (ChangeTrackingAction) -> Void)
}
```

**C5 — `GitFileVersion` (SheetStore, new).** Owner: T5. Consumer: T7 (adapter).

```swift
/// Reads the committed version of a file out of a git work tree, without linking
/// libgit2: `git` is invoked as a subprocess. Everything degrades to nil — no git
/// binary, not a repo, file untracked, command failure. Never throws, never blocks
/// the main actor (all entry points are async and run the process off-main).
public enum GitFileVersion {
    /// The repo work-tree root containing `url`, or nil. (`git rev-parse --show-toplevel`)
    public static func repositoryRoot(for url: URL) async -> URL?
    /// The bytes of `url` at HEAD, or nil. (`git show HEAD:<relpath>`) Capped at
    /// `maxBytes` (default 256 MB — same ceiling as SnapshotStore.Configuration).
    public static func headBytes(for url: URL, maxBytes: Int = 256 * 1024 * 1024) async -> Data?
    /// Short HEAD hash for labels ("a1b2c3d"), or nil.
    public static func headShortHash(for url: URL) async -> String?
}
```

**C6 — window roles (DocumentCore, changed).** Owner: T1. Consumer: T6.
`WindowRoleView.path: String?` (`DocumentCore/DocumentWindows.swift:19-30`) becomes
`WindowRoleView.role: Role` with `public enum Role: Equatable { case launcher, workspace }`.
`DocumentWindows` keeps `launchers(in:)` and `extras(in:)` semantics but the rules become:
**at most one workspace window (keep oldest), launcher only when no workspace window.**
`window(for:in:)` and `identity(for:)` are deleted (file-level dedupe now happens in
`TabsModel`); `documents(in:)` becomes `workspaces(in:) -> [NSWindow]`.

### 1.5 Status-dot precedence (one dot per tab, worst news wins)

`problem` > `conflict` > `agentChanged` > `unsaved` > `loading` > `none`.
Mapping from model state (T6 implements this exactly, in the app layer):

| Condition (checked in order) | Status |
| --- | --- |
| phase `.failed`, or `syncState` ∈ {missing, locked, unreadable} | `.problem` |
| `syncState == .conflict` | `.conflict` |
| `syncState == .stale` OR (`syncPhase != .hidden`) OR document refreshed from disk in the last 6 s | `.agentChanged` |
| `hasUnsavedEdits` (`DocumentModel.swift:1091`) | `.unsaved` |
| phase `.loading` | `.loading` |
| otherwise | `.none` |

("refreshed in the last 6 s" = non-empty `WorkbookDiff` applied by `applyRefresh`; T2 exposes
`public private(set) var lastRefreshAt: Date?` on `DocumentModel` for this — one line, part of C2.)

### 1.6 Permissions & security

- **Workspace grants are untouched.** Opening a tab goes through the same
  `AppModel.openDocument(at:consent:)` grant check/prompt (`AppModel.swift:160-184`). Restored
  tabs use `.fromOutsideTheApp` consent — their folders were granted when first opened, so no
  prompt appears; if a grant was revoked between sessions, the open fails into the tab's
  `.failed` phase with the existing `pathOutsideWorkspace` error. Nothing about tabs may widen a
  grant.
- **Git subprocess safety:** `GitFileVersion` only ever runs `git` with fixed argument arrays
  (never a shell), only against paths already inside a granted workspace (callers pass the
  document URL; the adapter in T7 is only reachable from an open document). Output is bytes, not
  code. `git` absent ⇒ feature silently absent.
- The MCP server, CLI, and deny-list are untouched.
- There is no server/database/RLS in this product; "hostile client" hardening = the parser caps
  already in place. The plan introduces no new parsing surface (checkpoint restore reuses
  `DocumentWorkbookReader`/snapshot bytes; git bytes go through the same hardened readers).

### 1.7 Persistence (no schema migration — everything rides existing tables)

| Key (in `preference` table, `Database.swift:112`) | Value | Written by |
| --- | --- | --- |
| `workspace.tabs` | JSON of `TabsModel.PersistedTabs` | T6 wiring (TabsModel `persist` hook) |
| `checkpoint:<canonical path>` | Snapshot ULID string of the checkpoint | T2 (`setCheckpoint`) |
| UserDefaults `OSChangeHighlights` (bool, default true) | last global highlight toggle | T2 |
| UserDefaults `OSFlagChangeTracking` (bool, default true) | feature flag gating chip/tints/checkpoint command | T2 (flag), read via `Flags` pattern (`AppModel.swift:338-354`) |

Canonical path = `AppModel.documentKey(for:)` (`AppModel.swift:328-330`).
Rollback story: the feature flag hides all change-tracking UI; deleting the two preference keys
returns a clean slate; tabs degrade to "restore nothing" if `workspace.tabs` is absent/corrupt
(corrupt JSON ⇒ treated as absent, never a crash).

### 1.8 Validation

| Input | Rule | Where | Failure behaviour |
| --- | --- | --- | --- |
| Restored tab path | must be absolute; file need not exist (missing ⇒ tab in `.failed`/MISSING state) | `TabsModel.restore` | skip non-absolute entries silently |
| `workspace.tabs` JSON | decodes to `PersistedTabs`; `activeIndex` clamped to range | T6 wiring | treat as absent |
| Checkpoint ULID pref | must parse as `ULID` and resolve via `SnapshotStore.data(for:of:)` with matching hash | T2 restore path | fall back to `.asOpened`, chip label "Since opened" |
| `activate(index:)` | 0-based, in range | `TabsModel` | no-op |
| Git output | `headBytes` size ≤ cap; UTF-8 relpath; exit status 0 | T5 | return nil |
| `reveal(sheetName:refA1:)` | sheet must exist by name, ref must parse via `CellRef(a1:)` | T6 handler | no-op |

No user-typed input is introduced anywhere in this feature, so there are no user-facing
validation messages beyond the designed states above.

### 1.9 Edge cases (intended behaviour, stated)

- **Same file opened twice** (any entry point): activates the existing tab. (Dedupe by
  `documentKey`; `AppModel` already refuses a second model — `AppModel.swift:135-141`.)
- **Two files, same name, different folders:** disambiguator shows parent folder on *both* tabs.
  Three-way collisions: still just parent folder (VS Code does path-suffix escalation; v1 keeps
  it to one level — full path is one hover away).
- **Close tab with unsaved edits:** confirm sheet (Save / Discard / Cancel). Save failure keeps
  the tab open with the error surfaced via existing `lastError` presentation.
- **Close window (⌘⇧W / red button):** if any tab has unsaved edits, one confirm listing them;
  otherwise closes all tabs (models released — watcher fd cleanup is `DocumentModel.close()`,
  `DocumentModel.swift:177-190`) and persists the tab set *before* closing so relaunch restores it.
- **Quit:** same sweep via `AppModel.openDocuments` (`AppModel.swift:233-235`) — unchanged from
  today's behaviour, but T8 must verify no regression.
- **File deleted while its tab is in background:** model goes MISSING; dot turns red; activating
  the tab shows the existing MISSING empty state with Save As. Tab close allowed.
- **200 writes/s agent burst on a background tab:** debounce + coalescing is upstream in the
  watcher (`FileWatcher.swift:59-66`); the only new work per refresh is the baseline recompute,
  which is debounced (500 ms) and cancelled when superseded — verify no pile-up (T2 test).
- **1M-cell workbook baseline diff:** `WorkbookDiffer.Options.comparisonBudget` caps work;
  `wasTruncated` ⇒ chip shows `500+` style counts, grid tints render only the listed changes,
  panel says "too many changes to enumerate". Never block the main actor.
- **Checkpoint snapshot evicted** (20-per-file cap): relaunch falls back to `.asOpened` (§1.3).
- **Baseline parse of checkpoint bytes fails** (file format changed on disk since, corrupt gz):
  same fallback, `lastError` untouched (this is not an error the user caused).
- **git repo with dirty index / file untracked / LFS placeholder:** `headBytes` returns nil ⇒
  source not offered / falls back with the label explaining ("No committed version").
- **CSV tabs:** everything works identically — CSV yields one sheet with `SheetID(1)`
  (`SheetFormat/CSV/CSVReader.swift:313-318`); the differ and highlights are sheet-id-keyed.
- **Double-⌘W race:** `TabsModel.close` on an id not in `tabs` is a no-op.
- **Open while a tab is mid-load for the same path:** `AppModel.opening` coalesces
  (`AppModel.swift:89`); the tab stays `.loading` until the shared task resolves.
- **Window restoration:** stays `.disabled` (`App/OpenSheetsApp.swift:76`). Tab restore is our
  own deterministic path through `OpenActions.handleLaunch`, not SwiftUI scene restoration —
  restoring runs ONLY when the launch carries no file arguments.
- **Reduce transparency / increase contrast:** chip and tab strip follow `AppearanceContext`
  like every GlassUI component; tint opacities must also pass the existing snapshot matrix
  (`GlassUI/Tokens/AppearanceContext.swift:115-122`). Grid tints under increased contrast use
  the same colours (they are content annotations, not chrome) but must keep cell text ≥ 4.5:1 —
  that is what the low default opacities are for; T4's `PaletteContrastTests` additions assert it.

### 1.10 Rollout

1. Wave order below **is** the deploy order; nothing ships user-visible until T6/T7 land, and
   the package stays green after every wave (each wave's additions are inert until wired).
2. `OSFlagChangeTracking` (default **true**) gates: chip, panel, grid tints, Set Checkpoint
   command, baseline machinery activation. Flipping it off returns the exact pre-feature
   experience minus tabs. Tabs themselves are **not** flagged: they replace the window
   architecture, and a flag would mean maintaining two window models (the project's flag
   philosophy is "ship unfinished work dark", not "keep finished work optional" — PLAN.md §11).
3. No DB migration, no new env vars, no third-party services, single environment (the user's
   Mac). Distribution unchanged.
4. Verify in "production" = run the built app: `Scripts/build.sh` then open two files from
   different folders, run an external edit, checkpoint, relaunch. T8 walks this literally.
5. Rollback = revert the merge commits; preferences left behind are harmless (unknown keys are
   never read).

### 1.11 Test plan (summary — per-task specifics in the task blocks)

Commands (from repo root):

```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors
cd Packages/OpenSheetsCore && swift test  -Xswiftc -warnings-as-errors
Scripts/test.sh --filter <SuiteName>
swiftformat --lint .
swiftlint lint --strict
Scripts/build.sh          # package + app (xcodebuild, warnings fail)
```

- Unit: `TabsModel` lifecycle/dedupe/persistence; baseline recompute triggers, debounce,
  cancellation, checkpoint persistence round-trip; `ChangeHighlights` rendering (image-diff via
  existing `RenderSurface` harness); `GitFileVersion` against a fixture repo created in a temp
  dir by the test itself; component model equality/mapping in GlassUI.
- Integration (DocumentCoreTests): open→edit-externally→refresh→counts; checkpoint→relaunch
  simulation (new AppModel over same store); window-rule scenarios rewritten for one-workspace.
- The perf gates in CI must stay green: no per-frame allocation in the tint pass, budgets in
  `docs/perf/` untouched.

---

## 2. Agent tasks

> Sizing note: each task is one focused agent. "Region" notes say where in the file to work.
> Every task: finish with `swift build` + `swift test` (with `-Xswiftc -warnings-as-errors`),
> `swiftformat .`, `swiftlint lint` clean. Do not edit files outside your list — if you are
> blocked without one, stop and report.

### Agent T1 — Tabs core: `TabsModel` and the one-workspace window rules
**Goal:** `TabsModel` (contract C1) exists and is fully tested, and `DocumentWindows` enforces
"one workspace window + launcher" (contract C6) with its test suite updated to the new rules.
**Depends on:** none — can start immediately.
**Files to create:**
- `Packages/OpenSheetsCore/Sources/DocumentCore/TabsModel.swift`
- `Packages/OpenSheetsCore/Tests/DocumentCoreTests/TabsModelTests.swift`
**Files to modify:**
- `Packages/OpenSheetsCore/Sources/DocumentCore/DocumentWindows.swift` — replace
  `WindowRoleView.path` with `role` enum; rewrite `DocumentWindows` per C6 (keep the
  `roleView(in:)` walker `:154-161` and `oldestFirst` `:150-152` as-is; keep the long doc
  comments' spirit — update their content to the new rules, keep the "why a marker not a
  registry" story `:8-18`).
- `Packages/OpenSheetsCore/Tests/DocumentCoreTests/OpenDocumentTests.swift` — window-level
  scenarios only: `twoFilesKeepTwoWindows` (`:155-163`) becomes an assertion that two opens
  yield ONE workspace window; `reopeningAnAlreadyOpenFileLeavesOneWindow` (`:116`),
  `twoSpellingsOfOnePathAreOneWindow` (`:134`), `argumentOrderIsTheOrderWindowsOpenIn` (`:411`)
  are re-expressed at the tab level using `TabsModel` with a fake opener. **Model-level
  scenarios (AppModel one-model-per-file) are untouched.**
**Do NOT touch:** `AppModel.swift`, `DocumentModel.swift` (T2 owns both), anything in `App/`
(T6 owns it), `SheetModel/` (frozen).
**Context it needs:**
- C1 and C6 above, verbatim.
- `@Observable` per-document pattern and its rationale: `DocumentCore/DocumentModel.swift:14-23`.
- Identity function: `AppModel.documentKey(for:)` — `DocumentCore/AppModel.swift:328-330`
  (call it; do not duplicate the logic).
- `WorkspaceConsent` — `DocumentCore/AppModel.swift:34-39`.
- House test style: `Tests/DocumentCoreTests/OpenDocumentTests.swift` (Swift Testing, `@Suite`,
  scenario naming in prose).
**Implementation notes:**
- `open(_:consent:)` must handle the *re-entrant* case: a second `open` for the same URL while
  the first is loading activates the existing loading tab (phase stays `.loading`) — the
  underlying `AppModel.opening` coalescing (`AppModel.swift:79-89`) makes the injected `open`
  hook safe to call twice, but the tab list must not grow.
- Closing the active tab activates the right neighbour, else left, else `activeTabID = nil`.
- `restore` opens sequentially (not in a task group) so tab order is deterministic; individual
  failures land in that tab's `.failed` phase and do not stop the rest.
- `persist` fires on every membership/active change including during `restore` (idempotent).
- Do not import AppKit in `TabsModel.swift` (keep it testable on any destination the package
  supports); `DocumentWindows.swift` already `#if canImport(AppKit)` — keep that.
**Acceptance criteria:**
1. `swift build -Xswiftc -warnings-as-errors` and `swift test -Xswiftc -warnings-as-errors`
   pass from `Packages/OpenSheetsCore`.
2. `TabsModelTests` covers, with a fake opener/closer/persistor: open two distinct files → two
   tabs in order, second active; open first again → still two tabs, first active; close active
   middle tab → right neighbour becomes active; close last remaining tab → `tabs.isEmpty` and
   `activeTabID == nil`; failing opener → tab in `.failed`, other tabs unaffected; `restore`
   with one bad + two good paths → three tabs, bad one `.failed`; every mutation invoked
   `persist` with the correct `PersistedTabs` (assert the last value and call count).
3. `activate(index:)` out of range is a no-op (asserted).
4. `OpenDocumentTests` window scenarios compile and pass against the new
   `DocumentWindows.workspaces(in:)`/`extras(in:)`: two workspace windows → oldest kept, newer
   in `extras`; launcher + workspace → launcher in `extras`; launcher alone → kept.
5. No file outside the four listed is modified (`git status` shows only them).
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'TabsModel|OpenDocument'
swiftformat --lint . && swiftlint lint --strict
```

### Agent T2 — Baseline & checkpoint core in the document model
**Goal:** `DocumentModel` tracks a baseline per contract C2 — default as-opened, user
checkpoint backed by a persistent snapshot, optional git source via injected provider — and
recomputes `baselineDiff` off-main on every relevant change.
**Depends on:** none — can start immediately.
**Files to create:**
- `Packages/OpenSheetsCore/Sources/DocumentCore/BaselineTracker.swift`
- `Packages/OpenSheetsCore/Tests/DocumentCoreTests/BaselineTrackingTests.swift`
**Files to modify:**
- `Packages/OpenSheetsCore/Sources/DocumentCore/DocumentModel.swift` — add C2 members; hook
  recompute into `applyRefresh` (`:242-289`, after the workbook swap), the save-completed event
  (`case .saved` in `handle(_:)` `:227-230`), and the local-edit path (`markEdited`/commit —
  debounce 500 ms); add `lastRefreshAt` stamping in `applyRefresh`.
- `Packages/OpenSheetsCore/Sources/DocumentCore/AppModel.swift` — pass the checkpoint
  persistence handle into `DocumentModel` in `load(_:key:consent:)` (`:208-216` region), and add
  `changeTrackingEnabled` to the `Flags` enum (`:338-354`) reading `OSFlagChangeTracking`
  default true.
- `Packages/OpenSheetsCore/Sources/SheetStore/SnapshotStore.swift` — add
  `case checkpoint` to `SnapshotReason` (`:7-26`) with `label` "checkpoint". (`parse` already
  falls back to `.manual` for unknown reasons — `:367-371` — so old builds degrade safely.)
- `Packages/OpenSheetsCore/Sources/SheetStore/DocumentSession.swift` — add
  `public func captureSnapshot(reason: SnapshotReason, summary: String?) async throws(SheetError) -> SnapshotRecord?`
  delegating to the session's snapshot store with the document's URL (near `snapshotHistory()`
  at `:222`).
- `Packages/OpenSheetsCore/Sources/SheetStore/Database.swift` — nothing structural: use the
  existing `preference`/`setPreference` (`:142`, `:149`). Add a tiny typed wrapper ONLY if it
  keeps call sites honest; otherwise leave the file untouched.
- `Packages/OpenSheetsCore/Tests/SheetStoreTests/SnapshotStoreTests.swift` — cases for the new
  reason: filename round-trip `<ulid>.checkpoint.gz`, list/restore behaviour identical to
  `.manual`.
**Do NOT touch:** `TabsModel.swift`/`DocumentWindows.swift` (T1), `GridKit/*` (T3),
`GlassUI/*` (T4), `SheetModel/` (frozen), `WorkbookDiffer.swift` (used as-is).
**Context it needs:**
- C2 verbatim, §1.3 semantics, §1.7 persistence keys, §1.9 edge cases (burst debounce,
  truncation, eviction fallback).
- `WorkbookDiffer` API: `SheetStore/WorkbookDiffer.swift:16-102` (`diff(before:after:)` at
  `:71`; `Options.default` fine for v1).
- Snapshot plumbing: `SnapshotStore.capture` `:145`, `data(for:of:)` `:224`; ULID sorts by
  time. `DocumentSession` holds the store (constructed at `AppModel.swift:194-204`).
- Concurrency model: `DocumentModel` is `@MainActor @Observable` (`DocumentModel.swift:41-43`);
  `Workbook` is a `Sendable` value; PLAN.md §2.3. Recompute pattern: capture the two workbook
  values, `Task.detached` (or a dedicated actor in `BaselineTracker`), apply the result back on
  main **only if the generation still matches** (guard against a stale result landing after a
  newer edit — keep a monotonically increasing generation counter; `workbookGeneration` already
  exists on the model, `DocumentModel.swift:245`).
- Checkpoint restore at open: read pref `checkpoint:<canonical path>`; if a ULID parses, load
  bytes via the snapshot store and parse with the same reader used for files
  (`DocumentWorkbookReader` — `DocumentCore/WorkbookIOAdapters.swift:28`; note its
  `read` is URL-based: write the snapshot bytes to a temp file under
  `FileManager.default.temporaryDirectory` and read that, then delete it. A data-based read
  overload on the reader is also acceptable if it stays inside `WorkbookIOAdapters.swift` —
  which you then own for that one addition; state it in your report).
- Flags pattern: `DocumentCore/AppModel.swift:338-354` (read fresh each check, default via
  `object(forKey:) as? Bool ?? default`).
**Implementation notes:**
- When `Flags.changeTrackingEnabled` is false: `baselineDiff` stays nil, `setCheckpoint()` and
  `setBaselineSource` are no-ops, zero background work — the flag must remove the cost, not
  just the UI.
- `setCheckpoint()` order: capture snapshot (reason `.checkpoint`, summary "checkpoint") →
  persist ULID pref → set `baselineSource = .checkpoint`, `baselineDate = now`, baseline
  workbook = current `workbook` → recompute (which yields `.empty` immediately).
- `.gitHEAD`: `setBaselineSource(.gitHEAD)` calls `gitBaselineProvider?(url)`; nil result ⇒
  revert to previous source (never leave the model claiming a baseline it does not have).
  `isGitBaselineAvailable` is set once at init-time by a fire-and-forget probe **only when the
  provider is non-nil** (wave 2 injects it; in wave 1 it stays nil and the code path is dormant).
- Style-only changes: counted into `BaselineCounts.styleOnly` from the diff's `.styleChanged`
  cell changes; excluded from added/modified/removed.
- `isChangeHighlightingEnabled` mirrors UserDefaults `OSChangeHighlights` (read at init, write
  on set) — global, not per-document, on purpose (Apple-simple: one switch).
**Acceptance criteria:**
1. Package builds and full test suite passes with warnings-as-errors.
2. `BaselineTrackingTests` proves: fresh model → `baselineSource == .asOpened`,
   `baselineDiff == .empty` (after settle); external-style workbook replacement via the session
   → diff reflects added/modified/removed counts exactly for a crafted 3-change case; 10 rapid
   edits → at most N recomputes where N < 10 (debounce observed) and final diff is correct;
   `setCheckpoint()` → diff `.empty`, snapshot with reason `.checkpoint` exists in the store,
   pref `checkpoint:<path>` holds its ULID; new model over the same store/URL → baseline
   restored from checkpoint (counts vs a mutated file are non-zero and correct); deleted
   snapshot + new model → source falls back to `.asOpened` without error.
3. `SnapshotStoreTests` new cases pass: capture with `.checkpoint` produces
   `<ulid>.checkpoint.gz`, appears in `snapshots(for:)`, restores byte-identically.
4. With `OSFlagChangeTracking` = false (use `AppModel.autoRefreshForNewDocuments`-style
   injection or set the default in the test's UserDefaults suite), no diff is ever computed
   (assert `baselineDiff` stays nil after edits).
5. A stale recompute cannot clobber a newer one (test with a manually-controlled slow diff via
   small workbooks + generation assertion, or by asserting final state after interleaved edits).
6. `git status` shows only the listed files.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'BaselineTracking|SnapshotStore'
swiftformat --lint . && swiftlint lint --strict
```

### Agent T3 — GridKit: persistent change tints
**Goal:** `GridView` accepts `ChangeHighlights` (contract C3) and the renderer draws green/amber/
red cell tints plus inserted-row/column bands, under selection and flash, at zero cost when empty.
**Depends on:** none — can start immediately.
**Files to create:**
- `Packages/OpenSheetsCore/Sources/GridKit/ChangeHighlights.swift`
- `Packages/OpenSheetsCore/Tests/GridKitTests/ChangeHighlightTests.swift`
**Files to modify:**
- `Packages/OpenSheetsCore/Sources/GridKit/GridTheme.swift` — add the five C3 theme fields
  (near `flashTint` `:106-110`; extend the memberwise init `:174-176` with defaulted params so
  existing call sites compile unchanged). Defaults (RGBA, both schemes handled by the bridge
  later — pick values that read on both white and `#1C1C1E`): green `0.20 0.78 0.35`, amber
  `1.00 0.72 0.18`, red `1.00 0.33 0.33`.
- `Packages/OpenSheetsCore/Sources/GridKit/GridRenderModel.swift` — add
  `public var highlights: ChangeHighlights` (defaulted `.none`, beside `flash` `:24-25`); add
  the resolved CGColors beside `flashTint` (`:123`, `:147`).
- `Packages/OpenSheetsCore/Sources/GridKit/GridRenderer.swift` — new
  `drawChangeTints(_:model:context:offset:)` pass invoked immediately **before**
  `drawFlashTints` (`:279`), so a fresh flash reads on top of a standing tint. Bands first
  (inserted rows/columns across the visible rect at `changeBandOpacity`), then per-cell fills at
  `changeTintOpacity`. Iterate the *visible* refs the same way `drawFlashTints` does
  (`:282-302`) — cost proportional to viewport, never to set size. Merged cells: same treatment
  as flash (`:366-369`).
- `Packages/OpenSheetsCore/Sources/GridKit/GridView.swift` — add
  `highlights: ChangeHighlights = .none` to the init (after `options`); thread into
  `renderModel` (`:229-242`).
- `Packages/OpenSheetsCore/Sources/GridKit/GridHostView.swift` — `update(model:)` (`:249-266`)
  already compares render models by value; confirm `ChangeHighlights: Equatable` participates so
  a highlight change invalidates and an unchanged one does not. Invalidate only the affected
  rect when feasible; whole-viewport invalidation on highlight *change* is acceptable (it is not
  per-frame).
**Do NOT touch:** `FlashController.swift` (flash stays independent), `GlassUI/*` (T4 owns the
design-system side), `DocumentCore/*`, `SheetModel/` (frozen).
**Context it needs:**
- C3 verbatim. Flash drawing as the pattern: `GridRenderer.swift:279-302`, model fields
  `GridRenderModel.swift:24-52`, theme fields `GridTheme.swift:106-110`.
- Perf discipline: `GridRenderer.swift:9-20` (frame cost ∝ screen, never sheet), CI perf gates
  (PLAN.md §10.6). No allocation inside the draw loop — pre-resolve the three CGColors like
  `flashTint` (`GridRenderModel.swift:147`).
- Render test harness: `Tests/GridKitTests/RenderSurface.swift` + `RenderTests.swift` show how
  to draw into a bitmap and assert pixels; `FlashAndCacheTests.swift` shows flash-specific
  assertions to mirror.
**Implementation notes:**
- Removed-cell tint draws on the (now possibly empty) cell rect — that is correct and cheap;
  do not attempt tombstone geometry.
- A cell in both `modified` and a banded inserted row should not double-darken noticeably;
  draw bands at `changeBandOpacity` and skip per-cell fill when the cell's row/col is banded
  *and* the cell is in `added` (a banded new row's cells are conceptually the band).
- `showsFormulas`, zoom, frozen panes: tints must land in every pane the cell is visible in —
  follow wherever `drawFlashTints` is called per-pane.
**Acceptance criteria:**
1. Package builds/tests green, warnings-as-errors; existing `GridKitTests` untouched and green
   (`GridPerformanceTests` included).
2. `ChangeHighlightTests` proves, via `RenderSurface` pixel assertions: an `added` ref renders
   greener than its unhighlighted neighbour; `modified` renders amber-shifted; `removed`
   red-shifted; an inserted-row band tints the full visible row width; `ChangeHighlights.none`
   renders byte-identical output to a build without highlights (baseline image equality);
   highlights render in a frozen pane when the ref is frozen.
3. Flash-over-tint: with the same ref flashed at intensity 1 and tinted, the flash colour
   dominates (pixel assertion at flash peak).
4. `GridView` init default keeps every existing call site compiling (no other file modified —
   `git status` proves it).
5. No allocation in `drawChangeTints` per cell beyond stack values (review + no CGColor
   creation inside the loop; colours pre-resolved on the model).
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'ChangeHighlight|Render|GridPerformance|FlashAndCache'
swiftformat --lint . && swiftlint lint --strict
```

### Agent T4 — GlassUI: file tab strip, changes chip & panel, tokens
**Goal:** The pure design-system components of contract C4 exist with tokens, previews, and
tests — consumable by the app layer without modification.
**Depends on:** none — can start immediately.
**Files to create:**
- `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/FileTabStrip.swift`
- `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/ChangeTracking.swift`
**Files to modify:**
- `Packages/OpenSheetsCore/Sources/GlassUI/Tokens/Palette.swift` — add explicit light/dark
  pairs: `changeAdded`, `changeModified`, `changeRemoved` (ink + tint variants following the
  signal pattern `:152-185`). This is the ONLY file that may hold the literals.
- `Packages/OpenSheetsCore/Sources/GlassUI/Tokens/DS.swift` — add `DS.Change` namespace
  exposing `addedInk/modifiedInk/removedInk(context)` and tint accessors, following `DS.Signal`
  (`:300-403`) including the reduce-transparency/increase-contrast handling.
- `Packages/OpenSheetsCore/Sources/GlassUI/Grid/GridTheme.swift` — add the matching five fields
  to the design-system grid theme and populate them in `resolved(_:)` (`:120`) from the new
  palette entries.
- `Packages/OpenSheetsCore/Sources/GlassUI/Floating/SnapshotBrowser.swift` — add `checkpoint`
  case to the GlassUI `SnapshotReason` mirror (the app maps by rawValue at
  `App/DocumentWindow.swift:331`, falling back to `.manual` — adding the case makes checkpoint
  snapshots self-describing in the browser). Label: "checkpoint".
- `Packages/OpenSheetsCore/Sources/GlassUI/Gallery/Previews.swift` — previews for
  `FileTabStrip` (states: single tab, many tabs with every `Status`, duplicate-name
  disambiguators, overflow scroll) and `ChangeTrackingChip`/`Panel` (counts, truncated,
  git source offered/not offered).
- `Packages/OpenSheetsCore/Tests/GlassUITests/ComponentModelTests.swift` — model-level tests
  for the new state types.
- `Packages/OpenSheetsCore/Tests/GlassUITests/PaletteContrastTests.swift` — contrast
  assertions: change inks ≥ 4.5:1 against chrome surfaces in both schemes; tint-over-canvas
  keeps `Palette` cell ink ≥ 4.5:1 at the documented opacities (0.14 fill on `#FFFFFF` and
  `#1C1C1E`).
**Do NOT touch:** `SheetTabBar.swift` (sheet tabs are a different control and stay at the
bottom), `GridKit/*` (T3 owns the renderer-side theme), `DocumentCore/*`, `App/*`.
**Context it needs:**
- C4 verbatim, §1.5 status semantics (the strip renders the dot colour purely from `Status`:
  none→nothing, loading→`ProgressView` 10 pt, unsaved→`DS.Chrome.secondary` dot,
  agentChanged→`DS.Chrome.accent` dot, conflict→`DS.Signal` conflict ink dot,
  problem→`DS.Change.removedInk`-red dot; 5 pt circles like `SheetTabBar.swift:212-217`).
- The component pattern to copy exactly: `GlassUI/Chrome/SheetTabBar.swift` (state struct,
  action enum, `perform` closure, one-lens rule `:80-88` — the strip is ONE surface, tabs are
  fills inside it; active tab = accent-filled capsule, `:222-228`).
- The strip lives in the **title bar row**, which drags the window on empty stretches
  (`App/WindowSupport.swift:184-189`): the strip must not stretch to fill — it hugs its
  content (`.fixedSize(horizontal:)` semantics with internal `ScrollView(.horizontal)` capped
  by a `maxWidth` the host passes via layout, exactly like `SheetTabBar`'s scroll region
  `:112-120`) so a Spacer beside it stays click-through for dragging.
- Chip typography: counts use `dsNumeric` (`GlassUI/Tokens/Typography.swift:109`); prefix
  glyphs `+ ~ −` coloured by `DS.Change` inks; the chip itself is a capsule like
  `SyncStateChip` (`GlassUI/Chrome/WindowChrome.swift:94`).
- Panel rows: mirror the diff panel's row shape (`GlassUI/Sync/SyncSurface.swift` — `DiffRow`
  at `:358`) — before → after in monospaced digits; section header per sheet; `omittedCount`
  renders "+N more".
- Accessibility: every control labelled; dots also carried in the accessibility label (status
  spoken, not colour-only) — see `SheetTabBar.swift:271-280`.
- GlassLint will fail literals/spacing outside tokens — run `swift test --filter GlassLint`.
**Implementation notes:**
- Close affordance: ✕ appears on hover (and always on the active tab), 16 pt hit target with
  `DS.Space.hitSlop`; context menu carries Close, Close Others, Reveal in Finder, Copy Path.
- `disambiguator` renders after the title in `DS.Chrome.secondary`, `DS.Text.caption`.
- The panel is presented by the app in a popover — the component is just content; include
  `dismiss` in the action enum for the explicit close button.
- No `GlassEffectContainer` violations: chip + sync chip will sit adjacent in the title bar —
  they are separate statements and must NOT merge; annotate with a `glass-lint:` comment as
  `App/GridPane.swift:103-105` does.
**Acceptance criteria:**
1. Package builds/tests green with warnings-as-errors; `GlassLintTests`,
   `PaletteContrastTests`, `AppearanceSnapshotTests` all pass.
2. New contrast assertions pass in light, dark, increaseContrast, reduceTransparency.
3. `ComponentModelTests` covers: `FileTabStripState` equality/identity; status-to-dot mapping
   exposed via an internal pure helper (test it directly); `ChangeTrackingPanelState.Row` id
   uniqueness across sheets.
4. Previews compile (they are part of the target build).
5. Public API matches C4 exactly — T6 compiles against it without edits (the integration agent
   will report any drift as a T4 defect).
6. `git status` shows only the listed files.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'GlassLint|PaletteContrast|ComponentModel|AppearanceSnapshot'
swiftformat --lint . && swiftlint lint --strict
```

### Agent T5 — Git file-version provider
**Goal:** `GitFileVersion` (contract C5) reads HEAD bytes/hash for a path via the `git` binary,
fully async, failure-as-nil, tested against a real temp repo.
**Depends on:** none — can start immediately.
**Files to create:**
- `Packages/OpenSheetsCore/Sources/SheetStore/GitFileVersion.swift`
- `Packages/OpenSheetsCore/Tests/SheetStoreTests/GitFileVersionTests.swift`
**Files to modify:** none.
**Do NOT touch:** everything else — this task is deliberately an island.
**Context it needs:**
- C5 verbatim, §1.6 subprocess rules (fixed argv, no shell, never throw).
- Strict concurrency: `Process` is not `Sendable`-friendly; run each invocation inside a
  detached task or a small helper that owns the process for its lifetime, reading stdout via
  `FileHandle` fully before `waitUntilExit`, with `qualityOfService = .utility`. Locate git via
  `/usr/bin/env git` — actually: use `Process.executableURL = URL(filePath: "/usr/bin/git")`
  and treat a launch failure (no Xcode CLT) as nil; do NOT consult `PATH` (deterministic, and
  avoids running an unexpected binary — this is a security posture, note it in the doc comment).
- Repo-relative path: compute from `repositoryRoot` by path components (mind case-preserving
  APFS: use `FileManager.default.fileExists` semantics, do not lowercase).
- Test style for SheetStore: `Tests/SheetStoreTests/AtomicWriterTests.swift` and
  `SnapshotStoreTests.swift` (temp dirs via `FileManager.default.temporaryDirectory`, cleaned
  in `deinit`/defer).
**Implementation notes:**
- Timeouts: kill the process after 10 s (`terminate()` then `waitUntilExit`) and return nil —
  a hung git (network FS) must not wedge a baseline switch.
- `maxBytes` enforced while reading, not after (stop and return nil past the cap).
- Skip the whole test suite with a recorded issue (`Issue.record` + early return, or
  `.enabled(if:)` trait) when `/usr/bin/git` is absent — CI has it; a user's machine might not.
**Acceptance criteria:**
1. Package builds/tests green with warnings-as-errors.
2. Tests (creating a real repo in a temp dir with `git init`/`add`/`commit` via the same
   subprocess helper): `repositoryRoot` resolves from a nested subdirectory; `headBytes`
   returns the committed bytes, not the working-tree bytes, after the file is modified on disk;
   untracked file → nil; path outside any repo → nil; `headShortHash` returns 7+ hex chars;
   `maxBytes: 4` on a larger file → nil.
3. No test leaves temp state behind (assert cleanup or use fresh UUID dirs).
4. `git status` shows only the two new files.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter GitFileVersion
swiftformat --lint . && swiftlint lint --strict
```

### Agent T6 — App shell: workspace window, tab strip in the title bar, commands
**Goal:** The app opens every file into one workspace window with a working tab strip and
changes chip in the title bar row, tab restore on launch, close-confirm flow, and the full
command set — the feature is user-visible and complete except grid tints (T7).
**Depends on:** T1, T2, T4 (and reads T3's types only through defaults — passing highlights is T7).
**Files to modify:**
- `App/OpenSheetsApp.swift` — `RootView` hosts the workspace: non-nil request seeds
  `tabs.open`; `OpenActions` gains a `static var tabs: TabsModel?` installed by the first
  workspace window (same pattern as `openWindow` `:249-268`): `open(_:consent:)` (`:313-330`)
  becomes "if a workspace window exists → `tabs.open` + front it + tidy; else `openWindow`
  with the request"; `handleLaunch` (`:283-299`) additionally restores `workspace.tabs` (via
  `app.store.database.preference`) when the launch names no files; `WindowRegistrar` (`:216-226`)
  updates to the new `WindowRoleView.role`.
- `App/DocumentWindow.swift` — restructure: `DocumentWindow` becomes the *workspace* window
  view taking `tabs: TabsModel` + `app` + `appearance`; the existing per-document body moves to
  a private `DocumentPane(model:…)` subview unchanged in behaviour; **remove**
  `.onDisappear { app.closeDocument(model) }` (`:127` — lifecycle now belongs to `TabsModel`;
  window teardown closes all tabs); `.focusedSceneValue(\.document, tabs.activeDocument)`;
  `.navigationTitle(activeDocument name or "OpenSheets")`; `TitleBarRow` (`:560-637`) gains the
  `FileTabStrip` (between sidebar toggle and the spacer) and the `ChangeTrackingChip` +
  popover (before `SyncStateChip`), both built inline from model state exactly like
  `snapshotState` (`:320-338`) — status mapping per §1.5, chip/panel state per C4 from C2's
  plain data. Per-tab content switches on the active tab's phase (§1.2 step "empty/loading").
  Tab-close confirm sheet (Save/Discard/Cancel) lives here.
- `App/DocumentCommands.swift` — add to the File group: "Close Tab" ⌘W (disabled when no tab)
  and "Close Window" ⌥⌘W. (Safari uses ⇧⌘W for Close Window, but here ⇧⌘S is Save As
  (`:36-38`) and keeping the ⇧⌘-pair symmetry matters less than not colliding; nothing uses
  ⌥⌘W today. Note the deviation from Safari in the doc comment.) "Set Checkpoint" ⇧⌘K after
  "Refresh from Disk", disabled when no document or flag off; View group: "Next Tab" ⇧⌘] ,
  "Previous Tab" ⇧⌘[ ; Window-style "Show Tab N" via ⌘1…⌘9 calling `tabs.activate(index:)`.
  All read `tabs` via a new `@FocusedValue(\.workspaceTabs)` (add the key beside
  `DocumentFocusKey` `:179-188`).
- `App/WindowSupport.swift` — no metric changes expected; touch only if the row's height math
  needs the strip (it should not — the strip fits the measured `centreFromTop * 2` row).
**Files to create (allowed):** `App/WorkspaceTabsSupport.swift` if `DocumentWindow.swift` grows
past taste — state mapping helpers (tab items, chip state, panel state) may live there. No
pbxproj edit needed (synchronized group).
**Do NOT touch:** `App/GridPane.swift`, `App/SidebarColumn.swift` (T7 owns both),
`App/LauncherScene.swift`, `App/Flags.swift`, anything in `Packages/` (wave-1 owners; report
API drift instead of fixing it yourself).
**Context it needs:**
- Contracts C1, C2, C4, C6; §1.2 flow; §1.5 mapping table; §1.7 keys; §1.9 edge cases
  (close-confirm, double-⌘W, restore-only-when-no-args).
- Title-bar mechanics you must preserve: the row sits on the traffic-light line, height
  `metrics.centreFromTop * 2` (`DocumentWindow.swift:624`), empty stretches drag the window
  (`WindowSupport.swift:184-189`) — the strip and chips are hit-testable, Spacers are not.
- The one-window discipline story you are replacing: read `OpenSheetsApp.swift:26-49` and
  `DocumentWindows` doc comments so the new comments tell the updated story with the same
  honesty.
- Consent: restored tabs and `tabs.open` from `OpenActions.open` pass through the same consent
  values as today (`consents` registry `:252-255`).
- Persist hook: `TabsModel` init's `persist` writes JSON to
  `app.store.database.setPreference("workspace.tabs", …)`; encode with `JSONEncoder`.
**Implementation notes:**
- `TabsModel` construction (in `RootView`/workspace setup):
  `open: { try await app.openDocument(at: $0, consent: $1) }`,
  `close: { app.closeDocument($0) }`. One instance per workspace window; since there is at most
  one workspace window, install it into `OpenActions.tabs` on appear, clear on disappear.
- Window close path: intercept via the confirm flow BEFORE tabs are torn down — use
  `.onDisappear` at workspace level only for cleanup (persist happens on every change already);
  the unsaved sweep runs from the red-button/⌘W-window path (`NSWindow.delegate` is taken by
  SwiftUI — use the existing pattern of asking per-tab on Close Tab, and for Close Window run
  the sweep from the command; the red button without a sweep loses nothing that autosave-off
  users have not already accepted today — windows close without prompting today too. State
  this honestly in a comment; a `windowShouldClose` interception is a follow-up).
- Chip visibility: hidden when `Flags.changeTrackingEnabled == false`, when
  `baselineDiff == nil`, or when counts are all zero and not truncated.
- Panel actions: `.setCheckpoint` → `await model.setCheckpoint()`; `.choose(source)` → map to
  C2 `BaselineSource` and `await model.setBaselineSource(_)`; `.toggleHighlights` → flip
  `model.isChangeHighlightingEnabled`; `.reveal` → resolve sheet by name
  (`workbook.sheet(named:)` — `SheetModel/Workbook.swift:439`), set `activeSheetID`, select +
  scroll via the same three calls as `showInGrid` (`DocumentModel.swift:365-373`).
- Sources offered: always `asOpened`; `checkpoint` labelled with availability;
  `gitHEAD` only when `model.isGitBaselineAvailable` (false until T7 wires the provider —
  fine: the menu simply omits it this wave).
**Acceptance criteria:**
1. `Scripts/build.sh` passes (package + app, xcodebuild, zero warnings from `App/`).
2. Launch with two file arguments (use repo fixtures) → ONE window, two tabs in argv order,
   the LAST opened active (VS Code behaviour). Assert via `DocumentWindows.workspaces(in:)`
   count == 1 where testable; the interactive half is T8's manual walk. For this task: the
   package tests still pass and the app builds.
3. Open the same fixture twice through `OpenActions.open` → `tabs.tabs.count == 1` (unit-level
   assertion added where OpenDocumentTests scenario points, if T1's fake-based tests don't
   already cover the OpenActions seam — otherwise document the manual check for T8).
4. ⌘W closes the active tab; last ⌘W closes the window. ⇧⌘K captures a checkpoint (snapshot
   browser shows a "checkpoint" entry). ⌘1 activates the first tab. (T8 verifies interactively;
   this task's criterion is that the commands exist, are wired to the right calls, and are
   disabled in the right states — reviewable in code + app builds.)
5. Tab restore: with `workspace.tabs` holding two fixture paths and a no-argument launch, two
   tabs open (verify by running the built app once manually; document the observation in your
   report).
6. No file outside your list (plus optional `App/WorkspaceTabsSupport.swift`) is modified.
**Verification commands:**
```bash
Scripts/build.sh
cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors
swiftformat --lint . && swiftlint lint --strict
```

### Agent T7 — Grid tint wiring, theme bridge, palette command, git adapter, sidebar provenance
**Goal:** Baseline diffs actually paint the grid; the GlassUI theme colours reach the renderer;
the git baseline source becomes live; the sidebar's file info shows provenance; the command
palette learns the new verbs.
**Depends on:** T2, T3, T4, T5.
**Files to create:**
- `Packages/OpenSheetsCore/Sources/DocumentCore/ChangeHighlightsMapping.swift` — pure mapping:
  `extension WorkbookDiff { func changeHighlights(for sheetID: SheetID) -> ChangeHighlights }`
  (added/valueChanged+formulaChanged/removed from `cellChanges`; `insertedRows/Columns` from
  `structuralChanges`; `.styleChanged` excluded).
- `Packages/OpenSheetsCore/Sources/DocumentCore/GitBaselineAdapter.swift` — builds the C2
  provider closure from T5: writes `GitFileVersion.headBytes` to a temp file, parses via
  `DocumentWorkbookReader`, returns the `Workbook?`; plus
  `probeAvailability(for url: URL) async -> Bool` (`repositoryRoot != nil` and `headBytes`
  non-nil cheaply — root check only; bytes are fetched on demand).
- `Packages/OpenSheetsCore/Tests/DocumentCoreTests/ChangeHighlightsMappingTests.swift`
**Files to modify:**
- `Packages/OpenSheetsCore/Sources/DocumentCore/GridThemeBridge.swift` — map the five new
  GlassUI grid-theme fields (T4) onto the GridKit theme fields (T3) in `convert` (`:25`).
- `Packages/OpenSheetsCore/Sources/DocumentCore/CommandRegistry.swift` — palette entries:
  "Set Checkpoint", "Toggle Change Highlights", "Next Tab", "Previous Tab" (the two tab verbs
  emit new `PaletteCommand` cases the window already routes — coordinate: add the cases here,
  and note that `App/DocumentWindow.swift`'s `run(_:)` switch is T6's; since T6 runs in the
  same wave, ADD the cases with safe no-op routing via a new closure the window installs —
  simplest: give `PaletteCommand` cases `.setCheckpoint`, `.toggleChangeHighlights`,
  `.nextTab`, `.previousTab`, and have the registry only offer the tab verbs when a new
  `hasTabs: Bool` parameter is true; T6's switch handles them — T6's task list already includes
  `DocumentWindow.swift`, and ITS acceptance includes compiling against the registry, so the
  registry cases must exist before T6 finishes. **Wave note: T6 and T7 both run in wave 2 —
  the orchestrator should start T7's `CommandRegistry.swift` commit early or T6 should
  hold its palette wiring until T7's registry lands; the two tasks touch disjoint files, so
  merge order is registry-first.**)
- `App/GridPane.swift` — pass
  `highlights: model.isChangeHighlightingEnabled ? (model.baselineDiff?.changeHighlights(for: model.activeSheetID) ?? .none) : .none`
  into `GridView` (`:48-65` region). Memoize per (diff, sheet) with a tiny `@State` cache keyed
  on `model.workbookGeneration`+sheet if profiling shows body-eval cost; the diff's change list
  is capped, so direct computation is acceptable first.
- `App/SidebarColumn.swift` — file-info section: add the full folder path row (the provenance
  answer at rest, complementing tab tooltips) with a "Reveal in Finder" affordance; wire
  nothing else new.
**Do NOT touch:** `App/DocumentWindow.swift`, `App/OpenSheetsApp.swift`,
`App/DocumentCommands.swift` (T6), any T1–T5 file.
**Context it needs:**
- C2, C3, C5 contracts. **Git wiring split (both agents read this):** C2 declares
  `gitBaselineProvider` and `isGitBaselineAvailable` settable post-init. T7 exposes
  `GitBaselineAdapter.install(on model: DocumentModel)` — sets the provider and kicks the
  async availability probe. The ONE call site (`GitBaselineAdapter.install(on:)` in the
  tab-ready path) lives in T6's `App/DocumentWindow.swift`, but T6 runs in the same wave and
  must not depend on T7's file: **T6 omits the call; T8 adds the one line during integration.**
  T8's checklist includes it explicitly.
- Mapping semantics §1.3 (style-only excluded, banded-row cells skip per-cell green — mirror
  T3's renderer rule so counts and pixels agree).
- `GridThemeBridge` conversion style: `DocumentCore/GridThemeBridge.swift:19-25`.
- Palette registry shape: `DocumentCore/CommandRegistry.swift` (sections/commands built at
  `App/DocumentWindow.swift:389-402`).
**Acceptance criteria:**
1. Package + app build green, warnings-as-errors; full `swift test` green.
2. `ChangeHighlightsMappingTests`: a `WorkbookDiff` with 2 added, 3 value-changed, 1
   formula-changed, 1 style-changed, 1 removed, and an inserted-row structural change maps to
   `added.count == 2`, `modified.count == 4`, `removed.count == 1`, `insertedRows == [i]`,
   style-change absent; sheet-id filtering proven with a two-sheet diff.
3. Adapter test (behind the same git-present guard as T5): `install(on:)` against a model whose
   URL sits in a fixture repo flips `isGitBaselineAvailable` to true; `setBaselineSource(.gitHEAD)`
   then yields non-nil `baselineDiff` reflecting a change committed vs working tree. (Reuse
   T5's temp-repo helper via `@testable import` or duplicate the 20-line helper — duplication
   in tests beats a cross-target test dependency; say which you did.)
4. `GridThemeBridge` maps all five fields (unit assertion comparing resolved values to palette
   entries in both schemes).
5. Sidebar shows the folder path for the open document (visual check in gallery/preview or
   presentation-test if `PresentationTests.swift` has the pattern — do not modify that file if
   it is outside taste; a preview is sufficient, state which).
6. `git status` shows only your listed files.
**Verification commands:**
```bash
cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors --filter 'ChangeHighlightsMapping|GitBaseline'
Scripts/build.sh
swiftformat --lint . && swiftlint lint --strict
```

### Agent T8 — Integration, end-to-end verification, docs (final wave, solo)
**Goal:** The seams are reconciled, every acceptance criterion above is re-verified, the full
user flow works in the built app, and the docs tell the truth.
**Depends on:** T1–T7 all merged.
**Files it may touch:** anything, minimally — its job is reconciliation, not rework. Expected:
the one `GitBaselineAdapter.install(on:)` call in `App/DocumentWindow.swift` if T6/T7
sequencing left it missing; import fixes; `DOCUMENTATION.md` (§ features + §12 limitations);
`README.md` (feature-flag list gains `OSFlagChangeTracking`; layout section mentions tabs);
`docs/agents/` — add a brief `T-tabs-tracking.md` recording ownership of the new files.
**The checklist (report pass/fail per line, fix or file honestly):**
1. `cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors` ✅/❌
2. `swift test -Xswiftc -warnings-as-errors` — full suite, including perf lanes ✅/❌
3. `Scripts/test.sh --release` ✅/❌ (perf budgets)
4. `Scripts/build.sh` (app, zero warnings) ✅/❌
5. `swiftformat --lint .` and `swiftlint lint --strict` ✅/❌
6. Seam audit: no orphaned/duplicated helpers across T4/T6/T7 mappings; every contract type
   matches this plan verbatim (list drift); no leftover `notImplemented` in feature paths; the
   `GitBaselineAdapter.install` call exists in the tab-ready path.
7. **Manual E2E walk of §1.2, every numbered step**, using `Fixtures/basic/*` copies in two
   temp folders (never edit fixtures in place): single window; disambiguators; background
   external edit (`python3` + a byte-append or the `opensheets` CLI write) → accent dot →
   tints on activation; chip counts match a hand-counted 3-cell edit; checkpoint → tints
   clear → relaunch → checkpoint persists; git source appears for a file inside this repo's
   work tree and diffs vs HEAD; close-with-unsaved confirm; last-tab close; relaunch restores
   tabs; launcher appears when `workspace.tabs` is cleared.
8. Flag off (`defaults write com.quino.opensheets OSFlagChangeTracking -bool NO`): chip,
   panel, ⇧⌘K, tints all absent; tabs unaffected. Flag deleted afterwards.
9. Error states: revoke a grant (Settings ▸ Workspace) → relaunch → restored tab shows the
   designed failure, not an alert; delete a background tab's file → red dot → MISSING state.
10. Accessibility spot-check: reduce transparency on → strip/chip legible; VoiceOver labels on
    tabs announce name + status.
11. Permissions audit per §1.6: confirm no new path can bypass the grant check (code review of
    `TabsModel.open` → `AppModel.openDocument` and the git adapter's URL source).
12. Docs updated; `docs/mcp.md` untouched (already superseded).
**Verification commands:** the checklist's own; plus a final `git status` review that the
worktree matches the intended file set across all tasks.

---

## 3. Execution graph

| Wave | Agents | Parallel-safe? | Why the boundary exists |
| --- | --- | --- | --- |
| 1 | T1 (tabs core) · T2 (baseline core) · T3 (GridKit tints) · T4 (GlassUI components) · T5 (git provider) | Yes — zero shared files (ownership table below) | Wave 2 compiles against every wave-1 contract (C1–C6) |
| 2 | T6 (app shell) · T7 (wiring/adapters) | Yes — disjoint files; **merge T7's `CommandRegistry.swift` before T6's palette wiring** (noted in both tasks) | T8 needs the whole feature assembled |
| 3 | T8 (integration) | Solo | Final reconciliation must see everything |

Critical path: T2 → T7 → T8 (baseline core is the largest wave-1 task).
Strictly sequential pairs: none within a wave except the T7-registry/T6-palette merge-order note.
Shared-file forcings avoided by design: `AppModel.swift` (T2 only), `DocumentModel.swift`
(T2 only), `DocumentWindow.swift` (T6 only), `GridPane.swift`/`SidebarColumn.swift` (T7 only),
`Palette.swift`/`DS.swift` (T4 only), Snapshot/Session/Database (T2 only).

File-ownership matrix (per wave, one owner per file — the integrator T8 may touch anything):

| File | Owner |
| --- | --- |
| `DocumentCore/TabsModel.swift`, `DocumentCore/DocumentWindows.swift` | T1 |
| `DocumentCore/DocumentModel.swift`, `DocumentCore/AppModel.swift`, `DocumentCore/BaselineTracker.swift`, `SheetStore/SnapshotStore.swift`, `SheetStore/DocumentSession.swift`, `SheetStore/Database.swift`, (`DocumentCore/WorkbookIOAdapters.swift` if data-read overload chosen) | T2 |
| `GridKit/ChangeHighlights.swift`, `GridKit/GridTheme.swift`, `GridKit/GridRenderModel.swift`, `GridKit/GridRenderer.swift`, `GridKit/GridView.swift`, `GridKit/GridHostView.swift` | T3 |
| `GlassUI/Tokens/Palette.swift`, `GlassUI/Tokens/DS.swift`, `GlassUI/Grid/GridTheme.swift`, `GlassUI/Chrome/FileTabStrip.swift`, `GlassUI/Chrome/ChangeTracking.swift`, `GlassUI/Floating/SnapshotBrowser.swift`, `GlassUI/Gallery/Previews.swift` | T4 |
| `SheetStore/GitFileVersion.swift` | T5 |
| `App/OpenSheetsApp.swift`, `App/DocumentWindow.swift`, `App/DocumentCommands.swift`, `App/WindowSupport.swift`, (`App/WorkspaceTabsSupport.swift`) | T6 |
| `App/GridPane.swift`, `App/SidebarColumn.swift`, `DocumentCore/GridThemeBridge.swift`, `DocumentCore/CommandRegistry.swift`, `DocumentCore/ChangeHighlightsMapping.swift`, `DocumentCore/GitBaselineAdapter.swift` | T7 |
| `DOCUMENTATION.md`, `README.md`, `docs/agents/T-tabs-tracking.md` | T8 |

Test files follow their source owner (listed in each task).

---

## 4. OPEN decisions (proceeding on the recommendation)

1. **Tab restore on launch** — recommended and planned: restore when the launch names no files;
   the launcher only shows on a truly empty slate. Alternative (always launcher, explicit
   "Reopen tabs") is one small change in T6 if the user prefers.
2. **Git baseline in v1** — recommended and planned (the user asked for "between commits"
   explicitly); it is isolated (T5 + one adapter) and degrades to absent. Cutting it removes
   T5 and shrinks T7 without touching anything else.
3. **Single workspace window** — recommended and planned. Drag-out to a second window is a
   clean v2 (TabsModel-per-window is already the shape); doing it now would double T1/T6.
4. **Close Window shortcut** — ⌥⌘W (⇧⌘W belongs to Save As conventions here). Trivial to change.
5. **Colour semantics** — green added / amber modified / red removed (the user's "yellow" reading
   maps to amber). A "deleted-row marker in the gutter" is deferred; deletions are chip/panel-only.

## 5. Explicitly out of scope (deliberate)

Native `NSWindow` tabbing; multi-window workspaces; **tab drag-reorder** (v1.1 — T4's strip is
static-order to cut risk; note it in the component doc, `SheetTabBar`'s `.draggable` pattern is
the template when it comes); tab pinning; rollback/revert-to-baseline actions (snapshots already
cover restore; a "revert cell to baseline" context action is a natural v1.1); MCP tools for
tabs/checkpoints (`open_file`, `set_checkpoint` over MCP — v1.1, needs the half-wired app
handshake finished first, see recon: `SheetMCP/Documents/AppHandshake.swift:104` publish is
uncalled today); diff between two arbitrary snapshots; the `autoSaveEnabled` dead toggle and
the handshake gap (both pre-existing; flagged to the user separately).
