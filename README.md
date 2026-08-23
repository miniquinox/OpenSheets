# OpenSheets

A native macOS spreadsheet that opens `.xlsx` and `.csv`, renders them in real Liquid Glass, and
treats **Claude Code as a first-class co-editor of the file on disk**.

The loop: you open a file → Claude Code edits it in your terminal → OpenSheets notices, shows you
*exactly what changed*, and lets you accept it. No Microsoft account, no plugin store, no cloud.
The file is the API.

**Status: v0.1 in development.** Wave 0 (the data model and scaffold) is done; the reader, writer,
formula engine, renderer, design system, and sync engine are being built in parallel. Nothing here
opens a spreadsheet yet.

**Requires** macOS 26.0 (Tahoe) · Xcode 26.6 · Swift 6.3

---

## What this is and is not

| We build | We deliberately don't |
| --- | --- |
| Fast, native rendering of xlsx/csv | Pivot table *authoring* |
| Editing cells, formulas, formats | Charting engine, drawing tools |
| ~120 common functions | All 500+ Excel functions |
| File-watch → diff → refresh loop | Real-time multi-user collaboration |
| MCP server so Claude edits *structurally* | VBA / macro execution (never) |
| Byte-preserving round-trip of parts we don't model | Reimplementing OOXML in full |

The bet: **visualisation and sync fidelity are the product.** Depth comes from Claude.

Read [`PLAN.md`](PLAN.md) for the architecture and the reasoning behind it.

---

## Layout

```
App/                              OpenSheets.app — thin on purpose, ~12 files
Config/                           Info.plist, entitlements
Packages/OpenSheetsCore/          ~95% of the code lives here
  Sources/
    SheetModel/                   the frozen data model — everything else compiles against it
    MiniZip/                      ZIP read and write, hardened
    SheetFormat/                  xlsx and csv, read and write
    SheetFormula/                 lexer, parser, dependency graph, functions
    GridKit/                      virtualised AppKit grid renderer
    GlassUI/                      design tokens and every glass surface
    SheetStore/                   file watcher, snapshots, workspace grants, SQLite
    SheetMCP/                     the MCP tool surface
    TestSupport/                  builders, fakes, matchers
Fixtures/                         the golden corpus everything is tested against
Scripts/                          build, test, benchmark
docs/agents/                      one brief per agent, with scope and ownership
```

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

Or directly:

```bash
cd Packages/OpenSheetsCore
swift build -Xswiftc -warnings-as-errors
swift test  -Xswiftc -warnings-as-errors

cd -
xcodebuild build -project OpenSheets.xcodeproj -scheme OpenSheets -destination 'platform=macOS'
```

Warnings are errors in CI. They are applied with `-Xswiftc` rather than in `Package.swift`,
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

Both are pinned by config files in the repository root, and CI runs them in `--lint` /
`--strict` mode. The two tools are configured not to overlap: SwiftFormat owns layout,
SwiftLint owns judgement.

---

## Feature flags

Unfinished work ships dark rather than blocking a release (PLAN.md §11).

```bash
defaults write com.quino.opensheets OSFlagEditing        -bool YES
defaults write com.quino.opensheets OSFlagMCP            -bool YES
defaults write com.quino.opensheets OSFlagFormulaEngine  -bool YES
defaults write com.quino.opensheets OSFlagSnapshots      -bool YES
defaults write com.quino.opensheets OSFlagAutoRefresh    -bool NO   # defaults to YES
defaults write com.quino.opensheets OSFlagDiagnostics    -bool YES
```

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
