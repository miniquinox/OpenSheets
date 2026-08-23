import CryptoKit
import Foundation
import SheetFormat
import SheetModel
import SheetStore
import Synchronization

/// The formats this server will open, and which of them it will write back.
public enum WorkbookFormatSupport {
    /// Extensions we can parse.
    public static let readable: Set<String> = ["xlsx", "xlsm", "xltx", "csv", "tsv", "txt"]
    /// Extensions we can serialise.
    public static let writable: Set<String> = ["xlsx", "xlsm", "xltx", "csv", "tsv"]

    /// Whether `url` looks like a delimited text file rather than a package.
    public static func isDelimited(_ url: URL) -> Bool {
        ["csv", "tsv", "txt"].contains(url.pathExtension.lowercased())
    }

    /// Rejects a path whose extension we do not handle, **before** any I/O.
    ///
    /// The order matters for the same reason ``SheetStore/SheetStore/openDocument(at:io:options:)``
    /// checks the grant before it stats the file: an error that distinguishes "wrong extension"
    /// from "does not exist" tells the caller whether a file is there, and that is a fact an
    /// agent should not be able to learn about a path outside a grant.
    public static func requireReadable(_ url: URL) throws(SheetError) {
        let ext = url.pathExtension.lowercased()
        guard readable.contains(ext) else {
            throw SheetError.unsupportedFileFormat(
                detail: ext.isEmpty
                    ? "'\(url.lastPathComponent)' has no file extension"
                    : "OpenSheets does not read .\(ext) files"
            )
        }
    }
}

/// Identity of a file's *contents*, independent of where it lives or when it was written.
///
/// The read cache is keyed on this rather than on ``SheetStore/FileFingerprint`` because a
/// restore writes bytes we already parsed to a path whose inode and mtime are both new. Keyed
/// on inode the cache would miss on exactly the operation we most want to be cheap; keyed on
/// content it hits.
struct ContentKey: Hashable, Sendable {
    var size: Int
    var headHash: UInt64

    static let headByteCount = 4096

    init(bytes: Data) {
        size = bytes.count
        headHash = ContentKey.hash(bytes.prefix(ContentKey.headByteCount))
    }

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let fileSize = attributes[.size] as? Int
        else { return nil }
        let head = (try? handle.read(upToCount: ContentKey.headByteCount)) ?? Data()
        size = fileSize
        headHash = ContentKey.hash(head)
    }

    /// SHA-256 folded to 64 bits — the same construction ``SheetStore/FileFingerprint`` uses,
    /// and for the same reason: `Hasher` is seeded per process and this value has to mean the
    /// same thing in the app and in `opensheets-mcp`.
    private static func hash(_ bytes: Data) -> UInt64 {
        var digest = SHA256()
        digest.update(data: bytes)
        var result: UInt64 = 0
        for byte in digest.finalize().prefix(8) { result = (result << 8) | UInt64(byte) }
        return result
    }
}

/// Bridges the format layer's `async` reader to ``SheetStore/WorkbookReading``'s synchronous
/// one, without blocking.
///
/// # The shape of the problem
///
/// A1's XLSX reader is `async` — it parses sheets in a task group, which is where a
/// multi-sheet workbook gets its parallelism. `WorkbookReading.readWorkbook(at:)` is
/// synchronous, because `DocumentSession` calls it from inside an actor. Bridging the two with
/// a semaphore blocks a cooperative thread, which is a deadlock waiting for a single-core
/// runner.
///
/// So this reader does not bridge: it **caches**. The broker parses asynchronously and calls
/// ``prime(_:bytes:workbook:)`` before it opens the document, so the synchronous read that
/// `SheetStore` performs is a dictionary lookup on content identity. Every path the server
/// drives — open, refresh, restore — primes first.
///
/// The fallback for a genuine miss is a blocking bridge, kept because a reader that throws
/// would put a session into a failed state for what should be a slow read. It is reached only
/// when the file changed under us between priming and reading.
public final class CachingWorkbookReader: WorkbookReading {
    private struct Entry {
        var key: ContentKey
        var workbook: Workbook
    }

