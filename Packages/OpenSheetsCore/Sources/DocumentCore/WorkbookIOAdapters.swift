import Foundation
import SheetFormat
import SheetModel
import SheetStore
import Synchronization

/// Reads `.xlsx`/`.xlsm` and `.csv`/`.tsv` for ``SheetStore``.
///
/// # The seam this closes
///
/// A6 declared ``WorkbookReading/readWorkbook(at:)`` **synchronous**, and A1's `XLSXReader.read`
/// is `async` — not because it does I/O concurrently with anything else, but because it fans the
/// worksheets out over a `TaskGroup`. Something has to bridge that, and the naive bridge —
/// semaphore plus `Task.detached` — blocks a cooperative-pool thread while the work it is waiting
/// for is scheduled onto the same pool. With five documents reloading at once that is a real
/// starvation hazard, and it would show up as a hang rather than as a crash.
///
/// So this reader is **cache-first**. The app reads the file in a proper `async` context with
/// ``read(_:)``, hands the result here with ``prime(_:for:)``, and only *then* asks the session to
/// reload. When ``readWorkbook(at:)`` is called it fingerprints the file — a `stat` and 4 KB —
/// and, if the bytes still match what was primed, returns the parsed workbook with no blocking at
/// all. That covers every path the app drives, and it also halves the work: `STALE` reads the file
/// once to build the diff and again to apply it, and both now hit the same primed parse.
///
/// The blocking bridge remains underneath for callers that cannot prime — an MCP-initiated
/// refresh, or a race where the file changed between the prime and the read. It is correct; it is
/// just not the path anything normally takes.
public final class DocumentWorkbookReader: WorkbookReading, Sendable {
    /// Extensions we parse as an OOXML package.
    public static let workbookExtensions: Set<String> = ["xlsx", "xlsm", "xltx", "xltm"]
    /// Extensions we parse as delimited text.
    public static let delimitedExtensions: Set<String> = ["csv", "tsv", "txt", "tab"]

    private struct Primed: Sendable {
        var fingerprint: FileFingerprint
        var workbook: Workbook
    }

    private let primed = Mutex<[String: Primed]>([:])

    public init() {}

    public func canRead(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.workbookExtensions.contains(ext) || Self.delimitedExtensions.contains(ext)
    }

    /// Parses `url` without blocking anything. The path the app always takes.
    public static func read(_ url: URL) async throws(SheetError) -> Workbook {
        if Self.delimitedExtensions.contains(url.pathExtension.lowercased()) {
            return try CSVReader.workbook(contentsOf: url)
        }
        return try await XLSXReader.read(contentsOf: url)
    }

    /// Records a workbook the app already parsed, against the file's current fingerprint.
    ///
    /// Kept rather than consumed: while the file still *is* what we read, every request for it
    /// has the same answer, and a `STALE` document is asked twice on purpose.
    public func prime(_ workbook: Workbook, for url: URL) {
        guard let fingerprint = try? FileFingerprint.capture(at: url) else { return }
        primed.withLock { $0[Self.key(for: url)] = Primed(fingerprint: fingerprint, workbook: workbook) }
    }

    /// Drops anything remembered about `url`. Called when a document closes.
    public func forget(_ url: URL) {
        primed.withLock { _ = $0.removeValue(forKey: Self.key(for: url)) }
    }

    /// Whether a call to ``readWorkbook(at:)`` right now would be served without blocking.
    /// Tests assert on this; nothing in the app branches on it.
    public func hasFreshPrime(for url: URL) -> Bool {
        guard let fingerprint = try? FileFingerprint.capture(at: url) else { return false }
        return primed.withLock { $0[Self.key(for: url)]?.fingerprint == fingerprint }
    }

    public func readWorkbook(at url: URL) throws -> Workbook {
        let key = Self.key(for: url)
        if let fingerprint = try? FileFingerprint.capture(at: url) {
            let hit = primed.withLock { store -> Workbook? in
                guard let entry = store[key], entry.fingerprint == fingerprint else { return nil }
                return entry.workbook
            }
            if let hit { return hit }
        }
        if Self.delimitedExtensions.contains(url.pathExtension.lowercased()) {
            return try CSVReader.workbook(contentsOf: url)
        }
        let workbook = try Self.blockingRead(url)
        prime(workbook, for: url)
        return workbook
    }

    /// The fallback. See the type's note for why nothing normally reaches it.
    private static func blockingRead(_ url: URL) throws(SheetError) -> Workbook {
        let box = Mutex<Result<Workbook, SheetError>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let outcome: Result<Workbook, SheetError>
            do {
                outcome = .success(try await XLSXReader.read(contentsOf: url))
            } catch let error as SheetError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(
                    .fileNotReadable(path: url.path(percentEncoded: false), underlying: "\(error)")
                )
            }
            box.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        switch box.withLock({ $0 }) {
        case let .success(workbook): return workbook
        case let .failure(error): throw error
        case nil:
            throw SheetError.fileNotReadable(
                path: url.path(percentEncoded: false),
                underlying: "the reader returned nothing"
            )
        }
    }

    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }
}

