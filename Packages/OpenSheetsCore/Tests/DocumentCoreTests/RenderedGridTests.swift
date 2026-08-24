import AppKit
import DocumentCore
import Foundation
import GlassUI
import GridKit
import SheetFormat
import SheetModel
import SwiftUI
import TestSupport
import Testing

/// The grid **as assembled**: a real `.xlsx` on disk, read by the real reader, drawn by the real
/// renderer into a real `NSWindow`, with the pixels read back out.
///
/// # Why this suite has to exist
///
/// Three separate suites tested the pieces of dark mode and every one of them passed while the app
/// was unreadable. `GlassUITests` asserted the palette's contrast ratios — correct.
/// `GridKitTests.DarkModeTextTests` asserted `CellFormatter.display(of:)`'s colour — correct.
/// `DocumentCoreTests` asserted `GridThemeBridge`'s conversion — correct. Every colour in the
/// pipeline was right, and the pixels were black, because the defect was in the last inch: a
/// `CTLine` shaped without `kCTForegroundColorFromContextAttributeName` ignores
/// `CGContext.fillColor` and paints Core Text's own default, which is opaque black. Not one value
/// in any of those suites was wrong, so not one of them could have failed.
///
/// The only test that could have caught it is one that reads the pixel. That is what these do.
/// They are deliberately about *what came out*, not about what any layer decided on the way.
@Suite("Rendered grid")
@MainActor
struct RenderedGridTests {
    // MARK: - Bug 1: cell text in dark mode

    /// The colour a `<color theme="1"/>` cell actually draws in.
    ///
    /// `theme="1"` is what every producer writes for ordinary text and it means *"the text
    /// colour"*, not *"black"* — so on a dark canvas it has to come out light. The assertion is a
    /// contrast ratio between two **sampled** pixels rather than a comparison against a named
    /// colour, because the point is legibility rather than equality — a glyph's edge pixels are
    /// blends, and the window's backing store is in the display's colour space, not the palette's.
    /// Samples are converted back to sRGB before they are compared so the numbers mean what the
    /// palette means; comparing two *sampled* colours keeps the claim true even so.
    @Test("Cell text is legible against the canvas it is drawn on", arguments: [GlassColorScheme.light, .dark])
    func cellTextIsLegibleOnTheCanvas(scheme: GlassColorScheme) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let url = try scratch.writeThemeColouredWorkbook()
        let workbook = try await XLSXReader.read(contentsOf: url)
        let sheet = try #require(workbook.sheets.first)
        let theme = GridThemeBridge.resolved(AppearanceContext(colorScheme: scheme))

        let shot = try Shot(sheet: sheet, workbook: workbook, theme: theme)
        let canvas = try #require(shot.canvasColour)
        let ink = try #require(shot.strongestColour(inCellAt: CellRef(row: 1, column: 0)))

