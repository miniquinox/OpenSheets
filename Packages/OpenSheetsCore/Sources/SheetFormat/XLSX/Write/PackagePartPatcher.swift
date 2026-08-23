//
//  PackagePartPatcher.swift
//  SheetFormat
//
//  Minimal surgery on `[Content_Types].xml`, the relationship parts, and `xl/workbook.xml`.
//

import Foundation
import SheetModel

/// Edits to the package-level parts, done by removing or rewriting exactly one element.
///
/// These parts are small, but they are also the parts every other part is reached through, and
/// regenerating one from a model is how a save loses a relationship nobody knew was there — the
/// `customXml` part, the `people.xml` a co-authoring session left behind, a producer's private
/// extension. So nothing here regenerates: it scans, drops or rewrites the one element it came
/// for, and re-emits every other byte as it found it.
public enum PackagePartPatcher {
    /// `[Content_Types].xml` with the `Override` for `partPath` removed.
    ///
    /// Needed because dropping `xl/calcChain.xml` leaves an override pointing at a part that is
    /// no longer in the package, which is invalid OPC.
    public static func contentTypes(_ xml: String, removingOverrideFor partPath: String) throws(SheetError) -> String? {
        let target = partPath.hasPrefix("/") ? partPath : "/" + partPath
        let scanned = try WorksheetPartScanner.scan(xml, part: OOXMLPart.contentTypes)
        var kept: [XMLElementSlice] = []
        var removed = false
        for child in scanned.children {
            if child.localName == "Override",
               XMLAttributeScanner.value(of: "PartName", inTag: openTag(of: child.text)) == target {
                removed = true
                continue
            }
            kept.append(child)
        }
        guard removed else { return nil }
        return reassemble(scanned, children: kept)
    }

    /// A relationships part with every relationship whose target resolves to `partPath` removed.
    ///
    /// Targets are relative to the part's own folder — `xl/_rels/workbook.xml.rels` says
    /// `calcChain.xml`, not `xl/calcChain.xml` — so the comparison is on the last path component
    /// after normalising away any `./` or leading slash.
    public static func relationships(_ xml: String, removingTargetsFor partPath: String) throws(SheetError) -> String? {
        let wanted = partPath.split(separator: "/").last.map(String.init) ?? partPath
        let scanned = try WorksheetPartScanner.scan(xml, part: OOXMLPart.workbookRelationships)
        var kept: [XMLElementSlice] = []
        var removed = false
        for child in scanned.children {
            if child.localName == "Relationship",
               let target = XMLAttributeScanner.value(of: "Target", inTag: openTag(of: child.text)),
               target.split(separator: "/").last.map(String.init) == wanted,
               XMLAttributeScanner.value(of: "TargetMode", inTag: openTag(of: child.text)) != "External" {
                removed = true
                continue
            }
            kept.append(child)
        }
        guard removed else { return nil }
        return reassemble(scanned, children: kept)
    }

    // MARK: - Assembly

    private static func reassemble(_ scanned: ScannedXMLPart, children: [XMLElementSlice]) -> String {
        var output = scanned.prolog + scanned.rootOpenTag
        for child in children { output += child.text }
        output += "</\(scanned.rootQualifiedName)>"
        return output
    }

    /// The open tag of an element slice, so its attributes can be read.
    static func openTag(of element: String) -> String {
        guard let end = element.firstIndex(of: ">") else { return element }
        return String(element[element.startIndex ... end])
    }
}

/// Surgery on `xl/workbook.xml`.
public enum WorkbookPartPatcher {
    /// `CT_Workbook`'s children in the order the schema requires.
    ///
    /// Only needed to place a `<calcPr>` that was not there before; existing children keep the
    /// order the producer wrote them in.
    static let childOrder: [String] = [
        "fileVersion", "fileSharing", "workbookPr", "workbookProtection", "bookViews", "sheets",
        "functionGroups", "externalReferences", "definedNames", "calcPr", "oleSize",
        "customWorkbookViews", "pivotCaches", "smartTagPr", "smartTagTypes", "webPublishing",
        "fileRecoveryPr", "webPublishObjects", "extLst",
    ]

