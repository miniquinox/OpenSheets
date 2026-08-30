import AppKit
import SwiftUI
import Testing

@testable import GlassUI

/// The file explorer, **driven through the real view**.
///
/// # Why the clicks are real
///
/// `FormulaBarFieldTests` records what happens when a component is tested only through the actions
/// it emits: a formula bar passed every test in that file while silently destroying formulas,
/// because a select-all is not an action and nothing was looking at what the view had drawn. The
/// explorer has the same shape of risk and more of it. Half of what it promises is *layout* — the
/// disclosure column keeps its width while a folder loads, indentation grows one even step per
/// level, a note is a sentence rather than a button — and none of that reaches an action closure.
///
/// So these host a real ``FileExplorer`` in a real `NSWindow`, find the controls AppKit actually
/// made for it, and click them with real `NSEvent`s. ``Explorer/targets`` is the list of things a
/// pointer can hit inside the list, in the order they are drawn, which lets a test say "the note
/// row is not one of them" — a claim about the picture rather than about the callback.
///
/// It has already paid for itself once: the search field reported a query nobody had typed, on
/// every appearance, and the action it emitted was indistinguishable from a real one.
///
/// The pure half — ``FileExplorer/activation(for:)`` — is asserted separately and exhaustively,
/// because a window has room for only a handful of the rows it has to be right about.
@Suite(.serialized)
@MainActor
struct FileExplorerTests {
    // MARK: - What a click means

    @Test func clickingAFileSelectsItAndThenOpensIt() {
        let explorer = Explorer([.workbook("/a/budget.xlsx", "budget.xlsx")])
        explorer.click(0)
        #expect(explorer.actions == [.select("/a/budget.xlsx"), .open("/a/budget.xlsx")])
    }

    /// The order is the assertion, not an accident of how the array was written. Selecting after
    /// opening leaves the previous row lit while a different document is already on screen.
    @Test func selectionIsReportedBeforeTheOpen() {
        let explorer = Explorer([.delimited("/a/exports.csv", "exports.csv")])
        explorer.click(0)
        #expect(explorer.actions.first == .select("/a/exports.csv"))
        #expect(explorer.actions.last == .open("/a/exports.csv"))
    }

    /// Two targets — the chevron and the row — and both mean the same thing. Neither selects: a
    /// folder is not a document, and lighting it up would say the window was showing it.
    @Test func clickingAFolderTogglesItAndNothingElse() {
        let explorer = Explorer([.folder("/a/Outreach", "Outreach")])
        #expect(explorer.targets.count == 2)
        for index in explorer.targets.indices {
            explorer.clearActions()
            explorer.click(index)
            #expect(explorer.actions == [.toggle("/a/Outreach")], "target \(index)")
        }
    }

    @Test func clickingARootTogglesIt() {
        let explorer = Explorer([.root("/a", "finance")])
        explorer.click(1)
        #expect(explorer.actions == [.toggle("/a")])
    }

    /// A note is a sentence. It has no hit target at all — not a disabled one, not a silent one.
    @Test func aNoteRowIsNotSomethingYouCanClick() {
        let explorer = Explorer([
            .folder("/a/Outreach", "Outreach"),
            .note("note:/a/Outreach", "+ 2,609 more"),
        ])
        #expect(explorer.targets.count == 2, "the folder's chevron and row, and nothing for the note")
        for index in explorer.targets.indices {
            explorer.click(index)
        }
        #expect(explorer.actions.allSatisfy { $0 == .toggle("/a/Outreach") }, "got \(explorer.actions)")
    }

    /// A file whose folder has been unmounted still draws, still hit-tests, and still does nothing.
    ///
    /// Both halves matter. Removing the row would answer "where did my file go" by making the
    /// question impossible to ask; opening it would put an error sheet in front of a click the user
    /// had every reason to make.
    @Test func aMissingRowIsStillDrawnAndStillDoesNothing() {
        let explorer = Explorer([.missingWorkbook("/a/gone.xlsx", "gone.xlsx")])
        #expect(explorer.targets.count == 1, "it is still on screen")
        explorer.click(0)
        #expect(explorer.actions.isEmpty)
    }

    @Test func theHeaderButtonAsksForAFolder() {
        let explorer = Explorer([.root("/a", "finance")])
        explorer.clickChrome(0)
        #expect(explorer.actions == [.addFolder])
    }

    /// The sidebar hosts this with `offersAddFolder: false`, because granting already lives in the
    /// Claude panel there. "Not offered" has to mean the button is absent, not disabled.
    @Test func theHeaderButtonIsAbsentWhenTheHostDoesNotOfferIt() {
        let explorer = Explorer([.root("/a", "finance")], offersAddFolder: false)
        #expect(explorer.chromeTargets.isEmpty)
    }

