import DocumentCore
import Foundation
import GlassUI
import GridKit
import SheetModel
import SheetStore
import TestSupport
import Testing

/// PLAN.md §1.3 — turning a ``WorkbookDiff`` into the tints the grid paints, and deciding when
/// not to paint at all.
///
/// # What these are really checking
///
/// Two things, and the second is the one with teeth. The first is arithmetic: which diff kinds
/// become which colour, which are dropped, and that a sheet's tints come only from that sheet.
///
/// The second is the density cap, and what it is defending is not the frame rate — it is the
/// meaning of the colour. A tint over a third of a sheet points at something; a tint over all of
/// it *is* the background, and the untinted cells start reading as the highlights. So the
/// assertions below are as much about the flag being raised as about the tints being dropped:
/// the failure mode this feature has to avoid is a grid that goes quietly blank while the chip
/// in the title bar counts thousands of changes, and the only defence against it is that the
/// mapping says out loud what it decided.
@Suite("Change highlights mapping")
struct ChangeHighlightsMappingTests {
    // MARK: - Kinds

    /// The acceptance case from the plan, cell kind by cell kind.
    @Test func eachChangeKindBecomesItsOwnColourAndStyleChangesBecomeNothing() throws {
        let workbook = try Fixture.sheet(rows: 40, columns: 10)
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: Fixture.first,
                sheetName: "Q4",
                cellChanges: [
                    Fixture.change("B2", .added),
                    Fixture.change("B3", .added),
                    Fixture.change("C2", .valueChanged),
                    Fixture.change("C3", .valueChanged),
                    Fixture.change("C4", .valueChanged),
                    Fixture.change("D2", .formulaChanged),
                    Fixture.change("E2", .styleChanged),
                    Fixture.change("F2", .removed),
                ],
                structuralChanges: [StructuralChange(kind: .insertedRows, index: 6, count: 1)]
            ),
        ])

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        #expect(mapped.suppression == nil)
        #expect(mapped.highlights.added.count == 2)
        // Value and formula changes are one colour: the user's question is "did this number
        // move", and it moved either way.
        #expect(mapped.highlights.modified.count == 4)
        #expect(mapped.highlights.removed.count == 1)
        #expect(mapped.highlights.insertedRows == [6])
        #expect(mapped.highlights.insertedColumns.isEmpty)

        // The style-only change is in none of the three sets — not tinted, and not silently
        // folded into `modified` either.
        let styled = try #require(CellRef(a1: "E2"))
        #expect(!mapped.highlights.added.contains(styled))
        #expect(!mapped.highlights.modified.contains(styled))
        #expect(!mapped.highlights.removed.contains(styled))
    }

    /// Deleted rows and columns are the panel's news, not the grid's: there is no row left to
    /// tint (§1.3).
    @Test func deletedRowsAndColumnsDoNotBecomeBands() throws {
        let workbook = try Fixture.sheet(rows: 40, columns: 10)
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: Fixture.first,
                sheetName: "Q4",
                cellChanges: [Fixture.change("B2", .valueChanged)],
                structuralChanges: [
                    StructuralChange(kind: .insertedRows, index: 3, count: 2),
                    StructuralChange(kind: .deletedRows, index: 14, count: 2),
                    StructuralChange(kind: .insertedColumns, index: 1, count: 1),
                    StructuralChange(kind: .deletedColumns, index: 7, count: 3),
                ]
            ),
        ])

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        #expect(mapped.highlights.insertedRows == [3, 4])
        #expect(mapped.highlights.insertedColumns == [1])
    }

    /// A sheet's tints come from that sheet's diff and no other. The grid draws one sheet at a
    /// time, and a ref is just a row and a column — nothing in a `CellRef` remembers which sheet
    /// it came from, so a mapping that pooled them would tint Q4 with Q3's edits.
    @Test func eachSheetSeesOnlyItsOwnChanges() throws {
        let workbook = try Fixture.twoSheets()
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: Fixture.first,
                sheetName: "Q4",
                cellChanges: [Fixture.change("A1", .added)],
                structuralChanges: [StructuralChange(kind: .insertedRows, index: 2, count: 1)]
            ),
            SheetDiff(
                sheetID: Fixture.second,
                sheetName: "Q3",
                cellChanges: [Fixture.change("B2", .removed), Fixture.change("B3", .removed)]
            ),
        ])

        let q4 = diff.changeHighlights(for: Fixture.first, in: workbook)
        #expect(q4.highlights.added.count == 1)
        #expect(q4.highlights.removed.isEmpty)
        #expect(q4.highlights.insertedRows == [2])

        let q3 = diff.changeHighlights(for: Fixture.second, in: workbook)
        #expect(q3.highlights.removed.count == 2)
        #expect(q3.highlights.added.isEmpty)
        #expect(q3.highlights.insertedRows.isEmpty)
    }

    /// A sheet the diff says nothing about is not a suppression — it is silence.
    @Test func anUnmentionedSheetPaintsNothingAndExplainsNothing() throws {
        let workbook = try Fixture.twoSheets()
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(sheetID: Fixture.first, sheetName: "Q4", cellChanges: [Fixture.change("A1", .added)]),
        ])

        let mapped = diff.changeHighlights(for: Fixture.second, in: workbook)
        #expect(mapped == .none)
        #expect(!mapped.isSuppressedByDensity)
    }

    /// A diff entry with a style-only change and nothing else is an empty answer, not an empty
    /// tint set with a density attached.
    @Test func aStyleOnlyDiffIsNothingToSay() throws {
        let workbook = try Fixture.sheet(rows: 40, columns: 10)
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(sheetID: Fixture.first, sheetName: "Q4", cellChanges: [Fixture.change("B2", .styleChanged)]),
        ])

        #expect(diff.changeHighlights(for: Fixture.first, in: workbook) == .none)
    }

    // MARK: - The density cap

    /// Under the cap, the tints are drawn and the density is reported honestly.
    @Test func asparseDiffIsPaintedAndMeasured() throws {
        // 10 × 10 used range; four changed cells is 4%.
        let workbook = try Fixture.sheet(rows: 10, columns: 10)
        let diff = Fixture.diff(modifying: ["A1", "B1", "C1", "D1"])

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        #expect(mapped.suppression == nil)
        #expect(!mapped.isSuppressedByDensity)
        #expect(mapped.highlights.modified.count == 4)
        #expect(mapped.consideredCellCount == 100)
        #expect(mapped.washedCellCount == 4)
        #expect(abs(mapped.density - 0.04) < 0.0001)
    }

    /// Over the cap the grid is handed nothing — and told to say so.
    ///
    /// The count is still reported. That is the whole point of returning a value rather than an
    /// optional: the panel can write *"most of this sheet changed"* with the real number behind
    /// it, instead of the grid and the chip disagreeing in silence.
    @Test func aRewrittenSheetIsNotPaintedAndSaysWhy() throws {
        // 10 × 10 used range; 40 changed cells is 40%, over the 35% default.
        let workbook = try Fixture.sheet(rows: 10, columns: 10)
        let refs = (0 ..< 40).map { CellRef(row: $0 / 10, column: $0 % 10) }
        let diff = Fixture.diff(modifying: refs)

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        #expect(mapped.highlights == .none)
        #expect(mapped.isSuppressedByDensity)
        #expect(mapped.suppression == .density)
        #expect(mapped.washedCellCount == 40)
        #expect(mapped.consideredCellCount == 100)
        #expect(abs(mapped.density - 0.4) < 0.0001)
    }

    /// The threshold is a threshold, not a rounding: 35 of 100 paints, 36 does not.
    @Test func theCapBitesExactlyAtTheDocumentedShare() throws {
        let workbook = try Fixture.sheet(rows: 10, columns: 10)
        #expect(ChangeHighlightsMapping.maxHighlightDensity == 0.35)

        let atTheLine = Fixture.diff(modifying: (0 ..< 35).map { CellRef(row: $0 / 10, column: $0 % 10) })
        #expect(atTheLine.changeHighlights(for: Fixture.first, in: workbook).suppression == nil)

        let overIt = Fixture.diff(modifying: (0 ..< 36).map { CellRef(row: $0 / 10, column: $0 % 10) })
        #expect(overIt.changeHighlights(for: Fixture.first, in: workbook).suppression == .density)
    }

    /// A caller may move the line. Tests need to, and so would a preference if one ever exists.
    @Test func theCapIsOverridable() throws {
        let workbook = try Fixture.sheet(rows: 10, columns: 10)
        let diff = Fixture.diff(modifying: (0 ..< 40).map { CellRef(row: $0 / 10, column: $0 % 10) })

        #expect(diff.changeHighlights(for: Fixture.first, in: workbook, maxDensity: 0.5).suppression == nil)
        #expect(diff.changeHighlights(for: Fixture.first, in: workbook, maxDensity: 0.1).suppression == .density)
    }

    /// A band is measured by the area it washes, not by the one integer that stores it.
    ///
    /// Three inserted rows across a ten-column sheet is thirty cells of alpha blending — the
    /// same cost as thirty individually tinted cells and the same loss of meaning. Counting the
    /// band as "one change" would let a whole-sheet wash slip under a cap designed to stop it.
    @Test func insertedBandsAreCountedByTheAreaTheyCover() throws {
        let workbook = try Fixture.sheet(rows: 10, columns: 10)
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: Fixture.first,
                sheetName: "Q4",
                cellChanges: [Fixture.change("A1", .added)],
                structuralChanges: [StructuralChange(kind: .insertedRows, index: 0, count: 4)]
            ),
        ])

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        // Four rows × ten columns. A1 sits inside the band and is not counted twice — the
        // renderer skips its per-cell green for exactly the same reason.
        #expect(mapped.washedCellCount == 40)
        #expect(mapped.suppression == .density)
    }

    /// A band that runs off the end of the sheet is measured against the sheet, not against the
    /// index it claims. One stripe over empty space is one stripe.
    @Test func aBandBeyondTheUsedRangeDoesNotInflateTheDenominator() throws {
        let workbook = try Fixture.sheet(rows: 4, columns: 3)
        let diff = WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: Fixture.first,
                sheetName: "Q4",
                cellChanges: [Fixture.change("A1", .valueChanged)],
                structuralChanges: [StructuralChange(kind: .insertedRows, index: 500, count: 1)]
            ),
        ])

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        #expect(mapped.consideredCellCount == 12)
        #expect(mapped.washedCellCount == 1)
        #expect(mapped.suppression == nil)
        #expect(mapped.highlights.insertedRows == [500])
    }

    /// Removed cells widen the region they are measured against.
    ///
    /// They live outside the current used range by definition — that is what removing them did —
    /// and a denominator that stopped at the shrunken sheet would report deleting a block as
    /// denser than the sheet it was deleted from.
    @Test func removedCellsOutsideTheUsedRangeWidenTheRegion() throws {
        let workbook = try Fixture.sheet(rows: 4, columns: 3)
        let diff = Fixture.diff(removing: ["A9", "B9"])

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        // A1:C4 unioned with A9:B9 is A1:C9 — 27 cells, not 12.
        #expect(mapped.consideredCellCount == 27)
        #expect(mapped.washedCellCount == 2)
        #expect(mapped.suppression == nil)
    }

    /// A truncated diff is a sample, not a list. Tinting a sample would tell the user that every
    /// untinted cell is unchanged, which is the one thing a truncated diff cannot promise.
    @Test func aTruncatedDiffIsNotPaintedEvenWhenItIsSparse() throws {
        let workbook = try Fixture.sheet(rows: 100, columns: 100)
        var diff = Fixture.diff(modifying: ["A1", "B2"])
        diff.wasTruncated = true

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        #expect(mapped.highlights == .none)
        #expect(mapped.isSuppressedByDensity)
        #expect(mapped.suppression == .truncatedDiff)
        #expect(mapped.washedCellCount == 2, "the panel still needs a number to be honest with")
    }

    /// A whole sheet that appeared is every cell green, which is no information at all.
    ///
    /// The differ reports it as a summary with no per-cell list, so there is nothing to iterate;
    /// the chip counts those cells anyway (`BaselineTracker.counts`), which is precisely why the
    /// mapping has to raise the flag rather than return an unexplained blank.
    @Test func aWhollyNewSheetIsSuppressedRatherThanSilentlyEmpty() throws {
        let workbook = try Fixture.sheet(rows: 10, columns: 10)
        let diff = WorkbookDiff(addedSheets: [SheetSummary(id: Fixture.first, name: "Q4", cellCount: 100)])

        let mapped = diff.changeHighlights(for: Fixture.first, in: workbook)
        #expect(mapped.highlights == .none)
        #expect(mapped.isSuppressedByDensity)
        #expect(mapped.suppression == .density)
        #expect(mapped.washedCellCount == 100)
        #expect(abs(mapped.density - 1) < 0.0001)
    }

    /// An empty sheet appearing is not news worth a sentence.
    @Test func anEmptyNewSheetIsJustNothing() throws {
        let workbook = try Fixture.sheet(rows: 10, columns: 10)
        let diff = WorkbookDiff(addedSheets: [SheetSummary(id: Fixture.first, name: "Q4", cellCount: 0)])

        #expect(diff.changeHighlights(for: Fixture.first, in: workbook) == .none)
    }

    // MARK: - The model's own view

    /// The global switch turns the tints off without inventing an explanation for them.
    ///
    /// `.none` with no suppression, because the user turned them off; a panel that read
    /// "most of this sheet changed" here would be blaming the app for the user's own choice.
    @Test @MainActor func theHighlightSwitchSilencesTheGridWithoutAnExcuse() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        let opened = try await workspace.open()
        defer { opened.close() }
        let sheetID = opened.model.workbook.sheets[0].id

        try await workspace.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(129.6), at: BaselineWorkspace.ref("B2"))
            }
        }
        try await opened.settle { $0.baselineCounts.modified == 1 }
        #expect(opened.model.activeChangeHighlights.highlights.modified.count == 1)

        opened.model.isChangeHighlightingEnabled = false
        #expect(opened.model.activeChangeHighlights == .none)
        #expect(!opened.model.activeChangeHighlights.isSuppressedByDensity)
        opened.model.isChangeHighlightingEnabled = true
    }
}

