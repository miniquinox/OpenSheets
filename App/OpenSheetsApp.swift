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
/// # One launcher, one workspace, files as tabs
///
/// A single launch used to put five document windows and five launchers on screen for one file:
/// five `DocumentModel`s, five watchers and five sync state machines racing over one path, which
/// is how a save becomes data loss. Three separate things were multiplying, and all three are
/// closed here rather than capped:
///
/// 1. **Scene restoration.** SwiftUI remembers a `WindowGroup(for:)`'s presented values and
///    re-creates a window for each of them at launch, on top of whatever the launch itself asked
///    for. `.restorationBehavior(.disabled)` above; tab restore is our own deterministic path
///    through ``OpenActions/handleLaunch(_:)`` rather than SwiftUI's half-remembered one.
/// 2. **A second window on the same file.** There is now exactly **one** workspace window and
///    every file is a tab in it (``DocumentCore/TabsModel``), so "the same file twice" is a
///    question about tabs rather than about windows and is answered by
///    ``DocumentCore/AppModel/documentKey(for:)`` in one place.
/// 3. **A second launcher.** The launcher is the group's `nil` case, so macOS can manufacture one
///    whenever it decides the app needs a default window — at launch, on reopen, on `open(1)`
///    against a running copy. ``OpenActions`` reads the live window list after every change and
///    closes the ones nobody asked for.
///
/// The opposite failure is worse and had its own cause. `open OpenSheets --args budget.xlsx` put
/// the file in `argv` rather than in an Apple Event; nothing read `argv`, and a bare `argv` token
/// is enough on its own to stop SwiftUI creating the group's default window — so that launch ended
/// with a menu bar, an empty Window menu, and nothing on screen. ``DocumentCore/LaunchArguments``
/// is the reading, ``OpenActions/handleLaunch(_:)`` is the window.
///
/// Each of those is asserted somewhere that runs, and every layer is in one file —
/// `DocumentCoreTests.OpenDocumentTests` — because the gaps between them are where a window bug
/// hides: a model-level count can stay right while the screen is wrong, and a tab-level count can
/// stay right while there are two windows. The rules the window scenarios exercise are
/// ``DocumentCore/DocumentWindows`` and ``DocumentCore/TabsModel``; this file is the wiring that
/// runs them against the live `NSApp.windows`.
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
        .defaultSize(width: DS.Metrics.documentWindowSize.width, height: DS.Metrics.documentWindowSize.height)
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

            // The other half of "a file was named on the command line" — see ``LaunchArguments``.
            // `application(_:open:)` below covers the Apple Event half and never sees this one.
            OpenActions.handleLaunch(LaunchArguments(CommandLine.arguments))
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

/// What the workspace window is opened for: the first file to put in it.
///
/// A path and nothing else, still — this value **is** the window's identity to SwiftUI. What
/// changed with tabs is what the identity *means*: there is one workspace window, so this is the
/// value it was created with rather than the file it is showing, and every later file arrives
/// through ``DocumentCore/TabsModel`` without SwiftUI hearing about it. `nil` is the launcher, as
/// before.
struct DocumentWindowRequest: Codable, Hashable, Sendable {
    /// The file to open, or empty when the window is being opened on a *folder* and has nothing
    /// in it yet.
    ///
    /// Empty string rather than `String?` because this is the `WindowGroup`'s presented value:
    /// SwiftUI keys windows on it, and two spellings of "no file" — `nil` and `""` — would be two
    /// window identities for one state.
    var path: String = ""

    /// A folder to open as the workspace and reveal in the tree. Independent of `path`: a file
    /// open carries none, a folder open carries only this.
    var folder: String?

    var url: URL? { path.isEmpty ? nil : URL(fileURLWithPath: path) }
    var folderURL: URL? { folder.map { URL(fileURLWithPath: $0) } }
}

