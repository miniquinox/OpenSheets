import Foundation

/// The only error type OpenSheets throws.
///
/// PLAN.md §8 is blunt about this: every failure returns a typed error with a human-readable
/// message and a machine-readable code — never a `fatalError`, never an `NSError` leaking out
/// of a framework call, never a silent no-op. That rule only works if there is exactly one
/// error type, so this is it. If you are reaching for a new error type, add a case here instead.
///
/// Three properties carry the whole contract:
///
/// - ``code`` is a stable dotted string (`"zip.bomb.total"`). It is what
///   `Fixtures/hostile/expected-errors.json` asserts against and what the MCP server puts on
///   the wire, so **changing an existing code is a breaking change**. Adding one is not.
/// - ``message`` is one sentence for a human, with the offending value in it. "Entry
///   'xl/sheet1.xml' inflates to 4.2 GB" beats "decompression limit exceeded".
/// - ``category`` groups cases for presentation: A5 shows hostile-input failures as a
///   read-only banner, validation failures inline, and security failures with the
///   grant-the-folder instruction.
///
/// Foundation errors are wrapped, not propagated: associated values are `String`, never
/// `any Error`, which keeps this type `Equatable` and `Hashable` so tests can compare
/// expected failures directly.
public enum SheetError: Error, Sendable, Hashable {
    // MARK: - Archive hardening (PLAN.md §7.4)

    /// The archive as a whole inflates past ``Limits/maxDecompressedBytes``.
    case archiveTooLarge(decompressedBytes: Int, limit: Int)

    /// One entry inflates past ``Limits/maxEntryDecompressedBytes``, or claims to.
    case archiveEntryTooLarge(path: String, declaredBytes: Int, limit: Int)

    /// One entry's compression ratio exceeds ``Limits/maxCompressionRatio`` — the signature of
    /// a zip bomb, since real XML tops out around 10:1.
    case archiveCompressionRatioExceeded(path: String, ratio: Double, limit: Double)

    /// More entries than ``Limits/maxArchiveEntries``.
    case archiveTooManyEntries(count: Int, limit: Int)

    /// An entry name that would escape the extraction root: contains `..`, starts with `/`,
    /// contains a NUL, or uses a Windows drive letter. We never extract to disk, but a
    /// traversal name means the file is hostile and nothing else in it should be trusted.
    case archivePathTraversal(entryName: String)

    /// Two entries with the same name. Ambiguous by construction, and a classic way to smuggle
    /// one payload past a validator and a different one past the parser.
    case archiveDuplicateEntry(name: String)

    /// The archive ends before its own central directory says it should.
    case archiveTruncated(detail: String)

    /// The archive has no end-of-central-directory record, or one that does not parse.
    case archiveMalformed(detail: String)

    /// An entry uses a compression method other than store (0) or deflate (8).
    case archiveUnsupportedCompression(path: String, method: UInt16)

    /// A named entry is not in the archive. Usually a broken relationship, not an attack.
    case archiveEntryNotFound(path: String)

    /// An entry's CRC32 does not match its inflated bytes.
    case archiveChecksumMismatch(path: String, expected: UInt32, actual: UInt32)

    /// Archives nested deeper than ``Limits/maxNestedArchiveDepth``.
    case archiveNestingTooDeep(depth: Int, limit: Int)

    // MARK: - XML hardening (PLAN.md §7.4)

    /// The document declares an external entity. We never resolve one — that is XXE, and the
    /// hostile corpus contains a file pointing at `/etc/passwd`.
    case xmlExternalEntityRejected(part: String, detail: String)

    /// A DTD or internal entity subset. Billion-laughs lives here; we reject rather than count.
    case xmlDocumentTypeRejected(part: String)

    /// Element nesting past ``Limits/maxXMLDepth``.
    case xmlDepthExceeded(part: String, depth: Int, limit: Int)

