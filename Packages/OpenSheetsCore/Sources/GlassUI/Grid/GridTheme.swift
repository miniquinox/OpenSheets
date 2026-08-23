import CoreGraphics
import SwiftUI

/// Everything `GridKit` needs to draw, as one resolved value.
///
/// This is the contract between A5 and A4: **we choose the colours, A4 draws the cells.** Nothing
/// in `GlassUI` knows what a cell looks like, and nothing in `GridKit` knows what a design token
/// is. A8 builds one of these from the live ``AppearanceContext`` and hands it to the renderer,
/// then hands it a new one whenever the context changes.
///
/// Three properties of this type are deliberate and worth defending:
///
/// - **Every colour is ``RGBA``, not `Color` or `NSColor`.** A dynamic colour resolves against
///   whatever appearance is current at draw time, and the grid draws tens of thousands of
///   primitives per frame inside a `CGContext` that has no appearance of its own. Resolving once,
///   here, is both faster and the only way to be sure the pixel is the one we designed.
/// - **Every colour is opaque** except the four that are explicitly washes (selection fill,
///   header tint, flash, editor shadowless backdrop) — and those carry their alpha so A4 can
///   composite them itself, which is cheaper than a layer. ``GridTheme/validate()`` checks this.
/// - **It is `Equatable`.** A4 can compare the incoming theme against the current one and skip
///   the invalidation when nothing moved. Appearance notifications fire more often than the
///   appearance actually changes.
///
/// There is no glass in here at all. That is the point of §3: the grid is the one opaque plane,
/// and glass floats above it.
public struct GridTheme: Sendable, Hashable {
    // MARK: Planes

    /// The single opaque plane. Nothing behind the grid shows through it, ever.
    public var canvas: RGBA
    /// Alternate row band. Equal to ``canvas`` by default — see ``Palette/canvasAlternateLight``.
    public var canvasAlternate: RGBA
    /// One-point cell boundary.
    public var gridline: RGBA
    /// Frozen-pane divider and the header/body boundary.
    public var gridlineMajor: RGBA

    // MARK: Headers

    public var headerBackground: RGBA
    public var headerInk: RGBA
    /// The header of the row or column containing the selection, tinted with the accent at 12%
    /// and already flattened onto ``headerBackground``.
    public var headerActiveBackground: RGBA
    public var headerActiveInk: RGBA
    /// The line between the header band and the cells.
    public var headerSeparator: RGBA

    // MARK: Ink

    /// Cell text. Asserted at ≥ 4.5:1 against ``canvas``.
    public var cellInk: RGBA
    /// Placeholders and repeated units.
    public var cellInkSecondary: RGBA
    /// Formula source when "show formulas" is on.
    public var cellInkFormula: RGBA
    /// `#DIV/0!` and friends.
    public var cellInkError: RGBA
    /// A cached value we could not recompute, and the dotted underline beneath it.
    public var cellInkStale: RGBA

    // MARK: Selection

    /// PLAN.md §3.3: a 2pt accent stroke.
    public var selectionStroke: RGBA
    /// …and a 6% accent fill. Carries its alpha; A4 composites.
    public var selectionFill: RGBA
    public var selectionStrokeWidth: CGFloat
    /// The 6pt fill handle at the bottom-right of the selection.
    public var fillHandleSize: CGFloat
    public var fillHandleFill: RGBA
    /// The ring around the fill handle, so it survives on a dark cell fill from the file.
    public var fillHandleStroke: RGBA
    /// A range highlighted by the formula editor, or by "show in grid" from the diff.
    public var referenceStroke: RGBA

    // MARK: The agent

    /// PLAN.md §1.2: cells the agent changed flash this, then fade over
    /// ``DS/Motion/changeFlashDuration``. Carries its alpha at full strength; A4 ramps it down.
    public var changeFlashFill: RGBA
    /// The same fact as a one-point left edge, for users who cannot see the wash. Always drawn,
    /// not only under increase-contrast — see ``DS/SignalKind/symbolName`` for the same argument.
    public var changeMarker: RGBA
    public var changeFlashDuration: TimeInterval

    // MARK: The in-cell editor

    public var editorBackground: RGBA
    public var editorStroke: RGBA
    public var editorInk: RGBA
    public var editorCornerRadius: CGFloat

    // MARK: Metrics

