import DocumentCore
import Foundation
import SheetModel
import SheetStore
import Testing

/// What the tab strip does to the list of open files: which tab appears where, which one is in
/// front afterwards, and what gets written down so the next launch can put it back.
///
/// # Why none of this opens a file
///
/// ``DocumentCore/TabsModel`` takes its three effects — open, close, persist — as closures for
/// exactly this reason. The rules worth asserting here are about *the list*: a second open of one
/// path must not grow it, closing the tab you are looking at has to leave you looking at something
/// sensible, and the stored tab set has to agree with the tabs on screen after every one of those.
/// None of that is about XLSX bytes, and a suite that stood up a real store to find out would be
/// slower, flakier, and no more convincing.
///
/// The documents the fake hands back are nevertheless real ``DocumentCore/DocumentModel``s over a
/// session that was never started — so there is no watcher and no file descriptor, but the type the
/// tab carries is the type the window will get.
@Suite("Workspace tabs")
@MainActor
struct TabsModelTests {
    // MARK: - Opening

    @Test func openingTwoFilesLeavesTwoTabsWithTheSecondInFront() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()

        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)

        #expect(tabs.tabs.map(\.url) == [Self.budget, Self.plan], "the order they were asked for")
        #expect(tabs.activeTabID == Self.id(of: Self.plan), "the newest tab comes forward")
        #expect(tabs.activeDocument?.url == Self.plan)
        #expect(spy.opened == [Self.budget, Self.plan])
    }

    /// Opening a file that is already open activates its tab. This is the rule that used to be
    /// "one window per file", and it is why tabs are keyed by
    /// ``DocumentCore/AppModel/documentKey(for:)`` rather than by whichever URL the caller held.
    @Test func openingAFileThatIsAlreadyOpenActivatesItsTabRatherThanAddingOne() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()

        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)
        await tabs.open(Self.budget, consent: .userSelectedInPanel)

        #expect(tabs.tabs.count == 2)
        #expect(tabs.activeTabID == Self.id(of: Self.budget))
    }

    /// A new tab lands beside the one it was opened from, not at the far end of the strip.
    @Test func aNewTabOpensAfterTheActiveOne() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()

        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)
        tabs.activate(Self.id(of: Self.budget))
        await tabs.open(Self.forecast, consent: .userSelectedInPanel)

        #expect(tabs.tabs.map(\.url) == [Self.budget, Self.forecast, Self.plan])
    }

    /// The re-entrant case, which is the shape that once produced five windows on one file: a
    /// second open arrives while the first is still reading. ``DocumentCore/AppModel`` coalesces
    /// the work underneath, so the only thing that can go wrong here is a second tab.
    @Test func openingAFileWhoseTabIsStillLoadingDoesNotAddASecondTab() async throws {
        let spy = try Spy()
        spy.holdsOpens = true
        let tabs = spy.makeTabs()

        let first = Task { await tabs.open(Self.budget, consent: .fromOutsideTheApp) }
        let second = Task { await tabs.open(Self.budget, consent: .fromOutsideTheApp) }
        await second.value

        #expect(tabs.tabs.count == 1)
        #expect(tabs.activeDocument == nil, "still loading — there is no document to hand out yet")
        guard case .loading = tabs.tabs[0].phase else {
            Issue.record("the tab left .loading before its document arrived")
            return
        }

        spy.release()
        await first.value
        #expect(tabs.activeDocument?.url == Self.budget)
        #expect(spy.opened.count == 1, "the second caller joined the first open rather than starting one")
    }

    /// A tab closed while its document is still loading has nobody left to hold that document, so
    /// this is where it gets let go. Forgetting it would leave a session — and, in the app, a
    /// watcher and a file descriptor — alive for the rest of the process.
    @Test func aDocumentThatArrivesAfterItsTabIsClosedIsReleased() async throws {
        let spy = try Spy()
        spy.holdsOpens = true
        let tabs = spy.makeTabs()

        let opening = Task { await tabs.open(Self.budget, consent: .fromOutsideTheApp) }
        // An empty task enqueued behind it: when this one completes, the open has run as far as its
        // first suspension, which is the gate.
        await Task { @MainActor in }.value
        #expect(tabs.tabs.count == 1)

        tabs.close(Self.id(of: Self.budget))
        #expect(tabs.isEmpty)

        spy.release()
        await opening.value
        #expect(spy.closed == [Self.budget], "the late document was released rather than orphaned")
    }

    /// A file that will not open is a state of its own tab — never an alert, and never a reason for
    /// the tabs beside it to notice.
    @Test func anOpenThatFailsLandsInItsOwnTabAndLeavesTheOthersAlone() async throws {
        let spy = try Spy()
        spy.refusing = ["plan.xlsx"]
        let tabs = spy.makeTabs()

        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)

        #expect(tabs.tabs.count == 2, "a refusal is still a tab; the user asked for this file")
        #expect(tabs.activeDocument == nil)
        guard case let .failed(error) = tabs.tabs[1].phase else {
            Issue.record("the failing open did not land in its tab")
            return
        }
        #expect(error == SheetError.pathOutsideWorkspace(path: Self.stored(Self.plan)))
        guard case let .ready(model) = tabs.tabs[0].phase else {
            Issue.record("the tab beside it stopped being ready")
            return
        }
        #expect(model.url == Self.budget)
    }

    // MARK: - Closing

    @Test func closingTheActiveTabActivatesTheOneToItsRight() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()
        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)
        await tabs.open(Self.forecast, consent: .userSelectedInPanel)
        tabs.activate(Self.id(of: Self.plan))

        tabs.close(Self.id(of: Self.plan))

        #expect(tabs.tabs.map(\.url) == [Self.budget, Self.forecast])
        #expect(tabs.activeTabID == Self.id(of: Self.forecast))
        #expect(spy.closed == [Self.plan], "the closed tab's document went with it")
    }

    /// There is no right-hand neighbour for the last tab, so the eye falls left rather than onto
    /// nothing.
    @Test func closingTheRightmostTabFallsBackToTheOneOnItsLeft() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()
        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)

        tabs.close(Self.id(of: Self.plan))

        #expect(tabs.activeTabID == Self.id(of: Self.budget))
    }

    @Test func closingTheLastRemainingTabLeavesNothingOpenAndNothingActive() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()
        await tabs.open(Self.budget, consent: .userSelectedInPanel)

        tabs.close(Self.id(of: Self.budget))

        #expect(tabs.isEmpty)
        #expect(tabs.activeTabID == nil)
        #expect(tabs.activeDocument == nil)
    }

    /// Two ⌘Ws in one run-loop turn both name the tab that was in front when the key went down.
    /// The second one has nothing to close, and that is not an error.
    @Test func closingATabTwiceIsANoOp() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()
        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)
        let id = Self.id(of: Self.plan)

        tabs.close(id)
        tabs.close(id)

        #expect(tabs.tabs.map(\.url) == [Self.budget])
        #expect(spy.closed == [Self.plan], "the document was released once, not twice")
    }

    // MARK: - Activation

    @Test func nextAndPreviousWalkTheStripAndWrapRound() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()
        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)
        await tabs.open(Self.forecast, consent: .userSelectedInPanel)

        tabs.activateNext()
        #expect(tabs.activeTabID == Self.id(of: Self.budget), "past the end is back to the start")
        tabs.activatePrevious()
        #expect(tabs.activeTabID == Self.id(of: Self.forecast))
        tabs.activatePrevious()
        #expect(tabs.activeTabID == Self.id(of: Self.plan))
    }

    /// ⌘7 with one tab open should do nothing rather than something.
    @Test func activatingAnIndexOutOfRangeDoesNothing() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()
        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        let before = tabs.activeTabID

        tabs.activate(index: 6)
        tabs.activate(index: -1)

        #expect(tabs.activeTabID == before)
        #expect(spy.writes.count == 1, "an ignored keystroke is not a change worth storing")
    }

    @Test func activatingByIndexIsZeroBased() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()
        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)

        tabs.activate(index: 0)
        #expect(tabs.activeTabID == Self.id(of: Self.budget))
    }

    // MARK: - Persistence

    /// Every change to membership or to which tab is in front is written down as it happens, so a
    /// crash loses at most the tab you were about to open. Phases are deliberately *not* stored: a
    /// document finishing its load does not change which files are open, and a write per load would
    /// make this count unanswerable.
    @Test func everyChangeToTheTabSetIsWrittenDownAndNothingElseIs() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()

        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        await tabs.open(Self.plan, consent: .userSelectedInPanel)
        await tabs.open(Self.budget, consent: .userSelectedInPanel)
        tabs.close(Self.id(of: Self.budget))
        tabs.close(Self.id(of: Self.plan))

        let budget = Self.stored(Self.budget)
        let plan = Self.stored(Self.plan)
        #expect(spy.writes.count == 5, "one write per membership or activation change, and no more")
        #expect(spy.writes[0] == TabsModel.PersistedTabs(paths: [budget], activeIndex: 0))
        #expect(spy.writes[1] == TabsModel.PersistedTabs(paths: [budget, plan], activeIndex: 1))
        #expect(spy.writes[2] == TabsModel.PersistedTabs(paths: [budget, plan], activeIndex: 0))
        #expect(spy.writes[3] == TabsModel.PersistedTabs(paths: [plan], activeIndex: 0))
        #expect(spy.writes[4] == TabsModel.PersistedTabs(paths: [], activeIndex: nil))
        #expect(spy.writes.last == tabs.persisted)
    }

    /// The stored set round-trips through JSON, because that is how it reaches the `preference`
    /// table (§1.7) — and a shape that only worked in memory would fail at the one moment it counts.
    @Test func theStoredTabSetSurvivesJSON() throws {
        let persisted = TabsModel.PersistedTabs(paths: ["/files/budget.xlsx", "/files/plan.xlsx"], activeIndex: 1)
        let data = try JSONEncoder().encode(persisted)
        #expect(try JSONDecoder().decode(TabsModel.PersistedTabs.self, from: data) == persisted)
    }

    // MARK: - Restore

    @Test func restoreOpensEveryPathInOrderAndKeepsTheOneThatFailed() async throws {
        let spy = try Spy()
        spy.refusing = ["plan.xlsx"]
        let tabs = spy.makeTabs()

        await tabs.restore(
            TabsModel.PersistedTabs(
                paths: [Self.stored(Self.budget), Self.stored(Self.plan), Self.stored(Self.forecast)],
                activeIndex: 2
            )
        )

        #expect(tabs.tabs.map(\.url) == [Self.budget, Self.plan, Self.forecast], "stored order is tab order")
        guard case .failed = tabs.tabs[1].phase else {
            Issue.record("the file that would not open should have failed in place, without stopping the rest")
            return
        }
        #expect(tabs.activeTabID == Self.id(of: Self.forecast))
        #expect(tabs.activeDocument?.url == Self.forecast)
    }

    /// A relative path in a stored preference cannot be resolved against anything trustworthy — it
    /// would land wherever the process's working directory happens to be. §1.8: skipped, silently,
    /// because the user never typed it.
    @Test func restoreIgnoresAPathThatIsNotAbsolute() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()

        await tabs.restore(
            TabsModel.PersistedTabs(paths: ["budget.xlsx", Self.stored(Self.plan)], activeIndex: 1)
        )

        #expect(tabs.tabs.map(\.url) == [Self.plan])
    }

    /// The stored index was written against a tab set that may have lost entries on the way back,
    /// and a preference file is a thing anyone can edit. Clamped rather than trusted.
    @Test func restoreClampsAnActiveIndexThatNoLongerFits() async throws {
        let spy = try Spy()
        let paths = [Self.stored(Self.budget), Self.stored(Self.plan)]

        let tooHigh = spy.makeTabs()
        await tooHigh.restore(TabsModel.PersistedTabs(paths: paths, activeIndex: 9))
        #expect(tooHigh.activeTabID == Self.id(of: Self.plan))

        let belowZero = spy.makeTabs()
        await belowZero.restore(TabsModel.PersistedTabs(paths: paths, activeIndex: -3))
        #expect(belowZero.activeTabID == Self.id(of: Self.budget))
    }

    @Test func restoringNothingLeavesAnEmptyWorkspace() async throws {
        let spy = try Spy()
        let tabs = spy.makeTabs()

        await tabs.restore(TabsModel.PersistedTabs())

        #expect(tabs.isEmpty)
        #expect(tabs.activeTabID == nil)
        #expect(spy.writes.isEmpty, "restoring nothing is not a change")
    }

    // MARK: - Scaffolding

    private static let budget = URL(fileURLWithPath: "/files/work/budget.xlsx")
    private static let plan = URL(fileURLWithPath: "/files/work/plan.xlsx")
    private static let forecast = URL(fileURLWithPath: "/files/models/forecast.csv")

    private static func id(of url: URL) -> String { AppModel.documentKey(for: url) }

    private static func stored(_ url: URL) -> String { url.path(percentEncoded: false) }

    /// The three effects ``DocumentCore/TabsModel`` takes as arguments, as something a test can
    /// look at afterwards — plus a gate, so "opened again while the first one is still loading" is
    /// a shape this suite can produce deliberately rather than a race it hopes to catch.
    @MainActor
    final class Spy {
        private(set) var opened: [URL] = []
        private(set) var closed: [URL] = []
        private(set) var writes: [TabsModel.PersistedTabs] = []
        /// Last path components that refuse to open, standing in for a revoked grant or a file that
        /// is no longer there.
        var refusing: Set<String> = []
        /// While true, every open parks until ``release()``.
        var holdsOpens = false

        private let workbook: Workbook
        private let reader = DocumentWorkbookReader()
        private var parked: [CheckedContinuation<Void, Never>] = []

        init() throws {
            workbook = try Harness.seedWorkbook(1)
        }

        func makeTabs() -> TabsModel {
            TabsModel(
                // The signature is written out because it has to be — see
                // ``DocumentCore/TabsModel/init(open:close:persist:)``. Swift 6.3 infers a closure
                // literal's thrown type as `any Error` and then refuses to convert it.
                open: { [self] (url: URL, _: WorkspaceConsent) async throws(SheetError) -> DocumentModel in
                    try await document(for: url)
                },
                close: { [self] model in
                    // What `AppModel.closeDocument` does, minus the registry it does it to.
                    model.close()
                    closed.append(model.url)
                },
                persist: { [self] value in writes.append(value) }
            )
        }

        func release() {
            let waiting = parked
            parked = []
            for continuation in waiting { continuation.resume() }
        }

        private func document(for url: URL) async throws(SheetError) -> DocumentModel {
            opened.append(url)
            if holdsOpens {
                await withCheckedContinuation { parked.append($0) }
            }
            guard !refusing.contains(url.lastPathComponent) else {
                throw SheetError.pathOutsideWorkspace(path: url.path(percentEncoded: false))
            }
            // A session that is never started: no watcher, no file descriptor, no I/O — but the
            // document the tab carries is the real type, wired the way the app wires it.
            let session = DocumentSession(
                url: url,
                workbook: workbook,
                io: WorkbookIO(reader: reader),
                suppressor: SelfWriteSuppressor(),
                options: DocumentSession.Options(autoRefresh: false, snapshotsEnabled: false)
            )
            return DocumentModel(
                url: url,
                workspaceURL: url.deletingLastPathComponent(),
                workbook: workbook,
                session: session,
                reader: reader,
                writer: nil,
                autoRefresh: false
            )
        }
    }
}
