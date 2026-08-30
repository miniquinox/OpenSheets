#if canImport(AppKit)
import AppKit
#endif
import Foundation
import GlassUI
import Observation
import SheetModel
import SheetStore

/// How the app came to be opening a file, and therefore whether granting its parent folder to
/// Claude Code needs a second, explicit yes.
///
/// # Why this is not one rule for everybody
///
/// PLAN.md §1.1 says opening a file grants its parent folder, and it has to: the CLI and the MCP
/// server cannot mint a grant by construction (neither links AppKit), so the app is the **only**
/// path to a first grant. Without it a user's first Claude Code call fails with
/// `grant.outsideWorkspace` and there is no obvious way forward.
///
/// But a grant is a real permission — read *and* write over every file in that folder, for an
/// agent, indefinitely — and the gestures that reach ``AppModel/openDocument(at:consent:)`` are
/// not equally strong:
///
/// - ``userSelectedInPanel`` is an `NSOpenPanel` or `NSSavePanel` result. The user navigated into
///   that folder and picked something in it a moment ago; that *is* the consent gesture, and it
///   is the one ``SheetStore/UserGrantAuthorization`` was designed around. No second prompt.
/// - ``fromOutsideTheApp`` is a path we were handed: `argv`, `open(1)`, a Finder double-click, a
///   drag from another application. The user asked to *see a spreadsheet*; nothing in that
///   gesture says "and give an agent the run of this folder". So we ask, once per folder, and
///   name the folder in the question.
///
/// The default is ``fromOutsideTheApp`` on purpose: a call site that forgets to say gets the
/// careful answer, not the permissive one.
public enum WorkspaceConsent: Sendable, Hashable {
    /// The user picked this file in one of our own panels.
    case userSelectedInPanel
    /// The path arrived from outside the app.
    case fromOutsideTheApp
}

/// Process-wide state: the store, the recents, the grants, and the MCP status.
///
/// One of these, unlike ``DocumentModel``. The distinction is the whole point of both: anything
/// that belongs to *a document* is per document, and anything that belongs to *the app* is here.
/// The list is deliberately short — recents, grants, preferences, MCP — because everything else
/// somebody is tempted to put in a shared model turns out on inspection to belong to a window.
@MainActor
@Observable
public final class AppModel {
    /// The database, the snapshot store, the grant boundary, and — the one that matters —
    /// **the one `SelfWriteSuppressor` this process has** (addendum §9). The MCP server in the
    /// other process shares its effect through the same on-disk database.
    @ObservationIgnored public let store: SheetStore
    @ObservationIgnored public let reader = DocumentWorkbookReader()
    @ObservationIgnored public let writer = DocumentWorkbookWriter()

    public private(set) var recents: [RecentItem] = []
    public private(set) var grants: [WorkspaceGrant] = []

    /// The granted folders as a browsable tree. One per process, so the launcher and every
    /// document window's sidebar are looking at the same expansion state rather than at two
    /// copies that drift apart the moment one of them lists a folder.
    ///
    /// `@ObservationIgnored` because the tree is `@Observable` in its own right: a view that
    /// reads `explorer.nodes` depends on `nodes`, and re-rendering it whenever anything else on
    /// `AppModel` changes would be a dependency on the wrong thing.
    @ObservationIgnored public let explorer: WorkspaceTree

    /// Settings ▸ Claude's connect/disconnect machinery, and the reader behind ``mcpStatus``.
    ///
    /// `@ObservationIgnored` for ``explorer``'s reason: the connector is `@Observable` in its
    /// own right, so a view that reads `claude.connections` depends on exactly that —
    /// re-rendering it whenever anything else on `AppModel` changes would be a dependency on
    /// the wrong thing.
    @ObservationIgnored public let claude: ClaudeConnector
    public private(set) var mcpStatus: MCPStatus = .notConfigured
    public private(set) var lastError: SheetError?

