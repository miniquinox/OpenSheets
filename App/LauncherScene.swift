import AppKit
import DocumentCore
import GlassUI
import SwiftUI
import UniformTypeIdentifiers

/// PLAN.md §1.1 — the first-run window: recents, a drop target, and the workspace grants.
///
/// A single glass panel over the desktop, and the one place in the app where a glass card floats
/// over nothing: there is no document plane yet, so the desktop *is* the backdrop. Everywhere
/// else, glass sits on the grid.
struct LauncherScene: View {
    let app: AppModel?
    let appearance: AccessibilityAppearance

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargeted = false
    @State private var rejection: String?

    /// The row the rail lights up. Local to the launcher, because "the file you last clicked" is a
    /// fact about this window rather than about the workspace — a document window's sidebar
    /// answers the same question with the file it is showing.
    @State private var explorerSelection: String?

    private var context: AppearanceContext { appearance.context(for: colorScheme) }

    /// Read in one place so the window, its configurator and its content cannot disagree about
    /// which launcher this is. Off must cost nothing: no rail, no state mapping, no listing.
    private var isExplorerEnabled: Bool { Flags.explorerEnabled }

    private var windowSize: CGSize { LauncherWindow.panelSize(explorerEnabled: isExplorerEnabled) }

    var body: some View {
        LauncherWindow(state: state, context: context) { action in
            perform(action)
        }
        .frame(minWidth: windowSize.width, minHeight: windowSize.height)
        // The titlebar is a safe-area inset even with `.fullSizeContentView` and a hidden title,
        // so a card asked to fill the window filled everything *below* it and left a 28pt band of
        // clear glass across the top with the close button floating in it. Applied here rather
        // than inside the component: a window's titlebar is not something a reusable card should
        // know about, and the gallery renders the same view with no window at all.
        .ignoresSafeArea()
        .background(LauncherWindowConfigurator(explorerEnabled: isExplorerEnabled))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            OpenActions.handleDrop(providers)
        }
        .onAppear { app?.reloadRecents() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshExplorer()
        }
    }

    private var state: LauncherState {
        LauncherState(
            recents: app?.recents ?? [],
            explorer: explorerState,
            isDropTargeted: isTargeted,
            dropRejection: rejection
        )
    }

    /// The rail, or `nil` when the flag is off — which renders exactly the launcher that shipped
    /// before this feature, at its old size.
    private var explorerState: FileExplorerState? {
        guard isExplorerEnabled, let app else { return nil }
        return WorkspaceExplorerState.explorer(
            for: app.explorer,
            selection: explorerSelection,
            offersAddFolder: true
        )
    }

    private func perform(_ action: LauncherAction) {
        switch action {
        case let .open(id):
            // A recent is a click in our own UI, but on a file the user chose some other day. If
            // its folder is no longer granted — revoked, most likely, which is a decision — that
            // is worth asking about rather than silently undoing. See `WorkspaceConsent`.
            OpenActions.open(URL(fileURLWithPath: id))
        case .openFile:
            OpenActions.showOpenPanel()
        case .newSheet:
            OpenActions.showOpenPanel()
        case .grantFolder, .explorer(.addFolder):
            grantFolder()
        case let .revealRecent(id):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
        case let .removeRecent(id):
            _ = id
            app?.reloadRecents()
        case let .explorer(explorerAction):
            performExplorer(explorerAction)
        default:
            break
        }
    }

    // MARK: - The rail

    private func performExplorer(_ action: FileExplorerAction) {
        guard let app else { return }
        switch action {
        case .addFolder:
            grantFolder()
        case let .toggle(id):
            app.explorer.toggle(id)
        case let .open(id):
            // `.fromOutsideTheApp`, the default and the careful one. The click happened in our own
            // UI, but the file's folder is already granted, so asking costs nothing here and is
            // the honest case for a path that arrived from a directory listing. Same call the
            // recents make, so a file opens the same way whichever half of the window found it.
            OpenActions.open(URL(fileURLWithPath: id))
        case let .select(id):
            explorerSelection = id
        case let .refresh(id):
            app.explorer.refresh(id)
        case let .revealInFinder(id):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
        case let .closeFolder(id):
            // The tree only. Closing a folder is tidying, not a permission change.
            app.explorer.unpin(id)
            if explorerSelection == id { explorerSelection = nil }
        case let .revokeFolder(id):
            app.explorer.unpin(id)
            guard let grant = app.grant(forRootID: id) else { return }
            app.revokeGrant(grant)
        case let .search(text):
            app.explorer.search = text
        }
    }

    /// The panel, the grant, and the two things that have to happen after it.
    ///
    /// `rejection` is cleared first and set on failure, which is the whole of "a refused grant says
    /// nothing": `AppModel.grantWorkspace` has always written `lastError`, and until now no view
    /// read it, so a deny-listed folder closed the panel and changed the window in no way at all.
    private func grantFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rejection = nil
        app?.clearLastError()
        guard app?.grantWorkspace(url) == true else {
            rejection = app?.lastError?.errorDescription ?? "That folder could not be granted."
            return
        }
        // Granting a folder *opens* it: the workspace window comes up with the tree on the left
        // and nothing in it, and this window goes away. Revealing it in the launcher's own rail
        // was the obvious thing and it was wrong — the folder people pick is usually inside one
        // they already granted, so it is not a new root, and the reveal put it forty rows down an
        // expanded subtree where nothing appeared to have happened at all.
        //
        // `expandNewRoot` still runs, for the case where the workspace window is already up and
        // `openWorkspace` resolves to a reveal rather than a new window.
        app?.explorer.expandNewRoot(url)
        OpenActions.openWorkspace(folder: url)
    }

    /// Re-lists every root when the app comes forward.
    ///
    /// The tree does not watch the filesystem, and says so: `FileWatcher` costs two descriptors
    /// per file and `~/Documents` holds 77,024 directories. So a file created in Finder appears
    /// only when something asks, and coming back to the app is the moment the user most expects
    /// it to have. On application activation rather than `NSWindow.didBecomeKeyNotification`,
    /// which is posted for every window in the process and would need a window reference this
    /// scene does not otherwise want.
    private func refreshExplorer() {
        guard isExplorerEnabled, let app else { return }
        for root in app.explorer.nodes where root.depth == 0 {
            app.explorer.refresh(root.id)
        }
    }
}

/// Preferences. Short on purpose.
struct PreferencesView: View {
    let app: AppModel?
    @AppStorage("OSAutoSave") private var autoSave = false
    @AppStorage("OSFlagSnapshots") private var snapshots = true
    @AppStorage("OSFlagMCP") private var mcp = true

    var body: some View {
        Form {
            Section("Syncing") {
                // Watching is not a preference. The app's whole reason to be open is that an agent
                // is editing the file underneath it, so a switch for "do not notice that" is a
                // switch for not using it — and every surface that offered one was a control that
                // made the window worse without making anything possible.
                Toggle("Keep snapshots before every refresh and save", isOn: $snapshots)
            }
            Section("Saving") {
                Toggle("Save automatically", isOn: $autoSave)
                // PLAN.md §5: off by default, and the reason is worth saying out loud rather than
                // leaving as a surprising default.
                Text("Off by default: a background save racing an agent's write is a bad surprise.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Claude") {
                Toggle("Show MCP status", isOn: $mcp)
                if let app {
                    LabeledContent("Granted folders", value: "\(app.grants.count)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}
