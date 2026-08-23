import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// PLAN.md §6.3, exercised with no filesystem at all.
///
/// The point of a pure transition function is that the *whole* table can be asserted, including
/// the pairs that should do nothing. A state machine tested only along its happy path is a
/// state machine whose illegal transitions are undefined behaviour, and undefined behaviour in
/// this particular machine is "the user's unsaved edits vanished".
@Suite struct SyncStateMachineTests {
    private func context(
        autoRefresh: Bool = true,
        dirty: Bool = false,
        writable: Bool = true,
        readOnly: ReadOnlyReason? = nil
    ) -> SyncContext {
        SyncContext(
            path: "/tmp/book.xlsx",
            autoRefreshEnabled: autoRefresh,
            hasUnsavedEdits: dirty,
            isWritable: writable,
            readOnlyReason: readOnly
        )
    }

    /// Every event, so the exhaustiveness checks below cannot silently miss one.
    private static let allEvents: [SyncEvent] = [
        .userEdited, .externalChangeDetected, .reloadRequested, .reloadSucceeded,
        .reloadFailed(.xmlMalformed(part: "sheet1.xml", line: 2, detail: "bad")),
        .saveRequested, .saveSucceeded, .saveFailed(.diskFull(path: "/tmp/book.xlsx")),
        .fileVanished, .fileReappeared, .fileLocked, .fileUnlocked,
        .fileBecameReadOnly, .fileBecameWritable,
        .fileUnreadable(.fileNotReadable(path: "/tmp/book.xlsx", underlying: "permission denied")),
        .conflictResolved(.keepMine), .conflictResolved(.takeDisk), .conflictResolved(.compare),
        .savedAsNewPath,
    ]

    // MARK: - The diagram, edge by edge

    /// `SYNCED --external change, autoRefresh ON--> RELOADING --> SYNCED`, with the snapshot
    /// PLAN.md §5.5 requires before every refresh.
    @Test func syncedAbsorbsAnExternalChangeWhenAutoRefreshIsOn() {
        let transition = DocumentSyncState.synced.transition(on: .externalChangeDetected, context: context())
        #expect(transition.state == .reloading)
        #expect(transition.effects.contains(.captureSnapshot(.preRefresh)))
        #expect(transition.effects.contains(.beginReload))

        let finished = DocumentSyncState.reloading.transition(on: .reloadSucceeded, context: context())
        #expect(finished.state == .synced)
        #expect(finished.effects.contains(.flashDiff))
    }

    /// `SYNCED --external change, autoRefresh OFF--> STALE -(⌘R)-> RELOADING --> SYNCED`.
    @Test func syncedGoesStaleWhenAutoRefreshIsOff() {
        let manual = context(autoRefresh: false)
        let stale = DocumentSyncState.synced.transition(on: .externalChangeDetected, context: manual)
        #expect(stale.state == .stale)
        #expect(stale.effects.contains(.presentDiff))
        #expect(!stale.effects.contains(.beginReload))

        let reload = DocumentSyncState.stale.transition(on: .reloadRequested, context: manual)
        #expect(reload.state == .reloading)
        #expect(reload.effects.contains(.captureSnapshot(.preRefresh)))
    }

    /// `SYNCED --user edits--> DIRTY --save--> SYNCED`, with the pre-save snapshot.
    @Test func dirtySavesBackToSynced() {
        #expect(DocumentSyncState.synced.transition(on: .userEdited, context: context()).state == .dirty)

        let save = DocumentSyncState.dirty.transition(on: .saveRequested, context: context(dirty: true))
        #expect(save.state == .dirty)
        #expect(save.effects.contains(.captureSnapshot(.preSave)))
        #expect(save.effects.contains(.beginSave))
        #expect(DocumentSyncState.dirty.transition(on: .saveSucceeded, context: context(dirty: true)).state == .synced)
    }

    /// `DIRTY --external change--> CONFLICT`, and the three ways out of it.
    @Test func conflictOffersThreeWaysOut() {
        let conflict = DocumentSyncState.dirty.transition(on: .externalChangeDetected, context: context(dirty: true))
        #expect(conflict.state == .conflict)
        #expect(conflict.effects.contains(.presentConflict))

        let mine = DocumentSyncState.conflict.transition(
            on: .conflictResolved(.keepMine),
            context: context(dirty: true)
        )
        #expect(mine.state == .conflict)
        #expect(mine.effects.contains(.beginSave))
        let saved = DocumentSyncState.conflict.transition(on: .saveSucceeded, context: context(dirty: true))
        #expect(saved.state == .synced)

        let disk = DocumentSyncState.conflict.transition(
            on: .conflictResolved(.takeDisk),
            context: context(dirty: true)
        )
        #expect(disk.state == .reloading)
        #expect(disk.effects.contains(.discardLocalEdits))
        #expect(disk.effects.contains(.captureSnapshot(.preRefresh)))

        let compare = DocumentSyncState.conflict.transition(
            on: .conflictResolved(.compare),
            context: context(dirty: true)
        )
        #expect(compare.state == .conflict, "Compare shows a diff; it does not resolve anything")
        #expect(compare.effects.contains(.presentDiff))
    }

