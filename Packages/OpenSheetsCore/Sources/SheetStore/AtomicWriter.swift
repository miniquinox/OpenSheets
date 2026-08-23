import Darwin
import Foundation
import SheetModel

/// The points a save passes through, in order.
///
/// Exists so tests can inject a failure at each one and assert the same thing every time: the
/// original file is byte-identical and no temporary file is left behind. A save that can fail
/// halfway is only safe if *every* halfway point has been tried.
public enum AtomicWriteStage: String, Sendable, Hashable, CaseIterable {
    /// The temporary sibling exists and is open.
    case temporaryCreated
    /// Every byte has been written to it.
    case contentWritten
    /// `F_FULLFSYNC` on the file has returned.
    case contentSynced
    /// The containing directory has been synced, so the rename will survive a power loss.
    case directorySynced
    /// `replaceItemAt` has returned. The original is gone from this point on.
    case replaced
}

/// Writes a file the only way that cannot corrupt it (PLAN.md §5.2).
///
/// Temporary sibling in the same directory → write → `F_FULLFSYNC` the file → `fsync` the
/// directory → `FileManager.replaceItemAt`. The original is untouched until that last call,
/// which is a single kernel `rename`: there is no instant at which the destination holds half
/// a workbook. A `kill -9` anywhere before it leaves the original byte-identical and at worst
/// leaves a temporary file, which ``cleanUpStaleTemporaries(in:olderThan:)`` sweeps.
///
/// Two decisions worth knowing about:
///
/// - **Symlinks are written through, not over.** Saving `~/link.xlsx` replaces the file the
///   link points at and leaves the link alone. Replacing the link itself would silently
///   detach it, which is data loss of a kind nobody notices until much later.
/// - **The original's metadata wins.** `replaceItemAt` without `.usingNewMetadataOnly`
///   carries the original's POSIX mode, creation date and extended attributes — Finder tags,
///   quarantine flags — onto the replacement. Those belong to the file, not to its bytes.
public struct AtomicWriter: Sendable {
    /// Knobs, all with safe defaults.
    public struct Options: Sendable {
        /// Refuse to write zero bytes over a file that currently has some.
        ///
        /// Defaults to `true`. An empty encode is nearly always an upstream bug, and the cost
        /// of being wrong in the two directions is not symmetric: a spurious refusal is an
        /// error message, a permitted one is the user's workbook.
        public var refusesEmptyOverwrite: Bool
        /// Keep the previous contents as a sibling until the replace succeeds. `nil` disables.
        public var backupItemName: String?
        /// Called at each ``AtomicWriteStage``. Throwing from it aborts the save as though the
        /// stage itself had failed — the cleanup path is identical, which is the point.
        public var observer: (@Sendable (AtomicWriteStage) throws -> Void)?

        public init(
            refusesEmptyOverwrite: Bool = true,
            backupItemName: String? = nil,
            observer: (@Sendable (AtomicWriteStage) throws -> Void)? = nil
        ) {
            self.refusesEmptyOverwrite = refusesEmptyOverwrite
            self.backupItemName = backupItemName
            self.observer = observer
        }

        public static let `default` = Options()

        /// Runs the observer for `stage` and reports what it threw, if anything.
        ///
        /// Returns rather than throws so the caller stays a straight line of `if let failure`
        /// branches. Every one of those branches has to unlink the temporary, and a `do`/`catch`
        /// around a mixture of typed and untyped throws is exactly where a cleanup path gets
        /// forgotten.
        func failure(at stage: AtomicWriteStage) -> SheetError? {
            guard let observer else { return nil }
            do {
                try observer(stage)
                return nil
            } catch let error as SheetError {
                return error
            } catch {
                return .cancelled(operation: "save at stage \(stage.rawValue)")
            }
        }
    }

    /// Marks our temporary files so a sweep can tell them from someone else's.
    public static let temporaryPrefix = ".opensheets-"
    /// Suffix on the same.
    public static let temporarySuffix = ".tmp"

    public init() {}