/// The launcher, or the workspace and its tabs.
///
/// Opening is asynchronous — parsing a million-cell workbook is not something to do on the main
/// thread — but the *window* no longer waits for it: the tab appears immediately in its loading
/// phase and the document lands in it when it arrives, so a slow file never leaves an empty window
/// on screen and a failure is a state of the tab rather than an `NSAlert` (PLAN.md §1.4, §1.2).
struct RootView: View {
    let request: DocumentWindowRequest?
    let app: AppModel?
    let appearance: AccessibilityAppearance

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var tabs: TabsModel?

    private var context: AppearanceContext { appearance.context(for: colorScheme) }

    var body: some View {
        Group {
            if let app, let tabs {
                DocumentWindow(tabs: tabs, app: app, appearance: appearance)
            } else if request == nil {
                LauncherScene(app: app, appearance: appearance)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minWidth: DS.Metrics.minimumWindowWidth, minHeight: DS.Metrics.minimumWindowHeight)
                    .gridPlane(context)
            }
        }
        .glassAppearance(context)
        .background(WindowRegistrar(role: request == nil ? .launcher : .workspace))
        .onDisappear { OpenActions.windowsChanged() }
        .onAppear {
            OpenActions.install(openWindow: openWindow)
            OpenActions.attach(app)
            // Re-fires when a closed window is shown again, which nothing else does — and macOS
            // shows the default window again on every `open(1)` against a running copy.
            OpenActions.windowsChanged()
        }
        .task(id: request) { buildWorkspace() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            OpenActions.handleDrop(providers)
        }
    }

    /// Builds this window's ``DocumentCore/TabsModel`` and hands it to ``OpenActions``.
    ///
    /// One instance per workspace window, and there is at most one workspace window (§1.1), so
    /// `OpenActions` can hold it in a static and every entry point — the menu, Finder, a drop,
    /// `argv`, a recent — lands in the same strip.
    private func buildWorkspace() {
        guard let app, let request, tabs == nil else { return }
        // Installed here as well as in `onAppear`, because the ordering of the two is SwiftUI's
        // business and a missing hook means a refused open rather than a silent grant.
        OpenActions.attach(app)
        let model = TabsModel(
            // Spelled out in full rather than `{ try await app.openDocument(at: $0, consent: $1) }`.
            // A closure literal's *thrown* type is not inferred from the parameter it is passed
            // to, so the short form comes out `throws(any Error)` and the conversion to
            // `throws(SheetError)` is then refused — measured on Swift 6.3.3, and documented on
            // `TabsModel.init` because it reads like a contract error and is not one.
            open: { (url: URL, consent: WorkspaceConsent) async throws(SheetError) -> DocumentModel in
                try await app.openDocument(at: url, consent: consent)
            },
            close: { model in app.closeDocument(model) },
            persist: { persisted in OpenActions.persistTabs(persisted, in: app) }
        )
        tabs = model
        OpenActions.installTabs(model, seed: request.url)
        // The folder half. Pinned after the tabs model is installed so the window exists to show
        // it, and pinned rather than merely granted: the folder the user just opened has to be a
        // root even when it sits inside one they granted months ago, or it lands forty rows down
        // somebody else's subtree and reads as nothing having happened.
        if let folder = request.folderURL { app.explorer.pin(folder) }
    }
}

/// Puts ``DocumentCore/WindowRoleView`` — the mark that says what this window is for — into the
/// window's view hierarchy. The rules that read it are in ``DocumentCore/DocumentWindows``, where
/// tests can reach them.
private struct WindowRegistrar: NSViewRepresentable {
    let role: WindowRoleView.Role

    func makeNSView(context: Context) -> NSView { WindowRoleView(role: role) }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The same view is reused when the request changes from `nil` to a file — which is what
        // happens when the launcher's window is handed a document — so the mark has to follow it.
        (nsView as? WindowRoleView)?.role = role
    }
}

