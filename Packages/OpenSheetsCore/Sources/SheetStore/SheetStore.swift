import Foundation
import SheetModel

/// The entry point A8 (the app) and A9 (the MCP server) both hold.
///
/// One object owning the database, the snapshot store, the grant boundary and the self-write
/// suppressor, and handing out ``DocumentSession``s. The suppressor in particular has to be
/// shared: a save made through the MCP server must suppress the watcher the *app* is running,
/// and two suppressors would leave that refresh loop in place for exactly the workflow this
/// product is for.
///
/// The MCP server builds one with ``Mode/mcpServer``, which makes ``grants`` refuse to create
/// anything — see ``WorkspaceGrants/Mode``.
public final class SheetStore: Sendable {
    /// Which process this is.
    public enum Mode: Sendable, Hashable {
        /// The app. May create grants, from a folder picker.
        case app
        /// `opensheets-mcp`. May check grants and nothing else.
        case mcpServer
    }

    /// Where everything lives.
    public struct Configuration: Sendable {
        /// `~/Library/Application Support/OpenSheets`.
        public var applicationSupport: URL
        /// See ``DenyList``.
        public var denyList: DenyList

        public init(applicationSupport: URL, denyList: DenyList = .standard) {
            self.applicationSupport = applicationSupport
            self.denyList = denyList
        }

        /// The real location.
        public static func standard() -> Configuration {
            let base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("OpenSheets")
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpenSheets")
            return Configuration(applicationSupport: base)
        }
    }

    /// See ``Mode``.
    public let mode: Mode
    /// The five tables. See ``Database``.
    public let database: Database
    /// The safety net. See ``SnapshotStore``.
    public let snapshots: SnapshotStore
    /// The security boundary. See ``WorkspaceGrants``.
    public let grants: WorkspaceGrants
    /// Reads folders from inside that boundary. See ``DirectoryLister``.
    ///
    /// Handed the same ``grants`` object rather than building its own, for the reason the
    /// suppressor is shared: two boundaries can disagree about what is granted, and the looser
    /// one would be the one that answered.
    public let directories: DirectoryLister
    /// Shared across every document and both processes' writes. See ``SelfWriteSuppressor``.
    public let suppressor: SelfWriteSuppressor

    public init(mode: Mode, configuration: Configuration = .standard()) throws(SheetError) {
        self.mode = mode
        let database = try Database(url: Database.standardURL(applicationSupport: configuration.applicationSupport))
        self.database = database
        snapshots = SnapshotStore(
            configuration: .standard(applicationSupport: configuration.applicationSupport),
            index: database
        )
        grants = WorkspaceGrants(
            mode: mode == .app ? .app : .enforcementOnly,
            storage: database,
            denyList: configuration.denyList
        )
        directories = DirectoryLister(grants: grants)
        suppressor = SelfWriteSuppressor()
    }

    /// Opens a document: checks the grant, reads the file, and returns a session that is
    /// already watching it.
    ///
    /// The grant check comes **first**, before the file is even stat-ed. A denial that happens
    /// after a read has already told the caller whether the file exists, and that is an
    /// information leak an agent can enumerate a home directory with.
    public func openDocument(
        at url: URL,
        io: WorkbookIO,
        options: DocumentSession.Options = .default
    ) async throws(SheetError) -> DocumentSession {
        try grants.check(url)
        let workbook: Workbook
        do {
            workbook = try io.reader.readWorkbook(at: url)
        } catch let error as SheetError {
            throw error
        } catch {
            throw SheetError.fileNotReadable(path: url.path(percentEncoded: false), underlying: "\(error)")
        }
        let session = DocumentSession(
            url: url,
            workbook: workbook,
            io: io,
            suppressor: suppressor,
            snapshots: snapshots,
            options: options
        )
        try await session.start()
        try? database.noteOpened(path: url.path(percentEncoded: false), bookmark: nil, cursor: nil)
        return session
    }

    /// Records a folder the user picked. Throws in ``Mode/mcpServer``.
    @discardableResult
    public func grantWorkspace(_ authorization: UserGrantAuthorization) throws(SheetError) -> WorkspaceGrant {
        try grants.grant(authorization)
    }
}
