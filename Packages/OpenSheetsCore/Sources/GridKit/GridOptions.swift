import Foundation

/// Space the shell reserves inside the grid, in points.
///
/// Its own type rather than `NSEdgeInsets` so this file stays free of AppKit, and so the value is
/// `Equatable` — ``GridRenderModel`` is compared field by field to decide whether a frame can be
/// skipped, and a member that cannot be compared would quietly force a redraw on every update.
public struct GridInsets: Sendable, Equatable, Hashable {
    public var top: Double
    public var left: Double
    public var bottom: Double
    public var right: Double

    public init(top: Double = 0, left: Double = 0, bottom: Double = 0, right: Double = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    public static let zero = GridInsets()

    public var isZero: Bool { self == .zero }
}

/// Behaviour switches that are not colours, and are therefore not the theme's business.
public struct GridOptions: Sendable, Equatable {
    /// Space the shell has taken from the grid's viewport, on top of the headers and the frozen
    /// band the grid reserves for itself.
    ///
    /// Two uses, and they are the same mechanism (PLAN.md §3.1):
    ///
    /// - **Chrome bleed.** The window's toolbar and formula bar are translucent, so the grid's
    ///   frame runs *under* them and a top inset holds the first row clear of them. Cells pass
    ///   beneath the glass as you scroll — which is what gives the lens something real to refract
    ///   — and no cell is ever permanently unreachable, because the inset is scroll range rather
    ///   than a mask.
    /// - **Floating surfaces.** The stats pill and the sync pill sit in the grid's bottom corners.
    ///   A bottom inset subtracts their height from the scroll range, so the last row can always
    ///   be scrolled above them instead of living under them.
    ///
    /// The grid folds this into the insets it already computes for the row and column headers, so
    /// the shell never has to know they exist — setting `NSScrollView.contentInsets` from outside
    /// destroys the header offsets, which is exactly what an earlier attempt at this did.
    public var contentInsets: GridInsets

    /// Overrides ``Sheet/showsGridlines``. `nil` follows the file, which is what a dashboard
    /// sheet with gridlines turned off expects.
    public var showsGridlines: Bool?

    /// Alternating row banding. **Off by default**: real workbooks bring their own fills, and
    /// banding underneath them reads as a rendering bug.
    public var showsAlternatingRows: Bool

    /// Whether the row and column headers are drawn at all.
    public var showsHeaders: Bool

    /// Excel's `⌃\``: show formula source instead of cached values.
    public var showsFormulas: Bool

    /// Whether clicks may start an edit. A read-only workbook (`ReadOnlyReason`) sets this false.
    public var isEditable: Bool

    /// How much beyond the visible rect to prepare, in screenfuls. One screen in the scroll
    /// direction is what `preparedContentRect` wants: enough that a fling never reveals unpainted
    /// canvas, little enough that the overdraw is not the frame budget.
    public var overdrawScreens: Double

    /// Whether the fill handle is drawn and draggable.
    public var showsFillHandle: Bool

    public init(
        showsGridlines: Bool? = nil,
        showsAlternatingRows: Bool = false,
        showsHeaders: Bool = true,
        showsFormulas: Bool = false,
        isEditable: Bool = true,
        overdrawScreens: Double = 1,
        showsFillHandle: Bool = true,
        contentInsets: GridInsets = .zero
    ) {
        self.contentInsets = contentInsets
        self.showsGridlines = showsGridlines
        self.showsAlternatingRows = showsAlternatingRows
        self.showsHeaders = showsHeaders
        self.showsFormulas = showsFormulas
        self.isEditable = isEditable
        self.overdrawScreens = overdrawScreens
        self.showsFillHandle = showsFillHandle
    }

    public static let `default` = GridOptions()
}
