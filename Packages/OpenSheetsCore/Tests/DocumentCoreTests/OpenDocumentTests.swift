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
/// # And the layer below them
///
/// Counting models is only half of it, and the half that keeps passing while the app is wrong: two
/// windows can host **one** `DocumentModel`, so `openDocuments.count == 1` says nothing about what
/// is on screen. The window scenarios below count windows instead, on real `NSWindow`s, through the
/// same ``DocumentCore/DocumentWindows`` rules the app runs at launch. Both layers are here rather
/// than in two files because it was the gap *between* them that hid a window bug.
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

    // MARK: - One window per file (the layer no test used to reach)

    /// A launch: macOS makes the `WindowGroup`'s default window — the launcher — and the file the
    /// launch named arrives in a second one. One window should survive, and it should be the file's.
    ///
    /// Measured, so the shape is the real one: the launcher is created first (lower `windowNumber`)
    /// and the document window a beat later, both at the same frame. Looking like one window is
    /// exactly why nothing caught this by looking.
    @Test func aLaunchLeavesExactlyOneDocumentWindow() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        stage.launcher()
        stage.document(at: "/files/budget.xlsx")

        stage.tidy()

        #expect(stage.documentWindowCount == 1, "the file's window is the one the launch asked for")
        #expect(stage.launcherCount == 0, "a launcher belongs on screen only when nothing else is")
    }

    /// Opening a file that is already open must not add a window — however macOS asked.
    ///
    /// The first half is the lookup the open path does: it finds the live window and fronts it. The
    /// second half is the belt to that brace — if a window for the file appeared anyway, the tidy
    /// pass takes it back off screen.
    @Test func reopeningAnAlreadyOpenFileLeavesOneWindow() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        let first = stage.document(at: "/files/budget.xlsx")

        #expect(
            stage.window(for: "/files/budget.xlsx") === first,
            "the open path has to find this window, or it opens a second one"
        )

        stage.document(at: "/files/budget.xlsx")
        stage.tidy()

        #expect(stage.documentWindowCount == 1)
        #expect(first.isVisible, "and it is the window the user was already looking at")
    }

    /// Two spellings of one path are one document — so they are one window, too.
    @Test func twoSpellingsOfOnePathAreOneWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("budget.xlsx")
        try Data().write(to: file)
        let link = directory.appendingPathComponent("alias.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let stage = WindowStage()
        defer { stage.tearDown() }
        stage.document(at: file.path)
        stage.document(at: link.path)

        stage.tidy()
        #expect(stage.documentWindowCount == 1)
    }

    /// One window *per file*, not one window in total. Tidying is not a licence to close the other
    /// document the user has open.
    @Test func twoFilesKeepTwoWindows() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        stage.document(at: "/files/budget.xlsx")
        stage.document(at: "/files/plan.xlsx")

        stage.tidy()
        #expect(stage.documentWindowCount == 2)
    }

    /// The duplicate that goes is the newer one, on every pass.
    ///
    /// `NSApp.windows` is in no order worth relying on, and an unordered tidy kept window A on one
    /// pass and window B on the next — closing both across two passes, which is how "one window"
    /// became "no windows". Two passes, one survivor, and it is the window the user has already
    /// seen.
    @Test func theWindowTheUserAlreadySawIsTheOneThatSurvives() {
        let stage = WindowStage()
        defer { stage.tearDown() }
        let first = stage.document(at: "/files/budget.xlsx")
        stage.document(at: "/files/budget.xlsx")

        stage.tidy()
        stage.tidy()

        #expect(stage.documentWindowCount == 1)
        #expect(stage.window(for: "/files/budget.xlsx") === first)
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
        stage.document(at: "/files/budget.xlsx")

        stage.tidy()
        #expect(stranger.isVisible, "no marker, no opinion")
        #expect(stage.documentWindowCount == 1)
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
            description: "two files in argv open two windows, in order",
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

    /// Everything a launch was handed is offered to the opener in the order it was given, so two
    /// files on one command line become two windows rather than one and a shrug.
    @Test func argumentOrderIsTheOrderWindowsOpenIn() {
        let launch = LaunchArguments(["/A/OpenSheets", "/b.xlsx", "/a.xlsx"])
        #expect(launch.files(existingAt: { _ in true }).map(\.path) == ["/b.xlsx", "/a.xlsx"])
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
        func document(at path: String) -> NSWindow { window(marking: path) }

        @discardableResult
        func launcher() -> NSWindow { window(marking: nil) }

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

        var documentWindowCount: Int { DocumentWindows.documents(in: mine).count }

        var launcherCount: Int { DocumentWindows.launchers(in: mine).count }

        func window(for path: String) -> NSWindow? {
            DocumentWindows.window(for: DocumentWindows.identity(for: URL(fileURLWithPath: path)), in: mine)
        }

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

        private func window(marking path: String?) -> NSWindow {
            let window = bareWindow()
            let content = NSView(frame: .zero)
            content.addSubview(NSView(frame: .zero))
            content.subviews[0].addSubview(WindowRoleView(path: path))
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