    /// More attributes on one element than ``Limits/maxXMLAttributesPerElement``.
    case xmlTooManyAttributes(part: String, count: Int, limit: Int)

    /// A single token longer than ``Limits/maxXMLTokenBytes``.
    case xmlTokenTooLong(part: String, bytes: Int, limit: Int)

    /// The XML does not parse. `line` is 1-based where the parser can report it.
    case xmlMalformed(part: String, line: Int?, detail: String)

    /// Bytes that are not valid in the declared encoding, or a NUL inside a string.
    case xmlInvalidEncoding(part: String, detail: String)

    // MARK: - Workbook structure

    /// A sheet claims more rows or columns than the format allows — "a sheet declaring 4
    /// billion rows" in the hostile corpus. Rejected before any allocation is sized from it.
    case sheetDimensionOutOfRange(sheet: String, rows: Int, columns: Int)

    /// A required part is missing or unreadable and we cannot model the workbook without it.
    case criticalPartMissing(path: String)

    /// A part we do not model, which we also cannot safely ignore.
    case criticalPartUnsupported(path: String, detail: String)

    /// The workbook is encrypted or password-protected. We open nothing and write nothing.
    case workbookEncrypted

    /// A format we do not read: `.xlsb`, `.xls`, `.ods`, and friends.
    case unsupportedFileFormat(detail: String)

    /// More sheets than ``Limits/maxSheets``, or more defined names than
    /// ``Limits/maxDefinedNames``.
    case workbookTooComplex(detail: String)

    // MARK: - Reference and range validation (PLAN.md §8)

    /// An A1 string that does not parse as a cell reference.
    case invalidCellReference(text: String)

    /// A row or column index outside the addressable grid.
    case cellReferenceOutOfRange(row: Int, column: Int)

    /// A range whose corners are addressable but which does not fit the sheet after an
    /// operation — an insert that would push data past `XFD1048576`, typically.
    case rangeOutOfRange(range: String, detail: String)

    /// A value array whose shape does not match the range it is being written into.
    case rangeShapeMismatch(expectedRows: Int, expectedColumns: Int, actualRows: Int, actualColumns: Int)

    /// An insert or delete that would silently destroy data by pushing it off the edge of the
    /// sheet. We refuse rather than truncate.
    case wouldShiftDataOffSheet(detail: String)

    /// Two merged ranges overlap. Excel's own behaviour here is undefined enough that we
    /// reject instead of guessing.
    case overlappingMerges(first: String, second: String)

    // MARK: - Naming

    /// A sheet name Excel would reject. See ``Limits/validateSheetName(_:)``.
    case invalidSheetName(name: String, reason: String)

    /// Two sheets whose names collide. Excel's comparison is case-insensitive, so `Data` and
    /// `data` collide — PLAN.md §9 lists this explicitly.
    case duplicateSheetName(name: String)

    /// No sheet with this name or id.
    case sheetNotFound(reference: String)

    /// A defined name that breaks Excel's identifier rules (starts with a digit, looks like a
    /// cell reference, contains a space, and so on).
    case invalidDefinedName(name: String, reason: String)

    /// Two defined names colliding within the same scope.
    case duplicateDefinedName(name: String)

    /// No defined name by this name in the requested scope.
    case definedNameNotFound(name: String)

    // MARK: - Styles and formats

    /// A cell references a style index that is not in the ``StyleTable``.
    case unknownStyleID(rawValue: Int32)

    /// A number-format code that does not parse.
    case invalidNumberFormat(code: String, reason: String)

    // MARK: - Formulas

    /// A formula that does not lex or parse. `position` is a UTF-8 offset into the source text.
    case invalidFormula(text: String, position: Int?, reason: String)

    /// A formula longer than ``Limits/maxFormulaLength``.
    case formulaTooLong(length: Int, limit: Int)

    /// Function-call nesting past ``Limits/maxFormulaNestingDepth``.
    case formulaNestingTooDeep(depth: Int, limit: Int)

