//
//  StylePartWriter.swift
//  SheetFormat
//
//  `styles.xml` grows at the end and never in the middle.
//

import Foundation
import SheetModel

/// Serialises `xl/styles.xml`.
///
/// # Append, never rebuild
///
/// A cell says `s="7"`, and `7` is an index into `<cellXfs>`. Dirty tracking is per part, so a
/// save that rewrites `sheet3.xml` copies `sheet1.xml` through untouched — and every index in it
/// has to keep meaning what it meant. Rebuilding `<cellXfs>` from the style table renumbers it
/// and restyles sheets nobody edited.
///
/// So the existing part is re-emitted verbatim and new styles are appended: a `<font>`, a
/// `<fill>`, a `<border>` and an `<xf>` per style beyond the count the file already had. The new
/// records are not deduplicated against the existing ones — doing that would mean parsing every
/// font in the file and agreeing with Excel about what makes two fonts equal, and duplicate
/// records are legal, small, and harmless.
///
/// `<dxfs>`, `<tableStyles>`, `<cellStyles>`, `<colors>` and `<extLst>` are copied untouched.
/// Conditional-format formatting lives in `<dxfs>` and is referenced by index from a
/// `<conditionalFormatting>` fragment we preserve verbatim; regenerating it would break both
/// halves at once.
public enum StylePartWriter {
    /// The existing part with any styles beyond its `cellXfs` count appended, or `nil` when
    /// there is nothing to add.
    public static func patched(_ xml: String, table: StyleTable) throws(SheetError) -> String? {
        let scanned = try WorksheetPartScanner.scan(xml, part: OOXMLPart.styles)
        var children = scanned.children

        let existingStyles = childCount(of: "cellXfs", in: children, element: "xf")
        guard table.count > existingStyles else { return nil }

        var fontIndex = childCount(of: "fonts", in: children, element: "font")
        var fillIndex = childCount(of: "fills", in: children, element: "fill")
        var borderIndex = childCount(of: "borders", in: children, element: "border")

        var newFonts = ""
        var newFills = ""
        var newBorders = ""
        var newXfs = ""
        var newFormats = ""
        var addedFonts = 0
        var addedFills = 0
        var addedBorders = 0
        var addedFormats = 0

        let declaredFormats = Set(
            (children.first { $0.localName == "numFmts" }?.text).map(numberFormatIDs(in:)) ?? []
        )

        for rawIndex in existingStyles ..< table.count {
            let style = table[StyleID(rawValue: Int32(rawIndex))]
            newFonts += fontElement(style.font)
            newFills += fillElement(style.fill)
            newBorders += borderElement(style.border)
            newXfs += xfElement(style, font: fontIndex, fill: fillIndex, border: borderIndex)
            fontIndex += 1
            fillIndex += 1
            borderIndex += 1
            addedFonts += 1
            addedFills += 1
            addedBorders += 1

            if style.numberFormatID >= 164, !declaredFormats.contains(style.numberFormatID),
               let format = table.customNumberFormats[style.numberFormatID] {
                newFormats += "<numFmt numFmtId=\"\(style.numberFormatID)\" "
                newFormats += "formatCode=\"\(XLSXEscape.attribute(format.formatCode))\"/>"
                addedFormats += 1
            }
        }

        append(newFonts, count: addedFonts, to: "fonts", in: &children)
        append(newFills, count: addedFills, to: "fills", in: &children)
        append(newBorders, count: addedBorders, to: "borders", in: &children)
        append(newXfs, count: table.count - existingStyles, to: "cellXfs", in: &children)
        if !newFormats.isEmpty {
            append(newFormats, count: addedFormats, to: "numFmts", in: &children)
        }

        var output = scanned.prolog + scanned.rootOpenTag
        for child in children { output += child.text }
        output += "</\(scanned.rootQualifiedName)>"
        return output
    }

