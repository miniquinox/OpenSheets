# One-click "Connect to Claude" — no terminal anywhere in the flow

**Goal.** A non-technical user opens OpenSheets ▸ Settings (⌘,), sees a **Claude** section with one row
per installed Claude client, and clicks **Connect**. The app registers its own bundled `opensheets-mcp`
binary in that client's config file, shows "Connected", and offers **Disconnect** to undo it. No
`swift build`, no `sudo cp`, no `claude mcp add`, no terminal.

**What exists today (recon-verified).** The app *reads* `~/.claude.json` to report registration
(`AppModel.refreshMCPStatus()`, `Packages/OpenSheetsCore/Sources/DocumentCore/AppModel.swift:502-515`)
and shows the result in the sidebar's Claude panel. Registration itself is a pasteboard string the
user is told to paste into a shell (`AppModel.mcpSetupCommand`, `AppModel.swift:518`; copy action at
`App/SidebarColumn.swift:207-209`). The MCP binary is **not** in the app bundle — users build it from
source and `sudo cp` it to `/usr/local/bin` (`DOCUMENTATION.md` §2.5). This feature replaces both
halves.

---

## Existing patterns to reuse (recon findings, all verified with file:line)

### Status machinery
- `MCPStatus` enum: `Sources/GlassUI/Chrome/Sidebar.swift:11` — `.connected / .idle / .notConfigured / .failing(String)`. **`.connected` and `.failing` are dead in production** — `refreshMCPStatus` only ever produces `.idle`/`.notConfigured`. Free real estate.
- `AppModel.mcpStatus` (`AppModel.swift:69`, `private(set)`, `@Observable`); sole UI consumer is `ClaudePanel` (`Sidebar.swift:460-608`; status row `:530-561`; the copy-command button gated on `.notConfigured` at `:568`). Sole `refreshMCPStatus()` call site: `App/DocumentWindow.swift:101` (`.onAppear`).
- `mentionsOpenSheets(_:)` (`AppModel.swift:520-533`) is a whole-document case-insensitive substring search — it false-positives on any `~/.claude.json` that merely records an OpenSheets *project path*. It must be replaced by targeted parsing, not extended.

### Settings pane
- `PreferencesView`: `App/LauncherScene.swift:179-213`. Stock SwiftUI `Form`/`.grouped`, `.frame(width: 460)`. `Section("Claude")` at `:202-207` = `Toggle("Show MCP status", isOn: $mcp)` (`@AppStorage("OSFlagMCP")`) + `LabeledContent("Granted folders", …)`.
- Rendered by the `Settings` scene at `App/OpenSheetsApp.swift:86-89` — **with a hardcoded `.light` appearance context** (`:88`), unlike `RootView` which follows `colorScheme` (`:197`). Fix in passing.
- Adjacent shipped lie: the grant alert says "revoke … in Settings ▸ Workspace" (`App/OpenSheetsApp.swift:716`) — no such section exists; revocation lives in the explorer context menu (`App/LauncherScene.swift:124`). Fix the string in passing.

### Config files — external facts (verified against current docs, Aug 2026)
- **Claude Code, user scope** = top-level `mcpServers` in `~/.claude.json`:
  `{"mcpServers": {"opensheets": {"type": "stdio", "command": "<abs path>", "args": [], "env": {}}}`.
  Default-scope (`claude mcp add` without `--scope`) entries nest under `projects.<cwd>.mcpServers` **in the same file**; precedence local > project > user. The file also holds unrelated machine-managed state (history, OAuth, onboarding) and can be multi-megabyte.
- **Claude Desktop** = `~/Library/Application Support/Claude/claude_desktop_config.json`, flat
  `{"mcpServers": {"opensheets": {"command": "<abs path>", "args": []}}}`. Desktop reads it at launch — a restart note is owed after connect.
- **`.mcpb`** bundles exist (zip + manifest, double-click install into Claude Desktop) — deferred, see OPEN-1.

### Writing the file safely
- `AtomicWriter` (`Sources/SheetStore/AtomicWriter.swift:98-143`): temp sibling → `F_FULLFSYNC` → dir fsync → `replaceItemAt`; **preserves the original's POSIX mode and xattrs** (`:36-38`, `:112`); writes through symlinks (`:33-35`); `Options.refusesEmptyOverwrite` default true (`:47`); typed `SheetError` throws. `DocumentCore` links `SheetStore` — usable directly. (Its `backupItemName` hook deletes the backup on success — for a durable backup, copy a sibling explicitly before writing.)
- `JSONValue.rendered` **alphabetises keys and emits one compact line** (`Sources/SheetMCP/JSONRPC/JSONValue.swift:110-118`, rationale `:81-84`) — wrong tool for a user's multi-megabyte config. `JSONSerialization` is the read pattern already used on this exact file (`AppModel.swift:509`) and preserves integers-as-integers and booleans on round-trip. **Decision D1 below.**
- Fault-injection harness: `Sources/TestSupport/FailingFileSystem.swift:105-115, :438-455`.

