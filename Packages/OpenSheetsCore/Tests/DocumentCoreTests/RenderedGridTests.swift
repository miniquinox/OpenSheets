import AppKit
import DocumentCore
import Foundation
import GlassUI
import GridKit
import SheetFormat
import SheetModel
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
