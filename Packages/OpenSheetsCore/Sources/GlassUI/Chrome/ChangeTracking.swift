import SwiftUI

/// `+12 ~5 −3` — the whole feature in eleven characters.
///
/// Three counts against a baseline the user chose. Style-only changes are **not** in here: a cell
/// whose fill went from grey to grey-ish is not news, and counting it would mean the chip lights up
/// every time an agent tidies a sheet. They are mentioned in the panel instead, as a number nobody
/// has to act on (plan §1.3).
public struct ChangeTrackingChipState: Sendable, Hashable {
    public var added: Int
    public var modified: Int
    public var removed: Int

    /// The differ hit its comparison budget, so these counts are floors rather than totals
    /// (`WorkbookDiff.wasTruncated`). Surfaced rather than swallowed: a chip that says `500` when
    /// it means "at least 500" is the kind of quiet lie that costs somebody an afternoon.
    public var isTruncated: Bool

    public init(added: Int = 0, modified: Int = 0, removed: Int = 0, isTruncated: Bool = false) {
        self.added = added
        self.modified = modified
        self.removed = removed
        self.isTruncated = isTruncated
    }

    public var total: Int { added + modified + removed }

    /// Nothing to show. The host hides the chip on this rather than rendering `+0 ~0 −0`, which is
    /// a control that takes up title-bar width to say nothing happened.
    public var isEmpty: Bool { total == 0 && !isTruncated }

    /// The count for one kind, so the chip and its accessibility label cannot disagree.
    public func count(_ kind: DS.Change.Kind) -> Int {
        switch kind {
        case .added: added
        case .modified: modified
        case .removed: removed
        }
    }
}

public struct ChangeTrackingPanelState: Sendable, Hashable {
    public var chip: ChangeTrackingChipState

    /// "Since opened · 09:41", "Since checkpoint · 12:03", "Since a1b2c3d". Composed by the app
    /// layer, which owns the clock and the formatter.
    public var baselineLabel: String

    /// Formatting-only changes. Counted, never tinted — see ``ChangeTrackingChipState``.
    public var styleOnlyCount: Int

    public var highlightsEnabled: Bool

    /// Why the grid is not painting, when the app decided that for the user.
    ///
    /// `nil` covers both of the cases where there is nothing to explain: the tints are on and
    /// drawing, or the user turned them off themselves — which is their choice and not news.
    /// Anything else and the panel has to say it out loud, because the alternative is a chip
    /// reading `+40,000 ~12,000` above a grid with no colour in it, which is the app telling two
    /// stories at once and letting the user pick the wrong one.
    public var highlightSuppression: HighlightSuppression?

    /// Mirrors `DocumentCore.ChangeHighlightsMapping.Suppression`, which lives on the other side
    /// of a dependency this module does not have. Two reasons rather than one flag because the
    /// panel says different sentences for them: one is *"most of this sheet changed"*, the other
    /// is *"we stopped counting"*.
    public enum HighlightSuppression: Sendable, Hashable {
        case density
        case truncatedDiff

        /// One sentence, in the same register as the truncation note the chip already carries.
        public var sentence: String {
            switch self {
            case .density: "Most of this sheet changed — per-cell highlights are off."
            case .truncatedDiff: "The comparison stopped at its budget, so the grid is not tinted."
            }
        }
    }

    /// In offer order. `gitHEAD` is absent unless the file resolves inside a git work tree, which
    /// is why this is a list rather than "all of them, some disabled": an option that is never
    /// available on this machine is better not drawn than drawn greyed out forever.
    public var sources: [SourceChoice]
    public var activeSource: SourceChoice

    public enum SourceChoice: Sendable, Hashable {
        /// The workbook as it was when this window opened it. The default, and the one that needs
        /// no setup: it answers "what has changed since I have been looking".
        case asOpened
        /// A point the user marked, backed by a byte snapshot so it survives relaunch.
        case checkpoint
        /// The committed bytes. Offered only inside a repository.
        case gitHEAD

