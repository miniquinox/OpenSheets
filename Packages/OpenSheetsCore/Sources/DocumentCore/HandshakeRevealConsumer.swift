import Foundation
import SheetMCP
import SheetModel

/// A `reveal_range` request, as it was found on disk.
///
/// The fields are exactly what ``SheetMCP/AppHandshake/requestReveal(url:sheet:range:)`` writes.
/// `sheet` and `range` are optional here although the writer always includes them, because an
/// empty string is not a sheet and treating it as one would set the document to no sheet at all.
public struct HandshakeRevealRequest: Sendable, Hashable {
    /// The file the agent named. **Untrusted** — it arrives from whatever wrote the file, and is
    /// grant-checked before anything acts on it.
    public var url: URL
    public var sheet: String?
    public var range: String?
    public var requestedAt: Date

    public init(url: URL, sheet: String? = nil, range: String? = nil, requestedAt: Date) {
        self.url = url
        self.sheet = sheet
        self.range = range
        self.requestedAt = requestedAt
    }
}

/// The four things the consumer cannot do for itself: check a grant, find a tab, front a tab, and
/// open a file.
///
/// Closures rather than a reference to the workspace, so the whole of ``HandshakeRevealConsumer``
/// runs in a test against a temporary directory with no app, no window and no tab strip — which is
/// the only way the interesting cases (a stale request, an ungranted path, malformed JSON) get
/// asserted at all.
@MainActor
public struct HandshakeRevealActions {
    /// Re-checked at consumption time, not at write time. The request file may have been written
    /// before the user revoked the folder, and a request is only ever a suggestion.
    public var isGranted: @MainActor (URL) -> Bool
    /// Whether the file is already a tab, in any phase.
    public var hasOpenTab: @MainActor (URL) -> Bool
    /// Bring that tab to the front.
    public var activate: @MainActor (URL) -> Void
    /// Open the file. This must be the app's single open funnel, so a file arriving this way gets
    /// the same consent, recents and dedupe treatment as one the user double-clicked.
    public var openFile: @MainActor (URL) -> Void
    /// Select and scroll to the range, once there is a document to do it to.
    public var reveal: @MainActor (HandshakeRevealRequest) async -> Void

    public init(
        isGranted: @escaping @MainActor (URL) -> Bool,
        hasOpenTab: @escaping @MainActor (URL) -> Bool,
        activate: @escaping @MainActor (URL) -> Void,
        openFile: @escaping @MainActor (URL) -> Void,
        reveal: @escaping @MainActor (HandshakeRevealRequest) async -> Void
    ) {
        self.isGranted = isGranted
        self.hasOpenTab = hasOpenTab
        self.activate = activate
        self.openFile = openFile
        self.reveal = reveal
    }
}

/// Reads the `*.request.json` files `reveal_range` leaves behind and acts on them.
///
/// # A request is a suggestion
///
/// ``SheetMCP/AppHandshake`` says it in its own documentation and this is the end that has to mean
/// it. The file is written by whatever is on the other end of the MCP stream — an agent, and one
/// the threat model assumes is hostile. So every request is re-checked against the live grants
/// here, at the moment of acting, rather than trusted because the server wrote it: the user may
/// have revoked the folder in the seconds since. A path that fails is deleted and nothing happens.
///
/// # Why the directory is swept before it is watched
///
/// A `DispatchSource` fires for changes made while it exists. Requests written before launch — the
/// app was closed, the agent asked anyway — would sit in the directory forever, and the directory
/// would grow. So ``start()`` sweeps first and arms second.
///
/// The sweep applies the same ninety-second staleness cut as the read side. Without it, launching
/// the app would replay every reveal an agent had ever asked for, scrolling the user through a
/// history of somebody else's afternoon.
///
/// # Every path deletes the file
///
/// Handled, stale, ungranted, malformed: all four delete. A request that is left behind because it
/// could not be honoured is a request that gets reconsidered on every subsequent event, forever,
/// and a directory in application support that only grows.
@MainActor
public final class HandshakeRevealConsumer {
    /// `<applicationSupport>/Handshake`, the same directory ``SheetMCP/AppHandshake`` writes into.
    public let directory: URL

    private let actions: HandshakeRevealActions
    private let now: @Sendable () -> Date
    private let tolerance: TimeInterval

    private var source: (any DispatchSourceFileSystemObject)?
    private var isRunning = false
    /// Requests are handled one at a time. Two events landing while one request is opening a file
    /// must not both start an open of it — ``HandshakeRevealActions/openFile`` dedupes, but the
    /// second pass would also see the request file the first is about to delete.
    private var isProcessing = false
    private var needsAnotherPass = false

    /// - Parameters:
    ///   - directory: the handshake directory. Injected rather than derived so a test can point at
    ///     a temporary one.
    ///   - tolerance: how old a request may be. The same ninety seconds
    ///     ``SheetMCP/AppPresence/isFresh(now:tolerance:)`` uses, because the two halves are
    ///     answering the same question — *is this still about now?*
    public init(
        directory: URL,
        actions: HandshakeRevealActions,
        now: @escaping @Sendable () -> Date = { Date() },
        tolerance: TimeInterval = 90
    ) {
        self.directory = directory
        self.actions = actions
        self.now = now
        self.tolerance = tolerance
    }

    deinit {
        source?.cancel()
    }

    // MARK: - Lifecycle

