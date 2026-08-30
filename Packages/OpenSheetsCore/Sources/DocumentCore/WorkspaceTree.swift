import Foundation
import Observation
import SheetStore

/// The granted folders, as a lazily expanded tree of ``WorkspaceNode``s.
///
/// One of these per process, owned by ``AppModel``, so the launcher and a document window's
/// sidebar cannot disagree about which folders are open.
///
/// # Why every folder is listed one level at a time
///
/// The numbers this design is built around were measured on the machine that asked for it:
/// `~/Documents` holds **77,024 directories and 525,127 entries**, of which 1,592 are
/// spreadsheets. `~/Downloads` holds 3,109 entries in its top level alone. A tree that walked a
/// granted folder to find the interesting files would spend minutes and hundreds of megabytes to
/// answer a question the user has not asked yet.
///
/// So nothing here is eager. A folder is listed when its triangle is turned, never before,
/// through ``SheetStore/DirectoryListingSource`` — one directory, one level, already inside the
/// grant boundary. Granting `~` is therefore cheap, and stays cheap.
///
/// # What this deliberately does not do: watch the filesystem
///
/// Files that change on disk do **not** move the tree on their own. ``SheetStore/FileWatcher``
/// spends two file descriptors and a dispatch source per watched file — correct for the handful
/// of documents a window has open, and completely unaffordable pointed at 77,024 directories.
/// There is no cheap kernel API that says "something under here changed" without also saying
/// what, for everything, all the time.
///
/// The consequence is stated rather than hidden: a file created in Finder while the app is
/// running does not appear until something asks. ``refresh(_:)`` is that ask, and the hosts also
/// call it when their window becomes key. A tree that quietly went stale would be worse than one
/// that says it only knows what it last looked at.
///
/// # What it is allowed to know
///
/// Nothing about SwiftUI, and nothing about grants. It publishes ``nodes`` — a flat array in
/// display order — and the app layer maps that to the view's own row type, the same split as
/// `WorkspaceState.tabStrip(for:asOf:)`. The security boundary is one layer below: every path in
/// here was minted by the lister out of a directory the lister had already grant-checked, so
/// there is no path in this type that could be widened into one, and no API here that could
/// widen a grant if there were.
@MainActor
@Observable
public final class WorkspaceTree {
    /// Flattened, in display order, roots first. The view does no walking.
    ///
    /// Rebuilt wholesale on every change rather than spliced in place. At a few hundred visible
    /// rows the rebuild is invisible, and splicing would mean maintaining a second model of
    /// where each subtree starts and ends — a second model that could disagree with this one.
    public private(set) var nodes: [WorkspaceNode] = []

    /// The folders the user has deliberately opened, in the order they opened them. Shown first,
    /// each exempt from the nested-root rule.
    ///
    /// The nested-root rule in ``setRoots(_:)`` is right for grants and wrong for this. On the
    /// machine this was measured against it ate four folders in a row — `~/Documents/GitHub/`
    /// `ExamAi-new` granted three times and `ToF_bench` once, every one of them inside an
    /// already-granted `~/Documents` — so "open this folder" produced a row nowhere and looked
    /// like nothing had happened. A folder somebody just chose gets to jump the rule.
    ///
    /// **There is more than one of them because opening a folder adds a row rather than replacing
    /// one.** That is what the tab strip's `+` means by "Open Folder…", and it is the shape a
    /// multi-root workspace has everywhere else it exists. Grants stay the separate concept they
    /// already were: many folders may be readable, and only the ones somebody deliberately opened
    /// are on screen.
    ///
    /// A containing root stays on screen alongside them. That is honest rather than tidy: the
    /// grant really does cover both, and hiding the outer one to avoid showing the same directory
    /// twice would be the tree deciding which of the user's folders counts. Two *pinned* folders
    /// where one is inside the other get the same answer, for the stronger reason that both were
    /// asked for by name.
    ///
    /// Two invariants hold: these are a prefix of ``nodes`` in this order — each root immediately
    /// followed by its own expanded subtree, which is what lets the app layer scope the tree by
    /// taking a prefix — and some granted root covers every one of them. ``pin(_:)`` refuses paths
    /// that would break the second.
    public private(set) var pinnedRoots: [String] = []

    /// True from the moment a search is scheduled until its walk lands or is cancelled.
    public private(set) var isSearching = false

    /// Non-nil when a search stopped at its budget. Never swallowed.
    ///
    /// A search that gave up after 2,000 directories and said nothing would read as "there is no
    /// such file", which is the one answer it does not have.
    public private(set) var searchNote: String?

    /// Files matching ``search``, newest walk wins. Empty while the query is empty.
    public private(set) var searchResults: [WorkspaceNode] = []

    /// What the user has typed. Setting it schedules a debounced walk; clearing it cancels.
    ///
    /// The stored value is exactly what was typed — the trimming and the 128-character cap are
    /// applied to the *query*, not written back here. Rewriting a property from its own `didSet`
    /// is how a text field starts fighting the person using it.
    public var search = "" {
        didSet { scheduleSearch() }
    }

