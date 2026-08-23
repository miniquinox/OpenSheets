import Foundation
@testable import SheetModel
import Testing

@Suite("Diff shapes")
struct DiffTests {
    private func ref(_ a1: String) throws -> CellRef { try #require(CellRef(a1: a1)) }

    @Test("classify reports the most interesting difference, not the first one")
    func classification() throws {
        let target = try ref("D2")
        let old = Cell.number(120)
        let new = Cell.number(129.6)

        #expect(CellChange.classify(ref: target, before: nil, after: nil) == nil)
        #expect(CellChange.classify(ref: target, before: old, after: old) == nil)
        #expect(CellChange.classify(ref: target, before: nil, after: new)?.kind == .added)
        #expect(CellChange.classify(ref: target, before: old, after: nil)?.kind == .removed)
        #expect(CellChange.classify(ref: target, before: old, after: new)?.kind == .valueChanged)

        // A formula edit usually moves the cached value too. Reporting that as `valueChanged`
        // would hide the half the user actually cares about.
        let before = Cell.formula("B2*1.05", cached: .number(120))
        let after = Cell.formula("B2*1.08", cached: .number(129.6))
        #expect(CellChange.classify(ref: target, before: before, after: after)?.kind == .formulaChanged)

        // A reformat is its own kind, so the grid can skip flashing for it.
        let plain = Cell(value: .number(1), styleID: .default)
        let styled = Cell(value: .number(1), styleID: StyleID(4))
        #expect(CellChange.classify(ref: target, before: plain, after: styled)?.kind == .styleChanged)
    }

    @Test("a change carries both sides so the panel can show '120 → 129.6'")
    func changePayload() throws {
        let change = try #require(CellChange.classify(
            ref: try ref("D2"), before: .number(120), after: .number(129.6)
        ))
        #expect(change.ref.a1String == "D2")
        #expect(change.before?.value == .number(120))
        #expect(change.after?.value == .number(129.6))
    }

    @Test("structural changes summarise in the words the panel uses")
    func structuralSummaries() {
        #expect(StructuralChange(kind: .insertedRows, index: 4, count: 1).summary == "inserted 1 row at 5")
        #expect(StructuralChange(kind: .insertedRows, index: 4, count: 3).summary == "inserted 3 rows at 5")
        #expect(StructuralChange(kind: .deletedRows, index: 0, count: 2).summary == "deleted 2 rows at 1")
        #expect(StructuralChange(kind: .insertedColumns, index: 3, count: 1).summary == "inserted 1 column at D")
        #expect(StructuralChange(kind: .deletedColumns, index: 26, count: 2).summary == "deleted 2 columns at AA")
    }

    @Test("a sheet diff separates what it listed from what it counted")
    func sheetDiffCounts() throws {
        var diff = SheetDiff(sheetID: SheetID(1), sheetName: "Data")
        #expect(diff.isEmpty)
        #expect(diff.totalCellChangeCount == 0)
        #expect(diff.changedRefs.isEmpty)

        diff = SheetDiff(
            sheetID: SheetID(1), sheetName: "Data",
            cellChanges: [
                CellChange(ref: try ref("A1"), before: nil, after: .number(1), kind: .added),
                CellChange(ref: try ref("B1"), before: .number(1), after: .number(2), kind: .valueChanged),
            ],
            omittedCellChangeCount: 4998,
            addedCount: 1, removedCount: 0, changedCount: 4999
        )
        #expect(!diff.isEmpty)
        #expect(diff.totalCellChangeCount == 5000, "the counts cover changes the list had to omit")
        #expect(diff.cellChanges.count == 2)
        #expect(diff.omittedCellChangeCount == 4998)
        #expect(diff.changedRefs == Set([try ref("A1"), try ref("B1")]))
    }

    @Test("a structural-only diff is not empty")
    func structuralOnlyDiff() {
        let diff = SheetDiff(
            sheetID: SheetID(1), sheetName: "Data",
            structuralChanges: [StructuralChange(kind: .insertedRows, index: 4, count: 1)]
        )
        #expect(!diff.isEmpty)
        #expect(diff.totalCellChangeCount == 0)
    }

    @Test("an empty workbook diff says so")
    func emptyWorkbookDiff() {
        let diff = WorkbookDiff.empty
        #expect(diff.isEmpty)
        #expect(diff.summary == "no changes")
        #expect(diff.totalCellChangeCount == 0)
        #expect(diff.changedSheetCount == 0)
        #expect(diff.flashSets.isEmpty)
        #expect(!diff.wasTruncated)
    }

    @Test("the summary is the refresh pill's line")
    func pillSummary() throws {
        let oneSheet = WorkbookDiff(sheetDiffs: [
            SheetDiff(sheetID: SheetID(1), sheetName: "Data", changedCount: 42),
        ])
        #expect(oneSheet.summary == "1 sheet, 42 cells")

        let twoSheets = WorkbookDiff(sheetDiffs: [
            SheetDiff(sheetID: SheetID(1), sheetName: "Data", changedCount: 42),
            SheetDiff(sheetID: SheetID(2), sheetName: "Summary", addedCount: 1),
        ])
        #expect(twoSheets.summary == "2 sheets, 43 cells")

        let singular = WorkbookDiff(sheetDiffs: [
            SheetDiff(sheetID: SheetID(1), sheetName: "Data", changedCount: 1),
        ])
        #expect(singular.summary == "1 sheet, 1 cell")

        // An unchanged sheet in the list does not inflate the count.
        let mixed = WorkbookDiff(sheetDiffs: [
            SheetDiff(sheetID: SheetID(1), sheetName: "Data", changedCount: 3),
            SheetDiff(sheetID: SheetID(2), sheetName: "Untouched"),
        ])
        #expect(mixed.changedSheetCount == 1)
        #expect(mixed.summary == "1 sheet, 3 cells")
    }

    @Test("added, removed, and renamed sheets appear in the summary")
    func sheetLevelSummary() {
        let diff = WorkbookDiff(
            sheetDiffs: [SheetDiff(sheetID: SheetID(1), sheetName: "Data", changedCount: 2)],
            addedSheets: [SheetSummary(id: SheetID(3), name: "Q4", cellCount: 320)],
            removedSheets: [SheetSummary(id: SheetID(4), name: "Old", cellCount: 10)],
            renamedSheets: [SheetRename(id: SheetID(1), before: "Sheet1", after: "Data")]
        )
        #expect(!diff.isEmpty)
        #expect(diff.summary.contains("1 sheet added"))
        #expect(diff.summary.contains("1 sheet removed"))
        #expect(diff.summary.contains("1 renamed"))
        #expect(diff.summary.contains("1 sheet, 2 cells"))
    }

    @Test("a diff with only a rename is still a change")
    func renameOnlyDiff() {
        let diff = WorkbookDiff(renamedSheets: [SheetRename(id: SheetID(1), before: "Sheet1", after: "Data")])
        #expect(!diff.isEmpty)
        #expect(diff.summary == "1 renamed")
    }

    @Test("flash sets are keyed by sheet, for the post-refresh highlight")
    func flashSets() throws {
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: SheetID(1), sheetName: "Data",
                cellChanges: [CellChange(
                    ref: try ref("D2"),
                    before: .number(1),
                    after: .number(2),
                    kind: .valueChanged
                )]
            ),
            SheetDiff(sheetID: SheetID(2), sheetName: "Summary"),
        ])
        #expect(diff.flashSets.count == 2)
        #expect(diff.flashSets[SheetID(1)] == Set([try ref("D2")]))
        #expect(diff.flashSets[SheetID(2)]?.isEmpty == true)
    }

    @Test("the reported cell list is capped, and the cap is a named limit")
    func capIsNamed() {
        #expect(Limits.maxDiffCellChanges == 5000)
    }
}