    /// A dependency cycle. The engine reports `#CIRCULAR` in the affected cells rather than
    /// throwing during recalc; this case is for callers that asked for a value and cannot be
    /// given one.
    case circularReference(refs: [String])

    /// Text longer than ``Limits/maxCellTextLength`` in one cell.
    case cellTextTooLong(ref: String, length: Int, limit: Int)

    // MARK: - Filesystem (PLAN.md §9)

    /// No file at this path.
    case fileNotFound(path: String)

    /// The file exists but cannot be read: permissions, a directory where a file should be,
    /// or an I/O error. `underlying` is the framework message, flattened to a string.
    case fileNotReadable(path: String, underlying: String)

    /// The file or its directory cannot be written.
    case fileNotWritable(path: String, underlying: String)

    /// The file is larger than ``Limits/maxFileBytes``.
    case fileTooLarge(path: String, bytes: Int, limit: Int)

    /// The volume ran out of space mid-write. The original file is untouched.
    case diskFull(path: String)

    /// The file disappeared between opening and finishing. PLAN.md §9: deleted or moved while
    /// open is a designed state, not a crash.
    case fileVanished(path: String)

    /// Another process holds an exclusive lock.
    case fileLocked(path: String)

    /// The volume is not mounted — a network share that went away.
    case volumeUnavailable(path: String)

    /// An iCloud or Dropbox placeholder whose contents have not been downloaded yet.
    case fileNotDownloaded(path: String)

    /// The temp-file-then-`replaceItemAt` dance failed. Distinct from ``fileNotWritable``
    /// because the original is guaranteed intact and the caller can safely retry.
    case atomicReplaceFailed(path: String, underlying: String)

    /// We hold a workbook we are not allowed to save. Refusing to write is always better than
    /// corrupting (PLAN.md §5.2).
    case writeRefused(reason: ReadOnlyReason)

    // MARK: - Text and CSV (PLAN.md §5.4)

    /// Bytes that decode in no encoding we try.
    case textEncodingUndetectable(path: String)

    /// An encoding named in the file that we cannot decode.
    case unsupportedTextEncoding(name: String)

    /// A CSV that violates RFC 4180 unrecoverably — an unterminated quoted field, typically.
    /// Ragged rows are *not* an error; they are padded and counted.
    case csvMalformed(line: Int, detail: String)

    // MARK: - Security (PLAN.md §7.2)

    /// A path that does not resolve inside an active workspace grant. The message tells the
    /// user to grant the folder in the app, because the server can never self-grant.
    case pathOutsideWorkspace(path: String)

    /// A path on the deny-list, which overrides every grant: `~/.ssh`, `~/.aws`, keychains,
    /// `.env*`, `*.pem`, `*.key`.
    case pathDenyListed(path: String, rule: String)

    /// A security-scoped bookmark that no longer resolves — the folder moved or the grant was
    /// revoked.
    case workspaceGrantUnresolvable(path: String)

    // MARK: - Persistence (PLAN.md §5.5)

    /// A database operation failed. `underlying` is SQLite's message.
    case databaseError(operation: String, underlying: String)

    /// A snapshot id that is not in the store.
    case snapshotNotFound(id: String)

    /// The snapshot store is at ``Limits/maxSnapshotStoreBytes`` and eviction did not free
    /// enough room.
    case snapshotStoreFull(bytes: Int, limit: Int)

    // MARK: - Tool surface (PLAN.md §12)

    /// An MCP tool name the server does not implement.
    case toolNotFound(name: String)

    /// Arguments that fail a tool's JSON Schema.
    case invalidToolArguments(tool: String, detail: String)

    /// A result that would exceed the caller's size budget. Returned instead of truncating
    /// silently, so the agent knows to page.
    case resultTooLarge(bytes: Int, limit: Int)

    // MARK: - Catch-alls