/// Opening files from every entry point: the menu, the dock, Finder, a drop on a window, `argv`,
/// and the tab set the last session left behind.
///
/// Centralised because three rules have to be true of *all* of them, and each is one forgotten
/// call site away from not being:
///
/// 1. **One workspace window; every file is a tab in it.** ``open(_:consent:)`` hands the URL to
///    ``DocumentCore/TabsModel`` when the workspace exists and asks SwiftUI for the workspace
///    window when it does not — and, crucially, only ever asks *once*: a second
///    `openWindow(value:)` with a different path would make a second window, which is the failure
///    ``DocumentCore/DocumentWindows/extras(in:)`` then has to clean up after.
/// 2. **Opening a file grants its parent folder** (PLAN.md §1.1), because the app is the only
///    thing that can — neither CLI binary links AppKit. Doing it in one place means drag-and-drop
///    and `Open Recent` get the same treatment as `Open…`. What differs between them is whether
///    the gesture was consent enough on its own: see ``DocumentCore/WorkspaceConsent``.
/// 3. **A launcher belongs on screen only when nothing else is.** The launcher is the group's
///    `nil` case, so macOS can manufacture one whenever it decides the app needs a default window.
///    ``windowsChanged()`` reads the live list after every change and closes what nobody asked for.
///
/// # Why the statics
///
/// `openWindow` is an environment value, the tab set belongs to a window, and closing a tab may
/// have to put a panel on screen — none of which a `Commands` struct or an `NSApplicationDelegate`
/// can reach. There is at most one workspace window (§1.1), so a static *is* the whole registry,
/// and every one of them is cleared when that window goes away (``workspaceClosed(_:)``).
@MainActor
enum OpenActions {
    /// The one scene's id, so ``showLauncher()`` can ask for a default (launcher) window by name.
    static let sceneID = "main"

    /// PLAN.md §1.7. Unknown preference keys are never read, so a rollback leaves this behind
    /// harmlessly.
    static let tabsPreferenceKey = "workspace.tabs"

    /// The workspace's tabs, installed by the workspace window when it appears. Private because
    /// the menu bar reaches them through `@FocusedValue(\.workspaceTabs)` instead: a focused value
    /// is observable and a static is not, so a `Close Tab` reading this one would be enabled or
    /// disabled according to whatever it happened to be when the menu was last built.
    private static var tabs: TabsModel?

    /// ⌘W and ⌥⌘W, installed by the workspace window. They live here rather than being called on
    /// ``tabs`` directly because both may have to ask about unsaved edits first, and only a window
    /// can ask.
    static var closeActiveTab: (() -> Void)?
    static var closeWorkspaceWindow: (() -> Void)?

    /// Set by whichever window appears first, because `openWindow` is an environment value and
    /// this is not a view.
    private static var openWindow: OpenWindowAction?
    /// URLs handed to us before there was anywhere to put them — the cold-launch file argument,
    /// which arrives during `application(_:open:)`, and everything after the first file while the
    /// workspace window is still being built.
    private static var queued: [(URL, WorkspaceConsent)] = []
    /// How each pending or open document was asked for. Not part of `DocumentWindowRequest`,
    /// because that value is the window's identity.
    private static var consents: [String: WorkspaceConsent] = [:]
    /// Whether SwiftUI has already been asked for the workspace window. Asking twice is what makes
    /// two of them.
    private static var workspaceRequested = false
    /// The app model, kept so the launch path can read `workspace.tabs` — the preference store
    /// belongs to ``DocumentCore/AppModel`` and the launch happens before any view exists.
    private static var app: AppModel?
    /// A stored tab set waiting for a workspace window to restore into.
    private static var pendingRestore: TabsModel.PersistedTabs?
    /// Whether this launch is allowed to restore at all. §1.9: **only** a launch that names no
    /// files restores; anything else is the user asking for something specific.
    private static var wantsTabRestore = false

    /// Gives the model the one thing only the app target can supply: a panel.
    static func attach(_ app: AppModel?) {
        guard let app else { return }
        if self.app == nil { self.app = app }
        if app.confirmWorkspaceGrant == nil {
            app.confirmWorkspaceGrant = { folder in await confirmWorkspaceGrant(folder) }
        }
        // The launch decided *whether* to restore before there was an `AppModel` to read the
        // preference from. This is where the two meet.
        restoreTabsIfWanted()
    }