    /// Writes `data` to `url` atomically and returns the fingerprint of the result.
    ///
    /// The returned fingerprint is what ``SelfWriteSuppressor`` needs so the watcher does not
    /// treat our own save as an external change (PLAN.md §6.2). Register it — or better, wrap
    /// the call in ``SelfWriteSuppressor/write(to:options:body:)``, which cannot forget to.
    @discardableResult
    public func write(
        _ data: Data,
        to url: URL,
        options: Options = .default
    ) throws(SheetError) -> FileFingerprint {
        let destination = AtomicWriter.writeTarget(for: url)
        let path = destination.path(percentEncoded: false)
        let directory = destination.deletingLastPathComponent()
        let existing = try preflight(destination, path: path, directory: directory, data: data, options: options)

        let temporary = directory.appendingPathComponent(
            AtomicWriter.temporaryPrefix + ULID().rawValue + AtomicWriter.temporarySuffix
        )
        let temporaryPath = temporary.path(percentEncoded: false)
        let mode: mode_t = existing == nil ? 0o644 : AtomicWriter.fileMode(of: path)

        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else { throw AtomicWriter.writeFailure(path: temporaryPath, errno: errno) }

        if let failure = AtomicWriter.fillTemporary(
            data,
            descriptor: descriptor,
            path: temporaryPath,
            directory: directory,
            options: options
        ) {
            _ = close(descriptor)
            _ = unlink(temporaryPath)
            throw failure
        }

        try AtomicWriter.moveIntoPlace(
            temporary: temporary,
            temporaryPath: temporaryPath,
            destination: destination,
            path: path,
            replacingExisting: existing != nil,
            backupItemName: options.backupItemName
        )
        if let failure = options.failure(at: .replaced) { throw failure }

        // Sync the directory again so the rename itself is durable, then fingerprint what is
        // actually on disk rather than what we believe we wrote.
        _ = AtomicWriter.syncDirectory(directory)
        return try FileFingerprint.capture(at: destination)
    }

    /// Where a save to `url` actually lands.
    ///
    /// Resolves the destination when it is a symlink, so we replace the target rather than the
    /// link. Directory components are `resolvingSymlinksInPath`'s job and it handles them.
    public static func writeTarget(for url: URL) -> URL {
        var status = stat()
        let path = url.path(percentEncoded: false)
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFLNK else { return url }
        return url.resolvingSymlinksInPath()
    }

    /// Removes temporaries this writer left behind — the residue of a `kill -9` mid-save.
    ///
    /// Only touches files matching our own prefix and older than `age`, so a save running
    /// concurrently in another process is never sabotaged.
    @discardableResult
    public static func cleanUpStaleTemporaries(in directory: URL, olderThan age: TimeInterval = 3600) -> Int {
        // Not `.skipsHiddenFiles`: our temporaries start with a dot precisely so Finder does
        // not show them, and skipping hidden files here would skip every one of them.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsSubdirectoryDescendants]
        ) else { return 0 }

        var removed = 0
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(temporaryPrefix), name.hasSuffix(temporarySuffix) else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Internals

    /// Everything that can be known to fail before a single byte is written. Returns the
    /// existing file's probe, or `nil` when we are creating the file.
    private func preflight(
        _ destination: URL,
        path: String,
        directory: URL,
        data: Data,
        options: Options
    ) throws(SheetError) -> FileProbe? {
        switch FileProbe.probe(destination) {
        case let .unreadable(error):
            throw error
        case .volumeUnavailable:
            throw SheetError.volumeUnavailable(path: path)
        case .notDownloaded:
            throw SheetError.fileNotDownloaded(path: path)
        case .missing:
            guard access(directory.path(percentEncoded: false), W_OK) == 0 else {
                throw SheetError.fileNotWritable(
                    path: directory.path(percentEncoded: false),
                    underlying: "the containing folder is not writable"
                )
            }
            return nil
        case let .readable(probe):
            if probe.isImmutable { throw SheetError.fileLocked(path: path) }
            if !probe.isFileWritable {
                throw SheetError.fileNotWritable(path: path, underlying: "permission denied")
            }
            if !probe.isDirectoryWritable {
                throw SheetError.fileNotWritable(
                    path: directory.path(percentEncoded: false),
                    underlying: "the containing folder is not writable"
                )
            }
            if options.refusesEmptyOverwrite, data.isEmpty, probe.fingerprint.size > 0 {
                throw SheetError.invalidArgument(
                    name: "data",
                    reason: "refusing to replace \(probe.fingerprint.size) bytes with an empty file"
                )
            }
            return probe
        }
    }

