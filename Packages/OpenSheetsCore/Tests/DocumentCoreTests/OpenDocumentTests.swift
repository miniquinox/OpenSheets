import AppKit
import DocumentCore
import Foundation
import SheetFormat
import SheetModel
import SheetStore
import TestSupport
import Testing

/// What happens when a file is opened — once, twice, or five times at the same instant — and what
/// opening it does to the workspace grants.
///
/// # Why this suite exists
///
/// A8's acceptance criterion was *"the same file open twice shares one `DocumentModel`"*, and the
/// implementation looked like it held: ``DocumentCore/AppModel`` keeps a weak table of open
/// documents and returns the live one. It held only for opens that did not overlap. The lookup
/// happens before two `await`s, so five windows asking in the same run-loop turn all saw "nothing
/// open" and the file ended up with five models, five sessions and five watchers — which is what
/// five stray windows on screen actually meant, and what would have turned a save into data loss.
///
/// A criterion nothing checks is a comment. These are the checks.
///
/// # And the layers below them
///
/// Counting models is only part of it, and the part that keeps passing while the app is wrong: what
/// is on screen is a different count. There are now two layers under this one and both are here.
///
/// **Tabs** are where "one of these per file" is enforced now — files are tabs in a single
/// workspace window (§1.1), so the scenarios that used to say "one window per file" say "one tab
/// per file" and run against ``DocumentCore/TabsModel``. **Windows** are the blunter rule that is
/// left: one workspace, and a launcher only when the workspace is not open. Those run on real
/// `NSWindow`s through the same ``DocumentCore/DocumentWindows`` rules the app runs at launch.
///
/// All three layers are in one file rather than three because it was the gap *between* them that
/// hid a window bug: the model-level count stayed right while the screen was wrong.
@Suite(.serialized)
@MainActor
struct OpenDocumentTests {
    // MARK: - One model per file

    @Test func theSameFileOpenedTwiceSharesOneDocumentModel() async throws {
        let harness = try await Harness(autoRefresh: nil)
        let again = try await harness.app.openDocument(at: harness.url)

        #expect(again === harness.model)
        #expect(harness.app.openDocuments.count == 1)
        harness.close()
    }

    /// The same file reached by two spellings of one path is still one document.
    @Test func aSymlinkedPathIsTheSameDocument() async throws {
        let harness = try await Harness(autoRefresh: nil)
        let link = harness.directory.appendingPathComponent("alias.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: harness.url)

        let again = try await harness.app.openDocument(at: link)
        #expect(again === harness.model)
        #expect(harness.app.openDocuments.count == 1)
        harness.close()
    }

    /// The one the window bug was made of: five opens started before any of them finishes.
    ///
    /// Without the in-flight table this fails with five distinct models — and it fails the same
    /// way whether the five requests came from five windows, five drops, or `open(1)` pointed at
    /// the same file five times, which is exactly how it was hit.
    @Test func fiveSimultaneousOpensOfOneFileShareOneDocumentModel() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "contended.xlsx")
        let app = AppModel(store: try Harness.makeStore())

        // Five tasks created before any of them runs. They inherit the main actor from this
        // test, so each one gets as far as `openDocument`'s first suspension before the next
        // starts — which is precisely the interleaving five windows produce.
        let attempts = (0 ..< 5).map { _ in
            Task { try await app.openDocument(at: url, consent: .userSelectedInPanel) }
        }
        var models: [DocumentModel] = []
        for attempt in attempts { models.append(try await attempt.value) }

