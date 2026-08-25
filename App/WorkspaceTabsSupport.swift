import DocumentCore
import GlassUI
import GridKit
import SheetModel
import SheetStore
import SwiftUI

/// The workspace window's state mapping: models in, plain component values out.
///
/// Split out of ``DocumentWindow`` for the same reason `snapshotState` is a computed property
/// rather than a view: every function here is a *pure* function of the documents, so it can be
/// read — and argued with — without running a window. `GlassUI` deliberately knows nothing about
/// `DocumentCore` (`Package.swift`), which means somebody has to do this translation; doing it in
/// one enum rather than inline in three `@ViewBuilder`s is what keeps the two halves of PLAN.md
/// §1.5's precedence table from drifting apart.
///
/// `@MainActor` because every input is: ``DocumentCore/TabsModel`` and
/// ``DocumentCore/DocumentModel`` are both main-actor observable, which is what lets these read
/// them directly and lets SwiftUI track the reads.
@MainActor
enum WorkspaceState {
    /// How long after a refresh a background tab keeps its accent dot (PLAN.md §1.5).
    ///
    /// Not a spacing token and not a guess: it is long enough that a glance away and back still
    /// catches "an agent touched this", and short enough that a dot on screen means *recently*
    /// rather than *at some point today*. ``DocumentWindow`` schedules exactly one wake-up per
    /// refresh to let it lapse, which is why it lives here as a shared constant.
    static let agentDotWindow: TimeInterval = 6

    /// How many changes the panel lists before it starts counting instead.
    ///
    /// The same number ``DocumentCore/SyncPresentation/listedChangeLimit`` uses for the diff
    /// panel, and for the same reason: past a couple of hundred rows nobody is reading the list,
    /// they are reading the count — and building ten thousand row values on every recompute is
    /// work spent on something no one will scroll to.
    static let listedChangeLimit = 200

    // MARK: - The tab strip

    /// One ``GlassUI/FileTabItem`` per open file.
    ///
    /// - Parameter clock: what "recently refreshed" is measured against. Passed in rather than
    ///   read from `Date()` so the accent dot's six seconds can actually *lapse* — see
    ///   ``DocumentWindow``'s `agentDotClock`.
    static func tabStrip(for tabs: TabsModel, asOf clock: Date) -> FileTabStripState {
        // VS Code's rule (§1.9): the parent folder appears on *every* tab in a collision and on
        // none otherwise. Counted first, because a tab cannot tell on its own whether its name is
        // ambiguous — that is a fact about the window, not about the file.
        var occurrences: [String: Int] = [:]
        for tab in tabs.tabs { occurrences[tab.url.lastPathComponent, default: 0] += 1 }

        return FileTabStripState(
            tabs: tabs.tabs.map { tab in
                let title = tab.url.lastPathComponent
                return FileTabItem(
                    id: tab.id,
                    title: title,
                    disambiguator: (occurrences[title] ?? 0) > 1
                        ? tab.url.deletingLastPathComponent().lastPathComponent
                        : nil,
                    fullPath: tab.url.path(percentEncoded: false),
                    status: status(of: tab, asOf: clock)
                )
            },
            activeID: tabs.activeTabID
        )
    }

    /// PLAN.md §1.5's precedence table, in the order the table states it: **worst news wins**.
    ///
    /// One dot, never a set. A tab is ninety points wide, and two dots on it is a decoration
    /// rather than a signal — so the ordering here *is* the design, and it is written as a
    /// straight-line sequence of returns so the order is legible rather than emergent.
    static func status(of tab: TabsModel.Tab, asOf clock: Date) -> FileTabItem.Status {
        let model: DocumentModel
        switch tab.phase {
        // A file that would not open is the loudest thing a tab can say, and it says it before
        // anything is known about sync state — because nothing is.
        case .failed: return .problem
        case .loading: return .loading
        case let .ready(ready): model = ready
        }

        switch model.syncState {
        case .missing, .locked, .unreadable: return .problem
        case .conflict: return .conflict
        default: break
        }
        // Three ways to have been touched from outside, and they are one dot: the file changed
        // and we have not reloaded (`stale`), the sync surface is saying so, or a refresh landed
        // moments ago and the user was looking at another tab when it did.
        if model.syncState == .stale { return .agentChanged }
        if model.syncPhase != .hidden { return .agentChanged }
        if let refreshed = model.lastRefreshAt,
           clock.timeIntervalSince(refreshed) < agentDotWindow { return .agentChanged }

        if model.hasUnsavedEdits { return .unsaved }
        return .none
    }

