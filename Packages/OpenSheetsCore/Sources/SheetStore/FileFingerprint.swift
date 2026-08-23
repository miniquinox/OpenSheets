import CryptoKit
import Darwin
import Foundation
import SheetModel

/// A filesystem timestamp kept at its native nanosecond resolution.
///
/// Deliberately **not** a `Date`. `Date` is a `Double` of seconds since 2001, and at 2026-era
/// epoch values a `Double` cannot represent nanoseconds — two saves 40 µs apart round to the
/// same `Date`. Since ``FileFingerprint`` equality is what stops the app refresh-looping after
/// every save, losing that resolution turns a correctness property into a coin flip.
public struct FileTimestamp: Sendable, Hashable, Codable, Comparable {
    /// Whole seconds since the Unix epoch.
    public var seconds: Int64
    /// Nanoseconds within the second, `0 ..< 1_000_000_000`.
    public var nanoseconds: Int64

    public init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    init(_ spec: timespec) {
        seconds = Int64(spec.tv_sec)
        nanoseconds = Int64(spec.tv_nsec)
    }

    /// The lossy `Date` form, for display only. Never compare two of these.
    public var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }

    public static func < (lhs: FileTimestamp, rhs: FileTimestamp) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }
}

/// Everything we need to decide "is this the same file, in the same state, as last time?".
///
/// Two jobs, and they pull in the same direction:
///
/// 1. **Change detection** (PLAN.md §6.1). The watcher compares this before doing any real
///    work, so a `touch` or an `.attrib` event does not cost a full reparse.
/// 2. **Self-write suppression** (PLAN.md §6.2). Every save records the fingerprint it
///    produced; the watcher drops events whose observed fingerprint matches. Without it the
///    app refreshes itself in a loop after every save.
///
/// ``deviceID`` is part of the identity because an inode number is only unique within a
/// volume — `/Volumes/A/x.xlsx` and `/Volumes/B/y.xlsx` collide on inode alone, and a
/// fingerprint that matches across volumes would suppress a real external write.
///
/// **A2 bridging note:** this is the type the atomic writer must return. If A2's writer
/// produces its own fingerprint shape, bridge it here rather than duplicating the concept —
/// ``AtomicWriter/write(_:to:options:)`` already returns exactly this.
public struct FileFingerprint: Sendable, Hashable, Codable {
    /// `st_dev`. Inodes are only unique per volume, so identity needs both.
    public var deviceID: UInt64
    /// `st_ino`.
    public var inode: UInt64
    /// `st_size`.
    public var size: Int64
    /// `st_mtimespec`, at full nanosecond resolution. See ``FileTimestamp``.
    public var modified: FileTimestamp
    /// SHA-256 of the first ``headByteCount`` bytes, folded to its leading 64 bits.
    ///
    /// Catches the case a `stat` alone misses: a writer that rewrote the file to the same
    /// length within the same nanosecond. It also catches a *truncated* file mid-write, which
    /// is what ``FileWatcher`` uses to back off and retry instead of handing a half-written
    /// archive to the parser.
    public var headHash: UInt64
    /// How many bytes ``headHash`` covers. Part of the value because comparing two
    /// fingerprints taken with different head sizes would be meaningless.
    public var headByteCount: Int

    public init(
        deviceID: UInt64,
        inode: UInt64,
        size: Int64,
        modified: FileTimestamp,
        headHash: UInt64,
        headByteCount: Int
    ) {
        self.deviceID = deviceID
        self.inode = inode
        self.size = size
        self.modified = modified
        self.headHash = headHash
        self.headByteCount = headByteCount
    }

    /// Default bytes hashed. PLAN.md §6.1 says "first-4KB hash".
    public static let defaultHeadByteCount = 4096

    /// Reads the current state of `url`.
    ///
    /// Follows symlinks on purpose: opening `~/link.xlsx` should fingerprint the file the link
    /// points at, so an edit made through either path is seen.
    public static func capture(
        at url: URL,
        headByteCount: Int = FileFingerprint.defaultHeadByteCount
    ) throws(SheetError) -> FileFingerprint {
        let path = url.path(percentEncoded: false)
        let descriptor = open(path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw openFailure(path: path, errno: errno) }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw SheetError.fileNotReadable(path: path, underlying: String(cString: strerror(errno)))
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw SheetError.fileNotReadable(
                path: path,
                underlying: (status.st_mode & S_IFMT) == S_IFDIR ? "it is a directory" : "it is not a regular file"
            )
        }

        var head = [UInt8](repeating: 0, count: max(0, headByteCount))
        var filled = 0
        var failure: Int32 = 0
        head.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while filled < buffer.count {
                let read = Darwin.read(descriptor, base.advanced(by: filled), buffer.count - filled)
                if read > 0 {
                    filled += read
                } else if read == 0 {
                    return
                } else if errno != EINTR {
                    failure = errno
                    return
                }
            }
        }
        if failure != 0 {
            throw SheetError.fileNotReadable(path: path, underlying: String(cString: strerror(failure)))
        }

        return FileFingerprint(
            deviceID: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino),
            size: Int64(status.st_size),
            modified: FileTimestamp(status.st_mtimespec),
            headHash: FileFingerprint.hash(head.prefix(filled)),
            headByteCount: headByteCount
        )
    }

    /// SHA-256 folded to 64 bits.
    ///
    /// Not `Hasher`: that is seeded per process, and this value is compared between the app
    /// and `opensheets-mcp`, which are two processes (PLAN.md §5.5).
    static func hash(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var digest = SHA256()
        digest.update(data: Data(bytes))
        var result: UInt64 = 0
        for byte in digest.finalize().prefix(8) { result = (result << 8) | UInt64(byte) }
        return result
    }

    static func openFailure(path: String, errno code: Int32) -> SheetError {
        switch code {
        case ENOENT: .fileVanished(path: path)
        case EACCES, EPERM: .fileNotReadable(path: path, underlying: "permission denied")
        case ENXIO, ENODEV: .volumeUnavailable(path: path)
        case EISDIR: .fileNotReadable(path: path, underlying: "it is a directory")
        default: .fileNotReadable(path: path, underlying: String(cString: strerror(code)))
        }
    }
}

extension FileFingerprint: CustomStringConvertible {
    public var description: String {
        "\(deviceID):\(inode) \(size)B @\(modified.seconds).\(modified.nanoseconds) #\(String(headHash, radix: 16))"
    }
}
