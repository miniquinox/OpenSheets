import AppKit
import DocumentCore
import GlassUI
import SheetModel
import SwiftUI
import UniformTypeIdentifiers

/// The app.
///
/// # Why a `WindowGroup` and not a `DocumentGroup`
///
/// `DocumentGroup` owns the file. It reads it, it writes it, it decides when the document is dirty
/// and it presents its own answer to an external change — all of which this app already does,
/// differently and on purpose. PLAN.md §6 is a file-sync engine with a nine-state machine, a
/// watcher on both the file descriptor and the parent directory, self-write suppression and
/// gzipped snapshots. Handing the file to `DocumentGroup` would mean fighting it at every one of
/// those points, and the first fight is the one that matters: `DocumentGroup` reloads on an
/// external change without asking, which is the exact behaviour §1.3 exists to replace.
///
/// So: a `WindowGroup` over a value we open ourselves, with ``DocumentCore/AppModel`` owning the
/// store and each window owning its ``DocumentCore/DocumentModel``. The costs are real and are
/// paid explicitly — `Open Recent`, window restoration and the unsaved-changes prompt are ours to
/// build, and they are in `DocumentCommands.swift`.
///
/// # One launcher, one window per file
///
/// A single launch used to put five document windows and five launchers on screen for one file:
/// five `DocumentModel`s, five watchers and five sync state machines racing over one path, which
/// is how a save becomes data loss. Three separate things were multiplying, and all three are
/// closed here rather than capped:
///
/// 1. **Scene restoration.** SwiftUI remembers a `WindowGroup(for:)`'s presented values and
///    re-creates a window for each of them at launch, on top of whatever the launch itself asked
///    for. `.restorationBehavior(.disabled)` above; window restoration is a later version's
///    feature (PLAN.md), and a half-restored launch is worse than none.
/// 2. **A second window on the same file.** ``OpenActions`` keeps a registry of what is on
///    screen and fronts the existing window instead of opening another. Belt and braces with
///    ``DocumentCore/AppModel``, which refuses to build a second `DocumentModel` for one path
///    however many callers ask at once.
/// 3. **A second launcher.** The launcher is the group's `nil` case, so macOS can manufacture one
///    whenever it decides the app needs a default window — at launch, on reopen, on `open(1)`
///    against a running copy. ``OpenActions`` reads the live window list after every change and
///    closes the ones nobody asked for.
///
/// Each of those is asserted somewhere that runs: the model-level ones in
/// `DocumentCoreTests.OpenDocumentTests`, the window-level ones by launching the app cold.
@main
struct OpenSheetsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.standard()
    @State private var appearance = AccessibilityAppearance()

    var body: some Scene {
        WindowGroup(id: OpenActions.sceneID, for: DocumentWindowRequest.self) { request in
            RootView(request: request.wrappedValue, app: app, appearance: appearance)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 820)
        // SwiftUI restores a `WindowGroup(for:)`'s presented values at launch: it re-creates a
        // window per value it remembers *and* hands remembered values to windows that were
        // already on screen. That is what turned one launch into several document windows with a
        // launcher beside each — restoration racing the file argument, and neither path checking
        // whether the file was already open. PLAN puts real window restoration in a later
        // version; until it is built, launching is deterministic rather than half-remembered.
        .restorationBehavior(.disabled)
        .commands { DocumentCommands(app: app) }

        Settings {
            PreferencesView(app: app)
                .glassAppearance(appearance.context(for: .light))
        }
    }
}

/// Handles the openings SwiftUI does not: Finder, the dock icon, and `open(1)`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Design tooling, not a preference. The screenshots in `docs/design/` have to show
            // both themes on one machine, and toggling System Settings between captures is not
            // something a script can do. `OPENSHEETS_APPEARANCE=light|dark` pins this process's
            // appearance; unset, the app follows the system, which is the only behaviour anyone
            // shipping gets.
            switch ProcessInfo.processInfo.environment["OPENSHEETS_APPEARANCE"] {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            // On a cold launch this arrives *before* any scene has appeared, so there is nothing
            // to call `openWindow` on yet. `OpenActions` queues rather than dropping — a file
            // argument that silently does nothing is worse than one that opens a moment late.
            for url in urls { OpenActions.open(url, consent: .fromOutsideTheApp) }
        }
    }

    /// A dock click, or `open(1)` against an already-running copy.
    ///
    /// `false` means *handled, do nothing more*. Saying it when windows already exist is what
    /// keeps AppKit — and through it SwiftUI — from deciding the app needs another default window
    /// on every single reopen. When there are no windows, the launcher is what should come back,
    /// and it is asked for by name rather than left to whatever the framework considers default.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard !flag else { return false }
            // Returning `true` when we could not is deliberate: at launch there is no scene to
            // ask yet, and suppressing AppKit's default there would leave the app with no window
            // at all — which is a worse bug than the one this method is here to prevent.
            return !OpenActions.showLauncher()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// What a window is opened for.