    static func install(openWindow action: OpenWindowAction) {
        openWindow = action
        drainQueue()
        // A folder asked for before there was anything to open a window with. Parked by
        // `openWorkspace(folder:)` rather than dropped, because the alternative is a grant that
        // works or does nothing depending on how far SwiftUI had got — which is precisely the
        // class of silent nothing this feature was built to remove.
        if let folder = pendingFolder {
            pendingFolder = nil
            openWorkspace(folder: folder)
        }
    }

    /// The workspace window has appeared and brought its tab set.
    ///
    /// Everything that has been waiting opens **here**, sequentially, rather than as a task each:
    /// the strip's order is the order the user asked for — `argv` order at launch, stored order on
    /// a restore — and a task per file hands it back in whatever order the disk felt like.
    static func installTabs(_ model: TabsModel, seed: URL?) {
        guard tabs !== model else { return }
        tabs = model
        workspaceRequested = true
        // The window arrived, so the watchdog's one retry is spent on nothing and available again
        // if this workspace is later closed and a new one asked for.
        workspaceRetried = false
        let restore = pendingRestore
        pendingRestore = nil
        let pending = queued
        queued = []
        Task {
            if let seed { await model.open(seed, consent: consent(for: seed)) }
            for (url, consent) in pending { await model.open(url, consent: consent) }
            // Additive and self-deduping, so the seed being the first restored path costs nothing;
            // the stored active index is applied at the end, which is what puts the tab the user
            // was last on back in front.
            if let restore { await model.restore(restore) }
        }
    }

    /// The workspace window has gone. Every static that named it is cleared, so the next open
    /// builds a new window rather than talking to a dead one.
    static func workspaceClosed(_ model: TabsModel) {
        guard tabs === model else { return }
        tabs = nil
        workspaceRequested = false
        closeActiveTab = nil
        closeWorkspaceWindow = nil
    }

    /// ``DocumentCore/TabsModel``'s persist hook: the tab set, as JSON, in the preference table.
    ///
    /// Fires on every membership and activation change rather than at quit, which is what makes
    /// the answer survive a crash, a force-quit and a window closed by the red button — none of
    /// which get to run a teardown.
    static func persistTabs(_ persisted: TabsModel.PersistedTabs, in app: AppModel) {
        guard let data = try? JSONEncoder().encode(persisted),
              let json = String(data: data, encoding: .utf8)
        else { return }
        try? app.store.database.setPreference(tabsPreferenceKey, to: json)
    }

    /// Reopens the last session's tabs, once, if this launch is allowed to.
    ///
    /// Corrupt or absent JSON is treated as "restore nothing" rather than as an error (§1.7): a
    /// preference nobody typed is not worth a message, and the launcher is a perfectly good answer.
    private static func restoreTabsIfWanted() {
        guard wantsTabRestore, let app else { return }
        wantsTabRestore = false
        guard let stored = storedTabs(in: app),
              let seed = stored.paths.first(where: { $0.hasPrefix("/") })
        else { return }
        if let tabs {
            Task { await tabs.restore(stored) }
            return
        }
        pendingRestore = stored
        // Restored tabs carry `.fromOutsideTheApp` consent: their folders were granted when the
        // files were first opened, so no prompt appears — and if a grant was revoked between
        // sessions the open fails into that tab's `.failed` phase, which is the designed answer
        // (§1.6). Nothing here can widen a grant.
        open(URL(fileURLWithPath: seed), consent: .fromOutsideTheApp)
    }

    private static func storedTabs(in app: AppModel) -> TabsModel.PersistedTabs? {
        // One optional, not two: `try?` flattens into the `String?` the preference already
        // returns. A store that cannot be read and a preference nobody has written mean the same
        // thing here — restore nothing — so there is nothing to tell apart.
        guard let raw = try? app.store.database.preference(tabsPreferenceKey),
              let data = raw.data(using: .utf8),
              let stored = try? JSONDecoder().decode(TabsModel.PersistedTabs.self, from: data),
              !stored.paths.isEmpty
        else { return nil }
        return stored
    }

    private static func drainQueue() {
        let pending = queued
        queued = []
        for (url, consent) in pending { open(url, consent: consent) }
    }

