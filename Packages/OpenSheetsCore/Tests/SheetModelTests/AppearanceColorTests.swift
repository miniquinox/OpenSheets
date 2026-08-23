import SheetModel
import Testing

/// Theme slots 0–3 are semantic, and resolving them literally is what made the dark grid
/// unreadable.
///
/// `<color theme="1"/>` is `dk1` — OOXML's *major text colour* — and it is what openpyxl,
/// xlsxwriter, pandas and Excel itself write for ordinary text. Reading it as "black" is
/// correct on a white canvas and wrong on a dark one, and since almost every file says it, the
/// wrongness is not an edge case.
@Suite("Appearance-relative theme colours")
struct AppearanceColorTests {
    private static let darkInk = RGBAColor(red: 245, green: 245, blue: 247)
    private static let darkCanvas = RGBAColor(red: 28, green: 28, blue: 30)

    private static var dark: ColorPalette {
        ColorPalette.office.forAppearance(ink: darkInk, canvas: darkCanvas)
    }

    private static var light: ColorPalette {
        ColorPalette.office.forAppearance(ink: .black, canvas: .white)
    }

    // MARK: - The bug

    @Test("theme=1 is the ink, not black")
    func majorTextFollowsTheAppearance() {
        let onDark = StyleColor.theme(index: 1, tint: 0).resolved(in: AppearanceColorTests.dark)
        #expect(onDark == AppearanceColorTests.darkInk)
        #expect(StyleColor.theme(index: 1, tint: 0).resolved(in: AppearanceColorTests.light) == .black)
    }

    @Test("theme=0 is the canvas, not white")
    func majorBackgroundFollowsTheAppearance() {
        let resolved = StyleColor.theme(index: 0, tint: 0).resolved(in: AppearanceColorTests.dark)
        #expect(resolved == AppearanceColorTests.darkCanvas)
        #expect(StyleColor.theme(index: 0, tint: 0).resolved(in: AppearanceColorTests.light) == .white)
    }

