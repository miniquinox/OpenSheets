import Foundation
import GlassUI
import GridKit
import SheetModel
import SheetStore

/// Turns A6's `WorkbookDiff` and `DocumentSyncState` into the values A5's surfaces render.
///
/// The two halves were built against each other's *ideas*, not each other's types, which is what
/// let them be built at the same time. This is where they meet, and it is the only place that
/// knows both. Two things happen here that could not happen on either side:
///
/// - **Values are formatted with the cell's own number format.** A5's `CellChange` takes
///   `String`s precisely so the diff can read `120 → 129.6` in the workbook's own currency rather
///   than in Swift's `Double` description. Only the app holds the `StyleTable`.
/// - **The list is capped.** A 10,000-cell diff is not a list, it is a scroll bar. The panel gets
///   `Limits.maxDiffCellChanges` rows and an honest `+ 9,750 more`.
public enum SyncPresentation {
    /// The number of rows the panel lists before it starts counting instead.
    public static let listedChangeLimit = 200

    /// The whole diff panel, from a diff and the workbook the values belong to.
    ///
    /// - Parameter workbook: the version whose styles format the numbers. For a `STALE` or
    ///   `CONFLICT` diff this is what is on screen; the disk version's own styles may differ, and
    ///   using the on-screen ones is right — the user is comparing against what they can see.
    public static func changeSet(
        for diff: WorkbookDiff,
        workbook: Workbook,
        state: DocumentSyncState,
        localEditCount: Int,
        isWatching: Bool,
        wasRediffed: Bool = false
    ) -> FileChangeSet {
        let formatter = ValueFormatter(workbook: workbook)
        var rows: [GlassUI.CellChange] = []
        var omitted = diff.sheetDiffs.reduce(0) { $0 + $1.omittedCellChangeCount }

        for sheetDiff in diff.sheetDiffs {
            for change in sheetDiff.cellChanges {
                guard rows.count < listedChangeLimit else {
                    omitted += 1
                    continue
                }
                rows.append(
                    GlassUI.CellChange(
                        sheetName: sheetDiff.sheetName,
                        ref: change.ref,
                        before: formatter.text(change.before, sheet: sheetDiff.sheetID, ref: change.ref),
                        after: formatter.text(change.after, sheet: sheetDiff.sheetID, ref: change.ref),
                        kind: kind(change.kind)
                    )
                )
            }
        }

        var summaries = diff.sheetDiffs.map { sheetDiff in
            SheetChangeSummary(
                name: sheetDiff.sheetName,
                changedCount: sheetDiff.changedCount,
                addedCount: sheetDiff.addedCount,
                removedCount: sheetDiff.removedCount,
                renamedFrom: diff.renamedSheets.first { $0.id == sheetDiff.sheetID }?.before
            )
        }
        // A rename with no cell changes still has to appear, or the panel says "1 sheet" and lists
        // nothing — which reads as a bug in the diff rather than as a rename.
        for rename in diff.renamedSheets where !summaries.contains(where: { $0.name == rename.after }) {
            summaries.append(SheetChangeSummary(name: rename.after, renamedFrom: rename.before))
        }
        for added in diff.addedSheets {
            summaries.append(SheetChangeSummary(name: added.name, addedCount: added.cellCount))
        }

        return FileChangeSet(
            notice: notice(
                for: diff,
                state: state,
                localEditCount: localEditCount,
                isWatching: isWatching
            ),
            sheets: summaries,
            changes: rows,
            truncatedCount: omitted,
            wasRediffed: wasRediffed
        )
    }

    /// The pill's own text.
    public static func notice(
        for diff: WorkbookDiff,
        state: DocumentSyncState,
        localEditCount: Int,
        isWatching: Bool
    ) -> RefreshNotice {
        let isConflict = state == .conflict || localEditCount > 0
        return RefreshNotice(
            signal: isConflict ? .conflict : .agent,
            headline: isConflict ? "Conflict" : "Changed on disk",
            sheetCount: diff.changedSheetCount,
            cellCount: diff.totalCellChangeCount,
            localEditCount: isConflict ? localEditCount : 0,
            shortcut: isConflict ? nil : "⌘R",
            isWatching: isWatching
        )
    }