    /// A feature that is genuinely not built yet. PLAN.md §13.1 blesses this: an honest
    /// `notImplemented` is fine, a silent wrong answer is not. It must never ship on a path
    /// the user can reach without a feature flag.
    case notImplemented(feature: String)

    /// The user or the system cancelled the operation.
    case cancelled(operation: String)

    /// An invariant we believed was guaranteed turned out not to be. This is the replacement
    /// for `fatalError` — it unwinds instead of killing the app, and it carries enough detail
    /// to fix the bug. Reaching one is always a bug in OpenSheets, never in the input.
    case internalInconsistency(detail: String)

    /// An argument that is wrong in a way none of the specific cases cover.
    case invalidArgument(name: String, reason: String)
}

// MARK: - Categories

extension SheetError {
    /// Coarse grouping, for presentation and for metrics.
    ///
    /// A5 keys its error surfaces off this: ``Category/hostileInput`` becomes a read-only
    /// banner explaining the file was rejected, ``Category/validation`` becomes an inline
    /// message next to the offending cell, and ``Category/security`` becomes the
    /// grant-the-folder instruction.
    public enum Category: String, Sendable, Hashable, CaseIterable, Codable {
        /// The file is malformed or actively hostile. Never the user's fault.
        case hostileInput
        /// The requested operation is not valid for this workbook.
        case validation
        /// The filesystem said no.
        case io
        /// A workspace grant or deny-list rule refused the path.
        case security
        /// The local database or snapshot store failed.
        case persistence
        /// A tool call was malformed.
        case toolProtocol
        /// We understand the file but do not support this part of it.
        case unsupported
        /// A bug in OpenSheets.
        case internalError
    }

    /// The category this case belongs to.
    public var category: Category {
        switch self {
        case .archiveTooLarge, .archiveEntryTooLarge, .archiveCompressionRatioExceeded,
             .archiveTooManyEntries, .archivePathTraversal, .archiveDuplicateEntry,
             .archiveTruncated, .archiveMalformed, .archiveChecksumMismatch, .archiveNestingTooDeep,
             .xmlExternalEntityRejected, .xmlDocumentTypeRejected, .xmlDepthExceeded,
             .xmlTooManyAttributes, .xmlTokenTooLong, .xmlMalformed, .xmlInvalidEncoding,
             .sheetDimensionOutOfRange, .workbookTooComplex, .textEncodingUndetectable,
             .csvMalformed, .cellTextTooLong:
            .hostileInput

        case .archiveUnsupportedCompression, .archiveEntryNotFound, .criticalPartMissing,
             .criticalPartUnsupported, .workbookEncrypted, .unsupportedFileFormat,
             .unsupportedTextEncoding, .notImplemented:
            .unsupported

        case .invalidCellReference, .cellReferenceOutOfRange, .rangeOutOfRange,
             .rangeShapeMismatch, .wouldShiftDataOffSheet, .overlappingMerges,
             .invalidSheetName, .duplicateSheetName, .sheetNotFound, .invalidDefinedName,
             .duplicateDefinedName, .definedNameNotFound, .unknownStyleID,
             .invalidNumberFormat, .invalidFormula, .formulaTooLong, .formulaNestingTooDeep,
             .circularReference, .invalidArgument:
            .validation

        case .fileNotFound, .fileNotReadable, .fileNotWritable, .fileTooLarge, .diskFull,
             .fileVanished, .fileLocked, .volumeUnavailable, .fileNotDownloaded,
             .atomicReplaceFailed, .writeRefused, .cancelled:
            .io

        case .pathOutsideWorkspace, .pathDenyListed, .workspaceGrantUnresolvable:
            .security

        case .databaseError, .snapshotNotFound, .snapshotStoreFull:
            .persistence

        case .toolNotFound, .invalidToolArguments, .resultTooLarge:
            .toolProtocol

        case .internalInconsistency:
            .internalError
        }
    }
}

// MARK: - Codes