// MARK: - Fixtures

/// Hand-built workbooks and diffs. Nothing here reads a file: the mapping is a pure function of
/// two values, and testing it through the filesystem would be testing the differ instead.
private enum Fixture {
    static let first = SheetID(1)
    static let second = SheetID(2)

    /// A rectangular sheet whose used range is exactly `rows × columns`, so the density
    /// denominator in every test above is a number the reader can check in their head.
    static func sheet(rows: Int, columns: Int) throws -> Workbook {
        var builder = WorkbookBuilder().sheet("Q4", id: first).partPath("xl/worksheets/sheet1.xml")
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                builder = builder.put(
                    CellRef(row: row, column: column).a1String,
                    Cell(value: .number(Double(row * columns + column)))
                )
            }
        }
        return try builder.build()
    }

    static func twoSheets() throws -> Workbook {
        try WorkbookBuilder()
            .sheet("Q4", id: first)
            .partPath("xl/worksheets/sheet1.xml")
            .rows("A1", [[.text("a"), .text("b")], [.text("c"), .text("d")]])
            .sheet("Q3", id: second)
            .partPath("xl/worksheets/sheet2.xml")
            .rows("A1", [[.text("a"), .text("b")], [.text("c"), .text("d")]])
            .build()
    }

    static func change(_ a1: String, _ kind: SheetModel.CellChange.Kind) -> SheetModel.CellChange {
        change(CellRef(a1: a1) ?? CellRef(row: 0, column: 0), kind)
    }

    static func change(_ ref: CellRef, _ kind: SheetModel.CellChange.Kind) -> SheetModel.CellChange {
        SheetModel.CellChange(
            ref: ref,
            before: kind == .added ? nil : Cell(value: .number(1)),
            after: kind == .removed ? nil : Cell(value: .number(2)),
            kind: kind
        )
    }

    static func diff(modifying a1: [String]) -> WorkbookDiff {
        diff(a1.map { CellRef(a1: $0) ?? CellRef(row: 0, column: 0) }, kind: .valueChanged)
    }

    static func diff(modifying refs: [CellRef]) -> WorkbookDiff {
        diff(refs, kind: .valueChanged)
    }

    static func diff(removing a1: [String]) -> WorkbookDiff {
        diff(a1.map { CellRef(a1: $0) ?? CellRef(row: 0, column: 0) }, kind: .removed)
    }

    private static func diff(_ refs: [CellRef], kind: SheetModel.CellChange.Kind) -> WorkbookDiff {
        WorkbookDiff(sheetDiffs: [
            SheetDiff(
                sheetID: first,
                sheetName: "Q4",
                cellChanges: refs.map { change($0, kind) }
            ),
        ])
    }
}

