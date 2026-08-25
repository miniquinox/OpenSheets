import CryptoKit
import Foundation
import SheetModel

/// Why a snapshot was taken. Shown verbatim in the snapshot list, so the wording is the
/// user-facing wording.
public enum SnapshotReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// Before pulling in an external change (PLAN.md §5.5).
    case preRefresh
    /// Before one of our own saves.
    case preSave
    /// The user asked for one.
    case manual
    /// Before restoring a different snapshot — so "undo the undo" works.
    case preRestore
    /// The user marked a baseline to track changes against (PLAN.md §1.3). Distinct from
    /// ``manual`` because it is not a copy taken for safety: something still *points* at it —
    /// the `checkpoint:<path>` preference — and the snapshot browser should say so rather than
    /// showing it as one more anonymous manual copy.
    case checkpoint

    /// One line for the snapshot list.
    public var label: String {
        switch self {
        case .preRefresh: "before refresh"
        case .preSave: "before save"
        case .manual: "manual"
        case .preRestore: "before restore"
        case .checkpoint: "checkpoint"
        }
    }
}

/// One stored copy of a file's bytes.
public struct SnapshotRecord: Sendable, Hashable, Codable, Identifiable {
    /// Sorts chronologically. See ``ULID``.
    public var id: ULID
    /// The file this is a snapshot of, canonicalised.
    public var filePath: String
    /// When it was taken.
    public var takenAt: Date
    /// See ``SnapshotReason``.
    public var reason: SnapshotReason
    /// Size of the original bytes.
    public var byteCount: Int
    /// Size on disk after gzip.
    public var compressedByteCount: Int
    /// SHA-256 of the original bytes, hex. Restores verify against it.
    public var contentHash: String
    /// A human line for the list — *"3 sheets, 412 cells"*.
    public var summary: String?

    public init(
        id: ULID,
        filePath: String,
        takenAt: Date,
        reason: SnapshotReason,
        byteCount: Int,
        compressedByteCount: Int,
        contentHash: String,
        summary: String? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.takenAt = takenAt
        self.reason = reason
        self.byteCount = byteCount
        self.compressedByteCount = compressedByteCount
        self.contentHash = contentHash
        self.summary = summary
    }
}

