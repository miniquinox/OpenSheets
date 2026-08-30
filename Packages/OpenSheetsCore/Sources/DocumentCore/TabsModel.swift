import Foundation
import Observation
import SheetModel
import SheetStore

/// The workspace's open tabs — one per file, in the order the user put them in.
///
/// # Why tabs cost the model layer nothing
///
/// A tab holds a ``DocumentModel`` exactly as a window used to. Nothing about the document, its
/// session, its watcher or its sync machine changes because it is now behind a tab rather than
/// behind a window: ``AppModel`` already guarantees **one model per file whatever the timing**
/// (`AppModel.openDocument(at:consent:)`), so a background tab keeps watching its file, keeps
/// auto-refreshing, and keeps its own undo stack. The only thing that moved is who owns the
/// lifetime — the window's `onDisappear` used to close the document, and now this does.
///
/// # Why the lifecycle arrives as three closures
///
/// Opening a document needs an ``AppModel``, which needs a database on disk; closing one needs the
/// same instance; persisting the tab set needs the app's preference store. A `TabsModel` that
/// reached for any of those could only be tested by standing up the whole app, and the interesting
/// cases here are the ones that have nothing to do with files: what a second open of the same path
/// does to the list, which tab is active after a close, and whether the tab set that gets written
/// down matches the tabs on screen. So the three effects are injected and the rules are testable
/// on their own — see `DocumentCoreTests.TabsModelTests`, which never opens a file.
///
/// # One workspace, one tab per file
///
/// Identity is ``AppModel/documentKey(for:)`` — the same question the model layer asks — so two
/// spellings of one path are one tab, and opening a file that is already open activates it rather
/// than growing the list. That has to hold *while a tab is still loading* too: `AppModel` coalesces
/// overlapping opens of one path into a single task, so calling the injected `open` twice is safe,
/// but the second caller must not leave a second tab behind. See ``open(_:consent:)``.
///
/// Explicitly out of scope for v1: dragging a tab out into its own window, and more than one
/// workspace window. Both are a `TabsModel` per window, which is already the shape this has — they
/// are deferred because the window plumbing, not this file, is where the cost is.
@MainActor
@Observable
public final class TabsModel {
    /// One open file.
    public struct Tab: Identifiable {
        /// `AppModel.documentKey(for: url)` — the same identity the model layer uses.
        public let id: String
        public let url: URL
        public var phase: Phase
    }

    /// What a tab has to show. A failed open is a state of the tab, not an alert: the user asked
    /// for this file, so the answer belongs where they asked, and the tab stays closable.
    public enum Phase {
        case loading
        case ready(DocumentModel)
        case failed(SheetError)
    }

    /// The tabs, left to right. `private(set)` because every membership change also has to be
    /// written down — see ``persisted``.
    public private(set) var tabs: [Tab] = []

    /// Which tab is frontmost. Settable, but ``activate(_:)`` is the call that also persists.
    public var activeTabID: String?

    /// The active tab's document, or `nil` when the active tab is still loading, has failed, or
    /// there is no active tab. This is what the window binds its grid, its commands and its
    /// focused-scene value to.
    public var activeDocument: DocumentModel? {
        guard let activeTabID, let tab = tabs.first(where: { $0.id == activeTabID }) else { return nil }
        guard case let .ready(model) = tab.phase else { return nil }
        return model
    }

    public var isEmpty: Bool { tabs.isEmpty }

    /// The tab set as it goes into the `workspace.tabs` preference (§1.7) — see
    /// ``SheetStore/PersistedOpenTabs``, which owns the fields.
    ///
    /// The payload lives in `SheetStore` so `SheetMCP` can read the same row and tell an agent
    /// which files are open in the app; `SheetMCP` cannot import `DocumentCore`. The nested name
    /// stays because every call site — including `App/OpenSheetsApp.swift`, which this task must
    /// not edit — spells it `TabsModel.PersistedTabs`, and a typealias keeps that a fact about
    /// one type rather than a second declaration of it.
    public typealias PersistedTabs = PersistedOpenTabs

    @ObservationIgnored
    private let openDocument: @MainActor (URL, WorkspaceConsent) async throws(SheetError) -> DocumentModel
    @ObservationIgnored
    private let closeDocument: @MainActor (DocumentModel) -> Void
    @ObservationIgnored
    private let persistTabs: @MainActor (PersistedTabs) -> Void