    @ObservationIgnored private let source: any DirectoryListingSource
    @ObservationIgnored private let fileExtensions: Set<String>
    @ObservationIgnored private let storage: (any WorkspaceTreeStorage)?

    /// The same object as ``storage`` when it can hold pins, `nil` when it cannot.
    ///
    /// A store that predates the pin is still a legal store; it remembers the expansion set and
    /// forgets the rest. See ``WorkspaceTreePinStorage``.
    @ObservationIgnored private let pinStorage: (any WorkspaceTreePinStorage)?

    /// Top-level rows in display order: the pinned folders first, in pin order, then whichever
    /// granted roots are not already among them.
    @ObservationIgnored private var roots: [String] = []

    /// The granted folders as ``setRoots(_:)`` last resolved them, before the pin is folded in.
    ///
    /// Split out from ``roots`` because "what a grant covers" and "what is on screen" stopped
    /// being the same list the moment a root could be pinned from inside another. This one is the
    /// authority on coverage — asking ``roots`` would let a pin vouch for itself.
    @ObservationIgnored private var grantedRoots: [String] = []

    /// Listed children, keyed by parent path. The `depth` on a cached node is meaningless; it is
    /// stamped during the flatten, where the node's actual place in the tree is known.
    @ObservationIgnored private var children: [String: [WorkspaceNode]] = [:]

    /// What we know about each path. Separate from ``children`` because `.unreadable` and
    /// `.loading` are states a path has *without* having children.
    @ObservationIgnored private var loads: [String: WorkspaceNode.Load] = [:]

    @ObservationIgnored private var expanded: Set<String> = []

    /// Listings started and not yet landed, mirroring `AppModel.opening`. A second turn of the
    /// same triangle collapses the row instead of starting a second read of the same directory.
    @ObservationIgnored private var inFlight: Set<String> = []

    /// Bumped whenever the shape of the tree changes underneath an in-flight listing. A listing
    /// that lands against a stale generation is answering a question nobody is asking.
    @ObservationIgnored private var generation = 0

    /// Expansion read from storage and not yet matched against a root, because at `init` there
    /// are no roots yet — ``AppModel`` builds the tree and then calls ``setRoots(_:)``.
    @ObservationIgnored private var pendingExpansion: [String] = []

    /// Last session's open folders, waiting for the first ``setRoots(_:)`` to say which of them a
    /// grant still covers. Consumed once, exactly like ``pendingExpansion``.
    ///
    /// Parked here rather than assigned straight to ``pinnedRoots`` so that "every pin is covered,
    /// and the pins are the first rows" is true at every instant rather than true once the first
    /// grant reload has been through.
    @ObservationIgnored private var pendingPins: [String] = []

    /// Folders ``expandNewRoot(_:)`` was asked to open before any root contained them.
    ///
    /// Separate from ``pendingExpansion``, which is last session's set and is consumed once. This
    /// one waits: a grant the launcher has just made is a root that is about to exist, and the
    /// request must survive until the ``setRoots(_:)`` that introduces it.
    @ObservationIgnored private var pendingReveals: Set<String> = []

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// Every listing and search this tree has started and not yet finished.
    ///
    /// Kept only so ``settled()`` can await exactly the work in flight. Production never reads
    /// it: the tree is already correct without it, because a landing listing rebuilds ``nodes``
    /// and SwiftUI redraws. Holding the handles costs one dictionary slot per open folder.
    @ObservationIgnored private var pendingWork: [Int: Task<Void, Never>] = [:]

    @ObservationIgnored private var nextWorkID = 0

    /// The normalised query the last scheduled walk was for. Guards against a `didSet` that a
    /// no-op assignment fired, which would otherwise restart the walk on every keystroke that
    /// changed nothing the search can see.
    @ObservationIgnored private var query = ""

    /// - Parameters:
    ///   - source: the only thing that touches the disk. A protocol so this type is testable
    ///     against a fake with no filesystem at all.
    ///   - fileExtensions: lowercase, without the dot. Directories are always listed; files that
    ///     do not match are not.
    ///   - storage: where the expansion set and ``pinnedRoots`` are remembered. `nil` means "do not
    ///     persist", which is what tests use; a store that conforms only to
    ///     ``WorkspaceTreeStorage`` keeps the expansion set and forgets the pins.
    public init(
        source: any DirectoryListingSource,
        fileExtensions: Set<String>,
        storage: (any WorkspaceTreeStorage)?
    ) {
        self.source = source
        self.fileExtensions = fileExtensions
        self.storage = storage
        let pins = storage as? any WorkspaceTreePinStorage
        pinStorage = pins
        let restored = pins?.treeState() ?? WorkspaceTreeState(expanded: storage?.expandedPaths() ?? [])
        pendingExpansion = restored.expanded
        pendingPins = restored.pinnedRoots
    }

    // MARK: - Roots

