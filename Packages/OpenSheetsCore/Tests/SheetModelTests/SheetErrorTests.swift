import Foundation
@testable import SheetModel
import Testing

@Suite("SheetError")
struct SheetErrorTests {
    /// One of every case, so the exhaustiveness checks below are real.
    ///
    /// Adding a case to `SheetError` and not adding it here means the uniqueness test stops
    /// covering it — which is the failure mode this list exists to prevent, so keep it in sync.
    static let allCases: [SheetError] = [
        .archiveTooLarge(decompressedBytes: 1, limit: 2),
        .archiveEntryTooLarge(path: "a", declaredBytes: 1, limit: 2),
        .archiveCompressionRatioExceeded(path: "a", ratio: 1, limit: 2),
        .archiveTooManyEntries(count: 1, limit: 2),
        .archivePathTraversal(entryName: "../a"),
        .archiveDuplicateEntry(name: "a"),
        .archiveTruncated(detail: "d"),
        .archiveMalformed(detail: "d"),
        .archiveUnsupportedCompression(path: "a", method: 12),
        .archiveEntryNotFound(path: "a"),
        .archiveChecksumMismatch(path: "a", expected: 1, actual: 2),
        .archiveNestingTooDeep(depth: 2, limit: 1),
        .xmlExternalEntityRejected(part: "a", detail: "d"),
        .xmlDocumentTypeRejected(part: "a"),
        .xmlDepthExceeded(part: "a", depth: 1, limit: 2),
        .xmlTooManyAttributes(part: "a", count: 1, limit: 2),
        .xmlTokenTooLong(part: "a", bytes: 1, limit: 2),
        .xmlMalformed(part: "a", line: 3, detail: "d"),
        .xmlInvalidEncoding(part: "a", detail: "d"),
        .sheetDimensionOutOfRange(sheet: "s", rows: 1, columns: 2),
        .criticalPartMissing(path: "a"),
        .criticalPartUnsupported(path: "a", detail: "d"),
        .workbookEncrypted,
        .unsupportedFileFormat(detail: "d"),
        .workbookTooComplex(detail: "d"),
        .invalidCellReference(text: "zz"),
        .cellReferenceOutOfRange(row: 1, column: 2),
        .rangeOutOfRange(range: "A1:B2", detail: "d"),
        .rangeShapeMismatch(expectedRows: 1, expectedColumns: 2, actualRows: 3, actualColumns: 4),
        .wouldShiftDataOffSheet(detail: "d"),
        .overlappingMerges(first: "A1:B2", second: "B2:C3"),
        .invalidSheetName(name: "n", reason: "r"),
        .duplicateSheetName(name: "n"),
        .sheetNotFound(reference: "n"),
        .invalidDefinedName(name: "n", reason: "r"),
        .duplicateDefinedName(name: "n"),
        .definedNameNotFound(name: "n"),
        .unknownStyleID(rawValue: 3),
        .invalidNumberFormat(code: "c", reason: "r"),
        .invalidFormula(text: "t", position: 1, reason: "r"),
        .formulaTooLong(length: 1, limit: 2),
        .formulaNestingTooDeep(depth: 1, limit: 2),
        .circularReference(refs: ["A1", "B1"]),
        .cellTextTooLong(ref: "A1", length: 1, limit: 2),
        .fileNotFound(path: "p"),
        .fileNotReadable(path: "p", underlying: "u"),
        .fileNotWritable(path: "p", underlying: "u"),
        .fileTooLarge(path: "p", bytes: 1, limit: 2),
        .diskFull(path: "p"),
        .fileVanished(path: "p"),
        .fileLocked(path: "p"),
        .volumeUnavailable(path: "p"),
        .fileNotDownloaded(path: "p"),
        .atomicReplaceFailed(path: "p", underlying: "u"),
        .writeRefused(reason: .encrypted),
        .textEncodingUndetectable(path: "p"),
        .unsupportedTextEncoding(name: "n"),
        .csvMalformed(line: 3, detail: "d"),
        .pathOutsideWorkspace(path: "p"),
        .pathDenyListed(path: "p", rule: "r"),
        .workspaceGrantUnresolvable(path: "p"),
        .databaseError(operation: "o", underlying: "u"),
        .snapshotNotFound(id: "i"),
        .snapshotStoreFull(bytes: 1, limit: 2),
        .toolNotFound(name: "n"),
        .invalidToolArguments(tool: "t", detail: "d"),
        .resultTooLarge(bytes: 1, limit: 2),
        .notImplemented(feature: "f"),
        .cancelled(operation: "o"),
        .internalInconsistency(detail: "d"),
        .invalidArgument(name: "n", reason: "r"),
    ]

