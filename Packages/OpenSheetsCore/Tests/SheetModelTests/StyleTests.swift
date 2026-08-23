import Foundation
@testable import SheetModel
import Testing

@Suite("Colour")
struct ColourTests {
    @Test("ARGB hex parses in both the eight- and six-digit forms")
    func hexParsing() {
        #expect(RGBAColor(argbHex: "FFFF0000") == RGBAColor(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(RGBAColor(argbHex: "FF0000") == RGBAColor(red: 255, green: 0, blue: 0, alpha: 255))
        #expect(RGBAColor(argbHex: "#00FF00") == RGBAColor(red: 0, green: 255, blue: 0))
        #expect(RGBAColor(argbHex: "8000FF00")?.alpha == 128)
        #expect(RGBAColor(argbHex: "ff00ff00") == RGBAColor(red: 0, green: 255, blue: 0))
        #expect(RGBAColor(argbHex: "GG0000") == nil)
        #expect(RGBAColor(argbHex: "FF00") == nil)
        #expect(RGBAColor(argbHex: "") == nil)
        #expect(RGBAColor(argbHex: "FFFFFFFFFF") == nil)
    }

    @Test("hex round-trips")
    func hexRoundTrip() {
        for color in [RGBAColor.black, .white, .red, RGBAColor(red: 68, green: 114, blue: 196)] {
            #expect(RGBAColor(argbHex: color.argbHex) == color)
        }
    }

    @Test("tint zero is a no-op, and the extremes reach black and white")
    func tinting() {
        let accent = RGBAColor(red: 68, green: 114, blue: 196)
        #expect(accent.tinted(0) == accent)
        #expect(accent.tinted(-1) == RGBAColor.black)
        #expect(accent.tinted(1) == RGBAColor.white)

        // A negative tint darkens, a positive one lightens — measured on luminance, not channels.
        let darker = accent.tinted(-0.5)
        let lighter = accent.tinted(0.5)
        let luminance = { (c: RGBAColor) in Int(c.red) + Int(c.green) + Int(c.blue) }
        #expect(luminance(darker) < luminance(accent))
        #expect(luminance(lighter) > luminance(accent))
    }

    @Test("grey tints stay grey")
    func tintingGreys() {
        let grey = RGBAColor(red: 128, green: 128, blue: 128)
        let lighter = grey.tinted(0.4)
        #expect(lighter.red == lighter.green && lighter.green == lighter.blue)
    }

    @Test("the legacy indexed palette has all 64 slots and the specials")
    func indexedPalette() {
        let palette = ColorPalette.office
        #expect(palette.indexedColors.count == 64)
        #expect(palette.indexed(0) == RGBAColor.black)
        #expect(palette.indexed(1) == RGBAColor.white)
        #expect(palette.indexed(2) == RGBAColor.red)
        #expect(palette.indexed(64) == palette.automatic, "64 is the system foreground")
        #expect(palette.indexed(65) == palette.background, "65 is the system background")
        #expect(palette.indexed(999) == palette.automatic, "an out-of-range index falls back")
    }

    @Test("theme indices are translated out of OOXML's swapped order")
    func themeIndexSwap() {
        let palette = ColorPalette.office
        // theme="0" is light1 (white) and theme="1" is dark1 (black) — the reverse of the XML.
        #expect(palette.theme(0) == RGBAColor.white)
        #expect(palette.theme(1) == RGBAColor.black)
        #expect(palette.theme(4) == RGBAColor(red: 0x44, green: 0x72, blue: 0xC4), "accent1")
        #expect(palette.theme(99) == palette.automatic)
    }

    @Test("StyleColor resolves each specification kind")
    func styleColourResolution() {
        let palette = ColorPalette.office
        #expect(StyleColor.automatic.resolved(in: palette) == palette.automatic)
        #expect(StyleColor.rgb(.red).resolved(in: palette) == .red)
        #expect(StyleColor.indexed(2).resolved(in: palette) == .red)
        #expect(StyleColor.theme(index: 0, tint: 0).resolved(in: palette) == .white)
        #expect(StyleColor.theme(index: 1, tint: 0).resolved(in: palette) == .black)
        // A tint on a theme colour is applied after the lookup.
        #expect(StyleColor.theme(index: 1, tint: 1).resolved(in: palette) == .white)
    }

    @Test("StyleColor keeps how the colour was specified, not just its pixels")
    func specificationSurvives() throws {
        let themed = StyleColor.theme(index: 4, tint: -0.25)
        let encoded = try JSONEncoder().encode(themed)
        let decoded = try JSONDecoder().decode(StyleColor.self, from: encoded)
        #expect(decoded == themed)
        if case let .theme(index, tint) = decoded {
            #expect(index == 4)
            #expect(tint == -0.25)
        } else {
            Issue.record("a theme colour must not decode as something else")
        }
    }
}

@Suite("StyleTable")
struct StyleTableTests {
    @Test("an empty table still answers for the default style")
    func defaultStyle() {
        let table = StyleTable.empty
        #expect(table.count == 1)
        #expect(table[.default] == .default)
        #expect(table[StyleID(999)] == .default, "an unknown id falls back rather than trapping")
    }