    /// Replaces the top-level rows. Called by `AppModel.reloadGrants()`.
    ///
    /// Idempotent, and cheaply so: this runs on every launch and after every grant change, and a
    /// call that changes nothing must not cancel a listing the user is watching a spinner for.
    ///
    /// **A root that is a descendant of another root is dropped.** `~/Documents` and
    /// `~/Documents/GitHub/OpenSheets/Demo` are both granted on the developer's machine right
    /// now; showing both as top-level rows would put the same folder on screen twice, with two
    /// independent expansion states for one directory. The nested one is still reachable — by
    /// expanding the outer one, which is where it actually lives.
    ///
    /// ``pinnedRoots`` are the exception, and each survives this call as long as one of the
    /// resolved roots still covers it. A grant that has been revoked underneath an open folder
    /// closes that folder, because the alternative is a top-level row for a directory the app may
    /// no longer read. The pins that are still covered keep their order.
    ///
    /// Containment is compared by path *components*, never by `hasPrefix`: `/Users/qui` is a
    /// prefix of `/Users/quino` and a parent of nothing.
    public func setRoots(_ paths: [String]) {
        let resolved = Self.topLevelRoots(paths)
        // Consumed here rather than at `init` for `pendingExpansion`'s reason: at `init` there
        // are no roots to check remembered pins against. Nothing can have pinned in between —
        // `pin(_:)` needs a covering grant, and there are none until this runs — so last session's
        // list wins outright rather than merging with one that is necessarily empty.
        let candidates = pendingPins.isEmpty ? pinnedRoots : pendingPins
        pendingPins = []
        let surviving = candidates.filter { Self.covers(resolved, $0) }
        let display = Self.display(roots: resolved, pinned: surviving)
        let restored = adoptPendingExpansion(under: display)
        guard display != roots || resolved != grantedRoots || surviving != pinnedRoots || restored
        else { return }
        invalidateInFlight()
        grantedRoots = resolved
        pinnedRoots = surviving
        roots = display
        pruneExpansion()
        applyPendingReveals()
        persist()
        settle()
    }

    /// Opens `url` as a workspace folder — appended to the pinned block, expanded, and kept even
    /// when it sits inside a folder that is already a root.
    ///
    /// **Appends rather than replaces.** Opening a second folder while the first is open leaves
    /// both on screen, which is what the `+` in the tab strip promises and what every other
    /// multi-root workspace does. Replacing would make "open" and "close" the same gesture, and
    /// there would be no way back to the folder that vanished except to find it on disk again.
    ///
    /// **A path no live grant covers is dropped, silently and without a throw.** The tree's whole
    /// security story is that every path in it was minted by the lister out of a directory the
    /// lister had already grant-checked; a pin is the one path that arrives from outside, so it
    /// is checked against ``setRoots(_:)``'s own roots before it is allowed to become a row.
    /// Silently, because there is no failure here to put on screen — the caller asked for a
    /// folder the app cannot read, and the answer is the same one an ungranted folder always
    /// gets.
    ///
    /// **Unlike ``expandNewRoot(_:)``, order matters: grant first, then pin.** That method
    /// remembers a folder that has not arrived yet, because a grant is on its way and the request
    /// has to survive the trip. This one has no such promise to keep — a pin that waited would be
    /// a pin for a folder nobody has granted, held indefinitely — so `AppModel` must have run
    /// `reloadGrants()` before it gets here. That is the order `grantWorkspace` already produces.
    ///
    /// Opening a folder that is already open neither duplicates it nor moves it: the row somebody
    /// is pointing at must not jump out from under them because a menu item was chosen twice. It
    /// does re-expand one they have since collapsed, which is the only observable thing left for a
    /// repeat "open" to mean.
    public func pin(_ url: URL) {
        let path = Self.canonicalPath(url.path(percentEncoded: false))
        guard !path.isEmpty, Self.covers(grantedRoots, path) else { return }
        let isNew = !pinnedRoots.contains(path)
        guard isNew || !expanded.contains(path) else { return }
        if isNew {
            pinnedRoots.append(path)
            roots = Self.display(roots: grantedRoots, pinned: pinnedRoots)
        }
        // The chain this opens is the one-element chain from the pin to itself, since the line
        // above made it one of `roots` and ``openChain(to:)`` starts from the deepest root that
        // contains its target. Routed through that method anyway so there is one definition of
        // what opening a revealed folder means, and so a pin cannot start listing the folder above
        // it — which is the difference between one directory read and a read of `~/Documents`.
        _ = openChain(to: path)
        persist()
        settle()
    }

    /// Closes one open folder, leaving the others alone.
    ///
    /// **The grant behind it is untouched.** Whether the app should still be allowed to read that
    /// directory is a different question from whether the user wants to look at it, and this type
    /// cannot reach `WorkspaceGrants` to answer the first one anyway. A folder closed here comes
    /// back the moment somebody opens it again, with no second trip through the open panel.
    ///
    /// The folder does not leave the tree if a granted root contains it — it goes back to living
    /// inside that root, where it actually is.
    public func unpin(_ path: String) {
        let canonical = Self.canonicalPath(path)
        guard pinnedRoots.contains(canonical) else { return }
        pinnedRoots.removeAll { $0 == canonical }
        roots = Self.display(roots: grantedRoots, pinned: pinnedRoots)
        persist()
        settle()
    }