// MARK: - The theme bridge

/// The five change-tint fields crossing from the design system to the renderer.
///
/// One mapping, checked in both schemes, because the whole reason two `GridTheme` types exist is
/// that neither target may import the other — which means nothing but a test can notice when one
/// of them grows a field the bridge forgets. A forgotten field here does not fail to compile: it
/// silently falls back to `GridKit`'s hard-coded default, and the grid quietly stops agreeing
/// with the chip about what green means.
@Suite("Change tints through the theme bridge")
struct ChangeTintThemeBridgeTests {
    @Test(arguments: [GlassColorScheme.light, .dark])
    func theChangeTintsSurviveTheCrossing(_ scheme: GlassColorScheme) {
        let context = AppearanceContext(colorScheme: scheme)
        let design = GlassUI.GridTheme.resolved(context)
        let rendered = GridThemeBridge.resolved(context)

        expectSameColour(rendered.changeAddedTint, design.changeAddedTint, "changeAddedTint")
        expectSameColour(rendered.changeModifiedTint, design.changeModifiedTint, "changeModifiedTint")
        expectSameColour(rendered.changeRemovedTint, design.changeRemovedTint, "changeRemovedTint")
        #expect(rendered.changeTintOpacity == design.changeTintOpacity)
        #expect(rendered.changeBandOpacity == design.changeBandOpacity)
    }

