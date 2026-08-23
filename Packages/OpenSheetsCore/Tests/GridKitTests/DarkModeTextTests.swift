import SheetModel
import Testing
@testable import GridKit

/// The bug a user reported: in dark mode, cell text rendered black on the dark canvas.
///
/// The tell was that the sidebar was bright white and the numbers beside it were not — two
/// halves of the same window disagreeing about what "text" means. The theme was never at fault;
/// `GridTheme.dark` has always specified near-white ink on `#1C1C1E`. What the cells were drawing
/// was the *file's declared font colour*, `<color theme="1"/>`, resolved against Office's
/// literal palette to black.
///
/// `<color theme="1"/>` is what every producer writes for ordinary text — twenty-one of the
/// seventy fixtures in this repository declare it, as does `Demo/q4-budget.xlsx`, which openpyxl
/// wrote. So this was not one unlucky file; it was nearly every real workbook.
@Suite("Dark-mode cell text")
struct DarkModeTextTests {
    /// A workbook styled the way openpyxl styles one: a default font that says `theme="1"`.
    private static func styles(color: StyleColor) -> StyleTable {
        var font = FontStyle()
        font.color = color
        return StyleTable(styles: [CellStyle(font: font)])
    }

    private static func ink(_ color: StyleColor, theme: GridTheme) -> RGBAColor {
        let formatter = CellFormatter(styles: styles(color: color), theme: theme)
        return formatter.display(of: Cell(value: .number(1234)), styleID: StyleID(rawValue: 0)).color
    }

    // MARK: - The symptom

    @Test("a cell declaring theme=1 renders light on the dark grid")
    func themeOneTextIsReadableInDarkMode() {
        let canvas = GridTheme.dark.canvasBackground
        let drawn = DarkModeTextTests.ink(.theme(index: 1, tint: 0), theme: .dark).composited(over: canvas)
        let luminance = drawn.relativeLuminance
        let contrast = drawn.contrastRatio(against: canvas)
        #expect(luminance > 0.5, "got \(drawn), which is not light")
        #expect(contrast >= 4.5, "got \(contrast):1")
    }

    @Test("and dark on the light grid")
    func themeOneTextIsReadableInLightMode() {
        let canvas = GridTheme.light.canvasBackground
        let drawn = DarkModeTextTests.ink(.theme(index: 1, tint: 0), theme: .light).composited(over: canvas)
        let luminance = drawn.relativeLuminance
        let contrast = drawn.contrastRatio(against: canvas)
        #expect(luminance < 0.5, "got \(drawn), which is not dark")
        #expect(contrast >= 4.5, "got \(contrast):1")
    }

    @Test("the grid agrees with itself: file-declared text matches automatic text")
    func theTwoDefaultTextColoursAgree() {
        // The two ways a file can say "just use the default text colour" have to land in the
        // same place, or half a sheet is one colour and half is another.
        for theme in [GridTheme.dark, GridTheme.light] {
            #expect(
                DarkModeTextTests.ink(.theme(index: 1, tint: 0), theme: theme)
                    == DarkModeTextTests.ink(.automatic, theme: theme)
            )
        }
    }

    // MARK: - The boundary

    @Test("an explicit black is still drawn black, in both schemes")
    func anExplicitColourIsHonoured() {
        // Someone who set black meant black. Excel keeps it, and swapping it would be an edit
        // to their document that they never made and cannot see us making.
        #expect(DarkModeTextTests.ink(.rgb(.black), theme: .dark) == .black)
        #expect(DarkModeTextTests.ink(.rgb(.black), theme: .light) == .black)
        #expect(DarkModeTextTests.ink(.rgb(.red), theme: .dark) == .red)
    }

    @Test("a workbook's own accent colour survives, on either appearance")
    func aCustomThemesAccentsAreUsedAndNotSwapped() {
        var custom = ColorPalette.office
        custom.themeColors[4] = RGBAColor(red: 0x12, green: 0x9A, blue: 0x74)
        var font = FontStyle()
        font.color = .theme(index: 4, tint: 0)
        var styles = StyleTable(styles: [CellStyle(font: font)])
        styles.palette = custom

        for theme in [GridTheme.dark, GridTheme.light] {
            let formatter = CellFormatter(styles: styles, theme: theme)
            let drawn = formatter.display(of: Cell(value: .number(1)), styleID: StyleID(rawValue: 0)).color
            #expect(drawn == RGBAColor(red: 0x12, green: 0x9A, blue: 0x74))
        }
    }

    @Test("a fill declaring theme=0 follows the canvas rather than painting white over it")
    func themeZeroFillsFollowTheCanvas() {
        let palette = GridTheme.dark.stylePalette
        #expect(StyleColor.theme(index: 0, tint: 0).resolved(in: palette) == GridTheme.dark.canvasBackground)
    }

    // MARK: - The class of bug, not just this instance

    @Test("every theme slot a file can name for text stays legible on both grids", arguments: 0 ... 9)
    func noThemeSlotProducesUnreadableText(slot: Int) {
        // Slots 0 and 1 are the semantic pair and must pass outright. The accents are brand
        // colours: they are allowed to be low-contrast against one canvas — that is the
        // document's own choice — but they must not be *identical* to the canvas, which is what
        // a mis-swapped semantic slot looks like.
        for theme in [GridTheme.dark, GridTheme.light] {
            let canvas = theme.canvasBackground
            let drawn = DarkModeTextTests.ink(.theme(index: slot, tint: 0), theme: theme)
                .composited(over: canvas)
            let contrast = drawn.contrastRatio(against: canvas)
            if slot == 1 {
                #expect(contrast >= 4.5, "theme=\(slot) on \(canvas) is \(contrast):1")
            }
            if slot >= 4 {
                #expect(drawn != canvas, "an accent must never resolve to the canvas itself")
            }
        }
    }
}
