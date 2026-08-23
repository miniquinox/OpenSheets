import CoreGraphics
import Foundation
import SheetModel

/// Every colour, font, and metric the grid draws with, injected from outside.
///
/// # Why it is a plain value type
///
/// `GridKit` deliberately does not import `GlassUI`. The grid is the one **opaque plane** in the
/// app (PLAN.md §3): glass floats above it and never behind data, so the grid interior needs
/// custom colours rather than materials, and it needs them resolved — a material or a dynamic
/// `NSColor` cannot be snapshot-tested or diffed. Everything here is therefore an ``RGBAColor``
/// or a `Double`, which makes the whole theme `Equatable` and `Sendable`, makes a redraw
/// trigger a pure value comparison, and lets the renderer run in a test with no window server.
///
/// `GlassUI` (A5) owns the palette and produces one of these; the app shell (A8) picks the
/// light or dark variant from the effective appearance and hands it in, re-deriving on an
/// appearance change, on `accessibilityDisplayShouldIncreaseContrast`, and on an accent-colour
/// change. ``light`` and ``dark`` exist so `GridKit` is previewable and testable on its own.
public struct GridTheme: Sendable, Equatable {
    // MARK: - Canvas

    /// The grid's opaque background. Custom, never a material — see the type's note.
    public var canvasBackground: RGBAColor

    /// Tint painted over odd rows when ``GridOptions/showsAlternatingRows`` is on. Off by default:
    /// banding fights with a sheet's own fills, and real spreadsheets carry their own.
    public var alternatingRowBackground: RGBAColor

    /// Hairlines between cells. `separatorColor` at ~50% in the system palette.
    public var gridline: RGBAColor

    /// Gridline width in points, before zoom. Hairlines stay hairlines when you zoom in.
    public var gridlineWidth: Double

    // MARK: - Cell content

    /// What ``StyleColor/automatic`` resolves to for text. Must clear 4.5:1 against
    /// ``canvasBackground`` in both schemes (PLAN.md §3.5).
    public var cellText: RGBAColor

    /// Error tokens — `#REF!`, `#DIV/0!`, and our own `#CIRCULAR`.
    public var errorText: RGBAColor

    /// The dotted underline under a cell whose cached value we could not recompute
    /// (``CellFlags/staleCache``). Honesty, not decoration: PLAN.md §5.3.
    public var staleCacheUnderline: RGBAColor

    /// The corner marker on a cell whose formula reaches into another workbook.
    public var externalLinkMarker: RGBAColor

    /// Text colour for a cell carrying a ``Hyperlink``.
    public var hyperlinkText: RGBAColor

    // MARK: - Selection

    /// The system accent. Never hardcode blue — PLAN.md §3.3.
    public var accent: RGBAColor

    /// Stroke around the selected range, in points.
    public var selectionStrokeWidth: Double

    /// Alpha of the accent wash inside a selected range. 0.06 in the design tokens.
    public var selectionFillOpacity: Double

    /// Side of the square fill handle at the selection's bottom-right corner.
    public var fillHandleSize: Double

    /// Ring drawn around the fill handle so it reads against a dark cell fill.
    public var fillHandleBorder: RGBAColor

    /// Alpha of the wash over ranges that are selected but do not hold the active cell.
    /// Lower than ``selectionFillOpacity`` so multi-range selection has a visible focus.
    public var inactiveRangeFillOpacity: Double

    // MARK: - Headers

    public var headerBackground: RGBAColor
    public var headerText: RGBAColor
    /// The line between the headers and the canvas, and between one header cell and the next.
    public var headerSeparator: RGBAColor
    /// Headers covering the selection: accent at ~12%.
    public var headerSelectedBackground: RGBAColor
    public var headerSelectedText: RGBAColor
    /// The header of the active cell's own row and column.
    public var headerActiveBackground: RGBAColor
    public var headerActiveText: RGBAColor
    /// Height of the column header strip.
    public var headerHeight: Double
    /// Width of the row header strip. Widened at run time for six-digit row numbers.
    public var headerWidth: Double
    /// Point size of header labels.
    public var headerFontSize: Double