        public var label: String {
            switch self {
            case .asOpened: "Since opened"
            case .checkpoint: "Since checkpoint"
            case .gitHEAD: "Since last commit"
            }
        }
    }

    public struct Row: Sendable, Hashable, Identifiable {
        /// `"<sheetName>!<a1>"` for a cell, `"structural-…"` for a row/column change. Unique
        /// across sheets, which is what lets one flat `ForEach` carry the whole diff.
        public var id: String
        public var sheetName: String
        /// `nil` for a structural row — there is no single cell to jump to.
        public var refA1: String?
        /// "120 → 129.6", "inserted 1 row at 5", "deleted 2 rows at 14".
        public var summary: String
        public var kind: Kind

        public enum Kind: Sendable, Hashable {
            case added
            case modified
            case removed
            /// A whole row or column arrived or left. Panel-only in v1: a marker between two rows
            /// of a spreadsheet is fiddly to place and easy to misread (plan §1.3).
            case structural
        }

        public init(id: String, sheetName: String, refA1: String? = nil, summary: String, kind: Kind) {
            self.id = id
            self.sheetName = sheetName
            self.refA1 = refA1
            self.summary = summary
            self.kind = kind
        }
    }

    public var sections: [Section]

    public struct Section: Sendable, Hashable, Identifiable {
        public var id: String
        public var sheetName: String
        public var rows: [Row]
        /// How many changes on this sheet were not listed. Rendered as "+N more" rather than
        /// dropped, so the list never quietly claims to be complete.
        public var omittedCount: Int

        public init(id: String, sheetName: String, rows: [Row], omittedCount: Int = 0) {
            self.id = id
            self.sheetName = sheetName
            self.rows = rows
            self.omittedCount = omittedCount
        }
    }

    public init(
        chip: ChangeTrackingChipState,
        baselineLabel: String,
        styleOnlyCount: Int = 0,
        highlightsEnabled: Bool = true,
        highlightSuppression: HighlightSuppression? = nil,
        sources: [SourceChoice] = [.asOpened, .checkpoint],
        activeSource: SourceChoice = .asOpened,
        sections: [Section] = []
    ) {
        self.chip = chip
        self.baselineLabel = baselineLabel
        self.styleOnlyCount = styleOnlyCount
        self.highlightsEnabled = highlightsEnabled
        self.highlightSuppression = highlightSuppression
        self.sources = sources
        self.activeSource = activeSource
        self.sections = sections
    }
}

public enum ChangeTrackingAction: Sendable, Hashable {
    /// Mark here. Captures a snapshot, moves the baseline to the current workbook, clears the
    /// tints.
    case setCheckpoint
    case choose(ChangeTrackingPanelState.SourceChoice)
    case toggleHighlights
    /// Jump to a cell. Structural rows never emit this — there is no single cell to jump to.
    case reveal(sheetName: String, refA1: String)
    case dismiss
}

/// The counts, in the title bar.
///
/// A capsule of plain text, drawing **no lens of its own** — exactly like ``SyncStateChip``, which
/// it sits beside. The title bar row is already one anchored material band, and two capsules of
/// glass floating on it would be two lenses over a surface that is not the grid, which is the one
/// arrangement `GlassSurface`'s note says never reads as real. The band is the surface; these are
/// text on it.
///
/// # Why the glyphs are not decoration
///
/// `+ ~ −` carry the meaning that the green, amber and red carry, for the person who cannot use
/// the colour. Same rule as ``DS/SignalKind/symbolName``, and the same reason it is unconditional
/// rather than switched on by `differentiateWithoutColor`: a signal that spells itself out for some
/// users and not others never gets designed properly, because nobody with the setting off ever sees
/// how ambiguous it is.
public struct ChangeTrackingChip: View {
    private let state: ChangeTrackingChipState
    private let context: AppearanceContext
    private let action: () -> Void

