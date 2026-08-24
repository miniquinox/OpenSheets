import SwiftUI

/// "You have 3 unsaved edits." — the amber signal.
///
/// PLAN.md §1.3: when the file changes on disk *while the user has unsaved edits*, nothing is
/// applied automatically and neither side is thrown away without being named. So this banner does
/// not have a dismiss control. Dismissing a conflict does not resolve it; it just hides the fact
/// that the next save will destroy something. The three buttons are the three real answers.
///
/// `Keep mine` is deliberately not the prominent button. The prominent one is `Take disk`, because
/// the common case by a long way is that Claude Code just made the change the user asked for, and
/// the local edit is a half-typed cell. Prominence should point at the likely intent, and the
/// destructive-to-*me* option is the one that needs a moment's thought.
public struct ConflictBanner: View {
    /// What the user can do about it. A separate enum from ``SyncAction`` because a conflict
    /// banner is a decision point rather than a review, and A8 routes them differently.
    public enum Action: Sendable, Hashable {
        /// Save the in-memory workbook over the file.
        case keepMine
        /// Discard local edits and reload from disk.
        case takeDisk
        /// Open the diff panel with both sides.
        case compare
    }

    /// What the banner says.
    public struct Model: Sendable, Hashable {
        public var localEditCount: Int
        public var fileName: String
        /// "2 minutes ago", already formatted. The banner does not own a clock.
        public var changedAgo: String?

        public init(localEditCount: Int, fileName: String, changedAgo: String? = nil) {
            self.localEditCount = localEditCount
            self.fileName = fileName
            self.changedAgo = changedAgo
        }

        public var headline: String {
            "Conflict — you have \(localEditCount) unsaved \(localEditCount == 1 ? "edit" : "edits")"
        }

        public var detail: String {
            let base = "\(fileName) also changed on disk"
            guard let changedAgo else { return base + "." }
            return base + " \(changedAgo)."
        }
    }

    private let model: Model
    private let context: AppearanceContext
    private let perform: (Action) -> Void

    public init(model: Model, context: AppearanceContext, perform: @escaping (Action) -> Void) {
        self.model = model
        self.context = context
        self.perform = perform
    }

    /// Chosen against the amber, not the colour scheme — see ``DS/Signal/inkOnTint(_:_:)``.
    /// Conflict amber is light in *both* schemes, so this is dark ink in both.
    private var ink: Color { DS.Signal.inkOnTint(.conflict, context) }

    public var body: some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: DS.SignalKind.conflict.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)

            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(model.headline)
                    .font(DS.Text.bodyEmphasis)
                    .foregroundStyle(ink)
                Text(model.detail)
                    .font(DS.Text.caption)
                    .foregroundStyle(ink.opacity(0.75))
            }

            Spacer(minLength: DS.Space.l)

            HStack(spacing: DS.Space.s) {
                Button("Compare") { perform(.compare) }
                    .buttonStyle(.plain)
                    .foregroundStyle(ink.opacity(0.75))
                Button("Keep mine") { perform(.keepMine) }
                    .buttonStyle(.bordered)
                    .tint(ink)
                Button("Take disk") { perform(.takeDisk) }
                    .buttonStyle(.borderedProminent)
                    // Tinted with the banner's own ink rather than the accent. The strip is
                    // already dyed amber; an accent-blue button on top of it is two unrelated hues
                    // fighting in 60 points of height. A dark fill on amber reads as primary
                    // without introducing a third colour.
                    .tint(ink)
            }
            .font(DS.Text.control)
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .glassCard(context: context, radius: DS.Radius.panel, signal: .conflict)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.headline). \(model.detail)")
    }
}
