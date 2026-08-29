import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

/// Where the document stands relative to the file on disk. PLAN.md §6.3.
///
/// This is the state machine's public face — one chip in the titlebar, always visible, that names
/// the current state in a word. The point is that the app never has an *unlabelled* relationship
/// with the file: if it is not synced, the titlebar says which of the six ways it is not synced,
/// and the fix is one click away.
public enum SyncState: Sendable, Hashable {
    /// In step with the file.
    case synced
    /// In step, and the watcher is running. The everyday state.
    case watching
    /// The user turned the watcher off. Not an error, and not something to nag about.
    case watchingPaused
    /// The file changed and we have not applied it, with the number of changed cells.
    case stale(cellCount: Int)
    /// Local edits and disk edits disagree, with the number of unsaved edits.
    case conflict(localEdits: Int)
    /// Unsaved local edits, no external change.
    case dirty(localEdits: Int)
    /// Opened read-only, with the reason. PLAN.md §5.2 — refusing to save beats corrupting.
    case readOnly(reason: String)
    /// Deleted or moved while open.
    case missing
    /// Another process holds a lock.
    case locked(holder: String?)

    public var label: String {
        switch self {
        case .synced: "Synced"
        case .watching: "Watching"
        case .watchingPaused: "Paused"
        case let .stale(count): "\(count.formatted()) changed on disk"
        case let .conflict(edits): "Conflict · \(edits) unsaved"
        case let .dirty(edits): "\(edits) unsaved"
        case .readOnly: "Read-only"
        case .missing: "File missing"
        case .locked: "Locked"
        }
    }

    /// The sentence under the label when the chip is hovered or read by VoiceOver. Every unhappy
    /// state says what to do, not just what happened.
    public var detail: String {
        switch self {
        case .synced: "The file on disk matches this window."
        case .watching: "Watching the file for outside changes."
        case .watchingPaused: "Outside changes will not be noticed until you resume."
        case .stale: "Press ⌘R to review and apply them."
        case .conflict: "Choose Keep mine, Take disk, or Compare."
        case .dirty: "Press ⌘S to save."
        case let .readOnly(reason): reason
        case .missing: "Use File ▸ Save As to write it somewhere else."
        case let .locked(holder):
            holder.map { "\($0) has the file open." } ?? "Another app has the file open."
        }
    }

    public var symbolName: String {
        switch self {
        case .synced: "checkmark.circle"
        case .watching: "eye"
        case .watchingPaused: "eye.slash"
        case .stale: "arrow.clockwise"
        case .conflict: "exclamationmark.triangle.fill"
        case .dirty: "pencil"
        case .readOnly: "lock"
        case .missing: "questionmark.folder"
        case .locked: "lock.doc"
        }
    }

    public var signal: DS.SignalKind {
        switch self {
        case .synced, .watching, .watchingPaused, .dirty: .neutral
        case .stale: .agent
        case .conflict: .conflict
        case .readOnly, .locked: .neutral
        case .missing: .failure
        }
    }
}

/// The live state chip in the titlebar.
///
/// Sits next to the document name in a unified, transparent titlebar, so the grid scrolls under
/// it. It is a button: clicking it does the obvious thing for the state — review the changes,
/// resolve the conflict, resume watching — rather than opening a menu of things you could do.
public struct SyncStateChip: View {
    private let state: SyncState
    private let context: AppearanceContext
    private let action: () -> Void

    public init(state: SyncState, context: AppearanceContext, action: @escaping () -> Void) {
        self.state = state
        self.context = context
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: state.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(state.label)
                    .dsNumeric(DS.Text.numericCaption)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.chipY)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(state.label). \(state.detail)")
        .accessibilityLabel("\(state.label). \(state.detail)")
    }

    private var tint: Color {
        state.signal == .neutral ? DS.Signal.calmInk(context) : state.signal.ink(context)
    }
}

#if canImport(AppKit)
/// Window configuration for a document window.
///
/// Applied by A8 from `NSApplicationDelegate` or a `WindowAccessor`; it is here because the
/// titlebar is part of the surface treatment and the settings only make sense next to the reason
/// for them.
///
/// The one that matters is ``configureDocumentWindow(_:)``'s transparent, full-size-content
/// titlebar. Without it the window has an opaque titlebar strip above the toolbar, the grid stops
/// at its bottom edge, and `.backgroundExtensionEffect()` has nothing to extend into — which is
/// the difference between chrome that floats over the document and chrome that is bolted above it.
@MainActor
public enum WindowChrome {
    /// Transparent, unified, full-size content. Call once per document window.
    public static func configureDocumentWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        // Hidden, because the window draws its own. `TitleBarRow` shows the file name next to the
        // sync chip and the sidebar toggle; leaving AppKit's copy visible put the same file name
        // on screen twice, one above the other, once the titlebar strip stopped being covered by
        // an opaque window background.
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        // The grid is the window's background; anything the system paints behind it is a colour
        // the user would see for one frame during a live resize.
        window.backgroundColor = .clear
    }

    /// The launcher: no title, no toolbar, a single glass panel over the desktop (PLAN.md §1.1).
    public static func configureLauncherWindow(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove(.resizable)
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        // The launcher shares its `WindowGroup` with the document windows, so it arrives at their
        // `.defaultSize` — 1280×820 of window around a 720×520 card. With a clear background that
        // surplus is invisible and still solid: it swallows every click meant for the desktop
        // behind it, and drags the whole window when the user tries to select an icon.
        //
        // Guarded on the size actually being wrong, because this runs again whenever the hosting
        // view is reattached to the window, and an unguarded `center()` there would teleport a
        // window the user had deliberately dragged somewhere.
        let sized = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: LauncherWindow.panelSize)
        )
        guard window.frame.size != sized.size else { return }
        window.setContentSize(LauncherWindow.panelSize)
        window.center()
    }
}
#endif
