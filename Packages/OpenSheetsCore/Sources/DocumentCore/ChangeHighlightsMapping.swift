import GridKit
import SheetModel

/// What the grid should paint for one sheet's share of a baseline diff — and, when the honest
/// answer is *nothing*, why.
///
/// # Why a result type rather than a plain ``GridKit/ChangeHighlights``
///
/// Because "paint nothing" and "there is nothing to paint" look identical to a renderer and are
/// opposite news to a person. The chip can be reading `+40,000 ~12,000` at the moment this
/// returns ``GridKit/ChangeHighlights/none``, and a grid that is silently unpainted underneath
/// that number is the app telling two different stories at once. So the decision is made here,
/// once, and carried out of here as a fact the panel can read and say out loud.
///
/// # The density cap (PLAN.md §1.3)
///
/// Washing a translucent tint over a viewport-full of cells costs about 8.3 ms a frame. T3
/// measured one viewport-sized fill, 544 per-cell fills, and a batched `fill([CGRect])` and
/// found all three within 3% of each other; the same area filled *opaquely* costs 0.44 ms. The
/// cost is the alpha blend and the memory bandwidth it eats, so no iteration strategy fixes it
/// — the only fix is to draw less. That is fine when an agent changed forty cells and fatal when
/// it rewrote the sheet, and "Claude rewrote the whole sheet" is a core scenario for this
/// product rather than an edge case. Unlike the select-all wash, which costs the same and is
/// gone the moment the user clicks, these tints are standing state the user *scrolls through
/// while reviewing*.
///
/// It is also the better interface, which is the part that would justify it even on a machine
/// with infinite fill rate: when every cell is green, green has stopped meaning anything. Above
/// the cap the honest statement is one sentence in the panel, not a million rectangles.
///
/// The decision belongs here and never in the renderer. The renderer stays a renderer — it
/// draws what it is handed — and the shell keeps the ability to *say* what it did.
public struct ChangeHighlightsMapping: Sendable, Equatable {
    /// The tints the renderer draws. Always ``GridKit/ChangeHighlights/none`` when
    /// ``suppression`` is set.
    public var highlights: ChangeHighlights

    /// Why the grid is not painting, or `nil` when it is.
    public var suppression: Suppression?

    /// How many cells would have carried a wash, counting a banded row or column as every cell
    /// it covers inside ``consideredCellCount``'s region. The numerator of ``density``.
    public var washedCellCount: Int

    /// The sheet's used range, widened to cover any cell the diff names outside it — removed
    /// cells live exactly there, and a denominator that excluded them would make deleting a
    /// block look denser than it is. The denominator of ``density``.
    public var consideredCellCount: Int

    /// Why per-cell highlights are off.
    ///
    /// Two reasons rather than one because the panel says different sentences for them: one is
    /// *"most of this sheet changed"*, the other is *"we stopped counting"*.
    public enum Suppression: Sendable, Equatable, Hashable {
        /// More than ``ChangeHighlightsMapping/maxHighlightDensity`` of the sheet changed.
        case density
        /// ``SheetModel/WorkbookDiff/wasTruncated`` — the comparison gave up before it finished.
        /// The changes it did name are a sample, not a list, and tinting a sample would claim a
        /// completeness the diff does not have: the user would read an untinted cell as unchanged.
        case truncatedDiff
    }

    public init(
        highlights: ChangeHighlights = .none,
        suppression: Suppression? = nil,
        washedCellCount: Int = 0,
        consideredCellCount: Int = 0
    ) {
        self.highlights = highlights
        self.suppression = suppression
        self.washedCellCount = washedCellCount
        self.consideredCellCount = consideredCellCount
    }

    /// Nothing to paint, and nothing to explain.
    public static let none = ChangeHighlightsMapping()

    /// Whether the grid is deliberately unpainted, so the panel can say so.
    ///
    /// True for ``Suppression/truncatedDiff`` as well as ``Suppression/density``: both mean
    /// *there were too many changes to draw honestly*, which is the one thing the panel has to
    /// tell the user, and a second flag would only invite a caller to handle one and forget the
    /// other. ``suppression`` carries which, for the wording.
    public var isSuppressedByDensity: Bool { suppression != nil }

    /// The share of the sheet that changed, `0 ... 1`. Zero when there is nothing to divide.
    public var density: Double {
        guard consideredCellCount > 0 else { return 0 }
        return Double(washedCellCount) / Double(consideredCellCount)
    }

    /// The share of a sheet that may be tinted before the tints stop being worth drawing.
    ///
    /// 0.35 rather than a rounder number for a reason that is about reading rather than about
    /// milliseconds: a third of a screen carrying colour still has enough uncoloured ground
    /// around it for the colour to point at something. Past that the eye reads the tint as the
    /// background and the untinted cells as the highlights, which is the opposite of the answer.
    /// The frame cost happens to fall off the same cliff, so one number serves both.
    public static let maxHighlightDensity = 0.35
}

