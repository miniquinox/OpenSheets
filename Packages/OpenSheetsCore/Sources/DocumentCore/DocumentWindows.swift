#if canImport(AppKit)
import AppKit
import Foundation

/// Marks the window a view landed in as the launcher or as a document, so ``DocumentWindows`` can
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
public final class WindowRoleView: NSView {
    /// `nil` marks the launcher.
    public var path: String?

    public init(path: String?) {
        self.path = path
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// What a window is for.
public enum WindowRole: Equatable, Sendable {
    /// The first-run panel — the `WindowGroup`'s `nil` case, which macOS manufactures whenever it
    /// decides the app needs a default window.
    case launcher
    /// A document window, identified by the file it is showing.
    case document(identity: String)
}

/// **One launcher, and only when nothing else is open. One window per file.**
///
/// The rules live here, in the package, rather than in the app target, because the app target has
/// no tests and this is the layer where the failure is *visible*: two windows can share one
/// `DocumentModel`, so `openDocuments.count == 1` stays true while two windows sit on screen. See
/// `DocumentCoreTests.OpenDocumentTests` — the model-level scenarios and the window-level ones are
/// deliberately in one file, because passing only one half is what let a window bug hide.
///
/// Everything is read off the live window list every time rather than from bookkeeping of our own,
/// because the list of windows is the only description of the windows that cannot be wrong. macOS
/// asks a `WindowGroup` for its default window whenever it decides the app needs one — at launch,
/// on a dock click, on `open(1)` against a running copy — and each of those used to leave another
/// launcher behind.
///
/// # Two windows on screen is not always two windows
///
/// Worth knowing before suspecting anything in here, because it has cost a day: a second *copy* of
/// the app — a build at another path, left running from an earlier session — puts its own window on
/// screen, on the same file, at the same default frame, because window placement is per process and
/// every fresh process starts the cascade in the same place. It looks exactly like a duplicate this
/// file failed to close: two identical windows, perfectly stacked, one active and one greyed out.
/// It is two processes, and no rule here can see the other one. `pkill -f <path>/OpenSheets.app`
/// does not match a copy that lives somewhere else, so a "clean" relaunch leaves it there.
///
/// `pgrep -fl OpenSheets.app/Contents/MacOS/OpenSheets` says how many processes there are, and
/// `CGWindowListCopyWindowInfo` attributes every on-screen window to its owning pid. Read those two
/// before reading this file.
///
/// # `isVisible`, and why a miniaturized window is deliberately not counted
///
/// Measured, because the answer decides two rules at once: a miniaturized `NSWindow` reports
/// `isVisible == false` while staying in `NSApp.windows`. So a document window in the Dock is not
/// "on screen" here, and two things follow.
///
/// The first looks like a bug and is not: ``window(for:in:)`` returns `nil` for that file, so
/// opening it again asks SwiftUI for a window rather than fronting one. SwiftUI presents the same
/// value into the window that already has it — measured: re-opening a minimised document restores
/// that window rather than making a second one — so the count stays at one either way.
///
/// The second is why the rule stays as it is: counting a miniaturized window as on screen would
/// make the tidy pass close the launcher that a dock click had just brought back, leaving a click
/// with nothing to show for it.
@MainActor
public enum DocumentWindows {
    /// The identity a file is known by, in both layers.
    ///
    /// Shared with ``AppModel`` on purpose: the window layer's "is this file already open" and the
    /// model layer's "does this file already have a model" have to be the same question, or one of
    /// them opens a window the other refuses to fill.
    public static func identity(for url: URL) -> String { AppModel.documentKey(for: url) }

    /// What a window is for, or `nil` if it is not one of ours or is not on screen.
    public static func role(of window: NSWindow) -> WindowRole? {
        guard window.isVisible, let marker = roleView(in: window.contentView) else { return nil }
        guard let path = marker.path else { return .launcher }
        return .document(identity: identity(for: URL(fileURLWithPath: path)))
    }

    /// The document windows on screen, **oldest first**.
    ///
    /// The order matters: ``extras(in:)`` keeps the first of any duplicate set, and `NSApp.windows`
    /// is in no order worth relying on — so on one pass it would keep window A and close B, and on
    /// the next keep B and close A, which is how "one window" became "no windows". `windowNumber`
    /// rises with creation, so oldest-first is the same answer every time, and the window the user
    /// has already seen is the one that survives.
    public static func documents(in windows: [NSWindow]) -> [(identity: String, window: NSWindow)] {
        oldestFirst(windows).compactMap { window in
            guard case let .document(identity) = role(of: window) else { return nil }
            return (identity, window)
        }
    }

    /// The launcher windows on screen, oldest first. More than one means macOS made one nobody
    /// asked for.
    public static func launchers(in windows: [NSWindow]) -> [NSWindow] {
        oldestFirst(windows).filter { role(of: $0) == .launcher }
    }

    /// The window already showing `identity`, if there is one. This is the lookup that turns "open
    /// the same file five times" into one window rather than five.
    public static func window(for identity: String, in windows: [NSWindow]) -> NSWindow? {
        documents(in: windows).first { $0.identity == identity }?.window
    }

    /// The windows nobody asked for: duplicates of a file that is already open, and any launcher
    /// that is not the only thing on screen.
    ///
    /// This is the whole tidy decision, and it is a *decision* rather than an action so that a test
    /// can ask what it would do without a window server having to agree.
    public static func extras(in windows: [NSWindow]) -> [NSWindow] {
        var doomed: [NSWindow] = []
        var seen: Set<String> = []
        for (identity, window) in documents(in: windows) {
            // Two windows on one file would mean two of everything downstream. The first one
            // stays; anything after it is a duplicate macOS made, not one the user asked for.
            if !seen.insert(identity).inserted { doomed.append(window) }
        }
        // A launcher belongs on screen only when nothing else is.
        var keptLauncher = !seen.isEmpty
        for window in launchers(in: windows) {
            if keptLauncher {
                doomed.append(window)
            } else {
                keptLauncher = true
            }
        }
        return doomed
    }

    private static func oldestFirst(_ windows: [NSWindow]) -> [NSWindow] {
        windows.sorted { $0.windowNumber < $1.windowNumber }
    }

    private static func roleView(in view: NSView?) -> WindowRoleView? {
        guard let view else { return nil }
        if let marker = view as? WindowRoleView { return marker }
        for subview in view.subviews {
            if let marker = roleView(in: subview) { return marker }
        }
        return nil
    }
}
#endif
