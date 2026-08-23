import Foundation
import SheetModel

/// Something the UI should react to.
public enum DocumentSessionEvent: Sendable, Hashable {
    /// The document moved between states. Both are given so a view can animate the edge
    /// rather than the node.
    case stateChanged(from: DocumentSyncState, to: DocumentSyncState)
    /// A reload landed. The diff is against what was on screen before it.
    case refreshed(WorkbookDiff)
    /// A save landed.
    case saved(FileFingerprint)
    /// There is a diff worth showing but nothing has been applied — `STALE`, or `CONFLICT`.
    case diffAvailable(WorkbookDiff)
    /// Something went wrong. Never fatal; the state says what the document can still do.
    case failed(SheetError)
    /// The file's path is gone and the in-memory workbook is the only copy.
    case saveAsRequired
}

/// One open document, wired to the real filesystem (PLAN.md §6).
///
/// Ties the five pieces together: ``FileWatcher`` sees the change, ``SelfWriteSuppressor``
/// filters out our own saves, ``DocumentSyncMachine`` decides what it means,
/// ``SnapshotStore`` takes the safety copy the machine asked for, and ``WorkbookDiffer``
/// works out what to show. Every side effect performed here is one the state machine named,
/// which is what makes the guarantee "a snapshot is taken before every refresh and every save"
/// structural rather than a rule to remember.
///
/// An actor: the watcher's queue, the UI, and an MCP tool call all reach one of these.
public actor DocumentSession {
    /// Per-document settings.
    public struct Options: Sendable {
        /// PLAN.md §6.3's `autoRefresh` switch.
        public var autoRefresh: Bool
        /// Watcher timings. See ``FileWatcher/Configuration``.
        public var watcher: FileWatcher.Configuration
        /// Diff tuning. See ``WorkbookDiffer/Options``.
        public var diff: WorkbookDiffer.Options
        /// Take a `.preSave` snapshot before writing. Off only for tests that are measuring
        /// something else.
        public var snapshotsEnabled: Bool

        public init(
            autoRefresh: Bool = true,
            watcher: FileWatcher.Configuration = .default,
            diff: WorkbookDiffer.Options = .default,
            snapshotsEnabled: Bool = true
        ) {
            self.autoRefresh = autoRefresh
            self.watcher = watcher
            self.diff = diff
            self.snapshotsEnabled = snapshotsEnabled
        }

        public static let `default` = Options()
    }

    /// The file.
    public nonisolated let url: URL
    private let io: WorkbookIO
    private let suppressor: SelfWriteSuppressor
    private let snapshots: SnapshotStore?
    private let differ: WorkbookDiffer
    private let options: Options
    private let continuation: AsyncStream<DocumentSessionEvent>.Continuation

    /// Everything the UI should react to, in order.
    public nonisolated let events: AsyncStream<DocumentSessionEvent>

    private var machine: DocumentSyncMachine
    private var watcher: FileWatcher?
    private var pump: Task<Void, Never>?
    private var currentWorkbook: Workbook
    private var reloadQueued = false

    /// The diff for the change that has not been applied yet — what `STALE` and `CONFLICT`
    /// show. `nil` in every other state.
    public private(set) var pendingDiff: WorkbookDiff?

    public init(
        url: URL,
        workbook: Workbook,
        io: WorkbookIO,
        suppressor: SelfWriteSuppressor,
        snapshots: SnapshotStore? = nil,
        options: Options = .default
    ) {
        self.url = url
        self.io = io
        self.suppressor = suppressor
        self.snapshots = snapshots
        self.options = options
        differ = WorkbookDiffer(options: options.diff)
        currentWorkbook = workbook

        let probe = FileProbe.probe(url)
        var context = SyncContext(
            path: url.path(percentEncoded: false),
            autoRefreshEnabled: options.autoRefresh,
            hasUnsavedEdits: false,
            isWritable: probe.probe?.isWritable ?? false,
            readOnlyReason: workbook.meta.readOnlyReason ?? (io.writer == nil ? .unsupportedFormat : nil)
        )
        let initial: DocumentSyncState
        switch probe {
        case let .readable(details):
            if details.isImmutable {
                initial = .locked
            } else if context.readOnlyReason != nil || !details.isWritable {
                initial = .readOnly
                if context.readOnlyReason == nil { context.readOnlyReason = .fileSystemPermissions }
            } else {
                initial = .synced
            }
        case .missing, .volumeUnavailable:
            initial = .missing
        case .notDownloaded:
            initial = .unreadable
        case .unreadable:
            initial = .unreadable
        }
        machine = DocumentSyncMachine(state: initial, context: context)

        let (stream, continuation) = AsyncStream<DocumentSessionEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
    }

    deinit {
        pump?.cancel()
        watcher?.stop()
        continuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts watching the file.
    public func start() throws(SheetError) {
        guard watcher == nil else { return }
        let watcher = FileWatcher(url: url, configuration: options.watcher, suppressor: suppressor)
        try watcher.start()
        self.watcher = watcher
        pump = Task { [weak self] in
            for await event in watcher.events {
                await self?.receive(event)
            }
        }
    }

    /// Stops watching and closes ``events``.
    public func stop() {
        pump?.cancel()
        pump = nil
        watcher?.stop()
        watcher = nil
        continuation.finish()
    }

    // MARK: - State

    /// Where the document is. See ``DocumentSyncState``.
    public var state: DocumentSyncState { machine.state }
    /// The workbook as it is in memory.
    public var workbook: Workbook { currentWorkbook }
    /// The transition log, for diagnostics.
    public var history: [DocumentSyncMachine.Entry] { machine.history }
    /// Whether there are unsaved edits.
    public var hasUnsavedEdits: Bool { machine.context.hasUnsavedEdits }

    /// PLAN.md §6.3's `autoRefresh` switch. Turning it on while `STALE` reloads immediately,
    /// which is what the user means by turning it on.
    public func setAutoRefresh(_ enabled: Bool) async {
        machine.setAutoRefresh(enabled)
        if enabled, machine.state == .stale { await refresh() }
    }

    // MARK: - Editing

    /// Applies an edit to the in-memory workbook and moves the document to `DIRTY`.
    ///
    /// The only way the workbook changes, so `hasUnsavedEdits` cannot drift out of step with
    /// what is actually in memory.
    public func edit<T>(_ body: (inout Workbook) throws -> T) rethrows -> T {
        let result = try body(&currentWorkbook)
        apply(.userEdited)
        return result
    }

    /// Replaces the workbook wholesale — Save As, or an MCP write that rebuilt it.
    public func replaceWorkbook(_ workbook: Workbook) {
        currentWorkbook = workbook
        apply(.userEdited)
    }

    // MARK: - The three verbs

    /// ⌘S.
    public func save() async {
        await run(.saveRequested)
    }

    /// ⌘R.
    public func refresh() async {
        await run(.reloadRequested)
    }

    /// Answers the conflict banner.
    public func resolveConflict(_ resolution: ConflictResolution) async {
        await run(.conflictResolved(resolution))
    }

    /// Points the document at a new path and saves there. The way out of `MISSING`,
    /// `READ_ONLY` and `LOCKED`.
    public func saveAs(to destination: URL) async throws(SheetError) -> FileFingerprint {
        let fingerprint = try await performSave(to: destination)
        apply(.savedAsNewPath)
        return fingerprint
    }

    /// Snapshots of this file, newest first.
    public func snapshotHistory() async throws(SheetError) -> [SnapshotRecord] {
        guard let snapshots else { return [] }
        return try await snapshots.snapshots(for: url)
    }

    /// Puts a snapshot back. Atomic, fingerprinted, and therefore does **not** set off a
    /// refresh loop — the restore is one of our own writes as far as the watcher is concerned.
    @discardableResult
    public func restore(_ id: ULID) async throws(SheetError) -> FileFingerprint {
        guard let snapshots else { throw SheetError.snapshotNotFound(id: id.rawValue) }
        let fingerprint = try await snapshots.restore(id, to: url, suppressor: suppressor)
        // The bytes on disk changed under us on purpose, so pull them back into memory rather
        // than leaving the screen showing the version the user just undid.
        await reload()
        return fingerprint
    }

    // MARK: - Driving the machine

    private func receive(_ event: FileWatcherEvent) async {
        guard let transition = machine.apply(event) else { return }
        await perform(transition)
    }

    private func run(_ event: SyncEvent) async {
        await perform(machine.handle(event))
    }

    /// Applies an event whose effects are synchronous. Used from `edit`, which cannot `await`.
    private func apply(_ event: SyncEvent) {
        let before = machine.state
        let transition = machine.handle(event)
        if transition.state != before {
            continuation.yield(.stateChanged(from: before, to: transition.state))
        }
        for effect in transition.effects {
            if case let .report(error) = effect { continuation.yield(.failed(error)) }
            if case .offerSaveAs = effect { continuation.yield(.saveAsRequired) }
        }
    }

    private func perform(_ transition: SyncTransition) async {
        let before = machine.history.last?.from ?? transition.state
        if before != transition.state {
            continuation.yield(.stateChanged(from: before, to: transition.state))
        }

        for effect in transition.effects {
            switch effect {
            case let .captureSnapshot(reason):
                await capture(reason)
            case .beginReload:
                await reload()
            case .reloadAgainAfterCurrent:
                reloadQueued = true
            case .beginSave:
                await performSaveAndReport()
            case .discardLocalEdits:
                // The workbook itself is replaced by the reload that follows; the machine has
                // already cleared `hasUnsavedEdits`, so there is nothing left to drop here.
                break
            case .presentDiff, .presentConflict:
                if let diff = await computeDiskDiff() {
                    pendingDiff = diff
                    continuation.yield(.diffAvailable(diff))
                }
            case .flashDiff:
                break
            case .offerSaveAs:
                continuation.yield(.saveAsRequired)
            case let .report(error):
                continuation.yield(.failed(error))
            }
        }
    }

    // MARK: - Effects

    private func capture(_ reason: SnapshotReason) async {
        guard options.snapshotsEnabled, let snapshots else { return }
        // A snapshot that cannot be taken must not stop the thing it was protecting. The user
        // losing the safety net for one save is bad; the save failing because the safety net
        // failed is worse, because it is the state they are trying to leave.
        _ = try? await snapshots.capture(url: url, reason: reason, summary: nil)
    }

    private func reload() async {
        let previous = currentWorkbook
        do {
            let fresh = try io.reader.readWorkbook(at: url)
            currentWorkbook = fresh
            let diff = differ.diff(before: previous, after: fresh)
            pendingDiff = nil
            let transition = machine.handle(.reloadSucceeded)
            continuation.yield(.refreshed(diff))
            await finish(transition)
        } catch let error as SheetError {
            await finish(machine.handle(.reloadFailed(error)))
        } catch {
            await finish(machine.handle(.reloadFailed(.fileNotReadable(
                path: url.path(percentEncoded: false),
                underlying: "\(error)"
            ))))
        }
        if reloadQueued {
            reloadQueued = false
            await run(.reloadRequested)
        }
    }

    private func performSaveAndReport() async {
        do {
            let fingerprint = try await performSave(to: url)
            continuation.yield(.saved(fingerprint))
            await finish(machine.handle(.saveSucceeded))
        } catch {
            // `performSave` is typed, so this binds a `SheetError` — the save failure reaches
            // the state machine with its code intact rather than as a string.
            await finish(machine.handle(.saveFailed(error)))
        }
    }

    private func performSave(to destination: URL) async throws(SheetError) -> FileFingerprint {
        guard let writer = io.writer else {
            throw SheetError.writeRefused(reason: machine.context.readOnlyReason ?? .unsupportedFormat)
        }
        guard writer.canWrite(currentWorkbook, to: destination) else {
            throw SheetError.writeRefused(reason: currentWorkbook.meta.readOnlyReason ?? .unsupportedFormat)
        }
        let original = try? Data(contentsOf: destination)
        let bytes: Data
        do {
            bytes = try writer.encodeWorkbook(currentWorkbook, for: destination, originalBytes: original)
        } catch let error as SheetError {
            throw error
        } catch {
            throw SheetError.fileNotWritable(path: destination.path(percentEncoded: false), underlying: "\(error)")
        }
        return try suppressor.write(bytes, to: destination)
    }

    /// Yields the state change for a transition applied outside ``perform(_:for:)``, then runs
    /// its effects. Split out because a reload's success is itself an event, and letting it
    /// recurse through `perform` would make the ordering of `refreshed` and `stateChanged`
    /// depend on how deep the stack happened to be.
    private func finish(_ transition: SyncTransition) async {
        let before = machine.history.last?.from ?? transition.state
        if before != transition.state {
            continuation.yield(.stateChanged(from: before, to: transition.state))
        }
        for effect in transition.effects {
            switch effect {
            case let .report(error): continuation.yield(.failed(error))
            case .offerSaveAs: continuation.yield(.saveAsRequired)
            default: break
            }
        }
    }

    /// The diff between what is on screen and what is on disk, without applying it.
    private func computeDiskDiff() async -> WorkbookDiff? {
        guard let disk = try? io.reader.readWorkbook(at: url) else { return nil }
        return differ.diff(before: currentWorkbook, after: disk)
    }
}
