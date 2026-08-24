import SwiftUI

/// The app's signature interaction: a pill that **becomes** the panel.
///
/// PLAN.md §1.2 — Claude edits the file in a terminal, the watcher fires, a pill rises in the
/// bottom-right, and clicking it opens the review. The temptation is to present a sheet or a
/// popover from the pill. Don't: a popover *appears next to* the pill and says "here is a second
/// thing", whereas this says "the thing you are looking at is the review, it just got bigger".
/// That difference is the whole product in one gesture — the file changed, and here is what
/// changed, and it is the same object.
///
/// How it actually works, because it is three specific details and skipping any one of them
/// breaks it:
///
/// 1. Both shapes live inside **one** ``GlassCluster``. Outside a container there is no lens to
///    carry from one to the other, and you get a cross-fade between two independent blurs.
/// 2. Both carry the same ``GlassMorphID`` via ``SwiftUI/View/glassMorph(_:in:)`` and a shared
///    `@Namespace`. This is the pairing the system interpolates.
/// 3. The shape animates on ``DS/Motion/standard`` and the *content* on ``DS/Motion/settle``.
///    Same start, different damping, so the surface arrives first and the rows land into it.
///    Animate both on the same curve and it reads as a resize; give the content its own slower
///    settle and it reads as liquid.
///
/// Under `reduceMotion` the morph is replaced by a cross-fade — see
/// ``SwiftUI/View/glassMorphTransition(_:)``.
public struct SyncSurface: View {
    /// Which shape is on screen. Owned by A8: the surface is stateless so the pill can be brought
    /// back by the watcher, dismissed by a menu command, or restored after a window reopen
    /// without this view having an opinion.
    public enum Phase: String, Sendable, Hashable, CaseIterable {
        case hidden
        case pill
        case panel
    }

    private let phase: Phase
    private let changeSet: FileChangeSet
    private let filteredSheet: String?
    private let context: AppearanceContext
    private let perform: (SyncAction) -> Void

    @Namespace private var morphNamespace

    public init(
        phase: Phase,
        changeSet: FileChangeSet,
        filteredSheet: String? = nil,
        context: AppearanceContext,
        perform: @escaping (SyncAction) -> Void
    ) {
        self.phase = phase
        self.changeSet = changeSet
        self.filteredSheet = filteredSheet
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        GlassCluster {
            switch phase {
            case .hidden:
                EmptyView()
            case .pill:
                RefreshPill(notice: changeSet.notice, context: context, perform: perform)
                    .glassMorph(.syncSurface, in: morphNamespace)
                    .glassMorphTransition(context)
            case .panel:
                DiffPanel(
                    changeSet: changeSet,
                    filteredSheet: filteredSheet,
                    context: context,
                    perform: perform
                )
                .glassMorph(.syncSurface, in: morphNamespace)
                .glassMorphTransition(context)
            }
        }
        .animation(DS.Motion.morph(context), value: phase)
    }
}

// MARK: - The pill

/// "Changed on disk · 1 sheet, 42 cells · ⌘R".
///
/// One capsule, one glass element, no border, no shadow. The pulsing dot is the only motion, and
/// it is the thing that makes the pill readable out of the corner of your eye while you are
/// looking at the grid — which is exactly where you will be when it appears.
///
/// The whole capsule is the button. A pill with a separate "Refresh" button inside it invites the
/// user to refresh without reading the diff, which is the one thing this feature exists to
/// prevent; clicking anywhere opens the review, and ⌘R is there for people who already trust it.
public struct RefreshPill: View {
    private let notice: RefreshNotice
    private let context: AppearanceContext
    private let perform: (SyncAction) -> Void

    public init(
        notice: RefreshNotice,
        context: AppearanceContext,
        perform: @escaping (SyncAction) -> Void
    ) {
        self.notice = notice
        self.context = context
        self.perform = perform
    }

    /// Chosen against the tint, not the colour scheme — see ``DS/Signal/inkOnTint(_:_:)``.
    private var ink: Color { DS.Signal.inkOnTint(notice.signal, context) }