        #expect(models.count == 5, "every caller should get a model, not an error")
        #expect(Set(models.map(ObjectIdentifier.init)).count == 1, "and it should be the same one")
        #expect(app.openDocuments.count == 1, "one file, one session, one watcher")
        for model in models { app.closeDocument(model) }
        scratch.remove()
    }

    /// Closing the document really does forget it, so the next open is a fresh one rather than a
    /// resurrected model whose session has already been stopped.
    @Test func closingForgetsTheDocument() async throws {
        let harness = try await Harness(autoRefresh: nil)
        harness.close()
        #expect(harness.app.openDocuments.isEmpty)
    }

    // MARK: - One tab per file (what "one window per file" became)

    /// Opening a file that is already open must not add a tab — however it was asked for.
    ///
    /// This is the same criterion `reopeningAnAlreadyOpenFileLeavesOneWindow` used to assert, moved
    /// down a layer with the thing it is about: there is no per-file window left to find, so the
    /// lookup that keeps "open the same file five times" honest is ``DocumentCore/TabsModel``'s.
    @Test func reopeningAnAlreadyOpenFileLeavesOneTab() async throws {
        let spy = try TabsModelTests.Spy()
        let tabs = spy.makeTabs()
        let url = URL(fileURLWithPath: "/files/budget.xlsx")

        await tabs.open(url, consent: .fromOutsideTheApp)
        await tabs.open(url, consent: .fromOutsideTheApp)

        #expect(tabs.tabs.count == 1)
        #expect(tabs.activeTabID == AppModel.documentKey(for: url))
        #expect(spy.opened.count == 1, "and the second ask did not start a second open")
    }

    /// Two spellings of one path are one document — so they are one tab, too.
    @Test func twoSpellingsOfOnePathAreOneTab() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("budget.xlsx")
        try Data().write(to: file)
        let link = directory.appendingPathComponent("alias.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let spy = try TabsModelTests.Spy()
        let tabs = spy.makeTabs()
        await tabs.open(file, consent: .fromOutsideTheApp)
        await tabs.open(link, consent: .fromOutsideTheApp)

        #expect(tabs.tabs.count == 1, "the tab layer has to resolve paths the way the model layer does")
    }

    /// Everything a launch was handed becomes a tab, in the order it was given.
    ///
    /// `argumentOrderIsTheOrderWindowsOpenIn`, one layer down: two files on one command line used
    /// to be two windows and are now two tabs, and the order is still the user's.
    @Test func argumentOrderIsTheOrderTabsOpenIn() async throws {
        let launch = LaunchArguments(["/A/OpenSheets", "/files/b.xlsx", "/files/a.xlsx"])
        let spy = try TabsModelTests.Spy()
        let tabs = spy.makeTabs()

        for url in launch.files(existingAt: { _ in true }) {
            await tabs.open(url, consent: .fromOutsideTheApp)
        }

        #expect(tabs.tabs.map(\.url.lastPathComponent) == ["b.xlsx", "a.xlsx"])
        #expect(tabs.activeTabID == AppModel.documentKey(for: URL(fileURLWithPath: "/files/a.xlsx")))
    }

    // MARK: - One workspace window (the layer no test used to reach)

    /// A launch: macOS makes the `WindowGroup`'s default window — the launcher — and the workspace
    /// arrives in a second one. One window should survive, and it should be the workspace.
    ///
    /// Measured, so the shape is the real one: the launcher is created first (lower `windowNumber`)
    /// and the workspace window a beat later, both at the same frame. Looking like one window is
    /// exactly why nothing caught this by looking.
    @Test func aLaunchLeavesExactlyOneWorkspaceWindow() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        stage.launcher()
        stage.workspace()

        stage.tidy()

        #expect(stage.workspaceCount == 1, "the workspace is the window the launch asked for")
        #expect(stage.launcherCount == 0, "a launcher belongs on screen only when nothing else is")
    }

    /// Two files, one window. This is `twoFilesKeepTwoWindows` inverted, and it is the whole shape
    /// change: a second file is a second *tab*, so a second workspace window is a window nobody
    /// asked for — two of them would mean two tab strips writing over each other's `workspace.tabs`.
    @Test func twoFilesShareOneWorkspaceWindow() async throws {
        let spy = try TabsModelTests.Spy()
        let tabs = spy.makeTabs()
        await tabs.open(URL(fileURLWithPath: "/files/budget.xlsx"), consent: .fromOutsideTheApp)
        await tabs.open(URL(fileURLWithPath: "/files/plan.xlsx"), consent: .fromOutsideTheApp)

        let stage = WindowStage()
        defer { stage.tearDown() }
        stage.workspace()
        stage.tidy()

        #expect(tabs.tabs.count == 2, "two files")
        #expect(stage.workspaceCount == 1, "one window")
    }

    /// The duplicate that goes is the newer one, on every pass.
    ///
    /// `NSApp.windows` is in no order worth relying on, and an unordered tidy kept window A on one
    /// pass and window B on the next — closing both across two passes, which is how "one window"
    /// became "no windows". Two passes, one survivor, and it is the window the user has already
    /// seen.
    @Test func theWorkspaceTheUserAlreadySawIsTheOneThatSurvives() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        let first = stage.workspace()
        stage.workspace()

        stage.tidy()
        stage.tidy()

        #expect(stage.workspaceCount == 1)
        #expect(first.isVisible, "and it is the window the user was already looking at")
    }

    /// The launcher is not a window nobody asked for when it is the only one there is.
    @Test func theLauncherStaysWhenNothingElseIsOpen() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        stage.launcher()

        stage.tidy()
        #expect(stage.launcherCount == 1)
    }

    /// A second launcher is one macOS manufactured — on a dock click, or `open(1)` against a
    /// running copy — and it goes.
    @Test func aSecondLauncherIsClosed() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        let first = stage.launcher()
        stage.launcher()

        stage.tidy()
        #expect(stage.launcherCount == 1)
        #expect(first.isVisible)
    }

    /// Windows that are not ours are not ours to close — an alert or a panel is nobody's duplicate.
    @Test func anUnmarkedWindowIsLeftAlone() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        let stranger = stage.unmarked()
        stage.workspace()

        stage.tidy()
        #expect(stranger.isVisible, "no marker, no opinion")
        #expect(stage.workspaceCount == 1)
    }

    // MARK: - Opening a file grants its folder (PLAN.md §1.1)

    @Test func openingFromAPanelGrantsTheParentFolderWithoutAskingAgain() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "budget.xlsx")
        let app = AppModel(store: try Harness.makeStore())
        let asked = Counter()
        app.confirmWorkspaceGrant = { _ in
            asked.bump()
            return true
        }

        #expect(app.grants.isEmpty, "the point of the test is that this starts empty")
        let model = try await app.openDocument(at: url, consent: .userSelectedInPanel)

        #expect(asked.value == 0, "the panel was the consent gesture; asking twice is nagging")
        #expect(app.grants.map(\.path).contains { $0.hasSuffix(scratch.url.lastPathComponent) })
        #expect(app.store.grants.isAllowed(url))
        // …and the user is told, in the panel that already shows the workspace path.
        #expect(model.feed.contains { $0.summary.contains("Granted") }, "a silent grant is the bug")
        app.closeDocument(model)
        scratch.remove()
    }

    @Test func openingAFileFromOutsideTheAppAsksFirst() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "dropped.xlsx")
        let app = AppModel(store: try Harness.makeStore())
        let asked = Counter()
        app.confirmWorkspaceGrant = { _ in
            asked.bump()
            return true
        }

        let model = try await app.openDocument(at: url, consent: .fromOutsideTheApp)
        #expect(asked.value == 1)
        #expect(app.store.grants.isAllowed(url))
        app.closeDocument(model)
        scratch.remove()
    }

    @Test func sayingNoLeavesNoGrantAndNoDocument() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "refused.xlsx")
        let app = AppModel(store: try Harness.makeStore())
        app.confirmWorkspaceGrant = { _ in false }

        await #expect(throws: SheetError.self) {
            _ = try await app.openDocument(at: url, consent: .fromOutsideTheApp)
        }
        #expect(app.grants.isEmpty)
        #expect(!app.store.grants.isAllowed(url))
        #expect(app.openDocuments.isEmpty)
        scratch.remove()
    }

    /// No hook installed is the same answer as "no". A permission that is granted because nobody
    /// wired up the question is a permission nobody granted.
    @Test func noConfirmationHookRefusesRatherThanGrants() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "unasked.xlsx")
        let app = AppModel(store: try Harness.makeStore())

        await #expect(throws: SheetError.self) {
            _ = try await app.openDocument(at: url, consent: .fromOutsideTheApp)
        }
        #expect(app.grants.isEmpty)
        scratch.remove()
    }

    /// A folder that is already granted is never asked about again, however the file arrives.
    @Test func anAlreadyGrantedFolderIsNotAskedAboutAgain() async throws {
        let scratch = try Scratch()
        let first = try scratch.writeWorkbook(named: "one.xlsx")
        let second = try scratch.writeWorkbook(named: "two.xlsx")
        let app = AppModel(store: try Harness.makeStore())
        let asked = Counter()
        app.confirmWorkspaceGrant = { _ in
            asked.bump()
            return true
        }

        let one = try await app.openDocument(at: first, consent: .fromOutsideTheApp)
        let two = try await app.openDocument(at: second, consent: .fromOutsideTheApp)
        #expect(asked.value == 1)
        #expect(two.feed.contains { $0.summary.contains("Granted") } == false, "said once, not per file")
        app.closeDocument(one)
        app.closeDocument(two)
        scratch.remove()
    }

    // MARK: - Cold launch

    /// Every shape a cold launch arrives in, and what each one owes the user.
    ///
    /// There are two ways to hand macOS a file and they do not meet. `open -a OpenSheets f.xlsx`
    /// sends an Apple Event and leaves `argv` empty; `open OpenSheets --args f.xlsx` fills `argv`
    /// and sends no event. Both have to end with exactly one window on that file.
    ///
    /// The second produced **zero** windows, and the cause was not this app's window bookkeeping —
    /// the tidy pass never ran, because no scene was ever created. A bare `argv` token is enough on
    /// its own to make SwiftUI skip the `WindowGroup`'s default window, and nothing read `argv` to
    /// make up the difference, so the app came up with an empty Window menu. Both halves are in
    /// this table: which files a launch names, and whether it leaves macOS owing us a window.
    struct LaunchScenario: Sendable, CustomStringConvertible {
        var description: String
        /// `argv`, executable path included, exactly as the process would see it.
        var argv: [String]
        /// Which of those are files to open, as indices into the launch's own bare arguments.
        var opens: [String]
        /// Whether SwiftUI will refuse the default window, so the app has to ask for one.
        var owesAWindow: Bool
    }

    nonisolated static let launchScenarios: [LaunchScenario] = [
        LaunchScenario(
            description: "open -a OpenSheets budget.xlsx — the file comes by Apple Event",
            argv: ["/A/OpenSheets"], opens: [], owesAWindow: false
        ),
        LaunchScenario(
            description: "open OpenSheets --args budget.xlsx — the file comes by argv",
            argv: ["/A/OpenSheets", "/files/budget.xlsx"],
            opens: ["/files/budget.xlsx"], owesAWindow: true
        ),
        LaunchScenario(
            description: "two files in argv open two tabs, in order",
            argv: ["/A/OpenSheets", "/files/budget.xlsx", "/files/plan.xlsx"],
            opens: ["/files/budget.xlsx", "/files/plan.xlsx"], owesAWindow: true
        ),
        LaunchScenario(
            description: "a plain launch with no arguments at all",
            argv: ["/A/OpenSheets"], opens: [], owesAWindow: false
        ),
        // Measured: this shape comes up with one window, so `YES` was eaten and nothing is bare.
        LaunchScenario(
            description: "a defaults flag and its value are AppKit's, and neither is a file",
            argv: ["/A/OpenSheets", "-NSDocumentRevisionsDebugMode", "YES"],
            opens: [], owesAWindow: false
        ),
        // Measured: no window, so `/files/budget.xlsx` survived `-AppleLanguages (en)`.
        LaunchScenario(
            description: "a flag pair before a file leaves the file",
            argv: ["/A/OpenSheets", "-AppleLanguages", "(en)", "/files/budget.xlsx"],
            opens: ["/files/budget.xlsx"], owesAWindow: true
        ),
        // Measured: no window. A flag eats the token after it even when that token is a flag, so
        // `-one` ate `-two` and the file is still there to open. Reading it the other way would
        // have this launch come up empty.
        LaunchScenario(
            description: "two flags in a row: the first eats the second, and the file survives",
            argv: ["/A/OpenSheets", "-one", "-two", "/files/budget.xlsx"],
            opens: ["/files/budget.xlsx"], owesAWindow: true
        ),
        LaunchScenario(
            description: "an argument naming nothing opens nothing — but still owes a window",
            argv: ["/A/OpenSheets", "/files/missing.xlsx"], opens: [], owesAWindow: true
        ),
        // Measured: `open OpenSheets --args ""` comes up with no window too.
        LaunchScenario(
            description: "an empty argument opens nothing and still suppresses the window",
            argv: ["/A/OpenSheets", ""], opens: [], owesAWindow: true
        ),
    ]

    @Test(arguments: launchScenarios)
    func aColdLaunchOpensWhatItWasGivenAndAsksForAWindowWhenItHasTo(scenario: LaunchScenario) {
        let onDisk: Set<String> = ["/files/budget.xlsx", "/files/plan.xlsx"]
        let launch = LaunchArguments(scenario.argv)

        #expect(
            launch.files(existingAt: { onDisk.contains($0) }).map(\.path) == scenario.opens,
            "\(scenario.description): opened \(launch.files(existingAt: { onDisk.contains($0) }).map(\.path))"
        )
        // The half that was actually broken. `false` here on an argv launch is the zero-window
        // bug: SwiftUI makes no default window, so nobody ever installs `openWindow`, so the
        // queued file never opens either.
        #expect(
            launch.suppressesTheDefaultWindow == scenario.owesAWindow,
            "\(scenario.description): owesAWindow should be \(scenario.owesAWindow)"
        )
    }

    /// The argument-domain rule, stated on its own because it is the reason `argv` cannot simply
    /// be filtered on a leading `-`: `-NSDocumentRevisionsDebugMode YES` would open a file called
    /// `YES`, and `--args` launches from Xcode carry exactly that pair.
    @Test func aFlagsValueIsNeverMistakenForAFile() {
        let launch = LaunchArguments(["/A/OpenSheets", "-Flag", "value", "real"])
        #expect(launch.bareArguments == ["real"])
    }

    // MARK: - Scaffolding

    /// Real windows, marked the way the app marks them, so the assertions are about
    /// `NSApp.windows` rather than about a model of it.
    ///
    /// The marker is *nested* inside the content view rather than being it, because that is where
    /// SwiftUI puts it — `.background(WindowRegistrar(…))` lands somewhere inside the hosting
    /// view — and a search that only looked at the content view would find nothing, decide the app
    /// has no windows of its own, and tidy nothing at all.
    @MainActor
    final class WindowStage {
        private var made: [NSWindow] = []

        init() { _ = NSApplication.shared }

        @discardableResult
        func workspace() -> NSWindow { window(marking: .workspace) }

        @discardableResult
        func launcher() -> NSWindow { window(marking: .launcher) }

        /// A window with no mark on it: something AppKit or a framework put on screen.
        @discardableResult
        func unmarked() -> NSWindow {
            let window = bareWindow()
            window.contentView = NSView(frame: .zero)
            window.orderFront(nil)
            return window
        }

        /// What the app does on every change: ask which windows nobody asked for, and close them.
        func tidy() {
            for window in DocumentWindows.extras(in: mine) { window.close() }
        }

        var workspaceCount: Int { DocumentWindows.workspaces(in: mine).count }

        var launcherCount: Int { DocumentWindows.launchers(in: mine).count }

        func tearDown() {
            for window in made { window.close() }
            made = []
        }

        /// Only the windows this stage made — `NSApp.windows` in a test process belongs to
        /// whatever else is running in it, and a suite that closed those would be a suite with a
        /// temper — and handed over **newest first**.
        ///
        /// The order is the point. `NSApp.windows` is in no order worth relying on, and a tidy pass
        /// that trusted it kept window A on one pass and window B on the next. Giving these back in
        /// the most inconvenient order there is means the rules have to do their own sorting to
        /// pass, which is the only way this suite can tell that they still do.
        private var mine: [NSWindow] { made.reversed() }

        private func window(marking role: WindowRole) -> NSWindow {
            let window = bareWindow()
            let content = NSView(frame: .zero)
            content.addSubview(NSView(frame: .zero))
            content.subviews[0].addSubview(WindowRoleView(role: role))
            window.contentView = content
            window.orderFront(nil)
            return window
        }

        /// Borderless and fully transparent: these windows are real enough for `isVisible` and
        /// `windowNumber`, which is all the rules read, without flashing over whatever the person
        /// running the tests is looking at.
        private func bareWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.alphaValue = 0
            window.isReleasedWhenClosed = false
            made.append(window)
            return window
        }
    }

    /// A temporary folder holding real `.xlsx` bytes, so the grant under test is a grant on a
    /// folder that exists.
    @MainActor
    struct Scratch {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensheets-open-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func writeWorkbook(named name: String) throws -> URL {
            let target = url.appendingPathComponent(name)
            let workbook = try Harness.seedWorkbook(1)
            var tracker = WorkbookEditTracker()
            for sheet in workbook.sheets { tracker.noteSheetReplaced(sheet) }
            try XLSXWriter.data(for: workbook, edits: tracker).write(to: target)
            return target
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    /// A counter the `@Sendable` confirmation hook can bump.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func bump() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}
