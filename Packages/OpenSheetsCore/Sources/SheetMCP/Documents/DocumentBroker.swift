import Foundation
import SheetFormat
import SheetModel
import SheetStore

/// What a tool learned by making an edit.
public struct EditOutcome<Value: Sendable>: Sendable {
    /// Whatever the edit body computed — a changed-cell count, a list of refs.
    public var value: Value
    /// What actually changed, computed by A6's differ over before and after.
    public var diff: WorkbookDiff
    /// `false` for a `preview: true` call.
    public var wrote: Bool
    /// The snapshot taken immediately before the write, if one was.
    public var snapshotID: ULID?
    /// The sheet the edit was aimed at, for the result header.
    public var sheetName: String?
}

/// An open document, and the facts a tool needs about it.
public struct LoadedDocument: Sendable {
    public var url: URL
    /// What to read. Values a producer left uncomputed have been put right *in memory* — see
    /// ``recalculationNotice`` and ``SheetMCP/OpenRecalculation``.
    public var workbook: Workbook
    /// Where the file stands relative to disk. `stale` means somebody else wrote it since we
    /// read it, and a tool result says so rather than pretending.
    public var state: DocumentSyncState
    /// Set when ``workbook`` is not literally what the file says, or when it is and should not
    /// have been. Read tools print it; nothing branches on it.
    public var recalculationNotice: String?

    public init(url: URL, workbook: Workbook, state: DocumentSyncState, recalculationNotice: String? = nil) {
        self.url = url
        self.workbook = workbook
        self.state = state
        self.recalculationNotice = recalculationNotice
    }
}

