//
//  XLSXReader.swift
//  SheetFormat
//
//  A1 owns this file. The front door: a `.xlsx` on disk becomes a `SheetModel.Workbook`.
//

import Foundation
import os

import MiniZip
import SheetModel

/// Where the time went, and how much was inflated to get there.
///
/// Returned alongside the workbook by ``XLSXReader/readWithDiagnostics(contentsOf:)`` and mirrored
/// into `os_signpost` intervals under the `xlsx-read` category, so the same numbers show up in
/// Instruments without a second measurement path that can disagree with this one.
public struct XLSXReadDiagnostics: Sendable {
    /// One sheet's contribution.
    public struct SheetTiming: Sendable {
        public var name: String
        public var part: String
        public var duration: Duration
        public var cellCount: Int
        public var inflatedBytes: Int
    }

    /// Reading the file and walking the central directory. No entry is inflated here.
    public var archiveOpen: Duration = .zero
    /// `[Content_Types].xml` and the relationship graph.
    public var partGraph: Duration = .zero
    /// `xl/workbook.xml`.
    public var workbookPart: Duration = .zero
    /// `xl/sharedStrings.xml`.
    public var sharedStrings: Duration = .zero
    /// `xl/styles.xml` and `xl/theme/theme1.xml`.
    public var styles: Duration = .zero
    /// Wall-clock across all sheets. Less than their sum when they run concurrently, which is
    /// the point.
    public var sheetsWallClock: Duration = .zero
    /// Per sheet, in workbook order.
    public var sheets: [SheetTiming] = []
    /// End to end.
    public var total: Duration = .zero

    /// Entries in the archive, including every one that was never inflated.
    public var archiveEntryCount = 0
    /// Bytes actually inflated. On `Fixtures/hostile/zip-bomb-nested.xlsx` this excludes the
    /// bomb entirely, which is the whole point of the file.
    public var inflatedBytes = 0
    /// Populated cells across every sheet.
    public var cellCount = 0

    /// The sum of the per-sheet durations, for comparing against ``sheetsWallClock`` to see how
    /// much parallelism was actually achieved.
    public var sheetsSerialTotal: Duration {
        sheets.reduce(Duration.zero) { $0 + $1.duration }
    }
}

/// Reads `.xlsx`, `.xlsm` and `.xltx` into a ``SheetModel/Workbook``.
///
/// # What it parses, and what it merely keeps
///
/// Modelled: `[Content_Types].xml`, the relationship graph, `xl/workbook.xml`, the worksheets,
/// `xl/sharedStrings.xml`, `xl/styles.xml`, `xl/theme/theme1.xml`, `docProps/*`. Everything else —
/// charts, drawings, pivot caches, images, `vbaProject.bin`, custom XML — is kept as compressed
/// bytes in ``SheetModel/Workbook/passthrough`` and **never inflated**, which is both faster and
/// the reason `Fixtures/hostile/zip-bomb-nested.xlsx` opens instead of exploding.
///
/// Inside the worksheets, every `CT_Worksheet` child that is not modelled is captured verbatim
/// into ``SheetModel/Sheet/sheetLevelFragments``. See ``WorksheetReader``.
public enum XLSXReader {
    static let signposter = OSSignposter(subsystem: "com.opensheets.SheetFormat", category: "xlsx-read")

    /// The magic bytes of an OLE2/CFB container, which is what a password-protected workbook is.
    private static let compoundFileMagic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    // MARK: - Entry points

    /// Reads the workbook at `url`.
    public static func read(contentsOf url: URL) async throws(SheetError) -> Workbook {
        try await readWithDiagnostics(contentsOf: url).workbook
    }

    /// Reads the workbook at `url`, reporting where the time went.
    ///
    /// Pass a `budget` to observe — or tighten — how much this read is allowed to inflate. The
    /// default is a fresh ``MiniZip/DecompressionBudget`` at
    /// ``SheetModel/Limits/maxDecompressedBytes``; a caller that wants to *prove* an entry was
    /// never touched can supply its own and read ``MiniZip/DecompressionBudget/used`` afterwards.
    public static func readWithDiagnostics(
        contentsOf url: URL,
        budget: DecompressionBudget? = nil
    ) async throws(SheetError) -> (workbook: Workbook, diagnostics: XLSXReadDiagnostics) {
        let path = url.path(percentEncoded: false)
        let data = try load(url)
        return try await read(
            data, name: path, extension: url.pathExtension.lowercased(), budget: budget
        )
    }