    /// A complete `styles.xml` for a workbook that never had one.
    public static func newPart(_ table: StyleTable) -> String {
        var output = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\r\n"
        output += "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"

        let customFormats = table.customNumberFormats.sorted { $0.key < $1.key }
        if !customFormats.isEmpty {
            output += "<numFmts count=\"\(customFormats.count)\">"
            for (identifier, format) in customFormats {
                output += "<numFmt numFmtId=\"\(identifier)\" "
                output += "formatCode=\"\(XLSXEscape.attribute(format.formatCode))\"/>"
            }
            output += "</numFmts>"
        }

        output += "<fonts count=\"\(table.count)\">"
        for index in 0 ..< table.count { output += fontElement(table[StyleID(rawValue: Int32(index))].font) }
        output += "</fonts>"

        // Excel requires the first two fills to be `none` and `gray125` and ignores what a file
        // says about them, so the generated table starts there and appends the real ones after.
        output += "<fills count=\"\(table.count + 2)\">"
        output += "<fill><patternFill patternType=\"none\"/></fill>"
        output += "<fill><patternFill patternType=\"gray125\"/></fill>"
        for index in 0 ..< table.count { output += fillElement(table[StyleID(rawValue: Int32(index))].fill) }
        output += "</fills>"

        output += "<borders count=\"\(table.count)\">"
        for index in 0 ..< table.count { output += borderElement(table[StyleID(rawValue: Int32(index))].border) }
        output += "</borders>"

        output += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>"
        output += "</cellStyleXfs>"

        output += "<cellXfs count=\"\(table.count)\">"
        for index in 0 ..< table.count {
            let style = table[StyleID(rawValue: Int32(index))]
            output += xfElement(style, font: index, fill: index + 2, border: index)
        }
        output += "</cellXfs>"

        output += "<cellStyles count=\"1\">"
        output += "<cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        output += "<dxfs count=\"0\"/>"
        output += "</styleSheet>"
        return output
    }

    // MARK: - Elements

    static func fontElement(_ font: FontStyle) -> String {
        var output = "<font>"
        output += "<sz val=\"\(XLSXEscape.number(font.size))\"/>"
        output += "<name val=\"\(XLSXEscape.attribute(font.name))\"/>"
        if font.isBold { output += "<b/>" }
        if font.isItalic { output += "<i/>" }
        if font.isStrikethrough { output += "<strike/>" }
        if font.underline != .none { output += "<u val=\"\(font.underline.rawValue)\"/>" }
        if font.verticalAlignment != .baseline { output += "<vertAlign val=\"\(font.verticalAlignment.rawValue)\"/>" }
        if let color = colorElement(font.color) { output += color }
        return output + "</font>"
    }

    static func fillElement(_ fill: FillStyle) -> String {
        guard fill.pattern != .none else { return "<fill><patternFill patternType=\"none\"/></fill>" }
        var output = "<fill><patternFill patternType=\"\(fill.pattern.rawValue)\">"
        if let foreground = fill.foreground, let element = colorElement(foreground, tag: "fgColor") {
            output += element
        }
        if let background = fill.background, let element = colorElement(background, tag: "bgColor") {
            output += element
        }
        return output + "</patternFill></fill>"
    }

    static func borderElement(_ border: BorderStyle) -> String {
        var output = "<border"
        if border.diagonalUp { output += " diagonalUp=\"1\"" }
        if border.diagonalDown { output += " diagonalDown=\"1\"" }
        output += ">"
        output += edgeElement("left", border.leading)
        output += edgeElement("right", border.trailing)
        output += edgeElement("top", border.top)
        output += edgeElement("bottom", border.bottom)
        output += edgeElement("diagonal", border.diagonal)
        return output + "</border>"
    }

    private static func edgeElement(_ name: String, _ edge: BorderEdge) -> String {
        guard edge.isVisible else { return "<\(name)/>" }
        var output = "<\(name) style=\"\(edge.style.rawValue)\">"
        if let color = edge.color, let element = colorElement(color) { output += element }
        return output + "</\(name)>"
    }