    /// PLAN.md §3.4: 24pt at 100% zoom.
    public var defaultRowHeight: CGFloat
    public var defaultColumnWidth: CGFloat
    public var headerRowHeight: CGFloat
    public var headerColumnWidth: CGFloat
    /// Left and right inset inside a cell. Numbers are right-aligned to `width - cellPadding`.
    public var cellPadding: CGFloat
    /// PostScript name for the cell face. `nil` means "the system face at ``cellFontSize``",
    /// which is what we want — hardcoding `.SFNS-Regular` breaks when the user overrides it.
    public var cellFontName: String?
    public var cellFontSize: CGFloat
    /// True when the user has asked for less transparency or more contrast. A4 does not draw
    /// glass, but it does use this to decide whether the stale-value underline is dotted (quiet)
    /// or solid (unmissable).
    public var increasedContrast: Bool

    // MARK: - Resolution

    /// Builds the theme for an appearance. The **only** way to make one — there is no memberwise
    /// initialiser, because a partially-specified grid theme is a grid with one wrong colour in it
    /// and that is much harder to notice than a compile error.
    ///
    /// The accent comes from `context.accent`, which is the user's `controlAccentColor`. It is
    /// never hardcoded and never blue-by-assumption.
    public static func resolved(_ context: AppearanceContext) -> GridTheme {
        let canvas = context.pick(light: Palette.canvasLight, dark: Palette.canvasDark)
        let header = context.pick(light: Palette.headerBackgroundLight, dark: Palette.headerBackgroundDark)
        let accent = context.accent
        let contrast = context.increaseContrast

        // Increase-contrast pushes ink further from the canvas and lines further from everything.
        // The amount is small because the base palette already clears 4.5:1 — this is about the
        // *lines*, which sit at 1.3:1 by design and are the thing that actually disappears.
        let inkBoost = contrast ? 0.35 : 0.0
        let lineBoost = contrast ? 0.55 : 0.0
        let extreme = context.pick(
            light: Palette.contrastExtremeLight,
            dark: Palette.contrastExtremeDark
        )

        func hardened(_ color: RGBA, _ amount: Double) -> RGBA {
            amount > 0 ? color.mixed(with: extreme, amount: amount) : color
        }

        var theme = GridTheme(
            canvas: canvas,
            canvasAlternate: context.pick(
                light: Palette.canvasAlternateLight,
                dark: Palette.canvasAlternateDark
            ),
            gridline: hardened(
                context.pick(light: Palette.gridlineLight, dark: Palette.gridlineDark),
                lineBoost
            ),
            gridlineMajor: hardened(
                context.pick(light: Palette.gridlineMajorLight, dark: Palette.gridlineMajorDark),
                lineBoost
            ),
            headerBackground: header,
            headerInk: hardened(
                context.pick(light: Palette.headerInkLight, dark: Palette.headerInkDark),
                inkBoost
            ),
            headerActiveBackground: accent.opacity(contrast ? 0.20 : 0.12).composited(over: header),
            headerActiveInk: context.pick(
                light: Palette.headerActiveInkLight,
                dark: Palette.headerActiveInkDark
            ),
            headerSeparator: hardened(
                context.pick(light: Palette.gridlineMajorLight, dark: Palette.gridlineMajorDark),
                lineBoost
            ),
            cellInk: hardened(context.pick(light: Palette.inkLight, dark: Palette.inkDark), inkBoost),
            cellInkSecondary: hardened(
                context.pick(light: Palette.inkSecondaryLight, dark: Palette.inkSecondaryDark),
                inkBoost
            ),
            cellInkFormula: hardened(
                context.pick(light: Palette.inkFormulaLight, dark: Palette.inkFormulaDark),
                inkBoost
            ),
            cellInkError: hardened(
                context.pick(light: Palette.inkErrorLight, dark: Palette.inkErrorDark),
                inkBoost
            ),
            cellInkStale: hardened(
                context.pick(light: Palette.inkStaleLight, dark: Palette.inkStaleDark),
                inkBoost
            ),
            selectionStroke: accent,
            selectionFill: accent.opacity(contrast ? 0.10 : 0.06),
            selectionStrokeWidth: DS.Stroke.selection(context),
            fillHandleSize: 6,
            fillHandleFill: accent,
            fillHandleStroke: canvas,
            referenceStroke: accent.opacity(0.7),
            changeFlashFill: accent.opacity(contrast ? 0.28 : 0.20),
            changeMarker: accent,
            changeFlashDuration: DS.Motion.changeFlashDuration,
            editorBackground: canvas,
            editorStroke: accent,
            editorInk: context.pick(light: Palette.inkLight, dark: Palette.inkDark),
            editorCornerRadius: DS.Radius.cellEditor,
            defaultRowHeight: DS.Text.defaultRowHeight,
            defaultColumnWidth: DS.Text.defaultColumnWidth,
            headerRowHeight: 22,
            headerColumnWidth: 46,
            cellPadding: 6,
            cellFontName: nil,
            cellFontSize: DS.Text.cellFontSize,
            increasedContrast: contrast
        )

        // Reduce-transparency does not change the grid — the grid was never transparent. It is
        // recorded anyway so A4 can key its own caches on the whole context without a second
        // channel, and so a theme built in that state is not `==` to one built outside it.
        theme.reducedTransparency = context.reduceTransparency
        return theme
    }

