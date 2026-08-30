import CryptoKit
import Foundation
import Observation
import SheetMCP
import SheetModel

/// One open document, reduced to the four strings the handshake carries about it.
///
/// A value rather than a reference on purpose: the publisher's job is to take a reading and write
/// it down, and holding a ``DocumentModel`` between readings would make the write depend on when
/// it ran rather than on when the reading was taken.
public struct HandshakeDocumentSnapshot: Sendable, Hashable {
    /// The file, as the app opened it. Canonicalised on the way into ``AppPresence``.
    public var url: URL
    /// The sheet the user is looking at.
    public var sheetName: String
    /// The selection, spelled the way the app spells it on the selection pill — `B2:B41`,
    /// `41R × 3C` for a block, `3 ranges · 90 cells` for a multi-selection.
    ///
    /// The app's own words rather than a re-derived A1 string, because `get_selection` exists to
    /// answer *"what is the user looking at"* and the honest answer to that is the one on their
    /// screen. ``activeCell`` is always a plain A1 reference, so an agent that needs something it
    /// can feed back into `read_range` has one.
    public var selection: String
    /// The active cell, in A1.
    public var activeCell: String

    public init(url: URL, sheetName: String, selection: String, activeCell: String) {
        self.url = url
        self.sheetName = sheetName
        self.selection = selection
        self.activeCell = activeCell
    }

    /// The reading for a live document.
    ///
    /// Reading ``DocumentModel/selection`` and ``DocumentModel/activeSheetID`` here is what makes
    /// ``HandshakePublisher``'s observation work: the properties are touched inside the tracked
    /// closure, so moving the selection is what tells the publisher to publish. That is the whole
    /// reason the mapping lives in a function rather than being inlined at each call site.
    @MainActor
    public init(document: DocumentModel) {
        self.init(
            url: document.url,
            sheetName: document.activeSheet?.name ?? "",
            selection: document.selectionStats.rangeLabel,
            activeCell: document.selection.active.a1String
        )
    }

    /// The reading for a tab, or `nil` when the tab has no document to read.
    ///
    /// **`.loading` and `.failed` publish nothing**, and this optional is where that rule lives.
    /// A presence record for a tab that is still parsing would tell an agent the app is sitting on
    /// a selection in a file it cannot yet show, and a record for a tab that failed to open would
    /// claim the app has a file open that it demonstrably does not.
    @MainActor
    public init?(tab: TabsModel.Tab) {
        guard case let .ready(document) = tab.phase else { return nil }
        self.init(document: document)
    }
}

/// Writes what the app has open into the handshake directory, so `get_selection` has something
/// true to report.
///
/// # Why this exists at all
///
/// ``SheetMCP/AppHandshake/publish(_:)`` has been public and documented as *"the app calls this"*
/// since the server shipped, and nothing called it. The consequence was not a crash: it was
/// `get_selection` answering *"the OpenSheets app is not open on this file"* while the app sat on
/// screen with the file open. Every half of the protocol worked; the sentence connecting them was
/// missing.
///
/// # Cadence, and why it is three mechanisms rather than one
///
/// ``AppPresence/isFresh(now:tolerance:)`` believes a record for ninety seconds. That number sets
/// the whole design:
///
/// - **Observation** (``armObservation()``) catches the change that matters — the user moving the
///   selection or switching sheet — and is debounced, because dragging across a hundred cells
///   would otherwise be a hundred atomic writes into application support for one gesture.
/// - **A 30 s repeating refresh** keeps a record inside the ninety-second window while the app
///   sits idle. Without it, a user who opens a file and then reads it for two minutes becomes
///   invisible to the server, which is the exact case `get_selection` was built for.
/// - **Explicit withdrawal** on close, because a file the user shut is not a file they are looking
///   at, and letting the record age out would leave ninety seconds in which the server would
///   confidently report a selection in a closed document.
///
/// Presence is published for **every** ready tab rather than only the active one. The protocol has
/// no notion of which document is in front — it is keyed by path — so activating a different tab
/// changes nothing any record says, and there is deliberately no activation hook to forget to call.
@MainActor
public final class HandshakePublisher {
    /// Where the readings come from. Injected so a test can publish a known selection without a
    /// window, a workbook or a file on disk.
    public typealias Source = @MainActor () -> [HandshakeDocumentSnapshot]