    /// Reads a workbook already in memory. `name` appears in error messages.
    public static func read(
        _ data: Data,
        name: String,
        extension fileExtension: String = "xlsx",
        budget: DecompressionBudget? = nil
    ) async throws(SheetError) -> (workbook: Workbook, diagnostics: XLSXReadDiagnostics) {
        let clock = ContinuousClock()
        let started = clock.now
        var diagnostics = XLSXReadDiagnostics()

        try rejectCompoundFile(data)

        let openState = signposter.beginInterval("zip.open")
        let archive = try ZipReader.read(data, name: name, budget: budget)
        signposter.endInterval("zip.open", openState)
        diagnostics.archiveOpen = clock.now - started
        diagnostics.archiveEntryCount = archive.entries.count

        let graphStarted = clock.now
        let graphState = signposter.beginInterval("part.graph")
        let contentTypes = try OPCPackage.readContentTypes(archive)
        let rootRelationships = try OPCPackage.readRelationships(
            for: OPCPackage.rootRelationshipsPath, in: archive
        )
        let workbookPath = try locateWorkbookPart(rootRelationships, in: archive)
        let workbookRelationships = try OPCPackage.readRelationships(for: workbookPath, in: archive)
        signposter.endInterval("part.graph", graphState)
        diagnostics.partGraph = clock.now - graphStarted

        let format = try sourceFormat(
            of: workbookPath, contentTypes: contentTypes, fileExtension: fileExtension
        )
        let readOnlyReason = unwritableReason(for: workbookPath, contentTypes: contentTypes)

        let workbookStarted = clock.now
        let workbookState = signposter.beginInterval("workbook.xml")
        let workbookPart = try WorkbookPartReader.read(
            try archive.bytes(of: workbookPath), part: workbookPath
        )
        signposter.endInterval("workbook.xml", workbookState)
        diagnostics.workbookPart = clock.now - workbookStarted

        let stringsStarted = clock.now
        let stringsState = signposter.beginInterval("sharedStrings.xml")
        let sharedStringsPath = workbookRelationships.first(kind: "sharedStrings").flatMap {
            workbookRelationships.resolve($0)
        }
        var sharedStrings = SharedStrings.empty
        if let sharedStringsPath, let bytes = try archive.bytesIfPresent(of: sharedStringsPath) {
            sharedStrings = try SharedStringsReader.read(bytes, part: sharedStringsPath)
        }
        signposter.endInterval("sharedStrings.xml", stringsState)
        diagnostics.sharedStrings = clock.now - stringsStarted

        let stylesStarted = clock.now
        let stylesState = signposter.beginInterval("styles.xml")
        let stylesPath = workbookRelationships.first(kind: "styles").flatMap { workbookRelationships.resolve($0) }
        let themePath = workbookRelationships.first(kind: "theme").flatMap { workbookRelationships.resolve($0) }
        var palette = ColorPalette.office
        if let themePath, let bytes = try archive.bytesIfPresent(of: themePath) {
            palette = try ThemeReader.read(bytes, part: themePath)
        }
        var styles = StyleTable.empty
        if let stylesPath, let bytes = try archive.bytesIfPresent(of: stylesPath) {
            styles = try StylesReader.read(bytes, part: stylesPath, palette: palette)
        }
        signposter.endInterval("styles.xml", stylesState)
        diagnostics.styles = clock.now - stylesStarted

        let plans = try sheetPlans(workbookPart.sheets, relationships: workbookRelationships, in: archive)

        let sheetsStarted = clock.now
        let parsed = try await parseSheets(
            plans,
            archive: archive,
            sharedStrings: sharedStrings,
            styles: styles,
            dateSystem: workbookPart.dateSystem
        )
        diagnostics.sheetsWallClock = clock.now - sheetsStarted
        diagnostics.sheets = parsed.map(\.timing)

        var workbook = Workbook(
            sheets: parsed.map(\.sheet),
            styles: styles,
            meta: try metadata(
                archive: archive,
                rootRelationships: rootRelationships,
                workbookPart: workbookPart,
                format: format,
                readOnlyReason: readOnlyReason
            ),
            passthrough: archive.opaqueParts(
                modelled: modelledPaths(
                    workbookPath: workbookPath,
                    // A string table holding formatting runs is **not** modelled. The runs are
                    // flattened to plain text on the way in, so regenerating the part would
                    // silently destroy bold-inside-a-cell. The writer stores an edited string
                    // inline instead — see ``SheetModel/CellFlags/richText`` and A1's notes to A2.
                    sharedStringsPath: sharedStrings.isRichText.contains(true) ? nil : sharedStringsPath,
                    stylesPath: stylesPath,
                    sheetPaths: plans.map(\.path),
                    in: archive
                )
            )
        )
        for definedName in workbookPart.definedNames {
            // Inserted directly rather than through `setDefinedName`, which validates: `_xlnm.`
            // built-ins and the occasional producer oddity are real, and dropping one silently
            // would lose a print area on the next save.
            workbook.definedNames[definedName.storageKey] = definedName
        }

        diagnostics.cellCount = workbook.cellCount
        diagnostics.inflatedBytes = archive.budget.used
        diagnostics.total = clock.now - started
        return (workbook, diagnostics)
    }