extension SheetError {
    /// A stable, machine-readable identifier for this failure.
    ///
    /// Dotted and namespaced by subsystem. These strings are a public contract:
    /// `Fixtures/hostile/expected-errors.json` maps files to codes, and the MCP server puts
    /// them on the wire. **Never change an existing code** — add a new case instead.
    public var code: String {
        switch self {
        case .archiveTooLarge: "zip.bomb.total"
        case .archiveEntryTooLarge: "zip.bomb.entry"
        case .archiveCompressionRatioExceeded: "zip.bomb.ratio"
        case .archiveTooManyEntries: "zip.entryCount"
        case .archivePathTraversal: "zip.pathTraversal"
        case .archiveDuplicateEntry: "zip.duplicateEntry"
        case .archiveTruncated: "zip.truncated"
        case .archiveMalformed: "zip.malformed"
        case .archiveUnsupportedCompression: "zip.unsupportedCompression"
        case .archiveEntryNotFound: "zip.entryNotFound"
        case .archiveChecksumMismatch: "zip.checksumMismatch"
        case .archiveNestingTooDeep: "zip.nestingTooDeep"
        case .xmlExternalEntityRejected: "xml.externalEntity"
        case .xmlDocumentTypeRejected: "xml.doctype"
        case .xmlDepthExceeded: "xml.depth"
        case .xmlTooManyAttributes: "xml.attributeCount"
        case .xmlTokenTooLong: "xml.tokenTooLong"
        case .xmlMalformed: "xml.malformed"
        case .xmlInvalidEncoding: "xml.invalidEncoding"
        case .sheetDimensionOutOfRange: "workbook.dimensionOutOfRange"
        case .criticalPartMissing: "workbook.criticalPartMissing"
        case .criticalPartUnsupported: "workbook.criticalPartUnsupported"
        case .workbookEncrypted: "workbook.encrypted"
        case .unsupportedFileFormat: "workbook.unsupportedFormat"
        case .workbookTooComplex: "workbook.tooComplex"
        case .invalidCellReference: "ref.invalid"
        case .cellReferenceOutOfRange: "ref.outOfRange"
        case .rangeOutOfRange: "range.outOfRange"
        case .rangeShapeMismatch: "range.shapeMismatch"
        case .wouldShiftDataOffSheet: "range.shiftOffSheet"
        case .overlappingMerges: "range.overlappingMerges"
        case .invalidSheetName: "sheet.invalidName"
        case .duplicateSheetName: "sheet.duplicateName"
        case .sheetNotFound: "sheet.notFound"
        case .invalidDefinedName: "name.invalid"
        case .duplicateDefinedName: "name.duplicate"
        case .definedNameNotFound: "name.notFound"
        case .unknownStyleID: "style.unknownID"
        case .invalidNumberFormat: "style.invalidNumberFormat"
        case .invalidFormula: "formula.invalid"
        case .formulaTooLong: "formula.tooLong"
        case .formulaNestingTooDeep: "formula.nestingTooDeep"
        case .circularReference: "formula.circular"
        case .cellTextTooLong: "cell.textTooLong"
        case .fileNotFound: "file.notFound"
        case .fileNotReadable: "file.notReadable"
        case .fileNotWritable: "file.notWritable"
        case .fileTooLarge: "file.tooLarge"
        case .diskFull: "file.diskFull"
        case .fileVanished: "file.vanished"
        case .fileLocked: "file.locked"
        case .volumeUnavailable: "file.volumeUnavailable"
        case .fileNotDownloaded: "file.notDownloaded"
        case .atomicReplaceFailed: "file.atomicReplaceFailed"
        case .writeRefused: "file.writeRefused"
        case .textEncodingUndetectable: "text.encodingUndetectable"
        case .unsupportedTextEncoding: "text.unsupportedEncoding"
        case .csvMalformed: "csv.malformed"
        case .pathOutsideWorkspace: "grant.outsideWorkspace"
        case .pathDenyListed: "grant.denyListed"
        case .workspaceGrantUnresolvable: "grant.unresolvable"
        case .databaseError: "db.error"
        case .snapshotNotFound: "snapshot.notFound"
        case .snapshotStoreFull: "snapshot.storeFull"
        case .toolNotFound: "tool.notFound"
        case .invalidToolArguments: "tool.invalidArguments"
        case .resultTooLarge: "tool.resultTooLarge"
        case .notImplemented: "core.notImplemented"
        case .cancelled: "core.cancelled"
        case .internalInconsistency: "core.internalInconsistency"
        case .invalidArgument: "core.invalidArgument"
        }
    }
}