@Suite("Value shorthands and accessors")
struct ValueAccessorTests {
    @Test("cell shorthands build what they say")
    func cellShorthands() {
        #expect(Cell.number(42).value == .number(42))
        #expect(Cell.text("hi").value == .text("hi"))
        #expect(Cell.boolean(true).value == .boolean(true))
        #expect(Cell.error(.divideByZero).value == .error(.divideByZero))
        #expect(Cell.styled(StyleID(3)).styleID == StyleID(3))
        #expect(Cell.styled(StyleID(3)).value == .empty)

        let formula = Cell.formula("SUM(A1:A9)", cached: .number(42), styleID: StyleID(2), flags: .staleCache)
        #expect(formula.formula == "SUM(A1:A9)")
        #expect(formula.value == .number(42))
        #expect(formula.styleID == StyleID(2))
        #expect(formula.flags.contains(.staleCache))
        #expect(formula.isFormula)
        #expect(!Cell.number(1).isFormula)

        #expect(Cell.number(1, styleID: StyleID(9)).styleID == StyleID(9))
        #expect(Cell.text("x", styleID: StyleID(9)).styleID == StyleID(9))
        #expect(Cell.boolean(false, styleID: StyleID(9)).styleID == StyleID(9))
        #expect(Cell.error(.notAvailable, styleID: StyleID(9)).styleID == StyleID(9))
    }

    @Test("isBlank means indistinguishable from an absent cell")
    func blankness() {
        #expect(Cell().isBlank)
        #expect(!Cell.number(0).isBlank)
        #expect(!Cell.text("").isBlank, "an empty string is not an empty cell")
        #expect(!Cell.styled(StyleID(1)).isBlank)
        #expect(!Cell(value: .empty, flags: .staleCache).isBlank)
        #expect(!Cell(value: .empty, formula: "A1").isBlank)
    }

    @Test("value accessors never coerce")
    func accessorsDoNotCoerce() {
        #expect(CellValue.number(42).number == 42)
        #expect(CellValue.text("42").number == nil, "text is not silently a number")
        #expect(CellValue.boolean(true).number == nil, "a boolean is not silently 1")
        #expect(CellValue.text("hi").text == "hi")
        #expect(CellValue.number(1).text == nil)
        #expect(CellValue.boolean(false).boolean == false)
        #expect(CellValue.number(0).boolean == nil)
        #expect(CellValue.error(.notAvailable).error == .notAvailable)
        #expect(CellValue.number(1).error == nil)
        #expect(CellValue.empty.isEmpty)
        #expect(!CellValue.text("").isEmpty)
        #expect(CellValue.error(.divideByZero).isError)
        #expect(!CellValue.number(1).isError)
    }