    public var body: some View {
        Button { perform(.expand) } label: {
            HStack(spacing: DS.Space.s) {
                AgentDot(
                    color: ink,
                    isActive: notice.isWatching,
                    reduceMotion: context.reduceMotion
                )

                Text(notice.headline)
                    .font(DS.Text.bodyEmphasis)
                    .foregroundStyle(ink)

                if !notice.detail.isEmpty {
                    Text("·")
                        .font(DS.Text.body)
                        .foregroundStyle(ink.opacity(0.45))
                    Text(notice.detail)
                        .dsNumeric(DS.Text.numeric)
                        .foregroundStyle(ink.opacity(0.8))
                }

                if let shortcut = notice.shortcut {
                    Text(shortcut)
                        .font(DS.Text.mono)
                        .foregroundStyle(ink.opacity(0.6))
                        .padding(.leading, DS.Space.xs)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .glassPill(context: context, signal: notice.signal)
        .accessibilityLabel(notice.accessibilityLabel)
        .accessibilityHint("Opens the list of changes")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - The panel

/// The review. Per-sheet counts, the changed cells, three ways out.
///
/// Fixed width, because the before/after columns are compared down the page and a panel that
/// resizes with its content re-flows those columns every time the diff is recomputed. Height is
/// capped so the list scrolls rather than the panel growing past the window.
public struct DiffPanel: View {
    private let changeSet: FileChangeSet
    private let filteredSheet: String?
    private let context: AppearanceContext
    private let perform: (SyncAction) -> Void

    public init(
        changeSet: FileChangeSet,
        filteredSheet: String? = nil,
        context: AppearanceContext,
        perform: @escaping (SyncAction) -> Void
    ) {
        self.changeSet = changeSet
        self.filteredSheet = filteredSheet
        self.context = context
        self.perform = perform
    }

    private var visibleChanges: [CellChange] {
        guard let filteredSheet else { return changeSet.changes }
        return changeSet.changes.filter { $0.sheetName == filteredSheet }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !changedSheets.isEmpty { sheetChips }
            Divider().overlay(DS.Chrome.separator(context))
            changeList
            Divider().overlay(DS.Chrome.separator(context))
            footer
        }
        .frame(width: 380)
        // Plain floating glass, **not** the signal tier — even though this is the same surface the
        // tinted pill morphs out of.
        //
        // Tint does not scale with area. At capsule size an accent-tinted lens is a signal you
        // cannot miss, which is exactly what the pill is for. At 380 × 420 the same tint is a
        // saturated blue slab with a spreadsheet behind it, and the twelve numbers you are meant
        // to be reading sit on top of it. The first screenshot of this panel made that decision
        // for us. The signal is still carried — by the sparkle in the header and by the accent on
        // Refresh — it is just no longer carried by 160,000 square points of colour.
        .glassCard(context: context)
        .animation(DS.Motion.settle, value: changeSet)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes on disk")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            SignalBadge(changeSet.notice.signal, context: context, showsLabel: false)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(changeSet.notice.headline)
                    .font(DS.Text.panelTitle)
                    .foregroundStyle(DS.Chrome.primary)
                if !changeSet.notice.detail.isEmpty {
                    Text(changeSet.notice.detail)
                        .dsNumeric(DS.Text.numericCaption)
                        .foregroundStyle(DS.Chrome.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { perform(.collapse) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Chrome.secondary)
                    .padding(DS.Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse to pill")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.l)
        .padding(.bottom, changedSheets.isEmpty ? DS.Space.m : DS.Space.s)
    }

    /// Only sheets that actually changed. A chip reading "Summary 0" is a filter that shows you
    /// nothing, taking up the width of one that shows you something.
    private var changedSheets: [SheetChangeSummary] {
        changeSet.sheets.filter { $0.totalCount > 0 || $0.renamedFrom != nil }
    }

    private var sheetChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DS.Space.s) {
                sheetChip(name: nil, count: changeSet.notice.cellCount, renamedFrom: nil)
                ForEach(changedSheets) { sheet in
                    sheetChip(
                        name: sheet.name,
                        count: sheet.totalCount,
                        renamedFrom: sheet.renamedFrom
                    )
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.m)
        }
        .scrollIndicators(.never)
    }

    private func sheetChip(name: String?, count: Int, renamedFrom: String?) -> some View {
        let isSelected = filteredSheet == name
        return Button { perform(.filterSheet(name)) } label: {
            HStack(spacing: DS.Space.xs) {
                if renamedFrom != nil {
                    Image(systemName: "character.cursor.ibeam")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(name ?? "All")
                    .font(DS.Text.controlEmphasis)
                Text(count.formatted())
                    .dsNumeric(DS.Text.numericCaption)
                    .foregroundStyle(isSelected ? DS.Chrome.onAccent.opacity(0.8) : DS.Chrome.secondary)
            }
            .foregroundStyle(isSelected ? DS.Chrome.onAccent : DS.Chrome.primary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.xs + 1)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? DS.Chrome.accent : DS.Chrome.separator)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            renamedFrom.map { "\(name ?? "All"), renamed from \($0), \(count) changes" }
                ?? "\(name ?? "All"), \(count) changes"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(visibleChanges) { change in
                    DiffRow(change: change, context: context) {
                        perform(.showInGrid(change.id))
                    }
                }
                if changeSet.truncatedCount > 0 {
                    Text("+ \(changeSet.truncatedCount.formatted()) more")
                        .dsNumeric(DS.Text.numericCaption)
                        .foregroundStyle(DS.Chrome.tertiary)
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, DS.Space.s)
                }
            }
            .padding(.vertical, DS.Space.s)
        }
        .frame(maxHeight: 260)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if changeSet.wasRediffed {
                Label("The file changed again while this was open.", systemImage: "arrow.clockwise")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Signal.conflictInk(context))
                    .accessibilityLabel("The file changed again while this panel was open")
            }
            HStack(spacing: DS.Space.s) {
                if changeSet.notice.localEditCount > 0 {
                    Button("Keep mine") { perform(.keepMine) }
                        .buttonStyle(.bordered)
                    Button("Take disk") { perform(.takeDisk) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Discard file changes") { perform(.discardFileChanges) }
                        .buttonStyle(.bordered)
                    Spacer(minLength: 0)
                    Button {
                        perform(.refresh)
                    } label: {
                        HStack(spacing: DS.Space.xs) {
                            Text("Refresh")
                            if let shortcut = changeSet.notice.shortcut {
                                Text(shortcut).opacity(0.7)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .font(DS.Text.control)
        }
        .padding(DS.Space.l)
    }
}

/// One row: `D2  120 → 129.6`.
///
/// Both value columns are tabular and right-aligned against a fixed width, so a list of numeric
/// changes lines up on the decimal point and you can see at a glance that everything moved by the
/// same proportion. That alignment is the entire reason to look at a diff of a spreadsheet rather
/// than at the sheet itself.
public struct DiffRow: View {
    private let change: CellChange
    private let context: AppearanceContext
    private let action: () -> Void

    @State private var isHovering = false

    public init(change: CellChange, context: AppearanceContext, action: @escaping () -> Void) {
        self.change = change
        self.context = context
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: change.kind.symbolName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Chrome.tertiary)
                    .frame(width: 12)

                Text(change.refLabel)
                    .font(DS.Text.mono)
                    .foregroundStyle(DS.Chrome.secondary)
                    .frame(width: 52, alignment: .leading)

                Text(change.beforeDisplay)
                    .dsNumeric(DS.Text.mono)
                    .foregroundStyle(DS.Chrome.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(1)
                    .truncationMode(.head)

                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DS.Chrome.tertiary)

                Text(change.afterDisplay)
                    .dsNumeric(DS.Text.mono)
                    .foregroundStyle(DS.Chrome.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.badgeX)
            .background {
                if isHovering {
                    Rectangle().fill(DS.Chrome.separator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(
            "\(change.sheetName) \(change.refLabel), \(change.kind.label), "
                + "was \(change.beforeDisplay), now \(change.afterDisplay)"
        )
        .accessibilityHint("Shows this cell in the grid")
    }
}