// MARK: - Messages

extension SheetError {
    /// One sentence for a human, with the offending value in it.
    ///
    /// These are shown to users in glass surfaces and returned to agents over MCP, so they
    /// name the thing that went wrong rather than describing the check that failed.
    public var message: String {
        switch self {
        case let .archiveTooLarge(bytes, limit):
            "This file expands to \(Self.bytes(bytes)), over the \(Self.bytes(limit)) limit. It looks like a zip bomb rather than a spreadsheet."
        case let .archiveEntryTooLarge(path, declared, limit):
            "'\(path)' claims to expand to \(Self.bytes(declared)), over the \(Self.bytes(limit)) per-entry limit."
        case let .archiveCompressionRatioExceeded(path, ratio, limit):
            "'\(path)' compresses \(Int(ratio)):1, past the \(Int(limit)):1 limit. Real spreadsheet XML never does that."
        case let .archiveTooManyEntries(count, limit):
            "This archive holds \(count) entries; the limit is \(limit)."
        case let .archivePathTraversal(name):
            "Archive entry '\(name)' points outside the archive. The file is malformed or hostile."
        case let .archiveDuplicateEntry(name):
            "Archive entry '\(name)' appears more than once, so its contents are ambiguous."
        case let .archiveTruncated(detail):
            "This file is incomplete — it may still be being written. \(detail)"
        case let .archiveMalformed(detail):
            "This is not a readable ZIP archive. \(detail)"
        case let .archiveUnsupportedCompression(path, method):
            "'\(path)' uses compression method \(method); OpenSheets reads stored and deflated entries only."
        case let .archiveEntryNotFound(path):
            "The workbook refers to '\(path)', which is not in the file."
        case let .archiveChecksumMismatch(path, expected, actual):
            "'\(path)' failed its checksum (expected \(String(expected, radix: 16)), got \(String(actual, radix: 16))). The file is damaged."
        case let .archiveNestingTooDeep(depth, limit):
            "Archives nested \(depth) deep; the limit is \(limit)."
        case let .xmlExternalEntityRejected(part, detail):
            "'\(part)' tries to pull in an external entity. OpenSheets never resolves those. \(detail)"
        case let .xmlDocumentTypeRejected(part):
            "'\(part)' declares a document type. OpenSheets rejects DTDs because they are an expansion attack."
        case let .xmlDepthExceeded(part, depth, limit):
            "'\(part)' nests elements \(depth) deep; the limit is \(limit)."
        case let .xmlTooManyAttributes(part, count, limit):
            "An element in '\(part)' has \(count) attributes; the limit is \(limit)."
        case let .xmlTokenTooLong(part, bytes, limit):
            "A single value in '\(part)' is \(Self.bytes(bytes)); the limit is \(Self.bytes(limit))."
        case let .xmlMalformed(part, line, detail):
            if let line {
                "'\(part)' is not valid XML at line \(line): \(detail)"
            } else {
                "'\(part)' is not valid XML: \(detail)"
            }
        case let .xmlInvalidEncoding(part, detail):
            "'\(part)' contains bytes that are not valid text: \(detail)"
        case let .sheetDimensionOutOfRange(sheet, rows, columns):
            "Sheet '\(sheet)' claims \(rows) rows by \(columns) columns; the maximum is \(Limits.rowCount) by \(Limits.columnCount)."
        case let .criticalPartMissing(path):
            "This workbook is missing '\(path)', which OpenSheets needs in order to read it."
        case let .criticalPartUnsupported(path, detail):
            "'\(path)' uses something OpenSheets does not understand, and ignoring it would be unsafe. \(detail)"
        case .workbookEncrypted:
            "This workbook is password-protected. OpenSheets cannot open encrypted files."
        case let .unsupportedFileFormat(detail):
            "OpenSheets does not read this format. \(detail)"
        case let .workbookTooComplex(detail):
            "This workbook is past a structural limit: \(detail)"
        case let .invalidCellReference(text):
            "'\(text)' is not a cell reference."
        case let .cellReferenceOutOfRange(row, column):
            "Row \(row + 1), column \(CellRef.columnLetters(column)) is outside the sheet (maximum XFD1048576)."
        case let .rangeOutOfRange(range, detail):
            "\(range) does not fit on the sheet: \(detail)"
        case let .rangeShapeMismatch(er, ec, ar, ac):
            "This range is \(er)×\(ec) but the values are \(ar)×\(ac)."
        case let .wouldShiftDataOffSheet(detail):
            "That would push data off the end of the sheet and lose it: \(detail)"
        case let .overlappingMerges(first, second):
            "Merged ranges \(first) and \(second) overlap."
        case let .invalidSheetName(name, reason):
            "'\(name)' is not a usable sheet name: \(reason)."
        case let .duplicateSheetName(name):
            "There is already a sheet called '\(name)'. Sheet names are compared without regard to case."
        case let .sheetNotFound(reference):
            "There is no sheet '\(reference)' in this workbook."
        case let .invalidDefinedName(name, reason):
            "'\(name)' is not a usable name: \(reason)."
        case let .duplicateDefinedName(name):
            "The name '\(name)' is already defined in this scope."
        case let .definedNameNotFound(name):
            "There is no name '\(name)' in this workbook."
        case let .unknownStyleID(rawValue):
            "Style \(rawValue) is not in this workbook's style table."
        case let .invalidNumberFormat(code, reason):
            "Number format '\(code)' does not parse: \(reason)."
        case let .invalidFormula(text, position, reason):
            if let position {
                "'\(text)' is not a valid formula at character \(position + 1): \(reason)."
            } else {
                "'\(text)' is not a valid formula: \(reason)."
            }
        case let .formulaTooLong(length, limit):
            "This formula is \(length) characters; the limit is \(limit)."
        case let .formulaNestingTooDeep(depth, limit):
            "This formula nests \(depth) levels deep; the limit is \(limit)."
        case let .circularReference(refs):
            "These cells depend on each other in a loop: \(refs.prefix(8).joined(separator: ", "))."
        case let .cellTextTooLong(ref, length, limit):
            "\(ref) holds \(length) characters; a cell can hold \(limit)."
        case let .fileNotFound(path):
            "There is no file at \(path)."
        case let .fileNotReadable(path, underlying):
            "\(path) could not be read: \(underlying)"
        case let .fileNotWritable(path, underlying):
            "\(path) could not be written: \(underlying)"
        case let .fileTooLarge(path, bytes, limit):
            "\(path) is \(Self.bytes(bytes)); OpenSheets opens files up to \(Self.bytes(limit))."
        case let .diskFull(path):
            "The volume holding \(path) is full. Nothing was written and the original file is unchanged."
        case let .fileVanished(path):
            "\(path) was deleted or moved while it was open."
        case let .fileLocked(path):
            "\(path) is locked by another application."
        case let .volumeUnavailable(path):
            "The volume holding \(path) is no longer available."
        case let .fileNotDownloaded(path):
            "\(path) has not finished downloading from iCloud yet."
        case let .atomicReplaceFailed(path, underlying):
            "Saving \(path) failed at the final step, so the original file is untouched: \(underlying)"
        case let .writeRefused(reason):
            "OpenSheets will not save this file: \(reason.message)"
        case let .textEncodingUndetectable(path):
            "OpenSheets could not work out the text encoding of \(path)."
        case let .unsupportedTextEncoding(name):
            "OpenSheets cannot decode '\(name)' text."
        case let .csvMalformed(line, detail):
            "This CSV is malformed at line \(line): \(detail)"
        case let .pathOutsideWorkspace(path):
            "\(path) is outside every folder you have granted. Open the folder in OpenSheets and grant it there — the server cannot grant itself access."
        case let .pathDenyListed(path, rule):
            "\(path) is always off limits (matched '\(rule)'), even inside a granted folder."
        case let .workspaceGrantUnresolvable(path):
            "The grant for \(path) no longer resolves. The folder was probably moved or renamed; grant it again."
        case let .databaseError(operation, underlying):
            "The OpenSheets database failed during \(operation): \(underlying)"
        case let .snapshotNotFound(id):
            "There is no snapshot \(id)."
        case let .snapshotStoreFull(bytes, limit):
            "The snapshot store is at \(Self.bytes(bytes)) of \(Self.bytes(limit)) and could not free enough room."
        case let .toolNotFound(name):
            "There is no tool called '\(name)'."
        case let .invalidToolArguments(tool, detail):
            "'\(tool)' was called with invalid arguments: \(detail)"
        case let .resultTooLarge(bytes, limit):
            "That result is \(Self.bytes(bytes)), over the \(Self.bytes(limit)) limit. Ask for a smaller range or use paging."
        case let .notImplemented(feature):
            "\(feature) is not built yet."
        case let .cancelled(operation):
            "\(operation) was cancelled."
        case let .internalInconsistency(detail):
            "OpenSheets hit a bug: \(detail). Please report this."
        case let .invalidArgument(name, reason):
            "'\(name)' is not valid: \(reason)."
        }
    }

