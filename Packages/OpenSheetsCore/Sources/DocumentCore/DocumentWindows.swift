#if canImport(AppKit)
import AppKit
import Foundation

/// Marks the window a view landed in as the launcher or as the workspace, so ``DocumentWindows``
/// can tell them apart by looking at `NSApp.windows`.
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
///
/// # Why the mark no longer names a file
///
/// It used to carry the path of the document the window was showing, because there was one window
/// per file and the open path had to find "the window already showing this". There is now one
/// window for *every* file — files are tabs inside it (``TabsModel``) — so the question the mark
/// has to answer shrank to two answers, and the file-level one moved to where the tabs are. A mark
/// that still carried a path would have to be updated on every tab switch to stay true, and a
/// marker that needs maintaining is the registry this exists instead of.
public final class WindowRoleView: NSView {
    /// What this window is for.
    public enum Role: Equatable, Sendable {
        /// The first-run panel — the `WindowGroup`'s `nil` case, which macOS manufactures whenever
        /// it decides the app needs a default window.
        case launcher
        /// The workspace: the tab strip, and whichever document is in front.
        case workspace
    }

    public var role: Role

    public init(role: Role) {
        self.role = role
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("not from a nib") }
}

/// What a window is for. Spelled at call sites that ask a window rather than build one.
public typealias WindowRole = WindowRoleView.Role

/// **One workspace window. One launcher, and only when the workspace is not open.**
///
/// The rules live here, in the package, rather than in the app target, because the app target has
/// no tests and this is the layer where the failure is *visible*: what is on screen and what the
/// models think is open are two different counts, and passing only one of them is what let a window
/// bug hide. See `DocumentCoreTests.OpenDocumentTests` — the model-level scenarios, the tab-level
/// ones and the window-level ones are deliberately in one file for that reason.
///
/// Everything is read off the live window list every time rather than from bookkeeping of our own,
/// because the list of windows is the only description of the windows that cannot be wrong. macOS
/// asks a `WindowGroup` for its default window whenever it decides the app needs one — at launch,
/// on a dock click, on `open(1)` against a running copy — and each of those used to leave another
/// launcher behind.
///
/// # Why one window, and what that cost the rules
///
/// There used to be one window per file, and the whole of this file was about keeping that true:
/// an identity per window, a lookup from file to window, and a duplicate rule that kept the oldest
/// window of each identity. Files are now tabs in a single workspace window, so the identity
/// question moved to ``TabsModel`` — which is the only place it can be answered honestly now, since
/// two tabs on one file are not two windows and no amount of looking at `NSApp.windows` would say
/// so. What is left here is the smaller, blunter rule: **more than one workspace window is a
/// window nobody asked for**, and the oldest one is the one the user has already seen.
///
/// Dragging a tab out into a second workspace window is explicitly out of scope for v1 (§1.1). If
/// it lands, this rule is what has to change, and it should change into a count rather than back
/// into a registry.
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
/// Measured, because the answer decides the launcher rule: a miniaturized `NSWindow` reports
/// `isVisible == false` while staying in `NSApp.windows`. So the workspace window sitting in the
/// Dock is not "on screen" here — and counting it as though it were would make the tidy pass close
/// the launcher that a dock click had just brought back, leaving a click with nothing to show for
/// it.
///
/// The other half of that trade is now cheaper than it was. Under one-window-per-file it meant a
/// minimised document's window could not be found and re-fronted; today the only thing a second
/// open can ask for is the workspace, and if it is minimised SwiftUI presents into the window that
/// already exists rather than making another — so the count stays at one either way.
@MainActor
public enum DocumentWindows {
    /// What a window is for, or `nil` if it is not one of ours or is not on screen.
    public static func role(of window: NSWindow) -> WindowRole? {
        guard window.isVisible, let marker = roleView(in: window.contentView) else { return nil }
        return marker.role
    }

    /// The workspace windows on screen, **oldest first**. There should be exactly one; more than
    /// one is what ``extras(in:)`` exists to name.
    ///
    /// The order matters: ``extras(in:)`` keeps the first, and `NSApp.windows` is in no order worth
    /// relying on — so on one pass it would keep window A and close B, and on the next keep B and
    /// close A, which is how "one window" became "no windows". `windowNumber` rises with creation,
    /// so oldest-first is the same answer every time, and the window the user has already seen is
    /// the one that survives.
    public static func workspaces(in windows: [NSWindow]) -> [NSWindow] {
        oldestFirst(windows).filter { role(of: $0) == .workspace }
    }

    /// The launcher windows on screen, oldest first. More than one means macOS made one nobody
    /// asked for.
    public static func launchers(in windows: [NSWindow]) -> [NSWindow] {
        oldestFirst(windows).filter { role(of: $0) == .launcher }
    }

    /// The windows nobody asked for: a second workspace, and any launcher that is not the only
    /// thing on screen.
    ///
    /// This is the whole tidy decision, and it is a *decision* rather than an action so that a test
    /// can ask what it would do without a window server having to agree.
    public static func extras(in windows: [NSWindow]) -> [NSWindow] {
        let workspaces = workspaces(in: windows)
        // A second workspace window would mean a second tab strip, a second set of tabs, and two
        // `TabsModel`s writing over each other's `workspace.tabs`. The first one stays; anything
        // after it is one macOS made, not one the user asked for.
        var doomed = Array(workspaces.dropFirst())
        // A launcher belongs on screen only when nothing else is.
        var keptLauncher = !workspaces.isEmpty
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