    // MARK: - What the view draws

    /// The bug this pins: a spinner that replaces the chevron *and its column* makes the row's name
    /// jump sideways the moment a folder starts listing — which is exactly when the user is
    /// watching, because they just clicked it.
    @Test func aRowDoesNotMoveWhenItsFolderStartsLoading() throws {
        let idle = Explorer([.folder("/a/Outreach", "Outreach")])
        let loading = Explorer([.loadingFolder("/a/Outreach", "Outreach")])

        let idleRow = try #require(idle.targets.last)
        let loadingRow = try #require(loading.targets.last)
        #expect(idle.originX(of: idleRow) == loading.originX(of: loadingRow))
    }

    @Test func aLoadingFolderShowsASpinnerWhereItsChevronWas() {
        let explorer = Explorer([.loadingFolder("/a/Outreach", "Outreach")])
        #expect(explorer.spinnerCount == 1)
        #expect(explorer.targets.count == 1, "the chevron is gone; only the row itself is clickable")
    }

    @Test func nothingSpinsWhenNothingIsLoading() {
        let explorer = Explorer([.folder("/a/Outreach", "Outreach"), .workbook("/a/b.xlsx", "b.xlsx")])
        #expect(explorer.spinnerCount == 0)
    }

    /// A folder we cannot read loses its chevron too — there is nothing behind it to disclose — but
    /// the row stays live, because permissions get granted and volumes get mounted, and a retry is
    /// the only affordance we have.
    @Test func anUnreadableFolderHasNoChevronAndStillRetries() {
        let explorer = Explorer([.unreadableFolder("/a/private", "private")])
        #expect(explorer.targets.count == 1)
        explorer.click(0)
        #expect(explorer.actions == [.toggle("/a/private")])
    }

