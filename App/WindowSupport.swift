import AppKit
import DocumentCore
import GlassUI
import SwiftUI
import UniformTypeIdentifiers

/// Applies A5's ``GlassUI/WindowChrome`` to the window this view lands in.
///
/// The transparent, full-size-content titlebar is the load-bearing part: without it the window has
/// an opaque strip above the content, the document plane stops at its bottom edge, and
/// `.backgroundExtensionEffect()` has nothing to extend into. That is the difference between
/// chrome that belongs to the document and chrome that is bolted above it.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.configure = { WindowChrome.configureDocumentWindow($0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The launcher's variant: no title, no toolbar, not resizable.
struct LauncherWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ConfiguringView()
        view.configure = { WindowChrome.configureLauncherWindow($0) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Runs a closure once the view has a window.
private final class ConfiguringView: NSView {
    var configure: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        configure?(window)
    }
}

/// A stand-in `FileDocument` for `fileExporter`.
///
/// The exporter is used only for its *panel*: it asks the user where to put the file and hands
/// back a URL, and ``DocumentCore/DocumentModel/saveAs(to:)`` does the actual write through
/// `SheetStore`'s atomic writer so the save is still snapshotted and still suppresses its own
/// watcher event. Letting `fileExporter` write the bytes would bypass all three, which is the
/// exact structural guarantee addendum §8 was arbitrated to protect.
struct WorkbookExport: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.data]

    init() {}

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data())
    }
}

// MARK: - The titlebar

/// Where the window's traffic lights actually are.
///
/// Both numbers are **measured off the buttons**, never assumed. macOS moves them: they shift with
/// the system's own metrics, and in full screen they slide out of the window entirely. A constant
/// here is a control sitting under the close button on somebody else's Mac, or a 72pt hole in the
/// leading edge of a full-screen window — and it is exactly the kind of number
/// `GlassLintTests.spacingComesFromTheScale` exists to keep out of the layout.
struct TitleBarMetrics: Equatable {
    /// Where leading content may start: past the zoom button, plus one step of air. Collapses to a
    /// plain margin in full screen, where there are no buttons to clear.
    var leadingInset: CGFloat

    /// Distance from the window's top edge down to the centre line of the buttons. The title row
    /// is sized to twice this, which is what puts our controls on the buttons' centre line rather
    /// than near it.
    var centreFromTop: CGFloat

    /// What to use before the view has a window. Replaced on the first layout pass.
    static let unmeasured = TitleBarMetrics(
        leadingInset: DS.Metrics.trafficLightInset,
        centreFromTop: DS.Metrics.titleBarHeight / 2
    )
}

/// Reports ``TitleBarMetrics`` for the window this view lands in, and again whenever they change.
///
/// Full screen is the case that makes this a live observation rather than a one-time read: the
/// buttons leave, the leading inset has to collapse, and both have to come back on exit.
struct TitleBarMetricsReader: NSViewRepresentable {
    let report: (TitleBarMetrics) -> Void

    func makeNSView(context: Context) -> NSView { MetricsView(report: report) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MetricsView)?.report = report
        (nsView as? MetricsView)?.measure()
    }

    private final class MetricsView: NSView {
        var report: (TitleBarMetrics) -> Void
        private var observers: [any NSObjectProtocol] = []
        private var last: TitleBarMetrics?

        init(report: @escaping (TitleBarMetrics) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else { return }
            for name: NSNotification.Name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didResizeNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.measure() }
                    }
                )
            }
            measure()
        }

        func measure() {
            guard let window else { return }
            let now = measured(in: window)
            guard now != last else { return }
            last = now
            report(now)
        }

        /// Full screen first, and on the style mask **alone**.
        ///
        /// The first version of this asked for `.fullScreen` *and* a hidden close button, on the
        /// assumption that macOS hides the buttons when it takes them away. It does not — it keeps
        /// them and moves them into the menu-bar overlay, so the `else` branch ran, measured a
        /// button that was no longer in this window's titlebar, and produced a `centreFromTop` of
        /// roughly half the screen. The title row is sized to twice that, so it grew to fill the
        /// window and pushed the toolbar, the formula bar and the entire grid out of view.
        ///
        /// Hence the clamp on the measured path as well. Any number that is not a plausible
        /// titlebar is not a titlebar, and falling back to the token costs a few points of
        /// alignment where believing it costs the whole window.
        private func measured(in window: NSWindow) -> TitleBarMetrics {
            guard !window.styleMask.contains(.fullScreen) else {
                // No buttons to clear: the leading edge is a plain margin like any other.
                return TitleBarMetrics(
                    leadingInset: DS.Space.m,
                    centreFromTop: DS.Metrics.titleBarHeight / 2
                )
            }
            guard let zoom = window.standardWindowButton(.zoomButton),
                  let close = window.standardWindowButton(.closeButton),
                  !close.isHidden
            else { return .unmeasured }

            // AppKit's window coordinates are bottom-up; SwiftUI's are top-down.
            let centre = window.frame.height - close.convert(close.bounds, to: nil).midY
            guard centre > 0, centre <= DS.Metrics.titleBarHeight else { return .unmeasured }

            return TitleBarMetrics(
                leadingInset: zoom.convert(zoom.bounds, to: nil).maxX + DS.Space.m,
                centreFromTop: centre
            )
        }

        /// The titlebar drags the window, and it has to keep doing that. Returning `nil` for a hit
        /// anywhere in this view lets the click fall through to whatever is behind it — which for
        /// the empty stretches of the row is AppKit's own titlebar, the thing that implements the
        /// drag. The controls sit in front of this view and are hit normally.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