    @Test("two NaNs compare equal, so a damaged file cannot cause a refresh loop")
    func nanEquality() {
        #expect(CellValue.number(.nan) == CellValue.number(.nan))
        #expect(CellValue.number(.nan) != CellValue.number(1))
        #expect(Set([CellValue.number(.nan), .number(.nan)]).count == 1)
        // Signed zero still compares equal, which is what a spreadsheet means.
        #expect(CellValue.number(0) == CellValue.number(-0.0))
        #expect(CellValue.number(.infinity) == CellValue.number(.infinity))
    }

    @Test("literals build cell values, which is what makes test fixtures readable")
    func literals() {
        let asInteger: CellValue = 42
        let asDouble: CellValue = 4.5
        let asString: CellValue = "hi"
        let asBool: CellValue = true
        #expect(asInteger == .number(42))
        #expect(asDouble == .number(4.5))
        #expect(asString == .text("hi"))
        #expect(asBool == .boolean(true))
    }

    @Test("error tokens are the strings Excel writes")
    func errorTokens() {
        #expect(CellError.divideByZero.rawValue == "#DIV/0!")
        #expect(CellError.invalidReference.rawValue == "#REF!")
        #expect(CellError.unknownName.rawValue == "#NAME?")
        #expect(CellError.wrongType.rawValue == "#VALUE!")
        #expect(CellError.notAvailable.rawValue == "#N/A")
        #expect(CellError.nullIntersection.rawValue == "#NULL!")
        #expect(CellError.invalidNumber.rawValue == "#NUM!")
        #expect(CellError(rawValue: "#DIV/0!") == .divideByZero)
        #expect(CellError(rawValue: "#NOPE!") == nil)
    }

    @Test("#CIRCULAR is ours, and never reaches a file")
    func circularIsNotExcels() {
        #expect(!CellError.circular.isExcelNative)
        #expect(CellError.circular.rawValue == "#CIRCULAR")
        #expect(CellError.circular.xlsxToken == "#VALUE!", "Excel refuses to open a file containing #CIRCULAR")

        for error in CellError.allCases where error != .circular {
            #expect(error.isExcelNative)
            #expect(error.xlsxToken == error.rawValue)
        }
    }

    @Test("descriptions are for debugging, not for the grid")
    func descriptions() {
        #expect(CellValue.empty.description == "<empty>")
        #expect(CellValue.text("hi").description == "\"hi\"")
        #expect(CellValue.boolean(true).description == "TRUE")
        #expect(CellValue.boolean(false).description == "FALSE")
        #expect(CellValue.error(.notAvailable).description == "#N/A")
        #expect(CellValue.number(1.5).description.contains("1.5"))

        #expect(Cell.formula("A1*2", cached: .number(4)).description.contains("=A1*2"))
        #expect(Cell(value: .number(1), styleID: StyleID(7)).description.contains("style#7"))
        #expect(Cell(value: .number(1), flags: .staleCache).description.contains("flags:"))
        #expect(CellRef(a1: "B7")!.description == "B7")
        #expect(CellRange(a1: "A1:B5")!.description == "A1:B5")
        #expect(SheetID(3).description == "sheet#3")
        #expect(StyleID(3).description == "style#3")
        #expect(RGBAColor.red.description == "#FFFF0000")
        #expect(NumberFormat("0.00").description.contains("0.00"))
        #expect(!CellStore().description.isEmpty)
        #expect(Workbook.blank().description.contains("1 sheets"))
        #expect(Sheet(id: SheetID(1), name: "Data").description.contains("Data"))
        #expect(RunLengthArray(defaultValue: 1.0).description.contains("RunLengthArray"))
    }

    @Test("identifiers order and compare")
    func identifierOrdering() {
        #expect(SheetID(1) < SheetID(2))
        #expect(StyleID(1) < StyleID(2))
        #expect(SheetID(rawValue: 5) == SheetID(5))
        #expect(StyleID(rawValue: 5) == StyleID(5))
        let sheet: SheetID = 7
        let style: StyleID = 7
        #expect(sheet.rawValue == 7)
        #expect(style.rawValue == 7)
        #expect(StyleID.default == StyleID(0))
        #expect([SheetID(3), SheetID(1), SheetID(2)].sorted() == [SheetID(1), SheetID(2), SheetID(3)])
    }

    @Test("range references carry a sheet where a plain range cannot")
    func rangeReferences() throws {
        let unqualified = RangeReference(range: try #require(CellRange(a1: "A1:B2")))
        #expect(unqualified.sheet == nil)
        let qualified = RangeReference(sheet: SheetID(2), range: try #require(CellRange(a1: "A1:B2")))
        #expect(qualified.sheet == SheetID(2))
        #expect(unqualified != qualified)
    }
}