    /// The result of a patch: the new text, or `nil` when nothing needed changing.
    public static func patched(
        _ xml: String,
        workbook: Workbook,
        fullCalculationOnLoad: Bool
    ) throws(SheetError) -> String? {
        let scanned = try WorksheetPartScanner.scan(xml, part: OOXMLPart.workbook)
        var children = scanned.children
        var changed = false

        // --- sheet names and visibility ------------------------------------------------------
        if let index = children.firstIndex(where: { $0.localName == "sheets" }) {
            let (rewritten, didChange) = try patchedSheets(children[index], workbook: workbook)
            if didChange {
                children[index] = rewritten
                changed = true
            }
        }

        // --- calcPr --------------------------------------------------------------------------
        if fullCalculationOnLoad {
            if let index = children.firstIndex(where: { $0.localName == "calcPr" }) {
                let tag = children[index].text
                let patched = XLSXAttributePatch.set("fullCalcOnLoad", to: "1", in: PackagePartPatcher.openTag(of: tag))
                let suffix = tag.hasSuffix("/>") ? "" : String(tag.dropFirst(PackagePartPatcher.openTag(of: tag).count))
                let replacement = patched + suffix
                if replacement != tag {
                    children[index] = XMLElementSlice(
                        localName: "calcPr",
                        qualifiedName: children[index].qualifiedName,
                        text: replacement
                    )
                    changed = true
                }
            } else {
                let element = XMLElementSlice(
                    localName: "calcPr", qualifiedName: "calcPr", text: "<calcPr fullCalcOnLoad=\"1\"/>"
                )
                children.insert(element, at: insertionIndex(for: "calcPr", among: children))
                changed = true
            }
        }

        guard changed else { return nil }
        var output = scanned.prolog + scanned.rootOpenTag
        for child in children { output += child.text }
        output += "</\(scanned.rootQualifiedName)>"
        return output
    }

    /// Rewrites `<sheets>` so each `<sheet>`'s `name` and `state` match the model.
    ///
    /// Sheets are matched by `sheetId`, which is what ``SheetID`` wraps and what Excel keeps
    /// stable across renames and reorders. **Adding or removing one is refused**, not attempted:
    /// that means a new part, a new content-type override and a new relationship, all agreeing
    /// with each other, and a half-finished job produces a file Excel calls damaged.
    private static func patchedSheets(
        _ element: XMLElementSlice,
        workbook: Workbook
    ) throws(SheetError) -> (XMLElementSlice, Bool) {
        let scanned = try WorksheetPartScanner.scan(element.text, part: OOXMLPart.workbook)
        var rewritten: [String] = []
        var changed = false

        for child in scanned.children where child.localName == "sheet" {
            let tag = PackagePartPatcher.openTag(of: child.text)
            guard let rawID = XMLAttributeScanner.value(of: "sheetId", inTag: tag), let identifier = Int32(rawID),
                  let sheet = workbook[SheetID(identifier)]
            else {
                rewritten.append(child.text)
                continue
            }
            var patched = tag
            if XMLAttributeScanner.value(of: "name", inTag: tag) != sheet.name {
                try Limits.validateSheetName(sheet.name)
                patched = XLSXAttributePatch.set("name", to: sheet.name, in: patched)
            }
            let state = XMLAttributeScanner.value(of: "state", inTag: patched)
            switch sheet.visibility {
            case .visible where state != nil:
                patched = XLSXAttributePatch.remove("state", from: patched)
            case .hidden where state != "hidden":
                patched = XLSXAttributePatch.set("state", to: "hidden", in: patched)
            case .veryHidden where state != "veryHidden":
                patched = XLSXAttributePatch.set("state", to: "veryHidden", in: patched)
            default:
                break
            }
            if patched != tag { changed = true }
            rewritten.append(patched + child.text.dropFirst(tag.count))
        }

        guard changed else { return (element, false) }
        var output = scanned.rootOpenTag
        for text in rewritten { output += text }
        output += "</\(scanned.rootQualifiedName)>"
        return (XMLElementSlice(localName: "sheets", qualifiedName: scanned.rootQualifiedName, text: output), true)
    }

    private static func insertionIndex(for name: String, among children: [XMLElementSlice]) -> Int {
        let ordinal = childOrder.firstIndex(of: name) ?? childOrder.count - 1
        for (index, child) in children.enumerated() {
            let other = childOrder.firstIndex(of: child.localName) ?? childOrder.count - 1
            if other > ordinal { return index }
        }
        return children.count
    }
}