    // MARK: - Sheets

    private struct SheetPlan: Sendable {
        var entry: WorkbookSheetEntry
        var path: String
    }

    private struct ParsedSheet: Sendable {
        var index: Int
        var sheet: Sheet
        var timing: XLSXReadDiagnostics.SheetTiming
    }

    private static func sheetPlans(
        _ entries: [WorkbookSheetEntry],
        relationships: OPCRelationships,
        in archive: ZipArchive
    ) throws(SheetError) -> [SheetPlan] {
        var plans: [SheetPlan] = []
        for entry in entries {
            guard let relationshipID = entry.relationshipID,
                  let relationship = relationships[relationshipID],
                  let path = relationships.resolve(relationship)
            else {
                throw SheetError.criticalPartMissing(
                    path: "the worksheet part for '\(entry.name)' (r:id \(entry.relationshipID ?? "missing"))"
                )
            }
            guard archive.contains(path) else {
                throw SheetError.criticalPartMissing(path: path)
            }
            plans.append(SheetPlan(entry: entry, path: path))
        }
        return plans
    }

    /// Parses every sheet concurrently, one task each.
    ///
    /// The parts are independent — a sheet needs only the shared strings, the styles and its own
    /// relationships, all of which are immutable `Sendable` values by this point — so this is the
    /// one place in the read path where parallelism is free. A 1M-cell workbook spread over eight
    /// sheets finishes in roughly the time of its largest sheet.
    private static func parseSheets(
        _ plans: [SheetPlan],
        archive: ZipArchive,
        sharedStrings: SharedStrings,
        styles: StyleTable,
        dateSystem: DateSystem
    ) async throws(SheetError) -> [ParsedSheet] {
        guard !plans.isEmpty else { return [] }

        do {
            var results = try await withThrowingTaskGroup(of: ParsedSheet.self) { group in
                for (index, plan) in plans.enumerated() {
                    group.addTask {
                        let clock = ContinuousClock()
                        let started = clock.now
                        let state = signposter.beginInterval("sheet", id: signposter.makeSignpostID())
                        let relationships = try OPCPackage.readRelationships(for: plan.path, in: archive)
                        let bytes = try archive.bytes(of: plan.path)
                        let sheet = try WorksheetReader.read(
                            bytes,
                            part: plan.path,
                            entry: plan.entry,
                            context: WorksheetReader.Context(
                                sharedStrings: sharedStrings,
                                styles: styles,
                                dateSystem: dateSystem,
                                relationships: relationships
                            )
                        )
                        signposter.endInterval("sheet", state)
                        return ParsedSheet(
                            index: index,
                            sheet: sheet,
                            timing: XLSXReadDiagnostics.SheetTiming(
                                name: plan.entry.name,
                                part: plan.path,
                                duration: clock.now - started,
                                cellCount: sheet.cells.count,
                                inflatedBytes: bytes.count
                            )
                        )
                    }
                }
                var collected: [ParsedSheet] = []
                collected.reserveCapacity(plans.count)
                for try await result in group { collected.append(result) }
                return collected
            }
            results.sort { $0.index < $1.index }
            return results
        } catch let error as SheetError {
            throw error
        } catch {
            throw SheetError.internalInconsistency(detail: "\(error)")
        }
    }

    // MARK: - The part graph

    private static func locateWorkbookPart(
        _ rootRelationships: OPCRelationships,
        in archive: ZipArchive
    ) throws(SheetError) -> String {
        guard let relationship = rootRelationships.first(kind: "officeDocument"),
              let path = rootRelationships.resolve(relationship)
        else {
            throw SheetError.criticalPartMissing(path: "the officeDocument relationship in _rels/.rels")
        }
        guard archive.contains(path) else {
            // The rels target dangles. Naming the *target* is what makes this a diagnosis rather
            // than an index-out-of-range somewhere further in.
            throw SheetError.criticalPartMissing(path: path)
        }
        return path
    }

