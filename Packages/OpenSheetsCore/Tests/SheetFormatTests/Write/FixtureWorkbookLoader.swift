//
//  FixtureWorkbookLoader.swift
//  SheetFormatTests
//
//  Just enough xlsx parsing to feed the writer's tests. See `FixtureArchive.swift` for why this
//  exists alongside A1's real reader rather than instead of it.
//

import Foundation
import MiniZip
@testable import SheetFormat
import SheetModel

/// Loads a fixture into a `Workbook` with its `OpaqueParts` intact.
///
/// Models only what the writer needs to be exercised: sheet identity and part paths, cells,
/// merges, hyperlinks, the declared dimension, and — crucially — the unmodelled sheet-level
/// elements, captured verbatim the way A1's reader must capture them.
enum FixtureWorkbookLoader {
    struct Loaded {
        var workbook: Workbook
        var archive: FixtureArchive
    }

    static func load(_ relativePath: String) throws -> Loaded {
        try load(
            archive: try FixtureArchive(contentsOf: FixtureRoot.url(relativePath)),
            isMacroEnabled: relativePath.hasSuffix(".xlsm")
        )
    }

    static func load(data: Data, isMacroEnabled: Bool = false) throws -> Loaded {
        try load(archive: try FixtureArchive(data), isMacroEnabled: isMacroEnabled)
    }

    static func load(archive: FixtureArchive, isMacroEnabled: Bool = false) throws -> Loaded {
        var modelled: Set<String> = [
            OOXMLPart.workbook, OOXMLPart.sharedStrings, OOXMLPart.styles,
            OOXMLPart.contentTypes, OOXMLPart.workbookRelationships,
        ]

        // --- the string table --------------------------------------------------------------
        var strings: [String] = []
        if archive[OOXMLPart.sharedStrings] != nil {
            let scanned = try WorksheetPartScanner.scan(
                try archive.text(OOXMLPart.sharedStrings), part: OOXMLPart.sharedStrings
            )
            strings = scanned.children.filter { $0.localName == "si" }.map { SharedStringTable.flatten($0.text) }
        }

        // --- relationships -----------------------------------------------------------------
        var targets: [String: String] = [:]
        if archive[OOXMLPart.workbookRelationships] != nil {
            let scanned = try WorksheetPartScanner.scan(
                try archive.text(OOXMLPart.workbookRelationships), part: OOXMLPart.workbookRelationships
            )
            for child in scanned.children where child.localName == "Relationship" {
                let tag = PackagePartPatcher.openTag(of: child.text)
                guard let identifier = XMLAttributeScanner.value(of: "Id", inTag: tag),
                      let target = XMLAttributeScanner.value(of: "Target", inTag: tag) else { continue }
                targets[identifier] = target.hasPrefix("/")
                    ? String(target.dropFirst())
                    : "xl/" + (target.hasPrefix("./") ? String(target.dropFirst(2)) : target)
            }
        }

        // --- workbook.xml --------------------------------------------------------------------
        let workbookXML = try archive.text(OOXMLPart.workbook)
        let workbookPart = try WorksheetPartScanner.scan(workbookXML, part: OOXMLPart.workbook)
        var sheets: [Sheet] = []
        if let sheetsElement = workbookPart.child(named: "sheets") {
            let scanned = try WorksheetPartScanner.scan(sheetsElement.text, part: OOXMLPart.workbook)
            for child in scanned.children where child.localName == "sheet" {
                let tag = PackagePartPatcher.openTag(of: child.text)
                let name = XMLAttributeScanner.value(of: "name", inTag: tag) ?? "Sheet"
                let identifier = Int32(XMLAttributeScanner.value(of: "sheetId", inTag: tag) ?? "1") ?? 1
                let relationship = XMLAttributeScanner.value(of: "r:id", inTag: tag)
                    ?? XMLAttributeScanner.value(of: "id", inTag: tag)
                let path = relationship.flatMap { targets[$0] }
                var sheet = Sheet(id: SheetID(identifier), name: name)
                sheet.partPath = path
                sheet.relationshipID = relationship
                switch XMLAttributeScanner.value(of: "state", inTag: tag) {
                case "hidden": sheet.visibility = .hidden
                case "veryHidden": sheet.visibility = .veryHidden
                default: sheet.visibility = .visible
                }
                if let path {
                    try populate(&sheet, from: try archive.text(path), strings: strings)
                    modelled.insert(path)
                }
                sheets.append(sheet)
            }
        }

        var meta = WorkbookMeta()
        meta.sourceFormat = isMacroEnabled ? .xlsm : .xlsx
        meta.containsMacros = archive[OOXMLPart.vbaProject] != nil

        let workbook = Workbook(
            sheets: sheets,
            styles: .empty,
            meta: meta,
            passthrough: archive.opaqueParts(modelled: modelled)
        )
        return Loaded(workbook: workbook, archive: archive)
    }

    // MARK: - One sheet

