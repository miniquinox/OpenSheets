import SwiftUI

/// Why a snapshot was taken. PLAN.md §5.5.
///
/// The reason is shown, not just the time, because "before Claude's change" and "before I saved"
/// are different kinds of restore point and you are usually looking for one specific kind.
public enum SnapshotReason: String, Sendable, Hashable, CaseIterable, Codable {
    case preRefresh
    case preSave
    case manual

    public var label: String {
        switch self {
        case .preRefresh: "Before refresh"
        case .preSave: "Before save"
        case .manual: "Manual"
        }
    }

    public var symbolName: String {
        switch self {
        case .preRefresh: "arrow.clockwise"
        case .preSave: "square.and.arrow.down"
        case .manual: "bookmark"
        }
    }
}

public struct SnapshotEntry: Sendable, Hashable, Identifiable {
    public var id: String
    /// "Today at 14:22", already formatted.
    public var takenAt: String
    /// "2 hours ago", already formatted. Both are shown: the absolute one to identify it, the
    /// relative one to judge it.
    public var relative: String
    public var reason: SnapshotReason
    /// "1 sheet, 42 cells" — what changed *after* this point, which is what you are choosing
    /// between when you pick a restore point.
    public var summary: String
    /// "118 KB", already formatted.
    public var size: String

    public init(
        id: String,
        takenAt: String,
        relative: String,
        reason: SnapshotReason,
        summary: String,
        size: String
    ) {
        self.id = id
        self.takenAt = takenAt
        self.relative = relative
        self.reason = reason
        self.summary = summary
        self.size = size
    }
}

public struct SnapshotBrowserState: Sendable, Hashable {
    public var entries: [SnapshotEntry]
    public var selectedID: String?
    /// "1.4 MB of 500 MB", already formatted. Shown because the cap is real (PLAN.md §5.5) and a
    /// user who has been working all week should be able to see it approaching.
    public var storageSummary: String

    public init(entries: [SnapshotEntry], selectedID: String? = nil, storageSummary: String = "") {
        self.entries = entries
        self.selectedID = selectedID
        self.storageSummary = storageSummary
    }
}

public enum SnapshotBrowserAction: Sendable, Hashable {
    case select(String)
    /// Replace the current file with this snapshot's bytes.
    case restore(String)
    /// Open a diff between this snapshot and the current file.
    case compare(String)
    /// Reveal the `.gz` in Finder.
    case reveal(String)
    case takeSnapshot
    case delete(String)
    case dismiss
}

/// Restore points, newest first.
///
/// The primary action is `Compare`, not `Restore`. Restoring is destructive and the honest first
/// step is to look at what you would be undoing — the same argument the diff panel makes about
/// refreshing. `Restore` is there, one click away, in the same place every time.
public struct SnapshotBrowser: View {
    private let state: SnapshotBrowserState
    private let context: AppearanceContext
    private let perform: (SnapshotBrowserAction) -> Void

    public init(
        state: SnapshotBrowserState,
        context: AppearanceContext,
        perform: @escaping (SnapshotBrowserAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DS.Chrome.separator(context))
            if state.entries.isEmpty {
                emptyState
            } else {
                list
            }
            Divider().overlay(DS.Chrome.separator(context))
            footer
        }
        .frame(width: 420)
        .glassCard(context: context)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Restore points")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Restore points")
                    .font(DS.Text.panelTitle)
                    .foregroundStyle(DS.Chrome.primary)
                Text("Taken before every refresh and every save. The last 20 are kept.")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Chrome.secondary)
            }
            Spacer(minLength: 0)
            Button { perform(.dismiss) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Chrome.secondary)
                    .padding(DS.Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(DS.Space.l)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(state.entries) { entry in
                    row(entry)
                }
            }
            .padding(.vertical, DS.Space.xs)
        }
        .frame(maxHeight: 300)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row(_ entry: SnapshotEntry) -> some View {
        let isSelected = entry.id == state.selectedID
        return Button { perform(.select(entry.id)) } label: {
            HStack(spacing: DS.Space.m) {
                Image(systemName: entry.reason.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.Chrome.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: DS.Space.xs) {
                        Text(entry.takenAt)
                            .dsNumeric(DS.Text.controlEmphasis)
                            .foregroundStyle(DS.Chrome.primary)
                        Text("·")
                            .foregroundStyle(DS.Chrome.tertiary)
                        Text(entry.reason.label)
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Chrome.secondary)
                    }
                    Text(entry.summary)
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Chrome.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: DS.Space.s)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(entry.relative)
                        .dsNumeric(DS.Text.numericCaption)
                        .foregroundStyle(DS.Chrome.tertiary)
                    Text(entry.size)
                        .dsNumeric(DS.Text.numericCaption)
                        .foregroundStyle(DS.Chrome.tertiary)
                }

                if isSelected {
                    HStack(spacing: DS.Space.xs) {
                        Button("Compare") { perform(.compare(entry.id)) }
                            .buttonStyle(.bordered)
                        Button("Restore") { perform(.restore(entry.id)) }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                    .font(DS.Text.caption)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .background {
                if isSelected {
                    DS.Radius.shape(DS.Radius.control)
                        .fill(DS.Chrome.selectedRow)
                        .padding(.horizontal, DS.Space.s)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Compare with current") { perform(.compare(entry.id)) }
            Button("Restore") { perform(.restore(entry.id)) }
            Button("Show in Finder") { perform(.reveal(entry.id)) }
            Divider()
            Button("Delete", role: .destructive) { perform(.delete(entry.id)) }
        }
        .accessibilityLabel(
            "\(entry.takenAt), \(entry.reason.label), \(entry.summary), \(entry.size)"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.xs) {
            Text("No restore points yet")
                .font(DS.Text.bodyEmphasis)
                .foregroundStyle(DS.Chrome.primary)
            Text("One is taken automatically before the first refresh or save.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Chrome.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xxl)
    }

    private var footer: some View {
        HStack {
            Text(state.storageSummary)
                .dsNumeric(DS.Text.numericCaption)
                .foregroundStyle(DS.Chrome.tertiary)
            Spacer(minLength: 0)
            Button("Take one now") { perform(.takeSnapshot) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(DS.Text.control)
        }
        .padding(DS.Space.l)
    }
}