    /// Depth is the only thing that moves a row sideways, and it moves it by a constant step.
    @Test func indentationGrowsOneEvenStepPerLevel() {
        let explorer = Explorer([
            .workbook("/a.xlsx", "a.xlsx", depth: 0),
            .workbook("/a/b.xlsx", "b.xlsx", depth: 1),
            .workbook("/a/b/c.xlsx", "c.xlsx", depth: 2),
        ])
        let origins = explorer.targets.map { explorer.originX(of: $0) }
        #expect(origins.count == 3)
        let steps = zip(origins, origins.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 > 0 }, "deeper rows sit further right: \(origins)")
        #expect(Set(steps).count == 1, "the step is not even: \(steps)")
    }

    // MARK: - Search

    @Test func theFieldShowsTheSearchItWasGiven() throws {
        let explorer = Explorer([.workbook("/a/b.xlsx", "b.xlsx")], search: "budget")
        let field = try #require(explorer.searchField)
        #expect(field.stringValue == "budget")
    }

    /// **The echo, pinned.** AppKit's field writes its own contents back through the binding as it
    /// lays out. Unguarded, merely showing the explorer reported a search nobody had typed — which
    /// this suite caught the first time it hosted the view, and which no action-only test could
    /// have seen, because the action it emitted was exactly the one a real keystroke produces.
    @Test func showingTheExplorerDoesNotReportASearchNobodyTyped() {
        let explorer = Explorer([.workbook("/a/b.xlsx", "b.xlsx")], search: "budget")
        #expect(explorer.actions.isEmpty, "got \(explorer.actions)")
    }

    @Test func theClearButtonIsThereOnlyWhileThereIsSomethingToClear() {
        let quiet = Explorer([.workbook("/a/b.xlsx", "b.xlsx")])
        let searching = Explorer([.workbook("/a/b.xlsx", "b.xlsx")], search: "budget")
        #expect(quiet.chromeTargets.count == 1, "just the + button")
        #expect(searching.chromeTargets.count == 2, "the + button and a way to empty the field")

        searching.clickChrome(1)
        #expect(searching.actions == [.search("")])
    }

    // MARK: - Empty

    /// An empty explorer is one line of text, not an empty scroller. A scroll view with nothing in
    /// it reads as a list that failed to load rather than as a workspace with nothing granted.
    @Test func anEmptyExplorerSaysSoInsteadOfShowingAnEmptyList() {
        let explorer = Explorer(state: FileExplorerState(emptyMessage: "No folders yet."))
        #expect(explorer.scrollView == nil)
        #expect(explorer.targets.isEmpty)
        #expect(explorer.chromeTargets.count == 1, "and the + is still offered")
    }

    /// The message is a fallback, not an override: rows win whenever there are any.
    @Test func rowsWinOverTheEmptyMessage() {
        let explorer = Explorer(
            state: FileExplorerState(
                rows: [FileExplorerRow(id: "/a/b.xlsx", name: "b.xlsx", depth: 0, kind: .workbook)],
                emptyMessage: "No folders yet."
            )
        )
        #expect(explorer.scrollView != nil)
        #expect(explorer.targets.count == 1)
    }

    // MARK: - The rule, exhaustively

    /// Every kind against every load state, which is more combinations than a window has room for.
    @Test func onlyNotesAndMissingRowsDoNothing() {
        let loads: [FileExplorerRow.Load] = [.idle, .loading, .unreadable, .missing]
        for kind in FileExplorerRow.Kind.allCases {
            for load in loads {
                let row = FileExplorerRow(id: "/x", name: "x", depth: 0, kind: kind, load: load)
                let actions = FileExplorer.activation(for: row)
                if kind == .note || load == .missing {
                    #expect(actions.isEmpty, "\(kind)/\(load) is not interactive but emitted \(actions)")
                } else {
                    #expect(!actions.isEmpty, "\(kind)/\(load) emitted nothing")
                }
            }
        }
    }

    @Test func nothingOpensWithoutSelectingFirst() {
        for kind in FileExplorerRow.Kind.allCases {
            let row = FileExplorerRow(id: "/x", name: "x", depth: 0, kind: kind)
            let actions = FileExplorer.activation(for: row)
            guard let open = actions.firstIndex(of: .open("/x")) else { continue }
            guard let select = actions.firstIndex(of: .select("/x")) else {
                Issue.record("\(kind) opens without ever selecting")
                continue
            }
            #expect(select < open)
        }
    }

    @Test func activationCarriesTheRowsOwnIdentity() {
        let folder = FileExplorerRow(id: "/a/b", name: "b", depth: 1, kind: .folder)
        #expect(FileExplorer.activation(for: folder) == [.toggle("/a/b")])
        let file = FileExplorerRow(id: "/a/b.csv", name: "b.csv", depth: 1, kind: .delimited)
        #expect(FileExplorer.activation(for: file) == [.select("/a/b.csv"), .open("/a/b.csv")])
    }

    // MARK: - Harness

    /// A ``FileExplorer`` in a real window, plus the controls AppKit made for it.
    ///
    /// The window is ordered **back** rather than made key, matching `FormulaBarFieldTests`: a
    /// suite that stole the keyboard from whoever ran it would be a worse citizen than the bugs it
    /// catches, and SwiftUI lays out off `displayIfNeeded` regardless.
    @MainActor
    private final class Explorer {
        let window: NSWindow
        let hosting: NSHostingView<AnyView>

        /// Actions land in a box because the closure is captured before `self` exists.
        private let sink = Sink()
        private final class Sink: @unchecked Sendable { var actions: [FileExplorerAction] = [] }

        /// Windows are kept for the life of the process. A deallocated `NSWindow` whose hosting
        /// view is still mid-update takes the runner down with it.
        nonisolated(unsafe) static var retained: [NSWindow] = []

        private static let width: CGFloat = 260
        private static let height: CGFloat = 460

        convenience init(_ rows: [FileExplorerRow], search: String = "", offersAddFolder: Bool = true) {
            self.init(
                state: FileExplorerState(rows: rows, search: search, offersAddFolder: offersAddFolder)
            )
        }

        init(state: FileExplorerState) {
            let sink = sink
            let view = FileExplorer(state: state, context: .light) { sink.actions.append($0) }
            hosting = NSHostingView(rootView: AnyView(view.frame(width: Self.width, height: Self.height)))
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = hosting
            hosting.frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
            hosting.layoutSubtreeIfNeeded()
            window.orderBack(nil)
            window.displayIfNeeded()
            Self.retained.append(window)
        }

        var actions: [FileExplorerAction] { sink.actions }

        func clearActions() { sink.actions.removeAll() }

        /// The list's scroller, or `nil` when the explorer drew a message instead of a list.
        var scrollView: NSScrollView? {
            Self.descendants(of: hosting).compactMap { $0 as? NSScrollView }.first
        }

        var searchField: NSTextField? {
            Self.descendants(of: hosting).compactMap { $0 as? NSTextField }.first
        }

        var spinnerCount: Int {
            Self.descendants(of: hosting).compactMap { $0 as? NSProgressIndicator }.count
        }

        /// Everything a pointer can hit **inside the list**, top to bottom then left to right.
        var targets: [NSView] {
            guard let documentView = scrollView?.documentView else { return [] }
            return Self.hitTargets(under: documentView)
        }

        /// The same for the header and the search row — everything outside the list. The field's
        /// own text machinery is excluded: a label and a line fragment are not controls.
        var chromeTargets: [NSView] {
            let field = searchField
            return Self.hitTargets(under: hosting).filter { view in
                guard view.enclosingScrollView == nil else { return false }
                guard let field else { return true }
                return !view.isDescendant(of: field)
            }
        }

        /// A control's left edge in window space, which is what indentation moves.
        func originX(of view: NSView) -> CGFloat { view.convert(view.bounds, to: nil).minX }

        func click(_ index: Int) {
            click(targets, index)
        }

        func clickChrome(_ index: Int) {
            click(chromeTargets, index)
        }

        private func click(_ all: [NSView], _ index: Int) {
            guard all.indices.contains(index) else {
                Issue.record("no target at \(index); there are \(all.count)")
                return
            }
            click(all[index])
        }

        /// A real left click in the middle of a control.
        ///
        /// Both events go straight to the window. `FormulaBarFieldTests` also *posts* a mouse-up to
        /// `NSApp` first, because an `NSTextView` runs its own tracking loop and sits there until
        /// it finds one; a SwiftUI `Button` does not, and the posted event is then never consumed —
        /// which killed the whole run at teardown, silently and with status 0, before this comment
        /// existed.
        private func click(_ target: NSView) {
            let centre = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
            let inWindow = target.convert(centre, to: nil)
            guard let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1
            ), let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 0
            ) else {
                Issue.record("could not synthesise a click")
                return
            }
            window.sendEvent(down)
            window.sendEvent(up)
            window.displayIfNeeded()
        }

        /// Leaf views with a real rectangle, deduplicated by that rectangle.
        ///
        /// Found by geometry rather than by class name: SwiftUI's focus and hit-test stand-ins are
        /// private types whose names move between releases, but their *rectangles* are the buttons.
        /// It puts two coincident ones behind each control, so counting views would count every
        /// control twice; counting rectangles counts controls. Progress indicators are dropped
        /// because a spinner is not a control here — it is what a control was replaced by.
        private static func hitTargets(under root: NSView) -> [NSView] {
            var byFrame: [String: NSView] = [:]
            for view in descendants(of: root) {
                guard view.subviews.isEmpty, !(view is NSProgressIndicator) else { continue }
                let frame = view.convert(view.bounds, to: nil)
                guard frame.width > 0, frame.height > 0 else { continue }
                let key = "\(frame)"
                if byFrame[key] == nil { byFrame[key] = view }
            }
            return byFrame.values.sorted { first, second in
                let a = first.convert(first.bounds, to: nil)
                let b = second.convert(second.bounds, to: nil)
                // Window space puts the origin at the bottom left, so the row nearer the top of
                // the list is the one with the *larger* maxY.
                if a.maxY != b.maxY { return a.maxY > b.maxY }
                return a.minX < b.minX
            }
        }

        static func descendants(of view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }
    }
}