        #expect(
            contrast(ink, canvas) >= 4.5,
            """
            \(scheme): a cell drawn with <color theme="1"/> came out \(hex(ink)) on a canvas of \
            \(hex(canvas)) — \(String(format: "%.2f", contrast(ink, canvas))):1. Under the defect \
            this was 1.28:1, black text on the dark canvas, while every colour value in the \
            pipeline said #F5F5F7.
            """
        )
        // …and on the right side of the canvas, which is the part a ratio alone cannot say:
        // black on a dark grid and white on a light one both fail, and only one of them fails the
        // ratio.
        #expect(
            (luminance(ink) > luminance(canvas)) == (scheme == .dark),
            "\(scheme): the ink is on the wrong side of the canvas — \(hex(ink)) on \(hex(canvas))"
        )
    }

    /// The same claim for the header strip, which shapes its labels through the same cache and
    /// went black in exactly the same way.
    @Test("Header labels are legible too", arguments: [GlassColorScheme.light, .dark])
    func headerLabelsAreLegible(scheme: GlassColorScheme) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let workbook = try await XLSXReader.read(contentsOf: try scratch.writeThemeColouredWorkbook())
        let sheet = try #require(workbook.sheets.first)
        let theme = GridThemeBridge.resolved(AppearanceContext(colorScheme: scheme))
        let shot = try Shot(sheet: sheet, workbook: workbook, theme: theme)

        let background = try #require(shot.colour(atX: 6, y: 6))
        let label = try #require(shot.strongestColour(in: shot.columnHeaderRect(ofColumn: 0), against: background))
        #expect(
            contrast(label, background) >= 3.0,
            "\(scheme): the column letter came out \(hex(label)) on \(hex(background))"
        )
    }

    // MARK: - The gridlines

    /// A gridline you cannot find is the same failure as text you cannot read, one tier quieter.
    ///
    /// Measured on the *drawn* line rather than on the palette entry, because a hairline is
    /// half a point wide and what reaches the eye is whatever survives being snapped to a device
    /// pixel. Drawn into a bitmap this suite owns rather than into the window, for the reason
    /// ``PaneShot`` gives: a window's backing store is not in the palette's colour space and a
    /// ratio read out of one is off by a fifth in either direction.
    @Test("Gridlines are visible in the drawn grid", arguments: [GlassColorScheme.light, .dark])
    func gridlinesAreVisibleWhenDrawn(scheme: GlassColorScheme) async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let workbook = try await XLSXReader.read(contentsOf: try scratch.writeThemeColouredWorkbook())
        let sheet = try #require(workbook.sheets.first)
        let theme = GridThemeBridge.resolved(AppearanceContext(colorScheme: scheme))
        let shot = try PaneShot(sheet: sheet, workbook: workbook, theme: theme)

        // Well below and to the right of the two rows the fixture fills, so nothing but the
        // canvas and its gridlines is drawn here.
        let empty = CGRect(x: 200, y: 120, width: 180, height: 160)
        let canvas = shot.colour(atX: empty.midX, y: empty.midY - 6)
        #expect(
            canvas == theme.canvasBackground,
            "the canvas sampled \(hex(canvas)) where the theme says \(hex(theme.canvasBackground))"
        )
        let line = try #require(shot.strongestColour(in: empty, against: canvas))
        let ratio = contrast(line, canvas)
        #expect(
            ratio >= 1.4,
            """
            \(scheme): the strongest gridline pixel is \(hex(line)) on \(hex(canvas)), \
            \(String(format: "%.2f", ratio)):1. Excel's own is about 1.44:1; below that people ask \
            whether the grid has cell lines at all — which is exactly what happened at 1.27:1 and \
            1.33:1, both of which cleared the old 1.2 floor.
            """
        )
        #expect(
            ratio <= 3.0,
            "\(scheme): \(String(format: "%.2f", ratio)):1 is a border, not a gridline"
        )
    }

    // MARK: - Bug 2: default-width columns

    /// A column the file does not size holds the number Excel would show in it.
    ///
    /// `<col width>` is "characters of the normal font"; the reader turns that into points and the
    /// renderer takes ``SheetModel/Limits/cellPadding`` back off before deciding whether a number
    /// fits. This asserts the two halves agree, in the units that decide it — the width of the
    /// *font the renderer actually resolved*, which is not Calibri, because Calibri is not on a
    /// Mac and `FontResolver` substitutes.
    ///
    /// Under the defect the reader also scaled by 72/96, so a default column arrived 25% narrower
    /// than Excel shows it and every numeric cell in it rendered `####`.
    @Test func aDefaultWidthColumnHoldsTheNumberExcelShowsInIt() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let workbook = try await XLSXReader.read(contentsOf: try scratch.writeThemeColouredWorkbook())
        let sheet = try #require(workbook.sheets.first)
        let theme = GridThemeBridge.resolved(.light)
        let model = GridRenderModel(sheet: sheet, styles: workbook.styles, theme: theme)

        // B2 is a seven-digit grouped number in a column the file gives no `<col>` for.
        let ref = CellRef(row: 1, column: 1)
        let cell = try #require(sheet.cells[ref])
        let styleID = model.effectiveStyleID(at: ref, cell: cell)
        let display = CellFormatter(styles: workbook.styles, theme: theme).display(of: cell, styleID: styleID)
        #expect(display.text == "1,681,500", "the fixture is meant to be a wide grouped number")

        let font = FontKey(
            style: workbook.styles[styleID].font,
            zoom: 1,
            fallbackFamily: theme.bodyFontName,
            fallbackSize: theme.defaultFontSize
        )
        let width = TextLayoutCache(capacity: 64).width(of: display.text, font: font)
        let available = sheet.columnWidths[1] - 2 * theme.cellPaddingX
        #expect(
            width <= available,
            """
            "\(display.text)" needs \(String(format: "%.1f", width))pt and the default column \
            leaves \(String(format: "%.1f", available))pt, so it renders as ####. The column is \
            \(String(format: "%.1f", sheet.columnWidths[1]))pt.
            """
        )
    }

    /// The general form of the same rule, stated once so it cannot drift: the width a file asks
    /// for in characters survives the round trip into points *and back out through the renderer's
    /// padding*.
    @Test func aColumnHoldsAsManyCharactersAsTheFileAskedFor() {
        let theme = GridThemeBridge.resolved(.light)
        #expect(
            theme.cellPaddingX * 2 == Limits.cellPadding,
            """
            The grid pads \(theme.cellPaddingX * 2)pt per column and the XLSX reader reserves \
            \(Limits.cellPadding)pt. Reserve one and subtract the other and every column in every \
            file holds fewer characters than the file promised — a column of ####.
            """
        )
        let excelDefault = 8.43
        let points = XLSXColumnMetrics.points(fromCharacters: excelDefault)
        let usable = points - theme.cellPaddingX * 2
        let font = FontKey(family: theme.bodyFontName, size: 11, isBold: false, isItalic: false)
        let digit = TextLayoutCache(capacity: 16).width(of: "0", font: font)
        #expect(
            usable / digit >= excelDefault - 0.2,
            """
            A default Excel column is \(excelDefault) characters. This one comes to \
            \(String(format: "%.2f", usable / digit)) of the renderer's own digit \
            (\(String(format: "%.2f", digit))pt) — the file's promise is not being kept.
            """
        )
    }

    // MARK: - The ambient appearance

    /// The appearance the window is actually **in**, followed all the way to a pixel.
    ///
    /// # The seam every other test in this file steps over
    ///
    /// The tests above are each handed an `AppearanceContext` and ask whether the drawing is right
    /// *for it*. That is the whole question for a renderer and it is only half the question for an
    /// app, because it leaves the other half unasked: **who decides which context?** A palette that
    /// is correct in both schemes and a selector that picks the wrong one produce a window that is
    /// uniformly, confidently wrong — and not one assertion in this file, or in `GlassUITests`, or
    /// in `GridKitTests`, would move. That is the same shape as the Core Text defect this suite was
    /// written for: every value correct, the pixels wrong, because the defect was in the assembly.
    ///
    /// So this one sets no context. It sets the **window's `NSAppearance`** — which is the only
    /// thing the system sets in the real app — hosts the same chain `DocumentWindow` builds
    /// (`@Environment(\.colorScheme)` → ``GlassUI/AccessibilityAppearance/context(for:)`` →
    /// ``SwiftUI/View/glassAppearance(_:)`` → ``SwiftUI/View/gridPlane(_:)``), and reads the
    /// canvas back out.
    ///
    /// The claim is deliberately "closer to its own canvas than to the other one" rather than an
    /// equality: a window's backing store is not in the palette's colour space (see ``PaneShot``),
    /// so `#1C1C1E` reads back as `#252528`. That skew is a few percent and the two canvases are
    /// near-white and near-black, so the comparison is not remotely close — which is the point. It
    /// fails only if the window painted *the other scheme*, which is exactly the bug worth having a
    /// test for.
    @Test(
        "The drawn canvas follows the window's own appearance",
        arguments: [GlassColorScheme.light, .dark]
    )
    func theCanvasFollowsTheWindowsOwnAppearance(scheme: GlassColorScheme) throws {
        let shot = try AmbientShot(windowAppearance: scheme)
        let sampled = try #require(shot.canvasColour, "nothing was drawn")

        let mine = GlassUI.GridTheme.resolved(AppearanceContext(colorScheme: scheme)).canvas
        let theirs = GlassUI.GridTheme.resolved(
            AppearanceContext(colorScheme: scheme == .dark ? .light : .dark)
        ).canvas

        let toMine = abs(luminance(sampled) - luminance(mine))
        let toTheirs = abs(luminance(sampled) - luminance(theirs))
        #expect(
            toMine < toTheirs,
            """
            A window whose NSAppearance is \(scheme) painted \(hex(sampled)), which is nearer the \
            \(scheme == .dark ? "light" : "dark") canvas (\(hex(theirs))) than its own \
            (\(hex(mine))). The palette is not what is wrong here — the window resolved the wrong \
            appearance and every colour in it is confidently, uniformly the other theme's.
            """
        )
        // Stated a second way, because the one above is a comparison and this is the claim a
        // person makes when they look at the screen: a light window is light.
        #expect(
            (luminance(sampled) > 0.5) == (scheme == .light),
            "\(scheme): the canvas sampled \(hex(sampled)), which is not a \(scheme) canvas"
        )
    }

    /// The same window, the same chain, the theme A4 would actually be handed.
    ///
    /// ``GridThemeBridge`` is what carries the appearance across into AppKit, where there is no
    /// SwiftUI environment to read — so "the SwiftUI half resolved light" and "the renderer was
    /// told light" are two claims, and the grid is drawn by the second one.
    @Test(
        "The renderer is handed the theme for the window's appearance",
        arguments: [GlassColorScheme.light, .dark]
    )
    func theRendererIsHandedTheWindowsAppearance(scheme: GlassColorScheme) throws {
        let shot = try AmbientShot(windowAppearance: scheme)
        let resolved = try #require(shot.resolvedContext, "the hosted view never evaluated")
        #expect(
            resolved.colorScheme == scheme,
            """
            A window whose NSAppearance is \(scheme) resolved an AppearanceContext of \
            \(resolved.colorScheme). GridThemeBridge hands that straight to A4, so the grid would \
            be drawn entirely in the other theme.
            """
        )
        let canvas = GridThemeBridge.resolved(resolved).canvasBackground
        #expect(
            (luminance(canvas) > 0.5) == (scheme == .light),
            "\(scheme): A4 would draw its canvas \(hex(canvas))"
        )
    }

    // MARK: - The chrome material

    /// A label on a chrome band stays readable **over any wallpaper**.
    ///
    /// # Why a nominal token is not enough here
    ///
    /// Every other contrast assertion in this project compares two palette values, and that works
    /// because both of them are ours. A chrome band is not: it is an `NSVisualEffectView` whose
    /// colour is *the user's desktop*, blurred and tinted. The composited result is the only thing
    /// a person actually reads, and no token describes it.
    ///
    /// This is the failure the material has to be tuned against, and it is a real one — the first
    /// attempt at making this app look like glass put a lens over a transparent window, and the
    /// sidebar labels ended up sitting on a legible photograph of a mountain. Nothing in the
    /// palette moved. The only measurement that would have caught it is this one: draw the label
    /// on the material, over the worst wallpaper there is, and read the pixels.
    ///
    /// # The two worst wallpapers
    ///
    /// Pure white and pure black. A real desktop is somewhere between, so a material that clears
    /// 4.5:1 against both ends clears it against every photograph in between.
    ///
    /// # `.withinWindow`, and what that costs the claim
    ///
    /// The app uses `.behindWindow` blending, which samples the desktop — and a test has no
    /// desktop, so it cannot be reproduced. This uses the **same material** with `.withinWindow`
    /// over a backdrop the test controls. The tint and the blur are the material's own and are
    /// identical; what differs is where the samples come from. So this asserts the material is
    /// opaque enough, which is the property under test, and does not assert anything about
    /// AppKit's window compositing, which is not ours to assert.
    @Test(
        "A chrome label is legible on the material over any wallpaper",
        arguments: [GlassColorScheme.light, .dark], [Wallpaper.white, .black]
    )
    func chromeLabelsAreLegibleOnTheMaterial(scheme: GlassColorScheme, wallpaper: Wallpaper) throws {
        let shot = try ChromeShot(scheme: scheme, wallpaper: wallpaper)
        let material = try #require(shot.materialColour, "the material drew nothing")
        let ink = try #require(shot.labelColour(against: material), "the label drew nothing")
        let ratio = contrast(ink, material)

        #expect(
            ratio >= 4.5,
            """
            \(scheme) chrome over a \(wallpaper) desktop: the label came out \(hex(ink)) on a \
            composited material of \(hex(material)) — \(String(format: "%.2f", ratio)):1. The \
            palette is not what is wrong: the material is too thin, and the wallpaper is reaching \
            the text. A band you can read the desktop through is a bug even when it is pretty.
            """
        )
    }

    /// The other half of the same claim, and the one that says *"you cannot see the picture"*.
    ///
    /// A material that merely clears 4.5:1 can still be a window: a *uniform* wallpaper is the
    /// easy case. What actually has to be true is that the band's own colour barely moves when the
    /// wallpaper behind it changes from white to black — that is what "ambient tint, not
    /// transparency" means, stated as a number.
    ///
    /// The threshold has room in it on purpose. Some drift is the whole point of vibrancy, and a
    /// material that did not move at all would be an opaque rectangle. What is ruled out is the
    /// band tracking the wallpaper closely enough for a photograph to survive it.
    ///
    /// Measured today: **0.10** dark, **0.16** light. A clear window would be 1.0 — which is what
    /// the first attempt at this actually scored, when the bands were Liquid Glass over a
    /// transparent window and the desktop came through at full sharpness. `0.30` sits well clear
    /// of the real values and well clear of that failure, so it can only move on a real change.
    @Test(
        "The material tints with the wallpaper rather than showing it",
        arguments: [GlassColorScheme.light, .dark]
    )
    func theMaterialTintsRatherThanTransmits(scheme: GlassColorScheme) throws {
        let onWhite = try #require(ChromeShot(scheme: scheme, wallpaper: .white).materialColour)
        let onBlack = try #require(ChromeShot(scheme: scheme, wallpaper: .black).materialColour)
        let drift = abs(luminance(onWhite) - luminance(onBlack))

        #expect(
            drift <= 0.30,
            """
            \(scheme): the band reads \(hex(onWhite)) over a white desktop and \(hex(onBlack)) \
            over a black one — a luminance swing of \(String(format: "%.2f", drift)) out of 1.0, \
            against a ceiling of 0.30 and measured values of 0.10/0.16. At that range the band is \
            not tinting with the wallpaper, it is transmitting it, and a photograph behind it will \
            be recognisable.
            """
        )
    }

    // MARK: - Scaffolding

    /// A temporary folder holding a real `.xlsx`, written by the real writer.
    struct Scratch {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensheets-render-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }

        /// A workbook whose text colour is `<color theme="1"/>` and whose columns carry no
        /// `<col>` element, so both defects have somewhere to happen.
        ///
        /// Written and then read back rather than built in memory: `theme="1"` only means what it
        /// means once it has been through the styles writer and the styles reader, and "the colour
        /// survived the round trip" is half of what is under test.
        func writeThemeColouredWorkbook() throws -> URL {
            var font = FontStyle()
            font.name = "Calibri"
            font.size = 11
            font.color = .theme(index: 1, tint: 0)
            var style = CellStyle()
            style.font = font
            style.numberFormatID = 3 // the built-in `#,##0`

            var builder = WorkbookBuilder().sheet("Budget")
                .partPath("xl/worksheets/sheet1.xml", relationshipID: "rId1")
            builder = builder.withStyle(style) { id, builder in
                builder
                    .cell("A1", .text("Line item")).styleID("A1", id)
                    .cell("A2", .text("Salaries")).styleID("A2", id)
                    .cell("B2", .number(1_681_500)).styleID("B2", id)
                    .cell("C2", .number(412_000)).styleID("C2", id)
            }
            let workbook = try builder.build()
            var tracker = WorkbookEditTracker()
            for sheet in workbook.sheets { tracker.noteSheetReplaced(sheet) }
            let target = url.appendingPathComponent("themed.xlsx")
            try XLSXWriter.data(for: workbook, edits: tracker).write(to: target)
            return target
        }
    }

    /// Windows outlive the test that made them: an `NSWindow` that goes out of scope takes its
    /// content view's layout with it, and half-laid-out pixels are not evidence.
    nonisolated(unsafe) private static var retained: [NSWindow] = []

    /// One drawn frame of the grid, with the pixels readable.
    @MainActor
    struct Shot {
        let view: GridHostView
        let bitmap: NSBitmapImageRep
        let scale: Double
        let insets: NSEdgeInsets
        let geometry: GridGeometry

        init(sheet: Sheet, workbook: Workbook, theme: GridKit.GridTheme) throws {
            let model = GridRenderModel(
                sheet: sheet,
                styles: workbook.styles,
                dateSystem: workbook.meta.dateSystem,
                theme: theme,
                geometry: GridGeometry(sheet: sheet),
                merges: MergeIndex(sheet.merges),
                // Parked well off screen. A selection on A1 puts an accent stroke and a fill
                // handle along A2's top edge, and "the strongest pixel in this cell" would find
                // the accent rather than the glyph — which is a test that passes on black text.
                selection: GridSelection(active: CellRef(row: 200, column: 40))
            )
            view = GridHostView(model: model)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 900, height: 500),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            window.contentView = view
            view.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RenderedGridTests.retained.append(window)

            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw ShotFailure.noBitmap
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            bitmap = rep
            scale = Double(rep.pixelsWide) / Double(view.bounds.width)
            insets = view.contentScrollView.contentInsets
            geometry = model.geometry
        }

        enum ShotFailure: Error { case noBitmap }

        func colour(atX x: Double, y: Double) -> NSColor? {
            bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }

        /// A cell's rectangle in the host's own coordinates.
        func rect(ofCellAt ref: CellRef) -> CGRect {
            let sheetRect = geometry.sheetRect(row: ref.row, column: ref.column)
            return CGRect(
                x: insets.left + sheetRect.minX - geometry.frozenWidth,
                y: insets.top + sheetRect.minY - geometry.frozenHeight,
                width: sheetRect.width,
                height: sheetRect.height
            )
        }

        func columnHeaderRect(ofColumn column: Int) -> CGRect {
            let sheetRect = geometry.sheetRect(row: 0, column: column)
            return CGRect(
                x: insets.left + sheetRect.minX - geometry.frozenWidth,
                y: 2, width: sheetRect.width, height: insets.top - 4
            )
        }

        /// Somewhere with nothing in it but the canvas and its gridlines.
        var emptyRegion: CGRect {
            CGRect(x: insets.left + 20, y: insets.top + 120, width: 300, height: 120)
        }

        /// The canvas colour, read off a cell nobody wrote in.
        var canvasColour: NSColor? {
            colour(atX: insets.left + 200, y: insets.top + 200)
        }

        /// The pixel in `rect` furthest from `reference`, which for a cell is the core of a glyph
        /// and for an empty region is a gridline.
        func strongestColour(in rect: CGRect, against reference: NSColor) -> NSColor? {
            var best: NSColor?
            var bestRatio = 1.0
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX {
                    if let sample = colour(atX: x, y: y) {
                        let ratio = contrast(sample, reference)
                        if ratio > bestRatio {
                            bestRatio = ratio
                            best = sample
                        }
                    }
                    x += 1 / scale
                }
                y += 1 / scale
            }
            return best
        }

        func strongestColour(inCellAt ref: CellRef) -> NSColor? {
            guard let canvas = canvasColour else { return nil }
            return strongestColour(in: rect(ofCellAt: ref), against: canvas)
        }
    }
}

