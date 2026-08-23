//
//  DirtyTracking.swift
//  SheetFormat
//
//  The API A8 (app shell) and A9 (MCP server) call to say what they changed.
//

import Foundation
import SheetModel

/// Which regions of one worksheet an edit touched.
///
/// # Why this exists on top of `DirtyPartSet`
///
/// `DirtyPartSet` answers *which ZIP parts must be regenerated*. This answers a second question
/// the writer needs before it can regenerate one safely: *which elements inside that part may be
/// rebuilt from the model, and which must be copied out of the original bytes.*
///
/// The distinction is not pedantry. `<cols>` stores widths in "characters of the normal font";
/// the model stores points; the conversion between them is producer-dependent and lossy in both
/// directions. `<sheetFormatPr>` carries a default row height that the model replaces with
/// OpenSheets' own display default. Regenerating either of those because somebody typed a number
/// into a cell would silently resize the user's whole sheet.
///
/// So the rule is: **anything not named here is copied verbatim from the original part.** An edit
/// that only touches cells produces a `sheetN.xml` that differs from the original only in
/// `<sheetData>` and `<dimension>`.
public struct SheetRegionChanges: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Cell values, formulas, or per-cell styles. The common case, and the cheap one.
    public static let cells = SheetRegionChanges(rawValue: 1 << 0)
    /// Column widths, hidden columns, column styles, or column outline levels — `<cols>`.
    public static let columns = SheetRegionChanges(rawValue: 1 << 1)
    /// Row heights, hidden rows, row styles, or row outline levels — the `<row>` attributes.
    public static let rows = SheetRegionChanges(rawValue: 1 << 2)
    /// Frozen or split panes, gridline visibility, zoom, reading direction — `<sheetViews>`.
    public static let views = SheetRegionChanges(rawValue: 1 << 3)
    /// Merged regions — `<mergeCells>`.
    public static let merges = SheetRegionChanges(rawValue: 1 << 4)
    /// Cell hyperlinks — `<hyperlinks>`.
    public static let hyperlinks = SheetRegionChanges(rawValue: 1 << 5)
    /// The filter range — `<autoFilter>`.
    public static let autoFilter = SheetRegionChanges(rawValue: 1 << 6)

    /// Everything the model represents. What a sheet built from scratch, or replaced wholesale,
    /// has to use — there is nothing to copy from.
    public static let all: SheetRegionChanges = [
        .cells, .columns, .rows, .views, .merges, .hyperlinks, .autoFilter,
    ]
}

/// Accumulates what an editing session changed, in the terms an editor thinks in.
///
/// A8 and A9 both hold one of these next to the `Workbook` they are mutating and call the
/// `note…` methods as they go; the writer is then handed the whole thing. Nothing above this
/// layer has to know that a cell edit invalidates `xl/calcChain.xml`, or that a sheet's part
/// path comes from `xl/_rels/workbook.xml.rels` rather than from its position in the tab bar.
///
/// ```swift
/// var edits = WorkbookEditTracker()
/// try workbook.withSheet(id) { try $0.cells.setCell(.number(42), at: ref) }
/// edits.noteCellsChanged(in: workbook[id]!, formulasChanged: false)
/// let fingerprint = try XLSXWriter.save(workbook, edits: edits, to: url)
/// ```
///
/// After a successful save, call ``reset()``. Nothing resets it implicitly, because a save that
/// threw must leave the edits still marked.
public struct WorkbookEditTracker: Sendable, Hashable {
    /// The parts that must be regenerated. Handed straight to the writer.
    public private(set) var dirty: DirtyPartSet

    /// Per-sheet detail, keyed by ``SheetID``. A sheet marked dirty with no entry here is
    /// treated as ``SheetRegionChanges/cells``.
    public private(set) var sheetChanges: [SheetID: SheetRegionChanges]

    /// Sheets whose part path was unknown at the time of the edit — a sheet created in-app.
    public private(set) var newSheets: Set<SheetID>

    public init() {
        dirty = DirtyPartSet()
        sheetChanges = [:]
        newSheets = []
    }

    /// Whether there is anything to write.
    public var isEmpty: Bool { dirty.isEmpty }

    /// Marks a sheet's cells changed.
    ///
    /// Pass `formulasChanged: true` whenever a formula was added, edited, or removed — including
    /// when a formula cell was replaced by a literal. That flag is what drops `xl/calcChain.xml`
    /// and sets `calcPr/@fullCalcOnLoad`, and getting it wrong in the *false* direction leaves
    /// Excel trusting a calculation chain that no longer describes the workbook.
    public mutating func noteCellsChanged(in sheet: Sheet, formulasChanged: Bool = false) {
        note(sheet, .cells)
        if formulasChanged { dirty.formulasChanged = true }
    }

