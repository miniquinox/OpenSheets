import Foundation
import GRDB
import SheetModel

/// The five tables from PLAN.md §5.5, in SQLite via GRDB.
///
/// **Two processes, one file.** The app and `opensheets-mcp` both open this, so:
///
/// - **WAL journalling**, which is what lets a reader and a writer coexist at all. `DatabasePool`
///   sets it, and it is a property of the *file*, so the second process inherits it.
/// - **`busy_timeout`**, without which the loser of a write race gets `SQLITE_BUSY` immediately
///   rather than waiting the 30 ms the winner needs. This is the single setting that decides
///   whether concurrent access works or merely usually works.
/// - **Every write in a transaction**, which GRDB's `write` gives by construction.
///
/// The concurrency claim is tested against a real second process rather than a second thread —
/// two threads share a connection pool and a page cache and prove nothing about file locking.
/// See `DatabaseTests.twoProcesses…`.
public final class Database: Sendable {
    /// The pool. Exposed so `SheetMCP` can run its own queries without this class growing a
    /// method per call site.
    public let pool: DatabasePool
    /// Where the file lives.
    public let url: URL

    /// How long a blocked writer waits before reporting `SQLITE_BUSY`.
    ///
    /// Five seconds is far longer than any write here takes; the number is a bound on
    /// pathological contention, not a normal wait. Anything under a second turns a busy moment
    /// during a save into a visible failure.
    public static let busyTimeout: TimeInterval = 5