    /// Sweeps whatever is already there, then watches for more.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { @MainActor [weak self] in
            await self?.processPending()
            self?.arm()
        }
    }

    public func stop() {
        isRunning = false
        source?.cancel()
        source = nil
    }

    /// One pass over the directory. Public because it is the whole of the behaviour worth
    /// asserting, and a test that had to wait for a file system event to fire would be a test that
    /// fails on a busy machine rather than on a bug.
    public func processPending() async {
        guard !isProcessing else {
            needsAnotherPass = true
            return
        }
        isProcessing = true
        defer { isProcessing = false }

        repeat {
            needsAnotherPass = false
            for file in requestFiles() {
                await consume(file)
            }
        } while needsAnotherPass
    }

    // MARK: - The watch

    /// One descriptor on one directory.
    ///
    /// The shape is ``SheetStore/FileWatcher``'s — `O_EVTONLY` plus a
    /// `DispatchSource.makeFileSystemObjectSource` — deliberately without the rest of that class.
    /// `FileWatcher` re-arms across atomic replaces and polls as a backstop because it is watching
    /// *a file a user is editing*. This watches one directory that only this app and one server
    /// ever write to, a handful of times a session; per-file watches and an FSEvents stream would
    /// be machinery for churn that does not exist.
    private func arm() {
        guard isRunning, source == nil else { return }
        // Created rather than assumed: `requestReveal` makes the directory when it first writes,
        // so on a machine that has never run the server there is nothing to open a descriptor on
        // and the watch would silently never exist.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watch = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .link, .rename, .delete, .revoke],
            queue: .main
        )
        watch.setEventHandler { [weak self] in
            // The handler runs off the actor even on the main queue, as far as the compiler is
            // concerned. Hopping is what makes every field this touches main-actor-isolated.
            Task { @MainActor in await self?.processPending() }
        }
        watch.setCancelHandler { _ = close(descriptor) }
        source = watch
        watch.resume()
    }

    // MARK: - Consuming

    private func requestFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
            ?? []
        // Sorted so a directory with several pending requests is handled in a defined order rather
        // than in whatever order the file system enumerated it.
        return names.filter { $0.hasSuffix(".request.json") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private func consume(_ file: URL) async {
        // Deleted first, unconditionally: whatever happens next, this request has been taken. A
        // delete after the work would leave the file behind for any path that throws or returns
        // early, and one that is left behind is retried on every event for the rest of the session.
        let parsed = Self.parse(contentsOf: file)
        try? FileManager.default.removeItem(at: file)

        guard let request = parsed else { return }
        guard now().timeIntervalSince(request.requestedAt) < tolerance else { return }
        guard actions.isGranted(request.url) else { return }

        if actions.hasOpenTab(request.url) {
            actions.activate(request.url)
        } else {
            actions.openFile(request.url)
        }
        await actions.reveal(request)
    }

    /// Parses one request file, or `nil` when it is not one.
    ///
    /// Read through ``SheetMCP/JSONValue`` rather than `JSONDecoder` for one reason:
    /// ``SheetMCP/AppHandshake/requestReveal(url:sheet:range:)`` *writes* through `JSONValue`, and
    /// a reader that shares the writer's parser cannot disagree with it about numbers, escapes or
    /// what an absent key means. `HandshakeRevealConsumerTests` closes the loop by having the real
    /// writer produce the bytes this reads.
    static func parse(contentsOf file: URL) -> HandshakeRevealRequest? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONValue.parse(data),
              let path = json["path"]?.stringValue,
              path.hasPrefix("/"),
              let requestedAt = json["requestedAt"]?.doubleValue
        else { return nil }
        func text(_ key: String) -> String? {
            guard let value = json[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        return HandshakeRevealRequest(
            url: URL(fileURLWithPath: path),
            sheet: text("sheet"),
            range: text("range"),
            requestedAt: Date(timeIntervalSince1970: requestedAt)
        )
    }
}

/// Putting a reveal request onto a document that is ready to receive it.
///
/// Separate from ``HandshakeRevealConsumer`` because it is the only part that needs a real
/// ``DocumentModel``, and keeping it out of the consumer is what lets the consumer's rules — stale,
/// ungranted, malformed — be asserted without one.
@MainActor
public enum HandshakeReveal {
    /// Selects `request`'s range and scrolls it into view. Returns whether anything moved.
    ///
    /// This is the command palette's go-to-cell, exactly: set the sheet, `selection.select`, then
    /// `grid.scroll(to:)`. Reusing it rather than writing a second selection path is the point —
    /// a reveal that selected differently from ⌘F would be a second definition of "go here" to
    /// keep in step, and the two would drift the first time either was touched.
    ///
    /// The order is load-bearing. ``DocumentModel/activeSheetID``'s `didSet` clears the selection,
    /// so a sheet set *after* the selection would leave the document on the right sheet with
    /// nothing selected — which looks exactly like the request having been ignored.
    @discardableResult
    public static func apply(_ request: HandshakeRevealRequest, to document: DocumentModel) -> Bool {
        var moved = false
        if let name = request.sheet, let sheet = document.workbook.sheet(named: name) {
            document.activeSheetID = sheet.id
            moved = true
        }
        guard let text = request.range, let range = CellRange(a1: text) else { return moved }
        document.selection.select(range, active: range.start)
        document.grid.scroll(to: range.start)
        return true
    }
}