    // MARK: - Frozen panes

    /// The 1pt divider between a frozen pane and a scrolling one.
    public var frozenDivider: RGBAColor
    /// A soft shadow cast *toward the scrolling side*, so the frozen pane reads as being on top.
    public var frozenDividerShadow: RGBAColor
    public var frozenDividerWidth: Double

    // MARK: - "Claude changed this"

    /// The tint washed over a cell an agent just changed. Accent, per PLAN.md §3.1's signal tier.
    public var flashTint: RGBAColor
    /// Alpha at the instant of the flash, decaying to zero over ``flashDuration``.
    public var flashPeakOpacity: Double
    /// How long a flash takes to decay. Six seconds.
    public var flashDuration: Double

    // MARK: - Typography

    /// Family used when a cell's own font is unavailable, and for `General` text.
    /// Empty means "the system UI font", which is what a preview wants.
    public var bodyFontName: String
    /// Family for a cell being edited whose content starts with `=`. SF Mono.
    public var monospacedFontName: String
    /// Point size for a cell whose style says nothing.
    public var defaultFontSize: Double

    // MARK: - Metrics

    /// Default row height at 100% zoom. 24pt, not Excel's 15pt — PLAN.md §3.4.
    public var defaultRowHeight: Double
    /// Default column width at 100% zoom, in points.
    public var defaultColumnWidth: Double
    /// Horizontal breathing room inside a cell, each side.
    public var cellPaddingX: Double
    /// Width of one indent step. Excel's is about three characters.
    public var indentWidth: Double
    /// How close to a header divider the pointer counts as "on" it, for resize.
    public var resizeHitSlop: Double

    /// Stronger separators and a heavier selection stroke, for
    /// `accessibilityDisplayShouldIncreaseContrast`. A8 observes the notification and re-derives.
    public var increaseContrast: Bool

    public init(
        canvasBackground: RGBAColor,
        alternatingRowBackground: RGBAColor,
        gridline: RGBAColor,
        gridlineWidth: Double = 1,
        cellText: RGBAColor,
        errorText: RGBAColor,
        staleCacheUnderline: RGBAColor,
        externalLinkMarker: RGBAColor,
        hyperlinkText: RGBAColor,
        accent: RGBAColor,
        selectionStrokeWidth: Double = 2,
        selectionFillOpacity: Double = 0.06,
        fillHandleSize: Double = 6,
        fillHandleBorder: RGBAColor,
        inactiveRangeFillOpacity: Double = 0.04,
        headerBackground: RGBAColor,
        headerText: RGBAColor,
        headerSeparator: RGBAColor,
        headerSelectedBackground: RGBAColor,
        headerSelectedText: RGBAColor,
        headerActiveBackground: RGBAColor,
        headerActiveText: RGBAColor,
        headerHeight: Double = 22,
        headerWidth: Double = 46,
        headerFontSize: Double = 11,
        frozenDivider: RGBAColor,
        frozenDividerShadow: RGBAColor,
        frozenDividerWidth: Double = 1,
        flashTint: RGBAColor,
        flashPeakOpacity: Double = 0.28,
        flashDuration: Double = 6,
        bodyFontName: String = "",
        monospacedFontName: String = "SF Mono",
        defaultFontSize: Double = 12,
        defaultRowHeight: Double = 24,
        defaultColumnWidth: Double = 76,
        cellPaddingX: Double = 4,
        indentWidth: Double = 9,
        resizeHitSlop: Double = 3,
        increaseContrast: Bool = false
    ) {
        self.canvasBackground = canvasBackground
        self.alternatingRowBackground = alternatingRowBackground
        self.gridline = gridline
        self.gridlineWidth = gridlineWidth
        self.cellText = cellText
        self.errorText = errorText
        self.staleCacheUnderline = staleCacheUnderline
        self.externalLinkMarker = externalLinkMarker
        self.hyperlinkText = hyperlinkText
        self.accent = accent
        self.selectionStrokeWidth = selectionStrokeWidth
        self.selectionFillOpacity = selectionFillOpacity
        self.fillHandleSize = fillHandleSize
        self.fillHandleBorder = fillHandleBorder
        self.inactiveRangeFillOpacity = inactiveRangeFillOpacity
        self.headerBackground = headerBackground
        self.headerText = headerText
        self.headerSeparator = headerSeparator
        self.headerSelectedBackground = headerSelectedBackground
        self.headerSelectedText = headerSelectedText
        self.headerActiveBackground = headerActiveBackground
        self.headerActiveText = headerActiveText
        self.headerHeight = headerHeight
        self.headerWidth = headerWidth
        self.headerFontSize = headerFontSize
        self.frozenDivider = frozenDivider
        self.frozenDividerShadow = frozenDividerShadow
        self.frozenDividerWidth = frozenDividerWidth
        self.flashTint = flashTint
        self.flashPeakOpacity = flashPeakOpacity
        self.flashDuration = flashDuration
        self.bodyFontName = bodyFontName
        self.monospacedFontName = monospacedFontName
        self.defaultFontSize = defaultFontSize
        self.defaultRowHeight = defaultRowHeight
        self.defaultColumnWidth = defaultColumnWidth
        self.cellPaddingX = cellPaddingX
        self.indentWidth = indentWidth
        self.resizeHitSlop = resizeHitSlop
        self.increaseContrast = increaseContrast
    }