extension RenderedGridTests {
    /// One pane, drawn by the real renderer into a bitmap **this suite owns**, in sRGB.
    ///
    /// The window is the right place to ask *whether* something painted; it is the wrong place to
    /// ask *what colour*. A window's backing store is in the display's space with its own transfer
    /// function, and a palette entry does not survive the trip: `#1C1C1E` reads back as `#252528`
    /// and `#D4D4D8` as `#DCDCE0`, which lifts a dark pair's contrast by a quarter and drops a
    /// light pair's by the same. Fine for "there is ink here" — a 15:1 pair stays far above 4.5 —
    /// and useless for a 1.4:1 hairline, where a fifth is the whole margin.
    ///
    /// So: same reader, same theme bridge, same renderer, named colour space. What comes out here
    /// is the number a designer can check against the palette.
    @MainActor
    struct PaneShot {
        let context: CGContext
        let scale: Double
        let geometry: GridGeometry

        init(sheet: Sheet, workbook: Workbook, theme: GridKit.GridTheme, scale: Double = 2) throws {
            self.scale = scale
            let model = GridRenderModel(
                sheet: sheet,
                styles: workbook.styles,
                dateSystem: workbook.meta.dateSystem,
                theme: theme,
                geometry: GridGeometry(sheet: sheet),
                merges: MergeIndex(sheet.merges),
                selection: GridSelection(active: CellRef(row: 200, column: 40))
            )
            geometry = model.geometry
            let width = 400
            let height = 300
            guard let made = CGContext(
                data: nil,
                width: Int(Double(width) * scale),
                height: Int(Double(height) * scale),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw Shot.ShotFailure.noBitmap }
            context = made
            // Flipped, which is the space the renderer draws in.
            context.translateBy(x: 0, y: Double(height) * scale)
            context.scaleBy(x: scale, y: -scale)
            let renderer = GridRenderer(theme: theme)
            renderer.backingScale = scale
            renderer.draw(
                .body,
                into: context,
                viewRect: CGRect(x: 0, y: 0, width: Double(width), height: Double(height)),
                sheetOrigin: .zero,
                model: model
            )
        }