    @Test("style(for:) throws where the subscript falls back")
    func strictLookup() throws {
        let table = StyleTable.empty
        #expect(try table.style(for: .default) == .default)
        #expect(throws: SheetError.self) { try table.style(for: StyleID(999)) }
    }

    @Test("interning deduplicates and keeps ids dense")
    func interning() {
        var table = StyleTable.empty
        var bold = CellStyle.default
        bold.font.isBold = true

        let first = table.intern(bold)
        let second = table.intern(bold)
        #expect(first == second, "the same style must not get two ids")
        #expect(first == StyleID(1))
        #expect(table.count == 2)

        var italic = CellStyle.default
        italic.font.isItalic = true
        #expect(table.intern(italic) == StyleID(2))
        #expect(table.count == 3)
        #expect(table.intern(.default) == .default)
    }

    @Test("ids are cellXfs indices when the table comes from a file")
    func idsMatchFilePositions() {
        var bold = CellStyle.default
        bold.font.isBold = true
        var wide = CellStyle.default
        wide.numberFormatID = 4

        let table = StyleTable(styles: [.default, bold, wide])
        #expect(table[StyleID(0)] == .default)
        #expect(table[StyleID(1)] == bold)
        #expect(table[StyleID(2)] == wide)
        #expect(table.count == 3)
    }

    @Test("built-in number formats resolve without appearing in the file")
    func builtInFormatResolution() {
        let table = StyleTable.empty
        #expect(table.numberFormat(id: 0).formatCode == "General")
        #expect(table.numberFormat(id: 2).formatCode == "0.00")
        #expect(table.numberFormat(id: 14).formatCode == "mm-dd-yy")
        #expect(table.numberFormat(id: 14).isDateTime)
        #expect(table.numberFormat(id: 9999).isGeneral, "an unknown id degrades to General")
    }

    @Test("custom formats take priority over the built-in table")
    func customFormatsWin() {
        var table = StyleTable.empty
        let id = table.internNumberFormat(NumberFormat("yyyy\"年\"m\"月\""))
        #expect(id >= NumberFormat.firstCustomFormatID)
        #expect(table.numberFormat(id: id).formatCode == "yyyy\"年\"m\"月\"")
        #expect(table.numberFormat(id: id).isDateTime)

        // Interning the same code twice reuses the id.
        #expect(table.internNumberFormat(NumberFormat("yyyy\"年\"m\"月\"")) == id)

        // A built-in code reuses its reserved id rather than allocating a custom one.
        #expect(table.internNumberFormat(NumberFormat("0.00")) == 2)
        #expect(table.internNumberFormat(NumberFormat("@")) == 49)
    }

    @Test("isDateTime is how a number becomes a date")
    func dateDetection() {
        var table = StyleTable.empty
        var dated = CellStyle.default
        dated.numberFormatID = 14
        let id = table.intern(dated)
        #expect(table.isDateTime(id))
        #expect(!table.isDateTime(.default))
        #expect(table.numberFormat(for: id).kind == .date)
    }

    @Test("derive changes one facet of an existing style")
    func derivation() {
        var table = StyleTable.empty
        let bold = table.derive(.default) { $0.font.isBold = true }
        #expect(table[bold].font.isBold)
        #expect(table[bold].font.size == CellStyle.default.font.size)

        let boldAndRed = table.derive(bold) { $0.font.color = .rgb(.red) }
        #expect(table[boldAndRed].font.isBold)
        #expect(table[boldAndRed].font.color == .rgb(.red))
        #expect(table.count == 3)
    }

    @Test("the quote prefix survives, so a text-forced cell stays text")
    func quotePrefix() {
        var table = StyleTable.empty
        let forced = table.derive(.default) { $0.quotePrefix = true }
        #expect(table[forced].quotePrefix)
        #expect(!table[.default].quotePrefix)
    }

    @Test("fills read their visible colour from the right slot")
    func fillColours() {
        #expect(FillStyle.none.effectiveColor == nil)
        #expect(FillStyle.solid(.rgb(.red)).effectiveColor == .rgb(.red))
        // For a solid fill the *foreground* is what you see, which is the counter-intuitive part.
        let solid = FillStyle(pattern: .solid, foreground: .rgb(.red), background: .rgb(.white))
        #expect(solid.effectiveColor == .rgb(.red))
        let hatched = FillStyle(pattern: .lightGrid, foreground: nil, background: .rgb(.white))
        #expect(hatched.effectiveColor == .rgb(.white))
    }

    @Test("borders report whether they draw anything")
    func borderVisibility() {
        #expect(!BorderStyle.none.isVisible)
        #expect(!BorderEdge.none.isVisible)
        var bordered = BorderStyle.none
        bordered.bottom = BorderEdge(style: .thin, color: .automatic)
        #expect(bordered.isVisible)
        #expect(bordered.bottom.isVisible)
        #expect(!bordered.top.isVisible)
    }
}
