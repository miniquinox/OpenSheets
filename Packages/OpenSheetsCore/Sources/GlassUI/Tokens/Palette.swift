import SwiftUI

/// Every colour literal in `GlassUI`. There are no others, and a test enforces that.
///
/// **Why one file.** Six agents will touch this package eventually, and the fastest way to lose a
/// palette is to let a `Color(red:…)` appear inside a component "just for this one badge". So
/// `GlassUITests/GlassLintTests` fails the build if a colour literal shows up anywhere else.
/// If you need a new colour, it goes here, with both schemes and a sentence saying what it is for.
///
/// **Why explicit light and dark.** Nothing below is derived from anything else. Dark mode is not
/// light mode inverted, and the increase-contrast variants are not light mode with a multiplier —
/// they are separate values chosen against a measured target. The contrast tests in
/// `PaletteContrastTests` pin every ink to a number.
///
/// **What is deliberately missing.** The accent. It is the user's, read from
/// `NSColor.controlAccentColor` at runtime and carried in ``AppearanceContext/accent``.
/// ``Palette/defaultAccentSwatchesOnly`` exists for the launcher's colour-dot picker and for
/// nothing else.
public enum Palette {
    // MARK: - The grid plane
    //
    // The one opaque surface in the app. Glass floats above it and never behind data, so these
    // are the only colours in the design system that are guaranteed to have a known backdrop —
    // which is what lets us assert real contrast ratios on cell text.

    /// PLAN.md §3.3. Pure white, not an off-white: a spreadsheet is compared against paper and
    /// against Excel, and both are white. Warming it by 2% reads as "unsaved draft".
    public static let canvasLight = RGBA(hex: "#FFFFFF")

    /// PLAN.md §3.3. Matches `NSColor.textBackgroundColor` in dark aqua to within one point
    /// (#1E1E1E measured); we sit two points darker so that a white cell fill loaded from the
    /// file still reads as a fill rather than as the canvas.
    public static let canvasDark = RGBA(hex: "#1C1C1E")

    /// Banded rows. Equal to the canvas by default — banding fights with the cell fills that come
    /// out of the file, and a workbook that arrives with its own zebra striping ends up with two
    /// stripes of different periods. A4 may switch this on for a sheet that has no fills at all.
    public static let canvasAlternateLight = RGBA(hex: "#FFFFFF")
    public static let canvasAlternateDark = RGBA(hex: "#1C1C1E")

    /// Gridlines.
    ///
    /// PLAN.md §3.3 says `separatorColor` at 50%. Measured, `separatorColor` is black at 9.8% in
    /// light and white at 9.8% in dark; halved and flattened onto the canvas that gives #F3F3F3
    /// light — invisible at one point on a Retina display — and, in dark, a colour *darker* than
    /// the canvas, so the gridlines would vanish entirely. These are explicit values instead.
    ///
    /// The explicit values were right to introduce and landed too low: 1.27:1 in light and 1.33:1
    /// in dark, against Excel's own ≈1.44:1 on white. Below Excel in both schemes and furthest
    /// below in the one with more light to lose is not "quiet", it is absent — the first thing
    /// anyone asked on seeing the grid was whether it had cell lines at all. These sit a little
    /// *above* Excel, at ≈1.48:1 light and ≈1.50:1 dark: enough to follow a row across a wide
    /// sheet, not enough to compete with the numbers on it. `PaletteContrastTests` holds the
    /// floor, so a future palette edit cannot quietly take the grid away again.
    public static let gridlineLight = RGBA(hex: "#D4D4D8")
    public static let gridlineDark = RGBA(hex: "#3A3A3E")

    /// Frozen-pane dividers and the edge of the header band. Twice the weight of a gridline,
    /// because it means something structural rather than "here is a cell boundary".
    ///
    /// "Twice" is measured as twice the *excess over 1:1*, which is the part a viewer can see:
    /// ≈2.05:1 against ≈1.50:1 in dark, ≈1.98:1 against ≈1.48:1 in light. Raising the minor line
    /// without raising this one would have left the structural lines reading as ordinary cell
    /// boundaries, which is the distinction they exist to make.
    public static let gridlineMajorLight = RGBA(hex: "#B8B8BD")
    public static let gridlineMajorDark = RGBA(hex: "#4E4E52")

