import AppKit
import DocumentCore
import GridKit
import SheetFormat
import SheetFormula
import SheetModel
import SwiftUI

/// The menu bar.
///
/// A macOS app is judged on this before it is judged on anything else, and the judgement is made
/// by pressing ⌘Z in the first thirty seconds. So the standard shortcuts are all here, they all
/// name what they will do (`Undo Paste`, not `Undo`), and every one of them is disabled rather
/// than silently inert when it cannot run.
///
/// Undo is deliberately **not** `UndoManager`. `UndoManager` is a registration API whose state
/// lives in AppKit, and mirroring a second stack next to it is how undo and the document end up
/// disagreeing after a refresh clears one of them. ``DocumentCore/DocumentUndoStack`` is the only
/// stack, and `Edit ▸ Undo` reads from it directly.
struct DocumentCommands: Commands {
    let app: AppModel?
    @FocusedValue(\.document) private var document: DocumentModel?
    @FocusedValue(\.workspaceTabs) private var tabs: TabsModel?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Sheet") { newSheet() }
                .keyboardShortcut("n")
            Button("Open…") { OpenActions.showOpenPanel() }
                .keyboardShortcut("o")
            Divider()
            // ⌘W closes a **tab**, and the window only when the tab was the last one — the
            // behaviour of every tabbed editor, and the reason Close Window needs a shortcut of
            // its own. ⌥⌘W rather than Safari's ⇧⌘W: ⇧⌘S is already Save As here, and colliding
            // with a save is worse than deviating from Safari on a shortcut nobody has muscle
            // memory for. Nothing else in this app uses ⌥⌘W.
            Button("Close Tab") { OpenActions.closeActiveTab?() }
                .keyboardShortcut("w")
                .disabled(tabs?.activeTabID == nil)
            Button("Close Window") { OpenActions.closeWorkspaceWindow?() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(tabs == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Save") { Task { await document?.save() } }
                .keyboardShortcut("s")
                .disabled(document?.syncState.allowsSaving != true)
            Button("Save As…") { saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(document == nil)
            Divider()
            Button("Refresh from Disk") { Task { await document?.refresh() } }
                .keyboardShortcut("r")
                .disabled(document == nil)
            // PLAN.md §1.2 step 8: mark here. Everything the chip reports is measured against
            // whatever this last captured, so it sits with the other file-versus-disk commands
            // rather than under View — it is a statement about the file, not about the display.
            Button("Set Checkpoint") { Task { await document?.setCheckpoint() } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(document == nil || !Flags.changeTrackingEnabled)
            Divider()
            Button("Restore Snapshot…") { document?.isPresentingSnapshots = true }
                .disabled(document == nil)
            Button("Show in Finder") {
                guard let url = document?.url else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(document == nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(document?.undoName.map { "Undo \($0)" } ?? "Undo") { document?.undo() }
                .keyboardShortcut("z")
                .disabled(document?.canUndo != true)
            Button(document?.redoName.map { "Redo \($0)" } ?? "Redo") { document?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(document?.canRedo != true)
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { document?.copy(cut: true) }
                .keyboardShortcut("x")
                .disabled(document?.isEditable != true)
            Button("Copy") { document?.copy() }
                .keyboardShortcut("c")
                .disabled(document == nil)
            Button("Paste") { document?.paste() }
                .keyboardShortcut("v")
                .disabled(document?.isEditable != true)
            Button("Paste Values Only") { document?.paste(.valuesOnly) }
                .keyboardShortcut("v", modifiers: [.command, .shift, .option])
                .disabled(document?.isEditable != true)
            Divider()
            Button("Delete") { document?.clearContents() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(document?.isEditable != true)
            Button("Select All") { selectAll() }
                .keyboardShortcut("a")
                .disabled(document == nil)
        }

        CommandMenu("Insert") {
            Button("Rows Above") { document?.structural(.insertRows) }
                .disabled(document?.isEditable != true)
            Button("Columns Before") { document?.structural(.insertColumns) }
                .disabled(document?.isEditable != true)
            Divider()
            Button("Delete Rows") { document?.structural(.deleteRows) }
                .disabled(document?.isEditable != true)
            Button("Delete Columns") { document?.structural(.deleteColumns) }
                .disabled(document?.isEditable != true)
            Divider()
            Button("Merge Cells") { document?.toggleMerge() }
                .keyboardShortcut("m", modifiers: [.command, .control])
                .disabled(document?.isEditable != true)
            Button("Freeze Panes") { document?.toggleFrozenPanes() }
                .disabled(document?.isEditable != true)
        }

        CommandGroup(after: .toolbar) {
            Button("Command Palette") { document?.isPaletteVisible.toggle() }
                .keyboardShortcut("k")
                .disabled(document == nil)
            Button("Show Sidebar") { document?.isSidebarVisible.toggle() }
                .keyboardShortcut("0")
                .disabled(document == nil)
            Button("Show Inspector") { document?.isInspectorVisible.toggle() }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(document == nil)
            Button("Show Formulas") { document?.showsFormulas.toggle() }
                .keyboardShortcut("`", modifiers: .control)
                .disabled(document == nil)
            // Under View with the other switches that change what the window draws, and
            // deliberately not beside Set Checkpoint: that one moves the baseline and so changes
            // every number the chip reports, while this changes none of them. The counts stay in
            // the title bar; the grid stops painting them.
            Button(highlightsTitle) { document?.isChangeHighlightingEnabled.toggle() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(document == nil || !Flags.changeTrackingEnabled)
            Divider()
            Button("Actual Size") { document?.zoom = 1 }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(document == nil)
            Button("Zoom In") { zoom(by: 1.25) }
                .keyboardShortcut("+")
                .disabled(document == nil)
            Button("Zoom Out") { zoom(by: 0.8) }
                .keyboardShortcut("-")
                .disabled(document == nil)
            Divider()
            // ⇧⌘] / ⇧⌘[ — Safari's and Xcode's, and they wrap, because a shortcut that stops
            // working when you reach the edge is a shortcut people stop using.
            Button("Next Tab") { tabs?.activateNext() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((tabs?.tabs.count ?? 0) < 2)
            Button("Previous Tab") { tabs?.activatePrevious() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((tabs?.tabs.count ?? 0) < 2)
        }

        // ⌘1…⌘9, in the Window menu, where Safari puts them. One item per **open** tab rather
        // than nine every time: a menu offering "Show Tab 7" with four files open is a menu
        // telling you about something that does not exist.
        CommandGroup(after: .windowList) {
            let open = Array((tabs?.tabs ?? []).prefix(Self.directTabShortcuts))
            if !open.isEmpty {
                Divider()
                ForEach(Array(open.enumerated()), id: \.element.id) { index, tab in
                    Button(tab.url.lastPathComponent) { tabs?.activate(index: index) }
                        .keyboardShortcut(Self.digits[index], modifiers: .command)
                }
            }
        }

        CommandGroup(replacing: .help) {
            Button("OpenSheets Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/quino/OpenSheets")!)
            }
        }
    }

    /// Named for what it will do, like Refresh from Disk above it and unlike Show Sidebar, whose
    /// title never changes. A toggle with a fixed title has to signal its state some other way —
    /// a checkmark — and a checkmark next to "Show Change Highlights" says the same thing twice
    /// while leaving the unchecked state ambiguous about whether it is a state or an offer.
    private var highlightsTitle: String {
        document?.isChangeHighlightingEnabled == true
            ? "Hide Change Highlights"
            : "Show Change Highlights"
    }

    /// ⌘1…⌘9. Nine because ⌘0 is Show Sidebar and because nobody counts tabs past nine by eye.
    private static let directTabShortcuts = 9
    private static let digits: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

    private func zoom(by factor: Double) {
        guard let document else { return }
        document.zoom = min(4, max(0.25, document.zoom * factor))
    }

    private func selectAll() {
        guard let document, let sheet = document.activeSheet else { return }
        document.selection.select(sheet.usedRange ?? Limits.entireSheet, active: .origin)
    }

    private func saveAs() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.url.lastPathComponent
        panel.allowedContentTypes = OpenActions.readableTypes
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { try? await document.saveAs(to: destination) }
    }

    private func newSheet() {
        // A workbook created in-app has no package to patch, so A2 builds one from scratch. It
        // has to be saved somewhere before it can be watched, which is why this asks first rather
        // than opening an untitled window that cannot refresh, cannot snapshot and cannot be
        // reached by Claude Code — three of the four things the app is for.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.xlsx"
        panel.allowedContentTypes = OpenActions.readableTypes
        guard panel.runModal() == .OK, let destination = panel.url, let app else { return }
        var workbook = Workbook.blank()
        workbook.meta.sourceFormat = .xlsx
        var tracker = WorkbookEditTracker()
        if let sheet = workbook.sheets.first { tracker.noteSheetReplaced(sheet) }
        guard let bytes = try? XLSXWriter.data(for: workbook, edits: tracker) else { return }
        guard (try? app.store.suppressor.write(bytes, to: destination)) != nil else { return }
        // The save panel is the consent gesture: the user just chose this folder to put a file in.
        OpenActions.open(destination, consent: .userSelectedInPanel)
    }
}

/// The focused document, so the menu bar can talk to the front window.
struct DocumentFocusKey: FocusedValueKey {
    typealias Value = DocumentModel
}

/// The focused window's tabs, so tab navigation and the enabled state of the tab commands read
/// from the window that is actually in front rather than from a static nothing can observe.
struct WorkspaceTabsFocusKey: FocusedValueKey {
    typealias Value = TabsModel
}

extension FocusedValues {
    var document: DocumentModel? {
        get { self[DocumentFocusKey.self] }
        set { self[DocumentFocusKey.self] = newValue }
    }

    var workspaceTabs: TabsModel? {
        get { self[WorkspaceTabsFocusKey.self] }
        set { self[WorkspaceTabsFocusKey.self] = newValue }
    }
}