/// Everything the tools do to a file, in one place.
///
/// # What this type is for
///
/// Three guarantees have to hold on *every* path through the server, and each of them is one
/// forgotten line away from not holding:
///
/// 1. **The grant is checked before any I/O.** ``resolve(_:)`` is the only way a tool obtains a
///    `URL`, and it calls A6's ``SheetStore/WorkspaceGrants/check(_:)-2c4rm`` first — before the
///    file is stat-ed, so a denial cannot tell an agent whether a path exists.
/// 2. **A snapshot precedes every write.** Not by convention: writes go through
///    ``SheetStore/DocumentSession``, whose state machine *emits* `captureSnapshot(.preSave)`
///    as an effect of `saveRequested`. There is no code path here that writes bytes without
///    going through it.
/// 3. **Writes are rate-limited.** An agent in a loop calling `write_range` 200 times a second
///    would otherwise produce 200 atomic replaces a second, each one a snapshot and a full
///    re-serialisation. ``Configuration/minimumWriteInterval`` makes the *call* wait rather
///    than deferring the write, so a tool that returned still means the file is saved.
///
/// An actor because the MCP server may have several calls in flight and they can name the same
/// file.
public actor DocumentBroker {
    /// Knobs, all with defensible defaults.
    public struct Configuration: Sendable {
        /// The floor between two writes to the same file. 250 ms caps a runaway agent at four
        /// saves a second without ever making a save invisible.
        public var minimumWriteInterval: Duration
        /// How many documents stay open. Each holds a parsed workbook and an FSEvents stream.
        public var maximumOpenDocuments: Int
        /// Ceiling on cells one `read_range` may return, before paging.
        public var maximumCellsPerRead: Int
        /// Ceiling on the characters a single tool result may carry. A result that would
        /// exceed it is truncated with a note rather than silently cut.
        public var maximumResultCharacters: Int

        public init(
            minimumWriteInterval: Duration = .milliseconds(250),
            maximumOpenDocuments: Int = 4,
            maximumCellsPerRead: Int = 20000,
            maximumResultCharacters: Int = 120_000
        ) {
            self.minimumWriteInterval = minimumWriteInterval
            self.maximumOpenDocuments = maximumOpenDocuments
            self.maximumCellsPerRead = maximumCellsPerRead
            self.maximumResultCharacters = maximumResultCharacters
        }

        public static let `default` = Configuration()
    }

    private struct OpenDocument {
        var session: DocumentSession
        var drain: Task<Void, Never>
        var lastUsed: ContinuousClock.Instant
        var lastWrite: ContinuousClock.Instant?
    }

    /// The store both processes share. See ``SheetStore/SheetStore``.
    public let store: SheetStore
    public let configuration: Configuration
    /// Exposed so a tool can prime it before asking `SheetStore` to reload.
    public let reader: CachingWorkbookReader
    /// Exposed so a tool can declare what it changed. See ``TrackedWorkbookWriter``.
    public let writer: TrackedWorkbookWriter

    private let differ = WorkbookDiffer()
    private let log: MCPLog
    private var documents: [String: OpenDocument] = [:]
    /// One recalculated read view per open document, so a session of `describe`, `find` and three
    /// `read_range` calls pays for the pass once rather than five times. Dropped whenever the
    /// session's workbook moves — which is only ever ``edit(path:preview:tool:_:)``,
    /// ``refresh(path:)`` and ``restore(path:id:)``.
    private var readViews: [String: OpenRecalculation.ReadView] = [:]
    private var failures = FailureBox()

    public init(
        store: SheetStore,
        configuration: Configuration = .default,
        log: MCPLog = MCPLog(destination: .none)
    ) {
        self.store = store
        self.configuration = configuration
        self.log = log
        reader = CachingWorkbookReader(capacity: configuration.maximumOpenDocuments)
        writer = TrackedWorkbookWriter()
    }

    // MARK: - The boundary

    /// Turns a path argument into a `URL`, or refuses.
    ///
    /// **Every** tool that names a file goes through here. The grant check runs on the string
    /// exactly as the caller wrote it, because A6's canonicaliser is what resolves `~`,
    /// `file://`, percent-encoding, `..` and symlinks — doing any of that first would move the
    /// resolution outside the check that depends on it.
    public nonisolated func resolve(_ path: String) throws(SheetError) -> URL {
        try store.grants.check(path)
        let url = URL(fileURLWithPath: DocumentBroker.expand(path))
        try WorkbookFormatSupport.requireReadable(url)
        return url
    }

    /// The same expansion A6's canonicaliser performs, applied after it has approved the path.
    ///
    /// Kept in step with ``SheetStore/WorkspaceGrants`` deliberately: the path we open must be
    /// the path that was checked, and the way to guarantee that is to do the same three things
    /// in the same order rather than to be cleverer here.
    static func expand(_ path: String) -> String {
        var input = path
        if input.hasPrefix("file://"), let url = URL(string: input), url.isFileURL {
            input = url.path(percentEncoded: false)
        }
        if input.hasPrefix("~") { input = (input as NSString).expandingTildeInPath }
        if !input.hasPrefix("/") {
            let base = FileManager.default.currentDirectoryPath
            input = base.hasSuffix("/") ? base + input : base + "/" + input
        }
        return input
    }

    // MARK: - Reading

    /// Opens `path` (or reuses an open session) and returns its workbook **as it should be read**.
    ///
    /// # Why this is not just `session.workbook`
    ///
    /// A workbook whose producer never calculated it — openpyxl, pandas, xlsxwriter, which is to
    /// say most files a Claude Code user has — stores real formulas next to placeholder zeroes.
    /// The app recalculates those on open so the user sees real numbers; if the server did not,
    /// `describe` and `read_range` would hand the agent the zeroes, and the agent and the person
    /// would disagree about the same file. See ``OpenRecalculation``, which is the *same*
    /// heuristic and the same 50,000-formula ceiling, shared rather than reimplemented.
    ///
    /// **Reading never writes.** The corrected workbook lives here; the file on disk keeps the
    /// producer's values until somebody calls `recalc`. ``edit(path:preview:tool:_:)`` deliberately
    /// starts from the session's untouched workbook for the same reason: an edit must not smuggle
    /// a whole-workbook recalculation into its diff.
    public func document(at path: String) async throws(SheetError) -> LoadedDocument {
        let url = try resolve(path)
        let session = try await session(for: url)
        let key = DocumentBroker.key(url)
        let raw = await session.workbook

        if let cached = readViews[key] {
            return LoadedDocument(url: url, workbook: cached.workbook, state: await session.state, recalculationNotice: cached.notice)
        }
        let view = OpenRecalculation.applyForReading(to: raw)
        readViews[key] = view
        return LoadedDocument(
            url: url, workbook: view.workbook, state: await session.state, recalculationNotice: view.notice
        )
    }

    /// Re-reads the file from disk, discarding nothing that was not already saved.
    public func refresh(path: String) async throws(SheetError) -> LoadedDocument {
        let url = try resolve(path)
        let session = try await session(for: url)
        guard await !session.hasUnsavedEdits else {
            throw SheetError.invalidToolArguments(
                tool: "refresh",
                detail: "there are unsaved in-memory edits; save or discard them first"
            )
        }
        // Prime before asking for the reload, so the synchronous read inside the session is a
        // cache hit rather than the blocking bridge. See `CachingWorkbookReader`.
        _ = try await primeFromDisk(url)
        await session.refresh()
        // A refresh is a re-open: whatever wrote the file is exactly the kind of tool that writes
        // formulas without computing them, so the read view has to be rebuilt, not reused.
        readViews[DocumentBroker.key(url)] = nil
        return LoadedDocument(url: url, workbook: await session.workbook, state: await session.state)
    }

    // MARK: - Writing

    /// Applies `body` to the workbook at `path` and saves the result.
    ///
    /// With `preview: true` the edit is applied to a copy, diffed, and thrown away — the file
    /// is never opened for writing and no snapshot is taken, because nothing happened.
    public func edit<Value: Sendable>(
        path: String,
        preview: Bool,
        tool: String,
        _ body: @Sendable (inout Workbook, inout WorkbookEditTracker) throws -> Value
    ) async throws -> EditOutcome<Value> {
        let url = try resolve(path)
        let session = try await session(for: url)
        let before = await session.workbook

        if let reason = before.meta.readOnlyReason {
            throw SheetError.writeRefused(reason: reason)
        }
        guard writer.canWrite(before, to: url) else {
            throw SheetError.writeRefused(reason: .unsupportedFormat)
        }

        var workbook = before
        var tracker = WorkbookEditTracker()
        let value = try body(&workbook, &tracker)
        let diff = differ.diff(before: before, after: workbook)

        guard !preview else {
            return EditOutcome(value: value, diff: diff, wrote: false, snapshotID: nil, sheetName: nil)
        }
        // Nothing changed: writing anyway would take a snapshot, bump the mtime and make the app
        // refresh, all to produce the same bytes. An agent that re-runs its own edit — which
        // they do — should not cost the user any of that.
        //
        // The diff is checked first because it is cheap; the whole-workbook comparison behind it
        // is exact and catches what a *cell* diff cannot, such as a column width. It only runs
        // when the diff already found nothing, so a real edit never pays for it.
        if diff.isEmpty, workbook == before {
            return EditOutcome(value: value, diff: diff, wrote: false, snapshotID: nil, sheetName: nil)
        }

        try await throttle(url)
        writer.setEdits(tracker, for: url)
        failures.clear(url)
        readViews[DocumentBroker.key(url)] = nil
        await session.replaceWorkbook(workbook)
        await session.save()

        if await session.hasUnsavedEdits {
            let state = await session.state
            writer.clearEdits(for: url)
            throw failures.take(url) ?? SheetError.fileNotWritable(
                path: url.path(percentEncoded: false),
                underlying: "the save did not complete; the document is \(state.rawValue)"
            )
        }
        writer.clearEdits(for: url)
        markWritten(url)
        log.write("wrote \(url.lastPathComponent) via \(tool): \(diff.summary)")

        let snapshot = try? await session.snapshotHistory().first { $0.reason == .preSave }
        return EditOutcome(
            value: value, diff: diff, wrote: true, snapshotID: snapshot?.id, sheetName: nil
        )
    }

    // MARK: - Snapshots

    /// Takes a snapshot the agent asked for.
    public func snapshot(path: String, summary: String?) async throws(SheetError) -> SnapshotRecord? {
        let url = try resolve(path)
        return try await store.snapshots.capture(url: url, reason: .manual, summary: summary)
    }

    /// Snapshots of `path`, newest first.
    public func snapshots(path: String) async throws(SheetError) -> [SnapshotRecord] {
        let url = try resolve(path)
        return try await store.snapshots.snapshots(for: url)
    }

    /// Puts a snapshot back, through the session so the app does not see it as an external
    /// change and refresh-loop.
    public func restore(path: String, id: ULID) async throws(SheetError) -> LoadedDocument {
        let url = try resolve(path)
        let bytes = try await store.snapshots.data(for: id, of: url)
        // A snapshot can outlive its file: `delete_file` snapshots the bytes and then trashes
        // them, and the documented undo is exactly this call. Opening a session reads the file,
        // so a missing target is resurrected from the snapshot's bytes first — through the
        // suppressor, atomically, like every write — and the session's own restore then runs
        // unchanged, pre-restore snapshot included.
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try store.suppressor.write(bytes, to: url)
        }
        let session = try await session(for: url)
        // The reload that follows the restore reads the bytes we are about to write. Parse
        // them now, so that read is a cache hit.
        if let workbook = try? await WorkbookParser.parse(bytes: bytes, url: url) {
            reader.prime(url, bytes: bytes, workbook: workbook)
        }
        _ = try await session.restore(id)
        readViews[DocumentBroker.key(url)] = nil
        return LoadedDocument(url: url, workbook: await session.workbook, state: await session.state)
    }

    /// The workbook a snapshot holds, without restoring it — what a `preview: true` restore
    /// diffs against.
    public func snapshotWorkbook(path: String, id: ULID) async throws(SheetError) -> Workbook {
        let url = try resolve(path)
        let bytes = try await store.snapshots.data(for: id, of: url)
        return try await WorkbookParser.parse(bytes: bytes, url: url)
    }

    /// What the writer is currently armed with for `url`, if anything.
    ///
    /// Exists so a test can assert the arming discipline — the tracker is set immediately before
    /// a save and cleared immediately after, and a preview never arms it at all.
    public func pendingEdits(for url: URL) -> WorkbookEditTracker? {
        writer.edits(for: url)
    }

    /// The differ every tool reports through, so two tools cannot disagree about what a change
    /// is.
    public nonisolated func diff(before: Workbook, after: Workbook) -> WorkbookDiff {
        WorkbookDiffer().diff(before: before, after: after)
    }

    /// Closes one file's session, if it is open.
    ///
    /// `delete_file` calls this immediately before trashing the file: a live session holds an
    /// FSEvents stream on the path and an in-memory workbook that would shadow the file's
    /// absence — every call after the delete should meet the missing file, not a ghost of it.
    public func close(_ url: URL) async {
        let key = DocumentBroker.key(url)
        guard let document = documents.removeValue(forKey: key) else { return }
        document.drain.cancel()
        await document.session.stop()
        readViews.removeValue(forKey: key)
    }

    /// Closes every session. The CLI calls this so a one-shot command does not leave an
    /// FSEvents stream running while the process tears down.
    public func closeAll() async {
        for (_, document) in documents {
            document.drain.cancel()
            await document.session.stop()
        }
        documents.removeAll()
        readViews.removeAll()
    }

    // MARK: - Sessions

    private func session(for url: URL) async throws(SheetError) -> DocumentSession {
        let key = DocumentBroker.key(url)
        if var existing = documents[key] {
            existing.lastUsed = .now
            documents[key] = existing
            return existing.session
        }
        try await evictIfNeeded()
        _ = try await primeFromDisk(url)

        let session = try await store.openDocument(
            at: url,
            io: WorkbookIO(reader: reader, writer: writer),
            // Auto-refresh off, on purpose. A tool call has to see one consistent workbook for
            // its whole duration; a reload landing between the read and the write would apply
            // an edit to a workbook the agent never saw. External changes still move the
            // document to `STALE`, and tools say so.
            options: DocumentSession.Options(autoRefresh: false)
        )
        let box = failures
        let drain = Task { [weak session] in
            guard let session else { return }
            for await event in session.events {
                if case let .failed(error) = event { box.record(error, for: url) }
            }
        }
        documents[key] = OpenDocument(session: session, drain: drain, lastUsed: .now, lastWrite: nil)
        return session
    }

    /// Reads the file and parses it asynchronously, so the synchronous read `SheetStore`
    /// performs is a cache hit.
    @discardableResult
    private func primeFromDisk(_ url: URL) async throws(SheetError) -> Workbook {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw SheetError.fileNotReadable(path: url.path(percentEncoded: false), underlying: "\(error)")
        }
        let workbook = try await WorkbookParser.parse(bytes: bytes, url: url)
        reader.prime(url, bytes: bytes, workbook: workbook)
        return workbook
    }

    private func evictIfNeeded() async throws(SheetError) {
        guard documents.count >= configuration.maximumOpenDocuments else { return }
        let victims = documents
            .sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(documents.count - configuration.maximumOpenDocuments + 1)
        for (key, document) in victims {
            // Never evict a document with unsaved edits: the in-memory workbook would be the
            // only copy and closing it would lose it silently.
            guard await !document.session.hasUnsavedEdits else { continue }
            document.drain.cancel()
            await document.session.stop()
            documents.removeValue(forKey: key)
            readViews.removeValue(forKey: key)
        }
    }

    // MARK: - Rate limiting

    private func throttle(_ url: URL) async throws(SheetError) {
        let key = DocumentBroker.key(url)
        guard let last = documents[key]?.lastWrite else { return }
        let elapsed = ContinuousClock.now - last
        guard elapsed < configuration.minimumWriteInterval else { return }
        try? await Task.sleep(for: configuration.minimumWriteInterval - elapsed)
    }

    private func markWritten(_ url: URL) {
        let key = DocumentBroker.key(url)
        guard var document = documents[key] else { return }
        document.lastWrite = .now
        documents[key] = document
    }

    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }
}

/// Catches the error a failed save reports through the session's event stream.
///
/// ``SheetStore/DocumentSession/save()`` returns `Void` and publishes the failure as an event,
/// because it was designed for a UI that observes a stream. A tool call has to answer *"did
/// that work"* synchronously, so the broker drains the stream into this and reads it back
/// after the save returns. `hasUnsavedEdits` is the authority on whether the save worked; this
/// only supplies the reason.
final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String: SheetError] = [:]

    func record(_ error: SheetError, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        errors[url.path(percentEncoded: false)] = error
    }

    func clear(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        errors.removeValue(forKey: url.path(percentEncoded: false))
    }

    func take(_ url: URL) -> SheetError? {
        lock.lock()
        defer { lock.unlock() }
        return errors.removeValue(forKey: url.path(percentEncoded: false))
    }
}