    /// - Parameters:
    ///   - open: `AppModel.openDocument(at:consent:)`. It is the *only* way a tab comes into
    ///     existence, which is what keeps the workspace-grant check on the single path §1.6
    ///     describes — nothing here may widen a grant, because nothing here can mint one.
    ///   - close: `AppModel.closeDocument(_:)`. Called for every tab that reaches `.ready`,
    ///     including one whose document arrives after its tab has already been closed.
    ///   - persist: receives the paths and the active index to store, on every change to either.
    ///
    /// # Write `open`'s signature out in full
    ///
    /// Measured on Swift 6.3.3, because it reads like a contract error and is not one:
    ///
    /// ```swift
    /// // error: invalid conversion of thrown error type 'any Error' to 'SheetError'
    /// TabsModel(open: { try await app.openDocument(at: $0, consent: $1) }, …)
    /// ```
    ///
    /// A closure literal's *thrown* type is not inferred from the parameter it is being passed to,
    /// so the body comes out `throws(any Error)` and the conversion is then refused. Spelling the
    /// signature fixes it, and is the form to copy:
    ///
    /// ```swift
    /// TabsModel(
    ///     open: { (url: URL, consent: WorkspaceConsent) async throws(SheetError) -> DocumentModel in
    ///         try await app.openDocument(at: url, consent: consent)
    ///     },
    ///     …
    /// )
    /// ```
    ///
    /// The typed throw earns that: `AppModel.openDocument(at:consent:)` throws exactly `SheetError`,
    /// and a tab's `.failed` phase carries exactly `SheetError` — widening the hook to `any Error`
    /// would put an un-presentable error in a place whose only job is to present one.
    public init(
        open: @escaping @MainActor (URL, WorkspaceConsent) async throws(SheetError) -> DocumentModel,
        close: @escaping @MainActor (DocumentModel) -> Void,
        persist: @escaping @MainActor (PersistedTabs) -> Void
    ) {
        openDocument = open
        closeDocument = close
        persistTabs = persist
    }

    // MARK: - Opening