    /// Closes every open folder at once, leaving the granted roots on their own.
    ///
    /// One call rather than a loop at the call site, so "close the workspace" is one rebuild and
    /// one write to the preference instead of one of each per folder.
    public func unpinAll() {
        guard !pinnedRoots.isEmpty else { return }
        pinnedRoots = []
        roots = Self.display(roots: grantedRoots, pinned: [])
        persist()
        settle()
    }

    /// Opens a folder that has just been granted, by `URL`, without the caller having to know how
    /// a path becomes a node id.
    ///
    /// Exists because the obvious spelling at the call site is wrong: ``AppModel/documentKey(for:)``
    /// keeps a directory's trailing slash, so it hands back `/Users/q/Reports/` for a node minted
    /// as `/Users/q/Reports`, and ``toggle(_:)`` drops ids it does not recognise — silently, which
    /// is the failure this whole feature exists to remove. Canonicalisation here goes through the
    /// same ``canonicalPath(_:)`` ``setRoots(_:)`` uses, so the two cannot drift.
    ///
    /// **Order does not matter.** `AppModel.grantWorkspace` calls `reloadGrants()` — and so
    /// ``setRoots(_:)`` — synchronously, so by the time the launcher gets here the row usually
    /// exists already. When it does not, the request is remembered and applied by the next
    /// ``setRoots(_:)`` that brings the folder in. Nothing about the sequencing is load-bearing.
    ///
    /// A folder granted *inside* an existing root is not a new top-level row (``setRoots(_:)``
    /// drops nested roots), so this opens the whole chain of ancestors down to it. Otherwise
    /// granting `~/Documents/Reports` while `~/Documents` is granted would look like it did
    /// nothing — the same bug in a different costume.
    public func expandNewRoot(_ url: URL) {
        let path = Self.canonicalPath(url.path(percentEncoded: false))
        guard !path.isEmpty else { return }
        let before = expanded
        guard openChain(to: path) else {
            pendingReveals.insert(path)
            return
        }
        guard expanded != before else { return }
        persist()
        settle()
    }

    /// Drops a root and its whole subtree from the tree. **Does not revoke the grant** — the
    /// folder comes back the next time ``setRoots(_:)`` runs, which is what "hide this from the
    /// list" should mean when the permission itself is somebody else's decision.
    ///
    /// It also drops any of ``pinnedRoots`` that is the removed row or lives inside it. A pin
    /// means "a folder you have open", and a row the user has just dismissed is not that; leaving
    /// it would also leave a pinned path outside every root this tree still believes in.
    public func removeRoot(_ id: String) {
        guard roots.contains(id) else { return }
        invalidateInFlight()
        pinnedRoots.removeAll { $0 == id || Self.isDescendant($0, of: id) }
        grantedRoots.removeAll { $0 == id }
        roots = Self.display(roots: grantedRoots, pinned: pinnedRoots)
        forget(id)
        expanded = expanded.filter { $0 != id && !Self.isDescendant($0, of: id) }
        persist()
        settle()
    }

    // MARK: - Expansion

    /// Opens a collapsed folder, or closes an open one.
    ///
    /// An id that is not currently on screen is ignored rather than trusted: ids reach this from
    /// the view layer, and a row that has been rebuilt away is a row whose click arrived late.
    public func toggle(_ id: String) {
        guard let node = nodes.first(where: { $0.id == id }), node.kind != .file else { return }
        if expanded.contains(id) {
            expanded.remove(id)
            persist()
            settle()
            return
        }
        guard node.depth < DirectoryLimits.maximumDepth else {
            // The honest end of the tree. The row keeps its triangle — the folder really does
            // have contents — but this is where a symlink loop that survived canonicalisation
            // stops, so turning it does nothing and says so.
            loads[id] = .unreadable
            settle()
            return
        }
        expanded.insert(id)
        persist()
        settle()
    }

    /// Forgets what we listed under `id` and lists it again if it is open.
    ///
    /// The whole subtree's cache goes, not just one level: the reason to refresh is that the disk
    /// moved, and the children of the children moved with it. Expansion is kept, so the same
    /// folders re-open as their listings land.
    public func refresh(_ id: String) {
        guard nodes.contains(where: { $0.id == id }) else { return }
        invalidateInFlight()
        forget(id)
        settle()
    }

    // MARK: - Listing

    /// Starts one directory read, off the main actor.
    ///
    /// `.userInitiated` rather than `.utility` because the user is looking at a spinner where
    /// this row's contents should be. This is not background maintenance; it is the thing they
    /// just clicked.
    private func startListing(_ path: String) {
        inFlight.insert(path)
        loads[path] = .loading
        let startedAt = generation
        let lister = source
        let extensions = fileExtensions
        let work = claimWorkID()
        pendingWork[work] = Task { [weak self] in
            let listing = await Task.detached(priority: .userInitiated) {
                try? lister.list(path, fileExtensions: extensions, limit: DirectoryLimits.pageSize)
            }.value
            guard let self else { return }
            // Struck off before `adopt`, because adopting is what starts the next round of
            // listings and the two must never be outstanding under one id.
            pendingWork[work] = nil
            guard generation == startedAt else { return }
            adopt(listing, for: path)
        }
    }

