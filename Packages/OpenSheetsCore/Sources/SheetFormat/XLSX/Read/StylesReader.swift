//
//  StylesReader.swift
//  SheetFormat
//
//  A1 owns this file. `xl/styles.xml` and `xl/theme/theme1.xml` → a `StyleTable`.
//

import Foundation

import SheetModel

/// Parses `xl/styles.xml` into a ``SheetModel/StyleTable``.
///
/// xlsx stores styles as five parallel index tables — `numFmts`, `fonts`, `fills`, `borders`,
/// `cellXfs` — where a cell points at a `cellXfs` row that points at all the others. The model
/// flattens that, and the flattening has to preserve **index order exactly**: a ``StyleID``'s raw
/// value *is* its `cellXfs` index, which is what lets `styles.xml` pass through byte-identical
/// while every cell's `s="…"` attribute stays correct.
public enum StylesReader {
    /// Reads `styles.xml`, optionally against a theme part for `theme=` colour references.
    public static func read(
        _ bytes: [UInt8],
        part: String,
        palette: ColorPalette = .office
    ) throws(SheetError) -> StyleTable {
        try XMLParsing.withParser(over: bytes, part: part) { parser throws(SheetError) in
            var customFormats: [Int32: NumberFormat] = [:]
            var fonts: [FontStyle] = []
            var fills: [FillStyle] = []
            var borders: [BorderStyle] = []
            var cellFormats: [CellStyle] = []
            var indexedOverrides: [RGBAColor] = []
            var section = Section.none

            while let event = try parser.next() {
                switch event {
                case .startElement:
                    if parser.nameIs("cellStyleXfs") {
                        // Named-style bases. We read `cellXfs` directly rather than resolving
                        // `xfId` inheritance: Excel's `applyFont`/`applyFill` flags decide which
                        // facets inherit, producers set them inconsistently, and a wrong
                        // inheritance is a visible restyle. See A1's notes to A2.
                        try parser.skipElement()
                    } else if parser.nameIs("dxfs") || parser.nameIs("tableStyles") || parser.nameIs("extLst") {
                        try parser.skipElement()
                    } else if parser.nameIs("numFmts") {
                        section = .numberFormats
                    } else if parser.nameIs("fonts") {
                        section = .fonts
                    } else if parser.nameIs("fills") {
                        section = .fills
                    } else if parser.nameIs("borders") {
                        section = .borders
                    } else if parser.nameIs("cellXfs") {
                        section = .cellFormats
                    } else if parser.nameIs("indexedColors") {
                        indexedOverrides = try readIndexedColors(&parser)
                    } else if parser.nameIs("numFmt"), section == .numberFormats {
                        if let id = parser.attribute("numFmtId")?.int32,
                           let code = try parser.attribute("formatCode")?.string() {
                            customFormats[id] = NumberFormat(code)
                        }
                    } else if parser.nameIs("font"), section == .fonts {
                        fonts.append(try readFont(&parser))
                    } else if parser.nameIs("fill"), section == .fills {
                        fills.append(try readFill(&parser))
                    } else if parser.nameIs("border"), section == .borders {
                        borders.append(try readBorder(&parser))
                    } else if parser.nameIs("xf"), section == .cellFormats {
                        cellFormats.append(
                            try readCellFormat(&parser, fonts: fonts, fills: fills, borders: borders)
                        )
                    }
                case .endElement:
                    if parser.nameIs("numFmts") || parser.nameIs("fonts") || parser.nameIs("fills")
                        || parser.nameIs("borders") || parser.nameIs("cellXfs") {
                        section = .none
                    }
                case .characters:
                    continue
                }
            }

            var resolved = palette
            if !indexedOverrides.isEmpty {
                // `<indexedColors>` replaces the legacy palette from index 0 up, entry for entry.
                for (index, colour) in indexedOverrides.enumerated() where resolved.indexedColors.indices
                    .contains(index) {
                    resolved.indexedColors[index] = colour
                }
            }
            return StyleTable(styles: cellFormats, customNumberFormats: customFormats, palette: resolved)
        }
    }

    private enum Section {
        case none, numberFormats, fonts, fills, borders, cellFormats
    }

    // MARK: - Fonts

