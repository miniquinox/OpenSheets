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

/// Preferences. Short on purpose — except Claude, which is the connect/disconnect UI and earns
/// its rows: registration used to be a command the user pasted into a shell, and the whole point
/// of the pane is that the labelled button now *is* that user action.
struct PreferencesView: View {
    let app: AppModel?
    let appearance: AccessibilityAppearance

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("OSAutoSave") private var autoSave = false
    @AppStorage("OSFlagSnapshots") private var snapshots = true
    @AppStorage("OSFlagMCP") private var mcp = true

    /// One inline failure per client, in the launcher's rejection idiom: shown under the row
    /// that refused, cleared by that row's next success. Never an alert — a config file
    /// declining a write is a normal thing to be told, not an incident.
    @State private var rejections: [ClaudeClient: String] = [:]

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
                if let app {
                    serverRow(for: app)
                    clientRow(for: .claudeCode, in: app)
                    clientRow(for: .claudeDesktop, in: app)
                    LabeledContent("Granted folders", value: "\(app.grants.count)")
                }
                Toggle("Show MCP status", isOn: $mcp)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        // Settings used to pin itself to the light appearance while every other window followed
        // the system — same chrome, different rules. The decision lives here rather than in the
        // `Settings` scene because `colorScheme` is an environment fact only a view can read.
        .glassAppearance(appearance.context(for: colorScheme))
        .onAppear {
            app?.claude.refresh()
            app?.refreshMCPStatus()
        }
    }

    // MARK: - Settings ▸ Claude

    /// The binary a Connect click would register, or the honest absence. `DetailRow` rather than
    /// `LabeledContent` because middle truncation is the row's own behaviour, and a path is read
    /// by its two ends.
    @ViewBuilder
    private func serverRow(for app: AppModel) -> some View {
        if let binary = app.claude.serverBinary {
            DetailRow("Server", binary.path(percentEncoded: false), monospaced: true)
        } else {
            DetailRow("Server", "missing from this build")
        }
    }

    private func clientRow(for client: ClaudeClient, in app: AppModel) -> some View {
        ClaudeClientRow(model: rowModel(for: client, in: app)) { action in
            switch action {
            case .buttonTapped:
                performClientAction(for: client, in: app)
            }
        }
    }

    /// `ClaudeConnection` → row model. The captions are written here and not in GlassUI because
    /// they are policy, not presentation: what a click will actually do (the consent line — the
    /// button is the consent, so the caption must say what it consents to), whether Desktop needs
    /// a restart, where a missing client can be downloaded. The row only knows how to draw them.
    private func rowModel(for client: ClaudeClient, in app: AppModel) -> ClaudeClientRowModel {
        let name = client == .claudeCode ? "Claude Code" : "Claude Desktop"
        let hasBinary = app.claude.serverBinary != nil
        let missingBinary = "The server binary is missing from this build."
        let status: ClaudeClientRowModel.Status
        let caption: String
        var buttonLabel: String?
        var buttonEnabled = false

        switch app.claude.connections[client] ?? .notInstalled {
        case .notInstalled:
            status = .notInstalled
            // No button at all rather than a disabled Connect: there is no config file to write
            // for a client that has never run, so the pointer is the only useful control.
            caption = client == .claudeCode
                ? "Not installed — get it at claude.com/code"
                : "Not installed"
        case .notConnected:
            status = .notConnected
            let consent = client == .claudeCode
                ? "Adds an `opensheets` entry to ~/.claude.json. A backup is kept beside it."
                : "Adds an entry to Claude Desktop's config. A backup is kept beside it."
            caption = hasBinary ? consent : "\(consent) \(missingBinary)"
            buttonLabel = "Connect"
            buttonEnabled = hasBinary
        case let .connected(command):
            status = .connected
            caption = client == .claudeCode
                ? "Registered at \(command). New Claude Code sessions will see it."
                : "Registered at \(command). Restart Claude Desktop to pick it up."
            buttonLabel = "Disconnect"
            buttonEnabled = true
        case .stale:
            status = .stale
            caption = "Connected, but the registered binary is missing."
            buttonLabel = "Reconnect"
            buttonEnabled = hasBinary
        case let .unreadable(reason):
            status = .unreadable
            // The reason *is* the caption — the connector already wrote the sentence ("could not
            // be parsed, so it was not modified"), and repeating it in different words here would
            // be two spellings of one refusal.
            caption = reason
        }

        return ClaudeClientRowModel(
            clientName: name,
            status: status,
            caption: caption,
            buttonLabel: buttonLabel,
            buttonEnabled: buttonEnabled,
            rejection: rejections[client]
        )
    }

    /// The app's only connect/disconnect call sites. Keeping them here, behind the labelled
    /// button, is the enforced half of the policy line: the deny list keeps the *agent* out of
    /// Claude's config, and this pane is where the *user's* action lives.
    private func performClientAction(for client: ClaudeClient, in app: AppModel) {
        do {
            switch app.claude.connections[client] {
            case .connected:
                try app.claude.disconnect(client)
            case .notConnected, .stale:
                // Reconnect is a connect: the same write with a freshly resolved binary path.
                try app.claude.connect(client)
            case .notInstalled, .unreadable, .none:
                // These states draw no button; an action that arrives anyway has nothing to do.
                break
            }
            rejections[client] = nil
        } catch {
            rejections[client] = error.message
        }
        // The connector refreshed itself, but the sidebar's readout maps through `AppModel` —
        // asking for both keeps the pane and the Claude panel telling one story, live.
        app.claude.refresh()
        app.refreshMCPStatus()
    }
}
