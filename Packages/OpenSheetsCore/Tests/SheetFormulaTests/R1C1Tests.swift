import Foundation
import SheetModel
import Testing
@testable import SheetFormula

/// R1C1 in and out.
///
/// Needed twice: xlsx stores a shared-formula group as one master formula that every member
/// re-anchors, and the MCP surface offers R1C1 because an offset is easier for a model to get
/// right than a column letter.
struct R1C1Tests {
    @Test(arguments: [
        // anchor C3 (row 2, column 2)
        ("A1", "R[-2]C[-2]"),
        ("$A$1", "R1C1"),
        ("$A1", "R[-2]C1"),
        ("A$1", "R1C[-2]"),
        ("C3", "RC"),
        ("C4", "R[1]C"),
        ("D3", "RC[1]"),
        ("A1:B2", "R[-2]C[-2]:R[-1]C[-1]"),
        ("$A$1:$B$2", "R1C1:R2C2"),
        ("A:A", "C[-2]"),
        ("$A:$A", "C1"),
        ("1:1", "R[-2]"),
        ("Data!A1", "Data!R[-2]C[-2]"),
        ("#REF!", "#REF!"),
    ])
    func convertsA1ToR1C1(_ a1: String, _ r1c1: String) throws {
        let anchor = CellRef(row: 2, column: 2)
        #expect(try FormulaSyntax.toR1C1(a1, at: anchor) == r1c1)
    }

    @Test(arguments: [
        ("R[-2]C[-2]", "A1"),
        ("R1C1", "$A$1"),
        ("R[-2]C1", "$A1"),
        ("R1C[-2]", "A$1"),
        ("RC", "C3"),
        ("R[1]C", "C4"),
        ("RC[1]", "D3"),
        ("R[-2]C[-2]:R[-1]C[-1]", "A1:B2"),
        ("R1C1:R2C2", "$A$1:$B$2"),
        ("C[-2]", "A:A"),
        ("C1", "$A:$A"),
        ("R[-2]", "1:1"),
        ("Data!R[-2]C[-2]", "Data!A1"),
    ])
    func convertsR1C1ToA1(_ r1c1: String, _ a1: String) throws {
        let anchor = CellRef(row: 2, column: 2)
        #expect(try FormulaSyntax.fromR1C1(r1c1, at: anchor) == a1)
    }

    @Test func r1c1FunctionNamesAreNotMistakenForReferences() throws {
        // `ROUND` starts with R and `COUNT` with C; a naive R1C1 scanner eats both.
        let anchor = CellRef(row: 4, column: 4)
        #expect(try FormulaSyntax.fromR1C1("ROUND(RC[-1],2)", at: anchor) == "ROUND(D5,2)")
        #expect(try FormulaSyntax.fromR1C1("COUNT(R[-1]C:RC)", at: anchor) == "COUNT(E4:E5)")
    }

    @Test func expandsASharedFormulaGroupTheWayXlsxDoes() throws {
        // The master at B2 is `=A2*2`; members B3 and B4 share it. Round-tripping through
        // R1C1 at each member's own address is exactly how the expansion is defined.
        let master = CellRef(row: 1, column: 1)
        let shared = try FormulaSyntax.toR1C1("A2*2", at: master)
        #expect(shared == "RC[-1]*2")
        #expect(try FormulaSyntax.fromR1C1(shared, at: CellRef(row: 2, column: 1)) == "A3*2")
        #expect(try FormulaSyntax.fromR1C1(shared, at: CellRef(row: 3, column: 1)) == "A4*2")
    }

    @Test func roundTripsThroughR1C1AndBack() throws {
        let anchor = CellRef(row: 7, column: 3)
        for formula in ["SUM(A1:A9)", "SUM($A$1:$A$9)", "IF(D8>0,D7,$B$1)", "SUM(A:A)+SUM(3:3)"] {
            let r1c1 = try FormulaSyntax.toR1C1(formula, at: anchor)
            #expect(try FormulaSyntax.fromR1C1(r1c1, at: anchor) == formula)
        }
    }

    @Test func relativeReferencesAreOffsetsSoTheAnchorMatters() throws {
        let shared = "R[-1]C"
        #expect(try FormulaSyntax.fromR1C1(shared, at: CellRef(row: 5, column: 0)) == "A5")
        #expect(try FormulaSyntax.fromR1C1(shared, at: CellRef(row: 9, column: 2)) == "C9")
    }
}
