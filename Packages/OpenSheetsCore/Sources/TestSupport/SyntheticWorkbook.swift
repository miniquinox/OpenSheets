//
//  SyntheticWorkbook.swift
//  TestSupport
//
//  Deterministic workbooks of arbitrary size, for the perf work in A1 and A4.
//

import Foundation
import SheetModel

/// A tiny, deterministic pseudo-random generator.
///
/// `SystemRandomNumberGenerator` would make every benchmark a different benchmark, and
/// `Foundation`'s seeded generators are not guaranteed stable across OS releases. SplitMix64 is
/// six lines, has no state beyond a `UInt64`, and produces the same stream on every machine and
/// every toolchain — which is the only property a fixture generator needs.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64 = 0x2545_F491_4F6C_DD1D) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Generates workbooks of any size with a shape that resembles a real sheet.
///
/// A million cells all holding `1` is not a benchmark of anything: it compresses to nothing,
/// interns to one shared string, and never exercises the formula or style paths. The default
/// ``Shape`` mixes numbers, text, formulas, styled cells and gaps in fixed proportions, so the
/// cost measured against it tracks the cost of a real workbook.
///
/// Everything here is **deterministic**: the same arguments give byte-identical output on every
/// run, which is what lets a benchmark number mean something from one week to the next.
public enum SyntheticWorkbook {
    /// The mix of cell kinds a generated sheet contains.
    ///
    /// The `…Every` fields are periods, not probabilities: `formulaEvery: 10` means every tenth
    /// cell is a formula, exactly. Periodic rather than random so the *count* of each kind is
    /// predictable, and a test can assert "100,000 cells, 10,000 of them formulas".
    public struct Shape: Sendable, Hashable {
        /// One in this many cells holds a formula over its neighbours.
        public var formulaEvery: Int
        /// One in this many cells holds text rather than a number.
        public var textEvery: Int
        /// One in this many cells carries a non-default style.
        public var styledEvery: Int
        /// One in this many cells is left absent entirely, so the sheet has holes.
        public var blankEvery: Int
        /// How many distinct styles the generated ``StyleTable`` holds.
        public var styleCount: Int
        /// Seed for the numeric values.
        public var seed: UInt64

        public init(
            formulaEvery: Int = 10,
            textEvery: Int = 7,
            styledEvery: Int = 5,
            blankEvery: Int = 23,
            styleCount: Int = 8,
            seed: UInt64 = 0xC0FF_EE00_5EED_0001
        ) {
            self.formulaEvery = max(formulaEvery, 0)
            self.textEvery = max(textEvery, 0)
            self.styledEvery = max(styledEvery, 0)
            self.blankEvery = max(blankEvery, 0)
            self.styleCount = max(styleCount, 1)
            self.seed = seed
        }

        /// The default mix: numbers, some text, a formula every tenth cell, some holes.
        public static let realistic = Shape()

        /// Numbers only, no formulas, no styles, no holes — the cheapest possible sheet.
        ///
        /// Use it when the thing under test is the container rather than the contents, so the
        /// measurement is not diluted by string interning.
        public static let numbersOnly = Shape(
            formulaEvery: 0, textEvery: 0, styledEvery: 0, blankEvery: 0, styleCount: 1
        )

        /// Text only — the shape that stresses shared-string handling.
        public static let textOnly = Shape(
            formulaEvery: 0, textEvery: 1, styledEvery: 0, blankEvery: 0, styleCount: 1
        )

        /// Every cell a formula, for recalculation benchmarks.
        public static let formulaHeavy = Shape(
            formulaEvery: 1, textEvery: 0, styledEvery: 0, blankEvery: 0, styleCount: 1
        )
    }

    // MARK: - Workbooks

    /// A one-sheet workbook of `rows` × `cols` cells.
    ///
    /// The argument label is `cols` rather than `columns` because that is the spelling in the
    /// brief every consuming agent read.
    public static func generate(
        rows: Int,
        cols: Int,
        sheetName: String = "Data",
        shape: Shape = .realistic
    ) throws(SheetError) -> Workbook {
        var styles = StyleTable()
        let styleIDs = internStyles(count: shape.styleCount, into: &styles)
        let sheet = try makeSheet(
            id: SheetID(1), name: sheetName, rows: rows, columns: cols, shape: shape, styleIDs: styleIDs
        )
        let workbook = Workbook(
            sheets: [sheet],
            styles: styles,
            meta: WorkbookMeta(application: "TestSupport.SyntheticWorkbook", sourceFormat: .new)
        )
        return workbook
    }