    /// Marks specific regions of a sheet changed.
    public mutating func note(_ sheet: Sheet, _ regions: SheetRegionChanges) {
        dirty.mark(sheet: sheet)
        if sheet.partPath == nil { newSheets.insert(sheet.id) }
        sheetChanges[sheet.id, default: []].formUnion(regions)
    }

    /// Marks a sheet as needing complete regeneration.
    public mutating func noteSheetReplaced(_ sheet: Sheet) {
        note(sheet, .all)
    }

    /// Marks the workbook-level part changed — a rename, a visibility change, a defined name.
    public mutating func noteWorkbookMetadataChanged() {
        dirty.mark(OOXMLPart.workbook)
    }

    /// Marks the style table changed.
    public mutating func noteStylesChanged() {
        dirty.mark(OOXMLPart.styles)
    }

    /// Marks the set of parts changed — a sheet added, removed, or reordered.
    ///
    /// v0.1's writer **refuses** this rather than guessing: adding a part means patching
    /// `[Content_Types].xml`, `xl/_rels/workbook.xml.rels`, and `xl/workbook.xml` in agreement
    /// with each other, and a partial job produces a file Excel calls damaged.
    public mutating func notePartStructureChanged() {
        dirty.partStructureChanged = true
    }

    /// The regions to regenerate for a sheet.
    public func regions(for sheet: Sheet) -> SheetRegionChanges {
        if sheet.partPath == nil { return .all }
        return sheetChanges[sheet.id] ?? .cells
    }

    /// Whether this sheet's part has to be written at all.
    public func isDirty(_ sheet: Sheet) -> Bool {
        if let path = sheet.partPath { return dirty.contains(path) }
        return newSheets.contains(sheet.id) || dirty.partStructureChanged
    }

    /// Clears everything after a successful save.
    public mutating func reset() {
        dirty.removeAll()
        sheetChanges.removeAll()
        newSheets.removeAll()
    }
}

/// Knobs on a save. The defaults are the safe ones.
public struct XLSXWriteOptions: Sendable, Hashable {
    /// What to do with characters XML 1.0 cannot represent, which arrive routinely from CSV.
    ///
    /// Defaults to Excel's own `_xHHHH_` convention, which is lossless and which a reader that
    /// knows the convention turns back into the original character.
    public var controlCharacters: XLSXEscape.ControlCharacterPolicy

    /// Whether to drop `xl/calcChain.xml` when a formula changed.
    ///
    /// On, and there is no good reason to turn it off. Excel rebuilds the chain; a stale one
    /// describes a dependency graph that no longer exists and causes real corruption.
    public var dropStaleCalculationChain: Bool

    /// Whether to set `calcPr/@fullCalcOnLoad` when a formula changed, so Excel recomputes what
    /// OpenSheets could not.
    public var requestFullCalculationOnLoad: Bool

    /// Whether to re-scan the original `sheetN.xml` for top-level elements the model does not
    /// carry, and splice them back verbatim.
    ///
    /// On. This is the belt to `sheetLevelFragments`' braces: if the reader ever fails to
    /// capture an element — a new one, or one nobody thought of — the writer still finds it in
    /// the bytes it is about to replace. Turning it off means trusting that the reader's list of
    /// captured elements is complete, forever.
    public var salvageUnmodelledSheetElements: Bool

    /// What to do when regenerating a sheet would drop dynamic-array metadata.
    public var dynamicArrayMetadata: DynamicArrayMetadataPolicy

    /// The two honest answers when a sheet holds `cm`/`vm` attributes we cannot reproduce.
    ///
    /// The model has nowhere to keep the metadata indices, so rewriting `sheetN.xml` for such
    /// a sheet **downgrades** every dynamic array on it to a fixed-size Ctrl-Shift-Enter array
    /// formula. The file still opens and the numbers are still right; what is lost is the
    /// array's ability to resize when its inputs change — which is exactly the thing its
    /// author chose it for, and exactly the kind of loss nobody notices for months.
    public enum DynamicArrayMetadataPolicy: Sendable, Hashable {
        /// Refuse the write and say which cell would be damaged. **The default.**
        case refuse
        /// Write anyway. For a caller that has told the user what they are losing, or for a
        /// test that is checking the degradation itself.
        case degrade
    }

    public init(
        controlCharacters: XLSXEscape.ControlCharacterPolicy = .escape,
        dropStaleCalculationChain: Bool = true,
        requestFullCalculationOnLoad: Bool = true,
        salvageUnmodelledSheetElements: Bool = true,
        dynamicArrayMetadata: DynamicArrayMetadataPolicy = .refuse
    ) {
        self.controlCharacters = controlCharacters
        self.dropStaleCalculationChain = dropStaleCalculationChain
        self.requestFullCalculationOnLoad = requestFullCalculationOnLoad
        self.salvageUnmodelledSheetElements = salvageUnmodelledSheetElements
        self.dynamicArrayMetadata = dynamicArrayMetadata
    }

    /// The defaults.
    public static let standard = XLSXWriteOptions()
}