        func colour(atX x: Double, y: Double) -> RGBAColor {
            guard let data = context.data else { return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) }
            let column = Int(x * scale)
            let row = Int(y * scale)
            guard column >= 0, column < context.width, row >= 0, row < context.height else {
                return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
            }
            let pointer = data.advanced(by: row * context.bytesPerRow + column * 4)
                .assumingMemoryBound(to: UInt8.self)
            return RGBAColor(red: pointer[0], green: pointer[1], blue: pointer[2], alpha: pointer[3])
        }

        /// The pixel in `rect` furthest from `reference` — a gridline, in an empty band.
        func strongestColour(in rect: CGRect, against reference: RGBAColor) -> RGBAColor? {
            var best: RGBAColor?
            var bestRatio = 1.0
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX {
                    let sample = colour(atX: x, y: y)
                    let ratio = contrast(sample, reference)
                    if ratio > bestRatio {
                        bestRatio = ratio
                        best = sample
                    }
                    x += 1 / scale
                }
                y += 1 / scale
            }
            return best
        }
    }
}

extension RenderedGridTests {
    /// One drawn frame of the document plane in a window that has been told **only** its
    /// `NSAppearance` — the single thing the system sets in the real app.
    ///
    /// Everything else has to be worked out downstream, by the same chain `RootView` and
    /// `DocumentWindow` use. Nothing here is handed an `AppearanceContext`; producing one is what
    /// is under test.
    @MainActor
    struct AmbientShot {
        let bitmap: NSBitmapImageRep
        let scale: Double
        /// What the hosted view actually resolved. The pixel says the SwiftUI half is right; this
        /// says A4 would be told the same thing, and they are two different claims.
        let resolvedContext: AppearanceContext?