///
/// The path and nothing else, deliberately: this value **is** the window's identity to SwiftUI, so
/// anything added here splits one file across two windows. How the open was requested travels
/// beside it in ``OpenActions``, not inside it.
struct DocumentWindowRequest: Codable, Hashable, Sendable {
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// Resolves a request into a live document.
///
/// The open is asynchronous — parsing a million-cell workbook is not something to do on the main
/// thread — so the window shows a quiet loading state rather than a beachball, and a failure lands
/// in a designed empty state rather than an `NSAlert` (PLAN.md §1.4).
struct RootView: View {
    let request: DocumentWindowRequest?
    let app: AppModel?
    let appearance: AccessibilityAppearance

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var model: DocumentModel?
    @State private var failure: SheetError?

    private var context: AppearanceContext { appearance.context(for: colorScheme) }

    var body: some View {
        Group {
            if let app, let model {
                DocumentWindow(model: model, app: app, appearance: appearance)
            } else if let failure {
                EmptyStateView(
                    model: .unreadable(detail: "\(failure.code): \(failure.message)"),
                    context: context
                ) { _ in }
                .frame(minWidth: 720, minHeight: 480)
                .gridPlane(context)
            } else if request == nil {
                LauncherScene(app: app, appearance: appearance)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: 720, minHeight: 480)
                    .gridPlane(context)
            }
        }
        .glassAppearance(context)
        .background(WindowRegistrar(path: request?.path))
        .onDisappear { OpenActions.windowsChanged() }
        .onAppear {
            OpenActions.install(openWindow: openWindow)
            OpenActions.attach(app)
            // Re-fires when a closed window is shown again, which nothing else does — and macOS
            // shows the default window again on every `open(1)` against a running copy.
            OpenActions.windowsChanged()
        }
        .task(id: request) { await load() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            OpenActions.handleDrop(providers)
        }
    }

    private func load() async {
        guard let app, let request, model == nil else { return }
        // Installed here as well as in `onAppear`, because the ordering of the two is SwiftUI's
        // business and a missing hook means a refused open rather than a silent grant.
        OpenActions.attach(app)
        do {
            model = try await app.openDocument(at: request.url, consent: OpenActions.consent(for: request.url))
        } catch {
            failure = error
        }
    }
}

/// Marks the window this view landed in as the launcher or as a document, so ``OpenActions`` can
/// tell them apart by looking at `NSApp.windows`.
///
/// # Why a marker and not a registry
///
/// There was a registry, keyed by path, filled from `viewDidMoveToWindow`. It kept going stale:
/// SwiftUI moves views between windows while a window lives on, closes and re-shows the same
/// window without telling anyone, and re-presents a scene whose window we thought we had closed.
/// Every one of those left the bookkeeping describing a world that no longer existed, and the
/// symptom was a stray window nothing would close.
///
/// `NSApp.windows` cannot go stale — it *is* the world. So the only thing kept per window is what
/// the window is *for*, carried by a view that is in the hierarchy exactly as long as the content
/// it describes.
final class WindowRoleView: NSView {
    /// `nil` marks the launcher.
    var path: String?

    init(path: String?) {
        self.path = path
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }
}

private struct WindowRegistrar: NSViewRepresentable {
    let path: String?

    func makeNSView(context: Context) -> NSView { WindowRoleView(path: path) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The same view is reused when the request changes from `nil` to a file — which is what
        // happens when the launcher's window is handed a document — so the mark has to follow it.
        (nsView as? WindowRoleView)?.path = path
    }
}