    /// See ``resolved(_:)``. Not part of the drawing contract; present so the theme is a faithful
    /// function of the context.
    public private(set) var reducedTransparency = false

    private init(
        canvas: RGBA, canvasAlternate: RGBA, gridline: RGBA, gridlineMajor: RGBA,
        headerBackground: RGBA, headerInk: RGBA, headerActiveBackground: RGBA,
        headerActiveInk: RGBA, headerSeparator: RGBA,
        cellInk: RGBA, cellInkSecondary: RGBA, cellInkFormula: RGBA, cellInkError: RGBA,
        cellInkStale: RGBA,
        selectionStroke: RGBA, selectionFill: RGBA, selectionStrokeWidth: CGFloat,
        fillHandleSize: CGFloat, fillHandleFill: RGBA, fillHandleStroke: RGBA,
        referenceStroke: RGBA,
        changeFlashFill: RGBA, changeMarker: RGBA, changeFlashDuration: TimeInterval,
        editorBackground: RGBA, editorStroke: RGBA, editorInk: RGBA, editorCornerRadius: CGFloat,
        defaultRowHeight: CGFloat, defaultColumnWidth: CGFloat, headerRowHeight: CGFloat,
        headerColumnWidth: CGFloat, cellPadding: CGFloat, cellFontName: String?,
        cellFontSize: CGFloat, increasedContrast: Bool
    ) {
        self.canvas = canvas
        self.canvasAlternate = canvasAlternate
        self.gridline = gridline
        self.gridlineMajor = gridlineMajor
        self.headerBackground = headerBackground
        self.headerInk = headerInk
        self.headerActiveBackground = headerActiveBackground
        self.headerActiveInk = headerActiveInk
        self.headerSeparator = headerSeparator
        self.cellInk = cellInk
        self.cellInkSecondary = cellInkSecondary
        self.cellInkFormula = cellInkFormula
        self.cellInkError = cellInkError
        self.cellInkStale = cellInkStale
        self.selectionStroke = selectionStroke
        self.selectionFill = selectionFill
        self.selectionStrokeWidth = selectionStrokeWidth
        self.fillHandleSize = fillHandleSize
        self.fillHandleFill = fillHandleFill
        self.fillHandleStroke = fillHandleStroke
        self.referenceStroke = referenceStroke
        self.changeFlashFill = changeFlashFill
        self.changeMarker = changeMarker
        self.changeFlashDuration = changeFlashDuration
        self.editorBackground = editorBackground
        self.editorStroke = editorStroke
        self.editorInk = editorInk
        self.editorCornerRadius = editorCornerRadius
        self.defaultRowHeight = defaultRowHeight
        self.defaultColumnWidth = defaultColumnWidth
        self.headerRowHeight = headerRowHeight
        self.headerColumnWidth = headerColumnWidth
        self.cellPadding = cellPadding
        self.cellFontName = cellFontName
        self.cellFontSize = cellFontSize
        self.increasedContrast = increasedContrast
    }

    // MARK: - Self-checks

    /// What ``validate()`` found. Empty means the theme is drawable.
    public struct Problem: Sendable, Hashable, CustomStringConvertible {
        public let token: String
        public let detail: String
        public var description: String { "\(token): \(detail)" }
    }

