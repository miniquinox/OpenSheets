import SwiftUI

/// One message in the sheet chat's transcript.
///
/// A value, pre-rendered by the controller, like every other state this package draws: the view
/// does not know what a language model is, which is what lets the gallery and the snapshot tests
/// show a conversation without one.
public struct ChatMessage: Sendable, Hashable, Identifiable {
    public enum Role: Sendable, Hashable {
        /// The person. Rendered trailing, on an accent chip.
        case user
        /// The model. Rendered leading, as plain text.
        case assistant
        /// The system explaining itself — "earlier messages were dropped". Centred caption.
        case notice
    }

    public var id: Int
    public var role: Role
    public var text: String
    /// `via read_cells, write_cells` — what the answer touched, shown small under it. The
    /// transparency matters: an answer that quietly edited the sheet is the failure mode.
    public var toolNote: String?
    /// Still receiving text. The row shows a working state instead of an empty bubble.
    public var isStreaming: Bool

    public init(
        id: Int,
        role: Role,
        text: String,
        toolNote: String? = nil,
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolNote = toolNote
        self.isStreaming = isStreaming
    }
}

/// Everything the chat surface draws. Owned by `SheetChat`'s controller; this package only
/// renders it.
public struct ChatSurfaceState: Sendable, Hashable {
    public var messages: [ChatMessage]
    public var isResponding: Bool
    /// `nil` when the model is ready. Otherwise the sentence the panel shows instead of an
    /// input field — an honest empty state, not a dead one (PLAN.md §1.4).
    public var unavailableReason: String?
    /// Offered when the transcript is empty. Tapping one sends it.
    public var suggestions: [String]

    public init(
        messages: [ChatMessage] = [],
        isResponding: Bool = false,
        unavailableReason: String? = nil,
        suggestions: [String] = []
    ) {
        self.messages = messages
        self.isResponding = isResponding
        self.unavailableReason = unavailableReason
        self.suggestions = suggestions
    }
}

public enum ChatSurfaceAction: Sendable, Hashable {
    case expand
    case collapse
    case send(String)
    case stop
    case clear
}

/// The sheet chat: a glass bubble in the bottom-right that becomes the conversation.
///
/// Same construction as ``SyncSurface``, and deliberately so — one ``GlassCluster``, one
/// ``GlassMorphID`` carried by both shapes, surface on `DS.Motion.standard` with content on its
/// own settle — because the bubble→panel morph is the app's signature gesture and a second
/// floating surface that transitioned differently would read as a different app.
public struct ChatSurface: View {
    /// Owned by A8, like the sync surface's phase: the surface is stateless so the menu bar,
    /// ⌥⌘C and the bubble itself can all drive the same bit.
    public enum Phase: String, Sendable, Hashable, CaseIterable {
        case hidden
        case bubble
        case panel
    }

    private let phase: Phase
    private let state: ChatSurfaceState
    private let context: AppearanceContext
    private let perform: (ChatSurfaceAction) -> Void

    @Namespace private var morphNamespace

    public init(
        phase: Phase,
        state: ChatSurfaceState,
        context: AppearanceContext,
        perform: @escaping (ChatSurfaceAction) -> Void
    ) {
        self.phase = phase
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        GlassCluster {
            switch phase {
            case .hidden:
                EmptyView()
            case .bubble:
                ChatBubble(isResponding: state.isResponding, context: context, perform: perform)
                    .glassMorph(.chatSurface, in: morphNamespace)
                    .glassMorphTransition(context)
                    .transition(Self.zoom(context))
            case .panel:
                ChatPanel(state: state, context: context, perform: perform)
                    .glassMorph(.chatSurface, in: morphNamespace)
                    .glassMorphTransition(context)
                    .transition(Self.zoom(context))
            }
        }
        .animation(DS.Motion.morph(context), value: phase)
    }

    /// The grow/shrink half of the gesture: the panel inflates out of the bubble's corner and
    /// deflates back into it, anchored bottom-trailing where both shapes live. Layered on the
    /// lens morph — the glass stretches while the content scales — which is what makes the
    /// expansion read as the system's own zoom rather than a swap. Under `reduceMotion`, a
    /// cross-fade, for ``SwiftUI/View/glassMorphTransition(_:)``'s exact reason.
    private static func zoom(_ context: AppearanceContext) -> AnyTransition {
        context.reduceMotion
            ? .opacity
            : .scale(scale: 0.35, anchor: .bottomTrailing).combined(with: .opacity)
    }
}

// MARK: - The bubble

/// The Apple Intelligence glyph in a round frosted lens — the system volume HUD's grammar: an
/// icon the OS has already taught, on the ``GlassTier/hud`` frost so it reads as a control and
/// not as a dark window onto the grid.
public struct ChatBubble: View {
    private let isResponding: Bool
    private let context: AppearanceContext
    private let perform: (ChatSurfaceAction) -> Void

    public init(
        isResponding: Bool,
        context: AppearanceContext,
        perform: @escaping (ChatSurfaceAction) -> Void
    ) {
        self.isResponding = isResponding
        self.context = context
        self.perform = perform
    }

    /// The system volume HUD's proportions: one glyph in a round frosted lens, no caption. The
    /// words moved to the tooltip and the accessibility label — an icon that needs a label next
    /// to it is an icon that is not doing its job, and this one is the OS's own.
    private static let diameter: CGFloat = 40

    public var body: some View {
        Button { perform(.expand) } label: {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 20, weight: .medium))
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(DS.Chrome.primary)
                .symbolEffect(.pulse, isActive: isResponding && !context.reduceMotion)
                .frame(width: Self.diameter, height: Self.diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassPill(context: context, frosted: true)
        .hoverTitle("Ask your sheet — ⌥⌘C")
        .accessibilityLabel(isResponding ? "Sheet chat, answering" : "Ask your sheet")
        .accessibilityHint("Opens the sheet chat")
    }
}

