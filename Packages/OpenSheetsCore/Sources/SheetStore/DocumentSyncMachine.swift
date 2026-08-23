import Foundation
import SheetModel

/// A ``DocumentSyncState`` plus the context it needs, with the bookkeeping that keeps them
/// consistent.
///
/// A value type with no filesystem in it, so the whole of PLAN.md §6.3 can be exercised by
/// feeding it events in a loop. ``DocumentSession`` owns one and drives it from the real
/// watcher; the tests drive the same code with no I/O at all.
public struct DocumentSyncMachine: Sendable, Hashable {
    /// Current state.
    public private(set) var state: DocumentSyncState
    /// Current context. Mutable so callers can flip `autoRefreshEnabled` between events.
    public private(set) var context: SyncContext
    /// Every transition so far, newest last. Bounded — this is a debugging aid on a long-lived
    /// document, not an audit log.
    public private(set) var history: [Entry]

    /// One applied event, for the "why is my document in this state" question.
    public struct Entry: Sendable, Hashable {
        public var from: DocumentSyncState
        public var event: SyncEvent
        public var to: DocumentSyncState
        public var effects: [SyncEffect]
        public var wasIgnored: Bool
    }

    /// How many transitions ``history`` keeps.
    public static let historyLimit = 64

    public init(state: DocumentSyncState = .synced, context: SyncContext = SyncContext()) {
        self.state = state
        self.context = context
        history = []
    }

    /// Applies `event` and returns what happened.
    ///
    /// The only place ``SyncContext/hasUnsavedEdits`` is maintained. Keeping it here rather
    /// than at call sites is deliberate: it is the flag that decides whether a reappearing
    /// file is a refresh or a conflict, and a call site that forgets to set it turns a
    /// conflict into silent data loss.
    @discardableResult
    public mutating func handle(_ event: SyncEvent) -> SyncTransition {
        let from = state
        let transition = from.transition(on: event, context: context)
        state = transition.state

        switch event {
        case .userEdited where !transition.wasIgnored:
            context.hasUnsavedEdits = true
        case .saveSucceeded where !transition.wasIgnored,
             .reloadSucceeded where !transition.wasIgnored,
             .savedAsNewPath where !transition.wasIgnored:
            context.hasUnsavedEdits = false
        default:
            break
        }
        // `takeDisk` is the one path that throws work away, and it does so before the reload
        // rather than after it — so the flag has to clear here, not on `reloadSucceeded`,
        // or a reload failure would leave the document claiming edits it no longer has.
        if transition.effects.contains(.discardLocalEdits) { context.hasUnsavedEdits = false }

        history.append(Entry(
            from: from,
            event: event,
            to: transition.state,
            effects: transition.effects,
            wasIgnored: transition.wasIgnored
        ))
        if history.count > DocumentSyncMachine.historyLimit {
            history.removeFirst(history.count - DocumentSyncMachine.historyLimit)
        }
        return transition
    }

    /// PLAN.md §6.3's `autoRefresh ON`/`OFF` switch.
    public mutating func setAutoRefresh(_ enabled: Bool) {
        context.autoRefreshEnabled = enabled
    }

    /// Records what a fresh probe found about writability, and feeds the matching event in.
    ///
    /// Returns `nil` when the probe changes nothing. This is the single translation point
    /// between "what the filesystem says" and "which event the state machine gets", so the
    /// mapping is asserted in one place rather than being re-invented per call site.
    @discardableResult
    public mutating func apply(_ condition: FileCondition) -> SyncTransition? {
        switch condition {
        case let .readable(probe):
            context.isWritable = probe.isWritable
            if probe.isImmutable, state != .locked { return handle(.fileLocked) }
            if !probe.isWritable, !probe.isImmutable, state != .readOnly { return handle(.fileBecameReadOnly) }
            if probe.isWritable, context.readOnlyReason == nil, state == .locked || state == .readOnly {
                return handle(state == .locked ? .fileUnlocked : .fileBecameWritable)
            }
            return nil
        case .missing, .volumeUnavailable:
            return state == .missing ? nil : handle(.fileVanished)
        case .notDownloaded:
            return handle(.fileUnreadable(.fileNotDownloaded(path: context.path)))
        case let .unreadable(error):
            return handle(.fileUnreadable(error))
        }
    }

    /// Feeds a ``FileWatcherEvent`` in, doing the probe-to-event translation in one place.
    @discardableResult
    public mutating func apply(_ event: FileWatcherEvent) -> SyncTransition? {
        switch event {
        case let .changed(probe):
            context.isWritable = probe.isWritable
            if probe.isImmutable, state != .locked { return handle(.fileLocked) }
            return handle(.externalChangeDetected)
        case let .attributesChanged(probe):
            return apply(FileCondition.readable(probe))
        case .vanished, .volumeUnavailable:
            return state == .missing ? nil : handle(.fileVanished)
        case let .reappeared(probe):
            context.isWritable = probe.isWritable
            return handle(.fileReappeared)
        case .notDownloaded:
            return handle(.fileUnreadable(.fileNotDownloaded(path: context.path)))
        case let .unreadable(error), let .failed(error):
            return handle(.fileUnreadable(error))
        }
    }
}
