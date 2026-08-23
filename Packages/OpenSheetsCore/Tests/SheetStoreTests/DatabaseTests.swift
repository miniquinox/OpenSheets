import Foundation
import GRDB
import SheetModel
@testable import SheetStore
import Testing

/// PLAN.md §5.5. The app and `opensheets-mcp` are **two processes** on one database, so the
/// concurrency test uses a real second process. Two threads share a connection pool and a page
/// cache and would prove nothing about SQLite's file locking, which is the thing that can
/// actually fail here.
@Suite struct DatabaseTests {
    /// The five tables, and WAL actually on.
    @Test func migratesToTheFiveTables() throws {
        let scratch = TemporaryDirectory("migrate")
        let database = try Database(url: scratch.url.appendingPathComponent("OpenSheets.sqlite"))

        let tables = try database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        for expected in ["workspace_grant", "recent_file", "doc_view_state", "snapshot", "preference"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }

        let mode = try database.pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(mode?.lowercased() == "wal")

        let timeout = try database.pool.read { db in try Int.fetchOne(db, sql: "PRAGMA busy_timeout") }
        #expect(timeout == Int(Database.busyTimeout * 1000))
    }

    /// Migrations are idempotent — reopening an existing database must not try to recreate it.
    @Test func reopeningAnExistingDatabaseIsSafe() throws {
        let scratch = TemporaryDirectory("reopen")
        let url = scratch.url.appendingPathComponent("OpenSheets.sqlite")

        let first = try Database(url: url)
        try first.setPreference("theme", to: "quiet-glass")

        let second = try Database(url: url)
        #expect(try second.preference("theme") == "quiet-glass")
    }

    /// **Two real processes writing concurrently: no `SQLITE_BUSY`, no corruption.**
    ///
    /// The second process is `/usr/bin/sqlite3` — a genuinely separate process taking genuine
    /// file locks against the same WAL. It hammers the database while this one does, and
    /// afterwards every row from both is present and the integrity check is clean.
    ///
    /// The duration is short by default so the suite stays fast; `OPENSHEETS_SOAK_SECONDS=30`
    /// runs it for the full thirty the brief asks for.
    @Test func twoProcessesWriteConcurrentlyWithoutBusyErrors() throws {
        let scratch = TemporaryDirectory("two-processes")
        let url = scratch.url.appendingPathComponent("OpenSheets.sqlite")
        let path = url.path(percentEncoded: false)
        let database = try Database(url: url)

        let seconds = Double(ProcessInfo.processInfo.environment["OPENSHEETS_SOAK_SECONDS"] ?? "") ?? 6
        let deadline = Date().addingTimeInterval(seconds)

        // The other process: its own connection, its own busy_timeout, its own transactions.
        let script = scratch.url.appendingPathComponent("hammer.sh")
        try """
        #!/bin/sh
        i=0
        end=$(( $(date +%s) + \(Int(seconds.rounded(.up))) ))
        while [ "$(date +%s)" -lt "$end" ]; do
          i=$((i+1))
          /usr/bin/sqlite3 '\(path)' \\
            "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; \\
             INSERT OR REPLACE INTO preference (key, value) VALUES ('other-$i', '$i'); COMMIT;" \\
            || echo "BUSY at $i" >> '\(scratch.url.path(percentEncoded: false))/errors.log'
        done
        echo "$i" > '\(scratch.url.path(percentEncoded: false))/other-count.txt'
        """.write(to: script, atomically: true, encoding: .utf8)

        let other = try #require(Shell.spawn("/bin/sh '\(script.path(percentEncoded: false))'"))

        var ours = 0
        var failures: [String] = []
        while Date() < deadline {
            ours += 1
            do {
                try database.setPreference("ours-\(ours)", to: "\(ours)")
            } catch {
                failures.append("\(error)")
            }
        }
        other.waitUntilExit()

        #expect(failures.isEmpty, "our writes failed: \(failures.prefix(3))")
        let errorLog = scratch.url.appendingPathComponent("errors.log")
        let reportedBusy = FileManager.default.fileExists(atPath: errorLog.path(percentEncoded: false))
        let busyDetail = (try? String(contentsOf: errorLog, encoding: .utf8))?.prefix(200) ?? ""
        #expect(!reportedBusy, "the other process reported SQLITE_BUSY: \(busyDetail)")

        // Everything both processes wrote is there, and the file is intact.
        let oursStored = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM preference WHERE key LIKE 'ours-%'") ?? 0
        }
        #expect(oursStored == ours, "wrote \(ours) rows, found \(oursStored)")