    /// Takes a landed listing. `nil` means the lister refused — outside a grant, deny-listed, or
    /// a symlink that resolved out of the boundary — which draws exactly like a folder the OS
    /// would not open, because from here they are the same fact: this branch does not open.
    private func adopt(_ listing: DirectoryListing?, for path: String) {
        inFlight.remove(path)
        guard let listing, listing.isReadable else {
            loads[path] = .unreadable
            settle()
            return
        }
        // Order is the listing's — directories first, then name — and is not re-derived here.
        // One comparator, in the layer that produced the entries, is the only way every consumer
        // sees the same order.
        children[path] = listing.entries.map { entry in
            WorkspaceNode(
                id: entry.path,
                name: entry.name,
                depth: 0,
                kind: entry.isDirectory ? .folder : .file,
                byteCount: entry.byteCount
            )
        }
        loads[path] = .loaded(omitted: listing.omittedCount)
        settle()
    }

    /// Re-flattens, then starts whatever the new shape asks for, then re-flattens again so the
    /// spinners those listings just turned on are actually on screen.
    private func settle() {
        rebuild()
        if startPendingListings() { rebuild() }
    }

    /// Lists every visible folder that is open and has never been looked at. Returns whether it
    /// changed anything.
    ///
    /// This is the one mechanism behind three things that look different: turning a triangle,
    /// restoring last session's expansion top-down as each parent lands, and re-opening a subtree
    /// after ``refresh(_:)``. All three are "this row is expanded and we have not listed it".
    private func startPendingListings() -> Bool {
        var changed = false
        for node in nodes where node.isExpanded && node.kind != .file {
            guard (loads[node.id] ?? .idle) == .idle else { continue }
            guard node.depth < DirectoryLimits.maximumDepth else {
                loads[node.id] = .unreadable
                changed = true
                continue
            }
            startListing(node.id)
            changed = true
        }
        return changed
    }

    /// Abandons every listing in flight.
    ///
    /// Bumping the generation on its own would leave the abandoned rows spinning forever, since
    /// the reply that would have cleared them is about to be dropped. Resetting them to `.idle`
    /// here is what lets ``startPendingListings()`` ask again.
    private func invalidateInFlight() {
        generation &+= 1
        inFlight.removeAll()
        for (path, load) in loads where load == .loading {
            loads[path] = .idle
        }
    }

    private func forget(_ path: String) {
        let doomed = Set(children.keys).union(loads.keys)
            .filter { $0 == path || Self.isDescendant($0, of: path) }
        for key in doomed {
            children[key] = nil
            loads[key] = nil
        }
    }

    // MARK: - Flattening

    private func rebuild() {
        var flattened: [WorkspaceNode] = []
        for root in roots {
            append(
                WorkspaceNode(id: root, name: Self.displayName(root), depth: 0, kind: .root),
                to: &flattened
            )
        }
        nodes = flattened
    }

    private func append(_ node: WorkspaceNode, to flattened: inout [WorkspaceNode]) {
        var node = node
        node.load = loads[node.id] ?? .idle
        node.isExpanded = expanded.contains(node.id)
        flattened.append(node)
        guard node.isExpanded, node.kind != .file, node.depth < DirectoryLimits.maximumDepth else { return }
        for child in children[node.id] ?? [] {
            var child = child
            child.depth = node.depth + 1
            append(child, to: &flattened)
        }
    }

    // MARK: - Persistence

    private func persist() {
        // Sorted so the stored value is a function of the set and not of insertion order — a
        // preference row that churns on every launch is a preference row nobody can diff.
        guard let pinStorage else {
            storage?.setExpandedPaths(expanded.sorted())
            return
        }
        // The pins are *not* sorted: their order is the order they were opened in, which is the
        // order they are drawn in, and is a fact worth remembering rather than churn to normalise.
        pinStorage.setTreeState(WorkspaceTreeState(expanded: expanded.sorted(), pinnedRoots: pinnedRoots))
    }

    /// Folds last session's expansion in, once, the first time roots exist to match it against.
    /// Returns whether anything was adopted.
    private func adoptPendingExpansion(under resolved: [String]) -> Bool {
        guard !pendingExpansion.isEmpty else { return false }
        let restored = pendingExpansion.filter { Self.covers(resolved, $0) }
        pendingExpansion = []
        guard !restored.isEmpty else { return false }
        expanded.formUnion(restored)
        return true
    }

    /// Opens every folder between the root that contains `path` and `path` itself, inclusive.
    /// Returns false when no live root contains it, which is the caller's cue to wait.
    ///
    /// Each ancestor has to be open for the next one down to be reachable — the tree only lists
    /// what is visible — so this is the whole chain or none of it.
    ///
    /// **The deepest containing root, not the first.** Two roots can both contain `path` now that
    /// a pinned folder may sit inside another one, and starting from the outer one would open —
    /// and therefore list — every directory between them. Nobody asked for those, and on the
    /// machine this was measured against the outer one is `~/Documents`.
    private func openChain(to path: String) -> Bool {
        let containing = roots.filter { path == $0 || Self.isDescendant(path, of: $0) }
        guard let root = containing.max(by: { Self.components($0).count < Self.components($1).count })
        else { return false }
        expanded.formUnion(Self.chain(from: root, to: path))
        return true
    }