    // MARK: - The invariants

    /// **Nothing but an explicit `takeDisk` ever discards local edits.**
    ///
    /// Asserted over the entire table rather than at the four places it could go wrong, because
    /// the fifth place is the one that ships.
    @Test func onlyTakeDiskEverDiscardsEdits() {
        for state in DocumentSyncState.allCases {
            for event in SyncStateMachineTests.allEvents {
                let transition = state.transition(on: event, context: context(dirty: true))
                if transition.effects.contains(.discardLocalEdits) {
                    #expect(
                        event == .conflictResolved(.takeDisk),
                        "\(state) + \(event) discards the user's edits without being asked"
                    )
                }
            }
        }
    }

    /// **A reload never starts while there are unsaved edits**, unless the user chose it. ⌘R
    /// with unsaved work goes to `CONFLICT` instead.
    @Test func reloadNeverStartsOverUnsavedEdits() {
        for state in DocumentSyncState.allCases {
            let transition = state.transition(on: .reloadRequested, context: context(dirty: true))
            #expect(
                !transition.effects.contains(.beginReload) || state == .unreadable,
                "\(state) + ⌘R starts a reload over unsaved edits"
            )
        }
        // …and the three states where it could have are all routed to the conflict banner
        // instead, so the user gets asked rather than overwritten.
        for state in [DocumentSyncState.synced, .stale, .dirty] {
            #expect(state.transition(on: .reloadRequested, context: context(dirty: true)).state == .conflict)
        }
        // `UNREADABLE` is the exception, and deliberately: there is no parsed document, so
        // there are no edits to protect. Retrying the read is the only useful thing ⌘R can do.
        #expect(DocumentSyncState.unreadable.transition(on: .reloadRequested, context: context(dirty: true))
            .state == .reloading)
    }

    /// **A failed save never lands anywhere that loses the edits.** Disk full leaves the
    /// document dirty and complaining, not clean and wrong.
    @Test func failedSaveKeepsTheEdits() {
        let full = DocumentSyncState.dirty.transition(
            on: .saveFailed(.diskFull(path: "/tmp/book.xlsx")),
            context: context(dirty: true)
        )
        #expect(full.state == .dirty)
        #expect(full.effects.contains(.report(.diskFull(path: "/tmp/book.xlsx"))))

        let vanished = DocumentSyncState.dirty.transition(
            on: .saveFailed(.fileVanished(path: "/tmp/book.xlsx")),
            context: context(dirty: true)
        )
        #expect(vanished.state == .missing)
        #expect(vanished.effects.contains(.offerSaveAs))

        let refused = DocumentSyncState.dirty.transition(
            on: .saveFailed(.writeRefused(reason: .fileSystemPermissions)),
            context: context(dirty: true)
        )
        #expect(refused.state == .readOnly)
        #expect(refused.effects.contains(.offerSaveAs))

        for state in DocumentSyncState.allCases {
            let transition = state.transition(
                on: .saveFailed(.diskFull(path: "/tmp/book.xlsx")),
                context: context(dirty: true)
            )
            #expect(
                transition.state != .synced || state == .synced,
                "\(state) + saveFailed moved the document to SYNCED, which reads as a save that worked"
            )
        }
    }

    /// **Editing while stale is a conflict**, arrived at from the other side of the diagram.
    /// Anything else would let ⌘S clobber the external change.
    @Test func editingWhileStaleIsAConflict() {
        let transition = DocumentSyncState.stale.transition(on: .userEdited, context: context(autoRefresh: false))
        #expect(transition.state == .conflict)
        #expect(transition.effects.contains(.presentConflict))
    }

    /// **A save is never attempted when it cannot succeed**, and the refusal names the reason.
    @Test func savingIsRefusedWhenTheWorkbookIsReadOnly() {
        for state in [DocumentSyncState.dirty, .conflict] {
            let transition = state.transition(
                on: .saveRequested,
                context: context(dirty: true, writable: false, readOnly: .encrypted)
            )
            #expect(!transition.effects.contains(.beginSave))
            #expect(transition.effects.contains(.report(.writeRefused(reason: .encrypted))))
            #expect(transition.effects.contains(.offerSaveAs))
        }
    }

    // MARK: - The blocking states

    /// `MISSING` — the file went away. The document is intact in memory and Save As is offered
    /// only when there is something unsaved to rescue.
    @Test func missingOffersSaveAsOnlyWhenThereIsSomethingToRescue() {
        let dirty = DocumentSyncState.dirty.transition(on: .fileVanished, context: context(dirty: true))
        #expect(dirty.state == .missing)
        #expect(dirty.effects.contains(.offerSaveAs))

        let clean = DocumentSyncState.synced.transition(on: .fileVanished, context: context())
        #expect(clean.state == .missing)
        #expect(!clean.effects.contains(.offerSaveAs))
    }

    /// A file that comes back while edits are pending is a **conflict**, not a refresh: nothing
    /// says the returning bytes are the ones we last saw.
    @Test func fileReappearingWhileDirtyIsAConflict() {
        let dirty = DocumentSyncState.missing.transition(on: .fileReappeared, context: context(dirty: true))
        #expect(dirty.state == .conflict)

        let clean = DocumentSyncState.missing.transition(on: .fileReappeared, context: context())
        #expect(clean.state == .reloading)

        let manual = DocumentSyncState.missing.transition(
            on: .fileReappeared,
            context: context(autoRefresh: false)
        )
        #expect(manual.state == .stale)
    }

    /// `LOCKED` blocks writing, not reading. Refreshes still happen and the state persists —
    /// the lock is a fact about the file, the reload is an activity.
    @Test func lockedStillRefreshes() {
        let refresh = DocumentSyncState.locked.transition(on: .externalChangeDetected, context: context())
        #expect(refresh.state == .locked)
        #expect(refresh.effects.contains(.beginReload))
        #expect(DocumentSyncState.locked.transition(on: .reloadSucceeded, context: context()).state == .locked)

        let save = DocumentSyncState.locked.transition(on: .saveRequested, context: context(dirty: true))
        #expect(save.state == .locked)
        #expect(!save.effects.contains(.beginSave))
        #expect(save.effects.contains(.offerSaveAs))

        #expect(DocumentSyncState.locked.transition(on: .fileUnlocked, context: context()).state == .synced)
        #expect(DocumentSyncState.locked.transition(on: .fileUnlocked, context: context(dirty: true)).state == .dirty)
    }

    /// `READ_ONLY`. The workbook's own refusal outranks the filesystem's: a `.xlsb` does not
    /// become writable because somebody ran `chmod`.
    @Test func readOnlyWorkbookStaysReadOnlyAfterChmod() {
        let filesystem = DocumentSyncState.readOnly.transition(on: .fileBecameWritable, context: context())
        #expect(filesystem.state == .synced)

        let workbook = DocumentSyncState.readOnly.transition(
            on: .fileBecameWritable,
            context: context(readOnly: .unsupportedFormat)
        )
        #expect(workbook.state == .readOnly)
        #expect(workbook.wasIgnored)
    }

    /// `UNREADABLE` is recoverable: the file changing means it may have been fixed, and ⌘R
    /// retries. No snapshot, though — there is nothing worth preserving about a file we cannot
    /// read.
    @Test func unreadableRetriesButDoesNotSnapshot() {
        let retry = DocumentSyncState.unreadable.transition(on: .reloadRequested, context: context())
        #expect(retry.state == .reloading)
        #expect(retry.effects.contains(.beginReload))
        #expect(!retry.effects.contains(.captureSnapshot(.preRefresh)))

        #expect(DocumentSyncState.unreadable.transition(on: .reloadSucceeded, context: context()).state == .synced)
        #expect(DocumentSyncState.unreadable.transition(on: .fileVanished, context: context()).state == .missing)
    }

    /// A reload that fails lands in the state the *error* implies, not a generic one.
    @Test func reloadFailureRoutesByError() {
        let cases: [(SheetError, DocumentSyncState)] = [
            (.fileVanished(path: "/tmp/b"), .missing),
            (.fileNotFound(path: "/tmp/b"), .missing),
            (.fileLocked(path: "/tmp/b"), .locked),
            (.xmlMalformed(part: "sheet1.xml", line: 3, detail: "bad"), .unreadable),
            (.workbookEncrypted, .unreadable),
        ]
        for (error, expected) in cases {
            let transition = DocumentSyncState.reloading.transition(on: .reloadFailed(error), context: context())
            #expect(transition.state == expected, "reloadFailed(\(error.code)) went to \(transition.state)")
            #expect(transition.effects.contains(.report(error)))
        }
    }

    // MARK: - Totality

    /// **Every state/event pair has an answer and none of them traps.** 9 states × 19 events.
    @Test func theTableIsTotal() {
        var pairs = 0
        for state in DocumentSyncState.allCases {
            for event in SyncStateMachineTests.allEvents {
                for dirty in [false, true] {
                    for autoRefresh in [false, true] {
                        let transition = state.transition(
                            on: event,
                            context: context(autoRefresh: autoRefresh, dirty: dirty)
                        )
                        #expect(DocumentSyncState.allCases.contains(transition.state))
                        if transition.wasIgnored {
                            #expect(transition.state == state, "an ignored \(state) + \(event) still moved")
                            #expect(transition.effects.isEmpty)
                        }
                        pairs += 1
                    }
                }
            }
        }
        #expect(pairs == DocumentSyncState.allCases.count * SyncStateMachineTests.allEvents.count * 4)
    }

    /// The illegal transitions, named one by one so a change to any of them is deliberate.
    @Test func illegalTransitionsAreIgnoredRatherThanTrapping() {
        let illegal: [(DocumentSyncState, SyncEvent)] = [
            (.synced, .saveRequested), // nothing to save; rewriting the file would churn the mtime
            (.synced, .saveSucceeded),
            (.synced, .reloadSucceeded),
            (.synced, .fileReappeared),
            (.synced, .conflictResolved(.keepMine)),
            (.stale, .saveRequested),
            (.stale, .reloadSucceeded),
            (.reloading, .saveRequested),
            (.reloading, .conflictResolved(.takeDisk)),
            (.dirty, .reloadSucceeded),
            (.dirty, .conflictResolved(.keepMine)),
            (.conflict, .reloadRequested), // ambiguous: it is takeDisk without confirmation
            (.conflict, .reloadSucceeded),
            (.missing, .saveSucceeded),
            (.missing, .fileLocked),
            (.locked, .fileLocked),
            (.locked, .conflictResolved(.compare)),
            (.readOnly, .fileBecameReadOnly),
            (.unreadable, .userEdited),
            (.unreadable, .saveRequested),
            (.unreadable, .fileLocked),
        ]
        for (state, event) in illegal {
            let transition = state.transition(on: event, context: context(dirty: true))
            #expect(transition.wasIgnored, "\(state) + \(event) was expected to be a no-op")
            #expect(transition.state == state)
        }
    }

    // MARK: - The machine wrapper

    /// `hasUnsavedEdits` is maintained in exactly one place, and it is the flag that decides
    /// whether a reappearing file is a refresh or a conflict.
    @Test func machineTracksUnsavedEdits() {
        var machine = DocumentSyncMachine(state: .synced, context: context())
        #expect(!machine.context.hasUnsavedEdits)

        machine.handle(.userEdited)
        #expect(machine.state == .dirty)
        #expect(machine.context.hasUnsavedEdits)

        machine.handle(.saveRequested)
        machine.handle(.saveSucceeded)
        #expect(machine.state == .synced)
        #expect(!machine.context.hasUnsavedEdits)
    }

    /// `takeDisk` clears the flag *before* the reload, so a reload failure does not leave the
    /// document claiming edits it no longer has.
    @Test func takeDiskClearsEditsBeforeTheReload() {
        var machine = DocumentSyncMachine(state: .synced, context: context())
        machine.handle(.userEdited)
        machine.handle(.externalChangeDetected)
        #expect(machine.state == .conflict)

        machine.handle(.conflictResolved(.takeDisk))
        #expect(machine.state == .reloading)
        #expect(!machine.context.hasUnsavedEdits)

        machine.handle(.reloadFailed(.xmlMalformed(part: "s", line: 1, detail: "x")))
        #expect(machine.state == .unreadable)
        #expect(!machine.context.hasUnsavedEdits)
    }

    /// The probe-to-event translation, which is the only place filesystem facts become events.
    @Test func machineTranslatesProbesIntoEvents() throws {
        let scratch = TemporaryDirectory("machine-probe")
        let file = scratch.file("book.xlsx")
        var machine = DocumentSyncMachine(state: .synced, context: context())

        let writable = try #require(FileProbe.probe(file).probe)
        #expect(machine.apply(FileCondition.readable(writable)) == nil)

        var locked = writable
        locked.isImmutable = true
        #expect(machine.apply(FileCondition.readable(locked))?.state == .locked)

        #expect(machine.apply(FileCondition.missing)?.state == .missing)
        #expect(machine.apply(FileCondition.missing) == nil, "a second vanish is not a new event")
    }

    /// History is bounded. A document open for a week must not accumulate a transition log.
    @Test func historyIsBounded() {
        var machine = DocumentSyncMachine(state: .synced, context: context())
        for _ in 0 ..< (DocumentSyncMachine.historyLimit * 3) { machine.handle(.userEdited) }
        #expect(machine.history.count == DocumentSyncMachine.historyLimit)
    }
}
