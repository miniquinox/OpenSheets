# A5 — GlassUI: the design system and every glass surface

**Wave 1 · parallel with A1–A4, A6, A7 · blocked by A0.**

## Mission
This is the task the whole project is judged on. The user's brief was: *"Must look clean as hell,
and feel like a truly glass product"* — and specifically **real native glass, not a translucent
`div`.** On macOS 26 that means the actual `glassEffect` APIs, used with discipline.

Read **PLAN.md §3 ("Quiet Glass") in full** before writing a line. Then read
`SignalToNoise/App/Design/DesignSystem.swift` (the author's own app) — that is the house
pattern for `DS` tokens and the `GlassSurface` modifier, and you are extending it to macOS and to
light mode. Also invoke the `frontend-design` skill before you start.

## Dependencies
A0 merged. **Nothing else** — you build against mock data and SwiftUI `#Preview`s only. You must not
import `GridKit`, `SheetFormat`, or `SheetStore`.

## Files you own
```
Packages/OpenSheetsCore/Sources/GlassUI/**
Packages/OpenSheetsCore/Tests/GlassUITests/**            ← snapshot tests
docs/design/                                             ← screenshots of every component, both schemes
```

## Files you must NOT touch
Everything else. Especially: do not style the grid interior — you *supply* a `GridTheme` value to
A4's spec, you do not draw cells.

## Build this

### 1. `DS` — tokens, light + dark, one place to touch the look
Follow the house pattern exactly (`enum DS`, static properties, a comment explaining the intent).
Light and dark defined explicitly, not derived. Cover: canvas/grid surfaces, gridline, selection,
header, text roles, semantic signal colours (agent-accent, conflict-amber, error-red, stale-grey),
radii (`card 24 · control 10 · cellEditor 6`, all `.continuous`), spacing scale, spring animations
(`response 0.35, damping 0.85`), and typography roles.

- **Accent is `Color.accentColor`** (the user's system accent). Never hardcode blue.
- Chrome colours use semantic system colours (`.primary`, `.secondary`, `separatorColor`,
  `unemphasizedSelectedContentBackgroundColor`) so the app inherits native behaviour.
- Grid surface colours are custom values, because they must be **opaque** — never materials.

### 2. `GlassSurface` — the signature modifier
macOS-26 path uses the real API; provide the three tiers from PLAN.md §3.1:

```swift
.glassEffect(.regular, in: shape)                       // Chrome
.glassEffect(.regular.interactive(), in: .capsule)      // Floating controls
.glassEffect(.regular.tint(DS.conflict), in: shape)     // Signal
```

Rules, all enforceable by review:
- **Never layer your own border, shadow, or `.ultraThinMaterial` on top of real glass.** The system
  has its own lighting model; adding to it just muddies it. (This exact note is in the house
  `DesignSystem.swift` — keep it.)
- **Every cluster of ≥2 glass elements lives inside a `GlassEffectContainer(spacing:)`** so adjacent
  lenses merge instead of stacking. Stacked glass is the #1 tell of a fake. This is the difference
  between "real glass product" and "blurry rectangles" — treat it as a hard rule.
- `.backgroundExtensionEffect()` on the grid container so content bleeds under the toolbar and
  sidebar rather than stopping at a hard edge.
- Use `.buttonStyle(.glass)` for toolbar buttons and `ToolbarSpacer(.fixed)` for grouping rather
  than reimplementing button chrome.

### 3. `reduceTransparency` / `increaseContrast` — mandatory, not optional
Observe `NSWorkspace.shared.notificationCenter` for
`accessibilityDisplayOptionsDidChangeNotification`; **do not just read the flag once at launch.**
When reduce-transparency is on, every glass surface swaps to a solid `DS` token with a hairline
border. When increase-contrast is on, separators and the selection stroke get heavier and no signal
is carried by tint alone. Both states are snapshot-tested.

### 4. Components (each with mock data and a `#Preview` in light + dark)
| Component | Tier | Notes |
| --- | --- | --- |
| `ToolbarSurface` + `ToolbarGroup` | Chrome | distilled Excel Home ribbon: clipboard, font, alignment, number format, insert/delete, sum, find. Overflow into a `Menu`. **One `GlassEffectContainer` per group.** |
| `FormulaBar` | Chrome | name box (A1 + defined-name picker) · `fx` · expanding field, SF Mono, syntax-highlighted tokens (ref / function / string / number / operator / error) |
| `SheetTabBar` | Chrome | capsule strip, drag-reorder, rename on double-click, `+`, colour dot, hidden-sheet affordance |
| `Sidebar` | Chrome | sheets · named ranges · file info · **Claude panel** (workspace path, MCP status dot, `Open terminal here`, session change feed) |
| `SelectionStatsPill` | Floating | Sum / Average / Count / Min / Max of selection, tabular figures, click to cycle which stats show |
| `RefreshPill` | Signal (accent) | **the signature component.** Pulsing dot + "Changed on disk · 1 sheet, 42 cells · Refresh ⌘R" |
| `DiffPanel` | Floating | the pill **morphs** into this via `glassEffectID` + shared `@Namespace`. Per-sheet counts, scrollable cell list (`D2  120 → 129.6`), three actions |
| `ConflictBanner` | Signal (amber) | "You have 3 unsaved edits" · Keep mine / Take disk / Compare |
| `CommandPalette` | Floating | ⌘K, fuzzy, sectioned results |
| `Inspector` | Chrome | number format, font, fill, border, alignment |
| `SnapshotBrowser` | Floating | restore points, timestamps, change summaries |
| `LauncherWindow` | Chrome | recents grid, drop target, workspace grants |
| `EmptyStates` | — | no sheets · unreadable · password-protected · file missing · file locked · read-only |

Every component takes a plain value type as input and emits actions through a closure or an enum.
**No component reads global state, no singletons, no `@EnvironmentObject`.** A8 wires them up.

### 5. Window chrome
`NSWindow` config helpers: `titlebarAppearsTransparent`, `.fullSizeContentView`, unified toolbar,
a live **sync-state chip** in the titlebar (Synced / Stale / Conflict / Read-only / Watching paused).

### 6. Motion
Springs only. The refresh-pill → diff-panel morph is the app's signature moment and should feel
liquid — spend real time on it. Respect `accessibilityReduceMotion` by cross-fading instead.

## Acceptance criteria
- [ ] A `GlassUIGallery` preview app target renders **every** component with mock data. It builds and
      runs standalone, with no dependency on any other Wave 1 target.
- [ ] Snapshot tests: every component × {light, dark} × {normal, reduceTransparency, increaseContrast}
      = 6 snapshots each, deterministic, committed.
- [ ] Screenshots of all of it in `docs/design/`, light and dark, at 1x and 2x.
- [ ] **Audit test:** a test that fails if any glass modifier is applied outside a
      `GlassEffectContainer` where a sibling glass view exists, and if any view applies both
      `.glassEffect` and a custom `.shadow`/`.border`. (A simple source-scanning test is acceptable
      and is genuinely worth it — this rule *will* be broken accidentally.)
- [ ] Contrast: cell-text-on-canvas ≥ 4.5:1 in both schemes; chrome text legible over both a white
      and a dark grid scrolling beneath (test both backgrounds).
- [ ] Toggling System Settings → Accessibility → Reduce transparency updates the running gallery
      **live**, without relaunch.
- [ ] Every control keyboard-reachable and VoiceOver-labelled.

## Report back
The `DS` token list, the `GridTheme` value you produce for A4, each component's input/action types
(A8 needs these), and screenshots.
