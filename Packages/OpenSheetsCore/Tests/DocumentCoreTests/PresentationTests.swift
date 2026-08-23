import DocumentCore
import Foundation
import GlassUI
import GridKit
import SheetModel
import SheetStore
import TestSupport
import Testing

/// Parsing, formatting, the design-system bridges, and the two safety affordances.
@Suite struct PresentationTests {
    // MARK: - PLAN.md §8: the input parsing order

    @Test(arguments: [
        ("=SUM(A1:A9)", "formula:SUM(A1:A9)"),
        ("'=SUM(A1:A9)", "text:=SUM(A1:A9)"),
        ("TRUE", "boolean:true"),
        ("false", "boolean:false"),
        ("1234", "number:1234.0"),
        ("1,234.50", "number:1234.5"),
        ("(1,234.50)", "number:-1234.5"),
        ("50%", "number:0.5"),
        ("12.5%", "number:0.125"),
        ("$1,234.50", "number:1234.5"),
        ("-$5", "number:-5.0"),
        ("1e3", "number:1000.0"),
        ("#N/A", "error:#N/A"),
        ("#DIV/0!", "error:#DIV/0!"),
        ("#CIRCULAR", "text:#CIRCULAR"),
        ("hello", "text:hello"),
        // Excel converts this in a General cell and keeps it only in a Text one —
        // see `aTextFormattedCellTakesTheInputVerbatim`.
        ("00123", "number:123.0"),
        ("1_0", "text:1_0"),
        ("nan", "text:nan"),
        ("0x10", "text:0x10"),
        ("", "empty"),
    ])
    func parsesTypedInputInPlanOrder(input: String, expected: String) {
        let parsed = CellInputParser.parse(input, locale: Locale(identifier: "en_US"))
        #expect(describe(parsed) == expected, "for input \(input.debugDescription)")
    }

    /// A leading zero survives when the cell is formatted as Text, and only then. That is what the
    /// format means, and it is the alternative to making everyone type an apostrophe.
    @Test func aTextFormattedCellTakesTheInputVerbatim() {
        let parsed = CellInputParser.parse("00123", format: .text)
        #expect(parsed.value == .text("00123"))
    }

    @Test func typingADateSuggestsADateFormat() {
        let parsed = CellInputParser.parse("2026-08-23", locale: Locale(identifier: "en_US"))
        #expect(parsed.suggestedNumberFormatID == 14)
        #expect(parsed.value.number != nil)
    }

    @Test func aBareTimeIsAFractionOfADay() throws {
        let parsed = CellInputParser.parse("14:30", locale: Locale(identifier: "en_US"))
        let value = try #require(parsed.value.number)
        #expect(abs(value - (14.5 / 24)) < 1e-9)
        #expect(parsed.suggestedNumberFormatID == 21)
    }

    @Test func typingAPercentageSuggestsAPercentFormatButOnlyIntoAGeneralCell() {
        let general = CellInputParser.parse("50%", locale: Locale(identifier: "en_US"))
        #expect(general.suggestedNumberFormatID == 9)
        let currency = CellInputParser.parse(
            "50%", format: NumberFormat("$#,##0.00"), locale: Locale(identifier: "en_US")
        )
        #expect(currency.suggestedNumberFormatID == nil, "an explicit format is not overridden")
        #expect(currency.value == .number(0.5))
    }

    private func describe(_ parsed: ParsedCellInput) -> String {
        if let formula = parsed.formula { return "formula:\(formula)" }
        switch parsed.value {
        case .empty: return "empty"
        case let .number(value): return "number:\(value)"
        case let .text(value): return "text:\(value)"
        case let .boolean(value): return "boolean:\(value)"
        case let .error(value): return "error:\(value.rawValue)"
        }
    }

    // MARK: - Fill

