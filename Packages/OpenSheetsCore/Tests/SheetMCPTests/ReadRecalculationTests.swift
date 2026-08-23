import Foundation
import SheetFormat
@testable import SheetMCP
import SheetModel
import SheetStore
import TestSupport
import Testing

/// What an agent sees when it reads a workbook whose producer never calculated it.
///
/// # The disagreement this closes
///
/// A8b taught the app to recalculate on open: openpyxl, pandas and xlsxwriter all write real
/// formulas next to placeholder zeroes, and rendering those faithfully puts `Total 0` under five
/// columns of real figures. The MCP server had no equivalent, so Claude Code reading the same file
/// through `describe` or `read_range` got the zeroes while the user looked at the real numbers —
/// the agent and the person disagreeing about one file, which is the one failure this product
/// cannot survive.
///
/// The other half matters just as much: **reading must not write.** A read that quietly corrected
/// the file would mean every `describe` is an edit, and an edit nobody asked for is what the whole
/// sync engine exists to prevent. So these tests assert the bytes on disk are byte-identical after
/// the read, and that `recalc` — a declared, snapshotted write — is still the only thing that
/// changes them.
@Suite struct ReadRecalculationTests {
    /// A workbook in the state openpyxl leaves one in: real data, real formulas, cached zeroes,
    /// no `calcChain.xml` and no `<calcPr>`.
    static func uncalculated() throws -> Workbook {
        try WorkbookBuilder()
            .sheet("Summary")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [
                [.text("Line item"), .text("Q1")],
                [.text("Salaries"), .number(418_500)],
                [.text("Travel"), .number(47900)],
                [.text("Software"), .number(14472)],
            ])
            .cell("A5", .text("Total"))
            .formula("B5", "SUM(B2:B4)", cached: .number(0))
            .build()
    }

    /// 418500 + 47900 + 14472.
    static let total = 480_872.0

    @Test @MainActor func describeShowsWhatTheFormulasMeanNotWhatTheProducerCached() async throws {
        let harness = try Harness.make("recalc-describe")
        let path = try harness.install(try Self.uncalculated(), as: "openpyxl.xlsx")

        // Precondition: the file really is uncalculated. If A2's writer ever starts emitting
        // `calcPr`, this fixture stops testing anything and should say so here rather than pass.
        let onDisk = try await harness.reload(path)
        #expect(!onDisk.meta.hasCalculationEvidence)
        #expect(onDisk.sheets[0].cells[CellRef(a1: "B5")!]?.value == .number(0))

        let output = await harness.call("describe", ["path": .string(path)])
        #expect(!output.isError)
        // `describe` reports a formula column as its formula rather than its values, so what this
        // asserts is the part `describe` is responsible for: saying, before the profile and
        // unprompted, that the numbers behind it are ours and not the file's. The values
        // themselves are asserted through `read_range`, which is what returns them.
        #expect(output.text.contains("recalculated 1 value"))
        #expect(output.text.contains("the file on disk is unchanged"))
        #expect(
            output.text.range(of: "recalculated")!.lowerBound < output.text.range(of: "openpyxl.xlsx ·")!.lowerBound,
            "the caveat goes above the profile it is about"
        )
    }

    @Test @MainActor func readRangeReturnsTheComputedValue() async throws {
        let harness = try Harness.make("recalc-read")
        let path = try harness.install(try Self.uncalculated(), as: "openpyxl.xlsx")

        let output = await harness.call("read_range", ["path": .string(path), "range": .string("A5:B5")])
        #expect(!output.isError)
        #expect(output.text.contains("480872"))
        #expect(!output.text.contains("\t0\n"), "the placeholder zero must not survive")
    }

    /// The guarantee that makes the correction safe to do at all.
    @Test @MainActor func readingNeverWritesTheFile() async throws {
        let harness = try Harness.make("recalc-readonly")
        let path = try harness.install(try Self.uncalculated(), as: "openpyxl.xlsx")
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        _ = await harness.call("describe", ["path": .string(path)])
        _ = await harness.call("read_range", ["path": .string(path)])
        _ = await harness.call("find", ["path": .string(path), "query": .string("Total")])

        let after = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(before == after, "three reads must leave the bytes exactly as they were")
        // And the file still says zero, because nothing has asked for it to say otherwise.
        let reloaded = try await harness.reload(path)
        #expect(reloaded.sheets[0].cells[CellRef(a1: "B5")!]?.value == .number(0))
    }

    /// `recalc` remains the only thing that puts the number on disk — and afterwards the read
    /// path has nothing left to correct, so it stops saying anything.
    @Test @MainActor func recalcIsStillTheOnlyThingThatWrites() async throws {
        let harness = try Harness.make("recalc-writes")
        let path = try harness.install(try Self.uncalculated(), as: "openpyxl.xlsx")

        let recalculated = await harness.call("recalc", ["path": .string(path)])
        #expect(!recalculated.isError)

        let reloaded = try await harness.reload(path)
        #expect(reloaded.sheets[0].cells[CellRef(a1: "B5")!]?.value == .number(Self.total))
    }

    /// A workbook somebody *did* calculate is left alone — the narrowness of the heuristic is the
    /// reason it is safe, and it is worth a test of its own.
    @Test @MainActor func aCalculatedWorkbookIsReadExactlyAsItStands() async throws {
        let harness = try Harness.make("recalc-trusted")
        let workbook = try WorkbookBuilder()
            .sheet("Summary")
            .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            .rows("A1", [[.number(1)], [.number(2)]])
            // A wrong cached value, deliberately: if we ever recalculate a file that has been
            // through a calculation engine, this is what would silently change under the user.
            .formula("A3", "SUM(A1:A2)", cached: .number(99))
            .calculationMode(.manual)
            .build()
        let path = try harness.install(workbook, as: "calculated.xlsx")

        let output = await harness.call("read_range", ["path": .string(path), "range": .string("A3")])
        #expect(output.text.contains("99"))
        #expect(!output.text.contains("recalculated"))
    }

    /// Over the ceiling the values stand as they are — and the result says so, because the totals
    /// the agent is looking at may be the producer's placeholders and it has no other way to know.
    @Test func theCeilingIsHonestRatherThanSilent() {
        let count = OpenRecalculation.formulaCeiling + 1
        var meta = WorkbookMeta()
        meta.fullCalculationOnLoad = true
        #expect(OpenRecalculation.decide(formulaCount: count, meta: meta) == .tooLarge(formulaCount: count))

        let view = OpenRecalculation.ReadView(
            workbook: Workbook(sheets: []), decision: .tooLarge(formulaCount: count), outcome: nil
        )
        #expect(view.notice?.contains("never calculated") == true)
        #expect(view.notice?.contains("too many to recalculate") == true)
    }

    /// The read view is rebuilt after a write, not reused. An agent that writes an input and then
    /// reads the total must see its own edit reflected.
    @Test @MainActor func anEditInvalidatesTheCorrectedView() async throws {
        let harness = try Harness.make("recalc-invalidate")
        let path = try harness.install(try Self.uncalculated(), as: "openpyxl.xlsx")

        let first = await harness.call("read_range", ["path": .string(path), "range": .string("B5")])
        #expect(first.text.contains("480872"))

        let written = await harness.call("write_range", [
            "path": .string(path),
            "range": .string("B2"),
            "values": .array([.array([.integer(0)])]),
        ])
        #expect(!written.isError)

        let second = await harness.call("read_range", ["path": .string(path), "range": .string("B5")])
        #expect(second.text.contains("62372"), "47900 + 14472, recomputed after the edit")
    }
}