    // MARK: - The changes chip

    /// The title bar's `+12 ~5 −3`, or `nil` when there is nothing to say.
    ///
    /// Two different silences, and conflating them is the bug this shape exists to prevent.
    /// `baselineDiff == nil` means *no answer yet* — tracking is off, or the first pass has not
    /// landed — and `isEmpty` means *nothing changed*. Either way the chip is absent rather than
    /// reading `+0 ~0 −0`, which is a control spending title-bar width to say nothing happened.
    static func chip(for model: DocumentModel) -> ChangeTrackingChipState? {
        guard model.baselineDiff != nil else { return nil }
        let counts = model.baselineCounts
        let chip = ChangeTrackingChipState(
            added: counts.added,
            modified: counts.modified,
            removed: counts.removed,
            isTruncated: counts.isTruncated
        )
        return chip.isEmpty ? nil : chip
    }

    // MARK: - The changes panel

    /// The popover's whole content, from the document's baseline diff.
    static func panel(for model: DocumentModel) -> ChangeTrackingPanelState {
        let counts = model.baselineCounts
        return ChangeTrackingPanelState(
            chip: ChangeTrackingChipState(
                added: counts.added,
                modified: counts.modified,
                removed: counts.removed,
                isTruncated: counts.isTruncated
            ),
            baselineLabel: baselineLabel(for: model),
            styleOnlyCount: counts.styleOnly,
            highlightsEnabled: model.isChangeHighlightingEnabled,
            highlightSuppression: suppression(for: model),
            sources: sources(for: model),
            activeSource: choice(model.baselineSource),
            sections: sections(for: model)
        )
    }

    /// Why the grid on screen is not tinted, when the app decided that rather than the user.
    ///
    /// Read off the sheet that is actually visible, because the decision is per sheet: an agent
    /// that rewrote `Summary` and left `Data` alone gets tints on one tab of the workbook and a
    /// sentence on the other, and a panel that averaged the two would be wrong on both.
    ///
    /// ``DocumentCore/ChangeHighlightsMapping`` already folds the user's own switch into `.none`
    /// with no suppression, so the "they turned it off" case arrives here as `nil` and says
    /// nothing — which is the whole point of the mapping carrying a reason rather than a flag.
    static func suppression(for model: DocumentModel) -> ChangeTrackingPanelState.HighlightSuppression? {
        switch model.activeChangeHighlights.suppression {
        case .density: .density
        case .truncatedDiff: .truncatedDiff
        case nil: nil
        }
    }

    /// *"Since opened · 09:41"*. Composed here because the app layer owns the clock and the
    /// formatter; the component is handed the finished sentence.
    static func baselineLabel(for model: DocumentModel) -> String {
        let time = model.baselineDate.formatted(date: .omitted, time: .shortened)
        return "\(choice(model.baselineSource).label) · \(time)"
    }

    /// Which baselines this document can actually produce, in offer order.
    ///
    /// A source that is not available is **not drawn**, rather than drawn and disabled: an option
    /// that can never be chosen on this machine is furniture. `checkpoint` earns its place the
    /// moment the user presses the button in the footer, and `gitHEAD` only inside a work tree.
    ///
    /// The current source is always in the list even when it says it is unavailable, because a
    /// segmented picker whose selection is not one of its segments draws nothing selected — which
    /// would read as "no baseline" beside a chip full of counts.
    static func sources(for model: DocumentModel) -> [ChangeTrackingPanelState.SourceChoice] {
        let active = choice(model.baselineSource)
        var offered: [ChangeTrackingPanelState.SourceChoice] = []
        for candidate in [ChangeTrackingPanelState.SourceChoice.asOpened, .checkpoint, .gitHEAD] {
            let isAvailable = switch candidate {
            case .asOpened: true
            case .checkpoint: model.isCheckpointAvailable
            case .gitHEAD: model.isGitBaselineAvailable
            }
            if isAvailable || candidate == active { offered.append(candidate) }
        }
        return offered
    }

    /// C2's ``DocumentCore/BaselineSource`` as C4's picker choice. Two enums rather than one
    /// because `GlassUI` may not import `DocumentCore`; this function is the whole cost of that.
    static func choice(_ source: BaselineSource) -> ChangeTrackingPanelState.SourceChoice {
        switch source {
        case .asOpened: .asOpened
        case .checkpoint: .checkpoint
        case .gitHEAD: .gitHEAD
        }
    }