    private let handshake: AppHandshake
    private let documents: Source
    private let processID: Int
    private let now: @Sendable () -> Date
    private let refreshInterval: Duration
    private let debounce: Duration

    private var isRunning = false
    private var refreshTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    /// - Parameters:
    ///   - handshake: the same type the server reads through, so there is one definition of the
    ///     file format rather than two that agree until they do not.
    ///   - documents: the ready documents to publish for.
    ///   - processID: `getpid()` in the app. A parameter because ``AppPresence/isFresh(now:tolerance:)``
    ///     calls `kill(pid, 0)`, and a test that wants a record judged *stale* needs to be able to
    ///     name a process that is not there.
    ///   - refreshInterval: how often to republish while nothing changes. A third of the ninety
    ///     second tolerance, so two consecutive misses still leave the record believed.
    ///   - debounce: how long a burst of selection changes coalesces for.
    public init(
        handshake: AppHandshake,
        documents: @escaping Source,
        processID: Int = Int(getpid()),
        now: @escaping @Sendable () -> Date = { Date() },
        refreshInterval: Duration = .seconds(30),
        debounce: Duration = .seconds(1)
    ) {
        self.handshake = handshake
        self.documents = documents
        self.processID = processID
        self.now = now
        self.refreshInterval = refreshInterval
        self.debounce = debounce
    }

