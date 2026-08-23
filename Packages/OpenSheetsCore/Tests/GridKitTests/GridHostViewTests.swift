import AppKit
import SheetModel
import Testing
@testable import GridKit

@Suite("Host view")
@MainActor
struct GridHostViewTests {
    private func host(
        cells: [(String, Cell)] = [("A1", .text("Alpha")), ("B1", .number(42)), ("A2", .text("Beta"))],
        frozen: FrozenPanes = .none,
        merges: [CellRange] = []
    ) -> GridHostView {
        var store = CellStore()
        for (address, cell) in cells {
            guard let ref = CellRef(a1: address) else { continue }
            try? store.setCell(cell, at: ref)
        }
        let sheet = Sheet(id: 1, name: "Report", cells: store, merges: merges, frozen: frozen)
        let model = GridRenderModel(
            sheet: sheet,
            styles: StyleTable(),
            geometry: GridGeometry(sheet: sheet),
            merges: MergeIndex(merges)
        )
        let view = GridHostView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        descendants(of: view).compactMap { $0 as? T }.first
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], characters: String = "") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ) ?? NSEvent()
    }

    // MARK: - Structure

    @Test("The hierarchy is a scroll view with a flipped document view, and chrome beside it")
    func hierarchy() {
        let view = host()
        let scroll = view.contentScrollView
        #expect(view.isFlipped)
        #expect(scroll.documentView?.isFlipped == true)
        #expect(scroll.documentView is GridDocumentView)
        // Headers, corner, three frozen panes, the divider overlay and the editor are **direct
        // subviews of the host**, not floating subviews of the scroll view. They are framed in
        // host coordinates on every layout pass, and `addFloatingSubview` re-parents them into a
        // container AppKit offsets by `contentInsets` — which put every one of them exactly one
        // header out of place in a real window. See `headersLineUpWithTheCellsTheyLabel`.
        let chrome = view.subviews
        #expect(chrome.contains { $0 is GridColumnHeaderView })
        #expect(chrome.contains { $0 is GridRowHeaderView })
        #expect(chrome.contains { $0 is GridCornerView })
        #expect(chrome.contains { $0 is CellEditor })
        #expect(chrome.filter { $0 is GridPaneView }.count == 3)
        #expect(descendants(of: scroll).allSatisfy { !($0 is GridColumnHeaderView) })
    }

    @Test("The document view is only as large as the scrolling quadrant")
    func documentSize() {
        let plain = host()
        let frozen = host(frozen: FrozenPanes(frozenRows: 2, frozenColumns: 1))
        guard let plainDocument = plain.contentScrollView.documentView,
              let frozenDocument = frozen.contentScrollView.documentView
        else {
            Issue.record("no document view")
            return
        }
        // Freezing two 24pt rows and one 76pt column takes exactly that much out of the scroll range.
        #expect(plainDocument.frame.height - frozenDocument.frame.height == 48)
        #expect(plainDocument.frame.width - frozenDocument.frame.width == 76)
    }

    @Test("Frozen pane views appear only when something is frozen")
    func frozenVisibility() {
        let plain = host()
        let frozen = host(frozen: FrozenPanes(frozenRows: 1, frozenColumns: 1))
        func visiblePanes(_ view: GridHostView) -> Int {
            view.subviews.compactMap { $0 as? GridPaneView }.filter { !$0.isHidden }.count
        }
        #expect(visiblePanes(plain) == 0)
        #expect(visiblePanes(frozen) == 3)
    }

    // MARK: - In a real window

    /// **The test the other 134 could not have failed.**
    ///
    /// Every other test in this suite calls `layoutSubtreeIfNeeded()` on a view that was never
    /// added to a window. AppKit's floating-subview pass never runs there, so for the whole of
    /// Wave 1 the row numbers sat on top of column A and the column letters sat one column across
    /// from the data they label — in the app, and in nothing else.
    ///
    /// So this one puts the grid in an `NSWindow` and asserts the headers against **the cells they
    /// label**, in window coordinates, which is the only claim that actually matters and the only
    /// one that fails when the header views are attached the wrong way. Under the defect it was
    /// off by exactly `contentInsets`, in both axes.
    @Test("Headers line up with the cells they label, in a real window")
    func headersLineUpWithTheCellsTheyLabel() throws {
        let view = try Self.hostInWindow()
        let geometry = view.model.geometry
        let scrollView = view.contentScrollView
        let document = try #require(scrollView.documentView)
        // Searched through the whole subtree, not just the host's own children: the point of this
        // test is *where the headers draw*, and it must keep failing on the geometry however they
        // come to be attached.
        let rowHeader = try #require(first(GridRowHeaderView.self, in: view))
        let columnHeader = try #require(first(GridColumnHeaderView.self, in: view))

        #expect(scrollView.contentInsets.top > 0, "the column header is paid for out of the insets")
        #expect(scrollView.contentInsets.left > 0, "and so is the row header")

        for row in [0, 3, 7] {
            let sheetY = geometry.sheetRect(row: row, column: 0).minY
            // Where the row header draws the number, and where the body draws the row.
            let label = rowHeader.convert(CGPoint(x: 0, y: sheetY - view.scrollOrigin.y), to: nil)
            let cell = document.convert(
                geometry.documentRect(fromSheet: geometry.sheetRect(row: row, column: 0)).origin, to: nil
            )
            #expect(
                abs(label.y - cell.y) < 0.5,
                "row \(row + 1)'s number draws at y=\(label.y) and its cells at y=\(cell.y)"
            )
        }

        for column in [0, 2, 5] {
            let sheetX = geometry.sheetRect(row: 0, column: column).minX
            let label = columnHeader.convert(CGPoint(x: sheetX - view.scrollOrigin.x, y: 0), to: nil)
            let cell = document.convert(
                geometry.documentRect(fromSheet: geometry.sheetRect(row: 0, column: column)).origin, to: nil
            )
            #expect(
                abs(label.x - cell.x) < 0.5,
                "column \(column + 1)'s letter draws at x=\(label.x) and its cells at x=\(cell.x)"
            )
        }

        // The corner is the origin of both strips, so it is the one frame that pins the pair.
        let corner = try #require(first(GridCornerView.self, in: view))
        #expect(corner.convert(corner.bounds, to: view) == corner.frame)
    }

    /// A shell inset is scroll range, not a mask: it comes off the viewport and off the resting
    /// position of the content, and the headers move with it.
    @Test("Shell content insets are added to the grid's own, and move the headers")
    func shellContentInsets() throws {
        let plain = try Self.hostInWindow()
        let ownInsets = plain.contentScrollView.contentInsets
        let ownViewport = plain.bodyViewportSize

        let inset = try Self.hostInWindow(insets: GridInsets(top: 80, left: 0, bottom: 40, right: 0))
        let insets = inset.contentScrollView.contentInsets
        #expect(insets.top == ownInsets.top + 80)
        #expect(insets.bottom == 40)
        #expect(inset.bodyViewportSize.height == ownViewport.height - 120)

        let corner = try #require(first(GridCornerView.self, in: inset))
        #expect(corner.frame.minY == 80, "the header strip sits below the chrome, not behind it")
        // Still lines up with the cells, which is the property the insets must not break.
        let geometry = inset.model.geometry
        let document = try #require(inset.contentScrollView.documentView)
        let rowHeader = try #require(first(GridRowHeaderView.self, in: inset))
        let sheetY = geometry.sheetRect(row: 4, column: 0).minY
        let label = rowHeader.convert(CGPoint(x: 0, y: sheetY - inset.scrollOrigin.y), to: nil)
        let cell = document.convert(
            geometry.documentRect(fromSheet: geometry.sheetRect(row: 4, column: 0)).origin, to: nil
        )
        #expect(abs(label.y - cell.y) < 0.5)
    }

    /// Keeps the window alive for the length of the test: an `NSWindow` that goes out of scope
    /// takes its content view's layout with it.
    nonisolated(unsafe) private static var retained: [NSWindow] = []

    private static func hostInWindow(insets: GridInsets = .zero) throws -> GridHostView {
        var store = CellStore()
        for row in 0 ..< 12 {
            for column in 0 ..< 6 {
                try store.setCell(.number(Double(row * 6 + column)), at: CellRef(row: row, column: column))
            }
        }
        let sheet = Sheet(id: 1, name: "Report", cells: store)
        var options = GridOptions.default
        options.contentInsets = insets
        let view = GridHostView(
            model: GridRenderModel(
                sheet: sheet,
                styles: StyleTable(),
                options: options,
                geometry: GridGeometry(sheet: sheet)
            )
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        retained.append(window)
        return view
    }

    // MARK: - Keyboard

    @Test("Arrows move the selection and ⌘arrows jump to the block edge")
    func arrows() {
        let view = host(cells: [
            ("A1", .number(1)), ("A2", .number(2)), ("A3", .number(3)), ("A9", .number(9)),
        ])
        #expect(view.handleKeyDown(key(125)))
        #expect(view.model.selection.active == CellRef(row: 1, column: 0))
        #expect(view.handleKeyDown(key(125, .command)))
        #expect(view.model.selection.active == CellRef(row: 2, column: 0))
        #expect(view.handleKeyDown(key(125, .command)))
        #expect(view.model.selection.active == CellRef(row: 8, column: 0))
    }

    @Test("Shift-arrow extends instead of moving")
    func shiftArrow() {
        let view = host()
        #expect(view.handleKeyDown(key(125, .shift)))
        #expect(view.handleKeyDown(key(124, .shift)))
        #expect(view.model.selection.activeRange == CellRange(rows: 0 ... 1, columns: 0 ... 1))
        #expect(view.model.selection.anchor == .origin)
    }

    @Test("Delete asks the shell to clear the selection")
    func delete() {
        let view = host()
        var events: [GridEvent] = []
        view.onEvent = { events.append($0) }
        #expect(view.handleKeyDown(key(51)))
        guard case let .clearContents(ranges)? = events.last else {
            Issue.record("expected a clearContents event, got \(events)")
            return
        }
        #expect(ranges == view.model.selection.ranges)
    }

    @Test("Typing a printable character starts an edit seeded with it")
    func typeToEdit() {
        let view = host()
        var events: [GridEvent] = []
        view.onEvent = { events.append($0) }
        #expect(view.handleKeyDown(key(0, [], characters: "7")))
        guard case let .beginEdit(ref, seed)? = events.last else {
            Issue.record("expected beginEdit, got \(events)")
            return
        }
        #expect(ref == .origin)
        #expect(seed == "7")
        #expect(view.editor.isEditing)
        #expect(view.editor.text == "7")
    }

    @Test("F2 opens the editor on the cell's existing text")
    func functionKeyTwo() {
        let view = host()
        #expect(view.handleKeyDown(key(120)))
        #expect(view.editor.isEditing)
        #expect(view.editor.text == "Alpha")
    }

    @Test("A formula gets the monospaced font, plain text does not")
    func editorFont() {
        let view = host(cells: [("A1", .formula("SUM(B1:B9)", cached: .number(3)))])
        view.beginEdit(at: .origin, seed: nil)
        #expect(view.editor.text == "=SUM(B1:B9)")
        #expect(view.editor.field.font?.isFixedPitch == true)

        view.editor.dismiss()
        let plain = host()
        plain.beginEdit(at: .origin, seed: nil)
        #expect(plain.editor.field.font?.fontName.contains("Mono") != true)
    }

    @Test("Committing an edit emits the raw text, unparsed")
    func commitEdit() {
        let view = host()
        var events: [GridEvent] = []
        view.onEvent = { events.append($0) }
        view.beginEdit(at: .origin, seed: "=SUM(A2:A9)")
        view.editor.commit(advance: .down)
        // A commit is followed by the caret moving, so the commit is not the last event.
        let commit = events.compactMap { event -> (CellRef, String, AdvanceDirection?)? in
            guard case let .commitEdit(ref, text, advance) = event else { return nil }
            return (ref, text, advance)
        }.last
        guard let (ref, text, advance) = commit else {
            Issue.record("expected commitEdit, got \(events)")
            return
        }
        #expect(ref == .origin)
        #expect(text == "=SUM(A2:A9)")
        #expect(advance == .down)
        #expect(!view.editor.isEditing)
    }

    @Test("Escape in the editor cancels without committing")
    func cancelEdit() {
        let view = host()
        var events: [GridEvent] = []
        view.onEvent = { events.append($0) }
        view.beginEdit(at: .origin, seed: "x")
        view.editor.cancel()
        guard case .cancelEdit? = events.last else {
            Issue.record("expected cancelEdit, got \(events)")
            return
        }
        #expect(!view.editor.isEditing)
    }

    @Test("Enter moves down; inside a selection it wraps")
    func enterAdvances() {
        let view = host()
        #expect(view.handleKeyDown(key(36)))
        #expect(view.model.selection.active == CellRef(row: 1, column: 0))

        var selection = GridSelection()
        selection.select(CellRange(rows: 0 ... 1, columns: 0 ... 1), active: .origin)
        view.setSelection(selection)
        #expect(view.handleKeyDown(key(36)))
        #expect(view.model.selection.active == CellRef(row: 1, column: 0))
        #expect(view.handleKeyDown(key(36)))
        #expect(view.model.selection.active == CellRef(row: 0, column: 1))
    }

    // MARK: - Headers

    @Test("Header divider hit testing finds the divider, not the middle of the column")
    func dividerHitTesting() {
        let view = host()
        #expect(view.columnDivider(nearSheetX: 76) == 0)
        #expect(view.columnDivider(nearSheetX: 152) == 1)
        #expect(view.columnDivider(nearSheetX: 40) == nil)
        #expect(view.rowDivider(nearSheetY: 24) == 0)
        #expect(view.rowDivider(nearSheetY: 12) == nil)
    }

    @Test("Clicking a header selects the whole row or column")
    func headerSelection() {
        let view = host()
        view.selectEntireColumn(2, extending: false, adding: false)
        #expect(view.model.selection.coversEntireColumn(2))
        view.selectEntireRow(4, extending: false, adding: true)
        #expect(view.model.selection.coversEntireRow(4))
        #expect(view.model.selection.ranges.count == 2)
        view.selectAll()
        #expect(view.model.selection.ranges == [CellRange.entireSheet])
    }

    @Test("Resizing a column emits a resize the shell can undo")
    func columnResize() {
        let view = host()
        var events: [GridEvent] = []
        view.onEvent = { events.append($0) }
        view.previewColumnResize(1, width: 200)
        #expect(view.model.geometry.columns.size(ofIndex: 1) == 200)
        view.commitColumnResize(1, width: 200)
        guard case let .columnsResized(columns, width)? = events.last else {
            Issue.record("expected columnsResized, got \(events)")
            return
        }
        #expect(columns == 1 ... 1)
        #expect(width == 200)
    }

    @Test("Double-clicking a divider suggests an auto-fit width")
    func autoFit() {
        let view = host(cells: [("A1", .text("A fairly long piece of text"))])
        var events: [GridEvent] = []
        view.onEvent = { events.append($0) }
        view.autoFitColumn(0)
        guard case let .autoFitColumns(columns, suggested)? = events.last else {
            Issue.record("expected autoFitColumns, got \(events)")
            return
        }
        #expect(columns == 0 ... 0)
        // Wide enough for the text, and not absurdly wide.
        #expect((suggested[0] ?? 0) > 76)
        #expect((suggested[0] ?? 0) < 400)
    }

    // MARK: - Fill handle

    @Test("The fill handle extends along whichever axis the drag went further in")
    func fillTarget() {
        let source = CellRange(rows: 0 ... 1, columns: 0 ... 0)
        let down = GridHostView.fillTarget(from: source, to: CellRef(row: 6, column: 0))
        #expect(down == CellRange(rows: 0 ... 6, columns: 0 ... 0))
        let right = GridHostView.fillTarget(from: source, to: CellRef(row: 1, column: 5))
        #expect(right == CellRange(rows: 0 ... 1, columns: 0 ... 5))
        let up = GridHostView.fillTarget(
            from: CellRange(rows: 4 ... 5, columns: 0 ... 0), to: CellRef(row: 0, column: 0)
        )
        #expect(up == CellRange(rows: 0 ... 5, columns: 0 ... 0))
    }

    // MARK: - Model updates

    @Test("Swapping the model updates the geometry and the data index")
    func modelUpdate() {
        let view = host()
        var sheet = view.model.sheet
        try? sheet.cells.setCell(Cell.number(5), at: CellRef(row: 20, column: 0))
        sheet.rowHeights.setValue(60, in: 0 ... 0)
        var updated = view.model
        updated.sheet = sheet
        updated.geometry = GridGeometry(sheet: sheet)
        view.update(model: updated)
        #expect(view.model.geometry.rows.size(ofIndex: 0) == 60)
        #expect(view.blocks.rowsWithData(inColumn: 0).contains(20))
    }

    @Test("Flashing marks cells as decaying — and reaches the renderer")
    func flash() {
        let view = host()
        let ref = CellRef(row: 1, column: 1)
        view.flash([ref])
        #expect(view.flashController.state.isActive)
        #expect(view.flashController.state.affectedRange == CellRange(ref))

        // The controller is not what draws. `GridRenderer.drawFlashTints` reads `model.flash` and
        // `model.flashTime`, so a flash that never lands in the model is a flash that decays
        // perfectly and is never once visible — which is exactly what shipped.
        #expect(view.model.flash.isActive)
        #expect(view.model.flash.intensity(of: ref, at: view.model.flashTime) > 0.5)

        // A model update from the shell — a selection change, a repaint — must not drop it.
        view.update(model: view.model)
        #expect(view.model.flash.isActive)

        view.flashController.cancel()
        #expect(!view.flashController.state.isActive)
        #expect(!view.model.flash.isActive)
    }

    // MARK: - Accessibility

    @Test("The grid is a table that reports the sheet's real extent")
    func accessibilityTable() {
        let view = host()
        view.setBuildsAccessibilityTree(true)
        #expect(view.accessibilityRole() == .table)
        #expect(view.accessibilityLabel() == "Report")
        #expect(view.accessibilityRowCount() == 2)
        #expect(view.accessibilityColumnCount() == 2)
        #expect((view.accessibilityRows() ?? []).isEmpty == false)
        #expect((view.accessibilityColumns() ?? []).isEmpty == false)
    }

    @Test("VoiceOver reads the active cell's address and its value")
    func accessibilityActiveCell() {
        let view = host()
        view.setBuildsAccessibilityTree(true)
        var selection = GridSelection()
        selection.select(CellRef(row: 0, column: 1))
        view.setSelection(selection)

        guard let focused = view.accessibilityFocusedUIElement() as? GridAccessibilityCell else {
            Issue.record("no focused element")
            return
        }
        #expect(focused.ref == CellRef(row: 0, column: 1))
        #expect(focused.accessibilityLabel() == "B1")
        #expect(focused.accessibilityValue() as? String == "42")
        #expect(focused.isAccessibilityFocused())
    }

    @Test("A cell can be reached by column and row, with its formula in the help text")
    func accessibilityCellLookup() {
        let view = host(cells: [
            ("A1", .text("Alpha")),
            ("B2", Cell(value: .number(7), formula: "SUM(A1:A9)", flags: .staleCache)),
        ])
        view.setBuildsAccessibilityTree(true)
        guard let cell = view.accessibilityCell(forColumn: 1, row: 1) as? GridAccessibilityCell else {
            Issue.record("no cell element")
            return
        }
        #expect(cell.accessibilityLabel() == "B2")
        #expect(cell.accessibilityValue() as? String == "7")
        let help = cell.accessibilityHelp() ?? ""
        #expect(help.contains("SUM(A1:A9)"))
        #expect(help.contains("not recalculated"))
    }

    @Test("A merged cell reports the span it really occupies")
    func accessibilityMergedRanges() {
        let merge = CellRange(rows: 0 ... 2, columns: 0 ... 1)
        let view = host(cells: [("A1", .text("Merged"))], merges: [merge])
        view.setBuildsAccessibilityTree(true)
        guard let cell = view.accessibilityCell(forColumn: 0, row: 0) as? GridAccessibilityCell else {
            Issue.record("no cell element")
            return
        }
        #expect(cell.accessibilityRowIndexRange() == NSRange(location: 0, length: 3))
        #expect(cell.accessibilityColumnIndexRange() == NSRange(location: 0, length: 2))
    }

    @Test("Rows carry their cells as children, in order")
    func accessibilityRowChildren() {
        let view = host()
        view.setBuildsAccessibilityTree(true)
        guard let row = (view.accessibilityRows() ?? []).first as? GridAccessibilityRow else {
            Issue.record("no row element")
            return
        }
        #expect(row.accessibilityIndex() == 0)
        #expect(row.accessibilityLabel() == "Row 1")
        let children = (row.accessibilityChildren() ?? []).compactMap { $0 as? GridAccessibilityCell }
        #expect(children.count > 1)
        #expect(children[0].ref == CellRef(row: 0, column: 0))
        #expect(children[1].ref == CellRef(row: 0, column: 1))
    }

    @Test("With VoiceOver off, no elements are built at all")
    func accessibilityIsFreeWhenUnused() {
        let view = host()
        view.setBuildsAccessibilityTree(false)
        #expect((view.accessibilityRows() ?? []).isEmpty)
        #expect((view.accessibilitySelectedCells() ?? []).isEmpty)
    }

    @Test("The element window is capped however large the viewport claims to be")
    func accessibilityWindowIsCapped() {
        let view = host()
        view.frame = CGRect(x: 0, y: 0, width: 4000, height: 40_000)
        view.layoutSubtreeIfNeeded()
        let window = view.accessibilityWindow
        #expect(window.rows.count <= 201)
        #expect(window.columns.count <= 65)
    }
}
