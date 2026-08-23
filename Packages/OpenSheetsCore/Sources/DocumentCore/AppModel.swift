#if canImport(AppKit)
import AppKit
#endif
import Foundation
import GlassUI
import Observation
import SheetModel
import SheetStore

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

    private struct WeakDocument {
        weak var model: DocumentModel?
    }

    public init(store: SheetStore) {
        self.store = store
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
    /// The order is load-bearing and is A6's, not ours: the **grant is checked before the file is
    /// stat-ed**, because a denial that happens after a read has already told the caller whether
    /// the file exists.
    public func openDocument(at url: URL) async throws(SheetError) -> DocumentModel {
        let key = Self.key(for: url)
        if let existing = open[key]?.model { return existing }

        let workspace = url.deletingLastPathComponent()
        // PLAN.md §1.1: opening a file grants its parent folder, one click, explained inline.
        // Doing it here rather than at the picker means drag-and-drop and `Open Recent` get the
        // same treatment as `Open…`, which is the only way the rule stays true.
        if !store.grants.isAllowed(url) {
            try store.grantWorkspace(UserGrantAuthorization(userSelectedDirectory: workspace))
            reloadGrants()
        }
        try store.grants.check(url)

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
                autoRefresh: Flags.autoRefreshEnabled,
                snapshotsEnabled: Flags.snapshotsEnabled
            )
        )
        try await session.start()
        try? store.database.noteOpened(path: url.path(percentEncoded: false), bookmark: nil, cursor: nil)

        let model = DocumentModel(
            url: url,
            workspaceURL: workspace,
            workbook: workbook,
            session: session,
            reader: reader,
            writer: workbook.meta.readOnlyReason == nil ? writer : nil,
            autoRefresh: Flags.autoRefreshEnabled
        )
        open[key] = WeakDocument(model: model)
        reloadRecents()
        return model
    }

    /// Forgets a closed document. Called from the window's teardown.
    public func closeDocument(_ model: DocumentModel) {
        model.close()
        open.removeValue(forKey: Self.key(for: model.url))
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
    /// it ourselves would start a second copy for no reason. The file is read, never written —
    /// it is on the deny list precisely because it is not ours (PLAN.md §7.2).
    public func refreshMCPStatus() {
        guard Flags.mcpEnabled else {
            mcpStatus = .notConfigured
            return
        }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            mcpStatus = .notConfigured
            return
        }
        mcpStatus = Self.mentionsOpenSheets(root) ? .idle : .notConfigured
    }

    /// The command the sidebar offers to copy when the server is not set up.
    public static let mcpSetupCommand = "claude mcp add opensheets -- opensheets-mcp"

    private static func mentionsOpenSheets(_ root: [String: Any]) -> Bool {
        func search(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                if dictionary.keys.contains(where: { $0.localizedCaseInsensitiveContains("opensheets") }) {
                    return true
                }
                return dictionary.values.contains(where: search)
            }
            if let array = value as? [Any] { return array.contains(where: search) }
            if let text = value as? String { return text.localizedCaseInsensitiveContains("opensheets") }
            return false
        }
        return search(root)
    }

    private static func key(for url: URL) -> String {
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
    public static var autoRefreshEnabled: Bool { bool("OSFlagAutoRefresh", default: true) }

    /// Sheet add, remove and reorder. **Off**, and it must stay off in v0.1: A2's writer throws
    /// `SheetError.notImplemented` for all three rather than producing a package whose
    /// `[Content_Types].xml`, relationships and `workbook.xml` disagree (addendum §4). The tab
    /// bar's `+` and its Delete item are hidden behind this rather than failing at save time.
    public static var sheetStructureEditing: Bool { bool("OSFlagSheetStructure") }

    private static func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }
}