    /// The palette a ``StyleColor`` resolves against, wired to this theme.
    ///
    /// ``StyleColor/automatic`` must follow the canvas, or a workbook authored on white text
    /// disappears on a dark grid. That is what ``ColorPalette/automatic`` is for.
    public var stylePalette: ColorPalette {
        var palette = ColorPalette.office
        palette.automatic = cellText
        palette.background = canvasBackground
        return palette
    }
}

// MARK: - Defaults

public extension GridTheme {
    /// A standalone light palette, close enough to PLAN.md §3.3 to develop and snapshot against.
    /// A5 replaces it; nothing here is a design decision A5 has to keep.
    static let light = GridTheme(
        canvasBackground: RGBAColor(red: 255, green: 255, blue: 255),
        alternatingRowBackground: RGBAColor(red: 0, green: 0, blue: 0, alpha: 8),
        gridline: RGBAColor(red: 0, green: 0, blue: 0, alpha: 40),
        cellText: RGBAColor(red: 0, green: 0, blue: 0, alpha: 229),
        errorText: RGBAColor(red: 191, green: 42, blue: 42),
        staleCacheUnderline: RGBAColor(red: 176, green: 122, blue: 0),
        externalLinkMarker: RGBAColor(red: 138, green: 90, blue: 200),
        hyperlinkText: RGBAColor(red: 0, green: 102, blue: 204),
        accent: RGBAColor(red: 0, green: 122, blue: 255),
        fillHandleBorder: RGBAColor(red: 255, green: 255, blue: 255),
        headerBackground: RGBAColor(red: 246, green: 246, blue: 248),
        headerText: RGBAColor(red: 0, green: 0, blue: 0, alpha: 150),
        headerSeparator: RGBAColor(red: 0, green: 0, blue: 0, alpha: 55),
        headerSelectedBackground: RGBAColor(red: 0, green: 122, blue: 255, alpha: 31),
        headerSelectedText: RGBAColor(red: 0, green: 0, blue: 0, alpha: 220),
        headerActiveBackground: RGBAColor(red: 0, green: 122, blue: 255),
        headerActiveText: RGBAColor(red: 255, green: 255, blue: 255),
        frozenDivider: RGBAColor(red: 0, green: 0, blue: 0, alpha: 90),
        frozenDividerShadow: RGBAColor(red: 0, green: 0, blue: 0, alpha: 36),
        flashTint: RGBAColor(red: 0, green: 122, blue: 255)
    )