// MARK: - The panel

/// The conversation. Fixed width like the diff panel, height capped so the transcript scrolls
/// rather than the panel growing past the window. Frosted (``GlassTier/hud``) rather than plain
/// floating glass: a transcript is read *on* the surface, not through it, and the frost is what
/// keeps three paragraphs legible over a grid of numbers.
public struct ChatPanel: View {
    private let state: ChatSurfaceState
    private let context: AppearanceContext
    private let perform: (ChatSurfaceAction) -> Void

    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    private enum Metrics {
        static let width: CGFloat = 340
        static let transcriptHeight: CGFloat = 320
    }

    public init(
        state: ChatSurfaceState,
        context: AppearanceContext,
        perform: @escaping (ChatSurfaceAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DS.Chrome.separator(context))
            if let reason = state.unavailableReason {
                unavailable(reason)
            } else {
                transcript
                Divider().overlay(DS.Chrome.separator(context))
                inputRow
            }
        }
        .frame(width: Metrics.width)
        // Frosted like the bubble it morphs out of — both ends of a morph are one lens, and a
        // lens that changes recipe mid-flight reads as a cross-fade between two objects.
        .glassCard(context: context, frosted: true)
        .onExitCommand { perform(.collapse) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sheet chat")
    }

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(DS.Chrome.accent)
            Text("Ask your sheet")
                .font(DS.Text.panelTitle)
                .foregroundStyle(DS.Chrome.primary)
            Text("On-device")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Chrome.tertiary)
                .hoverTitle("Runs entirely on this Mac with Apple Intelligence. Nothing leaves it.")
            Spacer(minLength: 0)
            if !state.messages.isEmpty {
                Button { perform(.clear) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Chrome.secondary)
                        .padding(DS.Space.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverTitle("Clear the conversation")
                .accessibilityLabel("Clear conversation")
            }
            Button { perform(.collapse) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Chrome.secondary)
                    .padding(DS.Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse to bubble")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.s) {
                    if state.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(state.messages) { message in
                            ChatMessageRow(message: message, context: context)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Metrics.transcriptHeight)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: state.messages) {
                guard let last = state.messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
            .onAppear {
                guard let last = state.messages.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// What an empty conversation offers. The pitch line earns its row by answering the two
    /// questions everyone asks a built-in assistant: what can it see, and where do my words go.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(
                "Ask about this spreadsheet, or ask for an edit. The model runs on this Mac and can read the sheet and write cells — every edit is one ⌘Z away."
            )
            .font(DS.Text.body)
            .foregroundStyle(DS.Chrome.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(state.suggestions, id: \.self) { suggestion in
                Button { perform(.send(suggestion)) } label: {
                    Text(suggestion)
                        .font(DS.Text.control)
                        .foregroundStyle(DS.Chrome.primary)
                        .padding(.horizontal, DS.Space.m)
                        .padding(.vertical, DS.Space.xs)
                        .background {
                            Capsule(style: .continuous).fill(DS.Chrome.separator)
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityHint("Sends this question")
            }
        }
        .padding(.vertical, DS.Space.s)
    }

    private func unavailable(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Label {
                Text(reason)
                    .font(DS.Text.body)
                    .foregroundStyle(DS.Chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "sparkles.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.Chrome.tertiary)
            }
        }
        .padding(DS.Space.l)
        .accessibilityLabel(reason)
    }

    private var inputRow: some View {
        HStack(spacing: DS.Space.s) {
            TextField("Ask about this sheet…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(DS.Text.body)
                .lineLimit(1 ... 4)
                .focused($isFieldFocused)
                .onSubmit(sendDraft)
                .accessibilityLabel("Message")

            if state.isResponding {
                Button { perform(.stop) } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(DS.Chrome.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop responding")
            } else {
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(canSend ? DS.Chrome.accent : DS.Chrome.tertiary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .onAppear { isFieldFocused = true }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !state.isResponding else { return }
        draft = ""
        perform(.send(text))
    }
}

// MARK: - One row

/// One transcript row. The roles are told apart by *position and surface*, not by naming them:
/// the user's words sit trailing on an accent chip, the model's sit leading as plain text — the
/// convention every chat UI since SMS has taught.
public struct ChatMessageRow: View {
    private let message: ChatMessage
    private let context: AppearanceContext

    public init(message: ChatMessage, context: AppearanceContext) {
        self.message = message
        self.context = context
    }

    public var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(DS.Text.body)
                .foregroundStyle(DS.Chrome.onAccent)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.chipY + DS.Space.hair)
                .background {
                    DS.Radius.shape(DS.Radius.control).fill(DS.Chrome.accent)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("You said: \(message.text)")
        case .assistant:
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if message.text.isEmpty, message.isStreaming {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.Chrome.tertiary)
                            .symbolEffect(.pulse, isActive: !context.reduceMotion)
                        Text("Reading the sheet…")
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Chrome.tertiary)
                    }
                    .accessibilityLabel("Thinking")
                } else {
                    Text(message.text)
                        .font(DS.Text.body)
                        .foregroundStyle(DS.Chrome.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel("Assistant said: \(message.text)")
                }
                if let note = message.toolNote {
                    Text(note)
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Chrome.tertiary)
                        .accessibilityLabel("Answered \(note)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notice:
            Text(message.text)
                .font(DS.Text.caption)
                .foregroundStyle(DS.Chrome.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, DS.Space.hair)
        }
    }
}