    /// The three hues are distinguishable from each other in both schemes. Green, amber and red
    /// carry the entire meaning of the feature; two of them resolving to the same bytes would be
    /// a palette bug no contrast assertion catches.
    @Test(arguments: [GlassColorScheme.light, .dark])
    func theThreeTintsAreThreeColours(_ scheme: GlassColorScheme) {
        let theme = GridThemeBridge.resolved(AppearanceContext(colorScheme: scheme))
        #expect(theme.changeAddedTint != theme.changeModifiedTint)
        #expect(theme.changeModifiedTint != theme.changeRemovedTint)
        #expect(theme.changeAddedTint != theme.changeRemovedTint)
    }

    /// `RGBA` doubles become `RGBAColor` bytes, so equality is to within a rounding step.
    private func expectSameColour(_ rendered: RGBAColor, _ design: RGBA, _ label: Comment) {
        let expected = design.clamped
        #expect(abs(Double(rendered.red) / 255 - expected.red) <= 1.0 / 255, label)
        #expect(abs(Double(rendered.green) / 255 - expected.green) <= 1.0 / 255, label)
        #expect(abs(Double(rendered.blue) / 255 - expected.blue) <= 1.0 / 255, label)
        #expect(abs(Double(rendered.alpha) / 255 - expected.alpha) <= 1.0 / 255, label)
    }
}

