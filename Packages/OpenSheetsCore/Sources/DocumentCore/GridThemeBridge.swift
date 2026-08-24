import CoreGraphics
import GlassUI
import GridKit
import SheetModel

/// Turns A5's design-system grid theme into A4's renderer theme.
///
/// The two exist because neither target may import the other: `GridKit` must not depend on
/// `GlassUI` (it is AppKit and has to be testable with no design system at all), and `GlassUI`
/// must not depend on `GridKit` (it draws no cells). They are the same idea expressed twice —
/// `GlassUI.GridTheme` in `RGBA` doubles, `GridKit.GridTheme` in `RGBAColor` bytes — and the app
/// is the only place that can hold both, so the conversion lives here.
///
/// Four fields have no counterpart on one side or the other and are derived rather than invented:
/// see the inline notes. Everything else is a straight copy, which is the point — the grid and the
/// chrome are decided by one ``AppearanceContext`` and cannot disagree about the appearance
/// (addendum §6).
public enum GridThemeBridge {
    /// The renderer theme for an appearance.
    public static func resolved(_ context: AppearanceContext) -> GridKit.GridTheme {
        convert(GlassUI.GridTheme.resolved(context), context: context)
    }

    /// The conversion itself, exposed so a test can drive it from a hand-built theme.
    public static func convert(
        _ theme: GlassUI.GridTheme,
        context: AppearanceContext
    ) -> GridKit.GridTheme {
        let accent = theme.selectionStroke

        return GridKit.GridTheme(
            canvasBackground: color(theme.canvas),
            // A5's `canvasAlternate` is a full opaque row colour; A4 composites its
            // `alternatingRowBackground` over the canvas. They agree because A5's default is the
            // canvas itself, and banding is off by default in `GridOptions`.
            alternatingRowBackground: color(theme.canvasAlternate),
            gridline: color(theme.gridline),
            gridlineWidth: 1,
            cellText: color(theme.cellInk),
            errorText: color(theme.cellInkError),
            staleCacheUnderline: color(theme.cellInkStale),
            // A5 has no external-link marker: the fact it signals — "this formula reaches outside
            // the workbook" — is the same class of honesty as a stale cache, so it borrows the
            // formula ink rather than a new colour nobody reviewed.
            externalLinkMarker: color(theme.cellInkFormula),
            // Likewise no hyperlink ink. The accent is right: a hyperlink is the one cell-level
            // thing the user can activate, and the accent is what "activatable" means everywhere
            // else in the window.
            hyperlinkText: color(accent),
            accent: color(accent),
            selectionStrokeWidth: Double(theme.selectionStrokeWidth),
            selectionFillOpacity: theme.selectionFill.alpha,
            fillHandleSize: Double(theme.fillHandleSize),
            fillHandleBorder: color(theme.fillHandleStroke),
            inactiveRangeFillOpacity: theme.selectionFill.alpha * 0.6,
            headerBackground: color(theme.headerBackground),
            headerText: color(theme.headerInk),
            headerSeparator: color(theme.headerSeparator),
            // A5 resolves one active-header colour (accent at 12% over the header). A4 wants two:
            // a wash for "the selection touches this header" and a solid for "this is the active
            // cell's own header". The wash is A5's value; the solid is the accent.
            headerSelectedBackground: color(theme.headerActiveBackground),
            headerSelectedText: color(theme.headerActiveInk),
            headerActiveBackground: color(accent),
            headerActiveText: color(inkOnAccent(accent)),
            headerHeight: Double(theme.headerRowHeight),
            headerWidth: Double(theme.headerColumnWidth),
            headerFontSize: 11,
            frozenDivider: color(theme.gridlineMajor),
            // **Black, not a tint of the gridline.** A shadow darkens; it never lightens. Deriving
            // it from `gridlineMajor` gives a *light* grey on a dark canvas, and a light shadow
            // spread on both sides of a divider is a glow — which is exactly how it read: column A
            // appeared to be lit from its right edge. Heavier in dark because a dark canvas
            // swallows a soft shadow; these are GridKit's own default alphas (36/255, 120/255).
            frozenDividerShadow: RGBAColor(
                red: 0, green: 0, blue: 0,
                alpha: context.colorScheme == .dark ? 120 : 36
            ),
            frozenDividerWidth: 1,
            flashTint: color(theme.changeMarker),
            flashPeakOpacity: theme.changeFlashFill.alpha,
            flashDuration: theme.changeFlashDuration,
            bodyFontName: theme.cellFontName ?? "",
            monospacedFontName: "SF Mono",
            defaultFontSize: Double(theme.cellFontSize),
            defaultRowHeight: Double(theme.defaultRowHeight),
            defaultColumnWidth: Double(theme.defaultColumnWidth),
            cellPaddingX: Double(theme.cellPadding),
            indentWidth: 9,
            resizeHitSlop: 3,
            increaseContrast: context.increaseContrast
        )
    }

    private static func color(_ rgba: RGBA) -> RGBAColor {
        let clamped = rgba.clamped
        return RGBAColor(
            red: channel(clamped.red),
            green: channel(clamped.green),
            blue: channel(clamped.blue),
            alpha: channel(clamped.alpha)
        )
    }

    private static func channel(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    /// Black or white, whichever survives on the accent. The user's accent can be macOS yellow.
    private static func inkOnAccent(_ accent: RGBA) -> RGBA {
        let white = RGBA(white: 1)
        let black = RGBA(white: 0)
        return white.contrastRatio(against: accent) >= black.contrastRatio(against: accent)
            ? white
            : black
    }
}