    // MARK: - Grid ink
    //
    // Every one of these is asserted at ≥ 4.5:1 against its canvas in `PaletteContrastTests`.

    /// Cell text. Not `#000000`: a hair of blue keeps a full column of digits from looking
    /// stamped on, and 17:1 is well past the point where more contrast buys legibility.
    public static let inkLight = RGBA(hex: "#1A1A1F")
    public static let inkDark = RGBA(hex: "#F5F5F7")

    /// Row and column numbers, unit suffixes, the "(blank)" placeholder.
    public static let inkSecondaryLight = RGBA(hex: "#5C5C66")
    public static let inkSecondaryDark = RGBA(hex: "#9E9EA8")

    /// A cell whose value came from a formula, when "show formulas" is on. Blue-leaning so it
    /// reads as *computed* next to plain ink, and dark enough to stay body text at 6.2:1.
    public static let inkFormulaLight = RGBA(hex: "#3A5BB8")
    public static let inkFormulaDark = RGBA(hex: "#8FB4FF")

    /// `#DIV/0!` and friends. Never the tint colour — an error in a cell is text, and text has
    /// to clear 4.5:1 whatever the user's contrast settings are.
    public static let inkErrorLight = RGBA(hex: "#B3251F")
    public static let inkErrorDark = RGBA(hex: "#FF9E99")

    /// A cached value we could not recompute (`CellFlags.staleCache`), plus the dotted underline
    /// under it. Grey rather than amber: stale is not an error, it is an admission.
    public static let inkStaleLight = RGBA(hex: "#6E6E78")
    public static let inkStaleDark = RGBA(hex: "#909099")

    // MARK: - Grid headers

    /// The row/column header band. PLAN.md §3.3 asks for the `.headerView` material; a material
    /// cannot be handed to Core Graphics and would put a blur *behind* data, which §3 forbids.
    /// These are the opaque equivalents.
    public static let headerBackgroundLight = RGBA(hex: "#F2F2F5")
    public static let headerBackgroundDark = RGBA(hex: "#252528")

    public static let headerInkLight = RGBA(hex: "#3C3C43")
    public static let headerInkDark = RGBA(hex: "#C7C7CC")

    /// The header of the column or row containing the selection. Tinted with the accent at 12%
    /// (PLAN.md §3.3) — that tint is applied at theme-build time, over these bases.
    public static let headerActiveInkLight = RGBA(hex: "#1A1A1F")
    public static let headerActiveInkDark = RGBA(hex: "#F5F5F7")

    // MARK: - Solid surfaces for reduce-transparency
    //
    // When the user asks for less transparency, glass becomes one of these plus a hairline. They
    // are *not* the window background: a floating panel still has to read as floating when it is
    // opaque, so they are a step away from the surface behind them.

    public static let solidChromeLight = RGBA(hex: "#F4F4F7")
    public static let solidChromeDark = RGBA(hex: "#2A2A2E")

    public static let solidFloatingLight = RGBA(hex: "#FCFCFD")
    public static let solidFloatingDark = RGBA(hex: "#323236")

    /// The `hud` tier's frost tint (alpha = frost strength), theme-adaptive like the system's
    /// own HUDs: in light mode a bright white frost, in dark mode only a *lift* — enough sheen
    /// that the surface reads as a control, little enough that the lens stays visibly glass and
    /// the panel stays dark. 65% white was tried here and read as a light-grey slab over a dark
    /// grid: past a point, frost stops being glass and starts being paint.
    public static let hudFrostLight = RGBA(hex: "#FFFFFF99")
    public static let hudFrostDark = RGBA(hex: "#EBEBF042")

    /// The hairline that replaces the glass edge. This is the only border in the design system,
    /// and it exists only when there is no glass to muddy.
    public static let solidBorderLight = RGBA(hex: "#00000026")
    public static let solidBorderDark = RGBA(hex: "#FFFFFF2E")

