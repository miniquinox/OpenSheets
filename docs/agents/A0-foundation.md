# A0 — Foundation & interface freeze

**Wave 0 · runs alone · blocks all other agents.** Nothing else starts until this is merged.

## Mission
Stand up the repository, the SwiftPM package with every target stubbed, the Xcode app shell, CI —
and above all **the frozen data model that seven agents will compile against simultaneously.**

Your API decisions are load-bearing. Spend your effort on `SheetModel` being right, not on
features. There is no UI in this task.

## Dependencies
None. Reference the author's `SignalToNoise` app for house style — `App/Design/DesignSystem.swift`
for the doc-comment register, `Shared/Store.swift` for the `@Observable` store pattern, `PLAN.md`
for prose voice.

## Files you own (create all of these)
```
.gitignore  .gitattributes  README.md  LICENSE (MIT)  .swiftformat  .swiftlint.yml
.github/workflows/ci.yml
OpenSheets.xcodeproj/                     ← create once, then nobody touches it again
App/OpenSheetsApp.swift                   ← minimal: opens an empty window, prints version
App/Flags.swift
App/Assets.xcassets/{AppIcon,AccentColor}
Config/OpenSheets.entitlements  Config/Info.plist
Scripts/build.sh  Scripts/test.sh  Scripts/bench.sh   (bench.sh may be a stub A7 fills in)
Packages/OpenSheetsCore/Package.swift
Packages/OpenSheetsCore/Sources/SheetModel/**            ← THE FREEZE. All of it.
Packages/OpenSheetsCore/Sources/MiniZip/Types.swift      ← shared types only, no impl
Packages/OpenSheetsCore/Sources/{SheetFormat,SheetFormula,GridKit,GlassUI,SheetStore,SheetMCP}/Placeholder.swift
Packages/OpenSheetsCore/Tests/SheetModelTests/**
docs/agents/MODEL-CHANGE-REQUESTS.md      ← already exists, leave it
```

## Files you must NOT touch
`PLAN.md`, `docs/agents/*.md` (other than the one above). Do not implement any real logic in
`SheetFormat`/`GridKit`/`GlassUI`/etc — a `Placeholder.swift` with a single `enum` is exactly right.

## Build this

### 1. `Package.swift`
Platform `.macOS(.v26)`. Swift tools 6.3. Targets exactly as in PLAN.md §2:
`SheetModel` (no deps) · `MiniZip` (SheetModel) · `SheetFormat` (SheetModel, MiniZip) ·
`SheetFormula` (SheetModel) · `GridKit` (SheetModel) · `GlassUI` (SheetModel) ·
`SheetStore` (SheetModel, SheetFormat) · `SheetMCP` (SheetModel, SheetFormat, SheetFormula, SheetStore) ·
`TestSupport` (SheetModel) · a test target per source target.
Enable `.enableUpcomingFeature("StrictConcurrency")` and treat warnings as errors in CI.
Add GRDB as the only external dependency (`groue/GRDB.swift`, 7.x) on `SheetStore`.

### 2. `SheetModel` — implement fully, with tests
Everything in PLAN.md §5.1, plus:
- `CellRef`, `CellRange` with A1 conversion (`CellRef("B7")`, `.a1String`), column-letter math
  covering `A`→`XFD` (16384) and the `Z`/`AA` boundary. **These are the most-used functions in the
  codebase; make them fast and test them exhaustively.**
- `CellStore`: row-major sparse (`[Int32: RowRun]`, sorted `[UInt32]` cols + parallel `[Cell]`).
  Public API only — `subscript(CellRef)`, `cells(in: CellRange)`, `rows(in:)`, `setCell`,
  `removeCell`, `insertRows/deleteRows/insertColumns/deleteColumns` (with ref-shifting semantics
  documented), `usedRange`, `count`. Document loudly that the representation is private and may change.
- `RunLengthArray<T: Equatable>` for column widths / row heights — 16,384 columns must not cost
  16,384 `Double`s when 3 are custom.
- `StyleTable`, `StyleID`, `NumberFormat` (parse the OOXML format string into a renderable spec:
  decimals, thousands, currency, percent, date pattern, negative-in-red, text placeholder).
- `SheetDiff`, `CellChange`, `StructuralChange` (row/col insert/delete) — the *shape* only;
  A6 computes them.
- `SheetError` — one exhaustive typed error enum with `code: String` + `message: String`.
  Everyone throws these. No `fatalError`, no `NSError`, no stringly-typed errors anywhere.
- `Limits` — the caps from PLAN.md §7.4 as named constants.
- `OpaqueParts` + `MiniZip.Types` (`ZipEntry`: name, compressed bytes, method, crc32, sizes,
  timestamps) so A1 and A2 can implement reader and writer independently.

### 3. `App/Flags.swift`
`enum Flags { static var editing: Bool { UserDefaults.standard.bool(forKey: "OSFlagEditing") } … }`
for `editing`, `mcp`, `formulaEngine`, `snapshots`, `autoRefresh` (default **true**).

### 4. `App/OpenSheetsApp.swift`
Absolute minimum that launches: `WindowGroup` with a `Text("OpenSheets")`. A8 replaces this.
Set `.windowStyle(.hiddenTitleBar)` and full-size content view so A8 inherits the right window.

### 5. `DS` token skeleton — **names and structure only, values are A5's job**
Create `Packages/OpenSheetsCore/Sources/GlassUI/Placeholder.swift` containing an empty
`public enum DS {}` so nothing else is blocked. Do **not** design the palette.

### 6. CI (`.github/workflows/ci.yml`)
macOS 26 runner: `swift build`, `swift test`, `swiftformat --lint`, `swiftlint`. Warnings as errors.
Add a `performance` job that is allowed to no-op until A7 lands.

## Acceptance criteria
- [ ] `swift build` and `swift test` pass from `Packages/OpenSheetsCore` with zero warnings.
- [ ] `xcodebuild -scheme OpenSheets build` succeeds; the app launches and shows a window.
- [ ] `SheetModelTests` covers: A1↔CellRef round-trip for `A1`, `Z1`, `AA1`, `XFD1048576`;
      out-of-range rejection; `CellStore` insert/delete row shifting; `RunLengthArray` splice
      correctness; number-format parsing for `0.00`, `#,##0`, `0%`, `$#,##0.00;[Red]($#,##0.00)`,
      `yyyy-mm-dd`, `@`. ≥90% line coverage on `SheetModel`.
- [ ] `CellStore` benchmark in the test suite: inserting 1,000,000 cells < 2 s, and
      `cells(in:)` over a 50×50 rect out of 1M cells < 1 ms.
- [ ] Every public symbol in `SheetModel` has a doc comment.
- [ ] `docs/agents/README.md` table matches reality.

## Report back
The final `SheetModel` public interface (paste the signatures) and any decision you made that a
Wave 1 agent would reasonably have expected to go the other way.