// MARK: - The git baseline

/// PLAN.md §1.3's third baseline: *"what is not committed"*.
///
/// These run against a real repository built in a temporary directory, because the thing worth
/// proving is not that the adapter calls `GitFileVersion` — it is that the bytes come back, parse
/// into a workbook, and diff against the one on screen. Every step of that has a failure mode a
/// mock would hide, and one of them was waiting: `git rev-parse --show-toplevel` answers with the
/// kernel's resolved path, so a repository under `/var/folders/…` comes back as
/// `/private/var/folders/…`, and a naive prefix comparison against the caller's URL never
/// matches. The git baseline would then be silently, permanently absent — which is
/// indistinguishable from "this file is not in a repository" and would never be reported as a
/// bug. (`GitFileVersion.repositoryRelativePath` canonicalises both sides; this suite is what
/// notices if that ever stops being true.)
///
/// Skipped rather than failed where `/usr/bin/git` is absent: CI has the command line tools, a
/// user's machine may not, and the product's answer in that case is that the source is quietly
/// not offered.
@Suite(.serialized, .enabled(if: GitRepositoryFixture.isGitInstalled))
@MainActor
struct GitBaselineAdapterTests {
    /// Installing the provider is the whole wiring: the model's `didSet` probe does the rest.
    @Test func installingTheProviderMakesTheGitSourceAvailable() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        try GitRepositoryFixture.initialise(at: workspace.directory, committing: workspace.url)

        let opened = try await workspace.open()
        defer { opened.close() }
        #expect(!opened.model.isGitBaselineAvailable, "nothing is offered before a provider exists")

