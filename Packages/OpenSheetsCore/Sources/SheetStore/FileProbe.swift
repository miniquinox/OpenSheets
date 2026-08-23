import Darwin
import Foundation
import SheetModel

/// What a look at the filesystem found.
///
/// The states here map one-for-one onto the blocking states of ``DocumentSyncState``, which is
/// the point: a probe is the only thing that decides whether a document is `MISSING`, `LOCKED`,
/// `READ_ONLY` or `UNREADABLE`, so that decision lives in one testable function rather than
/// being re-derived at four call sites.
public enum FileCondition: Sendable, Hashable {
    /// The file is a readable regular file.
    case readable(FileProbe)
    /// The path does not exist, and neither does anything explaining why.
    case missing
    /// The path does not exist and its volume is gone with it.
    case volumeUnavailable
    /// An iCloud or Dropbox placeholder that has not been materialised yet. Reading it would
    /// block for however long the download takes, so we report instead of hanging.
    case notDownloaded
    /// Something is there, but it is not a file we can read. Carries the reason.
    case unreadable(SheetError)

    /// The probe, when there is one.
    public var probe: FileProbe? {
        if case let .readable(probe) = self { return probe }
        return nil
    }
}

/// A single filesystem observation: the fingerprint plus the permissions that decide whether a
/// save can even be attempted.
public struct FileProbe: Sendable, Hashable {
    /// Identity and content state. See ``FileFingerprint``.
    public var fingerprint: FileFingerprint
    /// The file has `UF_IMMUTABLE` or `SF_IMMUTABLE` — Finder's "Locked" checkbox.
    public var isImmutable: Bool
    /// `access(W_OK)` on the file itself.
    public var isFileWritable: Bool
    /// `access(W_OK)` on the *containing directory*.
    ///
    /// Separate from ``isFileWritable`` because an atomic replace creates and renames a
    /// sibling: a writable file in a read-only directory cannot be saved (PLAN.md §5.2), and
    /// discovering that only at save time means telling the user after they typed.
    public var isDirectoryWritable: Bool

    public init(fingerprint: FileFingerprint, isImmutable: Bool, isFileWritable: Bool, isDirectoryWritable: Bool) {
        self.fingerprint = fingerprint
        self.isImmutable = isImmutable
        self.isFileWritable = isFileWritable
        self.isDirectoryWritable = isDirectoryWritable
    }

    /// Whether ``AtomicWriter`` could complete a save right now.
    public var isWritable: Bool { !isImmutable && isFileWritable && isDirectoryWritable }

    /// Reads `url`'s current condition without ever throwing.
    ///
    /// Returns rather than throws because every caller has to handle every outcome anyway —
    /// a missing file is a state the document enters, not an error it reports.
    public static func probe(
        _ url: URL,
        headByteCount: Int = FileFingerprint.defaultHeadByteCount
    ) -> FileCondition {
        let path = url.path(percentEncoded: false)
        var status = stat()

        guard lstat(path, &status) == 0 else {
            return classifyMissing(url: url, path: path, errno: errno)
        }
        if (status.st_mode & S_IFMT) == S_IFLNK {
            // A symlink to somewhere real is fine — `capture` follows it. A dangling one is
            // not, and `stat` is what tells them apart.
            guard stat(path, &status) == 0 else {
                return classifyMissing(url: url, path: path, errno: errno)
            }
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            let kind = (status.st_mode & S_IFMT) == S_IFDIR ? "it is a directory" : "it is not a regular file"
            return .unreadable(.fileNotReadable(path: path, underlying: kind))
        }
        if isPlaceholder(url) { return .notDownloaded }

        let fingerprint: FileFingerprint
        do {
            fingerprint = try FileFingerprint.capture(at: url, headByteCount: headByteCount)
        } catch {
            // The file was there a syscall ago. Losing the race with a delete is normal
            // during someone else's save, and is a `missing`, not a failure.
            if case .fileVanished = error { return .missing }
            return .unreadable(error)
        }

        let immutable = (status.st_flags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE))) != 0
        let directory = url.deletingLastPathComponent().path(percentEncoded: false)
        return .readable(FileProbe(
            fingerprint: fingerprint,
            isImmutable: immutable,
            isFileWritable: access(path, W_OK) == 0,
            isDirectoryWritable: access(directory, W_OK) == 0
        ))
    }

    /// Distinguishes "deleted" from "the disk it lived on was ejected" from "iCloud has not
    /// downloaded it yet". PLAN.md §9 lists all three as cases that must not read as a crash.
    private static func classifyMissing(url: URL, path: String, errno code: Int32) -> FileCondition {
        switch code {
        case ENOENT:
            if isPlaceholder(url) { return .notDownloaded }
            return isVolumeReachable(url) ? .missing : .volumeUnavailable
        case ENOTDIR:
            return .missing
        case EACCES, EPERM:
            return .unreadable(.fileNotReadable(path: path, underlying: "permission denied"))
        case ENXIO, ENODEV, ETIMEDOUT, EHOSTDOWN, ESTALE:
            return .volumeUnavailable
        case ENAMETOOLONG:
            return .unreadable(.fileNotReadable(path: path, underlying: "the path is too long"))
        default:
            return .unreadable(.fileNotReadable(path: path, underlying: String(cString: strerror(code))))
        }
    }

    /// Whether the volume the path lives on is still mounted.
    ///
    /// Walks up to the nearest existing ancestor: if not even `/Volumes/Backup` is there, the
    /// disk went away, and telling the user "file missing" would send them looking in the
    /// wrong place.
    private static func isVolumeReachable(_ url: URL) -> Bool {
        var directory = url.deletingLastPathComponent()
        var hops = 0
        while hops < 64 {
            let path = directory.path(percentEncoded: false)
            if path.isEmpty || path == "/" { return true }
            var status = stat()
            if stat(path, &status) == 0 { return true }
            if errno != ENOENT, errno != ENOTDIR { return false }
            let parent = directory.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == path { return true }
            directory = parent
            hops += 1
        }
        return true
    }

    /// An iCloud Drive file that has not been materialised.
    ///
    /// Two independent signals, because they do not always agree: the ubiquity resource key
    /// (which needs the file to still be enumerable) and the `.name.icloud` sibling stub that
    /// is what actually sits on disk when the payload has been evicted.
    private static func isPlaceholder(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            return true
        }
        let stub = url
            .deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud")
        var status = stat()
        return lstat(stub.path(percentEncoded: false), &status) == 0
    }
}