    private static func sourceFormat(
        of workbookPath: String,
        contentTypes: OPCPackage.ContentTypes,
        fileExtension: String
    ) throws(SheetError) -> WorkbookFormat {
        let type = contentTypes.type(of: workbookPath) ?? ""
        if type.contains("spreadsheetml.sheet.binary") || fileExtension == "xlsb" {
            // A binary workbook part is not XML at all. Reading "what we can" out of one and
            // letting a save near it is how a file gets destroyed.
            throw SheetError.unsupportedFileFormat(
                detail: ".xlsb stores its workbook in a binary part that OpenSheets does not read"
            )
        }
        if type.contains("template") { return .xltx }
        if type.contains("macroEnabled") || fileExtension == "xlsm" { return .xlsm }
        return .xlsx
    }

    /// Why this workbook cannot be written back, if it cannot.
    ///
    /// PLAN.md §5.2's rule: refusing to save is always better than corrupting. The encrypted and
    /// `.xlsb` cases throw outright — there is nothing to show — so the one that lands here is the
    /// third: a main document part whose content type is not a SpreadsheetML one at all. We can
    /// still read whatever XML is in it and show the user something, but regenerating the package
    /// around a part we do not recognise is how a file gets destroyed.
    ///
    /// Deliberately conservative. An *absent* content type is common in hand-rolled files and does
    /// not lock the workbook, and any type mentioning SpreadsheetML or Excel is accepted, because
    /// a false positive here means a file that opens and cannot be saved — which is worse than
    /// the risk it guards against for anything short of a genuinely foreign format.
    private static func unwritableReason(
        for workbookPath: String,
        contentTypes: OPCPackage.ContentTypes
    ) -> ReadOnlyReason? {
        guard let type = contentTypes.type(of: workbookPath), !type.isEmpty else { return nil }
        let lowered = type.lowercased()
        if lowered.contains("spreadsheetml") || lowered.contains("ms-excel") { return nil }
        return .unknownCriticalPart
    }

    /// Paths whose content the model represents and the writer may therefore regenerate.
    ///
    /// Everything else is untouchable. `xl/calcChain.xml` is in the set because it must be
    /// *deleted* on any formula change — Excel rebuilds it, and a stale one is real corruption
    /// (PLAN.md §5.2). Note what is deliberately absent: `[Content_Types].xml`, every `.rels`
    /// part, `docProps/*`, and `xl/theme/theme1.xml`. We read them; we do not claim we can
    /// rewrite them losslessly.
    private static func modelledPaths(
        workbookPath: String,
        sharedStringsPath: String?,
        stylesPath: String?,
        sheetPaths: [String],
        in archive: ZipArchive
    ) -> Set<String> {
        var modelled: Set<String> = [workbookPath]
        if let sharedStringsPath { modelled.insert(sharedStringsPath) }
        if let stylesPath { modelled.insert(stylesPath) }
        modelled.formUnion(sheetPaths)
        for entry in archive.entries where OPCPackage.fileName(of: entry.path) == "calcChain.xml" {
            modelled.insert(entry.path)
        }
        return modelled
    }

    // MARK: - Metadata

    private static func metadata(
        archive: ZipArchive,
        rootRelationships: OPCRelationships,
        workbookPart: WorkbookPart,
        format: WorkbookFormat,
        readOnlyReason: ReadOnlyReason?
    ) throws(SheetError) -> WorkbookMeta {
        var meta = WorkbookMeta(
            calculationMode: workbookPart.calculationMode,
            fullCalculationOnLoad: workbookPart.fullCalculationOnLoad,
            // Either mark is enough: a `calcChain` is the *result* of a calculation and a
            // `calcPr` is the record that an application which calculates wrote the file. A
            // package with neither has never been evaluated by anything.
            hasCalculationEvidence: workbookPart.hasCalculationProperties
                || archive.entries.contains {
                    OPCPackage.fileName(of: $0.path).lowercased() == "calcchain.xml"
                },
            dateSystem: workbookPart.dateSystem,
            sourceFormat: format,
            readOnlyReason: readOnlyReason
        )
        meta.containsMacros = archive.entries.contains {
            OPCPackage.fileName(of: $0.path).lowercased() == "vbaproject.bin"
        }
        if let relationship = rootRelationships.first(kind: "extended-properties"),
           let path = rootRelationships.resolve(relationship),
           let bytes = try archive.bytesIfPresent(of: path) {
            let app = try DocumentProperties.readApplication(bytes, part: path)
            meta.application = app.application
            meta.applicationVersion = app.version
        }
        if let relationship = rootRelationships.first(kind: "core-properties"),
           let path = rootRelationships.resolve(relationship),
           let bytes = try archive.bytesIfPresent(of: path) {
            let core = try DocumentProperties.readCore(bytes, part: path)
            meta.creator = core.creator
            meta.lastModifiedBy = core.lastModifiedBy
            meta.title = core.title
            meta.created = core.created
            meta.modified = core.modified
        }
        return meta
    }