    /// Where increase-contrast pushes ink and lines *towards*.
    ///
    /// Pure black on a light canvas and pure white on a dark one, used only as the far end of a
    /// mix — see ``GridTheme/resolved(_:)``. Nothing is ever drawn in these; they are a direction,
    /// not a colour. Naming them keeps the one place that hardens the palette from being the one
    /// place with a bare colour literal in it.
    public static let contrastExtremeLight = RGBA(hex: "#000000")
    public static let contrastExtremeDark = RGBA(hex: "#FFFFFF")

    /// The same hairline under increase-contrast: opaque, and dark enough to be a real edge.
    public static let solidBorderContrastLight = RGBA(hex: "#3C3C43")
    public static let solidBorderContrastDark = RGBA(hex: "#D0D0D6")

    // MARK: - Signal
    //
    // Three tints, and only three. Each means exactly one thing, everywhere in the app:
    //   accent — the agent touched this
    //   amber  — you and the file disagree
    //   red    — this failed
    // A fourth tint would make all four mean nothing.

    /// Conflict amber, used as a glass tint. Warmer than `systemOrange` (measured #FF8D28) so it
    /// separates from the red at a glance and does not read as an error.
    public static let conflictTintLight = RGBA(hex: "#FFB020")
    public static let conflictTintDark = RGBA(hex: "#FFA733")

    /// Conflict text and glyphs. The tint is unreadable as text in light mode, which is exactly
    /// why tint and ink are two tokens rather than one with an opacity on it.
    public static let conflictInkLight = RGBA(hex: "#8A4B00")
    public static let conflictInkDark = RGBA(hex: "#FFC978")

    /// Error red, as a glass tint.
    public static let errorTintLight = RGBA(hex: "#FF453A")
    public static let errorTintDark = RGBA(hex: "#FF5F55")

    /// Error text and glyphs — same values as the grid's error ink, on purpose. A `#REF!` in the
    /// grid and a "could not save" in the banner are the same fact in two places.
    public static let errorInkLight = RGBA(hex: "#B3251F")
    public static let errorInkDark = RGBA(hex: "#FF9E99")

    /// Text and glyphs sitting *on* a tinted signal surface.
    ///
    /// Two values, and which one is used is decided by the **tint's** luminance rather than by the
    /// colour scheme — see ``DS/Signal/inkOnTint(_:_:)``. Amber glass is light in dark mode as
    /// well as in light mode, so a scheme-driven `.primary` puts white text on it and the banner
    /// stops being readable exactly when it matters most.
    public static let onTintDark = RGBA(hex: "#17171A")
    public static let onTintLight = RGBA(hex: "#FFFFFF")

    /// "Nothing is wrong and nothing is happening." Watching, synced, read-only.
    public static let calmInkLight = RGBA(hex: "#5C5C66")
    public static let calmInkDark = RGBA(hex: "#9E9EA8")

    /// The one green in the app: the MCP status dot when Claude is actually connected. It is a
    /// dot, never text, so 3:1 is the bar and it clears it in both schemes.
    public static let connectedLight = RGBA(hex: "#1F8A46")
    public static let connectedDark = RGBA(hex: "#3FD37A")

    // MARK: - Change tracking
    //
    // Green added · amber changed · red removed. The diff vocabulary, and the one place this
    // design system knowingly puts a fourth, fifth and sixth colour next to the three signals.
    //
    // **Why that is not the "fourth tint" the signal note forbids.** A signal describes the
    // *app's* relationship with the file — the agent touched it, you disagree with it, it failed —
    // and there are three of those because there are three things that can be true. These describe
    // *content*: which cells moved since a baseline the user chose. They live on the grid plane
    // rather than on chrome, they annotate data rather than announce state, and green/amber/red is
    // not a palette we invented — it is what every diff the user has ever read already uses.
    // Reaching for the conflict amber here would say "you and the file disagree" about a cell that
    // simply has a new number in it.
    //
    // **Ink and tint are separate, for the same reason ``conflictTintLight`` and
    // ``conflictInkLight`` are.** The tint is a 14% wash under a cell, chosen to be *seen* without
    // pushing the cell's own text under 4.5:1. The ink is the `+12` on the chip and the glyph on a
    // panel row, chosen to *be read* on chrome. A single value cannot do both: the green that reads
    // as a wash on white is 2.7:1 as text, and the green that reads as text is nearly black as a
    // wash. `PaletteContrastTests` pins both jobs separately.
    //
    // Every value below is authored for its scheme. The greens are the same hue as
    // ``connectedLight``/``connectedDark`` at two different weights — the app has one green, and
    // this is it at text weight (4.5:1) rather than dot weight (3:1).

