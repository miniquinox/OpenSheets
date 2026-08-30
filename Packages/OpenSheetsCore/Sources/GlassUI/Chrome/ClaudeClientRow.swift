import SwiftUI

// MARK: - Model

/// One Claude client's row in Settings ▸ Claude. Value in, actions out.
///
/// Everything the row *says* — the caption, the button's verb, the rejection — arrives already
/// written, because the wording is policy and policy belongs to the App layer: only it knows
/// whether a backup was kept, whether Claude Desktop needs a restart, or where a missing client
/// can be downloaded from. What this type owns is the *shape* of a row, so the Settings pane
/// cannot end up rendering two clients two different ways.
public struct ClaudeClientRowModel: Sendable, Equatable {
    /// A GlassUI-local mirror of the connector's per-client state.
    ///
    /// Deliberately not `DocumentCore`'s `ClaudeConnection`: the module dependency has to keep
    /// pointing the one direction it always has — GlassUI imports nothing above it — and the App
    /// layer translates between the two. `CaseIterable` so the tests can prove every case has a
    /// name without maintaining a second list that would silently miss a sixth case.
    public enum Status: Sendable, Equatable, CaseIterable {
        /// The client has never run on this machine, so there is no config to write to.
        case notInstalled
        /// The client is present and has no `opensheets` entry.
        case notConnected
        /// Registered, and the registered binary exists.
        case connected
        /// Registered, but the binary behind the registration is gone — the app moved, or a dev
        /// build's DerivedData was cleaned. The designed recovery is the same write again with a
        /// freshly resolved path, which is why the word says what to do rather than what broke.
        case stale
        /// The config file exists but cannot be parsed, so writes are refused — never clobber a
        /// file that could not be read.
        case unreadable

        /// The status word beside the client's name.
        ///
        /// Owned here rather than supplied with the caption, because a state's name is identity,
        /// not policy: the same state must read the same in every pane that ever shows one of
        /// these rows, and the way to guarantee that is for the state to name itself.
        public var label: String {
            switch self {
            case .notInstalled: "Not installed"
            case .notConnected: "Not connected"
            case .connected: "Connected"
            case .stale: "Needs reconnect"
            case .unreadable: "Config unreadable"
            }
        }
    }

    /// "Claude Code", "Claude Desktop".
    public var clientName: String
    public var status: Status
    /// The sentence under the name. Supplied by the App layer; never computed here — see the
    /// type's own doc for why the wording is not this row's to invent.
    public var caption: String
    /// "Connect" / "Disconnect" / "Reconnect"; `nil` draws no button at all.
    public var buttonLabel: String?
    public var buttonEnabled: Bool
    /// Inline failure text, red-tinted, below the row. Shown in place rather than as an alert
    /// for the launcher's reason: a config file that refuses a write is a normal thing to be
    /// told, not an incident.
    public var rejection: String?

    public init(
        clientName: String,
        status: Status,
        caption: String,
        buttonLabel: String?,
        buttonEnabled: Bool,
        rejection: String?
    ) {
        self.clientName = clientName
        self.status = status
        self.caption = caption
        self.buttonLabel = buttonLabel
        self.buttonEnabled = buttonEnabled
        self.rejection = rejection
    }
}

/// What a row can ask its host to do.
///
/// One case, because the row has one control. The host already knows which verb it put on the
/// button, so the action does not repeat it — a `connectTapped`/`disconnectTapped` split would be
/// two spellings of state the model carries once in `buttonLabel`.
public enum ClaudeClientRowAction: Sendable {
    case buttonTapped
}

// MARK: - Row

/// One Claude client's connect/disconnect row.
///
/// Plain content on purpose: the row sits inside the Settings form, which already provides the
/// surface, so the row draws no glass of its own — a lens inside that pane would be the nested
/// glass the cluster rule exists to forbid. The dot, the type ramp and the inline rejection all
/// reuse the sidebar's and the launcher's idioms so that "how OpenSheets talks about Claude" is
/// one language wherever it appears.
public struct ClaudeClientRow: View {
    private let model: ClaudeClientRowModel
    private let perform: (ClaudeClientRowAction) -> Void

    /// The appearance is read from the environment key the design system injects at the top of
    /// every window (`glassAppearance(_:)`) rather than taken in the initialiser: this row's
    /// initialiser is the Settings pane's compile target, and its contract is value-in,
    /// actions-out — the appearance is not part of the row's value, it is the ambient the whole
    /// window has already agreed on. A plain `@Environment` *value* keeps that arrangement
    /// without touching the global state the component lint forbids.
    @Environment(\.glassAppearance) private var context

    public init(
        model: ClaudeClientRowModel,
        perform: @escaping (ClaudeClientRowAction) -> Void
    ) {
        self.model = model
        self.perform = perform
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            AgentDot(
                color: dotColor,
                diameter: 6,
                isActive: model.status == .connected,
                reduceMotion: context.reduceMotion
            )
            .padding(.top, DS.Space.xs)

            VStack(alignment: .leading, spacing: DS.Space.rowGap) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(model.clientName)
                        .font(DS.Text.controlEmphasis)
                        .foregroundStyle(DS.Chrome.primary)
                    Text(model.status.label)
                        .font(DS.Text.control)
                        .foregroundStyle(DS.Chrome.secondary)
                }
                Text(model.caption)
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let rejection = model.rejection {
                    Label(rejection, systemImage: "exclamationmark.circle")
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Signal.errorInk(context))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spokenSummary)

            Spacer(minLength: DS.Space.m)

            if let buttonLabel = model.buttonLabel {
                Button(buttonLabel) { perform(.buttonTapped) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(DS.Text.control)
                    .disabled(!model.buttonEnabled)
            }
        }
    }

    /// The dot is never left to carry the state alone — the status word sits right beside it —
    /// so VoiceOver gets the same full sentence a sighted reader assembles from the pieces.
    private var spokenSummary: String {
        var summary = "\(model.clientName), \(model.status.label). \(model.caption)"
        if let rejection = model.rejection {
            summary += " \(rejection)"
        }
        return summary
    }

    /// The sidebar's `dotColor` switch, restated for this vocabulary: the app's only green stays
    /// reserved for a registration that would actually work, the two broken states take the
    /// stale and error inks, and everything merely absent stays calm — absence is a fact, not a
    /// fault.
    private var dotColor: Color {
        switch model.status {
        case .connected: DS.Signal.connected(context)
        case .stale: DS.Signal.staleInk(context)
        case .unreadable: DS.Signal.errorInk(context)
        case .notInstalled, .notConnected: DS.Signal.calmInk(context)
        }
    }
}