    private let cache = Mutex<[String: Entry]>([:])
    /// How many distinct files stay parsed. Small on purpose: an MCP session works on one or
    /// two workbooks, and a 100 MB workbook held for a file nobody asked about again is worse
    /// than re-reading it.
    private let capacity: Int

    public init(capacity: Int = 4) {
        self.capacity = capacity
    }

    /// Records a workbook we already parsed, keyed by the bytes it came from.
    public func prime(_ url: URL, bytes: Data, workbook: Workbook) {
        let key = ContentKey(bytes: bytes)
        cache.withLock { cache in
            if cache.count >= capacity, cache[Self.key(url)] == nil {
                // Nothing clever: this holds at most a handful of entries, and an LRU with a
                // clock would be more code than the thing it optimises.
                if let victim = cache.keys.sorted().first { cache.removeValue(forKey: victim) }
            }
            cache[Self.key(url)] = Entry(key: key, workbook: workbook)
        }
    }

    /// Drops what we know about `url`.
    public func forget(_ url: URL) {
        _ = cache.withLock { $0.removeValue(forKey: Self.key(url)) }
    }

    /// Whether a synchronous read of `url` would hit the cache. Tests assert on this so a
    /// regression that silently starts blocking is visible.
    public func isPrimed(for url: URL) -> Bool {
        guard let key = ContentKey(url: url) else { return false }
        return cache.withLock { $0[Self.key(url)]?.key == key }
    }

    // MARK: - WorkbookReading

    public func canRead(_ url: URL) -> Bool {
        WorkbookFormatSupport.readable.contains(url.pathExtension.lowercased())
    }

    public func readWorkbook(at url: URL) throws -> Workbook {
        if let key = ContentKey(url: url),
           let entry = cache.withLock({ $0[Self.key(url)] }), entry.key == key {
            return entry.workbook
        }
        let bytes = try Data(contentsOf: url)
        let workbook = try WorkbookParser.parseBlocking(bytes: bytes, url: url)
        prime(url, bytes: bytes, workbook: workbook)
        return workbook
    }

    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }
}

/// Parses bytes into a ``SheetModel/Workbook``, choosing by extension.
public enum WorkbookParser {
    /// The asynchronous path. Everything the server drives goes through here.
    public static func parse(bytes: Data, url: URL) async throws(SheetError) -> Workbook {
        if WorkbookFormatSupport.isDelimited(url) {
            var options = CSVReadOptions.standard
            if url.pathExtension.lowercased() == "tsv" { options.delimiter = "\t" }
            return try CSVReader.workbook(from: bytes, name: sheetName(for: url), options: options)
        }
        return try await XLSXReader.read(
            bytes, name: url.path(percentEncoded: false), extension: url.pathExtension.lowercased()
        ).workbook
    }

    /// The last-resort synchronous path. See ``CachingWorkbookReader``.
    ///
    /// A delimited file never needs the bridge — A1's CSV reader is synchronous — so this only
    /// ever blocks for a package, and only on a cache miss.
    static func parseBlocking(bytes: Data, url: URL) throws -> Workbook {
        if WorkbookFormatSupport.isDelimited(url) {
            var options = CSVReadOptions.standard
            if url.pathExtension.lowercased() == "tsv" { options.delimiter = "\t" }
            return try CSVReader.workbook(from: bytes, name: sheetName(for: url), options: options)
        }
        let box = Mutex<Result<Workbook, any Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let workbook = try await parse(bytes: bytes, url: url)
                box.withLock { $0 = .success(workbook) }
            } catch {
                box.withLock { $0 = .failure(error) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.withLock({ $0 }) else {
            throw SheetError.internalInconsistency(detail: "the blocking parse produced no result")
        }
        return try result.get()
    }

    static func sheetName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let cleaned = String(stem.prefix(Limits.maxSheetNameLength))
            .filter { !Limits.forbiddenSheetNameCharacters.contains($0) }
        return cleaned.isEmpty ? "Sheet1" : cleaned
    }
}

