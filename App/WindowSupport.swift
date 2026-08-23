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
