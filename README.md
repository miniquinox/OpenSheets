# OpenSheets

A native macOS spreadsheet that opens `.xlsx` and `.csv`, renders them in real Liquid Glass, and
treats **Claude Code as a first-class co-editor of the file on disk**.

The loop: you open a file → Claude Code edits it in your terminal → OpenSheets notices, shows you
*exactly what changed*, and lets you accept it. No Microsoft account, no plugin store, no cloud.
The file is the API.

**Status: v0.1, pre-release.** The app opens and renders `.xlsx` and `.csv`, watches the file for
external changes, and edits through a 25-tool MCP server — including creating a workbook from
scratch, trashing one recoverably, and opening a file in the app from a terminal. The package
builds and its 1,862 tests pass. Several release gates are genuinely open — notably that nothing
we write has ever been opened in Microsoft Excel, and that the Settings ▸ Claude pane has never
been driven on a screen. See
[DOCUMENTATION.md §12](DOCUMENTATION.md#12-known-limitations-and-what-is-not-done) for the full,
honest list.

**Cloud Share is built but dark.** The relay is deployed and answering, and the whole app-side
stack — token, wire protocol, device identity, relay client, subprocess bridge, engine and service —
is written and tested. The Settings ▸ Cloud pane that drives it is built but has **never been opened
on a screen**, and `OSFlagCloudShare` defaults off. [docs/cloud-share.md](docs/cloud-share.md) is
the guide and states what is not verified.

**Full documentation: [DOCUMENTATION.md](DOCUMENTATION.md).**

**Requires** macOS 26.0 (Tahoe) · Xcode 26.6 · Swift 6.3

---

## What this is and is not

| We build | We deliberately don't |
| --- | --- |
| Fast, native rendering of xlsx/csv | Pivot table *authoring* |
| Editing cells, formulas, formats | Charting engine, drawing tools |
| 203 functions, including dynamic arrays | All 500+ Excel functions |
| File-watch → diff → refresh loop | Real-time multi-user collaboration |
| MCP server so Claude edits *structurally* | VBA / macro execution (never) |
| Connect to Claude from Settings — the server ships in the app, registration is one click, no terminal | An agent that edits Claude's own config — `~/.claude.json` stays on the deny list |
| Agents discover the Files panel — the folders you pinned, the tabs you have open — instead of asking you to paste a path | Link expiry dates, per-recipient folder scoping, or accounts — a share link is revocable, not fine-grained |
| **Cloud Share** — an opt-in, revocable relay that routes bytes and grants nothing, so a browser-based assistant can reach the folders you granted ([docs/cloud-share.md](docs/cloud-share.md)) | End-to-end encryption to that assistant — the relay terminates TLS, and we say so rather than implying otherwise |
| Byte-preserving round-trip of parts we don't model | Reimplementing OOXML in full |

The bet: **visualisation and sync fidelity are the product.** Depth comes from Claude.

Read [`PLAN.md`](PLAN.md) for the architecture and the reasoning behind it.

---

## Layout

```
App/                              OpenSheets.app — thin on purpose, 10 Swift files
Config/                           Info.plist, entitlements
Packages/OpenSheetsCore/          ~95% of the code lives here
  Sources/
    SheetModel/                   the frozen data model — everything else compiles against it
    MiniZip/                      ZIP read and write, hardened
    SheetFormat/                  xlsx and csv, read and write
    SheetFormula/                 lexer, parser, dependency graph, functions
    GridKit/                      virtualised AppKit grid renderer
    GlassUI/                      design tokens and every glass surface
    SheetStore/                   file watcher, snapshots, workspace grants, directory listing, SQLite
    SheetMCP/                     the 25-tool MCP surface and the CLI
    SheetShare/                   Cloud Share: token, wire protocol, relay socket, subprocess bridge
    DocumentCore/                 the wiring layer: AppModel, DocumentModel, window rules
    TestSupport/                  builders, fakes, matchers
Relay/                            the Cloud Share relay — a Cloudflare Worker, TypeScript, its own toolchain
Fixtures/                         the golden corpus everything is tested against
Scripts/                          build, test, benchmark
docs/agents/                      one brief per agent, with scope and ownership
```

`Relay/` is the one directory that is not Swift. It is versioned here rather than in its own
repository because the wire contract is a single artifact implemented twice, and two repositories
would let the halves drift. It is never imported by the Swift package, and it does not touch the
"one SwiftPM dependency" rule.

**Every new source file goes in a SwiftPM target.** Adding a file there requires editing no
manifest, which is what keeps eleven people out of one `project.pbxproj`. See PLAN.md §2.1.

---

## Building

```bash
# The package: build, test, and lint the part that matters
Scripts/build.sh --package-only
Scripts/test.sh

# Everything, including the app
Scripts/build.sh
```

The full `Scripts/build.sh` also embeds the MCP server in the built app
(`OpenSheets.app/Contents/MacOS/opensheets-mcp`), which is what the **Connect** button in
Settings ▸ Claude registers — no `sudo cp`, no terminal step. See
[DOCUMENTATION.md §2.5](DOCUMENTATION.md#25-the-mcp-server-ships-inside-the-app) and
[§3.2](DOCUMENTATION.md#32-connect-the-server-to-claude).

Or directly:

```bash
cd Packages/OpenSheetsCore
swift build -Xswiftc -warnings-as-errors
swift test  -Xswiftc -warnings-as-errors

cd -
xcodebuild build -project OpenSheets.xcodeproj -scheme OpenSheets -destination 'platform=macOS'
```

Warnings are errors: pass `-Xswiftc -warnings-as-errors`, which `Scripts/build.sh` and
`Scripts/test.sh` already do. They are applied that way rather than in `Package.swift`,
because `unsafeFlags` in a manifest makes a package unusable as a dependency — and
`OpenSheets.xcodeproj` depends on this one by path.

### Useful test invocations

```bash
Scripts/test.sh --coverage              # per-target line coverage
Scripts/test.sh --release               # the configuration the performance budgets assume
Scripts/test.sh --sanitize thread       # PLAN.md §10.8
Scripts/test.sh --filter CellStore
```

### Formatting

```bash
swiftformat .        # brew install swiftformat
swiftlint lint       # brew install swiftlint
```

Both are pinned by config files in the repository root; run them in `--lint` / `--strict` mode
before you commit. The two tools are configured not to overlap: SwiftFormat owns layout,
SwiftLint owns judgement.

Note that the pinned versions are older than what Homebrew installs today, so a bare
`swiftformat --lint .` reports thousands of findings from rules the config does not enable —
grep its output for the files you touched. Never run bare `swiftformat .`; it rewrites the repo.

---

## Feature flags

Unfinished work ships dark rather than blocking a release (PLAN.md §11).

```bash
defaults write com.quino.opensheets OSFlagEditing        -bool YES
defaults write com.quino.opensheets OSFlagMCP            -bool YES
defaults write com.quino.opensheets OSFlagFormulaEngine  -bool YES
defaults write com.quino.opensheets OSFlagSnapshots      -bool YES
defaults write com.quino.opensheets OSFlagChangeTracking -bool NO   # defaults to YES
defaults write com.quino.opensheets OSFlagExplorer       -bool NO   # defaults to YES
defaults write com.quino.opensheets OSFlagHandshake      -bool NO   # defaults to YES
defaults write com.quino.opensheets OSFlagSheetStructure -bool YES
defaults write com.quino.opensheets OSFlagCloudShare     -bool YES  # defaults to NO
```

`OSFlagCloudShare` gates whether Cloud Share **exists**: off, `AppModel.share` is `nil`, so there is
no object to start and nothing to switch on. The owner's own switch is a second, separate default
(`OSCloudShareEnabled`, also off), which gates whether the service *connects*. Turning the flag on
today gets you the Settings ▸ Cloud pane, which nobody has yet seen drawn — see
[docs/cloud-share.md](docs/cloud-share.md).

`OSFlagChangeTracking` gates the whole green/amber/red story — the changes chip, its panel, the
grid tints and Set Checkpoint. Off, the app does none of the diffing either: the flag removes the
cost, not just the controls.

`OSFlagHandshake` is a kill switch rather than a rollout gate. It gates both halves of the app↔agent
handshake — publishing what you have open so `get_selection` can answer, and acting on `reveal_range`
requests — and it exists because the reveal consumer is the one thing in the app that acts on a file
written by **another process**. Everything downstream of that is grant-checked at the moment of
acting, so the switch is not load-bearing for safety; it is there so a bug on that path is one
`defaults write` away from being off.

File tabs are deliberately **not** flagged; they replace the window architecture rather than adding to
it, and a flag there would mean keeping two window models. **Auto-refresh has no flag either** — an
earlier revision of this list included an `OSFlagAutoRefresh`, and no code has ever read that key.
It is a per-document option that defaults to on. See
[DOCUMENTATION.md §2.6](DOCUMENTATION.md#26-feature-flags) for the authoritative table.

---

## Security posture

- **Not sandboxed**, Developer ID signed and notarised, hardened runtime. A sandboxed app cannot
  fulfil "let Claude Code touch the file we're looking at" without fighting bookmarks at every
  turn, and this is not a Mac App Store product (PLAN.md §7.1).
- The real boundary is **workspace grants**: the MCP server refuses any path that does not
  resolve inside a folder you explicitly granted in the app, with a deny-list that overrides
  every grant. No argument and no file content can widen a grant (PLAN.md §7.2).
- **A cell is data, never an instruction.** Nothing is executed, no external link is ever
  auto-fetched, and MCP tool output wraps cell text in an explicit untrusted-content envelope
  (PLAN.md §7.3).
- A hostile `.xlsx` is a real attack surface, so the parser caps decompressed bytes, compression
  ratio, entry count, XML depth, and sheet dimensions — and rejects external entities outright
  (PLAN.md §7.4).
- **Cloud Share does not move that boundary.** A share link reaches your Mac through a relay that
  stores token hashes and routes bytes; the grant check, the deny-list and the untrusted-content
  envelope all still run in a local subprocess that cannot mint a grant. What we cannot promise, we
  state: the relay terminates TLS, so content transits it in plaintext per hop, and anyone holding
  an active link can read every workbook in every folder you granted
  ([docs/cloud-share.md](docs/cloud-share.md)).

---

## Contributing

Read [PLAN.md §13.1](PLAN.md) first. The short version:

1. **Own your files. Touch nothing else.** Each brief in [`docs/agents/`](docs/agents/) lists
   exact paths.
2. **`SheetModel` is frozen.** Need a change? Write it in
   [`docs/agents/MODEL-CHANGE-REQUESTS.md`](docs/agents/MODEL-CHANGE-REQUESTS.md) and work around
   it. A unilateral change breaks six other people's builds.
3. **Never touch `OpenSheets.xcodeproj/project.pbxproj`.** Everything goes in a SwiftPM target.
4. **Ship it green.** `swift build && swift test` must pass. No `TODO` in place of an
   implementation — an honest `throw SheetError.notImplemented(…)` is fine, a silent wrong answer
   is not.
5. **Write doc comments that say *why*.** Explain the constraint; be honest about what does not
   work.

---

## Licence

MIT. See [LICENSE](LICENSE).
