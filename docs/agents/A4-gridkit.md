# A4 — GridKit: the virtualised grid renderer

**Wave 1 · parallel with A1–A3, A5–A7 · blocked by A0.**

## Mission
Draw a spreadsheet at 120 fps. This is the single biggest performance decision in the app
(PLAN.md §2.2) and the one component that must be AppKit, not SwiftUI.

You are building a **self-contained, previewable component**. It takes a `Workbook` and a
selection, and emits events. It knows nothing about files, Claude, or glass.

## Dependencies
A0 merged. Nothing else. Build a demo harness that generates a synthetic 1M-cell `Workbook` in
memory so you can develop and profile without A1.

## Files you own
```
Packages/OpenSheetsCore/Sources/GridKit/**
Packages/OpenSheetsCore/Tests/GridKitTests/**
```

## Files you must NOT touch
`GlassUI/**` (A5 owns all styling of *chrome*; you style only the grid interior), everything else.

## Build this

### 1. View hierarchy
`NSScrollView` → flipped custom `NSView` document view drawing with Core Graphics in
`draw(_ dirtyRect:)`. Column headers and row headers as **floating subviews**
(`NSScrollView.addFloatingSubview(_:for:)`) so they pin while content scrolls; a corner view at the
origin. Wrap the whole thing in one `NSViewRepresentable` called `GridView` with a clean
SwiftUI-facing API. Set `preparedContentRect` to overdraw ~1 screen in the scroll direction.

### 2. Virtualisation
From `visibleRect` + the `RunLengthArray` widths/heights, binary-search the first/last visible
row and column. **Never iterate all rows.** Draw only cells in the visible rect plus the overdraw
margin. Maintain a small LRU of laid-out `CTLine`s keyed by (text, styleID) — text shaping, not
drawing, is the real cost.

### 3. What you render
- Gridlines, alternating-row option (off by default), merged cells (draw once, clip correctly).
- Cell content per `NumberFormat`: alignment defaults (numbers right, text left, booleans centred),
  overflow into empty neighbours for text, `####` when a number doesn't fit, truncation with no
  ellipsis for text that hits a non-empty neighbour — match Excel, people rely on this.
- **Tabular figures always** (PLAN.md §3.4).
- Fonts, bold/italic, colour, fills, borders, indent, wrap, rotation (0/90/-90 only).
- Error values in the error style; `.staleCache` cells get a dotted underline; `.externalLink` gets
  a small corner marker.
- Frozen panes: up to 4 quadrants, each independently clipped, with a 1pt divider that has a subtle
  shadow toward the scrolling side.
- Selection: 2pt accent stroke, 6% accent fill, 6pt fill handle bottom-right, multi-range selection,
  active-cell-within-selection styled differently. Row/column headers highlight for the selection.
- The **"recently changed by Claude" flash**: a per-cell accent tint that decays over 6 s. Expose it
  as `func flash(_ refs: Set<CellRef>)`; drive the decay off a `CADisplayLink`-equivalent
  (`CVDisplayLink`/`NSView.displayLink(target:selector:)`) and stop the timer when it reaches zero.
  **Do not schedule a repeating timer that never stops** — it will keep the GPU awake and eat battery.

### 4. Interaction
Click, shift-click, ⌘-click multi-range, drag-select with autoscroll at the edges, double-click to
edit, fill-handle drag, column/row resize by dragging the header divider, double-click divider to
auto-fit, header click to select whole row/column, right-click context menu (emit an event, don't
build the menu). Full keyboard: arrows, ⇧arrows, ⌘arrows (jump to edge of data block — implement
Excel's exact semantics), Tab/Enter with the wrap-within-selection rule, Page Up/Down, ⌘Home/End,
type-to-edit, F2, Escape, Delete.

### 5. In-cell editor
An `NSTextField`-based overlay positioned over the active cell, growing to the right/down as needed,
using SF Mono when the content starts with `=`. Emits `beginEdit`/`commitEdit`/`cancelEdit`. It does
**not** parse or evaluate anything — that is A3's job, called by A8.

### 6. Theming hook
Take a `GridTheme` struct (colours, gridline, selection, header, fonts, row height) injected from
outside. **Read no colours from `GlassUI` and hardcode nothing** — A5 defines the palette, A8 wires
it in. Provide a light and a dark default so you can develop standalone.

### 7. Accessibility
`NSAccessibility` table/row/cell protocol conformance so VoiceOver can read the grid and report the
selection. This is legitimately hard for a canvas-drawn grid; budget real time for it.

## Acceptance criteria
- [ ] **120 fps sustained** flinging through a 1,000,000-cell synthetic workbook on Apple Silicon,
      p99 frame time < 8.3 ms, zero dropped frames. Prove it with an Instruments trace committed to
      `docs/perf/`.
- [ ] Scrolling to row 1,048,576 is instant and correct (no linear scans anywhere — assert by
      instrumenting the row-lookup call count per frame).
- [ ] Memory stays flat while scrolling a 1M-cell sheet for 60 s (no unbounded caches).
- [ ] Keyboard suite: ⌘↓ from a cell inside a data block lands where Excel lands, across all the
      block-edge cases. ≥ 30 cases.
- [ ] Merged cells, frozen panes, and a merged cell straddling a frozen boundary all render correctly
      (snapshot-tested, light + dark).
- [ ] `flash()` decays to zero and the display link **stops**; assert with a CPU-idle check after 8 s.
- [ ] VoiceOver reads the active cell's address and value.
- [ ] Renders correctly at 100%, 50%, 200% zoom and on a non-Retina display.

## Report back
The `GridView` SwiftUI API, the `GridTheme` fields A5 must supply, the event surface A8 must handle,
and your measured frame times.
