import Foundation
import SheetModel

/// Where a document stands relative to the file on disk (PLAN.md §6.3).
///
/// The whole point of naming these is that each one has a designed presentation and a
/// designed set of things the user can do. A document is never "sort of stale"; it is in
/// exactly one of these nine.
public enum DocumentSyncState: String, Sendable, Hashable, Codable, CaseIterable {
    /// What is on screen is what is on disk.
    case synced
    /// The file changed, we have no local edits, and auto-refresh is off. ⌘R reloads.
    case stale
    /// A reload is in flight.
    case reloading
    /// There are unsaved local edits and the file has not changed under us.
    case dirty
    /// There are unsaved local edits **and** the file changed. Nothing is discarded until the
    /// user chooses.
    case conflict
    /// The file was deleted or moved away. The document is still fully in memory.
    case missing
    /// The file is immutable — Finder's "Locked", or `chflags uchg`. Readable, not writable.
    case locked
    /// The file or its folder is not writable by us, or the workbook itself refused to be
    /// written back (``ReadOnlyReason``).
    case readOnly
    /// The file is there and we cannot make sense of it.
    case unreadable

    /// Whether unsaved work exists in this state. Drives the close-window prompt.
    public var mayHaveUnsavedEdits: Bool {
        switch self {
        case .dirty, .conflict, .missing, .locked, .readOnly: true
        case .synced, .stale, .reloading, .unreadable: false
        }
    }

    /// Whether a save could succeed from here.
    public var allowsSaving: Bool {
        switch self {
        case .synced, .stale, .dirty, .conflict: true
        case .reloading, .missing, .locked, .readOnly, .unreadable: false
        }
    }

    /// States entered because of the file rather than because of the user. The UI shows a
    /// banner for these and only these.
    public var isBlocked: Bool {
        switch self {
        case .missing, .locked, .readOnly, .unreadable: true
        case .synced, .stale, .reloading, .dirty, .conflict: false
        }
    }
}

/// What the user chose in the conflict banner (PLAN.md §6.3).
public enum ConflictResolution: String, Sendable, Hashable, Codable, CaseIterable {
    /// Save over the file, keeping the in-memory version.
    case keepMine
    /// Discard local edits and reload from disk.
    case takeDisk
    /// Show the diff. Resolves nothing; the document stays in `CONFLICT`.
    case compare
}

/// Everything that can happen to a document.
///
/// One flat enum on purpose: the transition table is a function of `(state, event, context)`
/// and nothing else, so anything that influences a transition has to be visible here or in
/// ``SyncContext``. Hidden inputs are what make a state machine untestable.
public enum SyncEvent: Sendable, Hashable {
    /// The user (or an MCP write) changed the in-memory workbook.
    case userEdited
    /// The watcher reported a real external change.
    case externalChangeDetected
    /// ⌘R, or auto-refresh deciding to go.
    case reloadRequested
    /// A reload finished and the workbook was replaced.
    case reloadSucceeded
    /// A reload failed. The error decides which state we land in.
    case reloadFailed(SheetError)
    /// ⌘S, or an MCP save.
    case saveRequested
    /// The bytes are on disk.
    case saveSucceeded
    /// The save failed. The error decides which state we land in — but never one that
    /// discards the edits.
    case saveFailed(SheetError)
    /// The path stopped resolving.
    case fileVanished
    /// The path resolves again.
    case fileReappeared
    /// The file became immutable.
    case fileLocked
    /// The file stopped being immutable.
    case fileUnlocked
    /// The file, or its folder, stopped being writable.
    case fileBecameReadOnly
    /// …and became writable again.
    case fileBecameWritable
    /// The file is there and unparseable.
    case fileUnreadable(SheetError)
    /// The user picked one of the three conflict buttons.
    case conflictResolved(ConflictResolution)
    /// Save As completed; the document now points at a path that exists and matches memory.
    case savedAsNewPath
}