/// Opening files from every entry point: the menu, the dock, Finder, and a drop on a window.
///
/// Centralised because two rules have to be true of *all* of them, and each is one forgotten call
/// site away from not being:
///
/// 1. **One window per file.** ``open(_:consent:)`` looks at what is already on screen and fronts
///    that window rather than opening a second one. Two windows on one file would mean two
///    `DocumentModel`s, two watchers and two opinions about whether the document is dirty —
///    ``DocumentCore/AppModel`` refuses to build the second model, so the second window would sit
///    there loading forever even if it were harmless, which it is not.
/// 2. **Opening a file grants its parent folder** (PLAN.md §1.1), because the app is the only
///    thing that can — neither CLI binary links AppKit. Doing it in one place means drag-and-drop
///    and `Open Recent` get the same treatment as `Open…`. What differs between them is whether
///    the gesture was consent enough on its own: see ``DocumentCore/WorkspaceConsent``.
@MainActor
enum OpenActions {
    /// The one scene's id, so ``showLauncher()`` can ask for a default (launcher) window by name.
    static let sceneID = "main"

    /// Set by whichever window appears first, because `openWindow` is an environment value and
    /// this is not a view.
    private static var openWindow: OpenWindowAction?
    /// URLs handed to us before any scene existed — the cold-launch file argument, which arrives
    /// during `application(_:open:)` and would otherwise be dropped on the floor.
    private static var queued: [(URL, WorkspaceConsent)] = []
    /// How each pending or open document was asked for. Not part of `DocumentWindowRequest`,
    /// because that value is the window's identity.
    private static var consents: [String: WorkspaceConsent] = [:]

    /// Gives the model the one thing only the app target can supply: a panel.
    static func attach(_ app: AppModel?) {
        guard let app, app.confirmWorkspaceGrant == nil else { return }
        app.confirmWorkspaceGrant = { folder in await confirmWorkspaceGrant(folder) }
    }

    static func install(openWindow action: OpenWindowAction) {
        openWindow = action
        let pending = queued
        queued = []
        for (url, consent) in pending { open(url, consent: consent) }
    }

    /// Brings the launcher back, or reports that it could not so the caller can let AppKit try.
    @discardableResult
    static func showLauncher() -> Bool {
        if let existing = launcherWindows.first {
            existing.makeKeyAndOrderFront(nil)
            return true
        }
        guard let openWindow else { return false }
        openWindow(id: sceneID)
        return true
    }