    private static func bytes(_ count: Int) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) bytes" : String(format: "%.1f %@", value, units[unit])
    }
}

// MARK: - Presentation

extension SheetError: CustomStringConvertible {
    /// `[code] message` — the form that goes in logs.
    public var description: String { "[\(code)] \(message)" }
}

extension SheetError: LocalizedError {
    /// Bridges to `LocalizedError` so an error crossing into AppKit still reads properly in a
    /// system-presented alert. The same text as ``message``.
    public var errorDescription: String? { message }

    /// What the user can actually do about it, where there is something.
    public var recoverySuggestion: String? {
        switch category {
        case .security:
            "Open the folder in OpenSheets and grant it, then try again."
        case .hostileInput:
            "Open the file in the application that produced it and re-save it."
        case .unsupported:
            "OpenSheets can open the file read-only. Saving would risk losing what it cannot model."
        case .io, .validation, .persistence, .toolProtocol, .internalError:
            nil
        }
    }
}

// MARK: - Wire form

/// A ``SheetError`` flattened for JSON: what crosses the MCP boundary and what
/// `Fixtures/hostile/expected-errors.json` holds.
///
/// The enum itself is deliberately not `Codable` — decoding sixty cases with associated
/// values buys nothing, since consumers compare ``code`` and display ``message``.
public struct SheetErrorDescriptor: Sendable, Hashable, Codable {
    /// The stable dotted identifier. See ``SheetError/code``.
    public let code: String
    /// The human-readable sentence. See ``SheetError/message``.
    public let message: String
    /// The coarse grouping. See ``SheetError/category``.
    public let category: SheetError.Category

    public init(code: String, message: String, category: SheetError.Category) {
        self.code = code
        self.message = message
        self.category = category
    }
}

extension SheetError {
    /// This error in its JSON-safe form.
    public var descriptor: SheetErrorDescriptor {
        SheetErrorDescriptor(code: code, message: message, category: category)
    }
}