    /// The invariants the renderer relies on, checked without drawing anything.
    ///
    /// Called from a test over every appearance in the matrix rather than at runtime — a grid
    /// theme is built from constants, so if it is valid once it is valid always, and paying for
    /// the check on every appearance change would be paying for nothing.
    public func validate() -> [Problem] {
        var problems: [Problem] = []

        func requireOpaque(_ color: RGBA, _ name: String) {
            if color.alpha < 1 {
                problems.append(Problem(token: name, detail: "must be opaque, is \(color.hexString)"))
            }
        }

        func requireContrast(_ ink: RGBA, on backdrop: RGBA, _ name: String, min: Double) {
            let ratio = ink.contrastRatio(against: backdrop)
            if ratio < min {
                problems.append(
                    Problem(
                        token: name,
                        detail: String(format: "%.2f:1 against %@, needs %.1f", ratio, backdrop.hexString, min)
                    )
                )
            }
        }

        // The plane and everything drawn as a solid on it.
        for (color, name) in [
            (canvas, "canvas"), (canvasAlternate, "canvasAlternate"),
            (headerBackground, "headerBackground"), (headerActiveBackground, "headerActiveBackground"),
            (cellInk, "cellInk"), (cellInkSecondary, "cellInkSecondary"),
            (cellInkFormula, "cellInkFormula"), (cellInkError, "cellInkError"),
            (cellInkStale, "cellInkStale"), (editorBackground, "editorBackground"),
        ] {
            requireOpaque(color, name)
        }

        // PLAN.md §3.5: cell text ≥ 4.5:1 against the canvas, in both schemes.
        requireContrast(cellInk, on: canvas, "cellInk", min: 4.5)
        requireContrast(cellInkSecondary, on: canvas, "cellInkSecondary", min: 4.5)
        requireContrast(cellInkFormula, on: canvas, "cellInkFormula", min: 4.5)
        requireContrast(cellInkError, on: canvas, "cellInkError", min: 4.5)
        requireContrast(cellInkStale, on: canvas, "cellInkStale", min: 4.5)
        requireContrast(headerInk, on: headerBackground, "headerInk", min: 4.5)
        requireContrast(headerActiveInk, on: headerActiveBackground, "headerActiveInk", min: 4.5)

        // Cell text still has to be readable through a selection wash and through a change flash.
        requireContrast(
            cellInk, on: selectionFill.composited(over: canvas), "cellInk over selectionFill", min: 4.5
        )
        requireContrast(
            cellInk, on: changeFlashFill.composited(over: canvas), "cellInk over changeFlashFill", min: 4.5
        )

        // Lines are not text; 1.2:1 is the floor at which a one-point line is still findable.
        for (line, name) in [(gridline, "gridline"), (gridlineMajor, "gridlineMajor")] {
            let ratio = line.contrastRatio(against: canvas)
            if ratio < 1.2 {
                problems.append(
                    Problem(token: name, detail: String(format: "%.2f:1 against canvas, needs 1.2", ratio))
                )
            }
        }

        return problems
    }

    /// A stable, human-readable dump. This is what the appearance snapshots record, and it is why
    /// a palette change shows up in a diff as a list of hex values rather than as "GridTheme.swift
    /// changed".
    public var snapshotDescription: String {
        let colors: [(String, RGBA)] = [
            ("canvas", canvas), ("canvasAlternate", canvasAlternate),
            ("gridline", gridline), ("gridlineMajor", gridlineMajor),
            ("headerBackground", headerBackground), ("headerInk", headerInk),
            ("headerActiveBackground", headerActiveBackground), ("headerActiveInk", headerActiveInk),
            ("headerSeparator", headerSeparator),
            ("cellInk", cellInk), ("cellInkSecondary", cellInkSecondary),
            ("cellInkFormula", cellInkFormula), ("cellInkError", cellInkError),
            ("cellInkStale", cellInkStale),
            ("selectionStroke", selectionStroke), ("selectionFill", selectionFill),
            ("fillHandleFill", fillHandleFill), ("fillHandleStroke", fillHandleStroke),
            ("referenceStroke", referenceStroke),
            ("changeFlashFill", changeFlashFill), ("changeMarker", changeMarker),
            ("editorBackground", editorBackground), ("editorStroke", editorStroke),
            ("editorInk", editorInk),
        ]
        let metrics: [(String, String)] = [
            ("selectionStrokeWidth", String(format: "%.1f", selectionStrokeWidth)),
            ("fillHandleSize", String(format: "%.1f", fillHandleSize)),
            ("changeFlashDuration", String(format: "%.1f", changeFlashDuration)),
            ("editorCornerRadius", String(format: "%.1f", editorCornerRadius)),
            ("defaultRowHeight", String(format: "%.1f", defaultRowHeight)),
            ("defaultColumnWidth", String(format: "%.1f", defaultColumnWidth)),
            ("headerRowHeight", String(format: "%.1f", headerRowHeight)),
            ("headerColumnWidth", String(format: "%.1f", headerColumnWidth)),
            ("cellPadding", String(format: "%.1f", cellPadding)),
            ("cellFontName", cellFontName ?? "system"),
            ("cellFontSize", String(format: "%.1f", cellFontSize)),
            ("increasedContrast", increasedContrast ? "yes" : "no"),
            ("reducedTransparency", reducedTransparency ? "yes" : "no"),
        ]
        let lines = colors.map { "  \($0.0.padding(toLength: 24, withPad: " ", startingAt: 0)) \($0.1.hexString)" }
            + metrics.map { "  \($0.0.padding(toLength: 24, withPad: " ", startingAt: 0)) \($0.1)" }
        return (["GridTheme"] + lines).joined(separator: "\n")
    }
}
