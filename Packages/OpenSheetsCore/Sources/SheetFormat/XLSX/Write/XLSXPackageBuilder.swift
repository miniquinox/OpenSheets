//
//  XLSXPackageBuilder.swift
//  SheetFormat
//
//  Building a whole `.xlsx` from nothing — `New Sheet`, and `Save As…` from a CSV.
//

import Foundation
import MiniZip
import SheetModel

/// Builds a complete OOXML package for a workbook that did not come from one.
///
/// This is the *other* path, and it is the one with no safety net: there are no original bytes
/// to fall back on, so everything is generated and everything the model does not carry is simply
/// not there. That is fine for its two callers — a brand-new workbook and a CSV being saved as
/// `.xlsx` have nothing to lose — and it is exactly why ``XLSXWriter`` never takes this path for
/// a file it read from disk, however dirty.
///
/// The package is deliberately minimal: no `docProps`, no theme, no `calcChain`. Every part it
/// writes is one Excel requires or one the workbook actually uses.
public enum XLSXPackageBuilder {
    /// The `.xlsx` bytes.
    public static func package(for workbook: Workbook, options: XLSXWriteOptions = .standard) throws(SheetError) -> Data {
        try workbook.validate()

        var strings = SharedStringTable.generating
        var sheetParts: [(path: String, relationshipID: String, xml: String)] = []

        for (index, sheet) in workbook.sheets.enumerated() {
            var prepared = sheet
            prepared.partPath = OOXMLPart.worksheet(index + 1)
            prepared.relationshipID = "rId\(index + 1)"
            let output = try WorksheetPartWriter.serialise(
                prepared,
                context: WorksheetPartWriter.Context(
                    originalXML: nil, strings: strings, regions: .all, options: options
                )
            )
            strings = output.strings
            sheetParts.append((prepared.partPath!, prepared.relationshipID!, output.xml))
        }

        let sheetCount = workbook.sheets.count
        let stylesRelationship = "rId\(sheetCount + 1)"
        let sharedStringsRelationship = "rId\(sheetCount + 2)"
        let usesSharedStrings = !strings.generatedStrings.isEmpty

        var entries: [ZipEntry] = []
        func add(_ path: String, _ xml: String) {
            entries.append(ZipWriter.entry(path: path, contents: Data(xml.utf8)))
        }

        add(OOXMLPart.contentTypes, contentTypes(
            sheetPaths: sheetParts.map(\.path),
            includesSharedStrings: usesSharedStrings
        ))
        add(OOXMLPart.rootRelationships, rootRelationships())
        add(OOXMLPart.workbook, workbookPart(workbook, sheetRelationships: sheetParts.map(\.relationshipID)))
        add(OOXMLPart.workbookRelationships, workbookRelationships(
            sheetParts: sheetParts,
            stylesRelationship: stylesRelationship,
            sharedStringsRelationship: usesSharedStrings ? sharedStringsRelationship : nil
        ))
        for part in sheetParts { add(part.path, part.xml) }
        if usesSharedStrings {
            add(OOXMLPart.sharedStrings, try SharedStringTable.newPart(
                strings: strings.generatedStrings, options: options
            ))
        }
        add(OOXMLPart.styles, StylePartWriter.newPart(workbook.styles))

        return try ZipWriter.archive(entries)
    }

    // MARK: - Parts

    private static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\r\n"
    private static let mainNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let documentType = "application/vnd.openxmlformats-officedocument.spreadsheetml"

    private static func contentTypes(sheetPaths: [String], includesSharedStrings: Bool) -> String {
        var output = declaration
        output += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        output += "<Default Extension=\"rels\" "
        output += "ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        output += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        output += "<Override PartName=\"/\(OOXMLPart.workbook)\" ContentType=\"\(documentType).sheet.main+xml\"/>"
        for path in sheetPaths {
            output += "<Override PartName=\"/\(path)\" ContentType=\"\(documentType).worksheet+xml\"/>"
        }
        output += "<Override PartName=\"/\(OOXMLPart.styles)\" ContentType=\"\(documentType).styles+xml\"/>"
        if includesSharedStrings {
            output += "<Override PartName=\"/\(OOXMLPart.sharedStrings)\" "
            output += "ContentType=\"\(documentType).sharedStrings+xml\"/>"
        }
        return output + "</Types>"
    }

    private static func rootRelationships() -> String {
        var output = declaration
        output += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        output += "<Relationship Id=\"rId1\" Type=\"\(relationshipNamespace)/officeDocument\" "
        output += "Target=\"\(OOXMLPart.workbook)\"/>"
        return output + "</Relationships>"
    }

    private static func workbookRelationships(
        sheetParts: [(path: String, relationshipID: String, xml: String)],
        stylesRelationship: String,
        sharedStringsRelationship: String?
    ) -> String {
        var output = declaration
        output += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for part in sheetParts {
            let target = part.path.hasPrefix("xl/") ? String(part.path.dropFirst(3)) : part.path
            output += "<Relationship Id=\"\(part.relationshipID)\" Type=\"\(relationshipNamespace)/worksheet\" "
            output += "Target=\"\(target)\"/>"
        }
        output += "<Relationship Id=\"\(stylesRelationship)\" Type=\"\(relationshipNamespace)/styles\" "
        output += "Target=\"styles.xml\"/>"
        if let sharedStringsRelationship {
            output += "<Relationship Id=\"\(sharedStringsRelationship)\" "
            output += "Type=\"\(relationshipNamespace)/sharedStrings\" Target=\"sharedStrings.xml\"/>"
        }
        return output + "</Relationships>"
    }

    private static func workbookPart(_ workbook: Workbook, sheetRelationships: [String]) -> String {
        var output = declaration
        output += "<workbook xmlns=\"\(mainNamespace)\" xmlns:r=\"\(relationshipNamespace)\">"
        if workbook.meta.dateSystem == .excel1904 {
            output += "<workbookPr date1904=\"1\"/>"
        }
        output += "<sheets>"
        for (index, sheet) in workbook.sheets.enumerated() {
            output += "<sheet name=\"\(XLSXEscape.attribute(sheet.name))\" sheetId=\"\(sheet.id.rawValue)\""
            switch sheet.visibility {
            case .visible: break
            case .hidden: output += " state=\"hidden\""
            case .veryHidden: output += " state=\"veryHidden\""
            }
            output += " r:id=\"\(sheetRelationships[index])\"/>"
        }
        output += "</sheets>"

        let names = workbook.definedNames.values.sorted { $0.storageKey < $1.storageKey }
        if !names.isEmpty {
            output += "<definedNames>"
            for name in names {
                output += "<definedName name=\"\(XLSXEscape.attribute(name.name))\""
                if let scope = name.scope, let index = workbook.index(of: scope) {
                    output += " localSheetId=\"\(index)\""
                }
                if name.isHidden { output += " hidden=\"1\"" }
                if let comment = name.comment {
                    output += " comment=\"\(XLSXEscape.attribute(comment))\""
                }
                output += ">\(XLSXEscape.text(name.formula))</definedName>"
            }
            output += "</definedNames>"
        }

        if workbook.meta.calculationMode != .automatic || workbook.meta.fullCalculationOnLoad {
            output += "<calcPr"
            switch workbook.meta.calculationMode {
            case .automatic: break
            case .automaticExceptTables: output += " calcMode=\"autoNoTable\""
            case .manual: output += " calcMode=\"manual\""
            }
            if workbook.meta.fullCalculationOnLoad { output += " fullCalcOnLoad=\"1\"" }
            output += "/>"
        }
        return output + "</workbook>"
    }
}