    /// Opens `url` as a tab, or activates the tab that already has it.
    ///
    /// The tab appears **immediately**, in `.loading`, and the document lands in its phase when it
    /// arrives. Nothing about an open is presented as an alert: a file that will not open shows the
    /// reason inside its own tab, which is where the user was looking.
    ///
    /// The re-entrant case is the one worth stating, because it is the shape that used to produce
    /// five windows on one file: a second `open` for a path that is *still loading* activates the
    /// loading tab and returns. `AppModel` coalesces the underlying work, so the second caller
    /// would have got the same model anyway — but the list must not grow while it waits.
    public func open(_ url: URL, consent: WorkspaceConsent) async {
        let id = AppModel.documentKey(for: url)
        if tabs.contains(where: { $0.id == id }) {
            activate(id)
            return
        }

        // After the active tab, not at the end: a file opened from the one in front of you belongs
        // next to it, which is where every other tabbed editor puts it.
        let insertion = activeIndex.map { $0 + 1 } ?? tabs.count
        tabs.insert(Tab(id: id, url: url, phase: .loading), at: insertion)
        activeTabID = id
        persist()

        let phase: Phase
        do {
            phase = .ready(try await openDocument(url, consent))
        } catch {
            phase = .failed(error)
        }

        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            // Closed while it was loading — a double-⌘W, or a user who changed their mind during a
            // slow read. Nobody is holding this document now, so it has to be let go here or its
            // session keeps a watcher and a file descriptor open for as long as the app runs.
            if case let .ready(model) = phase { closeDocument(model) }
            return
        }
        tabs[index].phase = phase
        // No `persist()`: a phase is not membership. The stored value would be identical, and a
        // write per load turns "how many times did the tab set change" into an unanswerable
        // question for the tests that count them.
    }

    /// Reopens a stored tab set, in order, with ``WorkspaceConsent/fromOutsideTheApp`` consent.
    ///
    /// Sequentially rather than in a task group: the tab strip's order is the user's order, and a
    /// group would hand it back in whatever order the disk felt like. Every open is independent —
    /// a path that has been deleted, or whose folder's grant was revoked between sessions, lands in
    /// its own tab's `.failed` phase (§1.6) and the rest still open.
    ///
    /// Additive, and it dedupes exactly like ``open(_:consent:)``, so restoring into a workspace
    /// that already has tabs is harmless rather than doubling anything.
    public func restore(_ persisted: PersistedTabs) async {
        for path in persisted.paths {
            // §1.8: a relative path in a stored preference is not a file we can reason about — it
            // would resolve against whatever the process's working directory happens to be. Skipped
            // silently, because the user never typed it.
            guard path.hasPrefix("/") else { continue }
            await open(URL(fileURLWithPath: path), consent: .fromOutsideTheApp)
        }
        // Clamped rather than trusted: the stored index was written against a tab set that may have
        // lost entries to the check above. A missing index leaves the last-opened tab in front,
        // which is the same answer a fresh set of opens gives.
        if let index = persisted.activeIndex, !tabs.isEmpty {
            activate(index: min(max(index, 0), tabs.count - 1))
        }
    }

    // MARK: - Closing

    /// Closes the tab, releases its document, and activates the neighbour on the right, else the
    /// one on the left, else nothing.
    ///
    /// An id that is not in ``tabs`` is a no-op rather than a precondition failure: two ⌘Ws in the
    /// same run-loop turn both name the tab that was active when the key went down.
    ///
    /// This does **not** ask about unsaved edits. The confirmation is a panel, panels belong to the
    /// app layer, and a model that could put one on screen could not be tested without one.
    public func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if case let .ready(model) = tab.phase { closeDocument(model) }

        if activeTabID == id {
            // `index` now names the right-hand neighbour, because the removal shifted it into
            // place. Falling left keeps the eye where it was when the closed tab was the last one.
            if index < tabs.count {
                activeTabID = tabs[index].id
            } else {
                activeTabID = tabs.last?.id
            }
        }
        persist()
    }

    // MARK: - Activation

    public func activate(_ id: String) {
        guard activeTabID != id, tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        persist()
    }

    /// ⇧⌘] — the tab to the right, wrapping round at the end.
    ///
    /// Wrapping because the alternative is a shortcut that stops working when you reach the edge,
    /// and every tabbed application the user already has wraps.
    public func activateNext() {
        guard !tabs.isEmpty else { return }
        guard let index = activeIndex else {
            activate(index: 0)
            return
        }
        activate(index: (index + 1) % tabs.count)
    }

    /// ⇧⌘[ — the tab to the left, wrapping round at the start.
    public func activatePrevious() {
        guard !tabs.isEmpty else { return }
        guard let index = activeIndex else {
            activate(index: tabs.count - 1)
            return
        }
        activate(index: (index + tabs.count - 1) % tabs.count)
    }

    /// 0-based; out of range is ignored. ⌘1…⌘9 land here, and ⌘7 with four tabs open should do
    /// nothing rather than something.
    /// Move the tab at `from` so that it lands at `to`, the way dragging a browser tab does.
    ///
    /// `to` is the index of the tab being dropped **onto**, in the list as it looks before the
    /// move — which is what the view can see. Dragging right therefore lands *after* the tab you
    /// dropped on and dragging left lands *before* it, because removing the dragged tab first
    /// shifts everything to its right down by one. That asymmetry is not a bug to correct: it is
    /// what makes the tab end up under the pointer in both directions.
    ///
    /// Order is window state, not file content. Nothing here touches a workbook, so unlike sheet
    /// reordering it needs nothing from the writer and is not behind a flag.
    public func move(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: to)
        // The active tab is identified by id, so it does not move with the indices — but the
        // stored `activeIndex` does, which is why this persists rather than only reordering.
        persist()
    }

    public func activate(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index].id)
    }

    // MARK: - Persistence

    /// What ``restore(_:)`` would need to rebuild this workspace.
    public var persisted: PersistedTabs {
        PersistedTabs(
            paths: tabs.map { $0.url.path(percentEncoded: false) },
            activeIndex: activeIndex
        )
    }

    private var activeIndex: Int? {
        guard let activeTabID else { return nil }
        return tabs.firstIndex { $0.id == activeTabID }
    }

    private func persist() { persistTabs(persisted) }
}
