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
@main
struct OpenSheetsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.standard()
    @State private var appearance = AccessibilityAppearance()

    var body: some Scene {
        WindowGroup(for: DocumentWindowRequest.self) { request in
            RootView(request: request.wrappedValue, app: app, appearance: appearance)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 820)
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
            for url in urls { OpenActions.open(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// What a window is opened for. `nil` is the launcher.
struct DocumentWindowRequest: Codable, Hashable, Sendable {
    var path: String

    var url: URL { URL(fileURLWithPath: path) }
}

/// Resolves a request into a live document, or shows the launcher.
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
        .onAppear {
            OpenActions.openWindow = { request in openWindow(value: request) }
        }
        .task(id: request) { await load() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            OpenActions.handleDrop(providers)
        }
    }

    private func load() async {
        guard let app, let request, model == nil else { return }
        do {
            model = try await app.openDocument(at: request.url)
        } catch {
            failure = error
        }
    }
}

/// Opening files from every entry point: the menu, the dock, Finder, and a drop on a window.
///
/// Centralised because *"opening a file grants its parent folder"* (PLAN.md §1.1) has to be true
/// of all of them. A grant that only happens through `Open…` is a grant the user does not have
/// when they dragged the file in, and they will have no idea why the Claude panel says the folder
/// is not granted.
@MainActor
enum OpenActions {
    /// Set by the scene, because `openWindow` is an environment value and this is not a view.
    static var openWindow: ((DocumentWindowRequest) -> Void)?

    static func open(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        openWindow?(DocumentWindowRequest(path: url.path(percentEncoded: false)))
    }

    static func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = OpenActions.readableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
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
                Task { @MainActor in open(url) }
            }
        }
        return handled
    }
}