    private static func readFont(_ parser: inout XMLPullParser) throws(SheetError) -> FontStyle {
        let target = parser.depth - 1
        var font = FontStyle()
        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("sz") {
                    font.size = parser.attribute("val")?.double ?? font.size
                } else if parser.nameIs("name") || parser.nameIs("rFont") {
                    font.name = try parser.attribute("val")?.string() ?? font.name
                } else if parser.nameIs("b") {
                    font.isBold = parser.attribute("val").map(\.bool) ?? true
                } else if parser.nameIs("i") {
                    font.isItalic = parser.attribute("val").map(\.bool) ?? true
                } else if parser.nameIs("strike") {
                    font.isStrikethrough = parser.attribute("val").map(\.bool) ?? true
                } else if parser.nameIs("u") {
                    font.underline = underline(parser.attribute("val"))
                } else if parser.nameIs("vertAlign") {
                    if let value = parser.attribute("val") {
                        font.verticalAlignment = value.equals("superscript")
                            ? .superscript
                            : (value.equals("subscript") ? .subscript : .baseline)
                    }
                } else if parser.nameIs("color") {
                    font.color = readColor(&parser) ?? .automatic
                }
            case .endElement:
                if parser.depth == target { return font }
            case .characters:
                continue
            }
        }
        throw SheetError.xmlMalformed(part: parser.part, line: nil, detail: "<font> is not closed")
    }

    private static func underline(_ value: XMLValue?) -> FontStyle.Underline {
        guard let value else { return .single }
        if value.equals("none") { return .none }
        if value.equals("double") { return .double }
        if value.equals("singleAccounting") { return .singleAccounting }
        if value.equals("doubleAccounting") { return .doubleAccounting }
        return .single
    }

    // MARK: - Fills

    private static func readFill(_ parser: inout XMLPullParser) throws(SheetError) -> FillStyle {
        let target = parser.depth - 1
        var fill = FillStyle()
        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("patternFill") {
                    fill.pattern = pattern(parser.attribute("patternType"))
                } else if parser.nameIs("fgColor") {
                    fill.foreground = readColor(&parser)
                } else if parser.nameIs("bgColor") {
                    fill.background = readColor(&parser)
                } else if parser.nameIs("gradientFill") {
                    // Gradients are not modelled. The `<fill>` entry still round-trips through
                    // `OpaqueParts`; what is lost is only our *rendering* of it.
                    try parser.skipElement()
                }
            case .endElement:
                if parser.depth == target { return fill }
            case .characters:
                continue
            }
        }
        throw SheetError.xmlMalformed(part: parser.part, line: nil, detail: "<fill> is not closed")
    }

    private static func pattern(_ value: XMLValue?) -> FillStyle.Pattern {
        guard let value else { return .none }
        for candidate in FillStyle.Pattern.allCases where value.matchesRawValue(candidate.rawValue) {
            return candidate
        }
        return .none
    }

    // MARK: - Borders

    private static func readBorder(_ parser: inout XMLPullParser) throws(SheetError) -> BorderStyle {
        let target = parser.depth - 1
        var border = BorderStyle()
        border.diagonalUp = parser.attribute("diagonalUp")?.bool ?? false
        border.diagonalDown = parser.attribute("diagonalDown")?.bool ?? false
        var edge: WritableKeyPath<BorderStyle, BorderEdge>?

        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("left") || parser.nameIs("start") {
                    edge = \.leading
                } else if parser.nameIs("right") || parser.nameIs("end") {
                    edge = \.trailing
                } else if parser.nameIs("top") {
                    edge = \.top
                } else if parser.nameIs("bottom") {
                    edge = \.bottom
                } else if parser.nameIs("diagonal") {
                    edge = \.diagonal
                } else if parser.nameIs("color"), let edge {
                    border[keyPath: edge].color = readColor(&parser)
                    continue
                } else {
                    continue
                }
                if let edge {
                    border[keyPath: edge].style = lineStyle(parser.attribute("style"))
                }
            case .endElement:
                if parser.depth == target { return border }
            case .characters:
                continue
            }
        }
        throw SheetError.xmlMalformed(part: parser.part, line: nil, detail: "<border> is not closed")
    }

    private static func lineStyle(_ value: XMLValue?) -> BorderEdge.LineStyle {
        guard let value else { return .none }
        for candidate in BorderEdge.LineStyle.allCases where value.matchesRawValue(candidate.rawValue) {
            return candidate
        }
        return .none
    }

    // MARK: - Cell formats

    private static func readCellFormat(
        _ parser: inout XMLPullParser,
        fonts: [FontStyle],
        fills: [FillStyle],
        borders: [BorderStyle]
    ) throws(SheetError) -> CellStyle {
        let target = parser.depth - 1
        var style = CellStyle()
        style.numberFormatID = parser.attribute("numFmtId")?.int32 ?? 0
        if let index = parser.attribute("fontId")?.int, fonts.indices.contains(index) { style.font = fonts[index] }
        if let index = parser.attribute("fillId")?.int, fills.indices.contains(index) { style.fill = fills[index] }
        if let index = parser.attribute("borderId")?.int, borders.indices.contains(index) {
            style.border = borders[index]
        }
        // Load-bearing on write: without it a cell holding `00123` comes back as a number.
        style.quotePrefix = parser.attribute("quotePrefix")?.bool ?? false

        if parser.depth == target { return style }

        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("alignment") {
                    style.alignment = readAlignment(&parser)
                } else if parser.nameIs("protection") {
                    style.isLocked = parser.attribute("locked")?.bool ?? true
                    style.isFormulaHidden = parser.attribute("hidden")?.bool ?? false
                }
            case .endElement:
                if parser.depth == target { return style }
            case .characters:
                continue
            }
        }
        throw SheetError.xmlMalformed(part: parser.part, line: nil, detail: "<xf> is not closed")
    }

    private static func readAlignment(_ parser: inout XMLPullParser) -> CellAlignment {
        var alignment = CellAlignment()
        if let value = parser.attribute("horizontal") {
            for candidate in CellAlignment.Horizontal.allCases where value.matchesRawValue(candidate.rawValue) {
                alignment.horizontal = candidate
                break
            }
        }
        if let value = parser.attribute("vertical") {
            for candidate in CellAlignment.Vertical.allCases where value.matchesRawValue(candidate.rawValue) {
                alignment.vertical = candidate
                break
            }
        }
        alignment.wrapText = parser.attribute("wrapText")?.bool ?? false
        alignment.indent = parser.attribute("indent")?.int ?? 0
        alignment.textRotation = parser.attribute("textRotation")?.int ?? 0
        alignment.shrinkToFit = parser.attribute("shrinkToFit")?.bool ?? false
        alignment.readingOrder = parser.attribute("readingOrder")?.int ?? 0
        return alignment
    }

    // MARK: - Colours

    /// Reads a `<color>`/`<fgColor>`/`<bgColor>` element's colour specification.
    ///
    /// Order matters: `auto` wins over everything, then an explicit `rgb`, then a theme slot
    /// (with its tint), then the legacy indexed palette. Flattening all of these to RGB on read
    /// would render correctly today and silently break the file's relationship to its theme on
    /// the next save.
    static func readColor(_ parser: inout XMLPullParser) -> StyleColor? {
        if parser.attribute("auto")?.bool == true { return .automatic }
        if let hex = parser.attribute("rgb"), let colour = hex.rgbaColor { return .rgb(colour) }
        if let theme = parser.attribute("theme")?.int {
            return .theme(index: theme, tint: parser.attribute("tint")?.double ?? 0)
        }
        if let indexed = parser.attribute("indexed")?.int { return .indexed(indexed) }
        return nil
    }

    private static func readIndexedColors(_ parser: inout XMLPullParser) throws(SheetError) -> [RGBAColor] {
        let target = parser.depth - 1
        var colours: [RGBAColor] = []
        while let event = try parser.next() {
            switch event {
            case .startElement:
                if parser.nameIs("rgbColor"), let hex = parser.attribute("rgb"), let colour = hex.rgbaColor {
                    colours.append(colour)
                }
            case .endElement:
                if parser.depth == target { return colours }
            case .characters:
                continue
            }
        }
        return colours
    }
}