/// The facts outside the state that a transition depends on.
///
/// `hasUnsavedEdits` is here rather than being implied by ``DocumentSyncState/dirty`` because a
/// document can hold unsaved edits *while* in `MISSING`, `LOCKED` or `READ_ONLY` — and what
/// happens when the file comes back is completely different depending on which. Making it
/// explicit is what stops "the file reappeared" from silently discarding an hour of work.
public struct SyncContext: Sendable, Hashable {
    /// The document's path, so transitions can build accurate errors.
    public var path: String
    /// PLAN.md §6.3's `autoRefresh ON`/`OFF` branch.
    public var autoRefreshEnabled: Bool
    /// Whether the in-memory workbook differs from what was last written.
    public var hasUnsavedEdits: Bool
    /// Whether the file *and* its folder are writable right now.
    public var isWritable: Bool
    /// Non-`nil` when the workbook itself refuses to be written back (PLAN.md §5.2).
    public var readOnlyReason: ReadOnlyReason?

    public init(
        path: String = "",
        autoRefreshEnabled: Bool = true,
        hasUnsavedEdits: Bool = false,
        isWritable: Bool = true,
        readOnlyReason: ReadOnlyReason? = nil
    ) {
        self.path = path
        self.autoRefreshEnabled = autoRefreshEnabled
        self.hasUnsavedEdits = hasUnsavedEdits
        self.isWritable = isWritable
        self.readOnlyReason = readOnlyReason
    }

    /// Whether a save can be attempted at all, ignoring state.
    var canAttemptSave: Bool { isWritable && readOnlyReason == nil }

    /// The reason a save would be refused, for ``SheetError/writeRefused(reason:)``.
    var refusalReason: ReadOnlyReason { readOnlyReason ?? .fileSystemPermissions }
}

/// A side effect the transition asks its owner to perform.
///
/// The transition function does no I/O — it *names* the I/O. That is what makes the whole
/// table testable with no filesystem, and it is also why every snapshot in the product is
/// taken: `.captureSnapshot` is emitted by the table, not remembered by a call site.
public enum SyncEffect: Sendable, Hashable {
    /// Take a snapshot of the file as it is now, for the given reason. PLAN.md §5.5 requires
    /// one before every external refresh and before every one of our own saves.
    case captureSnapshot(SnapshotReason)
    /// Start reading the file.
    case beginReload
    /// Another change arrived while a reload was in flight; reload again when it finishes.
    case reloadAgainAfterCurrent
    /// Start writing the file.
    case beginSave
    /// Throw away the in-memory edits. Only ever emitted after an explicit user choice.
    case discardLocalEdits
    /// Show the diff panel.
    case presentDiff
    /// Show the conflict banner.
    case presentConflict
    /// Flash the changed cells in the grid.
    case flashDiff
    /// Offer Save As, because the original path is gone or unwritable.
    case offerSaveAs
    /// Surface this to the user.
    case report(SheetError)
}

/// The result of applying one event.
public struct SyncTransition: Sendable, Hashable {
    /// Where the document is now. Equal to the previous state for a self-loop.
    public var state: DocumentSyncState
    /// What the owner should do, in order.
    public var effects: [SyncEffect]
    /// The event does not apply in this state and nothing happened.
    ///
    /// Not an error: an `.attrib` event arriving in `UNREADABLE`, or a stray `saveSucceeded`
    /// after the user already reloaded, are both ordinary races. But a transition that
    /// *should* have done something and did not is a bug, so the flag is surfaced rather than
    /// swallowed, and every ignored pair is asserted in ``SyncStateMachineTests``.
    public var wasIgnored: Bool

    init(_ state: DocumentSyncState, _ effects: [SyncEffect] = [], ignored: Bool = false) {
        self.state = state
        self.effects = effects
        wasIgnored = ignored
    }

    static func ignore(_ state: DocumentSyncState) -> SyncTransition {
        SyncTransition(state, [], ignored: true)
    }
}

