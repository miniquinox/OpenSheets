import AppKit
import Foundation
import SheetModel
import SwiftUI

/// An imperative handle on a live grid.
///
/// SwiftUI's declarative surface covers "what is on screen"; it does not cover "tint these
/// cells", "scroll there", or "start editing", which are events rather than state. Those go
/// through here.
///
/// Hold one in the shell's view model and hand it to ``GridView``. It is safe to hold one that
/// is not attached to a view — every call is a no-op until it is.
@MainActor
public final class GridController {
    weak var host: GridHostView? {
        didSet { attachCallbacks() }
    }

    /// Called on every keystroke typed **into a cell**, so the shell's formula bar can show the
    /// same characters. Assigning ``editorText`` does not fire it, which is what stops the two
    /// fields feeding each other.
    public var onEditorTextChanged: ((String) -> Void)? {
        didSet { attachCallbacks() }
    }

    /// Called when an edit is refused because the cell's value is written by a formula anchored
    /// somewhere else. The grid has already beeped and scrolled to the anchor; this is the shell's
    /// chance to say *why*, which is the difference between a refusal and a dead keystroke.
    public var onEditRefused: ((CellRef, SheetError) -> Void)? {
        didSet { attachCallbacks() }
    }

    public init() {}

    private func attachCallbacks() {
        host?.onEditTextChanged = onEditorTextChanged
        host?.onEditRefused = onEditRefused
    }

    /// Whether a grid is currently attached.
    public var isAttached: Bool { host != nil }

    /// Tints these cells with the accent and decays over six seconds.
    ///
    /// This is the "Claude changed this" signal (PLAN.md §3.1). The decay is driven by a display
    /// link that **stops** when the last cell reaches zero — call this as often as diffs arrive
    /// without leaving anything running.
    public func flash(_ refs: Set<CellRef>) {
        host?.flash(refs)
    }

    /// Cancels every flash immediately.
    public func cancelFlash() {
        host?.flashController.cancel()
    }

    /// Scrolls the minimum distance that brings `ref` into view.
    public func scroll(to ref: CellRef) {
        host?.scroll(to: ref)
    }

    /// Opens the in-cell editor. `nil` edits the active cell.
    ///
    /// `takingFocus: false` opens it as a mirror of an edit that is happening in the formula bar:
    /// the cell shows the text, the caret stays in the bar.
    public func beginEdit(at ref: CellRef? = nil, seed: String? = nil, takingFocus: Bool = true) {
        guard let host else { return }
        host.beginEdit(at: ref ?? host.model.selection.active, seed: seed, takingFocus: takingFocus)
    }

    /// Commits whatever is in the editor.
    public func commitEdit(advance: AdvanceDirection? = nil) {
        host?.editor.commit(advance: advance)
    }

    /// Abandons the edit.
    public func cancelEdit() {
        host?.editor.cancel()
    }

    /// Moves the caret the way a commit does — the shell's own commit, from the formula bar.
    ///
    /// Goes through ``GridNavigator``, which is what makes Return from the bar skip a hidden row
    /// and step out of a merged cell instead of landing inside one.
    public func advance(_ direction: AdvanceDirection, from selection: GridSelection? = nil) {
        host?.advanceSelection(direction, from: selection)
    }

    /// Closes the editor and says nothing.
    ///
    /// For the shell that has already committed the text itself — through the formula bar — and
    /// only needs the editor off the screen. Calling ``cancelEdit()`` there would emit a cancel
    /// for an edit that did land, and calling ``commitEdit(advance:)`` would write it twice.
    public func dismissEdit() {
        host?.editor.dismiss()
    }

    /// Whether the in-cell editor is open.
    public var isEditing: Bool { host?.editor.isEditing ?? false }

    /// The text in the editor, for keeping a formula bar in step.
    ///
    /// Setting it does **not** fire ``onEditorTextChanged`` — that is what makes the two-way
    /// mirror terminate instead of echoing.
    public var editorText: String {
        get { host?.editor.text ?? "" }
        set { host?.editor.mirror(newValue) }
    }

    /// The cells currently on screen.
    public var visibleRange: CellRange? { host?.visibleRange }

    /// Takes keyboard focus, so the arrow keys go to the grid.
    public func focus() {
        guard let host else { return }
        host.window?.makeFirstResponder(host.firstResponderTarget)
    }

    /// Turns the VoiceOver element tree on regardless of whether VoiceOver is running. Tests use
    /// it; a shell might too, if it wants the tree always live.
    public func setAccessibilityTreeAlwaysOn(_ enabled: Bool) {
        host?.setBuildsAccessibilityTree(enabled)
    }
}