    // MARK: - Loading and sniffing

    private static func load(_ url: URL) throws(SheetError) -> Data {
        let path = url.path(percentEncoded: false)
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= Limits.maxFileBytes else {
                throw SheetError.fileTooLarge(path: path, bytes: data.count, limit: Limits.maxFileBytes)
            }
            return data
        } catch let error as SheetError {
            throw error
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw SheetError.fileNotFound(path: path)
        } catch {
            throw SheetError.fileNotReadable(path: path, underlying: error.localizedDescription)
        }
    }

    /// Refuses an OLE2/CFB container before the ZIP reader ever sees it.
    ///
    /// A password-protected workbook is not a damaged ZIP, it is a different container format
    /// holding an `EncryptedPackage` stream — and the difference matters to the person looking at
    /// the error, who can do something about "password protected" and nothing about "corrupt".
    private static func rejectCompoundFile(_ data: Data) throws(SheetError) {
        guard data.count >= compoundFileMagic.count else { return }
        let base = data.startIndex
        for (offset, byte) in compoundFileMagic.enumerated() where data[base + offset] != byte {
            return
        }
        // CFB directory entry names are UTF-16LE, so the ASCII spelling never appears.
        let marker = Array("EncryptedPackage".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        if contains(data, marker) {
            throw SheetError.workbookEncrypted
        }
        throw SheetError.unsupportedFileFormat(
            detail: "this is an OLE2 compound file — a legacy .xls, or an encrypted workbook"
        )
    }

    private static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { raw -> Bool in
            let limit = raw.count - needle.count
            var index = 0
            while index <= limit {
                if raw[index] == needle[0] {
                    var step = 1
                    while step < needle.count, raw[index + step] == needle[step] { step += 1 }
                    if step == needle.count { return true }
                }
                index += 1
            }
            return false
        }
    }
}

/// `docProps/core.xml` and `docProps/app.xml`.
///
/// Round-trip only. Writing our own name into `lastModifiedBy` would be a surprising edit to
/// someone else's document metadata, so the reader records and the writer replaces, and neither
/// invents.
enum DocumentProperties {
    struct Core {
        var creator: String?
        var lastModifiedBy: String?
        var title: String?
        var created: Date?
        var modified: Date?
    }

    static func readApplication(
        _ bytes: [UInt8], part: String
    ) throws(SheetError) -> (application: String?, version: String?) {
        let fields = try readTextFields(bytes, part: part, names: ["Application", "AppVersion"])
        return (fields["Application"], fields["AppVersion"])
    }

    static func readCore(_ bytes: [UInt8], part: String) throws(SheetError) -> Core {
        let fields = try readTextFields(
            bytes, part: part, names: ["creator", "lastModifiedBy", "title", "created", "modified"]
        )
        return Core(
            creator: fields["creator"],
            lastModifiedBy: fields["lastModifiedBy"],
            title: fields["title"],
            created: fields["created"].flatMap(timestamp),
            modified: fields["modified"].flatMap(timestamp)
        )
    }

    /// Collects the text of the named leaf elements. Matching is on the local name, so
    /// `<dc:creator>` and `<creator>` are the same field.
    private static func readTextFields(
        _ bytes: [UInt8], part: String, names: Set<String>
    ) throws(SheetError) -> [String: String] {
        try XMLParsing.withParser(over: bytes, part: part) { parser throws(SheetError) in
            var fields: [String: String] = [:]
            var current: String?
            while let event = try parser.next() {
                switch event {
                case .startElement:
                    let name = parser.name
                    current = names.contains(name) ? name : nil
                case .characters:
                    if let current { fields[current, default: ""] += try parser.text.string() }
                case .endElement:
                    current = nil
                }
            }
            return fields
        }
    }

    /// The `W3CDTF` timestamps OPC uses, with and without fractional seconds.
    private static func timestamp(_ text: String) -> Date? {
        if let value = try? Date(text, strategy: .iso8601) { return value }
        // `2024-01-02T03:04:05.123Z` — drop the fraction and try the plain form.
        guard let dot = text.firstIndex(of: "."), let zone = text.lastIndex(where: { $0 == "Z" || $0 == "+" })
        else { return nil }
        guard dot < zone else { return nil }
        return try? Date(text.replacingCharacters(in: dot ..< zone, with: ""), strategy: .iso8601)
    }
}