/// Serialises a workbook for ``SheetStore``, surgically.
///
/// # Bytes, not files
///
/// Wave 2 addendum §3 and §8: `SheetStore` owns the atomic write, the fingerprint and the pre-save
/// snapshot; `SheetFormat` owns the bytes. So A2's `XLSXWriter.save(_:edits:to:)` — which writes
/// to a URL through its own atomic writer and returns its own fingerprint type — is **not** used.
/// `XLSXWriter.data(for:edits:)` is, and ``DocumentSession`` hands the result to
/// ``SelfWriteSuppressor/write(_:to:options:)``. There is no second way to put bytes on disk, and
/// therefore no way to skip the snapshot or the self-write suppression.
///
/// # Why the tracker is staged rather than passed
///
/// ``WorkbookWriting/encodeWorkbook(_:for:originalBytes:)`` has nowhere to put a
/// ``WorkbookEditTracker``, and the tracker is the thing that decides whether a save regenerates
/// `<sheetFormatPr>` — which, per addendum §2, is the difference between an ordinary save and one
/// that makes every row in the user's workbook 60% taller in Excel. So the document stages its
/// tracker here immediately before asking the session to save, keyed by resolved path, and this
/// writer refuses to guess if there is nothing staged: an unstaged save falls back to
/// ``SheetRegionChanges/cells`` only, never to `.all`.
public final class DocumentWorkbookWriter: WorkbookWriting, Sendable {
    private let staged = Mutex<[String: WorkbookEditTracker]>([:])
    private let options: XLSXWriteOptions

    public init(options: XLSXWriteOptions = .standard) {
        self.options = options
    }

    /// Records what changed, for the save that is about to happen.
    public func stage(_ tracker: WorkbookEditTracker, for url: URL) {
        staged.withLock { $0[Self.key(for: url)] = tracker }
    }

    /// Drops the staged tracker. Called after a successful save and when a document closes.
    public func clearStage(for url: URL) {
        staged.withLock { _ = $0.removeValue(forKey: Self.key(for: url)) }
    }

    public func canWrite(_ workbook: Workbook, to url: URL) -> Bool {
        guard workbook.meta.readOnlyReason == nil else { return false }
        let ext = url.pathExtension.lowercased()
        if DocumentWorkbookReader.delimitedExtensions.contains(ext) { return true }
        guard DocumentWorkbookReader.workbookExtensions.contains(ext) else { return false }
        // A workbook read from CSV has no OOXML parts to preserve, so it is built from scratch;
        // one read from xlsx has them and is patched. Both are supported. What is not is writing
        // a format we only partly parsed — which `readOnlyReason` already covers.
        return true
    }

    public func encodeWorkbook(_ workbook: Workbook, for url: URL, originalBytes: Data?) throws -> Data {
        // `originalBytes` is unused on purpose: A2's surgical writer works from
        // `workbook.passthrough`, which holds the original package's entries still *compressed*,
        // so re-reading and re-inflating the file here would be strictly more work for strictly
        // less fidelity.
        _ = originalBytes

        let ext = url.pathExtension.lowercased()
        if DocumentWorkbookReader.delimitedExtensions.contains(ext) {
            guard let sheet = workbook.sheets.first else {
                throw SheetError.invalidArgument(name: "workbook", reason: "there is no sheet to write")
            }
            var csvOptions = CSVWriteOptions.standard
            if ext == "tsv" || ext == "tab" { csvOptions.dialect = .tsv }
            return try CSVWriter.data(
                for: sheet, options: csvOptions, sourceDialect: workbook.meta.csvDialect
            )
        }

        let tracker = staged.withLock { $0[Self.key(for: url)] } ?? Self.cellsOnly(for: workbook)
        return try XLSXWriter.data(for: workbook, edits: tracker, options: options)
    }

    /// The conservative fallback for a save nobody staged: every sheet's cells, and nothing else.
    ///
    /// Deliberately not ``WorkbookEditTracker/noteSheetReplaced(_:)``. Marking a sheet replaced
    /// regenerates `<cols>` and `<sheetFormatPr>` from the model, and the model's row height is
    /// OpenSheets' 24 pt display default rather than the file's own — addendum §2.
    private static func cellsOnly(for workbook: Workbook) -> WorkbookEditTracker {
        var tracker = WorkbookEditTracker()
        for sheet in workbook.sheets {
            tracker.noteCellsChanged(in: sheet, formulasChanged: true)
        }
        return tracker
    }

    private static func key(for url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }
}

public extension WorkbookIO {
    /// The real reader and writer, wired the way addendum §8 arbitrated.
    static func opensheets(
        reader: DocumentWorkbookReader,
        writer: DocumentWorkbookWriter?
    ) -> WorkbookIO {
        WorkbookIO(reader: reader, writer: writer)
    }
}