    public init(
        state: ChangeTrackingChipState,
        context: AppearanceContext,
        action: @escaping () -> Void
    ) {
        self.state = state
        self.context = context
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ChangeCounts(state: state, context: context)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.chipY)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverTitle(ChangeCounts.helpText(state))
        .accessibilityLabel(ChangeCounts.spokenLabel(state))
        .accessibilityHint("Opens the list of changes")
    }
}

/// `+12 ~5 −3`, with no opinion about whether it is a button.
///
/// Shared by the chip and by the panel's own header, because the counts appear twice — you click
/// the chip and the panel that opens has to agree with it — and two renderings of one number is how
/// they end up disagreeing. In the header it is a plain readout: the panel it is sitting in *is*
/// the thing the chip would have opened, so a second button there would be a control whose action
/// is "do nothing", which VoiceOver would still announce as a button.
struct ChangeCounts: View {
    let state: ChangeTrackingChipState
    let context: AppearanceContext

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(DS.Change.Kind.allCases, id: \.self) { kind in
                count(kind)
            }
            if state.isTruncated {
                // Not "500+". The chip's own added-glyph is a `+`, so a trailing one reads as a
                // fourth count. An ellipsis says the same thing — there is more than this — without
                // competing with the vocabulary the rest of the chip just established.
                Text("…")
                    .font(DS.Text.controlEmphasis)
                    .foregroundStyle(DS.Chrome.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(state))
    }

    private func count(_ kind: DS.Change.Kind) -> some View {
        HStack(spacing: DS.Space.hair) {
            Text(kind.glyph)
                .font(DS.Text.controlEmphasis)
            Text(state.count(kind).formatted())
                .dsNumeric(DS.Text.numericCaption)
        }
        .foregroundStyle(DS.Change.ink(kind, context))
        .accessibilityHidden(true)
    }

    static func helpText(_ state: ChangeTrackingChipState) -> String {
        state.isTruncated
            ? "\(spokenLabel(state)). More than this changed — the comparison stopped at its budget."
            : spokenLabel(state)
    }

    /// The counts as words. Colour and glyph both go missing for somebody using VoiceOver, so the
    /// kind is spelled out rather than implied by position.
    static func spokenLabel(_ state: ChangeTrackingChipState) -> String {
        let parts = DS.Change.Kind.allCases.map { "\(state.count($0)) \($0.label.lowercased())" }
        return (state.isTruncated ? "At least " : "") + parts.joined(separator: ", ")
    }
}

/// The review: what moved, since when, and the one button that resets the answer.
///
/// Presented in a popover by the app — this is only the content, which is why ``dismiss`` is an
/// action rather than an `@Environment(\.dismiss)`. The component never learns it is in a popover,
/// so the same view is a sheet, an inspector section or a gallery entry without a change.
///
/// # Set Checkpoint is the point of the panel
///
/// Everything above it answers "what changed"; that button answers "and I have now seen it". It is
/// the prominent one, at the bottom, in the same place every time — the same argument
/// ``DiffPanel``'s Refresh makes. The source picker sits above it rather than in a menu because
/// which baseline you are measuring against changes the meaning of every number on screen, and a
/// number whose meaning is hidden behind a disclosure is a number people misread.
public struct ChangeTrackingPanel: View {
    private let state: ChangeTrackingPanelState
    private let context: AppearanceContext
    private let perform: (ChangeTrackingAction) -> Void