    static func populate(_ sheet: inout Sheet, from xml: String, strings: [String]) throws {
        let scanned = try WorksheetPartScanner.scan(xml, part: sheet.partPath ?? sheet.name)

        for child in scanned.children {
            switch child.localName {
            case "dimension":
                let tag = PackagePartPatcher.openTag(of: child.text)
                sheet.declaredDimension = XMLAttributeScanner.value(of: "ref", inTag: tag)
                    .flatMap { CellRange(a1: $0) }
            case "mergeCells":
                let merges = try WorksheetPartScanner.scan(child.text, part: "mergeCells")
                sheet.merges = merges.children.compactMap {
                    XMLAttributeScanner.value(of: "ref", inTag: PackagePartPatcher.openTag(of: $0.text))
                        .flatMap { CellRange(a1: $0) }
                }
            case "autoFilter":
                let tag = PackagePartPatcher.openTag(of: child.text)
                sheet.autoFilter = XMLAttributeScanner.value(of: "ref", inTag: tag).flatMap { CellRange(a1: $0) }
            case "hyperlinks":
                let links = try WorksheetPartScanner.scan(child.text, part: "hyperlinks")
                for link in links.children where link.localName == "hyperlink" {
                    let tag = PackagePartPatcher.openTag(of: link.text)
                    guard let reference = XMLAttributeScanner.value(of: "ref", inTag: tag),
                          let ref = CellRef(a1: reference) else { continue }
                    let relationship = XMLAttributeScanner.value(of: "r:id", inTag: tag)
                    sheet.hyperlinks[ref] = Hyperlink(
                        target: XMLAttributeScanner.value(of: "location", inTag: tag) ?? "",
                        isExternal: relationship != nil,
                        location: XMLAttributeScanner.value(of: "location", inTag: tag),
                        tooltip: XMLAttributeScanner.value(of: "tooltip", inTag: tag),
                        relationshipID: relationship
                    )
                }
            case "sheetData":
                try populateCells(&sheet, from: child.text, strings: strings)
            default:
                if SheetFragment.capturedElements.contains(child.localName) {
                    sheet.sheetLevelFragments.append(
                        SheetFragment(elementName: child.localName, xml: child.text)
                    )
                }
            }
        }
    }

    private static func populateCells(_ sheet: inout Sheet, from sheetData: String, strings: [String]) throws {
        let scanned = try WorksheetPartScanner.scan(sheetData, part: "sheetData")
        for row in scanned.children where row.localName == "row" {
            let cells = try WorksheetPartScanner.scan(row.text, part: "row")
            for element in cells.children where element.localName == "c" {
                let tag = PackagePartPatcher.openTag(of: element.text)
                guard let reference = XMLAttributeScanner.value(of: "r", inTag: tag),
                      let ref = CellRef(a1: reference) else { continue }
                let type = XMLAttributeScanner.value(of: "t", inTag: tag) ?? "n"
                let style = XMLAttributeScanner.value(of: "s", inTag: tag).flatMap { Int32($0) } ?? 0

                var formula: String?
                var raw: String?
                var inline: String?
                var flags: CellFlags = []

                if !element.text.hasSuffix("/>") {
                    let parts = try WorksheetPartScanner.scan(element.text, part: "c")
                    for part in parts.children {
                        switch part.localName {
                        case "f":
                            // A shared-formula follower is `<f t="shared" si="0"/>` with no text:
                            // its formula lives on the master and the real reader expands it.
                            // This loader does not, so it records no formula rather than an empty
                            // one — `<f></f>` is not a thing.
                            let text = XMLAttributeScanner.unescape(innerText(of: part.text))
                            formula = text.isEmpty ? nil : text
                            let openTag = PackagePartPatcher.openTag(of: part.text)
                            if XMLAttributeScanner.value(of: "t", inTag: openTag) == "array",
                               let region = XMLAttributeScanner.value(of: "ref", inTag: openTag)
                               .flatMap({ CellRange(a1: $0) }) {
                                sheet.arrayFormulaRanges[ref] = region
                                flags.insert(.arrayFormula)
                            }
                        case "v":
                            raw = XMLAttributeScanner.unescape(innerText(of: part.text))
                        case "is":
                            let runs = try WorksheetPartScanner.scan(part.text, part: "is")
                            inline = runs.children
                                .filter { $0.localName == "t" }
                                .map { XMLAttributeScanner.unescape(innerText(of: $0.text)) }
                                .joined()
                            flags.insert(.inlineString)
                        default:
                            break
                        }
                    }
                }

                let value: CellValue
                switch type {
                case "s":
                    let index = raw.flatMap { Int($0) } ?? -1
                    value = strings.indices.contains(index) ? .text(strings[index]) : .empty
                case "inlineStr":
                    value = .text(inline ?? "")
                case "b":
                    value = .boolean(raw == "1")
                case "e":
                    value = raw.flatMap { CellError(rawValue: $0) }.map { CellValue.error($0) } ?? .empty
                case "str":
                    value = .text(raw ?? "")
                default:
                    value = raw.flatMap { Double($0) }.map { CellValue.number($0) } ?? .empty
                }

                let cell = Cell(value: value, formula: formula, styleID: StyleID(style), flags: flags)
                guard !cell.isBlank else { continue }
                try sheet.cells.setCell(cell, at: ref)
            }
        }
    }

    /// The text between an element's open and close tags.
    static func innerText(of element: String) -> String {
        guard !element.hasSuffix("/>"), let open = element.firstIndex(of: ">") else { return "" }
        let body = element[element.index(after: open)...]
        guard let close = body.range(of: "</", options: .backwards) else { return String(body) }
        return String(body[body.startIndex ..< close.lowerBound])
    }
}
