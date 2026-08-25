import Foundation
import Testing

@testable import GlassUI

/// PLAN.md §3.5, as arithmetic.
///
/// "Cell text ≥ 4.5:1 against the grid canvas in both schemes" is the kind of requirement that is
/// agreed to in a plan and then quietly missed by 0.3 in dark mode, because nobody can see the
/// difference between 4.2 and 4.6 by eye — that is the whole reason the threshold is a number.
/// So it is checked here, over every appearance in the matrix, on every ink, including the ones
/// composited under a selection wash and under the agent's change flash.
///
/// The one thing these tests deliberately do **not** check is the accent. It belongs to the user,
/// and someone whose accent is macOS yellow gets 1.4:1 against white. The design answer is
/// structural rather than numeric: the accent carries emphasis — strokes, fills, a selected chip —
/// and never carries information that only text can carry. `accentIsNeverBodyText` pins that.
@Suite("Contrast")
struct PaletteContrastTests {
    /// WCAG AA for body text.
    static let bodyTextMinimum = 4.5
    /// WCAG AA for large or bold text, and for meaningful graphics.
    static let largeTextMinimum = 3.0
    /// Below this a one-point line is not findable on a Retina display. Not a WCAG number — there
    /// isn't one for a gridline — it is measured against the reference every user already has:
    /// Excel's own gridline is ≈1.44:1 on white, and a spreadsheet whose lines are fainter than
    /// Excel's is one people ask whether it has lines at all. This palette sits just above that,
    /// and the floor is set just below it so the margin is real rather than exact.
    ///
    /// It was 1.2, and 1.2 is a floor the palette cleared while the grid still looked blank:
    /// 1.27:1 in light and 1.33:1 in dark both passed. A floor that passes the bug is not a floor.
    static let hairlineMinimum = 1.4

