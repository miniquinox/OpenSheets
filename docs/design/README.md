# Quiet Glass — the OpenSheets design system

Everything here is produced by `Sources/GlassUI`. Nothing is a mockup: every screenshot is a real
`NSWindow` on macOS 26 with real Liquid Glass composited by the window server, over a real (if
small) spreadsheet drawn from the same `GridTheme` value that `GridKit` consumes.

> **One opaque plane — the grid. Glass floats above it, never behind data.**

---

## The rule that makes it look real

A spreadsheet is 90% dense text, and the failure mode of a glass UI is that everything floats and
nothing is readable. So the discipline is severe, and most of it is enforced by
`GlassUITests/GlassLintTests` rather than by good intentions:

| Rule | Enforced by |
| --- | --- |
| `.glassEffect` is called in exactly one file | `rawGlassAPIIsContained` |
| Two or more adjacent glass elements live in a `GlassEffectContainer` | `everyGlassClusterHasAContainer` |
| The escape hatch from that rule has exactly one entry | `separatedAnnotationsAreOnTheAllowList` |
| No shadow, border or material is layered on glass | `nothingIsLayeredOnGlass` |
| No glass button sits on a glass panel | `glassIsNotNestedInGlass` |
| Glass buttons go opaque under reduce-transparency | `glassButtonsHonourReduceTransparency` |
| Colour literals exist only in `Palette.swift` | `colourLiteralsAreCentralised` |
| The accent is never hardcoded | `accentIsNeverHardcoded` |
| Springs only | `motionIsSpringsOnly` |
| Numbers use tabular figures | `numbersAreTabular` |
| No component reads global state | `componentsTakeValuesNotSingletons` |

Contrast is arithmetic, not opinion — `PaletteContrastTests` pins every ink against every surface
across the six-state appearance matrix, plus all eight macOS accent presets.

---

## The signature moment

`morph-pill-*.png` → `morph-panel-*.png`.

The refresh pill **becomes** the diff panel: one `GlassCluster`, one `glassEffectID`, one shared
`@Namespace`, and the lens stretches from a capsule into a 24pt card. It is not a popover appearing
next to the pill — it is the same object at a different size, which is the whole product in one
gesture. Under `accessibilityReduceMotion` it cross-fades instead.

Two details make it feel liquid rather than resized: the shape animates on `DS.Motion.standard`
(spring, response 0.35 / damping 0.85) while the content animates on `DS.Motion.settle` (slower,
fully damped), so the surface arrives first and the rows land into it.

---

## Screenshots

`2x/` is captured at native Retina resolution; `1x/` is the same set at half width.

| File | What it shows |
| --- | --- |
| `document-{light,dark}` | The whole window: sidebar, toolbar, formula bar, grid, tabs, both floating surfaces |
| `morph-pill-{light,dark}` | The signature interaction, collapsed |
| `morph-panel-{light,dark}` | …and expanded. Same lens |
| `refresh-pill-{light,dark}` | All three signals: agent, conflict, failure |
| `diff-panel-{light,dark}` | Per-sheet chips, the changed-cell list, three ways out |
| `conflict-banner-{light,dark}` | Amber signal glass, three real answers, no dismiss |
| `toolbar-{light,dark}` | One `GlassEffectContainer` per group — the lenses merge inside a group and not between groups |
| `formula-bar-{light,dark}` | Name box · `fx` · syntax-highlighted field, with and without a diagnostic |
| `sheet-tabs-{light,dark}` | Capsule strip, colour dots, pending-change dots, hidden-sheet affordance |
| `sidebar-{light,dark}` | Sheets · named ranges · file · the Claude panel |
| `inspector-{light,dark}` | Number, font, alignment, fill, border |
| `selection-stats-{light,dark}` | Average · Count · Sum, tabular, in Excel's order |
| `command-palette-{light,dark}` | ⌘K, sectioned, fuzzy |
| `snapshots-{light,dark}` | Restore points; Compare is the primary action, not Restore |
| `launcher-{light,dark}` | Recents, drop target, workspace grants |
| `sync-chips-{light,dark}` | All nine states of the file-sync machine |
| `empty-states-{light,dark}` | All seven, together, so they can be heard as one voice |
| `tokens-{light,dark}` | The palette with live contrast ratios |
| `a11y-reduce-transparency-{light,dark}` | Every lens replaced by an opaque token and a hairline |
| `a11y-increase-contrast-{light,dark}` | Heavier separators, heavier selection, stronger inks |
| `cross-dark-chrome-white-grid` | Dark chrome over a white spreadsheet — PLAN.md §3.5 |
| `cross-light-chrome-dark-grid` | …and the other way round |

---

## `snapshots/` — the deterministic goldens

Six text files, one per appearance: `{light, dark} × {normal, reduceTransparency,
increaseContrast}`. Each records what every component's surface resolves to, every signal tint and
lens, both stroke weights, and the complete `GridTheme` as hex values.

They are text rather than PNGs on purpose. Real Liquid Glass is composited by the window server, so
an offscreen `ImageRenderer` produces the layout with the lens missing — a green pixel-snapshot
suite would be proof that the one thing this project is judged on had not been rendered at all. And
pixel goldens of text drift with font rasterisation across OS point releases, which turns a design
regression test into a thing people re-record until they stop reading it. These catch everything a
pixel diff would catch except pure layout, and they catch it as a readable diff of hex values.

Layout and the real lens are reviewed the other way: by looking, in `GlassUIGallery`, with the
screenshots above as the record.

Re-record with `GLASSUI_RECORD_SNAPSHOTS=1 swift test`. A diff in one of these is a design change
and should be read as one.

---

## Three things the tests found that eyes did not

1. **Tint does not scale with area.** The diff panel was `.regular.tint(accent)` at full strength,
   matching the pill it morphs from. At capsule size that is a signal you cannot miss; at 380 × 420
   it is a saturated blue slab with the numbers you are meant to read sitting on top of it. The
   panel is plain floating glass now; the signal is carried by the header glyph and by the accent on
   `Refresh`.

2. **SwiftUI's vibrancy picks label colour from the colour scheme; a strong tint sets the lens
   luminance.** Conflict amber is light in *both* schemes, so a dark-mode conflict banner rendered
   white text on pale amber at about 2.5:1. Signal surfaces now choose their ink by measuring it
   against the modelled lens, and take whichever of two inks scores higher — a luminance threshold
   gets the mid-range accents wrong. The tint itself is applied at `DS.Signal.glassTintStrength`
   (0.42), which is the strongest dye that still clears 4.5:1 for all eight macOS accent presets.

3. **A saturated orange tab dot measures 2.78:1 on a light surface, and a yellow one 2.30:1.** A 6pt
   dot is a graphic carrying meaning, so it needs 3:1. The light-mode swatches are much darker than
   the hues they name; dark mode keeps the bright versions, because there the surface is dark.

## …and one the eyes found that the tests did not

`.buttonStyle(.glass)` is a *system* style and does not consult our `AppearanceContext`. With
reduce-transparency simulated, the toolbar kept its lenses while every surface around it went
opaque. It is now branched explicitly, with a hand-rolled opaque fallback matching `GlassSurface`'s,
and `glassButtonsHonourReduceTransparency` keeps it that way.