    /// Applies any ``expandNewRoot(_:)`` request whose folder has now arrived. Requests that are
    /// still homeless stay pending; a grant that never lands leaves one path string behind.
    private func applyPendingReveals() {
        guard !pendingReveals.isEmpty else { return }
        for path in pendingReveals where openChain(to: path) {
            pendingReveals.remove(path)
        }
    }

    /// Drops expansion for anything no longer under a live root. A revoked grant must not leave
    /// its subtree remembered in a preference the user cannot see.
    private func pruneExpansion() {
        expanded = expanded.filter { Self.covers(roots, $0) }
    }

    // MARK: - Search

    /// Debounce before a walk starts. Long enough that typing a word is one walk, short enough
    /// that stopping typing feels like an answer arriving. The shape is `DocumentModel`'s
    /// baseline debounce: cancel the outstanding task, sleep, check for cancellation, work.
    private static let searchDebounce = Duration.milliseconds(250)

    /// The longest query we will carry. Past this the walk is slower and no more selective.
    private static let maximumQueryLength = 128

    private func scheduleSearch() {
        let normalized = Self.normalize(search)
        guard normalized != query else { return }
        query = normalized
        searchTask?.cancel()
        guard !normalized.isEmpty else {
            isSearching = false
            searchNote = nil
            searchResults = []
            return
        }
        isSearching = true
        searchNote = nil
        let lister = source
        let extensions = fileExtensions
        // The granted roots, not the display list: a pin nested inside one of them would put the
        // same directory in the queue twice, spending the walk's budget on it and returning every
        // file under it as two results with one id.
        let origins = grantedRoots
        let work = claimWorkID()
        let task = Task { [weak self] in
            // `defer`, not a single exit: this body returns early on cancellation in two places,
            // and an id that outlives its task would hang ``settled()`` rather than fail it.
            defer { self?.finishWork(work) }
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            // `.utility`, unlike a listing: this one can visit two thousand directories, and
            // nothing on screen is blocked on it — the tree is still there and still usable.
            let outcome = await Task.detached(priority: .utility) {
                WorkspaceSearch.walk(
                    roots: origins, matching: normalized, using: lister, fileExtensions: extensions
                )
            }.value
            guard !Task.isCancelled, let self, query == normalized else { return }
            searchResults = outcome.matches
            searchNote = outcome.note
            isSearching = false
        }
        searchTask = task
        pendingWork[work] = task
    }

    private static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumQueryLength else { return trimmed }
        return String(trimmed.prefix(maximumQueryLength))
    }

    // MARK: - Quiescence

    private func claimWorkID() -> Int {
        defer { nextWorkID &+= 1 }
        return nextWorkID
    }

    private func finishWork(_ id: Int) {
        pendingWork[id] = nil
    }

    /// Waits for every listing and search this tree has started, including the ones that landing
    /// a listing starts in turn.
    ///
    /// **For tests, and the same kind of affordance as ``SheetStore/FileWatcher/poll()``.** The
    /// alternative is a test that polls a wall clock, and that test does not assert what it looks
    /// like it asserts: under a full `swift test` there are a hundred other suites competing for
    /// the executor, a detached listing plus its main-actor landing can miss any deadline you
    /// pick, and the failure reads as a bug in the tree rather than as load on the machine. A
    /// deadline that is generous enough never to fail is also generous enough never to catch a
    /// regression, so raising it trades a red suite for a suite that proves nothing.
    ///
    /// The loop is what makes it whole-tree rather than one-listing: adopting a listing reveals
    /// children, and a child that last session left expanded starts a listing of its own. This
    /// returns when the cascade has stopped, not when the first read has.
    ///
    /// Deliberately not `public`. Nothing in the app should be waiting for the tree to go quiet —
    /// the whole design is that rows arrive when they arrive.
    func settled() async {
        while let task = pendingWork.first?.value {
            await task.value
        }
    }

    // MARK: - Paths

    /// The spelling everything keys on: tilde expanded, `..` applied, symlinks resolved, no
    /// trailing slash.
    ///
    /// Not `AppModel.documentKey(for:)`, which is the same idea for *files*: its
    /// `path(percentEncoded:)` puts a trailing slash on a directory that exists, and a root
    /// spelled `/Users/q/Reports/` would then match none of the entries the lister mints under
    /// `/Users/q/Reports`.
    static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath().standardized.path(percentEncoded: false)
        guard resolved.count > 1, resolved.hasSuffix("/") else { return resolved }
        return String(resolved.dropLast())
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whether `path` lives inside `ancestor`, compared component by component.
    ///
    /// A string prefix test would call `/Users/quino` a child of `/Users/qui`. Compared exactly
    /// rather than case-insensitively: both sides are canonical paths minted from the same
    /// on-disk spelling, and folding case here would merge two genuinely different folders on a
    /// case-sensitive volume.
    static func isDescendant(_ path: String, of ancestor: String) -> Bool {
        let parent = components(ancestor)
        let child = components(path)
        guard child.count > parent.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    /// Whether any of `roots` is `path` or contains it.
    static func covers(_ roots: [String], _ path: String) -> Bool {
        roots.contains { path == $0 || isDescendant(path, of: $0) }
    }

    /// Display order: the pins first, in pin order, then everything else. A pinned path that is
    /// also a granted root moves to the front rather than appearing twice.
    ///
    /// The pinned block being a *prefix* is load-bearing above this type: the app layer scopes the
    /// tree to the open folders by taking rows until the first unpinned root, which only works
    /// while the pins come first and stay contiguous.
    static func display(roots: [String], pinned: [String]) -> [String] {
        guard !pinned.isEmpty else { return roots }
        return pinned + roots.filter { !pinned.contains($0) }
    }

    static func topLevelRoots(_ paths: [String]) -> [String] {
        var canonical: [String] = []
        var seen: Set<String> = []
        for path in paths {
            let resolved = canonicalPath(path)
            guard !resolved.isEmpty, seen.insert(resolved).inserted else { continue }
            canonical.append(resolved)
        }
        return canonical.filter { candidate in
            !canonical.contains { isDescendant(candidate, of: $0) }
        }
    }

    /// Every path from `root` down to `path`, inclusive of both. `[]` when `path` is not under
    /// `root`, which the one caller has already ruled out.
    static func chain(from root: String, to path: String) -> [String] {
        let rootComponents = components(root)
        let pathComponents = components(path)
        guard pathComponents.count >= rootComponents.count else { return [] }
        return (rootComponents.count ... pathComponents.count).map { depth in
            "/" + pathComponents.prefix(depth).joined(separator: "/")
        }
    }

    private static func displayName(_ path: String) -> String {
        components(path).last ?? path
    }
}