        private static let side = 200.0

        init(windowAppearance scheme: GlassColorScheme) throws {
            let recorder = ContextRecorder()
            let host = NSHostingView(rootView: AmbientPlane(recorder: recorder))
            let frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
            let window = NSWindow(
                contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            // The one and only input.
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = frame
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RenderedGridTests.retained.append(window)

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw Shot.ShotFailure.noBitmap
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            bitmap = rep
            scale = Double(rep.pixelsWide) / Double(host.bounds.width)
            resolvedContext = recorder.context
        }

        /// The middle of the plane. There is nothing else drawn in this window.
        var canvasColour: NSColor? {
            bitmap.colorAt(x: Int(Self.side / 2 * scale), y: Int(Self.side / 2 * scale))?
                .usingColorSpace(.sRGB)
        }
    }

    /// A box for what the hosted view resolved.
    ///
    /// A plain reference type rather than `@State` or `@Observable` on purpose: writing to it from
    /// `body` records without invalidating, so the render it is recording cannot loop.
    @MainActor
    final class ContextRecorder {
        var context: AppearanceContext?
    }

    /// The app's chain with nothing taken out: read the ambient scheme, build the context from it,
    /// pin it, paint the plane. `RootView` and `DocumentWindow` each do exactly this.
    struct AmbientPlane: View {
        let recorder: ContextRecorder

        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let context = AccessibilityAppearance().context(for: colorScheme)
            recorder.context = context
            return Color.clear.gridPlane(context)
        }
    }
}