extension DocumentSyncState {
    /// PLAN.md §6.3's diagram, as a total function.
    ///
    /// Total in the strict sense: every one of the 9 × 21 state/event pairs has an answer, and
    /// none of them traps. The illegal ones return the current state with
    /// ``SyncTransition/wasIgnored`` set, because a spreadsheet app that crashes on an
    /// out-of-order filesystem event is a spreadsheet app that crashes.
    ///
    /// Three rules run through the whole table and are worth stating once:
    ///
    /// 1. **Local edits are never discarded implicitly.** Anything that would overwrite them
    ///    routes to `CONFLICT` instead — including ⌘R while dirty, and a file reappearing
    ///    while dirty. Only ``ConflictResolution/takeDisk`` emits ``SyncEffect/discardLocalEdits``.
    /// 2. **A failed save keeps the document dirty.** The bytes in memory are the only copy of
    ///    what the user typed; a save that could not land must not look like one that did.
    /// 3. **`LOCKED` and `READ_ONLY` are about writability, not readability.** A locked file
    ///    still refreshes — the state persists across the reload rather than being replaced by
    ///    `RELOADING`, because the lock is a fact about the file and the reload is an activity.
    public func transition(on event: SyncEvent, context: SyncContext) -> SyncTransition {
        switch self {
        case .synced: DocumentSyncState.fromSynced(event, context)
        case .stale: DocumentSyncState.fromStale(event, context)
        case .reloading: DocumentSyncState.fromReloading(event, context)
        case .dirty: DocumentSyncState.fromDirty(event, context)
        case .conflict: DocumentSyncState.fromConflict(event, context)
        case .missing: DocumentSyncState.fromMissing(event, context)
        case .locked: DocumentSyncState.fromLocked(event, context)
        case .readOnly: DocumentSyncState.fromReadOnly(event, context)
        case .unreadable: DocumentSyncState.fromUnreadable(event, context)
        }
    }

    // MARK: - Shared fragments

    /// `SYNCED --external change--> RELOADING | STALE`, the top edge of the diagram.
    private static func absorbExternalChange(_ context: SyncContext) -> SyncTransition {
        guard context.autoRefreshEnabled else { return SyncTransition(.stale, [.presentDiff]) }
        return SyncTransition(.reloading, [.captureSnapshot(.preRefresh), .beginReload])
    }