    @Test("every code is unique — they are a public contract")
    func codesAreUnique() {
        var seen: [String: String] = [:]
        for error in Self.allCases {
            if let previous = seen[error.code] {
                Issue.record("code '\(error.code)' is used by both \(previous) and \(error)")
            }
            seen[error.code] = String(describing: error)
        }
        #expect(seen.count == Self.allCases.count)
    }

    @Test("every code is a lowercase dotted identifier")
    func codesAreWellFormed() {
        for error in Self.allCases {
            let code = error.code
            #expect(code.contains("."), "'\(code)' should be namespaced")
            #expect(!code.contains(" "), "'\(code)' should have no spaces")
            #expect(code.first?.isLowercase == true, "'\(code)' should start lowercase")
        }
    }

    @Test("every message is a real sentence with the offending value in it")
    func messagesAreUseful() {
        for error in Self.allCases {
            let message = error.message
            #expect(message.count > 15, "'\(message)' is too terse to help anyone")
            #expect(!message.hasSuffix(":"), "'\(message)' looks truncated")
            #expect(message.split(separator: " ").count >= 3, "'\(message)' is not a sentence")
            #expect(!message.contains(error.code), "'\(message)' just restates the code")
        }
    }

    @Test("categories partition the cases sensibly")
    func categories() {
        #expect(SheetError.archiveTooLarge(decompressedBytes: 1, limit: 2).category == .hostileInput)
        #expect(SheetError.xmlExternalEntityRejected(part: "a", detail: "d").category == .hostileInput)
        #expect(SheetError.invalidCellReference(text: "x").category == .validation)
        #expect(SheetError.fileNotFound(path: "p").category == .io)
        #expect(SheetError.pathOutsideWorkspace(path: "p").category == .security)
        #expect(SheetError.databaseError(operation: "o", underlying: "u").category == .persistence)
        #expect(SheetError.toolNotFound(name: "n").category == .toolProtocol)
        #expect(SheetError.workbookEncrypted.category == .unsupported)
        #expect(SheetError.internalInconsistency(detail: "d").category == .internalError)

        // Every category is reachable, so none of them is dead weight.
        let reached = Set(Self.allCases.map(\.category))
        #expect(reached == Set(SheetError.Category.allCases))
    }

    @Test("the security category tells the user to grant the folder in the app")
    func securityRecovery() {
        let denial = SheetError.pathOutsideWorkspace(path: "/Users/q/secret/a.xlsx")
        #expect(denial.message.contains("grant"))
        #expect(denial.recoverySuggestion?.contains("grant") == true)
        // The message must never suggest the server can widen its own access.
        #expect(denial.message.contains("in OpenSheets") || denial.message.contains("in the app"))
    }

    @Test("errors are comparable, which is what fixture assertions need")
    func equatable() {
        #expect(SheetError.fileNotFound(path: "a") == SheetError.fileNotFound(path: "a"))
        #expect(SheetError.fileNotFound(path: "a") != SheetError.fileNotFound(path: "b"))
        #expect(SheetError.fileNotFound(path: "a") != SheetError.fileVanished(path: "a"))
        #expect(Set([SheetError.workbookEncrypted, .workbookEncrypted]).count == 1)
    }

    @Test("the descriptor is the JSON-safe form")
    func descriptor() throws {
        let error = SheetError.archivePathTraversal(entryName: "../../etc/passwd")
        let descriptor = error.descriptor
        #expect(descriptor.code == "zip.pathTraversal")
        #expect(descriptor.message == error.message)
        #expect(descriptor.category == .hostileInput)

        let encoded = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(SheetErrorDescriptor.self, from: encoded)
        #expect(decoded == descriptor)
    }

    @Test("byte counts are rendered for humans")
    func byteFormatting() {
        #expect(SheetError.archiveTooLarge(decompressedBytes: 512, limit: 1024).message.contains("512 bytes"))
        #expect(SheetError.archiveTooLarge(decompressedBytes: 500 * 1024 * 1024, limit: 1).message.contains("500.0 MB"))
    }

    @Test("description carries the code, for logs")
    func description() {
        #expect(SheetError.workbookEncrypted.description.hasPrefix("[workbook.encrypted]"))
    }

    @Test("every hostile-input case from PLAN.md §7.4 has a home", arguments: [
        "zip.bomb.total", "zip.bomb.entry", "zip.bomb.ratio", "zip.entryCount",
        "zip.pathTraversal", "zip.duplicateEntry", "zip.truncated", "zip.nestingTooDeep",
        "xml.externalEntity", "xml.doctype", "xml.depth",
        "workbook.dimensionOutOfRange", "workbook.encrypted", "workbook.unsupportedFormat",
    ])
    func hostileCasesAreCovered(_ code: String) {
        #expect(Self.allCases.contains { $0.code == code }, "no case produces '\(code)'")
    }
}
