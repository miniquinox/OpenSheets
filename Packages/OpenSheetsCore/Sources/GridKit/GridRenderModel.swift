import CoreGraphics
import Foundation
import SheetModel

/// Everything the renderer reads, gathered into one value.
///
/// Passing a struct rather than a dozen arguments is not tidiness: it makes "did anything
/// change?" a single `==`, which is what lets the view skip a redraw, and it makes a frame
/// reproducible in a test from a value you can build by hand.
public struct GridRenderModel: Sendable {
    /// The sheet being drawn. A value type, so the renderer can never see a half-applied edit.
    public var sheet: Sheet
    /// The workbook's styles.
    public var styles: StyleTable
    /// 1900 or 1904, for date formats.
    public var dateSystem: DateSystem
    public var theme: GridTheme
    public var options: GridOptions
    public var geometry: GridGeometry
    /// Prebuilt from ``Sheet/merges`` — see ``MergeIndex`` for why it is not looked up directly.
    public var merges: MergeIndex
    public var selection: GridSelection
    /// The "Claude changed this" tints, and the moment to evaluate them at.
    public var flash: FlashState
    public var flashTime: Double
    /// Whether the grid has keyboard focus. An unfocused selection draws greyer, as everywhere
    /// else on the platform.
    public var isFocused: Bool

    public init(
        sheet: Sheet,
        styles: StyleTable,
        dateSystem: DateSystem = .excel1900,
        theme: GridTheme = .light,
        options: GridOptions = .default,
        geometry: GridGeometry? = nil,
        merges: MergeIndex? = nil,
        selection: GridSelection = GridSelection(),
        flash: FlashState = FlashState(),
        flashTime: Double = 0,
        isFocused: Bool = true
    ) {
        self.sheet = sheet
        self.styles = styles
        self.dateSystem = dateSystem
        self.theme = theme
        self.options = options
        self.geometry = geometry ?? GridGeometry(sheet: sheet)
        self.merges = merges ?? MergeIndex(sheet.merges)
        self.selection = selection
        self.flash = flash
        self.flashTime = flashTime
        self.isFocused = isFocused
    }

    /// Whether gridlines are drawn: the option wins, then the file's own setting.
    public var drawsGridlines: Bool {
        options.showsGridlines ?? sheet.showsGridlines
    }

    /// Why an edit at `ref` must be refused, or `nil` when it may go ahead.
    ///
    /// Delegates to ``SheetModel/Sheet/editRefusal(at:)``, which is where the rule lives now that
    /// the formula bar asks it too. Kept here because every call site inside the grid already has
    /// a render model and nothing else.
    public func editRefusal(at ref: CellRef) -> SheetError? {
        sheet.editRefusal(at: ref)
    }

    /// The spill or array region `ref` takes part in, for the outline the renderer draws.
    public func spillRegion(at ref: CellRef) -> CellRange? {
        sheet.spillOwner(of: ref)?.region
    }

    /// What the formula bar should show for `ref`.
    ///
    /// A spilled-into cell shows the anchor's formula, because that is what produced the
    /// number in it — showing the number instead invites the user to retype it, which is the
    /// edit that has to be refused. ``isEditable`` is `false` for exactly those cells.
    public func formulaBarText(at ref: CellRef) -> (text: String, isEditable: Bool) {
        let formatter = CellFormatter(styles: styles, dateSystem: dateSystem, theme: theme)
        guard let owner = sheet.spillOwner(of: ref), owner.owns(ref) else {
            return (formatter.editText(of: sheet.cells[ref]), true)
        }
        return (formatter.editText(of: sheet.cells[owner.anchor]), false)
    }

    /// The style that applies at a cell — its own, then the row's, then the column's, which is
    /// Excel's precedence and the reason an empty cell in a currency column still looks like money.
    public func effectiveStyleID(at ref: CellRef, cell: Cell?) -> StyleID {
        if let cell, cell.styleID != .default { return cell.styleID }
        let rowStyle = sheet.rowStyles[ref.row]
        if rowStyle != .default { return rowStyle }
        return sheet.columnStyles[ref.column]
    }
}

/// The theme's colours converted to `CGColor` once, instead of once per cell per frame.
///
/// `CGColor` creation allocates. Doing it inside the draw loop is a few thousand allocations a
/// frame, which is both the cost itself and the memory-growth graph that follows it.
struct ResolvedPalette {
    let canvas: CGColor
    let alternating: CGColor
    let gridline: CGColor
    let cellText: CGColor
    let errorText: CGColor
    let staleUnderline: CGColor
    let externalLink: CGColor
    let accent: CGColor
    let selectionFill: CGColor
    let inactiveSelectionFill: CGColor
    let fillHandleBorder: CGColor
    let headerBackground: CGColor
    let headerText: CGColor
    let headerSeparator: CGColor
    let headerSelected: CGColor
    let headerSelectedText: CGColor
    let headerActive: CGColor
    let headerActiveText: CGColor
    let frozenDivider: CGColor
    let frozenShadow: CGColor
    let flashTint: CGColor
    let unfocusedSelection: CGColor

    init(_ theme: GridTheme) {
        canvas = theme.canvasBackground.cgColor
        alternating = theme.alternatingRowBackground.cgColor
        gridline = theme.gridline.cgColor
        cellText = theme.cellText.cgColor
        errorText = theme.errorText.cgColor
        staleUnderline = theme.staleCacheUnderline.cgColor
        externalLink = theme.externalLinkMarker.cgColor
        accent = theme.accent.cgColor
        selectionFill = theme.accent.withOpacity(theme.selectionFillOpacity).cgColor
        inactiveSelectionFill = theme.accent.withOpacity(theme.inactiveRangeFillOpacity).cgColor
        fillHandleBorder = theme.fillHandleBorder.cgColor
        headerBackground = theme.headerBackground.cgColor
        headerText = theme.headerText.cgColor
        headerSeparator = theme.headerSeparator.cgColor
        headerSelected = theme.headerSelectedBackground.cgColor
        headerSelectedText = theme.headerSelectedText.cgColor
        headerActive = theme.headerActiveBackground.cgColor
        headerActiveText = theme.headerActiveText.cgColor
        frozenDivider = theme.frozenDivider.cgColor
        frozenShadow = theme.frozenDividerShadow.cgColor
        flashTint = theme.flashTint.cgColor
        // A background selection is grey rather than accent, matching every other list on macOS.
        unfocusedSelection = RGBAColor(red: 128, green: 128, blue: 128, alpha: 150).cgColor
    }
}