/// The grid, for SwiftUI.
///
/// # Why this is the only `NSViewRepresentable` in the app
///
/// PLAN.md §2.2: SwiftUI cannot draw a million cells at 120 fps, and there is no honest way
/// around that. Everything *around* the grid is SwiftUI so it can use real Liquid Glass; the grid
/// itself is one AppKit view behind one representable, with a value-typed API on the outside so
/// the seam is as small as possible.
///
/// # Usage
///
/// ```swift
/// GridView(
///     workbook: document.workbook,
///     sheetID: document.activeSheetID,
///     selection: $document.selection,
///     theme: .dark,
///     controller: gridController
/// ) { event in
///     document.handle(event)
/// }
/// ```
public struct GridView: NSViewRepresentable {
    /// The workbook being shown. A value type: handing in a new one is the whole update path.
    public var workbook: Workbook
    /// Which sheet. An unknown id falls back to the first sheet rather than showing nothing.
    public var sheetID: SheetID
    /// The selection, two-way bound.
    @Binding public var selection: GridSelection
    /// Colours, fonts, and metrics. `GlassUI` supplies this; ``GridTheme/light`` and
    /// ``GridTheme/dark`` exist so the grid previews on its own.
    public var theme: GridTheme
    /// 1.0 is 100%.
    public var zoom: Double
    /// Behaviour switches.
    public var options: GridOptions
    /// Optional imperative handle.
    public var controller: GridController?
    /// Everything the grid asks the shell to do.
    public var onEvent: GridEventHandler?

    public init(
        workbook: Workbook,
        sheetID: SheetID,
        selection: Binding<GridSelection>,
        theme: GridTheme = .light,
        zoom: Double = 1,
        options: GridOptions = .default,
        controller: GridController? = nil,
        onEvent: GridEventHandler? = nil
    ) {
        self.workbook = workbook
        self.sheetID = sheetID
        _selection = selection
        self.theme = theme
        self.zoom = zoom
        self.options = options
        self.controller = controller
        self.onEvent = onEvent
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection, onEvent: onEvent)
    }

    public func makeNSView(context: Context) -> GridHostView {
        makeHost(coordinator: context.coordinator)
    }

    public func updateNSView(_ nsView: GridHostView, context: Context) {
        apply(to: nsView, coordinator: context.coordinator)
    }

    /// The body of ``makeNSView(context:)``, taking the coordinator directly.
    ///
    /// `NSViewRepresentable.Context` has no public initialiser, so a test cannot call the
    /// framework entry points. Splitting the work out is the difference between this path being
    /// covered and being taken on trust.
    func makeHost(coordinator: Coordinator) -> GridHostView {
        let view = GridHostView(model: renderModel)
        view.onEvent = { event in coordinator.handle(event) }
        controller?.host = view
        return view
    }

    /// The body of ``updateNSView(_:context:)``.
    func apply(to view: GridHostView, coordinator: Coordinator) {
        coordinator.selection = $selection
        coordinator.onEvent = onEvent
        controller?.host = view
        view.update(model: renderModel)
    }

    public static func dismantleNSView(_ nsView: GridHostView, coordinator: Coordinator) {
        nsView.flashController.cancel()
    }

    /// The sheet being drawn, falling back to the first one.
    private var sheet: Sheet {
        workbook[sheetID] ?? workbook.sheets.first ?? Sheet(id: sheetID, name: "Sheet1")
    }

    private var renderModel: GridRenderModel {
        let sheet = sheet
        return GridRenderModel(
            sheet: sheet,
            styles: workbook.styles,
            dateSystem: workbook.meta.dateSystem,
            theme: theme,
            options: options,
            geometry: GridGeometry(sheet: sheet, zoom: zoom),
            merges: MergeIndex(sheet.merges),
            selection: selection,
            flashTime: 0
        )
    }

    /// Keeps the SwiftUI binding and the AppKit view in step.
    @MainActor
    public final class Coordinator {
        var selection: Binding<GridSelection>
        var onEvent: GridEventHandler?

        init(selection: Binding<GridSelection>, onEvent: GridEventHandler?) {
            self.selection = selection
            self.onEvent = onEvent
        }

        func handle(_ event: GridEvent) {
            // The selection is state, so it goes back through the binding; everything else is an
            // instruction to the document, so it goes to the shell.
            if case let .selectionChanged(updated) = event, selection.wrappedValue != updated {
                selection.wrappedValue = updated
            }
            onEvent?(event)
        }
    }
}
