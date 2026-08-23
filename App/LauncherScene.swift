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

    private var context: AppearanceContext { appearance.context(for: colorScheme) }

    var body: some View {
        LauncherWindow(state: state, context: context) { action in
            perform(action)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(LauncherWindowConfigurator())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            OpenActions.handleDrop(providers)
        }
        .onAppear { app?.reloadRecents() }
    }

    private var state: LauncherState {
        LauncherState(
            recents: app?.recents ?? [],
            grants: (app?.grants ?? []).map { grant in
                WorkspaceGrantItem(
                    id: String(grant.id ?? 0),
                    path: grant.path,
                    grantedAt: grant.grantedAt.formatted(date: .abbreviated, time: .shortened),
                    fileCount: 0
                )
            },
            isDropTargeted: isTargeted,
            dropRejection: rejection
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
        case .grantFolder:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { app?.grantWorkspace(url) }
        case let .revokeGrant(id):
            guard let grant = app?.grants.first(where: { String($0.id ?? 0) == id }) else { return }
            app?.revokeGrant(grant)
        case let .revealRecent(id):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: id)])
        case let .removeRecent(id):
            _ = id
            app?.reloadRecents()
        default:
            break
        }
    }
}

/// Preferences. Short on purpose.
struct PreferencesView: View {
    let app: AppModel?
    @AppStorage("OSAutoSave") private var autoSave = false
    @AppStorage("OSFlagAutoRefresh") private var autoRefresh = true
    @AppStorage("OSFlagSnapshots") private var snapshots = true
    @AppStorage("OSFlagMCP") private var mcp = true

    var body: some View {
        Form {
            Section("Syncing") {
                Toggle("Refresh automatically when the file changes", isOn: $autoRefresh)
                Text("With this off, OpenSheets still notices the change and offers ⌘R.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
