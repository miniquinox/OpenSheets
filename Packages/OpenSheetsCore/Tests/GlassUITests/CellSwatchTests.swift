import SheetModel
import SwiftUI
import Testing

@testable import GlassUI

/// The colours the toolbar offers.
///
/// Small surface, but the part that matters is not the arithmetic — it is that every swatch is a
/// colour somebody can still read the sheet through. A palette is the kind of thing that gets a
/// hue added in a hurry, and the pale row exists precisely so a highlighted row stays legible.
@Suite("Cell swatches")
struct CellSwatchTests {
    @Test("Every swatch becomes a literal colour in the file, never a theme reference")
    func swatchesAreLiteral() {
        for swatch in CellSwatches.strong + CellSwatches.pale {
            guard case let .rgb(rgba) = swatch.style else {
                Issue.record("\(swatch.name) is not an rgb colour")
                continue
            }
            #expect(rgba == swatch.color)
            // Opaque, because Excel ignores alpha almost everywhere and a translucent fill would
            // look right here and wrong the moment the file is opened anywhere else.
            #expect(rgba.alpha == 255)
        }
    }

    @Test("Names are unique, so the menu never shows the same label twice")
    func namesAreUnique() {
        let names = (CellSwatches.strong + CellSwatches.pale).map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("The two rows line up, so the grid is rectangular")
    func rowsAreEqualLength() {
        #expect(CellSwatches.strong.count == CellSwatches.pale.count)
        #expect(CellSwatches.all == [CellSwatches.strong, CellSwatches.pale])
    }

    /// The point of the pale row. Relative luminance per WCAG; 0.5 is the rough line at which
    /// black text stops being the obvious choice on top.
    @Test("Every pale swatch can carry black text, and every strong one cannot be mistaken for one")
    func paleSwatchesAreActuallyPale() {
        func luminance(_ c: RGBAColor) -> Double {
            func channel(_ value: UInt8) -> Double {
                let v = Double(value) / 255
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
        }
        for swatch in CellSwatches.pale {
            #expect(luminance(swatch.color) > 0.5, "\(swatch.name) is too dark for black text")
        }
        for swatch in CellSwatches.strong {
            #expect(luminance(swatch.color) < 0.5, "\(swatch.name) is too light to read as ink")
        }
    }
}
