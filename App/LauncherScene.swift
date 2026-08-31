import AppKit
import DocumentCore
import GlassUI
import SheetStore
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

    /// The Cloud Share master switch, on the key ``CloudShareService/enabledDefaultsKey`` reads.
    /// Bound rather than mirrored so a `defaults write` and a click land in the same place; the
    /// service is told about the change in `onChange`, because writing the key is not the same
    /// thing as opening a socket.
    @AppStorage("OSCloudShareEnabled") private var cloudShare = false

    /// One inline failure per client, in the launcher's rejection idiom: shown under the row
    /// that refused, cleared by that row's next success. Never an alert — a config file
    /// declining a write is a normal thing to be told, not an incident.
    @State private var rejections: [ClaudeClient: String] = [:]

    /// The same idiom one layer down, keyed by ``ShareLinkRecord/id``'s string: a relay that
    /// refuses a revocation says so under the row it refused, not in a dialog over the pane.
    @State private var linkRejections: [String: String] = [:]

    /// The create row's own failure line. Separate from ``linkRejections`` because a link that
    /// was never created has no row to hang a rejection under.
    @State private var createRejection: String?

    @State private var newLinkName = ""
    @State private var newLinkMode: ShareLinkMode = .readOnly

    private var context: AppearanceContext { appearance.context(for: colorScheme) }

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
            // Absent means absent. With `OSFlagCloudShare` off there is no section, no switch and
            // no row — not a disabled one — which is the same bar `Flags.explorerEnabled` meets in
            // the launcher: a feature that is off should be indistinguishable from a feature that
            // was never written. `app.share` is `nil` under exactly the same condition, so the
            // second half of this guard is the binding rather than a second opinion.
            if Flags.cloudShareEnabled, let service = app?.share {
                Section("Cloud") {
                    cloudToggle(for: service)
                    cloudStatusRow(for: service)
                    cloudCreateRow(for: service)
                    cloudLinkList(for: service)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
        // Settings used to pin itself to the light appearance while every other window followed
        // the system — same chrome, different rules. The decision lives here rather than in the
        // `Settings` scene because `colorScheme` is an environment fact only a view can read.
        .glassAppearance(context)
        .onAppear {
            app?.claude.refresh()
            app?.refreshMCPStatus()
            // The list is read here rather than at construction, which is what makes "off costs
            // nothing" true of the disk as well as the socket. `startIfEnabled` is a no-op when the
            // engine is already up; it exists here for the launch where the app came up before the
            // owner's switch was read, and it is cheap enough to be idempotent rather than clever.
            app?.share?.refresh()
            app?.share?.startIfEnabled()
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

    // MARK: - Settings ▸ Cloud

    /// The master switch.
    ///
    /// Two writes happen on a click and only one of them is redundant: `@AppStorage` writes the
    /// key, and ``CloudShareService/setEnabled(_:)`` writes it again and then acts on it. Binding
    /// the toggle straight to the service instead would have made the switch a computed property
    /// over an object that may not exist, and mirroring the key into `@State` would have made a
    /// `defaults write` invisible until relaunch. This way the key is the truth and the service is
    /// told, in that order.
    private func cloudToggle(for service: CloudShareService) -> some View {
        Toggle("Cloud Share", isOn: $cloudShare)
            .onChange(of: cloudShare) { _, enabled in
                service.setEnabled(enabled)
            }
    }

    /// Dot, word, sentence — `ClaudeClientRow`'s anatomy, rebuilt here rather than reused because
    /// that row is shaped around a client name and a button this one has neither of.
    private func cloudStatusRow(for service: CloudShareService) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            AgentDot(
                color: service.status.signal.ink(context),
                isActive: service.status == .online,
                reduceMotion: context.reduceMotion
            )
            .padding(.top, DS.Space.xs)

            VStack(alignment: .leading, spacing: DS.Space.rowGap) {
                Text(service.status.label)
                    .font(DS.Text.controlEmphasis)
                    .foregroundStyle(DS.Chrome.primary)
                Text(cloudStatusCaption(for: service))
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Chrome.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
        }
        .accessibilityElement(children: .combine)
    }

    /// The sentence under the status word.
    ///
    /// The *word* is GlassUI's, because a state's name is identity; every sentence here is policy
    /// and therefore App-layer. `offline` is the one case that defers to the service: the engine
    /// knows whether the socket never opened or the relay refused this Mac's credential, and
    /// inventing a vaguer sentence over the top of a specific one would be a downgrade. The second
    /// half is appended either way, because "retrying" is a promise the owner should not have to
    /// infer from a dash in a status word.
    private func cloudStatusCaption(for service: CloudShareService) -> String {
        var sentences: [String] = []
        switch service.status {
        case .disabled:
            sentences.append("Links answer offline to callers until you switch this on.")
        case .connecting:
            sentences.append("Reaching the relay. Links resolve as soon as this lands.")
        case .online:
            sentences.append("Links resolve to this Mac while OpenSheets is running.")
        case .offline:
            if let detail = service.statusDetail, !detail.isEmpty {
                sentences.append(detail)
                sentences.append("Links keep working when OpenSheets reconnects.")
            } else {
                sentences.append("Check your internet connection. Links keep working when OpenSheets reconnects.")
            }
        }
        // A revoke made while the socket was down is already enforced: the engine re-reads the row
        // on every inbound request, so the link is dead locally the instant the owner presses it.
        // What is pending is the relay's copy — the fast path — and that is all this sentence
        // claims, because promising more would be promising something the Mac does not control.
        if service.status != .online, service.links.contains(where: { !$0.isActive }) {
            sentences.append("Revocations sync when back online.")
        }
        return sentences.joined(separator: " ")
    }

    /// Name, mode, create — the whole feature from the owner's side, on one row.
    ///
    /// The caption under it is the consent line, in the Claude section's sense: the button is the
    /// consent, so the caption has to say what is being consented to, in the plainest available
    /// words. It is deliberately not softened — a share link is a capability over every granted
    /// folder, and a sentence that made that sound smaller would be the bug.
    private func cloudCreateRow(for service: CloudShareService) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                TextField("Who is this for? e.g. Ana", text: $newLinkName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { createLink(in: service) }
                Picker("Access", selection: $newLinkMode) {
                    ForEach(ShareLinkMode.allCases, id: \.self) { mode in
                        Text(Self.modeWord(for: mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Create & Copy") { createLink(in: service) }
                    .disabled(!canCreateLink)
            }

            Text("Anyone with this link can read your granted folders. Read & write links can also edit.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Chrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let createRejection {
                Label(createRejection, systemImage: "exclamationmark.circle")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Signal.errorInk(context))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The links, or the sentence that explains what a link is for.
    ///
    /// Revoked rows stay in the list until the owner removes them, which is why this is not
    /// `links.isEmpty ? caption : rows` over active links only: "I killed that one" should be
    /// something you can see rather than something you have to remember.
    @ViewBuilder
    private func cloudLinkList(for service: CloudShareService) -> some View {
        if service.links.isEmpty {
            Text("Share links let ChatGPT, Claude, or Gemini work with your granted folders through OpenSheets. Create & Copy creates one and copies it.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Chrome.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(service.links) { record in
                ShareLinkRow(model: rowModel(for: record)) { action in
                    perform(action, on: record, in: service)
                }
            }
        }
    }

    /// `ShareLinkRecord` → row model. Every string the row draws is written on this side of the
    /// line: GlassUI owns no clock and no locale, and "Created just now" is a sentence about a
    /// date rather than a fact about a link.
    private func rowModel(for record: ShareLinkRecord) -> ShareLinkRowModel {
        ShareLinkRowModel(
            id: record.id.rawValue,
            name: record.name,
            modeWord: Self.modeWord(for: record.mode),
            urlDisplay: record.url,
            createdDetail: "Created \(Self.relativeWords(for: record.createdAt))",
            // Empty rather than "Never used": `detailLine` drops empty fragments, so a fresh link
            // reads "Created just now" instead of "Created just now · Never used", and the absence
            // of the phrase is already the whole of what it would have said.
            lastUsedDetail: record.lastUsedAt.map { "Last used \(Self.relativeWords(for: $0))" } ?? "",
            isRevoked: !record.isActive,
            rejection: linkRejections[record.id.rawValue]
        )
    }

    /// The two legal spellings, in one place, so the picker and the rows cannot disagree about
    /// what a mode is called. Identity, per ``ShareLinkRowModel/modeWord``'s note — a third
    /// spelling would be a bug rather than a synonym.
    private static func modeWord(for mode: ShareLinkMode) -> String {
        switch mode {
        case .readOnly: "Read only"
        case .readWrite: "Read & write"
        }
    }

    /// Anything younger than this reads as "just now".
    ///
    /// `RelativeDateTimeFormatter` says "in 0 seconds" about a link created a moment ago — the
    /// formatter is right and the sentence is nonsense, and the row that appears the instant you
    /// press Create is exactly the row people read.
    private static let justNow: TimeInterval = 60

    private static func relativeWords(for date: Date, relativeTo now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= justNow else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private var trimmedLinkName: String {
        newLinkName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The service enforces this and throws a sentence when it is violated. Mirrored here so the
    /// button is simply not pressable rather than pressable-and-then-scolded — the rejection line
    /// is for failures the owner could not have seen coming, and an empty name is not one.
    private var canCreateLink: Bool {
        (1...CloudShareService.maximumNameLength).contains(trimmedLinkName.count)
    }

    /// Create, then copy — in that order, and the copy is the point.
    ///
    /// The plaintext token exists in exactly two places: the database row, and this pasteboard
    /// write. `clearContents()` before `setString` is the pasteboard's own requirement rather than
    /// tidiness; without it the old contents can survive alongside the new ones under a different
    /// type, which for a capability URL is a leak of the previous one.
    private func createLink(in service: CloudShareService) {
        guard canCreateLink else { return }
        do {
            let record = try service.createLink(name: trimmedLinkName, mode: newLinkMode)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.url, forType: .string)
            newLinkName = ""
            createRejection = nil
        } catch {
            createRejection = error.message
        }
    }

    /// The row's three verbs. Revoke asks nothing first — the destructive role and a row that
    /// visibly greys out are the affordance, and this app has no confirmation-dialog precedent to
    /// borrow. Remove is only ever offered on a revoked row, by the row itself, and the service
    /// refuses it for an active link regardless of what this sends.
    private func perform(
        _ action: ShareLinkRowAction,
        on record: ShareLinkRecord,
        in service: CloudShareService
    ) {
        switch action {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.url, forType: .string)
            linkRejections[record.id.rawValue] = nil
        case .revoke:
            do {
                try service.revoke(id: record.id)
                linkRejections[record.id.rawValue] = nil
            } catch {
                linkRejections[record.id.rawValue] = error.message
            }
        case .remove:
            do {
                try service.remove(id: record.id)
                // The row is gone, so its rejection has nowhere to be shown and would otherwise
                // outlive it — visibly, if the owner ever creates a link that lands on the same id.
                linkRejections[record.id.rawValue] = nil
            } catch {
                linkRejections[record.id.rawValue] = error.message
            }
        }
    }
}