    public init(
        state: ChangeTrackingPanelState,
        context: AppearanceContext,
        perform: @escaping (ChangeTrackingAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if state.sources.count > 1 {
                sourcePicker
            }
            Divider().overlay(DS.Chrome.separator(context))
            changeList
            Divider().overlay(DS.Chrome.separator(context))
            footer
        }
        // Fixed, for the same reason ``DiffPanel`` is fixed: the summaries are read down the page
        // as a column, and a panel that resizes with its content re-flows that column every time
        // the diff is recomputed — which, here, is every 500 ms while somebody is typing.
        .frame(width: Self.panelWidth)
        .glassCard(context: context, radius: DS.Radius.panel)
        .animation(DS.Motion.settle, value: state)
        .accessibilityElement(children: .contain)
        // Two sentences rather than one clause, because `baselineLabel` already begins with its
        // own preposition ("Since opened · 09:41") and gluing it on with another produces
        // "changes since since opened".
        .accessibilityLabel("Changes. \(state.baselineLabel)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text("Changes")
                    .font(DS.Text.panelTitle)
                    .foregroundStyle(DS.Chrome.primary)
                Text(state.baselineLabel)
                    .dsNumeric(DS.Text.numericCaption)
                    .foregroundStyle(DS.Chrome.secondary)
            }
            Spacer(minLength: DS.Space.m)
            ChangeCounts(state: state.chip, context: context)
            Button { perform(.dismiss) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Self.dismissGlyphSize, weight: .semibold))
                    .foregroundStyle(DS.Chrome.secondary)
                    .padding(DS.Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.l)
        .padding(.bottom, DS.Space.m)
    }

    private var sourcePicker: some View {
        Picker("Compare against", selection: sourceBinding) {
            ForEach(state.sources, id: \.self) { source in
                Text(source.label).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .font(DS.Text.control)
        .padding(.horizontal, DS.Space.l)
        .padding(.bottom, DS.Space.m)
        .accessibilityLabel("Compare against")
    }

    private var sourceBinding: Binding<ChangeTrackingPanelState.SourceChoice> {
        Binding(
            get: { state.activeSource },
            set: { perform(.choose($0)) }
        )
    }

    @ViewBuilder
    private var changeList: some View {
        if state.sections.isEmpty {
            emptyList
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.sections) { section in
                        sectionHeader(section)
                        ForEach(section.rows) { row in
                            ChangeRow(row: row, context: context) {
                                if let refA1 = row.refA1 {
                                    perform(.reveal(sheetName: row.sheetName, refA1: refA1))
                                }
                            }
                        }
                        if section.omittedCount > 0 {
                            Text("+ \(section.omittedCount.formatted()) more")
                                .dsNumeric(DS.Text.numericCaption)
                                .foregroundStyle(DS.Chrome.tertiary)
                                .padding(.horizontal, DS.Space.l)
                                .padding(.vertical, DS.Space.xs)
                        }
                    }
                }
                .padding(.vertical, DS.Space.s)
            }
            .frame(maxHeight: Self.listMaxHeight)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var emptyList: some View {
        // Two different facts, and saying the wrong one is worse than saying nothing. "Nothing has
        // changed" after a checkpoint is the reward for having taken it; "too many to list" is an
        // admission, and it has to read as one.
        // The baseline is named in the header directly above, so this does not repeat it — and
        // must not: `baselineLabel` is composed by the app layer and carries its own preposition,
        // so any sentence built around it here would read "changed since since opened".
        //
        // The counting half only. What the *grid* is doing is the footer's note, which says it
        // once whatever the list length — this sentence used to promise "the grid still tints the
        // ones it found", which stopped being true the moment a truncated diff started
        // suppressing the tints wholesale.
        Text(state.chip.isTruncated ? "Too many changes to enumerate." : "Nothing has changed.")
            .font(DS.Text.control)
            .foregroundStyle(DS.Chrome.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.l)
    }

    private func sectionHeader(_ section: ChangeTrackingPanelState.Section) -> some View {
        SectionHeader(section.sheetName, trailing: section.rows.count.formatted())
            .padding(.horizontal, DS.Space.l)
            .padding(.top, DS.Space.s)
            .padding(.bottom, DS.Space.xs)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Toggle("Highlight changes in grid", isOn: highlightBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(DS.Text.control)

            // Directly under the switch, because that is where somebody looks when the grid is
            // not painting and they are checking whether they turned it off. Never leave the grid
            // unpainted while the chip reports thousands of changes (plan §1.3).
            if state.highlightsEnabled, let suppression = state.highlightSuppression {
                Label(suppression.sentence, systemImage: "eye.slash")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.styleOnlyCount > 0 {
                // Stated, not counted. Formatting is a change to how a number looks, not to what
                // it is, and tinting it would mean a theme swap lights up the whole sheet.
                Text("\(state.styleOnlyCount.formatted()) formatting-only changes, not tinted")
                    .dsNumeric(DS.Text.numericCaption)
                    .foregroundStyle(DS.Chrome.tertiary)
            }

            HStack(spacing: DS.Space.s) {
                Spacer(minLength: 0)
                Button("Set Checkpoint") { perform(.setCheckpoint) }
                    .buttonStyle(.borderedProminent)
                    .hoverTitle("Make the workbook as it is now the thing everything is compared against")
            }
            .font(DS.Text.control)
        }
        .padding(DS.Space.l)
    }

    private var highlightBinding: Binding<Bool> {
        Binding(
            get: { state.highlightsEnabled },
            set: { _ in perform(.toggleHighlights) }
        )
    }

    // MARK: Sizes

    /// Matches ``DiffPanel``'s 380 within a step. The two panels answer neighbouring questions —
    /// "what just changed on disk" and "what has changed since I marked here" — and a user who
    /// opens one after the other should not see the window's furniture resize.
    private static let panelWidth: CGFloat = 380

    /// Roughly twelve rows. Past that the list scrolls rather than the popover growing toward the
    /// bottom of the screen.
    private static let listMaxHeight: CGFloat = 280

    private static let dismissGlyphSize: CGFloat = 10
}

/// One line of the panel: `D2   120 → 129.6`.
///
/// Deliberately not ``DiffRow``. That row splits before and after into two fixed, right-aligned
/// columns so a page of numeric changes lines up on the decimal point — which is right when every
/// row is a cell edit. Half the rows here are structural ("inserted 1 row at 5"), and a sentence
/// forced into a right-aligned numeric column reads as a rendering fault. So the summary is
/// composed by the app layer and set as one monospaced run.
struct ChangeRow: View {
    let row: ChangeTrackingPanelState.Row
    let context: AppearanceContext
    let action: () -> Void

    @State private var isHovering = false

    /// Structural rows are not buttons: there is no single cell behind "deleted 2 rows at 14", and
    /// a control that does nothing when clicked is worse than a label.
    private var isNavigable: Bool { row.refA1 != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbolName)
                    .font(.system(size: Self.glyphSize, weight: .semibold))
                    .foregroundStyle(ink)
                    .frame(width: Self.glyphColumn)

                Text(row.refA1 ?? "—")
                    .font(DS.Text.mono)
                    .foregroundStyle(DS.Chrome.secondary)
                    .frame(width: Self.refColumn, alignment: .leading)

                Text(row.summary)
                    .dsNumeric(DS.Text.mono)
                    .foregroundStyle(DS.Chrome.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.badgeX)
            .background {
                if isHovering, isNavigable {
                    Rectangle().fill(DS.Chrome.separator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isNavigable)
        .onHover { isHovering = $0 }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isNavigable ? "Shows this cell in the grid" : "Not a single cell")
    }

    private var changeKind: DS.Change.Kind? {
        switch row.kind {
        case .added: .added
        case .modified: .modified
        case .removed: .removed
        case .structural: nil
        }
    }

    private var ink: Color {
        changeKind.map { DS.Change.ink($0, context) } ?? DS.Chrome.secondary
    }

    private var symbolName: String {
        changeKind?.symbolName ?? "rectangle.split.3x1"
    }

    private var accessibilityLabel: String {
        let kindWord = changeKind?.label ?? "Structural change"
        let where_ = row.refA1.map { "\(row.sheetName) \($0)" } ?? row.sheetName
        return "\(where_), \(kindWord.lowercased()), \(row.summary)"
    }

    private static let glyphSize: CGFloat = 9
    private static let glyphColumn: CGFloat = 12
    private static let refColumn: CGFloat = 52
}
