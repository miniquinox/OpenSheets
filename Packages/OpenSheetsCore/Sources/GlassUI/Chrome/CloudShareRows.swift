import SwiftUI

// MARK: - Status

/// Whether this Mac is reachable through the share relay.
///
/// Four states, and the fourth is the one worth naming carefully: `offline` is not a failure the
/// user has to act on, it is a connection that dropped and is coming back, so its word says
/// *retrying* rather than *failed*. A red dot on a link that will heal itself in eight seconds
/// teaches people to ignore red dots.
///
/// **A revoked link is not a state of this enum.** Revocation is per-link — one dead link among
/// four live ones leaves the Mac perfectly online — so it lives on ``ShareLinkRowModel/isRevoked``
/// where it can only describe the row it belongs to. Hoisting it here would make the whole
/// section claim a failure that belongs to one line of it.
///
/// The words are owned here rather than supplied by the caller for the reason
/// ``ClaudeClientRowModel/Status/label`` gives: a state's name is identity, not policy. The
/// *sentence* under the word — which Mac, how many links, what to do about it — is App-layer
/// caption, because only the App layer knows any of that.
///
/// `String`-backed so the state can be logged and persisted by the name it shows;
/// `CaseIterable` so a fifth case cannot be added without the tests noticing.
public enum CloudShareStatus: String, CaseIterable, Sendable {
    /// Cloud Share is switched off. Nothing is listening and no link resolves.
    case disabled
    /// The relay socket is opening, or reopening after a drop.
    case connecting
    /// The socket is up and links resolve to this Mac.
    case online
    /// The socket dropped. The client retries on its own; links are dead until it lands.
    case offline

    /// The status word beside the dot.
    public var label: String {
        switch self {
        case .disabled: "Off"
        case .connecting: "Connecting…"
        case .online: "Online"
        case .offline: "Offline — retrying"
        }
    }

    /// The tint the dot and any signal surface take.
    ///
    /// `online` is the only case that gets the accent, because the accent is what this app uses
    /// for *something outside this window is alive*, and that is exactly what an open relay socket
    /// means. `offline` takes amber rather than red: red is reserved for something that will not
    /// fix itself. Off and connecting stay neutral — neither is a fault, and a spinner that also
    /// shouts is a spinner nobody reads.
    public var signal: DS.SignalKind {
        switch self {
        case .disabled, .connecting: .neutral
        case .online: .agent
        case .offline: .conflict
        }
    }
}

// MARK: - Model

/// One share link's row in Settings ▸ Cloud. Value in, actions out.
///
/// Every string arrives already written, and the split is the same one
/// ``ClaudeClientRowModel`` draws: this type owns the *shape* of a link row so that four links
/// cannot render four different ways, and the App layer owns the *wording*, because only it knows
/// what clock to format `createdDetail` against, whether a link has ever been used, or why the
/// relay refused a revocation.
///
/// The one exception is ``modeWord``, which is identity rather than policy and therefore has
/// exactly two legal spellings — `"Read only"` and `"Read & write"`. They are not computed here
/// only because this module has no share-mode type to compute them from: GlassUI imports nothing
/// above it, and the mode lives in `SheetShare`. Spelling them any third way is a bug.
public struct ShareLinkRowModel: Sendable, Equatable, Identifiable {
    /// The link's stable id — the opaque token id, never the secret itself.
    public var id: String
    /// What the owner called it. "Priya", "Q4 review".
    public var name: String
    /// `"Read only"` or `"Read & write"`. See the type's doc for why those two and no others.
    public var modeWord: String
    /// The link as shown: full, selectable, truncated in the middle.
    public var urlDisplay: String
    /// "Created 2 days ago". Written by the App layer — this package owns no clock and no locale.
    public var createdDetail: String
    /// "Last used 10 minutes ago", or whatever the App layer says when it never has been.
    public var lastUsedDetail: String
    /// Revoked links stay in the list until removed, so that "I killed that one" is something you
    /// can see rather than something you have to remember.
    public var isRevoked: Bool
    /// Inline failure text, red-tinted, below the row. In place rather than in an alert, for the
    /// launcher's reason: a relay that refuses a revocation is a normal thing to be told.
    public var rejection: String?

    public init(
        id: String,
        name: String,
        modeWord: String,
        urlDisplay: String,
        createdDetail: String,
        lastUsedDetail: String,
        isRevoked: Bool,
        rejection: String? = nil
    ) {
        self.id = id
        self.name = name
        self.modeWord = modeWord
        self.urlDisplay = urlDisplay
        self.createdDetail = createdDetail
        self.lastUsedDetail = lastUsedDetail
        self.isRevoked = isRevoked
        self.rejection = rejection
    }