    /// Opens whatever the command line named, and makes sure a window exists to open it into.
    ///
    /// See ``DocumentCore/LaunchArguments`` for the measurement behind this: a bare `argv` token
    /// stops SwiftUI from creating the `WindowGroup`'s default window, so this launch has no
    /// scene, no `openWindow` action, and no way to drain ``queued`` — the file would sit in the
    /// queue forever behind an empty Window menu.
    ///
    /// Asking macOS to open this app *again* is what breaks the deadlock, and it is not a trick:
    /// the second request reaches the running process as an ordinary reopen, which is the event
    /// ``applicationShouldHandleReopen(_:hasVisibleWindows:)`` already exists to answer. AppKit
    /// makes the default window, the first `RootView` installs `openWindow`, the queue drains into
    /// a document window, and ``tidyWindows()`` closes the launcher behind it — one window, the
    /// one the user asked for.
    static func handleLaunch(_ launch: LaunchArguments) {
        let files = launch.files()
        // §1.9: tab restore runs **only** when the launch names no files. A launch that names one
        // is the user asking for that file, and burying it under six restored tabs is not what
        // they asked for. Deferred rather than done here, because reading `workspace.tabs` needs
        // an `AppModel` and no view has handed us one yet — see ``attach(_:)``.
        wantsTabRestore = files.isEmpty
        restoreTabsIfWanted()
        guard launch.suppressesTheDefaultWindow else { return }
        for url in files { open(url, consent: .fromOutsideTheApp) }
        provokeDefaultWindow()
    }

    /// Guards ``provokeDefaultWindow()`` against ever asking twice. A reopen loop would be a
    /// launch that never settles.
    private static var provokedDefaultWindow = false