    @Test("Cell text clears 4.5:1 on the canvas, in every appearance", arguments: AppearanceContext.snapshotMatrix)
    func cellTextIsReadable(_ context: AppearanceContext) {
        let theme = GridTheme.resolved(context)
        let inks: [(String, RGBA)] = [
            ("cellInk", theme.cellInk),
            ("cellInkSecondary", theme.cellInkSecondary),
            ("cellInkFormula", theme.cellInkFormula),
            ("cellInkError", theme.cellInkError),
            ("cellInkStale", theme.cellInkStale),
        ]
        for (name, ink) in inks {
            let ratio = ink.contrastRatio(against: theme.canvas)
            #expect(
                ratio >= Self.bodyTextMinimum,
                """
                \(context.snapshotName): \(name) is \(String(format: "%.2f", ratio)):1 against the \
                canvas (\(theme.canvas.hexString)), needs \(Self.bodyTextMinimum).
                """
            )
        }
    }

    @Test(
        "Cell text survives the selection wash and the change flash",
        arguments: AppearanceContext.snapshotMatrix
    )
    func cellTextSurvivesWashes(_ context: AppearanceContext) {
        let theme = GridTheme.resolved(context)
        let backdrops: [(String, RGBA)] = [
            ("selection", theme.selectionFill.composited(over: theme.canvas)),
            ("change flash", theme.changeFlashFill.composited(over: theme.canvas)),
            ("both", theme.selectionFill.composited(
                over: theme.changeFlashFill.composited(over: theme.canvas)
            )),
        ]
        for (name, backdrop) in backdrops {
            let ratio = theme.cellInk.contrastRatio(against: backdrop)
            #expect(
                ratio >= Self.bodyTextMinimum,
                """
                \(context.snapshotName): cell text over the \(name) wash (\(backdrop.hexString)) is \
                \(String(format: "%.2f", ratio)):1. A cell the agent just changed and that you then \
                select is the most important cell on the screen; it cannot be the least readable.
                """
            )
        }
    }

    @Test("Header text clears 4.5:1, active and inactive", arguments: AppearanceContext.snapshotMatrix)
    func headerTextIsReadable(_ context: AppearanceContext) {
        let theme = GridTheme.resolved(context)
        #expect(theme.headerInk.contrastRatio(against: theme.headerBackground) >= Self.bodyTextMinimum)
        #expect(
            theme.headerActiveInk.contrastRatio(against: theme.headerActiveBackground)
                >= Self.bodyTextMinimum,
            """
            \(context.snapshotName): the active header is the base header tinted with the user's \
            accent at \(context.increaseContrast ? "20" : "12")%. If a strong accent pushes this \
            under 4.5, the tint percentage is what has to move.
            """
        )
    }

    @Test("Gridlines are findable but quiet", arguments: AppearanceContext.snapshotMatrix)
    func gridlinesAreVisible(_ context: AppearanceContext) {
        let theme = GridTheme.resolved(context)
        for (name, line) in [("gridline", theme.gridline), ("gridlineMajor", theme.gridlineMajor)] {
            let ratio = line.contrastRatio(against: theme.canvas)
            #expect(
                ratio >= Self.hairlineMinimum,
                "\(context.snapshotName): \(name) is \(String(format: "%.2f", ratio)):1 — invisible."
            )
            // The other half of "quiet": a gridline that reads as a border is worse than one that
            // reads as nothing, because it turns a spreadsheet into a table of boxes.
            //
            // The band between this and `hairlineMinimum` is narrow on purpose. There is one
            // right answer for a gridline and it is close to Excel's.
            if !context.increaseContrast {
                #expect(
                    ratio <= 2.4,
                    """
                    \(context.snapshotName): \(name) is \(String(format: "%.2f", ratio)):1, which is \
                    loud enough to compete with the data. Increase-contrast is where lines get \
                    heavy; the default is not.
                    """
                )
            }
        }
    }

    /// The structural lines have to stay clearly heavier than the cell boundaries, or the frozen
    /// divider stops saying "the sheet is pinned here" and starts saying "here is another cell".
    /// Measured as the excess over 1:1, which is the part that is visible.
    @Test("A major line is about twice the minor one", arguments: [GlassColorScheme.light, .dark])
    func majorGridlinesReadAsStructure(_ scheme: GlassColorScheme) {
        let theme = GridTheme.resolved(AppearanceContext(colorScheme: scheme))
        let minor = theme.gridline.contrastRatio(against: theme.canvas) - 1
        let major = theme.gridlineMajor.contrastRatio(against: theme.canvas) - 1
        #expect(
            major >= minor * 1.6,
            "\(scheme): the frozen divider is \(String(format: "%.2f", major / minor))× the cell line"
        )
    }

    @Test("Increase-contrast actually increases contrast", arguments: [GlassColorScheme.light, .dark])
    func increaseContrastIsNotCosmetic(_ scheme: GlassColorScheme) {
        let plain = GridTheme.resolved(AppearanceContext(colorScheme: scheme))
        let bold = GridTheme.resolved(AppearanceContext(colorScheme: scheme, increaseContrast: true))

        #expect(
            bold.gridline.contrastRatio(against: bold.canvas)
                > plain.gridline.contrastRatio(against: plain.canvas),
            "\(scheme): gridlines did not get heavier under increase-contrast"
        )
        // Both lines, not just the cell boundary — PLAN.md §3.5 is about the whole grid, and a
        // frozen divider that stayed put while the gridlines rose would end up quieter than them.
        #expect(
            bold.gridlineMajor.contrastRatio(against: bold.canvas)
                > plain.gridlineMajor.contrastRatio(against: plain.canvas),
            "\(scheme): frozen dividers did not get heavier under increase-contrast"
        )
        #expect(
            bold.cellInkSecondary.contrastRatio(against: bold.canvas)
                > plain.cellInkSecondary.contrastRatio(against: plain.canvas),
            "\(scheme): secondary ink did not get stronger under increase-contrast"
        )
        #expect(
            bold.selectionStrokeWidth > plain.selectionStrokeWidth,
            "\(scheme): the selection stroke did not get thicker under increase-contrast"
        )
    }

    @Test("Reduce-transparency surfaces are readable", arguments: AppearanceContext.snapshotMatrix)
    func solidSurfacesAreReadable(_ context: AppearanceContext) {
        // When glass is replaced by a solid, chrome text lands on that solid. Chrome text is a
        // semantic system colour, so the closest we can assert is the ink we would use on the grid
        // — which is a *harder* test than the real one, because `.primary` is higher-contrast than
        // our cell ink in both schemes.
        let ink = context.pick(light: Palette.inkLight, dark: Palette.inkDark)
        let surfaces: [(String, RGBA)] = [
            ("solid chrome", context.pick(light: Palette.solidChromeLight, dark: Palette.solidChromeDark)),
            (
                "solid floating",
                context.pick(light: Palette.solidFloatingLight, dark: Palette.solidFloatingDark)
            ),
        ]
        for (name, surface) in surfaces {
            let ratio = ink.contrastRatio(against: surface)
            #expect(
                ratio >= Self.bodyTextMinimum,
                "\(context.snapshotName): text on the \(name) surface is \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    @Test("Signal inks are readable on their own surfaces", arguments: AppearanceContext.snapshotMatrix)
    func signalInksAreReadable(_ context: AppearanceContext) {
        let surface = context.pick(light: Palette.solidFloatingLight, dark: Palette.solidFloatingDark)
        let inks: [(String, RGBA)] = [
            ("conflict", context.pick(light: Palette.conflictInkLight, dark: Palette.conflictInkDark)),
            ("error", context.pick(light: Palette.errorInkLight, dark: Palette.errorInkDark)),
            ("calm", context.pick(light: Palette.calmInkLight, dark: Palette.calmInkDark)),
        ]
        for (name, ink) in inks {
            let ratio = ink.contrastRatio(against: surface)
            #expect(
                ratio >= Self.bodyTextMinimum,
                """
                \(context.snapshotName): the \(name) ink is \(String(format: "%.2f", ratio)):1 on a \
                floating surface. Signal ink is text — the tint is what gets to be pretty.
                """
            )
        }

        // The connected dot is a graphic, not text, so 3:1 is the bar.
        let connected = context.pick(light: Palette.connectedLight, dark: Palette.connectedDark)
        #expect(connected.contrastRatio(against: surface) >= Self.largeTextMinimum)
    }

    @Test("Change inks are readable on every chrome surface", arguments: AppearanceContext.snapshotMatrix)
    func changeInksAreReadable(_ context: AppearanceContext) {
        // The chip's `+12 ~5 −3` and the panel's row glyphs are **text**, and they land on whatever
        // the title bar and the popover resolve to. Under reduce-transparency that is exactly one
        // of these two opaque tokens, which makes this the case the numbers were chosen against;
        // with real glass the lens is lighter than the solid in light mode and darker in dark, so
        // the solid is the harder backdrop in both. Asserting the harder one is the honest test.
        let surfaces: [(String, RGBA)] = [
            ("chrome", DS.Surface.chromeColor(context)),
            ("floating", DS.Surface.floatingColor(context)),
        ]
        for kind in DS.Change.Kind.allCases {
            let ink = DS.Change.inkValue(kind, context)
            for (name, surface) in surfaces {
                let ratio = ink.contrastRatio(against: surface)
                #expect(
                    ratio >= Self.bodyTextMinimum,
                    """
                    \(context.snapshotName): the \(kind.rawValue) ink \(ink.hexString) is \
                    \(String(format: "%.2f", ratio)):1 on the \(name) surface \
                    (\(surface.hexString)). A diff count is text; the tint is what gets to be quiet.
                    """
                )
            }
        }

        // Three inks that measure the same are one ink drawn three times. The chip puts all three
        // side by side, so they have to separate from each other as well as from the surface.
        let inks = DS.Change.Kind.allCases.map { DS.Change.inkValue($0, context) }
        #expect(Set(inks.map(\.hexString)).count == inks.count)
    }

    @Test("A change tint never costs the cell its text", arguments: AppearanceContext.snapshotMatrix)
    func changeTintsKeepCellTextReadable(_ context: AppearanceContext) {
        // The whole reason the wash is only 14%. Unlike the change *flash*, which is gone in six
        // seconds, a standing tint sits under a number for as long as the user goes without setting
        // a checkpoint — an afternoon, in the case this feature was built for. If a palette edit
        // ever makes the wash louder, this is the assertion that says so.
        let theme = GridTheme.resolved(context)
        let tints: [(String, RGBA)] = [
            ("added", theme.changeAddedTint),
            ("modified", theme.changeModifiedTint),
            ("removed", theme.changeRemovedTint),
        ]
        for (name, tint) in tints {
            for (label, opacity) in [
                ("cell", theme.changeTintOpacity),
                ("band", theme.changeBandOpacity),
                // A selected cell that also changed is the most important cell on screen. It is
                // wearing both washes at once, and it is still the one you are trying to read.
                ("cell under selection", theme.changeTintOpacity),
            ] {
                var backdrop = tint.opacity(opacity).composited(over: theme.canvas)
                if label.hasSuffix("selection") {
                    backdrop = theme.selectionFill.composited(over: backdrop)
                }
                let ratio = theme.cellInk.contrastRatio(against: backdrop)
                #expect(
                    ratio >= Self.bodyTextMinimum,
                    """
                    \(context.snapshotName): cell text over the \(name) \(label) wash \
                    (\(backdrop.hexString)) is \(String(format: "%.2f", ratio)):1. The tint \
                    annotates the number; it does not get to hide it.
                    """
                )
            }
        }
    }

    @Test("A change tint is quiet, but it is not invisible", arguments: AppearanceContext.snapshotMatrix)
    func changeTintsAreVisible(_ context: AppearanceContext) {
        // The other half of the 14%. There is no WCAG number for "an area tint you can notice out
        // of the corner of your eye", so this floor is set against the thing the palette already
        // measures: a gridline clears 1.4:1 at one point wide, and a wash covering a whole cell
        // needs far less than a line to register. Below 1.05 it is not quiet, it is absent — which
        // is the failure that made the gridlines get re-authored (see `hairlineMinimum`).
        let theme = GridTheme.resolved(context)
        let tints: [(String, RGBA)] = [
            ("added", theme.changeAddedTint),
            ("modified", theme.changeModifiedTint),
            ("removed", theme.changeRemovedTint),
        ]
        for (name, tint) in tints {
            let wash = tint.opacity(theme.changeTintOpacity).composited(over: theme.canvas)
            let ratio = wash.contrastRatio(against: theme.canvas)
            #expect(
                ratio >= 1.05,
                """
                \(context.snapshotName): the \(name) tint composites to \(wash.hexString), which is \
                \(String(format: "%.3f", ratio)):1 against the canvas — you cannot tell a changed \
                cell from an unchanged one.
                """
            )
        }

        // Three washes that land on the same luminance are one wash. They separate by hue, so this
        // compares the composited pixels rather than the ratios.
        let washes = tints.map { $0.1.opacity(theme.changeTintOpacity).composited(over: theme.canvas) }
        #expect(Set(washes.map(\.hexString)).count == washes.count)
    }

    @Test("Increase-contrast strengthens the change wash", arguments: [GlassColorScheme.light, .dark])
    func changeTintsRespondToIncreaseContrast(_ scheme: GlassColorScheme) {
        let plain = GridTheme.resolved(AppearanceContext(colorScheme: scheme))
        let bold = GridTheme.resolved(AppearanceContext(colorScheme: scheme, increaseContrast: true))

        #expect(bold.changeTintOpacity > plain.changeTintOpacity, "\(scheme): the cell wash did not")
        #expect(bold.changeBandOpacity > plain.changeBandOpacity, "\(scheme): the band did not")
        // The hue does not move — these are content annotations, not chrome, and someone who asked
        // for more contrast asked for a stronger signal, not a different vocabulary.
        #expect(bold.changeAddedTint == plain.changeAddedTint)
        #expect(bold.changeModifiedTint == plain.changeModifiedTint)
        #expect(bold.changeRemovedTint == plain.changeRemovedTint)
        // A band is always quieter than a cell: it is hundreds of points wide and carries its
        // meaning by extent. If that inverts, one inserted row repaints the viewport.
        #expect(bold.changeBandOpacity < bold.changeTintOpacity)
        #expect(plain.changeBandOpacity < plain.changeTintOpacity)
    }

    @Test("The change tints are hues, not washes — the strength is carried separately")
    func changeTintsAreOpaqueHues() {
        // A tint that arrived carrying its own alpha would be washed twice by the renderer and land
        // at 2%: visible in no appearance, and caught by no other test because both halves would be
        // individually reasonable.
        for context in AppearanceContext.snapshotMatrix {
            let theme = GridTheme.resolved(context)
            for (name, tint) in [
                ("changeAddedTint", theme.changeAddedTint),
                ("changeModifiedTint", theme.changeModifiedTint),
                ("changeRemovedTint", theme.changeRemovedTint),
            ] {
                #expect(tint.alpha == 1, "\(context.snapshotName): \(name) is \(tint.hexString)")
            }
        }
    }

    @Test("Sheet-tab swatches read as dots on both chrome surfaces", arguments: AppearanceContext.snapshotMatrix)
    func tabSwatchesAreDistinguishable(_ context: AppearanceContext) {
        let surface = context.pick(light: Palette.solidChromeLight, dark: Palette.solidChromeDark)
        for entry in Palette.tabSwatches {
            let swatch = context.pick(light: entry.light, dark: entry.dark)
            let ratio = swatch.contrastRatio(against: surface)
            #expect(
                ratio >= Self.largeTextMinimum,
                """
                \(context.snapshotName): the \(entry.name) tab dot is \
                \(String(format: "%.2f", ratio)):1 against chrome — at 6pt that is not a dot, it is \
                a smudge.
                """
            )
        }
    }

    /// How much of the backdrop a `.regular` lens covers, for the purposes of this test.
    ///
    /// Apple does not publish a number, and there is no API that resolves a `Glass` to a colour,
    /// so the alternative to a stated assumption is no test at all. 0.6 is deliberately
    /// conservative: sampled against a real window, `.regular` sits noticeably more opaque than
    /// this, and the system additionally applies a vibrancy pass that pushes `.primary` further
    /// from the surface than a flat composite would.
    ///
    /// What this proves: the palette cannot get *worse* than these numbers. What it does not
    /// prove: that the real lens looks right — for that there is the gallery's `Backdrop` control,
    /// which forces chrome of one scheme over a grid of the other, and the screenshots in
    /// `docs/design/`.
    static let modelledGlassCoverage = 0.6

    @Test("Chrome is legible over a white grid and over a dark grid")
    func chromeWorksOverEitherGrid() {
        // PLAN.md §3.5's second sentence, and the one people skip. A dark-mode window shows a
        // *white* grid whenever the workbook's cells are white, so dark chrome has to survive a
        // white backdrop bleeding under it through .backgroundExtensionEffect(), and vice versa.
        //
        // The ink used here is the grid's own ink rather than `.primary`, which makes the test
        // harder than reality: `.primary` is pure white in dark mode and pure black in light,
        // both further from the surface than our cell ink.
        for chrome in [GlassColorScheme.light, .dark] {
            for grid in [GlassColorScheme.light, .dark] {
                let chromeContext = AppearanceContext(colorScheme: chrome)
                let ink = chromeContext.pick(light: Palette.inkLight, dark: Palette.inkDark)
                let surface = chromeContext.pick(
                    light: Palette.solidChromeLight,
                    dark: Palette.solidChromeDark
                )
                let canvas = GridTheme.resolved(AppearanceContext(colorScheme: grid)).canvas
                let lens = surface.opacity(Self.modelledGlassCoverage).composited(over: canvas)
                let ratio = ink.contrastRatio(against: lens)

                // Matching schemes are the everyday case and must clear body text.
                // Mismatched is the awkward one — a dark toolbar over a white spreadsheet — and it
                // clears the graphics/large-text bar. That is why nothing in the chrome is smaller
                // than 11pt, and why the sync chip and the stats pill are semibold.
                let minimum = chrome == grid ? Self.bodyTextMinimum : Self.largeTextMinimum
                #expect(
                    ratio >= minimum,
                    """
                    \(chrome) chrome over a \(grid) grid resolves to \(lens.hexString) and gives \
                    \(String(format: "%.2f", ratio)):1, needs \(minimum).
                    """
                )
            }
        }
    }

    @Test("Ink on a tinted surface is chosen against the tint, not the scheme")
    func inkOnTintIsReadable() {
        // The bug this pins: `.regular.tint(amber)` is a *light* lens in dark mode too, and
        // SwiftUI's vibrant `.primary` there is white. The dark-mode conflict banner shipped into
        // a screenshot at roughly 2.5:1 before this rule existed.
        //
        // Modelled the same way the ink itself is chosen: the tint at DS.Signal.glassTintStrength
        // over the floating surface. Ink and assertion share one model on purpose — they can be
        // wrong about the compositor together, but they cannot disagree with each other.
        let accents = [
            "#007AFF", "#A550A7", "#F74F9E", "#FF5257", "#F7821B", "#FFC600", "#62BA46", "#8E8E93",
        ].map { RGBA(parsingHex: $0)! }

        for scheme in [GlassColorScheme.light, .dark] {
            for accent in accents {
                var context = AppearanceContext(colorScheme: scheme)
                context.accent = accent
                for kind in DS.SignalKind.allCases {
                    guard let lens = DS.Signal.lensValue(kind, context) else { continue }
                    let ink = DS.Signal.inkValueOnTint(kind, context)
                    let ratio = ink.contrastRatio(against: lens)
                    #expect(
                        ratio >= Self.bodyTextMinimum,
                        """
                        \(scheme) \(kind.rawValue) with accent \(accent.hexString): ink \
                        \(ink.hexString) on lens \(lens.hexString) is \
                        \(String(format: "%.2f", ratio)):1.
                        """
                    )
                }
            }
        }
    }

    @Test("The accent is never used as body text")
    func accentIsNeverBodyText() throws {
        // The accent belongs to the user and can be any hue, including macOS yellow at 1.4:1 on
        // white. So this is not a numeric check — it is a structural one: `DS.Chrome.accent` may
        // tint a glyph, a stroke, a fill or a link, and every place it appears next to a fact, the
        // fact is also carried by position, weight or a word. The lint keeps the accent out of
        // Palette; this pins the one thing arithmetic cannot.
        let theme = GridTheme.resolved(.light)
        #expect(theme.cellInk != theme.selectionStroke, "cell ink must not be the accent")
        #expect(theme.cellInkSecondary != theme.selectionStroke)
        #expect(theme.headerInk != theme.selectionStroke)
        #expect(theme.editorInk != theme.selectionStroke)

        // Everywhere the accent *is* used on the grid, it is a stroke or a wash.
        #expect(theme.selectionFill.alpha < 1, "the selection fill must be a wash, not a fill")
        #expect(theme.changeFlashFill.alpha < 1, "the change flash must be a wash, not a fill")
    }

    @Test("Every appearance produces a drawable grid theme", arguments: AppearanceContext.snapshotMatrix)
    func gridThemeValidates(_ context: AppearanceContext) {
        let problems = GridTheme.resolved(context).validate()
        let report = problems.map { "  \($0)" }.joined(separator: "\n")
        #expect(problems.isEmpty, "\(context.snapshotName):\n\(report)")
    }

    @Test("Non-default accents do not silently break the grid")
    func themeHoldsForOtherAccents() {
        // The six macOS accent presets, plus the two worst cases for contrast. If one of these
        // produces an invalid theme, the tint percentages are wrong — not the user's taste.
        let accents = [
            "#007AFF", "#A550A7", "#F74F9E", "#FF5257", "#F7821B", "#FFC600", "#62BA46", "#8E8E93",
        ].map { RGBA(parsingHex: $0)! }

        for accent in accents {
            for scheme in [GlassColorScheme.light, .dark] {
                var context = AppearanceContext(colorScheme: scheme)
                context.accent = accent
                let problems = GridTheme.resolved(context).validate()
                let report = problems.map { "  \($0)" }.joined(separator: "\n")
                #expect(problems.isEmpty, "accent \(accent.hexString) in \(scheme):\n\(report)")
            }
        }
    }
}