/// Row shorthands, named for the situation they put a row in rather than for the fields they set.
extension FileExplorerRow {
    fileprivate static func root(_ id: String, _ name: String) -> FileExplorerRow {
        FileExplorerRow(id: id, name: name, depth: 0, kind: .root, isExpanded: true)
    }

    fileprivate static func folder(_ id: String, _ name: String, depth: Int = 0) -> FileExplorerRow {
        FileExplorerRow(id: id, name: name, depth: depth, kind: .folder)
    }

    fileprivate static func loadingFolder(_ id: String, _ name: String) -> FileExplorerRow {
        FileExplorerRow(id: id, name: name, depth: 0, kind: .folder, load: .loading)
    }

    fileprivate static func unreadableFolder(_ id: String, _ name: String) -> FileExplorerRow {
        FileExplorerRow(id: id, name: name, depth: 0, kind: .folder, load: .unreadable)
    }

    fileprivate static func workbook(_ id: String, _ name: String, depth: Int = 0) -> FileExplorerRow {
        FileExplorerRow(id: id, name: name, depth: depth, kind: .workbook)
    }

    fileprivate static func delimited(_ id: String, _ name: String) -> FileExplorerRow {
        FileExplorerRow(id: id, name: name, depth: 0, kind: .delimited)
    }

    fileprivate static func note(_ id: String, _ name: String) -> FileExplorerRow {
        FileExplorerRow(id: id, name: name, depth: 1, kind: .note)
    }

    fileprivate static func missingWorkbook(_ id: String, _ name: String) -> FileExplorerRow {
        FileExplorerRow(id: id, name: name, depth: 0, kind: .workbook, load: .missing)
    }
}