    /// The blocking states, which can be entered from anywhere. Returns `nil` when `event` is
    /// not one of them, so each state's own table only spells out what is special about it.
    private static func blockingEntry(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition? {
        switch event {
        case .fileVanished:
            SyncTransition(.missing, context.hasUnsavedEdits ? [.offerSaveAs] : [])
        case .fileLocked:
            SyncTransition(.locked, [.report(.fileLocked(path: context.path))])
        case .fileBecameReadOnly:
            SyncTransition(.readOnly, [.report(.writeRefused(reason: context.refusalReason))])
        case let .fileUnreadable(error):
            SyncTransition(.unreadable, [.report(error)])
        default:
            nil
        }
    }

    /// Where a failed reload lands. The error, not the state, decides.
    private static func afterReloadFailure(_ error: SheetError, _ context: SyncContext) -> SyncTransition {
        switch error {
        case .fileVanished, .fileNotFound:
            SyncTransition(.missing, context.hasUnsavedEdits ? [.offerSaveAs, .report(error)] : [.report(error)])
        case .fileLocked:
            SyncTransition(.locked, [.report(error)])
        default:
            SyncTransition(.unreadable, [.report(error)])
        }
    }

    /// Where a failed save lands. Never anywhere that loses the edits.
    private static func afterSaveFailure(
        _ error: SheetError,
        _ context: SyncContext,
        stayingIn state: DocumentSyncState
    ) -> SyncTransition {
        switch error {
        case .fileVanished, .fileNotFound:
            SyncTransition(.missing, [.offerSaveAs, .report(error)])
        case .fileLocked:
            SyncTransition(.locked, [.report(error)])
        case .writeRefused, .fileNotWritable:
            SyncTransition(.readOnly, [.report(error), .offerSaveAs])
        default:
            // Disk full, a short write, anything transient: stay put and keep the edits.
            SyncTransition(state, [.report(error)])
        }
    }

    /// A save attempt from a state that has something to save.
    private static func attemptSave(_ context: SyncContext, from state: DocumentSyncState) -> SyncTransition {
        guard context.canAttemptSave else {
            return SyncTransition(state, [.report(.writeRefused(reason: context.refusalReason)), .offerSaveAs])
        }
        return SyncTransition(state, [.captureSnapshot(.preSave), .beginSave])
    }

    // MARK: - Per-state tables

    private static func fromSynced(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        if let blocked = blockingEntry(event, context) { return blocked }
        switch event {
        case .userEdited:
            return SyncTransition(.dirty)
        case .externalChangeDetected:
            return absorbExternalChange(context)
        case .reloadRequested:
            // Unreachable through the table — SYNCED with unsaved edits does not occur — but a
            // reload that could overwrite an edit must be impossible by construction, not by
            // reachability argument.
            guard !context.hasUnsavedEdits else { return SyncTransition(.conflict, [.presentConflict]) }
            return SyncTransition(.reloading, [.captureSnapshot(.preRefresh), .beginReload])
        case .savedAsNewPath:
            return SyncTransition(.synced)
        case .fileUnlocked, .fileBecameWritable:
            return SyncTransition(.synced)
        // Nothing to save, so ⌘S is a no-op rather than a pointless rewrite of the file —
        // which would produce an mtime change, an event, and a diff of nothing.
        case .saveRequested, .saveSucceeded, .saveFailed, .reloadSucceeded, .reloadFailed,
             .fileReappeared, .conflictResolved:
            return .ignore(.synced)
        case .fileVanished, .fileLocked, .fileBecameReadOnly, .fileUnreadable:
            return .ignore(.synced)
        }
    }

    private static func fromStale(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        if let blocked = blockingEntry(event, context) { return blocked }
        switch event {
        // Editing a document whose disk copy has already moved on is the conflict condition,
        // arrived at from the other side. PLAN.md draws only DIRTY -> CONFLICT; this is the
        // same predicate and it must land in the same place, or ⌘S would silently clobber.
        case .userEdited:
            return SyncTransition(.conflict, [.presentConflict])
        case .reloadRequested:
            guard !context.hasUnsavedEdits else { return SyncTransition(.conflict, [.presentConflict]) }
            return SyncTransition(.reloading, [.captureSnapshot(.preRefresh), .beginReload])
        case .externalChangeDetected:
            return SyncTransition(.stale, [.presentDiff])
        case .savedAsNewPath:
            return SyncTransition(.synced)
        case .fileUnlocked, .fileBecameWritable:
            return SyncTransition(.stale)
        case .saveRequested, .saveSucceeded, .saveFailed, .reloadSucceeded, .reloadFailed,
             .fileReappeared, .conflictResolved:
            return .ignore(.stale)
        case .fileVanished, .fileLocked, .fileBecameReadOnly, .fileUnreadable:
            return .ignore(.stale)
        }
    }

    private static func fromReloading(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        if let blocked = blockingEntry(event, context) { return blocked }
        switch event {
        case .reloadSucceeded:
            return SyncTransition(.synced, [.flashDiff])
        case let .reloadFailed(error):
            return afterReloadFailure(error, context)
        case .externalChangeDetected:
            return SyncTransition(.reloading, [.reloadAgainAfterCurrent])
        // An edit landing mid-reload means both sides moved. The reload's result would
        // overwrite the edit, so stop and ask rather than racing.
        case .userEdited:
            return SyncTransition(.conflict, [.presentConflict])
        case .savedAsNewPath:
            return SyncTransition(.synced)
        case .reloadRequested:
            return SyncTransition(.reloading, [.reloadAgainAfterCurrent])
        case .saveRequested, .saveSucceeded, .saveFailed, .fileReappeared,
             .conflictResolved, .fileUnlocked, .fileBecameWritable:
            return .ignore(.reloading)
        case .fileVanished, .fileLocked, .fileBecameReadOnly, .fileUnreadable:
            return .ignore(.reloading)
        }
    }

    private static func fromDirty(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        if let blocked = blockingEntry(event, context) { return blocked }
        switch event {
        case .userEdited:
            return SyncTransition(.dirty)
        case .externalChangeDetected:
            return SyncTransition(.conflict, [.presentConflict])
        case .saveRequested:
            return attemptSave(context, from: .dirty)
        case .saveSucceeded:
            return SyncTransition(.synced)
        case let .saveFailed(error):
            return afterSaveFailure(error, context, stayingIn: .dirty)
        // ⌘R with unsaved edits would discard them. Ask instead.
        case .reloadRequested:
            return SyncTransition(.conflict, [.presentConflict])
        case .savedAsNewPath:
            return SyncTransition(.synced)
        case .fileUnlocked, .fileBecameWritable:
            return SyncTransition(.dirty)
        case .reloadSucceeded, .reloadFailed, .fileReappeared, .conflictResolved:
            return .ignore(.dirty)
        case .fileVanished, .fileLocked, .fileBecameReadOnly, .fileUnreadable:
            return .ignore(.dirty)
        }
    }

    private static func fromConflict(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        if let blocked = blockingEntry(event, context) { return blocked }
        switch event {
        case let .conflictResolved(resolution):
            switch resolution {
            case .keepMine:
                return attemptSave(context, from: .conflict)
            case .takeDisk:
                return SyncTransition(
                    .reloading,
                    [.captureSnapshot(.preRefresh), .discardLocalEdits, .beginReload]
                )
            case .compare:
                return SyncTransition(.conflict, [.presentDiff])
            }
        case .saveRequested:
            return attemptSave(context, from: .conflict)
        case .saveSucceeded:
            return SyncTransition(.synced)
        case let .saveFailed(error):
            return afterSaveFailure(error, context, stayingIn: .conflict)
        case .userEdited, .externalChangeDetected:
            return SyncTransition(.conflict, [.presentConflict])
        case .savedAsNewPath:
            return SyncTransition(.synced)
        case .fileUnlocked, .fileBecameWritable:
            return SyncTransition(.conflict)
        // A bare ⌘R in a conflict is ambiguous — it is `takeDisk` with no confirmation.
        // Refusing it costs one click and cannot lose anything.
        case .reloadRequested, .reloadSucceeded, .reloadFailed, .fileReappeared:
            return .ignore(.conflict)
        case .fileVanished, .fileLocked, .fileBecameReadOnly, .fileUnreadable:
            return .ignore(.conflict)
        }
    }

    private static func fromMissing(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        switch event {
        // A file that comes back with edits pending is a conflict: we have no idea whether the
        // returning bytes are the ones we last saw.
        case .fileReappeared, .externalChangeDetected:
            if context.hasUnsavedEdits { return SyncTransition(.conflict, [.presentConflict]) }
            return absorbExternalChange(context)
        case .savedAsNewPath:
            return SyncTransition(.synced)
        case .userEdited:
            return SyncTransition(.missing)
        case .saveRequested:
            return SyncTransition(.missing, [.report(.fileVanished(path: context.path)), .offerSaveAs])
        case let .saveFailed(error):
            return SyncTransition(.missing, [.report(error), .offerSaveAs])
        case .reloadRequested:
            return SyncTransition(.missing, [.report(.fileVanished(path: context.path))])
        case let .reloadFailed(error):
            return SyncTransition(.missing, [.report(error)])
        case let .fileUnreadable(error):
            return SyncTransition(.unreadable, [.report(error)])
        case .saveSucceeded, .reloadSucceeded, .fileVanished, .fileLocked, .fileUnlocked,
             .fileBecameReadOnly, .fileBecameWritable, .conflictResolved:
            return .ignore(.missing)
        }
    }

    private static func fromLocked(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        switch event {
        case .fileUnlocked, .fileBecameWritable:
            return SyncTransition(context.hasUnsavedEdits ? .dirty : .synced)
        case .fileVanished:
            return SyncTransition(.missing, context.hasUnsavedEdits ? [.offerSaveAs] : [])
        case let .fileUnreadable(error):
            return SyncTransition(.unreadable, [.report(error)])
        case .userEdited:
            return SyncTransition(.locked)
        // Locked blocks writing, not reading: keep refreshing, keep the state.
        case .externalChangeDetected, .reloadRequested:
            guard !context.hasUnsavedEdits else { return SyncTransition(.locked, [.presentConflict]) }
            guard context.autoRefreshEnabled || event == .reloadRequested else {
                return SyncTransition(.locked, [.presentDiff])
            }
            return SyncTransition(.locked, [.captureSnapshot(.preRefresh), .beginReload])
        case .reloadSucceeded:
            return SyncTransition(.locked, [.flashDiff])
        case let .reloadFailed(error):
            return SyncTransition(.locked, [.report(error)])
        case .saveRequested:
            return SyncTransition(.locked, [.report(.fileLocked(path: context.path)), .offerSaveAs])
        case let .saveFailed(error):
            return SyncTransition(.locked, [.report(error)])
        case .savedAsNewPath:
            return SyncTransition(.synced)
        case .fileLocked, .fileBecameReadOnly, .saveSucceeded, .fileReappeared, .conflictResolved:
            return .ignore(.locked)
        }
    }

    private static func fromReadOnly(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        switch event {
        case .fileBecameWritable, .fileUnlocked:
            // The workbook's own refusal outranks the filesystem's: a `.xlsb` does not become
            // writable because someone ran `chmod`.
            guard context.readOnlyReason == nil else { return .ignore(.readOnly) }
            return SyncTransition(context.hasUnsavedEdits ? .dirty : .synced)
        case .fileVanished:
            return SyncTransition(.missing, context.hasUnsavedEdits ? [.offerSaveAs] : [])
        case .fileLocked:
            return SyncTransition(.locked, [.report(.fileLocked(path: context.path))])
        case let .fileUnreadable(error):
            return SyncTransition(.unreadable, [.report(error)])
        case .userEdited:
            return SyncTransition(.readOnly)
        case .externalChangeDetected, .reloadRequested:
            guard !context.hasUnsavedEdits else { return SyncTransition(.readOnly, [.presentConflict]) }
            guard context.autoRefreshEnabled || event == .reloadRequested else {
                return SyncTransition(.readOnly, [.presentDiff])
            }
            return SyncTransition(.readOnly, [.captureSnapshot(.preRefresh), .beginReload])
        case .reloadSucceeded:
            return SyncTransition(.readOnly, [.flashDiff])
        case let .reloadFailed(error):
            return SyncTransition(.readOnly, [.report(error)])
        case .saveRequested:
            return SyncTransition(
                .readOnly,
                [.report(.writeRefused(reason: context.refusalReason)), .offerSaveAs]
            )
        case let .saveFailed(error):
            return SyncTransition(.readOnly, [.report(error)])
        case .savedAsNewPath:
            return SyncTransition(.synced)
        case .fileBecameReadOnly, .saveSucceeded, .fileReappeared, .conflictResolved:
            return .ignore(.readOnly)
        }
    }

    private static func fromUnreadable(_ event: SyncEvent, _ context: SyncContext) -> SyncTransition {
        switch event {
        case .reloadRequested:
            return SyncTransition(.reloading, [.beginReload])
        // The file changed, so whatever was wrong with it may have been fixed. Try again —
        // but no snapshot: there is nothing worth preserving about a file we cannot read.
        case .externalChangeDetected:
            guard context.autoRefreshEnabled else { return SyncTransition(.unreadable) }
            return SyncTransition(.reloading, [.beginReload])
        case .reloadSucceeded:
            return SyncTransition(.synced)
        case let .reloadFailed(error):
            return SyncTransition(.unreadable, [.report(error)])
        case .fileVanished:
            return SyncTransition(.missing)
        case let .fileUnreadable(error):
            return SyncTransition(.unreadable, [.report(error)])
        case .savedAsNewPath:
            return SyncTransition(.synced)
        // There is no document to edit, save, lock or unlock.
        case .userEdited, .saveRequested, .saveSucceeded, .saveFailed, .fileReappeared,
             .fileLocked, .fileUnlocked, .fileBecameReadOnly, .fileBecameWritable, .conflictResolved:
            return .ignore(.unreadable)
        }
    }
}