/// The file search, off on its own because it is not part of the tree's state.
///
/// At file scope rather than as a member of ``WorkspaceTree``, so it carries no actor isolation
/// to shed: it runs inside `Task.detached`, and a `nonisolated` member on a `@MainActor` class is
/// a member the two linters in this repo cannot agree about how to spell.
private enum WorkspaceSearch {
    struct SearchOutcome: Sendable {
        var matches: [WorkspaceNode]
        var note: String?
    }

    /// Breadth-first, budgeted, and honest about stopping.
    ///
    /// Breadth-first because the file somebody is looking for is far more often three levels down
    /// than twelve, and a depth-first walk spends its whole budget in the first branch it finds.
    /// The budgets are not defensive programming: `~/Documents` has 77,024 directories in it, so
    /// an unbudgeted walk is not slow, it is a hang.
    static func walk(
        roots: [String],
        matching query: String,
        using lister: any DirectoryListingSource,
        fileExtensions: Set<String>
    ) -> SearchOutcome {
        var queue: [(path: String, depth: Int)] = roots.map { ($0, 0) }
        var next = 0
        var matches: [WorkspaceNode] = []
        var directoriesVisited = 0
        var entriesVisited = 0
        var stoppedEarly = false

        while next < queue.count {
            // Once per directory, which is the granularity the work comes in. Checking per entry
            // would cost more than the compare it is protecting.
            guard !Task.isCancelled else { return SearchOutcome(matches: [], note: nil) }
            guard directoriesVisited < DirectoryLimits.searchDirectoryBudget,
                  entriesVisited < DirectoryLimits.searchEntryBudget
            else {
                stoppedEarly = true
                break
            }
            let (path, depth) = queue[next]
            next += 1
            directoriesVisited += 1
            guard let listing = try? lister.list(path, fileExtensions: fileExtensions, limit: DirectoryLimits.pageSize),
                  listing.isReadable
            else { continue }

            for entry in listing.entries {
                entriesVisited += 1
                guard !entry.isDirectory else {
                    if depth + 1 < DirectoryLimits.maximumDepth { queue.append((entry.path, depth + 1)) }
                    continue
                }
                // Diacritic-insensitive as well as case-insensitive, because a file called
                // `Résumé.xlsx` is a file people type `resume` to find.
                guard entry.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                else { continue }
                matches.append(
                    WorkspaceNode(
                        id: entry.path,
                        name: entry.name,
                        depth: 0,
                        kind: .file,
                        byteCount: entry.byteCount
                    )
                )
            }
        }

        let note = stoppedEarly
            ? "Stopped after \(entriesVisited) files — narrow the search or open a subfolder."
            : nil
        return SearchOutcome(matches: matches, note: note)
    }
}

/// Everything the explorer remembers between launches: which folders were open, and which ones
/// the user had deliberately opened as workspaces.
///
/// # Why it decodes three shapes and writes one
///
/// `workspace.explorer` shipped as a bare JSON array of paths, then as an object with a single
/// `pinnedRoot` beside the expansion set, and now as an object with a `pinnedRoots` list. There
/// are databases holding each of the first two right now — the developer's had `["/tmp/x"]` in it
/// before it had the object. A decoder that only knew the newest shape would read every older row
/// as "nothing expanded, nothing open" on the launch that upgraded it: a preference silently
/// discarded, on the one launch where the user is least likely to connect the two.
///
/// So all three are read and only the newest is written. The array is tried first, then
/// `pinnedRoots`, then `pinnedRoot` — which becomes a one-element list, because one open folder is
/// what that session actually had. Migration runs in the direction it has to and no further; there
/// is no version number, because "list or dictionary, and which key" already answers the only
/// question there is.
///
/// The pins are a key beside the paths rather than marked elements inside them. A sentinel in a
/// list of paths is a path, and a path is something somebody eventually grants.
public struct WorkspaceTreeState: Sendable, Equatable, Codable {
    /// Folders that were open, canonical.
    public var expanded: [String]