    @Test("theme=1 text stays readable against theme=0 fill on either appearance")
    func theSemanticPairIsAlwaysReadable() {
        for palette in [AppearanceColorTests.dark, AppearanceColorTests.light] {
            let ink = StyleColor.theme(index: 1, tint: 0).resolved(in: palette)
            let fill = StyleColor.theme(index: 0, tint: 0).resolved(in: palette)
            #expect(
                ink.contrastRatio(against: fill) >= 4.5,
                "PLAN.md §3.5 wants 4.5:1; got \(ink.contrastRatio(against: fill))"
            )
        }
    }

    // MARK: - The boundaries

    @Test("an explicit rgb black stays black, even on a dark canvas")
    func literalColoursAreNeverSecondGuessed() {
        // The user asked for black. Excel honours that and so do we — overriding it would be a
        // different bug, and a worse one, because it is unrecoverable from the file.
        #expect(StyleColor.rgb(.black).resolved(in: AppearanceColorTests.dark) == .black)
        #expect(StyleColor.rgb(.white).resolved(in: AppearanceColorTests.dark) == .white)
    }

    @Test("legacy indexed colours stay literal")
    func indexedColoursAreNeverSecondGuessed() {
        // Index 0 is the legacy palette's black and means exactly that.
        #expect(StyleColor.indexed(0).resolved(in: AppearanceColorTests.dark) == .black)
        // 64 and 65 are the two that were always system colours, and still are.
        #expect(StyleColor.indexed(64).resolved(in: AppearanceColorTests.dark) == AppearanceColorTests.darkInk)
        #expect(StyleColor.indexed(65).resolved(in: AppearanceColorTests.dark) == AppearanceColorTests.darkCanvas)
    }

    @Test("accent slots are brand colours and never move", arguments: 4 ... 9)
    func accentsAreNeverSwapped(slot: Int) {
        let onDark = StyleColor.theme(index: slot, tint: 0).resolved(in: AppearanceColorTests.dark)
        let onLight = StyleColor.theme(index: slot, tint: 0).resolved(in: AppearanceColorTests.light)
        #expect(onDark == onLight)
        #expect(onDark == ColorPalette.office.literalTheme(slot))
    }

    @Test("the minor pair exchanges roles rather than becoming the grid's own colours")
    func theMinorPairKeepsItsHues() {
        // `dk2`/`lt2` are the document's secondary text and background. On a dark appearance
        // the light one is the text — but it is still the *file's* light one, so a document's
        // secondary shade stays recognisably its own.
        let literalDark2 = ColorPalette.office.literalTheme(2)
        let literalLight2 = ColorPalette.office.literalTheme(3)
        #expect(StyleColor.theme(index: 3, tint: 0).resolved(in: AppearanceColorTests.light) == literalDark2)
        #expect(StyleColor.theme(index: 3, tint: 0).resolved(in: AppearanceColorTests.dark) == literalLight2)
        #expect(StyleColor.theme(index: 2, tint: 0).resolved(in: AppearanceColorTests.dark) == literalDark2)
    }

    @Test("tint still applies on top of the appearance-relative base")
    func tintIsUnaffected() {
        // "60% lighter than the text colour" has to mean 60% lighter than *this* text colour,
        // or every tinted theme colour in the file comes out wrong.
        let base = StyleColor.theme(index: 1, tint: 0).resolved(in: AppearanceColorTests.light)
        let tinted = StyleColor.theme(index: 1, tint: 0.6).resolved(in: AppearanceColorTests.light)
        #expect(tinted == base.tinted(0.6))
        #expect(tinted != base)
        #expect(tinted.relativeLuminance > base.relativeLuminance, "a positive tint lightens")

        let darkBase = StyleColor.theme(index: 1, tint: 0).resolved(in: AppearanceColorTests.dark)
        let darkTinted = StyleColor.theme(index: 1, tint: -0.5).resolved(in: AppearanceColorTests.dark)
        #expect(darkTinted == darkBase.tinted(-0.5))
        #expect(darkTinted.relativeLuminance < darkBase.relativeLuminance, "a negative tint darkens")
    }

    @Test("a palette can still report what the theme part literally says")
    func literalResolutionIsStillAvailable() {
        // A colour picker showing theme swatches wants the file's own values, not the grid's.
        var literal = AppearanceColorTests.dark
        literal.resolvesSemanticThemeSlots = false
        #expect(StyleColor.theme(index: 1, tint: 0).resolved(in: literal) == .black)
        #expect(StyleColor.theme(index: 0, tint: 0).resolved(in: literal) == .white)
    }

    @Test("the default Office palette is unchanged, so nothing that was right became wrong")
    func theDefaultPaletteBehavesExactlyAsBefore() {
        #expect(StyleColor.theme(index: 1, tint: 0).resolved() == .black)
        #expect(StyleColor.theme(index: 0, tint: 0).resolved() == .white)
        #expect(StyleColor.theme(index: 4, tint: 0).resolved() == ColorPalette.office.literalTheme(4))
    }

    // MARK: - The measurement the rule is made of

    @Test("relative luminance and contrast match the WCAG reference values")
    func contrastArithmeticIsRight() {
        #expect(abs(RGBAColor.white.relativeLuminance - 1) < 1e-9)
        #expect(abs(RGBAColor.black.relativeLuminance) < 1e-9)
        #expect(abs(RGBAColor.white.contrastRatio(against: .black) - 21) < 1e-6)
        #expect(abs(RGBAColor.white.contrastRatio(against: .white) - 1) < 1e-9)
        // #767676 on white is WCAG's canonical "just passes 4.5:1" grey.
        let grey = RGBAColor(red: 0x76, green: 0x76, blue: 0x76)
        #expect(grey.contrastRatio(against: .white) >= 4.5)
    }

    @Test("compositing accounts for the grid ink's alpha")
    func translucentInkIsCompositedBeforeItIsJudged() {
        // The dark theme's ink is white at 91%, which has no luminance of its own until it is
        // drawn on something.
        let ink = RGBAColor(red: 255, green: 255, blue: 255, alpha: 232)
        let composited = ink.composited(over: AppearanceColorTests.darkCanvas)
        #expect(composited.alpha == 255)
        #expect(composited.red > 230 && composited.red < 255)
        #expect(composited.contrastRatio(against: AppearanceColorTests.darkCanvas) >= 4.5)
        #expect(RGBAColor.white.composited(over: .black) == .white, "an opaque colour is unchanged")
    }
}