extension RenderedGridTests {
    /// The two worst desktops there are. Everything a person actually sets is between them.
    enum Wallpaper: CustomStringConvertible {
        case white
        case black

        var color: NSColor { self == .white ? .white : .black }
        var description: String { self == .white ? "white" : "black" }
    }

    /// A chrome label drawn on the real material, over a backdrop the test owns.
    @MainActor
    struct ChromeShot {
        let bitmap: NSBitmapImageRep
        let scale: Double

        private static let side = 240.0
        /// Kept clear of the material's own edge treatment, which is brighter than its field and
        /// would otherwise be found instead of the glyph.
        private static let margin = 12.0

        init(scheme: GlassColorScheme, wallpaper: Wallpaper) throws {
            let frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
            let window = NSWindow(
                contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false
            )
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)

            let root = NSView(frame: frame)
            root.wantsLayer = true
            root.layer?.backgroundColor = wallpaper.color.cgColor

            let effect = NSVisualEffectView(frame: frame)
            effect.material = ChromeVibrancy.sidebar.material
            effect.blendingMode = .withinWindow
            effect.state = .active
            root.addSubview(effect)

            // The label the sidebar actually draws, in the token it actually uses.
            let host = NSHostingView(
                rootView: Text("Assumptions")
                    .font(DS.Text.control)
                    .foregroundStyle(DS.Chrome.primary)
            )
            host.frame = CGRect(x: 24, y: Self.side / 2 - 10, width: 180, height: 20)
            effect.addSubview(host)