        let theirCount = Int((try? String(
            contentsOf: scratch.url.appendingPathComponent("other-count.txt"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        #expect(theirCount > 0, "the other process never completed a write")
        let theirsStored = try database.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM preference WHERE key LIKE 'other-%'") ?? 0
        }
        #expect(theirsStored == theirCount, "the other process wrote \(theirCount) rows, found \(theirsStored)")

        let integrity = try database.pool.read { db in try String.fetchOne(db, sql: "PRAGMA integrity_check") }
        #expect(integrity == "ok")
    }

    /// A grant written by one process is visible to the other after it drops its cache — which
    /// is the real workflow: the user grants a folder in the app while the MCP server is
    /// already running.
    @Test func grantsCrossTheProcessBoundary() throws {
        let scratch = TemporaryDirectory("cross-process-grant")
        let url = scratch.url.appendingPathComponent("OpenSheets.sqlite")
        let workspace = scratch.directory("work")

        let appDatabase = try Database(url: url)
        let serverDatabase = try Database(url: url)
        let server = WorkspaceGrants(mode: .enforcementOnly, storage: serverDatabase, denyList: .empty)
        #expect(!server.isAllowed(workspace.appendingPathComponent("x.xlsx")))

        try WorkspaceGrants(mode: .app, storage: appDatabase, denyList: .empty)
            .grant(UserGrantAuthorization(unchecked: workspace))

        server.invalidateCache()
        #expect(server.isAllowed(workspace.appendingPathComponent("x.xlsx")))
    }

    // MARK: - The tables

    @Test func recentFilesRoundTrip() throws {
        let scratch = TemporaryDirectory("recent")
        let database = try Database(url: scratch.url.appendingPathComponent("db.sqlite"))

        try database.noteOpened(path: "/a/one.xlsx", bookmark: Data([1, 2, 3]), cursor: nil)
        try database.noteOpened(
            path: "/a/two.xlsx",
            bookmark: nil,
            cursor: (sheet: SheetID(3), ref: CellRef(row: 9, column: 4))
        )

        let recents = try database.recentFiles()
        #expect(recents.count == 2)
        #expect(recents.first?.path == "/a/two.xlsx", "most recently opened first")
        #expect(recents.first?.cursor?.sheet == SheetID(3))
        #expect(recents.first?.cursor?.ref == CellRef(row: 9, column: 4))
        #expect(recents.last?.bookmark == Data([1, 2, 3]))

        // Reopening updates rather than duplicating, and keeps a bookmark the new call omitted.
        try database.noteOpened(path: "/a/one.xlsx", bookmark: nil, cursor: nil)
        #expect(try database.recentFiles().count == 2)
        #expect(try database.recentFiles().first?.bookmark == Data([1, 2, 3]))
    }

    @Test func viewStateRoundTrips() throws {
        let scratch = TemporaryDirectory("view-state")
        let database = try Database(url: scratch.url.appendingPathComponent("db.sqlite"))

        #expect(try database.viewState(path: "/a/book.xlsx") == nil)
        try database.setViewState(DocumentViewState(
            path: "/a/book.xlsx",
            zoom: 1.25,
            frozenRows: 1,
            frozenColumns: 2,
            columnWidths: #"{"0":120}"#,
            sidebarState: #"{"open":true}"#
        ))

        let loaded = try #require(try database.viewState(path: "/a/book.xlsx"))
        #expect(loaded.zoom == 1.25)
        #expect(loaded.frozenRows == 1)
        #expect(loaded.frozenColumns == 2)
        #expect(loaded.columnWidths == #"{"0":120}"#)

        try database.setViewState(DocumentViewState(path: "/a/book.xlsx", zoom: 2))
        #expect(try database.viewState(path: "/a/book.xlsx")?.zoom == 2)
    }

    @Test func preferencesRoundTripAndDelete() throws {
        let scratch = TemporaryDirectory("prefs")
        let database = try Database(url: scratch.url.appendingPathComponent("db.sqlite"))

        #expect(try database.preference("missing") == nil)
        try database.setPreference("autoRefresh", to: "true")
        #expect(try database.preference("autoRefresh") == "true")
        try database.setPreference("autoRefresh", to: "false")
        #expect(try database.preference("autoRefresh") == "false")
        try database.setPreference("autoRefresh", to: nil)
        #expect(try database.preference("autoRefresh") == nil)
    }

    @Test func snapshotRowsRoundTrip() throws {
        let scratch = TemporaryDirectory("snapshot-rows")
        let database = try Database(url: scratch.url.appendingPathComponent("db.sqlite"))

        let record = SnapshotRecord(
            id: ULID(),
            filePath: "/a/book.xlsx",
            takenAt: Date(),
            reason: .preRefresh,
            byteCount: 1234,
            compressedByteCount: 321,
            contentHash: String(repeating: "a", count: 64),
            summary: "3 sheets, 412 cells"
        )
        try database.insert(record)

        let loaded = try #require(try database.snapshot(id: record.id))
        #expect(loaded.filePath == record.filePath)
        #expect(loaded.reason == .preRefresh)
        #expect(loaded.byteCount == 1234)
        #expect(loaded.summary == "3 sheets, 412 cells")
        #expect(try database.snapshots(forPath: "/a/book.xlsx").count == 1)

        try database.deleteSnapshot(id: record.id)
        #expect(try database.snapshot(id: record.id) == nil)
    }

    /// A database that cannot be opened is a typed error, never a crash.
    @Test func unopenableDatabaseIsATypedError() throws {
        let scratch = TemporaryDirectory("bad-db")
        let blocked = scratch.directory("blocked")
        let path = blocked.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }

        do {
            _ = try Database(url: blocked.appendingPathComponent("nope.sqlite"))
            Issue.record("opening a database in a read-only directory succeeded")
        } catch {
            #expect(error.code == "db.error")
            #expect(error.category == .persistence)
        }
    }
}