    /// A workbook with several sheets of the same shape, for tab-switching and diff benchmarks.
    public static func generate(
        sheets sheetCount: Int,
        rows: Int,
        cols: Int,
        shape: Shape = .realistic
    ) throws(SheetError) -> Workbook {
        var styles = StyleTable()
        let styleIDs = internStyles(count: shape.styleCount, into: &styles)
        var built: [Sheet] = []
        built.reserveCapacity(sheetCount)
        for index in 0 ..< max(sheetCount, 1) {
            var sheetShape = shape
            sheetShape.seed = shape.seed &+ UInt64(index) &* 0x9E37_79B9
            built.append(try makeSheet(
                id: SheetID(Int32(index + 1)),
                name: "Sheet\(index + 1)",
                rows: rows,
                columns: cols,
                shape: sheetShape,
                styleIDs: styleIDs
            ))
        }
        return Workbook(
            sheets: built,
            styles: styles,
            meta: WorkbookMeta(application: "TestSupport.SyntheticWorkbook", sourceFormat: .new)
        )
    }

    /// A workbook whose cells are scattered across the whole 1,048,576 × 16,384 grid.
    ///
    /// The dense generator produces a compact rectangle, which is the easy case for any store
    /// indexed by row. This one is the hard case: `cellCount` cells at pseudo-random addresses,
    /// so a representation that scales with the *bounding box* rather than the *population*
    /// falls over immediately.
    public static func sparse(cellCount: Int, seed: UInt64 = 0x5EED_5EED) throws(SheetError) -> Workbook {
        var random = SplitMix64(seed: seed)
        var store = CellStore()
        var placed = 0
        var attempts = 0
        // Bounded so a pathological seed cannot spin: collisions are rare at these densities.
        while placed < cellCount, attempts < cellCount * 4 {
            attempts += 1
            let ref = CellRef(
                row: Int(random.next() % UInt64(Limits.rowCount)),
                column: Int(random.next() % UInt64(Limits.columnCount))
            )
            if store.contains(ref) { continue }
            try store.setCell(.number(Double(placed)), at: ref)
            placed += 1
        }
        let sheet = Sheet(id: SheetID(1), name: "Sparse", cells: store)
        return Workbook(sheets: [sheet])
    }

    // MARK: - Pieces

    /// One generated sheet, for tests that do not need a whole workbook around it.
    public static func sheet(
        rows: Int,
        cols: Int,
        name: String = "Data",
        id: SheetID = SheetID(1),
        shape: Shape = .realistic
    ) throws(SheetError) -> Sheet {
        var styles = StyleTable()
        let styleIDs = internStyles(count: shape.styleCount, into: &styles)
        return try makeSheet(id: id, name: name, rows: rows, columns: cols, shape: shape, styleIDs: styleIDs)
    }

    /// Just the cells, for benchmarking ``CellStore`` on its own.
    public static func cellStore(rows: Int, cols: Int, shape: Shape = .numbersOnly) throws(SheetError) -> CellStore {
        var styles = StyleTable()
        let styleIDs = internStyles(count: shape.styleCount, into: &styles)
        return try makeStore(rows: rows, columns: cols, shape: shape, styleIDs: styleIDs)
    }

    /// A CSV document of the same shape, for the CSV reader's perf lane.
    ///
    /// Emitted as text rather than as a `Workbook` because that is what the reader consumes,
    /// and generating it here keeps the 2 GB fixture out of the repository.
    public static func csv(rows: Int, cols: Int, delimiter: Character = ",", seed: UInt64 = 0xC0FF_EE00_5EED_0001)
        -> String {
        var random = SplitMix64(seed: seed)
        var text = ""
        text.reserveCapacity(rows * cols * 8)
        for row in 0 ..< max(rows, 0) {
            for column in 0 ..< max(cols, 0) {
                if column > 0 { text.append(delimiter) }
                if row == 0 {
                    text += "col\(column)"
                } else if column.isMultiple(of: 7) {
                    text += "row\(row)-\(column)"
                } else {
                    text += String(Double(random.next() % 1_000_000) / 100)
                }
            }
            text += "\n"
        }
        return text
    }