    /// PLAN.md §5: auto-save is **off** by default. A background save racing an agent's write is
    /// a bad surprise, and the whole product is built around an agent writing the same file.
    public var autoSaveEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "OSAutoSave") }
        set { UserDefaults.standard.set(newValue, forKey: "OSAutoSave") }
    }

    /// Documents currently open, keyed by resolved path.
    ///
    /// Weak, so a closed window's model can go away. PLAN.md §9's *"same file open in two
    /// windows"* resolves here: the second window finds the live model and shares it rather than
    /// opening a second session on the same file, which would give the file two watchers, two
    /// undo stacks and two opinions about whether it is dirty.
    @ObservationIgnored private var open: [String: WeakDocument] = [:]

    /// Opens that have started and not finished, keyed the same way as ``open``.
    ///
    /// Without this the "one model per file" rule holds only for opens that do not overlap.
    /// ``openDocument(at:consent:)`` suspends twice — once to parse the workbook, once to start
    /// the session — and the lookup that decides whether a model already exists happens *before*
    /// both. Two windows asking for the same file in the same run-loop turn therefore both see
    /// "nothing open", and the file ends up with two sessions, two watchers and two opinions about
    /// whether it is dirty. Five windows, five of each — which is exactly the shape of the bug
    /// this exists to make impossible.
    ///
    /// Recording the *task* rather than a flag means the second caller gets the same model the
    /// first one is still building, instead of an error or a second read.
    @ObservationIgnored private var opening: [String: Task<DocumentModel, any Error>] = [:]

    private struct WeakDocument {
        weak var model: DocumentModel?
    }

    /// Asked before a folder is granted for an open the user did not initiate inside the app.
    ///
    /// Installed by the app target, which is the only layer that may put a panel on screen. `nil`
    /// refuses, which is the safe direction: a hook nobody installed must not become an open door.
    /// See ``WorkspaceConsent``.
    @ObservationIgnored public var confirmWorkspaceGrant: (@MainActor (URL) async -> Bool)?

    /// Whether documents opened from here watch their file. `nil` means yes, which is what the
    /// app always wants — **this is a test seam, not a preference.**
    ///
    /// The user-facing switch is gone: watching is the reason the app is open, so a control for
    /// turning it off was a control for not using the product. What remains is the ability for a
    /// suite to hold a document in `STALE` and assert on it. It is per-instance rather than a
    /// `UserDefaults` key on purpose — that key was process-wide, so a suite that set it to
    /// `false` and then suspended could have another set it back underneath, and the document
    /// under test would auto-refresh out of the state the test was waiting for. That failure read
    /// as a watcher bug and was not one.
    @ObservationIgnored public var autoRefreshForNewDocuments: Bool?

    /// Whether documents opened from here track changes against a baseline. `nil` asks
    /// ``Flags``, which is what the app wants.
    ///
    /// Here for the same reason as ``autoRefreshForNewDocuments``, and it is worth repeating
    /// rather than cross-referencing: `OSFlagChangeTracking` is process-wide, so a suite that
    /// wrote `false` to prove the flag removes the cost could have another suite write `true`
    /// back underneath it, and the assertion "no diff was ever computed" would fail somewhere
    /// else entirely. A per-instance value cannot be raced by a suite that does not share the
    /// instance.
    @ObservationIgnored public var changeTrackingForNewDocuments: Bool?

    public init(store: SheetStore) {
        self.store = store
        // `forAuxiliaryExecutable:` resolves against Contents/MacOS/, where `Scripts/build.sh`
        // places the server. Resolved here rather than inside the connector so a test process —
        // whose main bundle is the test runner — can hand it a temp binary instead.
        claude = ClaudeConnector(bundledBinary: Bundle.main.url(forAuxiliaryExecutable: "opensheets-mcp"))
        // Before the reloads, because `reloadGrants()` is what hands the tree its roots. The
        // extension set is the reader's, not the Open panel's four types: a folder listing that
        // hid the `.csv` next to the `.xlsx` would be hiding a file this app can open.
        // `storage: nil` with the flag off, and it is not a detail: the storage is what restores
        // last session's expanded folders, and restoring an expansion is what starts a directory
        // listing. Handing the tree its storage anyway would make "off" mean "the UI is hidden
        // while the work still happens", which is the one thing the flag promises it does not.
        explorer = WorkspaceTree(
            source: store.directories,
            fileExtensions: DocumentWorkbookReader.workbookExtensions
                .union(DocumentWorkbookReader.delimitedExtensions),
            storage: Flags.explorerEnabled
                ? DatabaseWorkspaceTreeStorage(database: store.database)
                : nil
        )
        reloadRecents()
        reloadGrants()
    }

    /// The standard configuration, or `nil` when the database will not open.
    public static func standard() -> AppModel? {
        guard let store = try? SheetStore(mode: .app) else { return nil }
        return AppModel(store: store)
    }

    // MARK: - Opening

    /// Opens a document, or returns the one already open on that path.
    ///
    /// **One ``DocumentModel`` per file, whatever the timing.** A path that is already open
    /// returns its live model; a path that is *being* opened joins that open rather than starting
    /// a second one. See ``opening``.
    ///
    /// The order inside is load-bearing and is A6's, not ours: the **grant is checked before the
    /// file is stat-ed**, because a denial that happens after a read has already told the caller
    /// whether the file exists.
    public func openDocument(
        at url: URL,
        consent: WorkspaceConsent = .fromOutsideTheApp
    ) async throws(SheetError) -> DocumentModel {
        let key = Self.documentKey(for: url)
        if let existing = open[key]?.model { return existing }

        let task: Task<DocumentModel, any Error>
        if let inFlight = opening[key] {
            task = inFlight
        } else {
            task = Task { [self] in try await load(url, key: key, consent: consent) }
            opening[key] = task
        }
        do {
            let model = try await task.value
            opening[key] = nil
            return model
        } catch {
            opening[key] = nil
            throw error as? SheetError
                ?? .cancelled(operation: "open \(url.lastPathComponent)")
        }
    }

    private func load(
        _ url: URL,
        key: String,
        consent: WorkspaceConsent
    ) async throws(SheetError) -> DocumentModel {
        let workspace = url.deletingLastPathComponent()
        // PLAN.md §1.1: opening a file grants its parent folder, one click, explained inline.
        // Doing it here rather than at the picker means drag-and-drop and `Open Recent` get the
        // same treatment as `Open…`, which is the only way the rule stays true.
        //
        // A grant is a real permission — it is what lets Claude Code read and write every file in
        // that folder — so *how* the path arrived decides whether the open is consent enough on
        // its own. See ``WorkspaceConsent``.
        var grantedNow: URL?
        if !store.grants.isAllowed(url) {
            if consent == .fromOutsideTheApp {
                guard let confirm = confirmWorkspaceGrant, await confirm(workspace) else {
                    throw SheetError.pathOutsideWorkspace(path: url.path(percentEncoded: false))
                }
            }
            try store.grantWorkspace(UserGrantAuthorization(userSelectedDirectory: workspace))
            reloadGrants()
            grantedNow = workspace
        }
        try store.grants.check(url)

        // Always, unless a test says otherwise. There is no user-facing switch and no flag: a
        // document that does not watch its file is a document this app has no reason to be showing.
        let autoRefresh = autoRefreshForNewDocuments ?? true
        let workbook = try await DocumentWorkbookReader.read(url)
        reader.prime(workbook, for: url)

        let io = WorkbookIO(
            reader: reader,
            writer: workbook.meta.readOnlyReason == nil ? writer : nil
        )
        let session = DocumentSession(
            url: url,
            workbook: workbook,
            io: io,
            suppressor: store.suppressor,
            snapshots: store.snapshots,
            options: DocumentSession.Options(
                autoRefresh: autoRefresh,
                snapshotsEnabled: Flags.snapshotsEnabled
            )
        )
        try await session.start()
        try? store.database.noteOpened(path: url.path(percentEncoded: false), bookmark: nil, cursor: nil)

        // PLAN.md §1.3. The store is handed over only when tracking is on, so the flag being
        // off leaves the document with nothing to persist a checkpoint *to* — the cost is
        // removed rather than the button hidden.
        let changeTracking = changeTrackingForNewDocuments ?? Flags.changeTrackingEnabled
        let model = DocumentModel(
            url: url,
            workspaceURL: workspace,
            workbook: workbook,
            session: session,
            reader: reader,
            writer: workbook.meta.readOnlyReason == nil ? writer : nil,
            autoRefresh: autoRefresh,
            changeTracking: ChangeTracking(
                isEnabled: changeTracking,
                checkpoints: changeTracking
                    ? CheckpointStore(database: store.database, snapshots: store.snapshots)
                    : nil
            )
        )
        open[key] = WeakDocument(model: model)
        reloadRecents()
        // Said in the window that caused it, not in a dialog nobody reads: the Claude panel in
        // this document's sidebar is where the workspace path already lives, so the sentence that
        // explains why it is reachable belongs next to it.
        if let grantedNow { model.noteWorkspaceGranted(grantedNow) }
        return model
    }

    /// Forgets a closed document. Called from the window's teardown.
    public func closeDocument(_ model: DocumentModel) {
        model.close()
        open.removeValue(forKey: Self.documentKey(for: model.url))
    }

    /// Live documents. Used by the "save everything before quitting" prompt.
    public var openDocuments: [DocumentModel] {
        open.values.compactMap(\.model)
    }

    // MARK: - Recents and grants

    public func reloadRecents() {
        let files = (try? store.database.recentFiles(limit: 20)) ?? []
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        recents = files.map { file in
            let url = URL(fileURLWithPath: file.path)
            return RecentItem(
                id: file.path,
                name: url.lastPathComponent,
                folder: url.deletingLastPathComponent().path(percentEncoded: false),
                lastOpened: formatter.localizedString(for: file.lastOpened, relativeTo: Date()),
                sheetCount: 0,
                exists: FileManager.default.fileExists(atPath: file.path),
                isGranted: store.grants.isAllowed(url)
            )
        }
    }

    public func reloadGrants() {
        grants = store.grants.activeGrants()
        store.grants.invalidateCache()
        // Rootless is the tree's zero-cost state: no roots, no rows, and nothing that could
        // begin a listing. Read fresh rather than cached at init, like every other flag here.
        guard Flags.explorerEnabled else { return }
        explorer.setRoots(grants.map(\.path))
    }

    /// The grant a root row in the explorer stands for, or `nil` when none does.
    ///
    /// **Not `grants.first { $0.path == id }`.** A grant is stored the way the open panel spelled
    /// it; a node id is canonical, and `resolvingSymlinksInPath` rewrites `/private/tmp/x` as
    /// `/tmp/x`. Two of the seven grants on the machine this was written on differ exactly that
    /// way, so the equality match found nothing and Remove from List did nothing — silently, on a
    /// control whose entire purpose is to undo a grant. That is the failure this feature exists to
    /// delete, so it does not get to survive inside it.
    public func grant(forRootID id: String) -> WorkspaceGrant? {
        grants.first { WorkspaceTree.canonicalPath($0.path) == id }
    }

    @discardableResult
    public func grantWorkspace(_ url: URL) -> Bool {
        do {
            try store.grantWorkspace(UserGrantAuthorization(userSelectedDirectory: url))
            reloadGrants()
            reloadRecents()
            return true
        } catch {
            lastError = error
            return false
        }
    }

    /// Whether `url` is inside a live grant — read through ``grants`` on purpose.
    ///
    /// ``store`` is `@ObservationIgnored` and ``SheetStore/WorkspaceGrants`` is not
    /// `@Observable`, so a view that calls `store.grants.isAllowed` alone registers no dependency
    /// and never re-renders when a grant is added. Touching ``grants`` first is what makes the
    /// answer live; the check is what makes it correct.
    public func isGranted(_ url: URL) -> Bool {
        _ = grants.count
        return store.grants.isAllowed(url)
    }

    /// Clears the last error once a view has shown it. Without this the launcher's rejection line
    /// would be permanent.
    public func clearLastError() { lastError = nil }

    public func revokeGrant(_ grant: WorkspaceGrant) {
        guard let id = grant.id else { return }
        try? store.grants.revoke(id: id)
        reloadGrants()
        reloadRecents()
    }

    // MARK: - MCP

    /// Whether `opensheets-mcp` is registered with Claude Code.
    ///
    /// Read from `~/.claude.json` rather than by launching anything: the server is spawned *by*
    /// Claude Code, so the only honest question we can answer is "is it registered", and probing
    /// it ourselves would start a second copy for no reason. The file is read here for status;
    /// it is *written* only by ``ClaudeConnector/connect(_:)`` and
    /// ``ClaudeConnector/disconnect(_:)``, which run solely from the user's explicit click in
    /// Settings ▸ Claude — the "user action, not agent action" the docs demanded. The agent-side
    /// deny list is unchanged: the server still cannot touch this file (PLAN.md §7.2); a human
    /// pressing a labelled button in our own Settings is not the agent.
    public func refreshMCPStatus() {
        guard Flags.mcpEnabled else {
            mcpStatus = .notConfigured
            return
        }
        claude.refresh()
        mcpStatus = Self.mcpStatus(for: claude.connections[.claudeCode] ?? .notInstalled)
    }

    /// The sidebar readout for one observed ``ClaudeConnection`` (the plan's D8).
    ///
    /// `.connected(command:)` maps to `.idle`, not `MCPStatus.connected`: a config entry proves
    /// the server is *registered*, and "Registered. Nothing has called it yet." is the honest
    /// claim. Truthfully claiming a live session needs the server to have talked to us, which is
    /// the handshake's job — that enum case stays unused here. Static and pure so a test can
    /// assert the whole table without a home directory.
    static func mcpStatus(for connection: ClaudeConnection) -> MCPStatus {
        switch connection {
        case .connected:
            .idle
        case .stale:
            .failing("the registered server binary is missing — reconnect in Settings")
        case let .unreadable(reason):
            .failing(reason)
        case .notConnected, .notInstalled:
            .notConfigured
        }
    }

    /// The command the sidebar offers to copy when the server is not set up.
    public static let mcpSetupCommand = "claude mcp add opensheets -- opensheets-mcp"

    /// The same command with the server binary's resolved absolute path, for the terminal
    /// fallback to offer once the Settings pane adopts it. The static above survives verbatim —
    /// its consumer compiles against it today — but it silently assumes `opensheets-mcp` is on
    /// `$PATH`, which stops being true the day the binary ships inside the app bundle instead.
    public var setupCommand: String {
        guard let binary = claude.serverBinary else { return Self.mcpSetupCommand }
        return "claude mcp add opensheets -- \(binary.path(percentEncoded: false))"
    }

    /// The identity a file is known by.
    ///
    /// Public because the tab layer asks the same question — see ``TabsModel/open(_:consent:)``,
    /// which keys a tab on exactly this. Two spellings of one path are one document, and a tab
    /// strip that disagreed would open a tab this table then refuses to fill.
    /// (It used to point at `DocumentWindows.identity(for:)`, which one-window-per-file took with
    /// it; a symbol link only resolves when documentation is built, so a stale one is invisible
    /// to every build that matters.)
    ///
    /// `nonisolated` because it is a pure function of its argument, and the things that key
    /// storage on it — a checkpoint preference, a snapshot directory — are reached from
    /// background tasks that have no business hopping to the main actor to spell a path.
    public nonisolated static func documentKey(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }
}

