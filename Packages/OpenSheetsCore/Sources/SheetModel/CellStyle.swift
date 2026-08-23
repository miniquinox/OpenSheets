import Foundation

/// How text in a cell is drawn.
public struct FontStyle: Sendable, Hashable, Codable {
    /// Where a run of text sits relative to the baseline.
    public enum VerticalAlignment: String, Sendable, Hashable, Codable, CaseIterable {
        case baseline, superscript, `subscript`
    }

    /// Excel distinguishes accounting underlines, which extend across the cell rather than
    /// only under the glyphs.
    public enum Underline: String, Sendable, Hashable, Codable, CaseIterable {
        case none, single, double, singleAccounting, doubleAccounting
    }

    /// Typeface name as written in the file. Not resolved to an installed font here — that is
    /// a rendering concern, and the substitution has to happen where the font list lives.
    public var name: String
    /// Size in points.
    public var size: Double
    /// Excel has no weight axis — a font is bold or it is not.
    public var isBold: Bool
    public var isItalic: Bool
    /// Underlines are a style, not a boolean, because accounting underlines span the cell.
    public var underline: Underline
    public var isStrikethrough: Bool
    /// ``StyleColor/automatic`` is the common value and resolves against the grid, so text
    /// stays legible when the canvas is dark.
    public var color: StyleColor
    /// Superscript and subscript, which xlsx models per font rather than per run.
    public var verticalAlignment: VerticalAlignment

    public init(
        name: String = "Calibri",
        size: Double = 11,
        isBold: Bool = false,
        isItalic: Bool = false,
        underline: Underline = .none,
        isStrikethrough: Bool = false,
        color: StyleColor = .automatic,
        verticalAlignment: VerticalAlignment = .baseline
    ) {
        self.name = name
        self.size = size
        self.isBold = isBold
        self.isItalic = isItalic
        self.underline = underline
        self.isStrikethrough = isStrikethrough
        self.color = color
        self.verticalAlignment = verticalAlignment
    }

    /// Calibri 11 in the automatic colour — Excel's own default, and what an unstyled cell gets.
    public static let `default` = FontStyle()
}

/// A cell's background.
///
/// Modelled as xlsx models it — a pattern plus two colours — rather than as a single fill,
/// because the pattern is what round-trips. Nearly every real fill is `.solid`, where the
/// *foreground* colour is the visible one. That is counter-intuitive and is a reliable source
/// of "why is my fill white" bugs.
public struct FillStyle: Sendable, Hashable, Codable {
    /// The eighteen fill patterns xlsx defines. Everything but ``none`` and ``solid`` is a
    /// legacy hatch that modern files rarely use, but they still have to round-trip.
    public enum Pattern: String, Sendable, Hashable, Codable, CaseIterable {
        case none
        case solid
        case mediumGray, darkGray, lightGray, darkHorizontal, darkVertical, darkDown, darkUp
        case darkGrid, darkTrellis, lightHorizontal, lightVertical, lightDown, lightUp
        case lightGrid, lightTrellis, gray125, gray0625
    }

    /// Which of the eighteen patterns this fill uses.
    public var pattern: Pattern
    /// For `.solid`, this is the colour you see.
    public var foreground: StyleColor?
    /// The colour behind the pattern. Ignored for `.solid`.
    public var background: StyleColor?

    public init(pattern: Pattern = .none, foreground: StyleColor? = nil, background: StyleColor? = nil) {
        self.pattern = pattern
        self.foreground = foreground
        self.background = background
    }

    /// No fill.
    public static let none = FillStyle()

    /// A flat colour.
    public static func solid(_ color: StyleColor) -> FillStyle {
        FillStyle(pattern: .solid, foreground: color)
    }

    /// The colour actually painted, or `nil` when nothing is.
    public var effectiveColor: StyleColor? {
        switch pattern {
        case .none: nil
        case .solid: foreground
        default: foreground ?? background
        }
    }
}

/// One edge of a cell's border.
public struct BorderEdge: Sendable, Hashable, Codable {
    /// The fourteen border weights xlsx defines. `hair` is thinner than `thin`; the renderer
    /// maps these to point widths rather than treating them as an ordered scale.
    public enum LineStyle: String, Sendable, Hashable, Codable, CaseIterable {
        case none, thin, medium, thick, double, hair, dotted, dashed
        case dashDot, dashDotDot, mediumDashed, mediumDashDot, mediumDashDotDot, slantDashDot
    }

    /// How this edge is drawn, or ``LineStyle/none`` for not at all.
    public var style: LineStyle
    /// `nil` means the automatic border colour, which is not the same as black.
    public var color: StyleColor?

    public init(style: LineStyle = .none, color: StyleColor? = nil) {
        self.style = style
        self.color = color
    }

    /// Nothing drawn.
    public static let none = BorderEdge()

    /// Whether this edge draws anything.
    public var isVisible: Bool { style != .none }
}

/// A cell's four edges plus its diagonals.
public struct BorderStyle: Sendable, Hashable, Codable {
    public var top: BorderEdge
    /// The *start* edge, which is the right-hand one on a right-to-left sheet. xlsx calls this
    /// `left`; naming it by writing direction is what makes ``Sheet/isRightToLeft`` work
    /// without a second set of fields.
    public var leading: BorderEdge
    public var bottom: BorderEdge
    /// The *end* edge. See ``leading``.
    public var trailing: BorderEdge
    /// Drawn across the cell, in the directions given by ``diagonalUp`` and ``diagonalDown``.
    public var diagonal: BorderEdge
    /// Whether ``diagonal`` runs bottom-left to top-right.
    public var diagonalUp: Bool
    /// Whether ``diagonal`` runs top-left to bottom-right. Both can be true.
    public var diagonalDown: Bool

