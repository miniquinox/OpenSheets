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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Sheet") { newSheet() }
                .keyboardShortcut("n")
            Button("Open…") { OpenActions.showOpenPanel() }
                .keyboardShortcut("o")
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
            Button(document?.isWatching == true ? "Pause Watching" : "Resume Watching") {
                guard let document else { return }
                Task { await document.setAutoRefresh(!document.isWatching) }
            }
            .disabled(document == nil)
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
        }

        CommandGroup(replacing: .help) {
            Button("OpenSheets Help") {
                NSWorkspace.shared.open(URL(string: "https://github.com/quino/OpenSheets")!)
            }
        }
    }

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
        OpenActions.open(destination)
    }
}

/// The focused document, so the menu bar can talk to the front window.
struct DocumentFocusKey: FocusedValueKey {
    typealias Value = DocumentModel
}

extension FocusedValues {
    var document: DocumentModel? {
        get { self[DocumentFocusKey.self] }
        set { self[DocumentFocusKey.self] = newValue }
    }
}