    @Test func aNumericPairContinuesAsASeries() throws {
        let sheet = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [[.number(10)], [.number(20)]])
            .buildSheet()
        let series = try #require(FillSeries.detect(CellRange(a1: "A1:A2")!, in: sheet, alongRows: true))
        #expect(series == .arithmetic(start: 10, step: 10))
        #expect(series.value(at: 2, template: Cell.number(0)).value == .number(30))
    }

    @Test func aNumberedTextPairContinuesAndKeepsItsPadding() throws {
        let sheet = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [[.text("Item 007")], [.text("Item 008")]])
            .buildSheet()
        let series = try #require(FillSeries.detect(CellRange(a1: "A1:A2")!, in: sheet, alongRows: true))
        #expect(series.value(at: 2, template: Cell.text("")).value == .text("Item 009"))
    }

    @Test func anUnrecognisedPairCopies() throws {
        let sheet = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [[.text("alpha")], [.text("beta")]])
            .buildSheet()
        #expect(FillSeries.detect(CellRange(a1: "A1:A2")!, in: sheet, alongRows: true) == .copy)
    }

    @Test func fillDownTranslatesFormulasRatherThanRepeatingThem() throws {
        var workbook = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [[.number(1)], [.number(2)], [.number(3)]])
            .formula("B1", "A1*2", cached: .number(2))
            .build()
        let sheetID = workbook.sheets[0].id
        _ = WorkbookEditor.fill(
            from: CellRange(CellRef(a1: "B1")!),
            to: CellRange(a1: "B1:B3")!,
            on: sheetID, in: &workbook, selection: GridSelection()
        )
        #expect(workbook[sheetID]?.cells[CellRef(a1: "B2")!]?.formula == "A2*2")
        #expect(workbook[sheetID]?.cells[CellRef(a1: "B3")!]?.formula == "A3*2")
        // Addendum §11: a filled formula has not been computed yet, so it is marked stale rather
        // than shown carrying the source cell's cached number as if it were its own.
        #expect(workbook[sheetID]?.cells[CellRef(a1: "B3")!]?.flags.contains(.staleCache) == true)
    }

    // MARK: - Clipboard

    @Test func theTextPasteboardRoundTripsThroughTheParser() throws {
        let payload = try #require(
            ClipboardPayload.parsingText("1\t2\n#N/A\t=A1+1\n", at: .origin)
        )
        #expect(payload.rowCount == 2)
        #expect(payload.columnCount == 2)
        #expect(payload[0, 0]?.value == .number(1))
        #expect(payload[1, 0]?.value == .error(.notAvailable))
        #expect(payload[1, 1]?.formula == "A1+1")
    }

    @Test func aCellContainingATabIsQuotedRatherThanBreakingTheRow() {
        let payload = ClipboardPayload(
            rowCount: 1, columnCount: 2, origin: .origin,
            cells: [Cell.text("a\tb"), Cell.text("c")]
        )
        let text = payload.tabSeparatedText { $0?.value.text ?? "" }
        #expect(text == "\"a\tb\"\tc")
    }

    @Test func theRichPayloadSurvivesEncoding() throws {
        let payload = ClipboardPayload(
            rowCount: 1, columnCount: 1, origin: CellRef(row: 3, column: 4),
            cells: [Cell.formula("SUM(A1:A9)", cached: .number(12), styleID: StyleID(3))],
            styles: [StyleID(3): CellStyle()]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClipboardPayload.self, from: data)
        #expect(decoded == payload)
    }

    // MARK: - The diff, as the panel sees it

    @Test func theDiffPanelFormatsValuesWithTheCellsOwnFormat() throws {
        let workbook = try WorkbookBuilder()
            .sheet("Q4")
            .rows("A1", [[.number(120)]])
            .style("A1", CellStyle(numberFormatID: 44))
            .build()
        let currency = try #require(workbook[workbook.sheets[0].id]?.cells[CellRef(a1: "A1")!]?.styleID)

        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: workbook.sheets[0].id,
                sheetName: "Q4",
                cellChanges: [
                    SheetModel.CellChange(
                        ref: CellRef(a1: "A1")!,
                        before: Cell(value: .number(120), styleID: currency),
                        after: Cell(value: .number(129.6), styleID: currency),
                        kind: .valueChanged
                    ),
                ],
                changedCount: 1
            ),
        ])

        let changeSet = SyncPresentation.changeSet(
            for: diff, workbook: workbook, state: .stale,
            localEditCount: 0, isWatching: true
        )
        let row = try #require(changeSet.changes.first)
        #expect(row.before.contains("120"))
        #expect(row.after.contains("129.6"))
        #expect(changeSet.notice.signal == .agent)
        #expect(changeSet.notice.shortcut == "⌘R")
    }

    @Test func unsavedEditsTurnTheNoticeIntoAConflict() {
        let notice = SyncPresentation.notice(
            for: WorkbookDiff(), state: .conflict, localEditCount: 3, isWatching: true
        )
        #expect(notice.signal == .conflict)
        #expect(notice.headline == "Conflict")
        #expect(notice.localEditCount == 3)
        #expect(notice.shortcut == nil, "⌘R must not be advertised while it would clobber")
    }

    @Test func aRenameWithNoCellChangesStillAppearsInThePanel() {
        let diff = WorkbookDiff(
            renamedSheets: [SheetRename(id: SheetID(1), before: "Assumptions", after: "Assumptions v2")]
        )
        let changeSet = SyncPresentation.changeSet(
            for: diff, workbook: Workbook.blank(), state: .stale, localEditCount: 0, isWatching: true
        )
        #expect(changeSet.sheets.contains { $0.renamedFrom == "Assumptions" })
    }

    @Test(arguments: DocumentSyncState.allCases)
    func everySyncStateHasAChip(state: DocumentSyncState) {
        let chip = SyncPresentation.chip(
            for: state, pendingCellCount: 42, localEditCount: 3,
            isWatching: true, readOnlyReason: .fileSystemPermissions
        )
        #expect(!chip.label.isEmpty)
        #expect(!chip.detail.isEmpty, "every state must say what to do about it")
    }

    /// PLAN.md §1.4 and §9: every blocked state is a designed glass state, never an alert dump.
    @Test(arguments: DocumentSyncState.allCases.filter(\.isBlocked))
    func everyBlockedStateHasADesignedEmptyState(state: DocumentSyncState) throws {
        let model = SyncPresentation.emptyState(
            for: state, fileName: "budget.xlsx", sheetCount: 1,
            readOnlyReason: nil, lastError: nil
        )
        if state == .readOnly {
            #expect(model == nil, "read-only shows the workbook, with a banner")
        } else {
            let unwrapped = try #require(model)
            #expect(!unwrapped.title.isEmpty)
            #expect(unwrapped.primaryLabel != nil, "an unhappy state must offer a way out")
        }
    }

    // MARK: - Addendum §6: one appearance, two renderers

    @Test(arguments: AppearanceContext.snapshotMatrix)
    func theGridThemeFollowsTheInjectedAppearance(context: AppearanceContext) {
        let glass = GlassUI.GridTheme.resolved(context)
        let grid = GridThemeBridge.convert(glass, context: context)
        #expect(grid.increaseContrast == context.increaseContrast)
        #expect(grid.canvasBackground.alpha == 255, "the one opaque plane must be opaque")
        #expect(grid.defaultRowHeight == Double(glass.defaultRowHeight))
        #expect(abs(grid.selectionFillOpacity - glass.selectionFill.alpha) < 0.001)
        #expect(grid.headerHeight == Double(glass.headerRowHeight))
    }

    @Test func lightAndDarkProduceDifferentGridThemes() {
        let light = GridThemeBridge.resolved(.light)
        let dark = GridThemeBridge.resolved(.dark)
        #expect(light.canvasBackground != dark.canvasBackground)
        #expect(light.cellText != dark.cellText)
    }

    // MARK: - Addendum §5: known staleness is disclosed

    @Test func aWorkbookWithAChartWarnsOnTheFirstEdit() throws {
        var workbook = try Fixtures.workbook()
        workbook.passthrough = OpaqueParts(entries: [
            ZipEntry(path: "xl/charts/chart1.xml", compressedData: Data()),
        ])
        let notice = StalenessNotice.detect(in: workbook)
        #expect(notice.reasons.contains(.charts))
        #expect(notice.forCellEdit().reasons == [.charts])
        #expect(!notice.summary.isEmpty)
    }

    @Test func aPlainWorkbookWarnsAboutNothing() throws {
        #expect(StalenessNotice.detect(in: try Fixtures.workbook()).isEmpty)
    }

    @Test func macrosAreDisclosedButNotForACellEdit() throws {
        var workbook = try Fixtures.workbook()
        workbook.meta.containsMacros = true
        let notice = StalenessNotice.detect(in: workbook)
        #expect(notice.reasons == [.macros])
        #expect(notice.forCellEdit().isEmpty, "a cell edit does not make macros any staler")
    }

    // MARK: - PLAN.md §12: `claude`, typed and not run

    @MainActor
    @Test(arguments: TerminalLauncher.Terminal.allCases)
    func theTerminalScriptTypesTheCommandWithoutRunningIt(terminal: TerminalLauncher.Terminal) {
        let script = TerminalLauncher.script(
            for: terminal,
            directory: URL(fileURLWithPath: "/Users/q/work/finance"),
            command: "claude"
        )
        #expect(script.contains("keystroke \"claude\""))
        #expect(!script.contains("keystroke return"))
        #expect(!script.contains("key code 36"))
        // The only `do script` / `write text` in it is the `cd`, which is navigation.
        let runs = script.components(separatedBy: "\n").filter {
            $0.contains("do script") || $0.contains("write text")
        }
        #expect(runs.allSatisfy { $0.contains("cd ") || $0.contains("do script \"\"") })
    }

    @MainActor
    @Test func aPathWithAQuoteInItIsEscaped() {
        let script = TerminalLauncher.script(
            for: .terminal,
            directory: URL(fileURLWithPath: "/Users/q/it's \"fine\""),
            command: "claude"
        )
        #expect(!script.contains("/Users/q/it's \"fine\""))
        #expect(script.contains("\\\""))
    }

    // MARK: - Selection statistics

    @Test func theStatsPillFormatsWithTheSelectionsOwnFormat() throws {
        let workbook = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [[.number(1000)], [.number(2000)]])
            .style("A1", CellStyle(numberFormatID: 44))
            .style("A2", CellStyle(numberFormatID: 44))
            .build()

        var selection = GridSelection()
        selection.select(CellRange(a1: "A1:A2")!)
        let stats = SelectionStatistics.compute(
            selection: selection,
            sheet: workbook.sheets[0],
            styles: workbook.styles,
            dateSystem: .excel1900
        )
        #expect(stats.values[.count] == "2")
        #expect(stats.values[.sum]?.contains("3,000") == true)
        #expect(stats.rangeLabel == "A1:A2")
    }

    @Test func aTextOnlySelectionHasNoAverage() throws {
        let workbook = try WorkbookBuilder()
            .sheet("S")
            .rows("A1", [[.text("a")], [.text("b")]])
            .build()
        var selection = GridSelection()
        selection.select(CellRange(a1: "A1:A2")!)
        let stats = SelectionStatistics.compute(
            selection: selection, sheet: workbook.sheets[0],
            styles: workbook.styles, dateSystem: .excel1900
        )
        #expect(stats.values[.average] == nil, "there is no average of a column of text")
        #expect(stats.values[.count] == "2")
    }

    @Test func aBlockShowsItsShapeRatherThanItsAddress() {
        var selection = GridSelection()
        selection.select(CellRange(a1: "B2:D42")!)
        #expect(SelectionStatistics.label(for: selection) == "41R × 3C")
    }

    // MARK: - Decimal places

    @Test(arguments: [
        ("0.00", 1, "0.000"),
        ("0.00", -1, "0.0"),
        ("0.0", -1, "0"),
        ("0", -1, "0"),
        ("$#,##0.00", 1, "$#,##0.000"),
        ("#,##0", 1, "#,##0.0"),
        ("0.00%", 1, "0.000%"),
        ("General", 1, "0.0"),
    ])
    func addsAndRemovesDecimalPlacesWithoutLosingTheFormat(
        code: String, delta: Int, expected: String
    ) {
        let adjusted = NumberFormatDecimals.adjusting(NumberFormat(code), by: delta)
        if code == "0" || (code == "0.0" && delta == -1 && expected == "0") {
            // "0" minus a decimal is a no-op; "0.0" minus one really does become "0".
            #expect(adjusted?.formatCode ?? code == expected)
        } else {
            #expect(adjusted?.formatCode == expected, "\(code) \(delta > 0 ? "+" : "")\(delta)")
        }
    }

    @Test func everySectionOfAMultiSectionCodeMovesTogether() throws {
        let adjusted = try #require(
            NumberFormatDecimals.adjusting(NumberFormat("#,##0.00;[Red](#,##0.00)"), by: 1)
        )
        #expect(adjusted.formatCode == "#,##0.000;[Red](#,##0.000)")
    }

    @Test func aDateFormatRefusesDecimalPlaces() {
        #expect(NumberFormatDecimals.adjusting(NumberFormat("d mmm yy"), by: 1) == nil)
    }

    @Test func aTextFormatRefusesDecimalPlaces() {
        #expect(NumberFormatDecimals.adjusting(.text, by: 1) == nil)
    }

    // MARK: - The palette

    @Test func aCellReferenceShortCircuitsToTheTop() throws {
        let workbook = try Fixtures.workbook()
        let built = CommandRegistry.sections(
            query: "D14", workbook: workbook, definedNames: [],
            canUndo: false, canRedo: false, canRefresh: true, canSave: false
        )
        #expect(built.sections.first?.id == "goto")
        #expect(built.commands["goto"] == .goToCell(CellRef(a1: "D14")!))
    }

    @Test func disabledCommandsAreShownRatherThanHidden() throws {
        let workbook = try Fixtures.workbook()
        let built = CommandRegistry.sections(
            query: "undo", workbook: workbook, definedNames: [],
            canUndo: false, canRedo: false, canRefresh: false, canSave: false
        )
        let undo = try #require(built.sections.flatMap(\.items).first { $0.id == "undo" })
        #expect(!undo.isEnabled)
    }
}