public extension WorkbookDiff {
    /// One sheet's changes, as tints — or as a stated refusal to tint.
    ///
    /// Style-only changes are absent by design (PLAN.md §1.3): a recoloured cell is not a
    /// changed number, and tinting it spends the user's attention on the one kind of change they
    /// did not ask about. Deleted rows and columns are absent too — there is no row left to
    /// tint, so they are the panel's news, not the grid's.
    ///
    /// Cells inside an inserted row stay in ``GridKit/ChangeHighlights/added``. The renderer
    /// skips their per-cell green because the band already says it (`GridRenderer.changeTint`),
    /// and dropping them here instead would take them out of the diff's own bounding box — which
    /// is what the renderer intersects with the viewport before it iterates anything. They are
    /// counted once, as band area, for ``ChangeHighlightsMapping/density``.
    ///
    /// - Parameters:
    ///   - sheetID: the sheet on screen.
    ///   - workbook: the *current* workbook, for the used range that forms the density
    ///     denominator. The diff alone cannot supply it: it knows what moved, not how big the
    ///     sheet it moved in is, and forty changes mean something different in a 4×3 sheet than
    ///     in a 40,000-row one.
    ///   - maxDensity: overridable so a test can drive the cap from both sides without building
    ///     a sheet the size of the threshold.
    func changeHighlights(
        for sheetID: SheetID,
        in workbook: Workbook,
        maxDensity: Double = ChangeHighlightsMapping.maxHighlightDensity
    ) -> ChangeHighlightsMapping {
        // A sheet that appeared or vanished whole. The differ reports it as a summary rather
        // than as cell changes — there is no per-cell list to map — and every one of its cells
        // is a change, so it is over any threshold by construction. Saying so is the point: the
        // chip counts those cells (`BaselineTracker.counts`), and a grid that went quiet without
        // a word next to a five-figure count is the exact failure this type exists to prevent.
        let wholeSheet = addedSheets.first(where: { $0.id == sheetID })
            ?? removedSheets.first(where: { $0.id == sheetID })
        if let wholeSheet {
            guard wholeSheet.cellCount > 0 else { return .none }
            return ChangeHighlightsMapping(
                suppression: .density,
                washedCellCount: wholeSheet.cellCount,
                consideredCellCount: wholeSheet.cellCount
            )
        }

        guard let sheetDiff = sheetDiffs.first(where: { $0.sheetID == sheetID }) else { return .none }

        var added: Set<CellRef> = []
        var modified: Set<CellRef> = []
        var removed: Set<CellRef> = []
        var changedBounds: CellRange?

        for change in sheetDiff.cellChanges {
            switch change.kind {
            case .added: added.insert(change.ref)
            case .valueChanged, .formulaChanged: modified.insert(change.ref)
            case .removed: removed.insert(change.ref)
            case .styleChanged: continue
            }
            let box = CellRange(change.ref)
            changedBounds = changedBounds?.union(box) ?? box
        }

        var insertedRows: Set<Int> = []
        var insertedColumns: Set<Int> = []
        for structural in sheetDiff.structuralChanges {
            guard structural.index >= 0, structural.count >= 1 else { continue }
            let span = structural.index ..< (structural.index + structural.count)
            switch structural.kind {
            case .insertedRows: insertedRows.formUnion(span)
            case .insertedColumns: insertedColumns.formUnion(span)
            case .deletedRows, .deletedColumns: continue
            }
        }

        let highlights = ChangeHighlights(
            added: added,
            modified: modified,
            removed: removed,
            insertedRows: insertedRows,
            insertedColumns: insertedColumns
        )
        guard !highlights.isEmpty else { return .none }

        // The region the user is reviewing: what is in the sheet now, plus wherever the diff
        // points outside it. Bands are clipped into this rather than allowed to widen it — an
        // inserted row at index 500 of a four-row sheet is one stripe over empty space, not
        // proof that the sheet is five hundred rows tall.
        let region = (workbook[sheetID]?.usedRange).map { used in
            changedBounds.map { used.union($0) } ?? used
        } ?? changedBounds

        let washed = region.map { region in
            let bandedRows = insertedRows.count { region.rows.contains($0) }
            let bandedColumns = insertedColumns.count { region.columns.contains($0) }
            // Inclusion–exclusion: the cells where a banded row crosses a banded column would
            // otherwise be counted twice.
            let banded = bandedRows * region.columnCount
                + bandedColumns * region.rowCount
                - bandedRows * bandedColumns
            let loose = [added, modified, removed].reduce(0) { total, refs in
                total + refs.count { !insertedRows.contains($0.row) && !insertedColumns.contains($0.column) }
            }
            return banded + loose
        } ?? 0
        let considered = region?.cellCount ?? 0

        guard !wasTruncated else {
            return ChangeHighlightsMapping(
                suppression: .truncatedDiff,
                washedCellCount: washed,
                consideredCellCount: considered
            )
        }

        let mapped = ChangeHighlightsMapping(
            highlights: highlights,
            washedCellCount: washed,
            consideredCellCount: considered
        )
        guard mapped.density <= maxDensity else {
            return ChangeHighlightsMapping(
                suppression: .density,
                washedCellCount: washed,
                consideredCellCount: considered
            )
        }
        return mapped
    }
}

public extension DocumentModel {
    /// The tints for the sheet on screen, honouring the global highlight switch.
    ///
    /// Depends on ``DocumentModel/baselineDiff``, which is observed, and deliberately **not** on
    /// ``DocumentModel/workbookGeneration``, which is `@ObservationIgnored` — reading the
    /// generation would give a view a cache key, not an invalidation trigger, and a grid that
    /// only repainted when something *else* changed would show yesterday's tints.
    ///
    /// Computed on demand rather than cached on the model. The per-sheet change list is capped
    /// at `Limits.maxDiffCellChanges`, so the walk is bounded by a constant rather than by the
    /// size of the sheet, and a cache here would need invalidating from three places that all
    /// live in another agent's file.
    ///
    /// With highlighting switched off this is ``ChangeHighlightsMapping/none`` and carries no
    /// suppression: the user turned the tints off, which is not news the panel should report as
    /// the app's decision.
    var activeChangeHighlights: ChangeHighlightsMapping {
        guard isChangeHighlightingEnabled, let diff = baselineDiff else { return .none }
        return diff.changeHighlights(for: activeSheetID, in: workbook)
    }
}