    /// The same workbook with `changedCells` cells altered, for diff benchmarks.
    ///
    /// Changes are spread evenly rather than clustered, because a diff that walks rows is
    /// fastest when every change is in one row and slowest when they are scattered — and the
    /// slow case is the one worth measuring.
    public static func perturb(
        _ workbook: Workbook,
        changedCells: Int,
        seed: UInt64 = 0xD1FF_5EED
    ) throws(SheetError) -> Workbook {
        var copy = workbook
        guard var sheet = copy.sheets.first, let used = sheet.usedRange, changedCells > 0 else { return copy }
        var random = SplitMix64(seed: seed)
        for _ in 0 ..< changedCells {
            let ref = CellRef(
                row: used.start.row + Int(random.next() % UInt64(used.rowCount)),
                column: used.start.column + Int(random.next() % UInt64(used.columnCount))
            )
            var cell = sheet.cells[ref] ?? Cell()
            cell.value = .number(Double(random.next() % 100_000) / 100)
            try sheet.cells.setCell(cell, at: ref)
        }
        copy.update(sheet)
        return copy
    }

    // MARK: - Internals

    private static func internStyles(count: Int, into table: inout StyleTable) -> [StyleID] {
        // Number-format ids only: a style whose only difference is `numberFormatID` is the
        // commonest kind in a real workbook, and it keeps the table cheap to build.
        let formatIDs: [Int32] = [0, 1, 2, 3, 4, 9, 10, 14, 22, 44]
        return (0 ..< count).map { index in
            table.intern(CellStyle(numberFormatID: formatIDs[index % formatIDs.count]))
        }
    }

    private static func makeSheet(
        id: SheetID,
        name: String,
        rows: Int,
        columns: Int,
        shape: Shape,
        styleIDs: [StyleID]
    ) throws(SheetError) -> Sheet {
        let store = try makeStore(rows: rows, columns: columns, shape: shape, styleIDs: styleIDs)
        return Sheet(id: id, name: name, cells: store, declaredDimension: store.usedRange)
    }

    private static func makeStore(
        rows: Int,
        columns: Int,
        shape: Shape,
        styleIDs: [StyleID]
    ) throws(SheetError) -> CellStore {
        var store = CellStore()
        guard rows > 0, columns > 0 else { return store }
        store.reserveCapacity(rows: rows)
        var random = SplitMix64(seed: shape.seed)
        var ordinal = 0
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                defer { ordinal += 1 }
                let noise = random.next()
                if shape.blankEvery > 0, ordinal.isMultiple(of: shape.blankEvery) { continue }
                var cell: Cell
                if shape.formulaEvery > 0, ordinal.isMultiple(of: shape.formulaEvery), row + column > 0 {
                    // Left neighbour when there is one, otherwise the cell above. Without that
                    // fallback a period that divides the column count — 10 formulas per row on a
                    // 10-column sheet — lands every candidate on column 0 and produces no
                    // formulas at all.
                    let neighbour = column > 0
                        ? CellRef(row: row, column: column - 1)
                        : CellRef(row: row - 1, column: column)
                    cell = .formula("\(neighbour.a1String)*2", cached: .number(Double(noise % 100_000) / 100))
                } else if shape.textEvery > 0, ordinal.isMultiple(of: shape.textEvery) {
                    cell = .text("r\(row)c\(column)")
                } else {
                    cell = .number(Double(noise % 10_000_000) / 100)
                }
                if shape.styledEvery > 0, ordinal.isMultiple(of: shape.styledEvery) {
                    cell.styleID = styleIDs[Int(noise % UInt64(styleIDs.count))]
                }
                try store.setCell(cell, at: CellRef(row: row, column: column))
            }
        }
        return store
    }
}