    public init(
        top: BorderEdge = .none,
        leading: BorderEdge = .none,
        bottom: BorderEdge = .none,
        trailing: BorderEdge = .none,
        diagonal: BorderEdge = .none,
        diagonalUp: Bool = false,
        diagonalDown: Bool = false
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
        self.diagonal = diagonal
        self.diagonalUp = diagonalUp
        self.diagonalDown = diagonalDown
    }

    /// No borders.
    public static let none = BorderStyle()

    /// Whether any edge draws.
    public var isVisible: Bool {
        top.isVisible || leading.isVisible || bottom.isVisible || trailing.isVisible || diagonal.isVisible
    }
}

/// Where content sits inside a cell.
public struct CellAlignment: Sendable, Hashable, Codable {
    /// `general` is the important one: it means "right for numbers, left for text, centred for
    /// booleans and errors", resolved per value rather than per cell. Anything that renders a
    /// cell has to implement that rule; people rely on the alignment telling them a column is
    /// really numeric.
    public enum Horizontal: String, Sendable, Hashable, Codable, CaseIterable {
        case general, left, center, right, fill, justify, centerContinuous, distributed
    }

    /// Excel's default is ``bottom``, not ``center`` — worth knowing before "fixing" a sheet
    /// that looks misaligned.
    public enum Vertical: String, Sendable, Hashable, Codable, CaseIterable {
        case top, center, bottom, justify, distributed
    }

    /// See ``Horizontal`` — ``Horizontal/general`` resolves per value, not per cell.
    public var horizontal: Horizontal
    public var vertical: Vertical
    /// Wrapping changes the row's natural height, so the renderer has to measure before it lays out.
    public var wrapText: Bool
    /// Indent steps, each roughly three characters wide.
    public var indent: Int
    /// Degrees, `-90...90`. The value `255` in the file means stacked-vertical text and is
    /// preserved as-is rather than mapped into the angle range.
    public var textRotation: Int
    /// Scale the text down to fit rather than clipping it. Mutually exclusive with ``wrapText``
    /// in Excel's UI, though a file can set both.
    public var shrinkToFit: Bool
    /// `0` context-dependent, `1` left-to-right, `2` right-to-left.
    public var readingOrder: Int

    public init(
        horizontal: Horizontal = .general,
        vertical: Vertical = .bottom,
        wrapText: Bool = false,
        indent: Int = 0,
        textRotation: Int = 0,
        shrinkToFit: Bool = false,
        readingOrder: Int = 0
    ) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.wrapText = wrapText
        self.indent = indent
        self.textRotation = textRotation
        self.shrinkToFit = shrinkToFit
        self.readingOrder = readingOrder
    }

    /// General / bottom / no wrap — what an unstyled cell gets.
    public static let `default` = CellAlignment()
}

/// Everything about how one cell looks, flattened.
///
/// xlsx stores this as five parallel index tables (`fonts`, `fills`, `borders`, `numFmts`,
/// `cellXfs`) and a cell points at a `cellXfs` row that points at all the others. That
/// indirection is right for a file and wrong for an inspector panel, a renderer, or an MCP
/// `set_format` call — all of which want to ask "is this bold?" without three lookups.
///
/// So the model flattens, and `SheetFormat` re-derives the index tables on write. The one piece
/// left as an index is ``numberFormatID``, because the built-in formats (ids 0–49) are implicit
/// and never appear in the file at all — see ``StyleTable/numberFormat(id:)``.
public struct CellStyle: Sendable, Hashable, Codable {
    /// Index into the workbook's number-format table. `0` is `General`.
    public var numberFormatID: Int32
    public var font: FontStyle
    public var fill: FillStyle
    public var border: BorderStyle
    /// Where content sits in the cell. ``CellAlignment/Horizontal/general`` — the default —
    /// means the answer depends on the value, not on the style.
    public var alignment: CellAlignment

    /// Whether this cell is locked when the sheet is protected. We do not enforce protection;
    /// this exists so it round-trips.
    public var isLocked: Bool

    /// Whether the formula is hidden when the sheet is protected. Also round-trip only.
    public var isFormulaHidden: Bool

    /// The cell's content was entered with a leading `'` to force it to be text.
    ///
    /// Load-bearing on write: without it, a cell holding the text `00123` or `=NOT A FORMULA`
    /// comes back as a number or an error next time the file opens (PLAN.md §8).
    public var quotePrefix: Bool

    public init(
        numberFormatID: Int32 = 0,
        font: FontStyle = .default,
        fill: FillStyle = .none,
        border: BorderStyle = .none,
        alignment: CellAlignment = .default,
        isLocked: Bool = true,
        isFormulaHidden: Bool = false,
        quotePrefix: Bool = false
    ) {
        self.numberFormatID = numberFormatID
        self.font = font
        self.fill = fill
        self.border = border
        self.alignment = alignment
        self.isLocked = isLocked
        self.isFormulaHidden = isFormulaHidden
        self.quotePrefix = quotePrefix
    }

    /// General format, Calibri 11, no fill, no borders. `isLocked` is `true` because that is
    /// Excel's default, odd as it looks — locking only takes effect on a protected sheet.
    public static let `default` = CellStyle()
}