/// The app's feature flags, mirrored into the package so `DocumentCore` can gate behaviour
/// without the Xcode target having to pass every switch down.
///
/// Read fresh each time, like `App/Flags.swift`: `defaults write` should take effect at the next
/// check rather than at the next launch, which is what makes a flag useful while developing.
public enum Flags {
    public static var editingEnabled: Bool { bool("OSFlagEditing", default: true) }
    public static var mcpEnabled: Bool { bool("OSFlagMCP", default: true) }
    public static var formulaEngineEnabled: Bool { bool("OSFlagFormulaEngine", default: true) }
    public static var snapshotsEnabled: Bool { bool("OSFlagSnapshots", default: true) }

    /// PLAN.md §1.3's green/amber/red tracking against a baseline: the chip, the panel, the grid
    /// tints and the checkpoint command. **On**, and switching it off has to remove the cost as
    /// well as the controls — no diffing, no snapshots, no background passes.
    public static var changeTrackingEnabled: Bool { bool("OSFlagChangeTracking", default: true) }

    /// The workspace file explorer. **On.**
    ///
    /// Off costs nothing, and that is enforced rather than asserted: ``AppModel`` withholds both
    /// the tree's storage and its roots, so it holds no nodes and can start no listing. The object
    /// itself still exists — both hosts take a non-optional reference and an empty `@Observable`
    /// costs a pointer — but it does no work, which is the part that would have been a lie.
    public static var explorerEnabled: Bool { bool("OSFlagExplorer", default: true) }

    /// Sheet add, remove and reorder. **Off**, and it must stay off in v0.1: A2's writer throws
    /// `SheetError.notImplemented` for all three rather than producing a package whose
    /// `[Content_Types].xml`, relationships and `workbook.xml` disagree (addendum §4). The tab
    /// bar's `+` and its Delete item are hidden behind this rather than failing at save time.
    public static var sheetStructureEditing: Bool { bool("OSFlagSheetStructure") }

    private static func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}