    /// The folders that were open as workspaces, in the order they were opened. Empty for a
    /// session that never opened one.
    public var pinnedRoots: [String]

    public init(expanded: [String] = [], pinnedRoots: [String] = []) {
        self.expanded = expanded
        self.pinnedRoots = pinnedRoots
    }

    private enum CodingKeys: String, CodingKey {
        case expanded
        case pinnedRoots
        /// The single pin the object form shipped with. Read, never written.
        case pinnedRoot
    }

    public init(from decoder: any Decoder) throws {
        if let legacy = try? [String](from: decoder) {
            expanded = legacy
            pinnedRoots = []
            return
        }
        // `decodeIfPresent` throughout, so an object that is merely *not this* — the shape the
        // corrupt-preference test writes — lands on the same empty state a missing row does.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expanded = try container.decodeIfPresent([String].self, forKey: .expanded) ?? []
        if let roots = try container.decodeIfPresent([String].self, forKey: .pinnedRoots) {
            pinnedRoots = roots
            return
        }
        pinnedRoots = try container.decodeIfPresent(String.self, forKey: .pinnedRoot).map { [$0] } ?? []
    }

    /// Written by hand rather than synthesised, because ``CodingKeys`` carries a case for the
    /// legacy key that no property matches.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expanded, forKey: .expanded)
        // Omitted rather than written as `[]`, matching what the optional `pinnedRoot` used to
        // encode to: a row for somebody who has never opened a folder should say nothing about
        // folders, since the documented way to inspect this preference is to read it in `sqlite3`.
        guard !pinnedRoots.isEmpty else { return }
        try container.encode(pinnedRoots, forKey: .pinnedRoots)
    }
}

/// Storage that can also remember ``WorkspaceTree/pinnedRoots``.
///
/// A refinement rather than two more requirements on ``WorkspaceTreeStorage``, which is the
/// contract the rest of the app already conforms to. The pins arrived after the expansion set did,
/// and widening the base protocol would make "where do I keep a pin" a question every conformance
/// has to answer — including the ones with nowhere to put one. ``WorkspaceTree`` asks for this by
/// a conditional cast and degrades to remembering only the expansion set when the cast fails,
/// which is a store one feature behind rather than a store that will not compile.
public protocol WorkspaceTreePinStorage: WorkspaceTreeStorage {
    func treeState() -> WorkspaceTreeState
    func setTreeState(_ state: WorkspaceTreeState)
}

/// `workspace.explorer` in the `preference` table — the same place and the same shape as
/// `workspace.tabs`. Failures are swallowed to "nothing expanded": a tree that refuses to draw
/// because a preference would not decode is worse than a tree that starts collapsed.
///
/// The precedent is `CheckpointStore.storedID(for:)`, which swallows for the same reason. Neither
/// of these is a failure the user caused, and neither has a recovery worth putting on screen —
/// the fix for a corrupt row is to turn a triangle.
public struct DatabaseWorkspaceTreeStorage: WorkspaceTreePinStorage {
    public static let preferenceKey = "workspace.explorer"

    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func expandedPaths() -> [String] {
        treeState().expanded
    }

    /// Reads before it writes, so a caller holding only the base protocol cannot erase a pin it
    /// has no way to see. One row holds both facts; anything that writes half of it owes the
    /// other half a read.
    public func setExpandedPaths(_ paths: [String]) {
        var state = treeState()
        state.expanded = paths
        setTreeState(state)
    }

    public func treeState() -> WorkspaceTreeState {
        guard let stored = storedValue(),
              let data = stored.data(using: .utf8),
              let state = try? JSONDecoder().decode(WorkspaceTreeState.self, from: data)
        else { return WorkspaceTreeState() }
        return state
    }

    public func setTreeState(_ state: WorkspaceTreeState) {
        let encoder = JSONEncoder()
        // Sorted keys for the reason the paths themselves are sorted before they get here: the
        // stored text has to be a function of the state and nothing else. Unescaped slashes
        // because the documented way to reset the explorer is to read this row in `sqlite3`, and
        // `["\/Users\/x"]` is a path nobody can grep for.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(state),
              let text = String(data: data, encoding: .utf8)
        else { return }
        try? database.setPreference(Self.preferenceKey, to: text)
    }

    /// The raw preference, or `nil` for either of the two ways there is not one: the read failed,
    /// or the row does not exist. Written as a method because the read is doubly optional and
    /// flattening it inline reads as an accident.
    private func storedValue() -> String? {
        guard let value = try? database.preference(Self.preferenceKey) else { return nil }
        return value
    }
}