### The policy line this feature must draw
`~/.claude.json` is on the MCP server's deny list (`Sources/SheetStore/WorkspaceGrants.swift:38`) and
three places state the app never writes it: `AppModel.swift:496-501` ("The file is read, never
written"), `DOCUMENTATION.md:317-323` ("not something an agent should do unasked"),
`DOCUMENTATION.md:2317-2320` ("registration is a user action, not an agent action"). The deny list is
enforced on the **server's** path arguments, not on the app — so the feature is mechanically clean, but
it inverts a stated narrative. The line to write down everywhere: **the deny list keeps the *agent*
out of Claude's config; a human clicking a labelled button in Settings is precisely the "user action"
the docs demanded.** The deny list itself does not change, and the three tests asserting it
(`WorkspaceGrantsTests.swift:116`, `GrantEscapeTests.swift:122`, `ShippedBinaryTests.swift:288`) must
keep passing untouched.

### Bundling constraints
- **`project.pbxproj` may not be edited** (house rule, `Package.swift:4-8`, `DOCUMENTATION.md` §13). The project has **no** CopyFiles/ShellScript/Embed phase (pbxproj:65-69, zero matches) and xcodebuild builds only the `OpenSheetsCore` library product — never the executables (pbxproj:78-80, 290-293).
- The executables **are already built** by `Scripts/build.sh:25-29` (bare `swift build`, all products) into `Packages/OpenSheetsCore/.build/<config>/`, before xcodebuild runs. The .app lands in unpinned DerivedData (`DOCUMENTATION.md:170-171`); `build.sh` ends at line 57 with no post-step. **The sanctioned bundling point is a new copy step in `build.sh` after xcodebuild**, resolving the product dir via `xcodebuild -showBuildSettings`.
- Runtime lookup: `Bundle.main.url(forAuxiliaryExecutable:)` resolves against `Contents/MacOS/` — the app has never used it (only `Bundle.main` use is `OpenSheetsApp.swift:485`).
- The app never spawns subprocesses, deliberately (`AppModel.swift:496-501`): Claude is the server's parent. **Nothing in this feature spawns the binary either** — connect = write config; verify = stat the binary, never run it.

### Conventions every agent must follow (no CLAUDE.md exists; from DOCUMENTATION.md §13, PLAN.md §13.1)
1. New source files go in `Packages/OpenSheetsCore`; **never touch `OpenSheets.xcodeproj/project.pbxproj`**; App-layer files may be edited but not added.
2. Swift 6.3, language mode v6, `ExistentialAny`, macOS 26. `cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors`. Zero warnings; no TODO placeholders.
3. Swift Testing (`@Test`/`@Suite`); suites named as sentences; tests named as the claim they make.
4. Typed `SheetError` with stable dotted codes; **`SheetModel` is interface-frozen — do not edit it**; reuse existing cases (`.fileNotWritable(path:underlying:)` — used by `AppHandshake.swift:127-145` — and `.atomicReplaceFailed`); a genuinely-needed new case goes to `docs/agents/MODEL-CHANGE-REQUESTS.md` instead of an edit. Never `fatalError`, never `NSError`, no force-unwrap/cast/try.
5. GlassUI lint (14 tests, `Tests/GlassUITests/GlassLintTests.swift`): the spacing rule scans **all of `App/`** (`:331`, via `GlassSource.layoutFiles()`) — no numeric literal in `.padding(…)`/`spacing:` (0 legal; use `DS.Space.*`/named constants). Components in `Sources/GlassUI/` additionally: no global state — value in, actions out via closure (`:282`); buttons inside glass are `.bordered`/`.borderedProminent`/`.plain`, never `.glass` (`:130`); colour literals only in `Tokens/` (`:182`); springs only (`DS.Motion`); ≥2 glass elements need `GlassCluster`.
6. Failure is a state, not an alert (`OpenSheetsApp.swift:171`); alerts only for decisions (`:707-731`). Inline-rejection precedent: `App/LauncherScene.swift:138-149` + `LauncherWindow.swift:63-65`.
7. Flags: read via `DocumentCore.Flags` (`AppModel.swift:552-600`), written via `@AppStorage`; a new flag must join `Flags.summary` (`App/Flags.swift:18-27`). **This feature adds no flag** — a button is not an automation (D7).
8. Testability: `homeDirectoryForCurrentUser` is not `HOME`-redirectable in-process (`ShippedBinaryTests.swift:56-71` explains `CFFIXED_USER_HOME`); config paths must be **injected**, following the `handshakeDirectory` / `SheetStore.Configuration(applicationSupport:)` seam (`AppModel.swift:388-400`, `SheetStore.swift:24-42`).

---

## Locked design

### Decisions

- **D1 · File format.** Read-modify-write with `JSONSerialization` (`.jsonObject` → mutate `[String: Any]` → `.data(withJSONObject:options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])`), written through `AtomicWriter` (mode-preserving, fsync'd, `refusesEmptyOverwrite`). Content is fully preserved (unknown keys, integers, booleans); *formatting* is normalised (keys sorted, 2-space indent) — accepted, because Claude Code machine-manages this file and rewrites it constantly. Before **every** write, copy the current file to a sibling `<name>.opensheets-backup` (overwriting the previous backup); surface that path in the UI caption. **If the existing file does not parse, refuse to write and say so** — never clobber a file we could not read. `JSONValue` is not used here (it compacts to one line and its own docs call that a hazard for this file).
- **D2 · Consent.** The labelled button *is* the consent — no second alert. The row's caption states exactly what will happen before the click ("Adds an `opensheets` entry to `~/.claude.json`. A backup is kept beside it."). This is the "user action, not agent action" the docs demand; the deny list (agent-side) is untouched.
- **D3 · What connect writes.** Always the **user scope** / global entry (top-level `mcpServers` for Claude Code; the flat object for Desktop), name `opensheets`, `command` = absolute resolved binary path, `args: []`; Claude Code entry also gets `"type": "stdio"` and `"env": {}` for parity with `claude mcp add`. Connect is idempotent — rewriting an existing entry is a no-op-shaped update, never a duplicate.
- **D4 · What disconnect removes.** The `opensheets` key from top-level `mcpServers` **and** from every `projects.<path>.mcpServers` in `~/.claude.json` (leftovers from old manual `claude mcp add` runs make Disconnect a lie otherwise); for Desktop, the `opensheets` key. Nothing else is touched; empty containers left behind are fine.
- **D5 · Binary resolution order.** (1) `Bundle.main.url(forAuxiliaryExecutable: "opensheets-mcp")` if it exists and is executable; (2) `/usr/local/bin/opensheets-mcp` if it exists (the documented manual install); (3) none → Connect disabled with "The server binary is missing from this build" caption. The bundled path always wins when present. Verification is `stat` + executable bit — the app never runs the binary.
- **D6 · Client detection.** Claude Code = `~/.claude.json` exists (the client has run at least once); absent → row reads "Not installed — get it at claude.com/code", Connect disabled (we do not create the file for a client that has never run). Claude Desktop = `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` for the Desktop bundle id **or** existence of `~/Library/Application Support/Claude/`; the config file itself may not exist yet — connect creates it (and the directory) with just the `mcpServers` object.
- **D7 · No new feature flag.** The kill-switch rationale (`AppModel.swift:576-589`) covers autonomous behaviour; a button that does nothing until clicked needs none. `OSFlagMCP` keeps its exact current meaning (gates the *sidebar readout* only, `AppModel.swift:503`); the Settings pane reads true state regardless of it.
- **D8 · Status vocabulary.** New per-client state in DocumentCore (see Backend); the sidebar's `MCPStatus` maps from the Claude Code client only, as today, but now honestly: registered-and-binary-present → `.idle`; registered-but-binary-missing → `.failing("the registered server binary is missing — reconnect in Settings")`; otherwise `.notConfigured`. The dead `.connected` case stays dead (truthfully claiming a live connection needs the server to talk to us, which is the handshake's job, not this feature's).

### User flow (happy path)

1. User opens **OpenSheets ▸ Settings** (⌘,) → **Claude** section.
2. They see: a **server row** ("Server · bundled with this app" + the resolved path, middle-truncated), then one row per client — **Claude Code** and **Claude Desktop** — each with a status dot, a status word, a one-line caption, and a `Connect` (or `Disconnect`) button. Clients that aren't installed show "Not installed" with a disabled button and a pointer.
3. Click **Connect** on Claude Code → the app backs up `~/.claude.json` to `~/.claude.json.opensheets-backup`, splices the entry, atomically replaces the file, re-reads status → row flips to "Connected", caption now "Registered at <path>. New Claude Code sessions will see it." The sidebar's Claude panel updates live (same `@Observable` model).
4. Click **Connect** on Claude Desktop → same, plus the caption "Restart Claude Desktop to pick it up."
5. **Disconnect** reverses it (D4), with the same backup-first behaviour.
6. **Empty state**: no client installed → both rows disabled with pointers; the section still renders.
   **Loading**: reads are synchronous small-file I/O — no spinner; refresh happens on pane appear and after every write.
   **Error state**: any thrown `SheetError` lands in an inline red-tinted caption under the row (launcher `rejection` pattern, `LauncherScene.swift:138-149`) — e.g. "Your `~/.claude.json` could not be parsed, so it was not modified." Never an alert, never a silent failure.
7. Stale state: the app was moved/rebuilt so the registered `command` no longer exists → row shows "Connected, but the registered binary is missing" with the button relabelled **Reconnect** (same write path).

### Backend (DocumentCore — there is no server; "backend" = the connector)

New file `Packages/OpenSheetsCore/Sources/DocumentCore/ClaudeConnector.swift`:

```swift
/// Which Claude client a row talks about.
public enum ClaudeClient: String, CaseIterable, Sendable { case claudeCode, claudeDesktop }

/// One client's observed relationship to our server. Derived, never stored.
public enum ClaudeConnection: Sendable, Equatable {
    case notInstalled                      // client absent (D6)
    case notConnected                      // client present, no opensheets entry
    case connected(command: String)        // entry present, binary exists+executable
    case stale(command: String)            // entry present, binary missing → Reconnect
    case unreadable(reason: String)        // config exists but does not parse → writes refused
}

/// Injectable paths — the test seam (convention 8).
public struct ClaudeConnectorPaths: Sendable {
    public var claudeCodeConfig: URL       // ~/.claude.json
    public var desktopConfig: URL          // ~/Library/Application Support/Claude/claude_desktop_config.json
    public var desktopSupportDirectory: URL
    public var desktopBundleIdentifier: String
    public var fallbackBinary: URL         // /usr/local/bin/opensheets-mcp
    public static func standard() -> ClaudeConnectorPaths
}

@MainActor @Observable public final class ClaudeConnector {
    public init(paths: ClaudeConnectorPaths = .standard(), bundledBinary: URL?)
    public private(set) var connections: [ClaudeClient: ClaudeConnection]
    public var serverBinary: URL?          // resolution D5; nil = Connect disabled
    public func refresh()
    public func connect(_ client: ClaudeClient) throws(SheetError)     // D1–D3
    public func disconnect(_ client: ClaudeClient) throws(SheetError)  // D4
    public static let serverName = "opensheets"
}
```

Side effects and idempotency: `connect`/`disconnect` are read-modify-write on one file each, idempotent, backup-first, atomic (D1), and end with `refresh()`. All failures are thrown `SheetError`s (reuse `.fileNotWritable(path:underlying:)` for every write-path refusal including the parse-refusal — the message carries the true reason; `.atomicReplaceFailed` propagates from `AtomicWriter`). No new `SheetError` case; if an implementer disagrees, the house route is a note in `docs/agents/MODEL-CHANGE-REQUESTS.md`, not an edit.

`AppModel` changes (same agent): own `public let claude: ClaudeConnector` (constructed with `Bundle.main.url(forAuxiliaryExecutable: "opensheets-mcp")` — resolved in App layer? No: `Bundle.main` is fine from DocumentCore, it is the app process's bundle; construct in `AppModel.init`); `refreshMCPStatus()` delegates to `claude.refresh()` and maps per D8 (still honouring `Flags.mcpEnabled` for the sidebar readout); **delete `mentionsOpenSheets`** (replaced by targeted parsing); `mcpSetupCommand` becomes a computed `static var` that uses the resolved absolute path when available, falling back to today's string — the sidebar copy button (`SidebarColumn.swift:207`) keeps compiling unchanged. Rewrite the stale doc comment at `AppModel.swift:496-501` to state the new line (D2): read for status; written only by the user's explicit Settings action; the agent-side deny list unchanged.

### Frontend

**GlassUI** — new file `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/ClaudeClientRow.swift`:
- `ClaudeClientRowModel` (value type): `clientName: String`, `status: Status` (mirror of `ClaudeConnection`, GlassUI-local so GlassUI keeps zero DocumentCore imports), `caption: String`, `buttonLabel: String?` (`nil` = no button), `rejection: String?`.
- `ClaudeClientRow(model:perform:)` — `AgentDot` for the status dot (colour via `DS.Signal` helpers per `Sidebar.swift:554-561` precedent), status word + caption in a `VStack(spacing: DS.Space.xs)`, `.bordered` button trailing (lint rule — never `.glass` here), `rejection` rendered below in the launcher's inline style. No global state; value in, closure out (lint `:282`).
- Also owns the one string change in `Sources/GlassUI/Chrome/Sidebar.swift:96-103`: `.notConfigured` `statusDetail` becomes "Connect in Settings ▸ Claude (⌘,)." (the copy-command button stays as the power-user fallback).
- Tests in `Tests/GlassUITests/ComponentModelTests.swift` style: every `Status` yields a non-empty caption; the existing `mcpStatusExplainsItself` (`:233-246`) keeps passing with the new string.

**App layer** (edits only, no new files): `PreferencesView` in `App/LauncherScene.swift:179-213` — `Section("Claude")` becomes: server `DetailRow` (path, middle-truncated — `Atoms.swift:385`), two `ClaudeClientRow`s driven by `app.claude.connections` with `perform:` closures calling `connect`/`disconnect` and catching into a per-row `@State` rejection string, the kept `LabeledContent("Granted folders", …)`, and the kept `Toggle("Show MCP status", isOn: $mcp)`. `.onAppear { app?.claude.refresh(); app?.refreshMCPStatus() }`. Also: fix the Settings appearance to follow `colorScheme` instead of hardcoded `.light` (`OpenSheetsApp.swift:86-89` — move the `glassAppearance` decision inside `PreferencesView` where `@Environment(\.colorScheme)` is available); fix the "Settings ▸ Workspace" alert lie (`OpenSheetsApp.swift:716` → "…at any time from the folder's menu in the Files sidebar."). Spacing lint applies to all of it (convention 5).

### Bundling (build system)

`Scripts/build.sh`, after the xcodebuild block (`:41-55`), non-`--package-only` path only:

1. Resolve the app: `xcodebuild -project OpenSheets.xcodeproj -scheme OpenSheets -configuration "$XCODE_CONFIGURATION" -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk` out `TARGET_BUILD_DIR` and `FULL_PRODUCT_NAME`.
2. `cp "$ROOT/Packages/OpenSheetsCore/.build/$CONFIGURATION/opensheets-mcp" "<app>/Contents/MacOS/"` — the binary is guaranteed to exist because `build.sh:25-29` already built every product. **Fail loudly** (`exit 1` with a message) if either the binary or the app is missing — a silent skip would ship a Settings pane whose Connect button can never enable.
3. `echo` the destination so the build log shows where it landed.

No pbxproj change, no scheme change. Known consequence, documented rather than solved: a dev build's registered path points into DerivedData and goes stale on clean — the `stale` state + Reconnect button is the designed recovery. Future Developer-ID signing must sign the embedded helper too; no signing pipeline exists in-repo today (recon: `build.sh:49` `CODE_SIGNING_ALLOWED=NO`, no notarisation scripts anywhere), so this is a doc note, not work.

### Database
None. No schema, no migration. The only persistent artifacts are the two client config files (owned by Claude) and their `.opensheets-backup` siblings.

### Permissions
- The app is unsandboxed (`Config/OpenSheets.entitlements`); OS-level writes to `~` succeed. The **server's** deny list (`WorkspaceGrants.swift:38`) is untouched — the agent still cannot read or write `~/.claude.json`; its three asserting tests must pass unmodified.
- Writes happen only from the two connector methods, only on a user's button click. No background path calls them (enforced by review: `connect`/`disconnect` call sites must exist only in `PreferencesView`).

### Validation
| Input | Rule | Where | Failure message (inline, per row) |
| --- | --- | --- | --- |
| Existing config bytes | must parse as a JSON object | connector, before any mutation | "Your `<file>` could not be parsed, so it was not modified." |
| `mcpServers` value | if present, must be an object | connector | same as above (treated as unparseable) |
| Server binary | exists + executable bit | connector (`serverBinary`, and re-checked in `connect`) | "The server binary is missing from this build." (button disabled) |
| Write result | non-empty, atomic replace succeeded | `AtomicWriter` (`refusesEmptyOverwrite`) | the thrown `SheetError.errorDescription` |

### Edge cases (each becomes a test)
- **Connect twice** → byte-stable second write (idempotent), no duplicate keys.
- **Config with unrelated keys** (history, OAuth, `projects`) → all preserved verbatim in content; only formatting normalised; asserted against a golden file.
- **Integers and booleans** survive the round-trip as `1`/`true`, never `1.0`/`0`.
- **Unparseable config** → throws, file byte-identical afterwards, backup not created.
- **Empty existing file** (0 bytes) → treated as absent for Claude Code detection... no: `~/.claude.json` exists ⇒ client installed; empty ⇒ unparseable ⇒ refuse with the parse message. Honest and safe.
- **Disconnect with project-scope leftovers** → removes `opensheets` from every `projects.*.mcpServers` and top level; everything else untouched.
- **Disconnect when not connected** → no-op, no error, no write.
- **Desktop installed, config missing** → connect creates directory + file with only `mcpServers`.
- **Binary vanished after registration** (moved app, cleaned DerivedData) → `stale`, Reconnect re-writes with the newly resolved path.
- **Concurrent write by Claude Code** while we replace → atomic rename means last-writer-wins on the whole file; accepted (the write is a rare, user-initiated, sub-millisecond splice); documented in the connector's doc comment.
- **Read-only home / permissions failure** → thrown `SheetError.fileNotWritable`, inline rejection, file untouched.
- **Both bundled and `/usr/local/bin` binaries exist** → bundled wins (D5), asserted.

### Tests
- `Tests/DocumentCoreTests/ClaudeConnectorTests.swift` — all connector behaviour above, against temp-dir `ClaudeConnectorPaths` (convention 8); golden `~/.claude.json` fixture with junk keys + a `projects` section lives inline in the test file as a string. Failure injection for the atomic path via `AtomicWriter.Options.observer` if exposed, else `FailingFileSystem`.
- `Tests/GlassUITests/` — row-model captions non-empty per case; lint suite picks the new component up automatically.
- Existing suites that must pass unmodified: the three deny-list tests, `ComponentModelTests.mcpStatusExplainsItself`, the full 14-rule GlassUI lint.
- Commands: `cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors`; scoped `Scripts/test.sh --filter ClaudeConnector`; app build `Scripts/build.sh`. Known flakes to not chase: `CoreLoopTests` under parallel load, `CellStore performance` debug-lane budget (documented in §12.3).

### Rollout
Single release, no flag (D7), no migration. Ship order inside the branch: connector → UI → build.sh → docs. Verify by building (`Scripts/build.sh`), checking `Contents/MacOS/opensheets-mcp` exists in the built app, launching, connecting against a scratch `CFFIXED_USER_HOME` (integration agent does this headlessly at the connector level; a human clicks the real button — recorded as unverified in docs otherwise). Roll back = revert; a user who connected keeps a valid entry pointing at a still-existing binary, and Disconnect (or `claude mcp remove opensheets`) undoes it.

### Integrations
Claude Code (`~/.claude.json`) and Claude Desktop (`claude_desktop_config.json`) as above. No network, no env vars, no secrets. macOS only.

---

## OPEN decisions (proceeding on the recommendation)

- **OPEN-1 · `.mcpb` bundle for Claude Desktop**: skip. The binary already lives on disk inside our .app; an `.mcpb` would copy a second one into Desktop's extension store that diverges on every app update. Direct config write gives the same one-click outcome without the fork. Revisit only if Desktop deprecates direct config.
- **OPEN-2 · Disconnect scope**: also remove `opensheets` entries from `projects.*.mcpServers` (old manual registrations). Recommended yes — Disconnect must mean disconnected. (Flip one method if you disagree.)
- **OPEN-3 · Desktop bundle id**: recon found none in-repo; implementer must check the installed app (`osascript -e 'id of app "Claude"'` or `mdls`) and fall back to the support-directory check when the id lookup finds nothing. The paths type keeps it injectable either way.
- **OPEN-4 · Second confirmation alert before writing**: no (D2) — the labelled button plus an honest caption is the consent. Say so if you want the alert instead; it is one `NSAlert` at the `perform:` seam.

**Risk to weigh:** connect normalises the *formatting* of `~/.claude.json` (sorted keys, reindent) on first write. Content is preserved and a backup sibling is kept, but a user who diffs that file will see a large formatting diff once. The alternative (surgical text splice) was rejected as fragile against a file another program rewrites constantly.

---

## Agent tasks

### Agent 1 — The connector: detect, read, connect, disconnect
**Goal:** `ClaudeConnector` exists in DocumentCore with the exact API in "Backend", `AppModel` delegates its MCP status to it, and every edge case above is a passing test.
**Depends on:** none — can start immediately.
**Files to create:** `Packages/OpenSheetsCore/Sources/DocumentCore/ClaudeConnector.swift`, `Packages/OpenSheetsCore/Tests/DocumentCoreTests/ClaudeConnectorTests.swift`.
**Files to modify:** `Packages/OpenSheetsCore/Sources/DocumentCore/AppModel.swift` — only the MCP region (`:69`, `:496-533`, `:518`): add `public let claude: ClaudeConnector` constructed in `init` with `Bundle.main.url(forAuxiliaryExecutable: "opensheets-mcp")`; rework `refreshMCPStatus()` to delegate and map per D8 (keep the `Flags.mcpEnabled` gate exactly as-is at `:503`); delete `mentionsOpenSheets`; make `mcpSetupCommand` computed off the resolved path with today's string as fallback; rewrite the `:496-501` doc comment to the D2 line.
**Do NOT touch:** `Sources/SheetModel/` (frozen — reuse `.fileNotWritable`/`.atomicReplaceFailed`; a wish for a new case goes to `docs/agents/MODEL-CHANGE-REQUESTS.md`); `Sources/SheetStore/WorkspaceGrants.swift` (the deny list is deliberately unchanged); anything in `GlassUI` (Agent 2) or `App/` (Agent 3); `Scripts/` (Agent 3); docs (Agent 4).
**Context it needs:** everything under "Locked design → Backend", D1–D8, the edge-case list (each is an acceptance test); `AtomicWriter` API (`Sources/SheetStore/AtomicWriter.swift:41-83, :98-143`); the injectable-paths seam rationale (`AppModel.swift:388-400`, `ShippedBinaryTests.swift:56-62` — in-process tests cannot redirect `homeDirectoryForCurrentUser`, so `ClaudeConnectorPaths` is the only test seam); `JSONSerialization` read precedent (`AppModel.swift:507-513`); config schemas exactly as in "Config files — external facts"; `AppHandshake.swift:127-145` for the `SheetError.fileNotWritable` throw shape; conventions 1–4, 8.
**Implementation notes:** backup = `FileManager.copyItem` to `<name>.opensheets-backup` (remove stale backup first), before mutation, only when the target file exists and parses; write via `AtomicWriter().write(data, to: url, options: .init())` — mode preservation and `refusesEmptyOverwrite` are why it beats `Data.write(.atomic)` here. Desktop connect must `createDirectory(withIntermediateDirectories: true)` first. Detection per D6 (OPEN-3 for the bundle id — implement the support-directory fallback regardless). `connections` and `serverBinary` refresh together; all methods `@MainActor`; file I/O is small and synchronous — do not add async ceremony.
**Acceptance criteria:**
1. `swift build -Xswiftc -warnings-as-errors` and full `swift test -Xswiftc -warnings-as-errors` pass; the three deny-list tests pass unmodified.
2. `swift test --filter ClaudeConnector` runs a non-empty suite covering, at minimum: idempotent connect; golden-file content preservation (junk keys + `projects` intact, `1` stays `1`, `true` stays `true`); unparseable-config refusal with byte-identical file; backup sibling created before a successful write; disconnect removes top-level **and** project-scope entries and nothing else; disconnect-when-absent is a silent no-op; Desktop connect creates directory+file; stale detection when the registered command is missing; bundled-beats-fallback resolution.
3. `grep -n "mentionsOpenSheets" Packages/OpenSheetsCore/Sources` returns nothing.
4. `AppModel.mcpStatus` maps: no entry → `.notConfigured`; entry+binary → `.idle`; entry+missing binary → `.failing` (asserted via a temp-paths connector injected into the mapping, or by testing the mapping function directly).
**Verification commands:** `cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors` and `swift test -Xswiftc -warnings-as-errors --filter ClaudeConnector` (confirm the count is non-zero).

### Agent 2 — The GlassUI row
**Goal:** a lint-clean, reusable `ClaudeClientRow` component and the updated sidebar `statusDetail` string, with model tests.
**Depends on:** none — can start immediately (the `Status` mirror keeps GlassUI decoupled from Agent 1's types).
**Files to create:** `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/ClaudeClientRow.swift`.
**Files to modify:** `Packages/OpenSheetsCore/Sources/GlassUI/Chrome/Sidebar.swift` — only `ClaudePanelState.statusDetail` (`:96-103`): `.notConfigured` → "Connect in Settings ▸ Claude (⌘,)."; `Packages/OpenSheetsCore/Tests/GlassUITests/ComponentModelTests.swift` — extend with the new row-model assertions and update `mcpStatusExplainsItself` (`:233-246`) if it pins the old string.
**Do NOT touch:** `AppModel`/DocumentCore (Agent 1), `App/` (Agent 3), `Surfaces/GlassSurface.swift`, `Tokens/`.
**Context it needs:** "Locked design → Frontend → GlassUI"; the component contract rules (value in, `perform:` closure out — `GlassLintTests.swift:282`; `.bordered` buttons on glass — `:130`; DS tokens only — `:331`, `:182`); atoms to compose (`AgentDot` `Atoms.swift:15`, `DetailRow` `:385`, `SectionHeader` `:117`); dot-colour precedent `Sidebar.swift:554-561`; the exact `Status` cases mirroring `ClaudeConnection` in "Backend"; conventions 1–5.
**Implementation notes:** captions come from the model, not computed in the view, so the App layer (Agent 3) supplies wording; include a `rejection: String?` slot rendered in the launcher's inline style (`LauncherWindow.swift:226` precedent). Provide a `MockData`-style preview entry only if the Gallery pattern requires zero effort — otherwise skip.
**Acceptance criteria:**
1. Full `swift test -Xswiftc -warnings-as-errors` passes — including all 14 GlassUI lint tests, untouched.
2. The new component contains no `@EnvironmentObject`/`@StateObject`/`.shared.`, no `.glass` button style, no numeric literals in padding/spacing (grep-checkable).
3. `ComponentModelTests` asserts every `ClaudeClientRow` status yields a non-empty caption slot handling, and `mcpStatusExplainsItself` passes with the new `.notConfigured` string.
**Verification commands:** `cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors --filter 'GlassLint|ComponentModel'` then the full suite.

### Agent 3 — Settings pane, app wiring, and the bundle step
**Goal:** the Settings ▸ Claude section is the connect/disconnect UI described in the user flow; `Scripts/build.sh` embeds `opensheets-mcp` in the built app; the two adjacent shipped lies are fixed.
**Depends on:** Agents 1 and 2 (compiles against both APIs).
**Files to create:** none (house rule: no new App-layer files; the pane stays in `LauncherScene.swift`).
**Files to modify:** `App/LauncherScene.swift` — `PreferencesView` (`:179-213`) per "Frontend → App layer" (rows driven by `app.claude`, per-row `@State` rejection strings, `.onAppear` refresh); `App/OpenSheetsApp.swift` — the Settings scene appearance (`:86-89`, follow `colorScheme`) and the alert string (`:716`); `Scripts/build.sh` — the copy step per "Bundling", after `:55`, failing loudly.
**Do NOT touch:** `OpenSheets.xcodeproj/**` (hard house rule — the copy happens in `build.sh`, nowhere else); `Sources/**` (Agents 1–2 own the package); the `.xcscheme`; docs (Agent 4).
**Context it needs:** "Locked design → User flow", "Frontend → App layer", "Bundling"; Agent 1's `ClaudeConnector` API and Agent 2's `ClaudeClientRow` contract verbatim from this plan; the spacing-lint reach over `App/` (convention 5); the inline-rejection pattern (`LauncherScene.swift:138-149`); caption wording from the flow (backup mention, Desktop restart note, not-installed pointers); `xcodebuild -showBuildSettings` for `TARGET_BUILD_DIR`/`FULL_PRODUCT_NAME`; conventions 1–3, 5, 6.
**Implementation notes:** map `ClaudeConnection` → row model in a small private func in `PreferencesView` (wording lives here); `connect`/`disconnect` calls wrapped in `do/catch` setting the row's rejection to `error.errorDescription`; after either, call `app.claude.refresh()` and `app.refreshMCPStatus()` so the sidebar updates live. In `build.sh`, guard the copy on the xcodebuild path having run (mirror the existing `--package-only` early-exit structure) and use `"$CONFIGURATION"` (lowercase) for the SwiftPM product dir vs `"$XCODE_CONFIGURATION"` for the app — they differ (`build.sh:41-43`).
**Acceptance criteria:**
1. `Scripts/build.sh` completes and `test -x "<resolved app>/Contents/MacOS/opensheets-mcp"` succeeds (the script itself prints the path; the agent verifies with a follow-up `test`).
2. `Scripts/build.sh --package-only` still completes with no copy attempted.
3. Full `swift test -Xswiftc -warnings-as-errors` passes — the App-wide spacing lint included.
4. `grep -n "Settings ▸ Workspace" App/` returns nothing; `grep -n 'context(for: .light)' App/OpenSheetsApp.swift` returns nothing.
5. The pane compiles with rows for both clients, disabled-with-pointer when not installed (compile-level + model-mapping unit assertions where practical; pixel behaviour is honestly out of scope, recorded as such for Agent 4).
**Verification commands:** `Scripts/build.sh` then the `test -x` check; `Scripts/build.sh --package-only`; `cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors`.

### Agent 4 — Documentation truth pass
**Goal:** the docs describe the button as the primary path, the terminal as the fallback, the deny-list line as deliberately unchanged, and the formatting-normalisation trade-off honestly.
**Depends on:** Agents 1–3 (documents what landed — verify claims against the tree before writing).
**Files to modify:** `DOCUMENTATION.md`, `docs/mcp.md`, `README.md`. **Do NOT touch** any Swift file, `PLAN.md`, `Fixtures/README.md`.
**Context it needs:** the whole locked design; the doc-mention inventory (recon §1c above): `DOCUMENTATION.md:245` (OSFlagMCP row), `:307-323` (§3.2 + the Unverified note), `:686-687` (§5.1), `:1119` (§5.9 Desktop row), `:2317-2320` (§12.1 gate); `docs/mcp.md:58-78, :123, :428`; the house honesty voice (§3.4/§3.5 "Unverified" callouts).
**Implementation notes — the specific edits:** §2.5 — bundled binary is the default story; `sudo cp` demoted to "CLI on your PATH (optional)". §3.1-3.2 — rewrite Quick Start around Settings ▸ Claude ▸ Connect; keep the `claude mcp add` block as the manual alternative; update the Unverified note (registration is now app-performed on click — state exactly what has and has not been driven on a real screen, per Agent 3's report). §5.9 — Desktop row now "one click in Settings". §9.x — add the policy paragraph: deny list unchanged, user-action line (D2), backup behaviour, formatting normalisation. §12.1 — retire or reword the "`claude mcp add` has not been run" gate to today's truth. `AppModel.mcpSetupCommand` doc references and `docs/mcp.md` §1-2 updated to the bundled path. README — feature bullet ("Connect to Claude in Settings — no terminal"). Verify every number/command by running it; record anything unverified in the §3.4 callout style.
**Acceptance criteria:**
1. `grep -n "sudo cp" DOCUMENTATION.md docs/mcp.md` shows it only in the optional-CLI subsection.
2. The D2 policy paragraph exists and names the deny list as unchanged.
3. `swift test` passes and `git diff --stat` shows only the three markdown files.
**Verification commands:** `git diff --stat`; `cd Packages/OpenSheetsCore && swift test -Xswiftc -warnings-as-errors`.

### Agent 5 — Integration and final verification (final wave)
**Goal:** one green build of everything, the flow proven end to end at the connector level against scratch configs, every acceptance criterion re-checked, unmet items listed rather than declared away.
**Depends on:** Agents 1–4. **Files to modify:** only to fix integration breakage, reported explicitly.
**What it runs, literally:**
1. `cd Packages/OpenSheetsCore && swift build -Xswiftc -warnings-as-errors && swift test -Xswiftc -warnings-as-errors` (report count; known flakes: `CoreLoopTests`, `CellStore performance` — confirm in isolation, don't chase).
2. `Scripts/build.sh` → `test -x` the embedded binary inside the resolved .app; `Scripts/build.sh --package-only` still clean.
3. **Live connector round-trip** (in-process, temp `ClaudeConnectorPaths`): seed a realistic `~/.claude.json` (junk keys, a `projects` map with an old `opensheets` entry, an OAuth-shaped blob) → `connect(.claudeCode)` → assert entry + preservation + backup → point paths at a nonexistent binary → assert `stale` → `disconnect` → assert both scopes cleaned. Same for Desktop from an absent file.
4. Seam checks: `grep -rn "TODO\|FIXME"` over the new/modified files is empty; `grep -rn "mentionsOpenSheets" Packages/OpenSheetsCore/Sources` empty; deny-list tests untouched (`git diff --stat` on those three test files is empty); no call site of `connect(`/`disconnect(` outside `PreferencesView`.
5. `swiftformat --lint .` / `swiftlint lint --strict` — report honestly; installed versions drift from the pinned ones (0.62.1/0.65.1 vs 0.58.6/0.61.0), so judge only findings in files this feature touched, against the neighbouring house spelling.
6. Walk the Phase-2 user flow step by step at the model level; list what remains screen-unverified (clicking the real button in the real Settings window) for the docs' honesty note.
7. Pass/fail table over every agent's acceptance criteria.
**Verification commands:** as listed — they are the task.

---

## Execution graph

| Wave | Agents | Parallel-safe? | Why the boundary exists |
| --- | --- | --- | --- |
| 1 | **A1** connector (DocumentCore) · **A2** row (GlassUI) | Yes — disjoint modules, no shared files | A3 compiles against both APIs |
| 2 | **A3** Settings pane + build.sh | — | A4 documents A3's final behaviour (incl. what stayed screen-unverified) |
| 3 | **A4** docs | — | A5 verifies doc claims against reality |
| 4 | **A5** integration | — | always last |

No file is owned by two agents in any wave. `AppModel.swift` is A1-only; `LauncherScene.swift`/`OpenSheetsApp.swift`/`build.sh` are A3-only; `Sidebar.swift`/`ComponentModelTests.swift` are A2-only. Critical path: A1/A2 → A3 → A4 → A5 (4 waves).

## Deliberately out of scope
- `.mcpb` packaging (OPEN-1) and any other client (Cursor, etc.) — the connector's injectable-paths shape leaves the door open.
- Signing/notarisation pipeline for the embedded helper — no distribution pipeline exists in-repo at all (recon-confirmed); noted in docs.
- Driving the Settings UI on a real screen — model-tested per house practice; recorded as unverified.
- Any change to the deny list, the grant model, or `TerminalLauncher` (the "open terminal with `claude` typed" affordance stays as-is).
