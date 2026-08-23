//
//  WorkbookPartReader.swift
//  SheetFormat
//
//  A1 owns this file. `xl/workbook.xml`: the sheet list, the defined names, and the date epoch.
//

import Foundation

import SheetModel

/// One `<sheet>` entry from `xl/workbook.xml`, before its part has been located or parsed.
public struct WorkbookSheetEntry: Sendable, Hashable {
    public var name: String
    public var id: SheetID
    public var relationshipID: String?
    public var visibility: SheetVisibility

    public init(
        name: String,
        id: SheetID,
        relationshipID: String? = nil,
        visibility: SheetVisibility = .visible
    ) {
        self.name = name
        self.id = id
        self.relationshipID = relationshipID
        self.visibility = visibility
    }
}

/// Everything `xl/workbook.xml` says.
public struct WorkbookPart: Sendable {
    public var sheets: [WorkbookSheetEntry] = []
    public var definedNames: [DefinedName] = []

    /// **The epoch.** Reading a 1904 workbook as 1900 shifts every date by four years and a day,
    /// silently, which is why this is read before a single cell is.
    public var dateSystem: DateSystem = .excel1900

    public var calculationMode: CalculationMode = .automatic
    public var fullCalculationOnLoad = false

    /// Whether a `<calcPr>` element was present at all.
    ///
    /// Not the same question as ``calculationMode``, which has a default and therefore cannot tell
    /// "the file said automatic" from "the file said nothing". Excel and LibreOffice both write
    /// this element; openpyxl, pandas and xlsxwriter do not, and its absence — together with a
    /// missing `xl/calcChain.xml` — is the evidence that nothing ever evaluated the formulas whose
    /// cached values we are about to render. See ``SheetModel/WorkbookMeta/hasCalculationEvidence``.
    public var hasCalculationProperties = false

    /// Whether the workbook declares `<externalReferences>`. Recorded, never followed.
    public var hasExternalReferences = false
}

/// Parses `xl/workbook.xml`.
public enum WorkbookPartReader {
    public static func read(_ bytes: [UInt8], part: String) throws(SheetError) -> WorkbookPart {
        try XMLParsing.withParser(over: bytes, part: part) { parser throws(SheetError) in
            var result = WorkbookPart()
            // `localSheetId` indexes the *sheet list*, not a `sheetId`. Getting that wrong scopes
            // a name to the wrong tab, which only shows up when two sheets share a name.
            var pendingNames: [(name: String, localSheetIndex: Int?, hidden: Bool, formula: String)] = []

            while let event = try parser.next() {
                guard event == .startElement else { continue }

                if parser.nameIs("workbookPr") {
                    if let flag = parser.attribute("date1904"), flag.bool {
                        result.dateSystem = .excel1904
                    }
                } else if parser.nameIs("calcPr") {
                    result.hasCalculationProperties = true
                    if let mode = parser.attribute("calcMode") {
                        result.calculationMode = if mode.equals("manual") {
                            .manual
                        } else if mode.equals("autoNoTable") {
                            .automaticExceptTables
                        } else {
                            .automatic
                        }
                    }
                    result.fullCalculationOnLoad = parser.attribute("fullCalcOnLoad")?.bool ?? false
                } else if parser.nameIs("sheet") {
                    guard result.sheets.count < Limits.maxSheets else {
                        throw SheetError.workbookTooComplex(
                            detail: "a workbook may hold at most \(Limits.maxSheets) sheets"
                        )
                    }
                    let name = try parser.attribute("name")?.string() ?? ""
                    let sheetID = parser.attribute("sheetId")?.int32 ?? Int32(result.sheets.count + 1)
                    let state = parser.attribute("state")
                    let visibility: SheetVisibility = if state?.equals("veryHidden") == true {
                        .veryHidden
                    } else if state?.equals("hidden") == true {
                        .hidden
                    } else {
                        .visible
                    }
                    result.sheets.append(
                        WorkbookSheetEntry(
                            name: name,
                            id: SheetID(rawValue: sheetID),
                            relationshipID: try parser.attribute("id")?.string(),
                            visibility: visibility
                        )
                    )
                } else if parser.nameIs("externalReference") {
                    result.hasExternalReferences = true
                } else if parser.nameIs("definedName") {
                    guard pendingNames.count < Limits.maxDefinedNames else {
                        throw SheetError.workbookTooComplex(
                            detail: "a workbook may hold at most \(Limits.maxDefinedNames) names"
                        )
                    }
                    let name = try parser.attribute("name")?.string() ?? ""
                    let localSheetIndex = parser.attribute("localSheetId")?.int
                    let hidden = parser.attribute("hidden")?.bool ?? false
                    var formula = ""
                    // The definition is the element's text, which may arrive in several runs.
                    let target = parser.depth - 1
                    while let inner = try parser.next() {
                        if inner == .characters {
                            formula += try parser.text.string()
                        } else if inner == .endElement, parser.depth == target {
                            break
                        }
                    }
                    if !name.isEmpty {
                        pendingNames.append((name, localSheetIndex, hidden, formula))
                    }
                }
            }

            for pending in pendingNames {
                let scope = pending.localSheetIndex.flatMap { index in
                    result.sheets.indices.contains(index) ? result.sheets[index].id : nil
                }
                result.definedNames.append(
                    DefinedName(
                        name: pending.name,
                        scope: scope,
                        target: DefinedNameTarget.parse(pending.formula, sheets: result.sheets),
                        formula: pending.formula,
                        isHidden: pending.hidden
                    )
                )
            }
            return result
        }
    }
}

/// Turns a defined name's stored formula into a ``SheetModel/RangeReference`` when — and only
/// when — it is a plain range.
///
/// `=SUM(Sheet1!A:A)*2` is a legal definition and is not a range; pretending otherwise would put
/// a wrong rectangle in front of the user. Anything that is not a single unambiguous reference
/// keeps its text and leaves `target` `nil`.
enum DefinedNameTarget {
    static func parse(_ formula: String, sheets: [WorkbookSheetEntry]) -> RangeReference? {
        var text = formula
        if text.hasPrefix("=") { text.removeFirst() }
        guard !text.isEmpty, !text.contains("("), !text.contains(","), !text.contains(" ") else { return nil }

        var sheetName: String?
        var rangeText = Substring(text)
        if let bang = text.lastIndex(of: "!") {
            var name = String(text[text.startIndex ..< bang])
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            sheetName = name
            rangeText = text[text.index(after: bang)...]
        }

        let plain = rangeText.replacingOccurrences(of: "$", with: "")
        guard let range = CellRange(a1: plain) ?? wholeColumnOrRow(plain) else { return nil }

        let scope = sheetName.flatMap { name in
            sheets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        if sheetName != nil, scope == nil { return nil }
        return RangeReference(sheet: scope, range: range)
    }

    /// `A:A` and `1:5` — legal in a defined name and not something ``CellRange/init(a1:)``
    /// accepts, since they have no row (or no column) to parse.
    private static func wholeColumnOrRow(_ text: String) -> CellRange? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        if let first = CellRef.columnIndex(letters: parts[0]), let second = CellRef.columnIndex(letters: parts[1]) {
            return CellRange(rows: 0 ... Limits.maxRow, columns: min(first, second) ... max(first, second))
        }
        if let first = Int(parts[0]), let second = Int(parts[1]),
           first >= 1, second >= 1, first <= Limits.rowCount, second <= Limits.rowCount {
            let low = min(first, second) - 1
            let high = max(first, second) - 1
            return CellRange(rows: low ... high, columns: 0 ... Limits.maxColumn)
        }
        return nil
    }
}