/// Parses `xl/theme/theme1.xml` down to the twelve colours a `theme=` attribute indexes.
public enum ThemeReader {
    /// The `clrScheme` slots, in the order ``SheetModel/ColorPalette/themeColors`` documents.
    private static let slots: [StaticString] = [
        "dk1", "lt1", "dk2", "lt2",
        "accent1", "accent2", "accent3", "accent4", "accent5", "accent6",
        "hlink", "folHlink",
    ]

    /// Reads the theme's colour scheme, falling back to Office's defaults for anything missing.
    public static func read(_ bytes: [UInt8], part: String) throws(SheetError) -> ColorPalette {
        var palette = ColorPalette.office
        try XMLParsing.withParser(over: bytes, part: part) { parser throws(SheetError) in
            var inScheme = false
            var slot: Int?
            while let event = try parser.next() {
                switch event {
                case .startElement:
                    if parser.nameIs("clrScheme") {
                        inScheme = true
                    } else if inScheme, slot == nil {
                        slot = slots.firstIndex { parser.nameIs($0) }
                    } else if let index = slot, index < palette.themeColors.count {
                        if parser.nameIs("srgbClr"), let hex = parser.attribute("val"), let colour = hex.rgbaColor {
                            palette.themeColors[index] = colour
                        } else if parser.nameIs("sysClr"), let hex = parser.attribute("lastClr"),
                                  let colour = hex.rgbaColor {
                            palette.themeColors[index] = colour
                        }
                    }
                case .endElement:
                    if parser.nameIs("clrScheme") { inScheme = false }
                    if let index = slot, parser.nameIs(slots[index]) { slot = nil }
                case .characters:
                    continue
                }
            }
        }
        return palette
    }
}

extension XMLValue {
    /// Whether the raw bytes equal `rawValue`, for matching an enum case without allocating.
    func matchesRawValue(_ rawValue: String) -> Bool {
        guard rawValue.utf8.count == byteCount else { return false }
        var index = 0
        for byte in rawValue.utf8 {
            guard bytes[index] == byte else { return false }
            index += 1
        }
        return true
    }

    /// The value as an `ARGB` colour, or `nil`.
    var rgbaColor: RGBAColor? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        return RGBAColor(argbHex: text)
    }
}