/// Serialises a workbook, and carries the edit tracker the XLSX writer needs.
///
/// # Why this holds state
///
/// A2's writer needs a ``SheetFormat/WorkbookEditTracker`` to know which parts to regenerate
/// and, crucially, which to copy through byte-identical — the Wave 2 addendum §2 is about what
/// happens when it does not. A6's ``SheetStore/WorkbookWriting`` has no parameter for one,
/// because it was designed before that tracker existed and its shape is what keeps the atomic
/// write, the fingerprint and the pre-save snapshot inside `SheetStore`.
///
/// Rather than widen a Wave 1 protocol, the tracker is handed to the writer out of band, keyed
/// by path, immediately before the save that consumes it. The rule is one line and the tests
/// enforce it: **no tracker recorded means the sheet is treated as cells-only**, which is the
/// conservative answer — it regenerates less, never more, and regenerating more is the
/// direction that resizes somebody's rows.
public final class TrackedWorkbookWriter: WorkbookWriting {
    private let pending = Mutex<[String: WorkbookEditTracker]>([:])
    private let options: XLSXWriteOptions

    public init(options: XLSXWriteOptions = .standard) {
        self.options = options
    }

    /// Declares what changed, for the next save of `url`.
    public func setEdits(_ tracker: WorkbookEditTracker, for url: URL) {
        pending.withLock { $0[Self.key(url)] = tracker }
    }

    /// Clears the record after a successful save.
    public func clearEdits(for url: URL) {
        _ = pending.withLock { $0.removeValue(forKey: Self.key(url)) }
    }

    /// What is currently recorded. Tests assert on this.
    public func edits(for url: URL) -> WorkbookEditTracker? {
        pending.withLock { $0[Self.key(url)] }
    }

    // MARK: - WorkbookWriting

    public func canWrite(_ workbook: Workbook, to url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard WorkbookFormatSupport.writable.contains(ext) else { return false }
        guard workbook.meta.readOnlyReason == nil else { return false }
        // Writing a three-sheet workbook to `.csv` would silently drop two of them. Refusing
        // is a worse experience than a warning exactly once, and a better one than the support
        // thread that follows losing a sheet.
        if ["csv", "tsv"].contains(ext), workbook.sheets.count > 1 { return false }
        return true
    }

    public func encodeWorkbook(_ workbook: Workbook, for url: URL, originalBytes _: Data?) throws -> Data {
        let ext = url.pathExtension.lowercased()
        if ["csv", "tsv"].contains(ext) {
            guard let sheet = workbook.sheets.first else {
                throw SheetError.unsupportedFileFormat(detail: "the workbook has no sheets to write")
            }
            var writeOptions = CSVWriteOptions.standard
            if ext == "tsv", workbook.meta.csvDialect == nil { writeOptions.dialect = .tsv }
            return try CSVWriter.data(
                for: sheet, options: writeOptions, sourceDialect: workbook.meta.csvDialect
            )
        }
        let tracker = pending.withLock { $0[Self.key(url)] } ?? TrackedWorkbookWriter.everythingChanged(workbook)
        return try XLSXWriter.data(for: workbook, edits: tracker, options: options)
    }

    /// The fallback tracker: every sheet's cells, nothing else.
    ///
    /// Not ``SheetFormat/SheetRegionChanges/all`` — that would regenerate `<cols>` and
    /// `<sheetFormatPr>` from a model whose display defaults are not the file's, which is the
    /// row-height bug the addendum warns about. Cells-only is the answer that cannot damage a
    /// workbook it does not understand.
    private static func everythingChanged(_ workbook: Workbook) -> WorkbookEditTracker {
        var tracker = WorkbookEditTracker()
        for sheet in workbook.sheets {
            tracker.noteCellsChanged(in: sheet, formulasChanged: true)
        }
        return tracker
    }

    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }
}
