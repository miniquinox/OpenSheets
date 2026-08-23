import Foundation

/// Behaviour switches that are not colours, and are therefore not the theme's business.
public struct GridOptions: Sendable, Equatable {
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
        showsFillHandle: Bool = true
    ) {
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