/// The safety net for *"Claude trashed my sheet"* (PLAN.md §5.5).
///
/// Gzipped raw file bytes at
/// `~/Library/Application Support/OpenSheets/Snapshots/<sha256-of-path>/<ulid>.gz`, taken
/// **before every external refresh and before every one of our own saves**. Last 20 per file,
/// oldest evicted, 500 MB across everything.
///
/// Three choices worth defending:
///
/// - **Raw bytes, not a serialised `Workbook`.** A snapshot has to be able to restore a file we
///   could not fully parse — that is exactly when one is most wanted. Bytes round-trip
///   perfectly by definition; a re-encoded model does not.
/// - **The path is hashed, not embedded.** A file named `../../etc/passwd` cannot become a
///   directory outside the store, and a 300-character path cannot exceed `NAME_MAX`.
/// - **Eviction runs after the write, never before.** Making room first means a crash between
///   the two leaves the user with fewer snapshots and no new one. Twenty-one snapshots for a
///   moment is not a problem; nineteen and a gap is.
///
/// An actor because the app and a background save can both reach it, and the per-file
/// eviction is a read-modify-write over the directory.
public actor SnapshotStore {
    /// Where the store lives, and how much of it there may be.
    public struct Configuration: Sendable {
        /// The `Snapshots` directory.
        public var root: URL
        /// Snapshots kept per file. ``Limits/maxSnapshotsPerFile``.
        public var maximumPerFile: Int
        /// Total bytes across every file. ``Limits/maxSnapshotStoreBytes``.
        public var maximumTotalBytes: Int
        /// Files bigger than this are not snapshotted, and ``capture(url:reason:summary:)``
        /// returns `nil` rather than throwing — refusing to save because a 900 MB workbook
        /// will not fit in the safety net would be the wrong trade.
        public var maximumFileBytes: Int

        public init(
            root: URL,
            maximumPerFile: Int = Limits.maxSnapshotsPerFile,
            maximumTotalBytes: Int = Limits.maxSnapshotStoreBytes,
            maximumFileBytes: Int = 256 * 1024 * 1024
        ) {
            self.root = root
            self.maximumPerFile = maximumPerFile
            self.maximumTotalBytes = maximumTotalBytes
            self.maximumFileBytes = maximumFileBytes
        }

        /// `~/Library/Application Support/OpenSheets/Snapshots`.
        public static func standard(
            applicationSupport: URL? = nil
        ) -> Configuration {
            let base = applicationSupport ?? FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("OpenSheets")
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("OpenSheets")
            return Configuration(root: base.appendingPathComponent("Snapshots"))
        }
    }

    /// See ``Configuration``.
    public let configuration: Configuration
    private let index: (any SnapshotIndexing)?

    /// - Parameter index: the `snapshot` table (PLAN.md §5.5). Optional: the store is fully
    ///   functional without it by reading the directory, so a database problem degrades the
    ///   snapshot list rather than removing the safety net.
    public init(configuration: Configuration, index: (any SnapshotIndexing)? = nil) {
        self.configuration = configuration
        self.index = index
    }

    /// Copies `url`'s current bytes into the store.
    ///
    /// Returns `nil` when there is nothing to snapshot — the file does not exist yet, or is
    /// larger than ``Configuration/maximumFileBytes``. Both are normal, and neither should
    /// stop the save that asked for the snapshot.
    @discardableResult
    public func capture(
        url: URL,
        reason: SnapshotReason,
        summary: String? = nil
    ) throws(SheetError) -> SnapshotRecord? {
        let canonical = SnapshotStore.canonicalPath(url)
        guard case let .readable(probe) = FileProbe.probe(url) else { return nil }
        guard probe.fingerprint.size <= configuration.maximumFileBytes else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw SheetError.fileNotReadable(path: canonical, underlying: "\(error)")
        }

        let record = SnapshotRecord(
            id: ULID(),
            filePath: canonical,
            takenAt: Date(),
            reason: reason,
            byteCount: data.count,
            compressedByteCount: 0,
            contentHash: SnapshotStore.digest(data),
            summary: summary
        )
        let compressed = try Gzip.compress(data)
        let directory = try directory(for: canonical)
        let destination = directory.appendingPathComponent(SnapshotStore.fileName(id: record.id, reason: reason))
        try AtomicWriter().write(compressed, to: destination, options: AtomicWriter.Options(
            refusesEmptyOverwrite: false
        ))

        var stored = record
        stored.compressedByteCount = compressed.count
        try? index?.insert(stored)

        // After the write, never before. See the type's note.
        evictPerFile(directory: directory, keeping: configuration.maximumPerFile, path: canonical)
        try enforceGlobalCap()
        return stored
    }

    /// Snapshots of `url`, newest first.
    public func snapshots(for url: URL) throws(SheetError) -> [SnapshotRecord] {
        let canonical = SnapshotStore.canonicalPath(url)
        if let index, let rows = try? index.snapshots(forPath: canonical), !rows.isEmpty {
            return rows.sorted { $0.id > $1.id }
        }
        // No database, or nothing in it: the directory is the source of truth for what can
        // actually be restored, and reconstructing a usable list from filenames alone is the
        // difference between a degraded feature and a missing one.
        let directory = try self.directory(for: canonical, creating: false)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return entries
            .compactMap { entry -> SnapshotRecord? in
                guard let parsed = SnapshotStore.parse(fileName: entry.lastPathComponent) else { return nil }
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                // `byteCount` and `contentHash` live only in the database, so they come back
                // zero and empty here. Everything a restore actually needs — which id, which
                // file, when, and why — is in the filename, which is why the reason is encoded
                // there: this fallback is a degraded list rather than a broken one.
                return SnapshotRecord(
                    id: parsed.id,
                    filePath: canonical,
                    takenAt: parsed.id.timestamp,
                    reason: parsed.reason,
                    byteCount: 0,
                    compressedByteCount: size,
                    contentHash: ""
                )
            }
            .sorted { $0.id > $1.id }
    }

    /// The original bytes of a snapshot, checksum-verified.
    public func data(for id: ULID, of url: URL) throws(SheetError) -> Data {
        let canonical = SnapshotStore.canonicalPath(url)
        let directory = try directory(for: canonical, creating: false)
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            ?? []
        guard let file = entries.first(where: { $0.lastPathComponent.hasPrefix(id.rawValue + ".") }),
              let compressed = try? Data(contentsOf: file)
        else {
            throw SheetError.snapshotNotFound(id: id.rawValue)
        }
        let data = try Gzip.decompress(compressed)
        if let index, let record = try? index.snapshot(id: id), !record.contentHash.isEmpty {
            guard SnapshotStore.digest(data) == record.contentHash else {
                throw SheetError.archiveChecksumMismatch(path: file.path(percentEncoded: false), expected: 0, actual: 0)
            }
        }
        return data
    }

    /// Puts a snapshot back, atomically, through the same path as a save.
    ///
    /// Takes a `.preRestore` snapshot of the current bytes first — undoing a restore has to be
    /// possible, or the safety net has a hole exactly where someone panicking will fall
    /// through it. Registers the resulting fingerprint with `suppressor`, so the restore does
    /// not read as an external change and set off a refresh loop.
    @discardableResult
    public func restore(
        _ id: ULID,
        to url: URL,
        suppressor: SelfWriteSuppressor
    ) throws(SheetError) -> FileFingerprint {
        let data = try data(for: id, of: url)
        _ = try? capture(url: url, reason: .preRestore, summary: "before restoring \(id.rawValue)")
        return try suppressor.write(data, to: url, options: AtomicWriter.Options(refusesEmptyOverwrite: false))
    }

    /// Total bytes the store occupies.
    public func totalBytes() -> Int {
        SnapshotStore.totalBytes(under: configuration.root)
    }

    /// Deletes every snapshot of `url`.
    public func forget(_ url: URL) {
        let canonical = SnapshotStore.canonicalPath(url)
        guard let directory = try? directory(for: canonical, creating: false) else { return }
        try? FileManager.default.removeItem(at: directory)
        try? index?.deleteSnapshots(forPath: canonical)
    }

    // MARK: - Internals

    private func directory(for canonicalPath: String, creating: Bool = true) throws(SheetError) -> URL {
        let directory = configuration.root.appendingPathComponent(SnapshotStore.digest(Data(canonicalPath.utf8)))
        if creating {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw SheetError.fileNotWritable(path: directory.path(percentEncoded: false), underlying: "\(error)")
            }
        }
        return directory
    }

    private func evictPerFile(directory: URL, keeping limit: Int, path: String) {
        let entries = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "gz" }
        guard entries.count > limit else { return }
        // ULID filenames sort chronologically, so "oldest first" is a string sort — no `stat`
        // per file, and no dependence on an mtime a backup restore can rewrite.
        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in sorted.prefix(entries.count - limit) {
            try? FileManager.default.removeItem(at: entry)
            if let parsed = SnapshotStore.parse(fileName: entry.lastPathComponent) {
                try? index?.deleteSnapshot(id: parsed.id)
            }
        }
    }

    /// Trims the whole store to ``Configuration/maximumTotalBytes``, oldest first across every
    /// file — but never removes a file's only remaining snapshot, so a single enormous
    /// workbook cannot evict every other document's safety net.
    private func enforceGlobalCap() throws(SheetError) {
        var total = SnapshotStore.totalBytes(under: configuration.root)
        guard total > configuration.maximumTotalBytes else { return }

        var byDirectory: [URL: [URL]] = [:]
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: configuration.root,
            includingPropertiesForKeys: nil
        )) ?? []
        for directory in directories {
            let entries = ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []).filter { $0.pathExtension == "gz" }
            guard !entries.isEmpty else { continue }
            byDirectory[directory] = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        var candidates = byDirectory.values
            .flatMap { $0.dropLast() }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        while total > configuration.maximumTotalBytes, !candidates.isEmpty {
            let entry = candidates.removeFirst()
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            try? FileManager.default.removeItem(at: entry)
            if let parsed = SnapshotStore.parse(fileName: entry.lastPathComponent) {
                try? index?.deleteSnapshot(id: parsed.id)
            }
            total -= size
        }
        if total > configuration.maximumTotalBytes {
            throw SheetError.snapshotStoreFull(bytes: total, limit: configuration.maximumTotalBytes)
        }
    }

    private static func totalBytes(under root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += values?.fileSize ?? 0
        }
        return total
    }

    /// `<ulid>.<reason>.gz`.
    ///
    /// The reason is in the filename, not only in the database, so a snapshot directory is
    /// self-describing: a user recovering by hand can see which copy was taken before which
    /// save, and the store can rebuild a usable list if the database is lost. The ULID stays
    /// the prefix, so sorting filenames is still sorting by time.
    static func fileName(id: ULID, reason: SnapshotReason) -> String {
        "\(id.rawValue).\(reason.rawValue).gz"
    }

    static func parse(fileName: String) -> (id: ULID, reason: SnapshotReason)? {
        let parts = fileName.split(separator: ".")
        guard parts.count == 3, parts[2] == "gz", let id = ULID(rawValue: String(parts[0])) else { return nil }
        return (id, SnapshotReason(rawValue: String(parts[1])) ?? .manual)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Snapshots are keyed on the resolved path, so opening a file through a symlink and
    /// through its real path shows one history rather than two.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }
}

/// The persistence half of the snapshot store, so the store can be tested without a database
/// and the database can be swapped without touching the store.
public protocol SnapshotIndexing: Sendable {
    func insert(_ record: SnapshotRecord) throws
    func snapshot(id: ULID) throws -> SnapshotRecord?
    func snapshots(forPath path: String) throws -> [SnapshotRecord]
    func deleteSnapshot(id: ULID) throws
    func deleteSnapshots(forPath path: String) throws
}