        GitBaselineAdapter.install(on: opened.model)
        try await opened.settle { $0.isGitBaselineAvailable }
        #expect(opened.model.isGitBaselineAvailable)
    }

    /// The committed version really is the *committed* one: a baseline taken against HEAD sees a
    /// change that both the as-opened baseline and a fresh checkpoint have already absorbed.
    ///
    /// The checkpoint in the middle is what makes this a proof rather than a coincidence. Without
    /// it, "the diff shows one modified cell" is the same answer the as-opened baseline gives,
    /// and a `setBaselineSource(.gitHEAD)` that silently did nothing would pass.
    @Test func theGitBaselineDiffsAgainstWhatWasCommitted() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        try GitRepositoryFixture.initialise(at: workspace.directory, committing: workspace.url)

        let opened = try await workspace.open()
        defer { opened.close() }
        GitBaselineAdapter.install(on: opened.model)
        try await opened.settle { $0.isGitBaselineAvailable }

        let sheetID = opened.model.workbook.sheets[0].id
        try await workspace.externalEdit { workbook in
            try workbook.withSheet(sheetID) { sheet in
                try sheet.cells.setCell(.number(129.6), at: BaselineWorkspace.ref("B2"))
            }
        }
        try await opened.settle { $0.baselineCounts.modified == 1 }

        // Everything up to here is now the past, as far as the user is concerned.
        await opened.model.setCheckpoint()
        try await opened.settle { $0.baselineCounts == .zero }
        #expect(opened.model.baselineSource == .checkpoint)

        await opened.model.setBaselineSource(.gitHEAD)
        try await opened.settle { $0.baselineSource == .gitHEAD && $0.baselineDiff != nil }
        #expect(opened.model.baselineSource == .gitHEAD)
        #expect(
            opened.model.baselineCounts == BaselineCounts(modified: 1),
            "the working tree differs from HEAD by exactly the cell the agent wrote"
        )

        // …and the tints the grid paints come out of that same diff.
        let mapped = opened.model.activeChangeHighlights
        #expect(mapped.suppression == nil)
        #expect(mapped.highlights.modified == [BaselineWorkspace.ref("B2")])
    }

    /// A file in no repository offers nothing, and costs one `rev-parse` to find out.
    @Test func afileOutsideAnyRepositoryHasNoCommittedVersion() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }

        let available = await GitBaselineAdapter.probeAvailability(for: workspace.url)
        #expect(!available)
        let committed = await GitBaselineAdapter.committedWorkbook(for: workspace.url)
        #expect(committed == nil)
    }

    /// Inside a repository but never committed: the cheap probe says yes (it is in a work tree),
    /// the real read says no. That split is deliberate — the model's own probe runs the real
    /// read, so the source is offered only when there is something behind it.
    @Test func anUntrackedFileIsInsideTheRepositoryAndStillHasNothingToShow() async throws {
        let workspace = try BaselineWorkspace()
        defer { workspace.remove() }
        try GitRepositoryFixture.initialise(at: workspace.directory, committing: nil)

        let available = await GitBaselineAdapter.probeAvailability(for: workspace.url)
        #expect(available)
        let committed = await GitBaselineAdapter.committedWorkbook(for: workspace.url)
        #expect(committed == nil)

        let opened = try await workspace.open()
        defer { opened.close() }
        GitBaselineAdapter.install(on: opened.model)
        // Long enough for the probe to have landed on the wrong answer, if it were going to.
        try await Task.sleep(for: .milliseconds(750))
        #expect(!opened.model.isGitBaselineAvailable)
    }
}

/// A throwaway git repository, built with the same fixed-argument-array discipline the product
/// uses (§1.6). Duplicated from `SheetStoreTests` rather than shared: a cross-target test
/// dependency to save twenty lines is the worse trade.
enum GitRepositoryFixture {
    static let executable = URL(fileURLWithPath: "/usr/bin/git")

    static var isGitInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false))
    }

    /// `git init` in `directory`, with an identity of its own so the commit does not depend on
    /// whatever the machine's global config happens to say — and with signing off, because a
    /// developer's `commit.gpgsign = true` would otherwise make this suite fail on their machine
    /// and nowhere else.
    static func initialise(at directory: URL, committing file: URL?) throws {
        try run(["init", "-q"], in: directory)
        try run(["config", "user.email", "tests@opensheets.invalid"], in: directory)
        try run(["config", "user.name", "OpenSheets Tests"], in: directory)
        try run(["config", "commit.gpgsign", "false"], in: directory)
        guard let file else { return }
        try run(["add", "-f", "--", file.lastPathComponent], in: directory)
        try run(["commit", "-q", "--no-gpg-sign", "-m", "fixture"], in: directory)
    }

    private static func run(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.first ?? "") failed")
    }
}