    /// A cell that did not exist at the baseline. Ink: `+12` on the chip, the row glyph in the panel.
    public static let changeAddedInkLight = RGBA(hex: "#0F7434")
    public static let changeAddedInkDark = RGBA(hex: "#3FD37A")

    /// …and the wash under the cell itself, applied at ``DS/Change/cellTintOpacity(_:)``.
    public static let changeAddedTintLight = RGBA(hex: "#34C759")
    public static let changeAddedTintDark = RGBA(hex: "#30D158")

    /// A cell whose value or formula moved. Amber, and deliberately a hair more golden than
    /// ``conflictTintLight`` — the two are adjacent in hue and mean different things, so the
    /// difference has to be visible when a conflict banner and a changed cell are on screen at once.
    public static let changeModifiedInkLight = RGBA(hex: "#8A5A00")
    public static let changeModifiedInkDark = RGBA(hex: "#F5C24C")

    public static let changeModifiedTintLight = RGBA(hex: "#E8940C")
    public static let changeModifiedTintDark = RGBA(hex: "#FFB02E")

    /// A cell that is gone. Not ``errorInkLight``: a removed row is not a failure, and using the
    /// error red for it would mean the app cries wolf every time an agent tidies a sheet. This is a
    /// deeper, quieter red that still reads as a deletion.
    public static let changeRemovedInkLight = RGBA(hex: "#A81E1E")
    public static let changeRemovedInkDark = RGBA(hex: "#FF8A82")

    public static let changeRemovedTintLight = RGBA(hex: "#E5484D")
    public static let changeRemovedTintDark = RGBA(hex: "#FF6369")

    // MARK: - Sheet tab dots

    /// The colour dots on sheet tabs. Excel lets a user colour a tab; this is our palette for it.
    /// Eight hues, evenly spread, ordered so adjacent choices in the picker are adjacent in hue.
    ///
    /// The light-mode orange and yellow are much darker than the hues they name — `#C25A00` and
    /// `#9C7300` rather than a cheerful `#FF9F0A`. That is not a taste decision. A 6pt dot is a
    /// graphic carrying meaning, so it needs 3:1 against the chrome behind it, and a saturated
    /// orange measures 2.78:1 on a light surface while a saturated yellow measures 2.30:1. The
    /// test caught both. Dark mode keeps the bright versions, because there the surface is dark
    /// and the bright hue is the one that clears the bar.
    public static let tabSwatches: [(name: String, light: RGBA, dark: RGBA)] = [
        ("Red", RGBA(hex: "#E5484D"), RGBA(hex: "#FF6369")),
        ("Orange", RGBA(hex: "#C25A00"), RGBA(hex: "#FF9F45")),
        ("Yellow", RGBA(hex: "#9C7300"), RGBA(hex: "#F5CE3E")),
        ("Green", RGBA(hex: "#1F8A46"), RGBA(hex: "#3FD37A")),
        ("Teal", RGBA(hex: "#0D8A87"), RGBA(hex: "#3FD0CC")),
        ("Blue", RGBA(hex: "#2C6BD8"), RGBA(hex: "#6BA6FF")),
        ("Purple", RGBA(hex: "#7A4BD1"), RGBA(hex: "#B08CFF")),
        ("Grey", RGBA(hex: "#7A7A85"), RGBA(hex: "#A0A0AA")),
    ]

    /// The launcher's swatch row only. See ``AppearanceContext/accent`` for the real accent.
    public static let defaultAccentSwatchesOnly = RGBA.defaultAccent
}