    /// The titlebar chip.
    public static func chip(
        for state: DocumentSyncState,
        pendingCellCount: Int,
        localEditCount: Int,
        readOnlyReason: ReadOnlyReason?
    ) -> GlassUI.SyncState {
        switch state {
        case .synced: .watching
        case .stale: .stale(cellCount: pendingCellCount)
        case .reloading: .watching
        case .dirty: .dirty(localEdits: localEditCount)
        case .conflict: .conflict(localEdits: localEditCount)
        case .missing: .missing
        case .locked: .locked(holder: nil)
        case .readOnly: .readOnly(reason: (readOnlyReason ?? .fileSystemPermissions).message)
        case .unreadable: .readOnly(reason: "OpenSheets could not read this file.")
        }
    }

    /// The designed state that fills the window when the document cannot show a grid.
    ///
    /// `nil` means "show the grid". Every blocked state has one; PLAN.md §1.4 forbids an alert
    /// dump, and this is the list that makes that a compile-time-visible promise rather than a
    /// good intention.
    public static func emptyState(
        for state: DocumentSyncState,
        fileName: String,
        sheetCount: Int,
        readOnlyReason: ReadOnlyReason?,
        lastError: SheetError?
    ) -> EmptyStateModel? {
        switch state {
        case .missing:
            return .fileMissing(name: fileName)
        case .locked:
            return .fileLocked(holder: nil)
        case .unreadable:
            if case .workbookEncrypted = lastError { return .passwordProtected }
            return .unreadable(detail: lastError.map { "\($0.code): \($0.message)" })
        case .synced, .stale, .reloading, .dirty, .conflict, .readOnly:
            // Read-only is a banner, not a blank window: the workbook is right there and the
            // whole point of opening it read-only was to look at it.
            return sheetCount == 0 ? .noSheets : nil
        }
    }

    /// One line in the sidebar's session feed.
    public static func feedEntry(
        for diff: WorkbookDiff,
        at date: Date,
        id: String,
        formatter: DateFormatter
    ) -> SessionFeedEntry {
        let sheet = diff.sheetDiffs.max { $0.totalCellChangeCount < $1.totalCellChangeCount }
        return SessionFeedEntry(
            id: id,
            timestamp: formatter.string(from: date),
            summary: diff.summary,
            sheetName: sheet?.sheetName,
            cellCount: diff.totalCellChangeCount,
            signal: .agent
        )
    }

    private static func kind(_ kind: SheetModel.CellChange.Kind) -> GlassUI.CellChange.Kind {
        switch kind {
        case .added: .added
        case .removed: .removed
        case .valueChanged, .formulaChanged, .styleChanged: .changed
        }
    }
}

/// Formats a diffed cell the way the grid would show it.
///
/// Public because the diff panel is no longer the only surface that reports `120 → 129.6`: the
/// changes panel (plan §1.2 step 7) does too, from the app target, which cannot see an `internal`
/// type. It was briefly copied there instead, and two formatters for one question is how a
/// currency cell ends up reading `$1,200` in one panel and `1200` in the other.
public struct ValueFormatter {
    private let workbook: Workbook
    private let formatters: [SheetID: CellFormatter]

    public init(workbook: Workbook) {
        self.workbook = workbook
        var built: [SheetID: CellFormatter] = [:]
        for sheet in workbook.sheets {
            built[sheet.id] = CellFormatter(
                styles: workbook.styles,
                dateSystem: workbook.meta.dateSystem,
                theme: .light
            )
        }
        formatters = built
    }

    /// The display text for a cell, or an empty string when there was no cell — which A5 renders
    /// as an em dash rather than as blank, so an added cell's "before" column is not a hole.
    public func text(_ cell: Cell?, sheet: SheetID, ref: CellRef) -> String {
        guard let cell else { return "" }
        guard let formatter = formatters[sheet] else { return cell.value.description }
        let styleID = workbook[sheet]?.effectiveStyleID(at: ref) ?? cell.styleID
        return formatter.display(
            of: cell, styleID: cell.styleID == .default ? styleID : cell.styleID
        ).text
    }
}