    static func xfElement(_ style: CellStyle, font: Int, fill: Int, border: Int) -> String {
        var output = "<xf numFmtId=\"\(style.numberFormatID)\" fontId=\"\(font)\" "
        output += "fillId=\"\(fill)\" borderId=\"\(border)\" xfId=\"0\""
        if style.numberFormatID != 0 { output += " applyNumberFormat=\"1\"" }
        if style.font != .default { output += " applyFont=\"1\"" }
        if style.fill != .none { output += " applyFill=\"1\"" }
        if style.border != .none { output += " applyBorder=\"1\"" }
        if style.quotePrefix { output += " quotePrefix=\"1\"" }

        let alignment = style.alignment
        let needsAlignment = alignment != .default
        if needsAlignment { output += " applyAlignment=\"1\"" }
        if !style.isLocked || style.isFormulaHidden { output += " applyProtection=\"1\"" }

        guard needsAlignment || !style.isLocked || style.isFormulaHidden else { return output + "/>" }
        output += ">"
        if needsAlignment {
            output += "<alignment"
            if alignment.horizontal != .general { output += " horizontal=\"\(alignment.horizontal.rawValue)\"" }
            if alignment.vertical != .bottom { output += " vertical=\"\(alignment.vertical.rawValue)\"" }
            if alignment.wrapText { output += " wrapText=\"1\"" }
            if alignment.shrinkToFit { output += " shrinkToFit=\"1\"" }
            if alignment.indent != 0 { output += " indent=\"\(alignment.indent)\"" }
            if alignment.textRotation != 0 { output += " textRotation=\"\(alignment.textRotation)\"" }
            if alignment.readingOrder != 0 { output += " readingOrder=\"\(alignment.readingOrder)\"" }
            output += "/>"
        }
        if !style.isLocked || style.isFormulaHidden {
            output += "<protection locked=\"\(style.isLocked ? 1 : 0)\" hidden=\"\(style.isFormulaHidden ? 1 : 0)\"/>"
        }
        return output + "</xf>"
    }

    private static func colorElement(_ color: StyleColor, tag: String = "color") -> String? {
        switch color {
        case .automatic: nil
        case let .rgb(value): "<\(tag) rgb=\"\(value.argbHex)\"/>"
        case let .indexed(index): "<\(tag) indexed=\"\(index)\"/>"
        case let .theme(index, tint):
            tint == 0
                ? "<\(tag) theme=\"\(index)\"/>"
                : "<\(tag) theme=\"\(index)\" tint=\"\(XLSXEscape.number(tint))\"/>"
        }
    }

    // MARK: - Container surgery

    /// Appends `content` inside `container`, bumping its `count` attribute by `count`.
    ///
    /// Creates the container when it is absent — a file with no `<numFmts>` gets one the first
    /// time a custom format is added.
    private static func append(
        _ content: String,
        count: Int,
        to container: String,
        in children: inout [XMLElementSlice]
    ) {
        guard !content.isEmpty, count > 0 else { return }
        guard let index = children.firstIndex(where: { $0.localName == container }) else {
            children.append(XMLElementSlice(
                localName: container,
                qualifiedName: container,
                text: "<\(container) count=\"\(count)\">\(content)</\(container)>"
            ))
            return
        }
        let element = children[index]
        let openTag = PackagePartPatcher.openTag(of: element.text)
        let existing = XMLAttributeScanner.value(of: "count", inTag: openTag).flatMap { Int($0) } ?? 0
        let patchedOpen = XLSXAttributePatch.set("count", to: "\(existing + count)", in: openTag)

        let text: String
        if element.text.hasSuffix("/>") {
            text = String(patchedOpen.dropLast(2)) + ">" + content + "</\(element.qualifiedName)>"
        } else {
            let body = element.text.dropFirst(openTag.count).dropLast(element.qualifiedName.count + 3)
            text = patchedOpen + body + content + "</\(element.qualifiedName)>"
        }
        children[index] = XMLElementSlice(localName: container, qualifiedName: element.qualifiedName, text: text)
    }

    private static func childCount(of container: String, in children: [XMLElementSlice], element: String) -> Int {
        guard let text = children.first(where: { $0.localName == container })?.text else { return 0 }
        guard let scanned = try? WorksheetPartScanner.scan(text, part: OOXMLPart.styles) else { return 0 }
        return scanned.children.count { $0.localName == element }
    }

    private static func numberFormatIDs(in numFmts: String) -> [Int32] {
        guard let scanned = try? WorksheetPartScanner.scan(numFmts, part: OOXMLPart.styles) else { return [] }
        return scanned.children.compactMap { child in
            XMLAttributeScanner.value(of: "numFmtId", inTag: PackagePartPatcher.openTag(of: child.text))
                .flatMap { Int32($0) }
        }
    }
}