    deinit {
        refreshTask?.cancel()
        debounceTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Publishes once immediately, then keeps publishing.
    ///
    /// Immediately rather than after the first interval: the app is at its most interesting to an
    /// agent in the seconds after a file opens, and a thirty-second window in which `get_selection`
    /// says "not open" about a file that plainly is would read as the feature not working.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        publishNow()
        refreshTask = Task { @MainActor [weak self, refreshInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refreshInterval)
                guard !Task.isCancelled, let self, isRunning else { return }
                publishNow()
            }
        }
    }

    /// Stops publishing and takes down every record this publisher wrote.
    ///
    /// Withdrawing rather than letting the records age out, for the reason ``withdraw(_:)`` gives:
    /// ninety seconds of confidently wrong answers is worse than one file delete.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        withdrawAll()
    }

    // MARK: - Publishing

    /// Takes a reading, writes it down, and re-arms the observation. Returns how many records
    /// were written, which is what the tests count.
    @discardableResult
    public func publishNow() -> Int {
        var written = 0
        armObservation {
            written = documents().reduce(into: 0) { total, snapshot in
                total += publish(snapshot) ? 1 : 0
            }
        }
        return written
    }

    /// A change has happened; publish once the burst settles.
    ///
    /// Public because the app may know about a change the observation cannot see, and cheap to
    /// call more than once — a second call inside the debounce window replaces the first.
    public func publishSoon() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self, isRunning else { return }
            debounceTask = nil
            publishNow()
        }
    }

    /// Removes the record for a document that is no longer open.
    ///
    /// Best effort, and silent when there is nothing there: the record may never have been written
    /// (a tab closed while it was still loading), and a document being closed is not a moment to
    /// raise an error about application support.
    public func withdraw(_ url: URL) {
        try? FileManager.default.removeItem(at: presenceFile(for: url))
    }

    /// Withdraws every record this publisher can currently see a document for.
    ///
    /// Called from ``stop()``, which the app runs when its workspace goes away. It cannot promise
    /// to catch a kill -9, which is exactly why ``AppPresence/isFresh(now:tolerance:)`` checks the
    /// pid as well as the age — this is the tidy exit, not the safety net.
    public func withdrawAll() {
        for snapshot in documents() { withdraw(snapshot.url) }
    }

    // MARK: - Machinery

    /// Writes one presence record. `false` when it could not be written.
    ///
    /// # Why this renders the payload instead of calling `AppHandshake.publish(_:)`
    ///
    /// It cannot call it. ``SheetMCP/AppHandshake/publish(_:)`` is `public` and documented as
    /// *"The app calls this"*, but its argument ``SheetMCP/AppPresence`` has no public
    /// initialiser — the memberwise one is `internal` — so no code outside `SheetMCP` can
    /// construct the value the method needs. The method has been uncallable since it shipped,
    /// which is a large part of why the app side of the handshake was never built.
    ///
    /// Fixing that belongs to whoever owns `SheetMCP`; the protocol is frozen for this change. So
    /// the bytes are rendered here, through the same ``SheetMCP/JSONValue`` the server uses, with
    /// the same six keys — and the duplication is not left to inspection.
    /// `HandshakePublisherTests.aPublishedRecordIsWhatTheServerReadsBack` asserts the real
    /// ``SheetMCP/AppHandshake/presence(for:)`` parses this file as fresh with every field intact,
    /// so a key renamed on either side fails a test rather than silently reporting nothing.
    private func publish(_ snapshot: HandshakeDocumentSnapshot) -> Bool {
        let payload = JSONValue.object([
            "path": .string(AppModel.documentKey(for: snapshot.url)),
            "sheet": .string(snapshot.sheetName),
            "selection": .string(snapshot.selection),
            "activeCell": .string(snapshot.activeCell),
            "pid": .integer(processID),
            "updatedAt": .number(now().timeIntervalSince1970),
        ])
        do {
            try FileManager.default.createDirectory(
                at: handshake.directory, withIntermediateDirectories: true
            )
            // Atomic, like the writer on the other side: the server may read this file at any
            // moment, and a half-written record would parse as no record at all.
            try Data(payload.rendered.utf8).write(to: presenceFile(for: snapshot.url), options: [.atomic])
            return true
        } catch {
            // Application support being unwritable is not something to interrupt a spreadsheet
            // over. The server's answer degrades to "the app is not open on this file", which is
            // what it said before any of this existed.
            return false
        }
    }

    /// Runs `body` inside an observation, so that touching any document's selection or sheet
    /// schedules the next publish.
    ///
    /// This is deliberately *not* a hook inside ``DocumentModel``'s `selection` didSet. That
    /// property is on the path of every arrow key in the application, and hanging an application
    /// support write off it — even a debounced one — would put a file system dependency in the
    /// middle of the app's hottest loop. Observation costs nothing until something changes.
    private func armObservation(_ body: () -> Void) {
        guard isRunning else {
            body()
            return
        }
        withObservationTracking(body) { [weak self] in
            // `onChange` fires *before* the value lands, on whatever thread mutated it, and only
            // once per arming — so hop to the main actor, then debounce, then re-arm inside the
            // next `publishNow()`.
            Task { @MainActor in self?.publishSoon() }
        }
    }

    /// The file the server will look for when asked about `url`.
    ///
    /// The name is the SHA-256 of the canonical path, which is `AppHandshake.key(_:)`'s rule —
    /// `internal` there, so it is spelled again here. Two reasons it is a hash and not the path,
    /// both worth keeping in view: a file called `../../etc/passwd` cannot escape the directory,
    /// and a three-hundred-character path cannot exceed `NAME_MAX`.
    ///
    /// The duplication is guarded rather than trusted:
    /// `HandshakePublisherTests.aPublishedRecordIsWhatTheServerReadsBack` publishes through this
    /// and reads through the real ``SheetMCP/AppHandshake/presence(for:)``, which finds nothing at
    /// all if the two derivations ever disagree by a byte.
    private func presenceFile(for url: URL) -> URL {
        let canonical = url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
        let key = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return handshake.directory.appendingPathComponent("\(key).json")
    }
}