    private static func provokeDefaultWindow() {
        guard openWindow == nil, !provokedDefaultWindow else { return }
        provokedDefaultWindow = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
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

    /// Opens `url` as a tab in the workspace, building the workspace window first if there is not
    /// one yet.
    ///
    /// "The same file five times" is one tab, not five windows: ``DocumentCore/TabsModel/open(_:consent:)``
    /// dedupes on ``DocumentCore/AppModel/documentKey(for:)`` and activates the tab that already
    /// has it. What this end has to get right is the *window* — asking SwiftUI for a second one
    /// while the first is still being built is the only way two appear.
    static func open(_ url: URL, consent: WorkspaceConsent = .fromOutsideTheApp) {
        consents[AppModel.documentKey(for: url)] = consent
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        if let tabs {
            Task { await tabs.open(url, consent: consent) }
            frontWorkspace()
            return
        }
        guard let openWindow, !workspaceRequested else {
            queued.append((url, consent))
            return
        }
        workspaceRequested = true
        openWindow(value: DocumentWindowRequest(path: url.path(percentEncoded: false)))
        confirmWorkspaceArrives()
    }

    /// How `url` was asked for, for the grant decision. Defaults to the careful answer.
    static func consent(for url: URL) -> WorkspaceConsent {
        consents[AppModel.documentKey(for: url)] ?? .fromOutsideTheApp
    }

    /// A window has arrived, or the launcher has been shown again. Either way, put the set of
    /// windows back the way it should be.
    static func windowsChanged() {
        // Next turn of the run loop: a window that has just appeared is not `isVisible` yet
        // while its content view is still being installed, and a tidy that runs then cannot see
        // the window it is meant to be tidying.
        Task { tidyWindows() }
    }

    /// **One workspace window. One launcher, and only when the workspace is not open.**
    ///
    /// The decision is ``DocumentCore/DocumentWindows/extras(in:)`` — which windows nobody asked
    /// for — and it lives in the package because that is where the tests are. This end is the part
    /// that cannot be tested away from a running app: reading the live list, and closing what the
    /// decision names.
    private static func tidyWindows() {
        for window in DocumentWindows.extras(in: NSApp.windows) { dismiss(window) }
    }

    private static var launcherWindows: [NSWindow] { DocumentWindows.launchers(in: NSApp.windows) }

    private static var workspaceWindows: [NSWindow] { DocumentWindows.workspaces(in: NSApp.windows) }

    /// How long a requested workspace window has to actually appear.
    ///
    /// Generous on purpose: this is a deadlock breaker, not a progress bar. A window that is
    /// merely slow must never trip it, and nothing the user can see depends on the delay.
    private static let workspaceArrivalGrace = Duration.seconds(3)

    /// Makes sure the window we just asked for actually arrived, and un-latches if it did not.
    ///
    /// ``workspaceRequested`` exists so that five files opening at launch produce one window
    /// rather than five. It is set the moment `openWindow(value:)` is *called*, and it was only
    /// ever cleared by ``workspaceClosed(_:)`` — that is, by a workspace window that existed going
    /// away. So a request that never produced a window left it latched on with ``tabs`` still
    /// `nil`, and from then on every ``open(_:consent:)`` appended to ``queued`` and returned.
    /// Process alive, no window, no path back, and nothing on screen to act on: the app was
    /// running and invisible until it was killed.
    ///
    /// Observed once and never reproduced in thirty launches, which is the argument *for* this
    /// rather than against it — a state that strands the whole app and cannot be recovered from
    /// does not need to be likely to be worth a way out. The check is cheap, runs once per
    /// request, and does nothing at all in the case where the window turned up.
    /// One retry, then stop asking. Measured, not assumed: an unbounded version re-requested
    /// every three seconds forever against a window request that could not succeed.
    private static var workspaceRetried = false

    private static func confirmWorkspaceArrives() {
        Task { @MainActor in
            try? await Task.sleep(for: workspaceArrivalGrace)
            // Three ways this is a false alarm, and all of them mean the same thing: something
            // came back, so leave it alone. `tabs` is the strongest — the window not only opened
            // but installed its model.
            guard workspaceRequested, tabs == nil, workspaceWindows.isEmpty else { return }
            workspaceRequested = false
            guard !workspaceRetried else {
                // Asked twice, got nothing twice. Stop, and make sure there is a window: a
                // launcher the user can open a file from beats a correct, empty screen.
                _ = showLauncher()
                return
            }
            workspaceRetried = true
            // The queue still holds what was asked for, so this re-latches and tries once more.
            if queued.isEmpty { _ = showLauncher() } else { drainQueue() }
        }
    }


    /// Brings the workspace forward, because an open the user asked for should land somewhere they
    /// can see. A miniaturized window is not in this list (``DocumentCore/DocumentWindows``
    /// explains why), so this quietly does nothing then — the tab still opened, and un-minimising
    /// shows it.
    private static func frontWorkspace() {
        guard let window = DocumentWindows.workspaces(in: NSApp.windows).first else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        tidyWindows()
    }

    /// Closes a window nobody asked for, on the next turn of the run loop.
    ///
    /// Not immediately: SwiftUI orders a new window front *after* its content view is installed,
    /// so a `close()` from inside that pass is quietly undone a moment later. One frame of a
    /// window that should not exist is the price of it going away at all.
    private static func dismiss(_ window: NSWindow) {
        Task { window.close() }
    }

    /// Open a folder as the workspace: the window comes up with the tree on the left and nothing
    /// in it, which is what "I granted a folder" should look like.
    ///
    /// Distinct from ``open(_:consent:)`` because a folder is not a document. It never becomes a
    /// tab, never touches recents, and the window it opens is legitimately empty — the state the
    /// tabless branch of `DocumentWindow` used to treat as one frame on the way out.
    static func openWorkspace(folder: URL) {
        guard let app else { return }
        // Already have a workspace window? Then this is a reveal, not a new window. Opening a
        // second one would split the tabs across two windows, which §1.1 exists to prevent.
        if tabs != nil {
            app.explorer.pin(folder)
            frontWorkspace()
            return
        }
        guard let openWindow, !workspaceRequested else {
            pendingFolder = folder
            return
        }
        workspaceRequested = true
        openWindow(value: DocumentWindowRequest(folder: folder.path(percentEncoded: false)))
        confirmWorkspaceArrives()
    }

    /// A folder asked for before there was a window to put it in.
    static var pendingFolder: URL?

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