            window.contentView = root
            root.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RenderedGridTests.retained.append(window)

            guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
                throw Shot.ShotFailure.noBitmap
            }
            root.cacheDisplay(in: root.bounds, to: rep)
            bitmap = rep
            scale = Double(rep.pixelsWide) / Double(root.bounds.width)
        }

        func colour(atX x: Double, y: Double) -> NSColor? {
            bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }

        /// The band's own colour, read well away from the label.
        var materialColour: NSColor? {
            colour(atX: Self.side - Self.margin, y: Self.margin)
        }

        /// The core of a glyph: the pixel furthest from the material anywhere in the band.
        func labelColour(against material: NSColor) -> NSColor? {
            var best: NSColor?
            var bestRatio = 1.0
            var y = Self.margin
            while y < Self.side - Self.margin {
                var x = Self.margin
                while x < Self.side - Self.margin {
                    if let sample = colour(atX: x, y: y) {
                        let ratio = contrast(sample, material)
                        if ratio > bestRatio {
                            bestRatio = ratio
                            best = sample
                        }
                    }
                    x += 1 / scale
                }
                y += 1 / scale
            }
            return best
        }
    }
}

// MARK: - Colour arithmetic

/// WCAG relative luminance, on a sampled pixel.
private func luminance(_ colour: NSColor) -> Double {
    func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(colour.redComponent)
        + 0.7152 * channel(colour.greenComponent)
        + 0.0722 * channel(colour.blueComponent)
}