    static func open(_ url: URL, consent: WorkspaceConsent = .fromOutsideTheApp) {
        let identity = key(for: url)
        // Already on screen: front it. This is the line that turns "open the same file five
        // times" into one window rather than five.
        if let existing = documentWindow(for: identity) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            tidyWindows()
            return
        }
        consents[identity] = consent
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        guard let openWindow else {
            queued.append((url, consent))
            return
        }
        openWindow(value: DocumentWindowRequest(path: url.path(percentEncoded: false)))
    }

    /// How `url` was asked for, for the grant decision. Defaults to the careful answer.
    static func consent(for url: URL) -> WorkspaceConsent {
        consents[key(for: url)] ?? .fromOutsideTheApp
    }

    /// A window has arrived, or the launcher has been shown again. Either way, put the set of
    /// windows back the way it should be.
    static func windowsChanged() {
        // Next turn of the run loop: a window that has just appeared is not `isVisible` yet
        // while its content view is still being installed, and a tidy that runs then cannot see
        // the window it is meant to be tidying.
        Task { tidyWindows() }
    }

    /// **One launcher, and only when nothing else is open. One window per file.**
    ///
    /// Read off `NSApp.windows` every time rather than from bookkeeping of our own, because the
    /// list of windows is the only description of the windows that cannot be wrong. macOS asks a
    /// `WindowGroup` for its default window whenever it decides the app needs one — at launch, on
    /// a dock click, on `open(1)` against a running copy — and each of those used to leave another
    /// launcher behind.
    private static func tidyWindows() {
        let documents = documentWindows()
        var seen: Set<String> = []
        for (identity, window) in documents {
            // Two windows on one file would mean two of everything downstream. The first one
            // stays; anything after it is a duplicate macOS made, not one the user asked for.
            if !seen.insert(identity).inserted { dismiss(window) }
        }
        // A launcher belongs on screen only when nothing else is.
        var keptLauncher = !documents.isEmpty
        for window in launcherWindows {
            if keptLauncher {
                dismiss(window)
            } else {
                keptLauncher = true
            }
        }
    }

    /// Oldest first. The order matters: ``tidyWindows()`` keeps the first of any duplicate set,
    /// and `NSApp.windows` is in no order worth relying on — so on one pass it would keep window
    /// A and close B, and on the next keep B and close A, which is how "one window" became "no
    /// windows". `windowNumber` rises with creation, so oldest-first is the same answer every
    /// time, and the window the user has already seen is the one that survives.
    private static var launcherWindows: [NSWindow] {
        NSApp.windows
            .filter { window in
                guard window.isVisible, let role = roleView(in: window.contentView) else { return false }
                return role.path == nil
            }
            .sorted { $0.windowNumber < $1.windowNumber }
    }

    private static func documentWindows() -> [(String, NSWindow)] {
        NSApp.windows
            .sorted { $0.windowNumber < $1.windowNumber }
            .compactMap { window in
                guard window.isVisible, let path = roleView(in: window.contentView)?.path else { return nil }
                return (key(for: URL(fileURLWithPath: path)), window)
            }
    }

    private static func documentWindow(for identity: String) -> NSWindow? {
        documentWindows().first { $0.0 == identity }?.1
    }

    private static func roleView(in view: NSView?) -> WindowRoleView? {
        guard let view else { return nil }
        if let marker = view as? WindowRoleView { return marker }
        for subview in view.subviews {
            if let marker = roleView(in: subview) { return marker }
        }
        return nil
    }

    /// Closes a window nobody asked for, on the next turn of the run loop.
    ///
    /// Not immediately: SwiftUI orders a new window front *after* its content view is installed,
    /// so a `close()` from inside that pass is quietly undone a moment later. One frame of a
    /// window that should not exist is the price of it going away at all.
    private static func dismiss(_ window: NSWindow) {
        Task { window.close() }
    }

    /// The same key ``DocumentCore/AppModel`` uses, so the two cannot disagree about whether a
    /// file is already open.
    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }

    static func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = OpenActions.readableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        // The panel *is* the consent gesture: the user navigated into that folder and picked a
        // file in it a moment ago. See ``DocumentCore/WorkspaceConsent``.
        for url in panel.urls { open(url, consent: .userSelectedInPanel) }
    }

    static let readableTypes: [UTType] = [
        UTType(filenameExtension: "xlsx"),
        UTType(filenameExtension: "xlsm"),
        .commaSeparatedText,
        UTType(filenameExtension: "tsv"),
    ].compactMap { $0 }

    static func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                // A drop says "show me this"; it does not say "and hand an agent the folder it
                // came from". If that folder is not granted yet, the user is asked.
                Task { @MainActor in open(url, consent: .fromOutsideTheApp) }
            }
        }
        return handled
    }

    /// The question asked before a folder is granted for a file the user did not pick in one of
    /// our panels. Installed on ``DocumentCore/AppModel`` at launch.
    ///
    /// Modal on purpose. It is a permission prompt — the folder it names becomes readable *and
    /// writable* by an agent until it is revoked — and a permission prompt that can be scrolled
    /// past is a permission nobody granted.
    ///
    /// # Two things here are load-bearing
    ///
    /// **It is presented from a fresh turn of the run loop.** Called straight from the open —
    /// which happens inside a SwiftUI `task` while the first window is still being assembled —
    /// `runModal()` returns `.alertFirstButtonReturn` *immediately*, without drawing anything. A
    /// permission dialog that answers itself "yes" is the worst failure this code could have, and
    /// it is not hypothetical: it is what this did until it was moved off that stack.
    ///
    /// **An implausibly fast answer is read as "no".** Nobody reads a folder path and clicks a
    /// button in a seventh of a second, so a `runModal` that returns that quickly did not ask
    /// anybody anything. Refusing then costs a user one retry; believing it costs them a grant
    /// they never made.
    static func confirmWorkspaceGrant(_ folder: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    continuation.resume(returning: askAboutGranting(folder))
                }
            }
        }
    }

    private static func askAboutGranting(_ folder: URL) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Add \u{201C}\(folder.lastPathComponent)\u{201D} to your Claude Code workspaces?"
        alert.informativeText = """
        OpenSheets opens files from folders you have granted, and grants let Claude Code read and \
        write every spreadsheet in them.

        \(folder.path(percentEncoded: false))

        You can revoke this at any time in Settings \u{25B8} Workspace.
        """
        alert.addButton(withTitle: "Grant and Open")
        alert.addButton(withTitle: "Cancel")

        // Return cancels, not grants. Unusual, and deliberate: the same reasoning as the timing
        // check below. A prompt that hands an agent a folder because a keystroke went to the
        // wrong window is a grant nobody made, and the cost of getting it wrong in this direction
        // is one retry.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"

        let started = ContinuousClock.now
        let response = alert.runModal()
        guard ContinuousClock.now - started > .milliseconds(150) else { return false }
        return response == .alertFirstButtonReturn
    }
}