    /// And back again, for the picker's action.
    static func source(_ choice: ChangeTrackingPanelState.SourceChoice) -> BaselineSource {
        switch choice {
        case .asOpened: .asOpened
        case .checkpoint: .checkpoint
        case .gitHEAD: .gitHEAD
        }
    }

    // MARK: - The change list

    private static func sections(for model: DocumentModel) -> [ChangeTrackingPanelState.Section] {
        guard let diff = model.baselineDiff else { return [] }
        // The diff panel's formatter, not a second one. It resolves a cell's inherited style per
        // sheet and formats through ``GridKit/CellFormatter``, which is what makes a currency cell
        // read `$1,200` here and in the grid — the eight lines that used to do this inline agreed
        // with it right up until one of them was changed.
        let formatter = ValueFormatter(workbook: model.workbook)
        var sections: [ChangeTrackingPanelState.Section] = []
        var listed = 0

        for sheetDiff in diff.sheetDiffs where !sheetDiff.isEmpty {
            var rows: [ChangeTrackingPanelState.Row] = []
            // The differ's own cap, before ours: a sheet whose changes did not all fit says so
            // rather than letting the list quietly claim to be complete.
            var omitted = sheetDiff.omittedCellChangeCount

            for change in sheetDiff.cellChanges where change.kind != .styleChanged {
                guard listed < listedChangeLimit else {
                    omitted += 1
                    continue
                }
                listed += 1
                let ref = change.ref.a1String
                rows.append(
                    ChangeTrackingPanelState.Row(
                        id: "\(sheetDiff.sheetName)!\(ref)",
                        sheetName: sheetDiff.sheetName,
                        refA1: ref,
                        summary: summary(of: change, on: sheetDiff.sheetID, formatter: formatter),
                        kind: kind(change.kind)
                    )
                )
            }

            // Structural changes are never omitted: there are at most a handful of them, and
            // "deleted 2 rows at 14" is the only place a deletion is reported at all (§1.3 keeps
            // deleted-row markers out of the grid).
            for (index, structural) in sheetDiff.structuralChanges.enumerated() {
                rows.append(
                    ChangeTrackingPanelState.Row(
                        id: "structural-\(sheetDiff.sheetName)-\(index)",
                        sheetName: sheetDiff.sheetName,
                        summary: structural.summary,
                        kind: .structural
                    )
                )
            }

            guard !rows.isEmpty || omitted > 0 else { continue }
            sections.append(
                ChangeTrackingPanelState.Section(
                    id: "sheet-\(sheetDiff.sheetName)",
                    sheetName: sheetDiff.sheetName,
                    rows: rows,
                    omittedCount: omitted
                )
            )
        }
        return sections
    }

    /// *"120 → 129.6"*, in the workbook's own formats.
    ///
    /// Through ``DocumentCore/ValueFormatter`` rather than `CellValue.description`, so the panel
    /// says what the grid says: a currency cell reads `$1,200` in both places, and a date reads as
    /// a date rather than as a serial number. An absent side is an em dash, not a blank, so an
    /// added cell's *before* is a statement rather than a hole — and an em dash rather than the
    /// empty string the formatter returns, because a blank in a two-sided summary reads as a
    /// rendering fault.
    private static func summary(
        of change: SheetModel.CellChange,
        on sheet: SheetID,
        formatter: ValueFormatter
    ) -> String {
        let before = text(change.before, on: sheet, at: change.ref, formatter: formatter)
        let after = text(change.after, on: sheet, at: change.ref, formatter: formatter)
        return "\(before) \u{2192} \(after)"
    }

    private static func text(
        _ cell: Cell?,
        on sheet: SheetID,
        at ref: CellRef,
        formatter: ValueFormatter
    ) -> String {
        let text = formatter.text(cell, sheet: sheet, ref: ref)
        return text.isEmpty ? "\u{2014}" : text
    }

    /// `SheetModel`'s five kinds as the panel's four. `styleChanged` never reaches here — it is
    /// filtered out above and reported as a count instead (§1.3).
    private static func kind(_ kind: SheetModel.CellChange.Kind) -> ChangeTrackingPanelState.Row.Kind {
        switch kind {
        case .added: .added
        case .removed: .removed
        case .valueChanged, .formulaChanged, .styleChanged: .modified
        }
    }
}