    /// The two provenance details as one line, dot-separated the way ``SnapshotBrowser`` separates
    /// its own.
    ///
    /// Joining here rather than in the body is what keeps a dangling separator impossible: an App
    /// layer that has nothing to say about last use passes `""` and gets one clean detail, not
    /// `"Created 2 days ago · "`. It is also the only assembled string on the row, which is why it
    /// is a property a test can read instead of a shape only a renderer can see.
    public var detailLine: String {
        [createdDetail, lastUsedDetail]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// What a share-link row can ask its host to do.
///
/// Three, because the row has three controls' worth of intent and no more: the clipboard write,
/// the kill, and the tidy-up. All three are policy to carry out — the pasteboard belongs to the
/// App layer, and so does the confirmation, if it ever wants one.
///
/// `Equatable` so a host can compare what it was handed; the row never compares them itself.
public enum ShareLinkRowAction: Sendable, Equatable {
    /// Put the link on the pasteboard.
    case copy
    /// Kill the token. The row stays, struck through.
    case revoke
    /// Drop an already-revoked row from the list.
    case remove
}

// MARK: - Row

/// One share link's row.
///
/// Plain content on purpose, and for the same reason ``ClaudeClientRow`` is: the row sits inside
/// the Settings form, which already provides the surface, so a lens here would be the nested glass
/// the cluster rule exists to forbid. The consequence, stated because it is the part that gets
/// undone by accident: since it asks for no surface tier it has **no `ComponentCatalog` entry and
/// no snapshot goldens** — the ``FileExplorer`` rule. Add a surface here and the goldens start
/// describing a design that no longer exists.
///
/// The anatomy is ``SnapshotBrowser``'s row narrowed to a `Form`'s width: identity on the first
/// line, the thing itself on the second, provenance under that, and the destructive verbs in a
/// context menu rather than as buttons — a revoke that is one stray click away from a demo is a
/// revoke that will happen during one.
public struct ShareLinkRow: View {
    private let model: ShareLinkRowModel
    private let perform: (ShareLinkRowAction) -> Void

    /// Read from the environment the design system injects at the top of every window rather than
    /// taken in the initialiser: the appearance is not part of this row's value, it is the ambient
    /// the whole window already agreed on. A plain `@Environment` *value* keeps that without
    /// touching the global state the component lint forbids.
    @Environment(\.glassAppearance) private var context

    /// The word a dead link wears.
    ///
    /// Identity, like ``CloudShareStatus/label``, and kept next to the row that draws it so the
    /// struck-through name and the word can never drift into disagreeing about what happened.
    private static let revokedWord = "Revoked"

    public init(
        model: ShareLinkRowModel,
        perform: @escaping (ShareLinkRowAction) -> Void
    ) {
        self.model = model
        self.perform = perform
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: DS.Space.rowGap) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(model.name)
                        .font(DS.Text.controlEmphasis)
                        .foregroundStyle(model.isRevoked ? DS.Chrome.tertiary : DS.Chrome.primary)
                        .strikethrough(model.isRevoked)
                        .lineLimit(1)
                    Text(model.modeWord)
                        .font(DS.Text.control)
                        .foregroundStyle(DS.Chrome.secondary)
                    if model.isRevoked {
                        Text(Self.revokedWord)
                            .font(DS.Text.control)
                            .foregroundStyle(DS.Chrome.tertiary)
                    }
                }

                // Truncated in the middle and selectable, the workspace-path idiom: the
                // interesting parts of a share URL are the host and the token's tail, and the
                // reason someone stares at one is to check it against what they pasted.
                Text(model.urlDisplay)
                    .font(DS.Text.path)
                    .foregroundStyle(DS.Chrome.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .hoverTitle(model.urlDisplay)

                if !model.detailLine.isEmpty {
                    Text(model.detailLine)
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Chrome.tertiary)
                        .lineLimit(1)
                }

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

            // The sidebar's copy control, unchanged: icon-only, bordered, small. Its label is
            // spelled out for VoiceOver because a clipboard glyph on its own says "clipboard",
            // not "the thing you are about to send someone".
            Button {
                perform(.copy)
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(DS.Text.control)
            .hoverTitle(model.urlDisplay)
            .accessibilityLabel("Copy share link")
        }
        .contentShape(Rectangle())
        .contextMenu {
            if model.isRevoked {
                Button("Remove from list", role: .destructive) { perform(.remove) }
            } else {
                Button("Revoke", role: .destructive) { perform(.revoke) }
            }
        }
    }

    /// What VoiceOver reads instead of assembling the four fragments a sighted reader assembles
    /// from position and type weight.
    ///
    /// The revoked word is included rather than left to the strikethrough, which no screen reader
    /// announces — a link that reads as live because its only "dead" marker was a line through the
    /// glyphs is the exact failure this sentence exists to prevent.
    private var spokenSummary: String {
        var summary = "\(model.name), \(model.modeWord)"
        if model.isRevoked {
            summary += ", \(Self.revokedWord)"
        }
        summary += ". \(model.urlDisplay)"
        if !model.detailLine.isEmpty {
            summary += ". \(model.detailLine)"
        }
        if let rejection = model.rejection {
            summary += " \(rejection)"
        }
        return summary
    }
}