private func contrast(_ lhs: NSColor, _ rhs: NSColor) -> Double {
    let a = luminance(lhs)
    let b = luminance(rhs)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func hex(_ colour: NSColor) -> String {
    String(
        format: "#%02X%02X%02X",
        Int((colour.redComponent * 255).rounded()),
        Int((colour.greenComponent * 255).rounded()),
        Int((colour.blueComponent * 255).rounded())
    )
}


private func luminance(_ colour: RGBAColor) -> Double {
    func channel(_ value: UInt8) -> Double {
        let unit = Double(value) / 255
        return unit <= 0.03928 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(colour.red) + 0.7152 * channel(colour.green) + 0.0722 * channel(colour.blue)
}

private func contrast(_ lhs: RGBAColor, _ rhs: RGBAColor) -> Double {
    let a = luminance(lhs)
    let b = luminance(rhs)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func hex(_ colour: RGBAColor) -> String {
    String(format: "#%02X%02X%02X", Int(colour.red), Int(colour.green), Int(colour.blue))
}

private func luminance(_ colour: RGBA) -> Double {
    func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(colour.red) + 0.7152 * channel(colour.green) + 0.0722 * channel(colour.blue)
}

private func hex(_ colour: RGBA) -> String {
    String(
        format: "#%02X%02X%02X",
        Int((colour.red * 255).rounded()),
        Int((colour.green * 255).rounded()),
        Int((colour.blue * 255).rounded())
    )
}