    /// The one irreversible step, isolated so its cleanup is impossible to get wrong.
    private static func moveIntoPlace(
        temporary: URL,
        temporaryPath: String,
        destination: URL,
        path: String,
        replacingExisting: Bool,
        backupItemName: String?
    ) throws(SheetError) {
        guard replacingExisting else {
            // No original to inherit metadata from, so a plain rename — also atomic, and
            // unlike `replaceItemAt` it does not need the destination to already exist.
            guard rename(temporaryPath, path) == 0 else {
                let failure = errno
                _ = unlink(temporaryPath)
                throw SheetError.atomicReplaceFailed(path: path, underlying: String(cString: strerror(failure)))
            }
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: backupItemName,
                options: []
            )
        } catch {
            _ = unlink(temporaryPath)
            throw SheetError.atomicReplaceFailed(path: path, underlying: "\(error)")
        }
    }

    /// Everything between creating the temporary and being ready to rename it.
    ///
    /// Returns the failure rather than throwing so the single caller owns the one cleanup
    /// path. Closes `descriptor` on success; leaves it open on failure so the caller's
    /// close-then-unlink pairing stays in one place.
    private static func fillTemporary(
        _ data: Data,
        descriptor: Int32,
        path: String,
        directory: URL,
        options: Options
    ) -> SheetError? {
        if let failure = options.failure(at: .temporaryCreated) { return failure }
        if let failure = writeAll(data, to: descriptor, path: path) { return failure }
        if let failure = options.failure(at: .contentWritten) { return failure }
        // `fsync` on Darwin only pushes to the drive's cache; `F_FULLFSYNC` is the real
        // barrier. It is unsupported on some filesystems, hence the fallback.
        if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) == -1 {
            return writeFailure(path: path, errno: errno)
        }
        if let failure = options.failure(at: .contentSynced) { return failure }
        _ = close(descriptor)
        if let failure = syncDirectory(directory) { return failure }
        if let failure = options.failure(at: .directorySynced) { return failure }
        return nil
    }

    private static func fileMode(of path: String) -> mode_t {
        var status = stat()
        guard stat(path, &status) == 0 else { return 0o644 }
        return status.st_mode & 0o7777
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) -> SheetError? {
        var written = 0
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while written < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                if result > 0 {
                    written += result
                } else if result == 0 {
                    failure = EIO
                    return
                } else if errno != EINTR {
                    failure = errno
                    return
                }
            }
        }
        if failure != 0 { return writeFailure(path: path, errno: failure) }
        guard written == data.count else {
            return .fileNotWritable(path: path, underlying: "short write: \(written) of \(data.count) bytes")
        }
        return nil
    }

    private static func syncDirectory(_ directory: URL) -> SheetError? {
        let path = directory.path(percentEncoded: false)
        let descriptor = open(path, O_RDONLY)
        guard descriptor >= 0 else { return writeFailure(path: path, errno: errno) }
        defer { _ = close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) == -1 {
            return writeFailure(path: path, errno: errno)
        }
        return nil
    }

    private static func writeFailure(path: String, errno code: Int32) -> SheetError {
        switch code {
        case ENOSPC, EDQUOT: .diskFull(path: path)
        case EACCES, EPERM, EROFS: .fileNotWritable(path: path, underlying: "permission denied")
        case ENOENT: .fileVanished(path: path)
        case ENXIO, ENODEV, ESTALE: .volumeUnavailable(path: path)
        default: .fileNotWritable(path: path, underlying: String(cString: strerror(code)))
        }
    }
}
