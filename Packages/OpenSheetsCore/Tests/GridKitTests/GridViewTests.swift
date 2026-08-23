import AppKit
import SheetModel
import SwiftUI
import Testing
@testable import GridKit

@Suite("SwiftUI surface")
@MainActor
struct GridViewTests {
    @Test("The demo workbooks are valid sheets")
    func demoWorkbooksValidate() throws {
        for workbook in [
            GridDemoWorkbook.make(rows: 40, columns: 12),
            GridDemoWorkbook.make(rows: 40, columns: 12, frozen: (3, 2), merges: true),
            GridDemoWorkbook.frozenAndMerged(),
        ] {
            try workbook.validate()
        }
    }

    @Test("The frozen-and-merged fixture really does straddle both boundaries")
    func straddlingFixture() {
        let workbook = GridDemoWorkbook.frozenAndMerged()
        let sheet = workbook.sheets[0]
        #expect(sheet.frozen.frozenRows == 2)
        #expect(sheet.frozen.frozenColumns == 2)
        // One merge crosses the vertical divider, one crosses the horizontal one, one is wholly
        // inside the corner — the three cases the renderer has to get right.
        #expect(sheet.merges.contains { $0.start.column < 2 && $0.end.column >= 2 })
        #expect(sheet.merges.contains { $0.start.row < 2 && $0.end.row >= 2 })
        #expect(sheet.merges.contains { $0.end.row < 2 && $0.end.column < 2 })
    }

    @Test("Making and updating the view swaps the model without rebuilding it")
    func representableLifecycle() {
        let workbook = GridDemoWorkbook.make(rows: 30, columns: 8)
        var selection = GridSelection()
        let controller = GridController()
        var events: [GridEvent] = []

        let binding = Binding(get: { selection }, set: { selection = $0 })
        var view = GridView(
            workbook: workbook,
            sheetID: workbook.sheets[0].id,
            selection: binding,
            theme: .dark,
            controller: controller
        ) { events.append($0) }

        let coordinator = view.makeCoordinator()
        let host = view.makeHost(coordinator: coordinator)
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        host.layoutSubtreeIfNeeded()
        #expect(controller.isAttached)
        #expect(host.model.theme == GridTheme.dark)
        #expect(host.model.sheet.cells.count == workbook.cellCount)

        view.zoom = 2
        view.apply(to: host, coordinator: coordinator)
        #expect(host.model.geometry.zoom == 2)
        #expect(host.model.geometry.rows.size(ofIndex: 1) == 48)

        // A selection change inside the grid flows back out through the binding.
        var moved = GridSelection()
        moved.select(CellRef(row: 3, column: 2))
        coordinator.handle(.selectionChanged(moved))
        #expect(selection.active == CellRef(row: 3, column: 2))
        // The shell sees the selection change too — plus whatever visible-range events the layout
        // produced, which is why this counts the kind rather than the total.
        let selectionEvents = events.filter { if case .selectionChanged = $0 { true } else { false } }
        #expect(selectionEvents.count == 1)
    }

    @Test("An unknown sheet id falls back to the first sheet rather than showing nothing")
    func unknownSheetFallback() {
        let workbook = GridDemoWorkbook.make(rows: 10, columns: 4)
        var selection = GridSelection()
        let view = GridView(
            workbook: workbook,
            sheetID: SheetID(999),
            selection: Binding(get: { selection }, set: { selection = $0 })
        )
        let host = view.makeHost(coordinator: view.makeCoordinator())
        #expect(host.model.sheet.id == workbook.sheets[0].id)
    }

    @Test("A detached controller is inert rather than crashing")
    func detachedController() {
        let controller = GridController()
        #expect(!controller.isAttached)
        controller.flash([CellRef.origin])
        controller.scroll(to: CellRef(row: 5, column: 5))
        controller.beginEdit()
        controller.cancelEdit()
        #expect(!controller.isEditing)
        #expect(controller.visibleRange == nil)
        #expect(controller.editorText.isEmpty)
    }

    @Test("The controller drives a real grid")
    func attachedController() {
        let workbook = GridDemoWorkbook.make(rows: 40, columns: 8)
        var selection = GridSelection()
        let controller = GridController()
        let view = GridView(
            workbook: workbook,
            sheetID: workbook.sheets[0].id,
            selection: Binding(get: { selection }, set: { selection = $0 }),
            controller: controller
        )
        let host = view.makeHost(coordinator: view.makeCoordinator())
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
        host.layoutSubtreeIfNeeded()

        controller.flash([CellRef(row: 2, column: 2), CellRef(row: 3, column: 2)])
        #expect(host.flashController.state.count == 2)
        controller.cancelFlash()
        #expect(!host.flashController.state.isActive)

        controller.beginEdit(at: CellRef(row: 1, column: 0), seed: "hello")
        #expect(controller.isEditing)
        #expect(controller.editorText == "hello")
        controller.cancelEdit()
        #expect(!controller.isEditing)
        #expect(controller.visibleRange != nil)
    }

}
