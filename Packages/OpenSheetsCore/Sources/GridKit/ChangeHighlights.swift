import SheetModel

/// Persistent per-sheet change tints, drawn under selection and flash. Unlike
/// ``FlashState`` this does not decay; it is standing state until the baseline moves.
///
/// # Why this is separate from the flash
///
/// The two answer different questions. The flash answers *"what just happened?"* and fades,
/// which is why it owns a clock and a display link. This answers *"what has changed since the
/// baseline I chose?"* — a question whose answer is only allowed to change when the baseline
/// or the workbook does. Folding them into one type would give the standing state a decay
/// curve it must never have, and give the flash a lifetime nothing turns off.
///
/// Colour semantics are fixed and mean the same thing everywhere in the app: green added,
/// amber value-or-formula changed, red removed. Style-only changes are deliberately absent —
/// a recoloured cell is not a changed number, and tinting it would spend the user's attention
/// on the one kind of change they did not ask about.
///
/// Whole inserted rows and columns arrive as ``insertedRows``/``insertedColumns`` rather than
/// as a million individual refs: a band is one rectangle to draw and one integer to store,
/// and the alternative is a set the size of the sheet. Deleted rows and columns are not here
/// at all — there is no row left to tint, so they are reported in the changes panel instead.
public struct ChangeHighlights: Sendable, Equatable {
    /// Cells that did not exist at the baseline. Tinted green.
    public var added: Set<CellRef> { didSet { recomputeBounds() } }
    /// Cells whose value or formula differs from the baseline. Tinted amber.
    public var modified: Set<CellRef> { didSet { recomputeBounds() } }
    /// Cells that existed at the baseline and do not now. Tinted red, on the empty rectangle
    /// they used to occupy.
    public var removed: Set<CellRef> { didSet { recomputeBounds() } }
    /// 0-based indices of rows inserted since the baseline; each gets a light band across its
    /// whole visible width.
    public var insertedRows: Set<Int>
    /// 0-based indices of inserted columns, banded the same way.
    public var insertedColumns: Set<Int>

    /// The rectangle covering every tinted cell, or `nil` when there are none.
    ///
    /// The renderer intersects this with what is on screen before it iterates anything, which is
    /// what keeps a three-cell diff from costing a screenful of set probes on every frame of a
    /// fling — the same trick, and the same reason, as ``FlashState/affectedRange``. It is
    /// maintained on write rather than computed on read because a frame must never pay for it.
    private(set) var cellBounds: CellRange?

    public init(
        added: Set<CellRef> = [],
        modified: Set<CellRef> = [],
        removed: Set<CellRef> = [],
        insertedRows: Set<Int> = [],
        insertedColumns: Set<Int> = []
    ) {
        self.added = added
        self.modified = modified
        self.removed = removed
        self.insertedRows = insertedRows
        self.insertedColumns = insertedColumns
        cellBounds = nil
        recomputeBounds()
    }

    /// Nothing highlighted. The default, and the value the grid draws at zero cost.
    public static let none = ChangeHighlights()

    /// Whether anything at all is highlighted.
    public var isEmpty: Bool {
        added.isEmpty && modified.isEmpty && removed.isEmpty
            && insertedRows.isEmpty && insertedColumns.isEmpty
    }

    /// How many individual cells carry a tint, ignoring bands.
    var cellCount: Int { added.count + modified.count + removed.count }

    /// Whether `ref` sits in an inserted row or column, and so is covered by a band already.
    func isBanded(_ ref: CellRef) -> Bool {
        insertedRows.contains(ref.row) || insertedColumns.contains(ref.column)
    }

    private mutating func recomputeBounds() {
        var bounds: CellRange?
        func absorb(_ refs: Set<CellRef>) {
            for ref in refs {
                let box = CellRange(ref)
                bounds = bounds?.union(box) ?? box
            }
        }
        absorb(added)
        absorb(modified)
        absorb(removed)
        cellBounds = bounds
    }
}