    /// The dark counterpart. Canvas is `#1C1C1E` per PLAN.md §3.3.
    static let dark = GridTheme(
        canvasBackground: RGBAColor(red: 28, green: 28, blue: 30),
        alternatingRowBackground: RGBAColor(red: 255, green: 255, blue: 255, alpha: 10),
        gridline: RGBAColor(red: 255, green: 255, blue: 255, alpha: 45),
        cellText: RGBAColor(red: 255, green: 255, blue: 255, alpha: 232),
        errorText: RGBAColor(red: 255, green: 118, blue: 110),
        staleCacheUnderline: RGBAColor(red: 235, green: 180, blue: 60),
        externalLinkMarker: RGBAColor(red: 190, green: 150, blue: 255),
        hyperlinkText: RGBAColor(red: 88, green: 166, blue: 255),
        accent: RGBAColor(red: 10, green: 132, blue: 255),
        fillHandleBorder: RGBAColor(red: 28, green: 28, blue: 30),
        headerBackground: RGBAColor(red: 38, green: 38, blue: 41),
        headerText: RGBAColor(red: 255, green: 255, blue: 255, alpha: 165),
        headerSeparator: RGBAColor(red: 255, green: 255, blue: 255, alpha: 60),
        headerSelectedBackground: RGBAColor(red: 10, green: 132, blue: 255, alpha: 46),
        headerSelectedText: RGBAColor(red: 255, green: 255, blue: 255, alpha: 235),
        headerActiveBackground: RGBAColor(red: 10, green: 132, blue: 255),
        headerActiveText: RGBAColor(red: 255, green: 255, blue: 255),
        frozenDivider: RGBAColor(red: 255, green: 255, blue: 255, alpha: 110),
        frozenDividerShadow: RGBAColor(red: 0, green: 0, blue: 0, alpha: 120),
        flashTint: RGBAColor(red: 10, green: 132, blue: 255)
    )

    /// A copy with the contrast adjustments PLAN.md §3.5 requires: stronger separators, a
    /// heavier selection stroke, and no signal that is carried by tint alone.
    func increasingContrast() -> GridTheme {
        var theme = self
        theme.increaseContrast = true
        theme.selectionStrokeWidth = max(selectionStrokeWidth, 3)
        theme.gridline = gridline.opaqueBlend(over: canvasBackground, boostingAlphaBy: 0.35)
        theme.headerSeparator = headerSeparator.opaqueBlend(over: headerBackground, boostingAlphaBy: 0.35)
        theme.frozenDivider = frozenDivider.opaqueBlend(over: canvasBackground, boostingAlphaBy: 0.4)
        return theme
    }
}

// MARK: - Colour helpers

public extension RGBAColor {
    /// This colour as a Core Graphics colour in the sRGB space.
    var cgColor: CGColor {
        CGColor(
            srgbRed: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            alpha: Double(alpha) / 255
        )
    }

    /// The same hue with a different alpha, `0 ... 1`.
    func withOpacity(_ opacity: Double) -> RGBAColor {
        RGBAColor(
            red: red,
            green: green,
            blue: blue,
            alpha: UInt8(max(0, min(255, (opacity * 255).rounded())))
        )
    }

    /// Flattens this colour onto `background` and pushes its alpha up, for high-contrast mode.
    func opaqueBlend(over background: RGBAColor, boostingAlphaBy boost: Double) -> RGBAColor {
        let alphaFraction = min(1, Double(alpha) / 255 + boost)
        func mix(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
            let value = Double(top) * alphaFraction + Double(bottom) * (1 - alphaFraction)
            return UInt8(max(0, min(255, value.rounded())))
        }
        return RGBAColor(
            red: mix(red, background.red),
            green: mix(green, background.green),
            blue: mix(blue, background.blue),
            alpha: 255
        )
    }

    /// Perceived luminance, `0 ... 1`, for deciding whether to draw light or dark text on a fill.
    var relativeLuminance: Double {
        func channel(_ raw: UInt8) -> Double {
            let value = Double(raw) / 255
            return value <= 0.039_28 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}