    /// Opens or creates the database at `url`, running migrations.
    public init(url: URL) throws(SheetError) {
        self.url = url
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var configuration = GRDB.Configuration()
            configuration.busyMode = .timeout(Database.busyTimeout)
            configuration.prepareDatabase { db in
                // A second process can be mid-write when we connect. WAL is already on from
                // the file header, but the timeout is per-connection and has to be set here.
                try db.execute(sql: "PRAGMA busy_timeout = \(Int(Database.busyTimeout * 1000))")
                try db.execute(sql: "PRAGMA foreign_keys = ON")
                // NORMAL rather than FULL: in WAL mode NORMAL still survives a process crash,
                // and only loses the most recent commits to a power cut. The file we actually
                // care about surviving a power cut is the user's workbook, and that one is
                // `F_FULLFSYNC`-ed by `AtomicWriter`.
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
            }
            pool = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
            try Database.migrator.migrate(pool)
        } catch let error as SheetError {
            throw error
        } catch {
            throw SheetError.databaseError(operation: "open \(url.lastPathComponent)", underlying: "\(error)")
        }
    }

    /// The default location: `~/Library/Application Support/OpenSheets/OpenSheets.sqlite`.
    public static func standardURL(applicationSupport: URL? = nil) -> URL {
        let base = applicationSupport ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("OpenSheets")
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpenSheets")
        return base.appendingPathComponent("OpenSheets.sqlite")
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-tables") { db in
            try db.create(table: "workspace_grant") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("path", .text).notNull().indexed()
                table.column("bookmark", .blob)
                table.column("granted_at", .datetime).notNull()
                table.column("revoked_at", .datetime)
            }
            try db.create(table: "recent_file") { table in
                table.column("path", .text).primaryKey()
                table.column("bookmark", .blob)
                table.column("last_opened", .datetime).notNull().indexed()
                table.column("cursor_sheet_id", .integer)
                table.column("cursor_row", .integer)
                table.column("cursor_column", .integer)
            }
            try db.create(table: "doc_view_state") { table in
                table.column("path", .text).primaryKey()
                table.column("zoom", .double).notNull().defaults(to: 1)
                table.column("frozen_rows", .integer).notNull().defaults(to: 0)
                table.column("frozen_columns", .integer).notNull().defaults(to: 0)
                table.column("column_widths", .text)
                table.column("sidebar_state", .text)
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(table: "snapshot") { table in
                table.column("id", .text).primaryKey()
                table.column("file_path", .text).notNull().indexed()
                table.column("taken_at", .datetime).notNull()
                table.column("reason", .text).notNull()
                table.column("byte_count", .integer).notNull()
                table.column("compressed_byte_count", .integer).notNull()
                table.column("content_hash", .text).notNull()
                table.column("summary", .text)
            }
            try db.create(table: "preference") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v2-recent-file-sequence") { db in
            // `last_opened` is a wall-clock timestamp and GRDB stores it to the millisecond, so
            // two files opened in the same millisecond — a session restore, or a folder full of
            // sheets — tie, and `ORDER BY last_opened DESC` then returns them in whatever order
            // SQLite feels like. Recents order is a *sequence*, not a time; the timestamp is only
            // ever displayed. So order by an integer that always increases.
            try db.alter(table: "recent_file") { table in
                table.add(column: "open_sequence", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: """
                UPDATE recent_file
                SET open_sequence = (
                    SELECT COUNT(*) FROM recent_file AS earlier
                    WHERE earlier.last_opened <= recent_file.last_opened
                )
                """)
            try db.create(index: "recent_file_open_sequence", on: "recent_file", columns: ["open_sequence"])
        }
        return migrator
    }

    // MARK: - Preferences

    /// Reads a preference.
    public func preference(_ key: String) throws(SheetError) -> String? {
        try run("read preference") { db in
            try String.fetchOne(db, sql: "SELECT value FROM preference WHERE key = ?", arguments: [key])
        }
    }

    /// Writes a preference. `nil` deletes it.
    public func setPreference(_ key: String, to value: String?) throws(SheetError) {
        try write("write preference") { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO preference (key, value) VALUES (?, ?) " +
                        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM preference WHERE key = ?", arguments: [key])
            }
        }
    }

    // MARK: - Recent files

    /// Records that a file was opened, and where the cursor was.
    public func noteOpened(path: String, bookmark: Data?, cursor: (sheet: SheetID, ref: CellRef)?) throws(SheetError) {
        try write("write recent_file") { db in
            try db.execute(
                sql: """
                INSERT INTO recent_file (
                    path, bookmark, last_opened, cursor_sheet_id, cursor_row, cursor_column, open_sequence
                )
                VALUES (?, ?, ?, ?, ?, ?, (SELECT COALESCE(MAX(open_sequence), 0) + 1 FROM recent_file))
                ON CONFLICT(path) DO UPDATE SET
                    bookmark = COALESCE(excluded.bookmark, recent_file.bookmark),
                    last_opened = excluded.last_opened,
                    open_sequence = excluded.open_sequence,
                    cursor_sheet_id = excluded.cursor_sheet_id,
                    cursor_row = excluded.cursor_row,
                    cursor_column = excluded.cursor_column
                """,
                arguments: [
                    path, bookmark, Date(),
                    cursor.map { Int($0.sheet.rawValue) }, cursor?.ref.row, cursor?.ref.column,
                ]
            )
        }
    }

    /// The most recently opened files, newest first.
    public func recentFiles(limit: Int = 20) throws(SheetError) -> [RecentFile] {
        try run("read recent_file") { db in
            try RecentFile.fetchAll(
                db,
                sql: "SELECT * FROM recent_file ORDER BY open_sequence DESC, last_opened DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    // MARK: - View state

    /// Per-document UI state that does not belong in the file.
    public func viewState(path: String) throws(SheetError) -> DocumentViewState? {
        try run("read doc_view_state") { db in
            try DocumentViewState.fetchOne(db, sql: "SELECT * FROM doc_view_state WHERE path = ?", arguments: [path])
        }
    }

    /// Writes ``viewState(path:)``.
    public func setViewState(_ state: DocumentViewState) throws(SheetError) {
        try write("write doc_view_state") { db in
            try db.execute(
                sql: """
                INSERT INTO doc_view_state
                    (path, zoom, frozen_rows, frozen_columns, column_widths, sidebar_state, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    zoom = excluded.zoom, frozen_rows = excluded.frozen_rows,
                    frozen_columns = excluded.frozen_columns, column_widths = excluded.column_widths,
                    sidebar_state = excluded.sidebar_state, updated_at = excluded.updated_at
                """,
                arguments: [
                    state.path, state.zoom, state.frozenRows, state.frozenColumns,
                    state.columnWidths, state.sidebarState, Date(),
                ]
            )
        }
    }

    // MARK: - Plumbing

    /// Every read, with the error translation in one place.
    private func run<T>(_ operation: String, _ body: @Sendable (GRDB.Database) throws -> T) throws(SheetError) -> T {
        do {
            return try pool.read(body)
        } catch {
            throw SheetError.databaseError(operation: operation, underlying: "\(error)")
        }
    }

    /// Every write, in a transaction, with the same translation. `pool.write` *is* the
    /// transaction — PLAN.md §5.5's "every write in a transaction" is structural here rather
    /// than a rule somebody has to remember.
    func write<T>(_ operation: String, _ body: @Sendable (GRDB.Database) throws -> T) throws(SheetError) -> T {
        do {
            return try pool.write(body)
        } catch {
            throw SheetError.databaseError(operation: operation, underlying: "\(error)")
        }
    }
}

// MARK: - Rows

/// A row of `recent_file`.
public struct RecentFile: Sendable, Hashable, Codable, FetchableRecord {
    public var path: String
    public var bookmark: Data?
    public var lastOpened: Date
    public var cursorSheetID: Int32?
    public var cursorRow: Int?
    public var cursorColumn: Int?

    enum CodingKeys: String, CodingKey {
        case path
        case bookmark
        case lastOpened = "last_opened"
        case cursorSheetID = "cursor_sheet_id"
        case cursorRow = "cursor_row"
        case cursorColumn = "cursor_column"
    }

    /// Where the cursor was when the file was last closed, when that was recorded.
    public var cursor: (sheet: SheetID, ref: CellRef)? {
        guard let cursorSheetID, let cursorRow, let cursorColumn else { return nil }
        return (SheetID(cursorSheetID), CellRef(row: cursorRow, column: cursorColumn))
    }
}

/// A row of `doc_view_state`.
public struct DocumentViewState: Sendable, Hashable, Codable, FetchableRecord {
    public var path: String
    public var zoom: Double
    public var frozenRows: Int
    public var frozenColumns: Int
    /// JSON, because column widths are a sparse map the UI owns the shape of and the store has
    /// no reason to model.
    public var columnWidths: String?
    /// JSON, same reasoning.
    public var sidebarState: String?

    enum CodingKeys: String, CodingKey {
        case path
        case zoom
        case frozenRows = "frozen_rows"
        case frozenColumns = "frozen_columns"
        case columnWidths = "column_widths"
        case sidebarState = "sidebar_state"
    }

    public init(
        path: String,
        zoom: Double = 1,
        frozenRows: Int = 0,
        frozenColumns: Int = 0,
        columnWidths: String? = nil,
        sidebarState: String? = nil
    ) {
        self.path = path
        self.zoom = zoom
        self.frozenRows = frozenRows
        self.frozenColumns = frozenColumns
        self.columnWidths = columnWidths
        self.sidebarState = sidebarState
    }
}

// MARK: - Storage conformances

extension Database: WorkspaceGrantStoring {
    public func insert(_ grant: WorkspaceGrant) throws -> WorkspaceGrant {
        try write("insert workspace_grant") { db in
            try db.execute(
                sql: "INSERT INTO workspace_grant (path, bookmark, granted_at, revoked_at) VALUES (?, ?, ?, ?)",
                arguments: [grant.path, grant.bookmark, grant.grantedAt, grant.revokedAt]
            )
            var stored = grant
            stored.id = db.lastInsertedRowID
            return stored
        }
    }

    public func revoke(id: Int64, at date: Date) throws {
        try write("revoke workspace_grant") { db in
            try db.execute(
                sql: "UPDATE workspace_grant SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
                arguments: [date, id]
            )
        }
    }

    public func allGrants() throws -> [WorkspaceGrant] {
        try run("read workspace_grant") { db in
            try Row
                .fetchAll(db, sql: "SELECT id, path, bookmark, granted_at, revoked_at FROM workspace_grant")
                .map { row in
                    WorkspaceGrant(
                        id: row["id"],
                        path: row["path"],
                        bookmark: row["bookmark"],
                        grantedAt: row["granted_at"],
                        revokedAt: row["revoked_at"]
                    )
                }
        }
    }
}

extension Database: SnapshotIndexing {
    public func insert(_ record: SnapshotRecord) throws {
        try write("insert snapshot") { db in
            try db.execute(
                sql: """
                INSERT INTO snapshot
                    (id, file_path, taken_at, reason, byte_count, compressed_byte_count, content_hash, summary)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.id.rawValue, record.filePath, record.takenAt, record.reason.rawValue,
                    record.byteCount, record.compressedByteCount, record.contentHash, record.summary,
                ]
            )
        }
    }

    public func snapshot(id: ULID) throws -> SnapshotRecord? {
        try run("read snapshot") { db in
            try Row.fetchOne(db, sql: "SELECT * FROM snapshot WHERE id = ?", arguments: [id.rawValue])
                .flatMap(Database.snapshot(from:))
        }
    }

    public func snapshots(forPath path: String) throws -> [SnapshotRecord] {
        try run("read snapshots") { db in
            try Row
                .fetchAll(db, sql: "SELECT * FROM snapshot WHERE file_path = ? ORDER BY id DESC", arguments: [path])
                .compactMap(Database.snapshot(from:))
        }
    }

    public func deleteSnapshot(id: ULID) throws {
        try write("delete snapshot") { db in
            try db.execute(sql: "DELETE FROM snapshot WHERE id = ?", arguments: [id.rawValue])
        }
    }

    public func deleteSnapshots(forPath path: String) throws {
        try write("delete snapshots") { db in
            try db.execute(sql: "DELETE FROM snapshot WHERE file_path = ?", arguments: [path])
        }
    }

    private static func snapshot(from row: Row) -> SnapshotRecord? {
        guard let raw: String = row["id"], let id = ULID(rawValue: raw) else { return nil }
        return SnapshotRecord(
            id: id,
            filePath: row["file_path"],
            takenAt: row["taken_at"],
            reason: SnapshotReason(rawValue: row["reason"] ?? "") ?? .manual,
            byteCount: row["byte_count"],
            compressedByteCount: row["compressed_byte_count"],
            contentHash: row["content_hash"],
            summary: row["summary"]
        )
    }
}
