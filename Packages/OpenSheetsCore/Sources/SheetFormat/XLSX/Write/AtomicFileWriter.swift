//
//  AtomicFileWriter.swift
//  SheetFormat
//
//  Never write in place. Ever.
//

import CryptoKit
import Darwin
import Foundation
import SheetModel

/// What a file looked like immediately after OpenSheets wrote it.
///
/// A6's watcher sees its own saves as filesystem events like anyone else's. Comparing the event
/// against this is what stops a save from triggering a reload that triggers a diff that asks the
/// user to accept their own edit (PLAN.md §6.2).
///
/// All four fields are here because none of them is sufficient alone. `mtime` has one-second
/// resolution on some volumes and goes backwards under clock skew. `size` collides constantly.
/// The inode changes on every atomic replace, which is exactly what makes it useful — a matching
/// inode *and* hash means this is our file, untouched. The hash is the last word and the only
/// one that cannot coincide.
public struct SavedFileFingerprint: Sendable, Hashable, Codable {
    /// The file's path at the moment of writing.
    public var path: String
    /// The inode the file has after the atomic replace, which is a **new** one.
    public var inode: UInt64
    /// The device the file lives on, so an inode number means something.
    public var deviceID: UInt64
    /// The modification time the filesystem recorded.
    public var modificationDate: Date
    /// Bytes on disk.
    public var size: Int
    /// SHA-256 of the bytes, lowercase hex.
    public var contentHash: String
    /// When OpenSheets finished the write, by its own clock.
    public var writtenAt: Date

    public init(
        path: String,
        inode: UInt64,
        deviceID: UInt64,
        modificationDate: Date,
        size: Int,
        contentHash: String,
        writtenAt: Date
    ) {
        self.path = path
        self.inode = inode
        self.deviceID = deviceID
        self.modificationDate = modificationDate
        self.size = size
        self.contentHash = contentHash
        self.writtenAt = writtenAt
    }

    /// Whether `other` describes the same bytes at the same place.
    ///
    /// Compares the hash rather than the timestamps, because a copy-on-write clone, a Time
    /// Machine restore and a cloud-sync round trip can all change the metadata without changing
    /// a byte.
    public func matches(_ other: SavedFileFingerprint) -> Bool {
        path == other.path && size == other.size && contentHash == other.contentHash
    }

    /// SHA-256 of `data`, lowercase hex — the same spelling the fixture sidecars use.
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Writes a file atomically, or leaves the original exactly as it was.
///
/// The sequence, in this order, for the reasons given:
///
/// 1. **Write a temp file in the same directory.** Same directory because `rename(2)` is only
///    atomic within a filesystem, and `/tmp` is routinely a different one.
/// 2. **`fsync` the file.** Otherwise the rename can land before the data does, and a power cut
///    in between leaves a correctly-named file full of zeroes.
/// 3. **`fsync` the directory.** The rename itself is metadata, and metadata needs its own
///    barrier.
/// 4. **Copy permissions, ownership and extended attributes** from the original. Extended
///    attributes are not a detail: Finder tags live there, and so do quarantine flags and
///    cloud-provider bookkeeping.
/// 5. **`FileManager.replaceItemAt`.**
///
/// Every failure path deletes the temp file. A directory quietly filling with
/// `.opensheets-*.tmp` after failed saves is its own bug.
public enum AtomicFileWriter {
    /// A point in the sequence, for tests that need to interrupt it.
    public enum Phase: String, Sendable, Hashable, CaseIterable {
        case temporaryFileWritten
        case temporaryFileSynced
        case metadataCopied
        case beforeReplace
    }

    /// Writes `data` to `url`, atomically.
    ///
    /// `interrupt` is a test seam: it runs at each ``Phase`` and anything it throws aborts the
    /// save from that point, which is how "killing the process between temp-write and replace
    /// leaves the original intact" gets asserted rather than assumed.
    @discardableResult
    public static func write(
        _ data: Data,
        to url: URL,
        interrupt: ((Phase) throws -> Void)? = nil
    ) throws(SheetError) -> SavedFileFingerprint {
        let directory = url.deletingLastPathComponent()
        let path = url.path
        let temporaryURL = directory.appendingPathComponent(temporaryName())

        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw SheetError.fileVanished(path: directory.path)
        }

        var temporaryExists = false
        func cleanUp() {
            guard temporaryExists else { return }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            try writeAndSync(data, to: temporaryURL)
            temporaryExists = true
            try interrupt?(.temporaryFileWritten)
            try syncDirectory(directory)
            try interrupt?(.temporaryFileSynced)
            copyMetadata(from: url, to: temporaryURL)
            try interrupt?(.metadataCopied)
            try interrupt?(.beforeReplace)

            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            temporaryExists = false
            try syncDirectory(directory)
        } catch let error as SheetError {
            cleanUp()
            throw error
        } catch {
            cleanUp()
            throw SheetError.atomicReplaceFailed(path: path, underlying: "\(error)")
        }

        return try fingerprint(of: url, data: data)
    }

    /// The fingerprint of a file that is already on disk.
    public static func fingerprint(of url: URL, data: Data? = nil) throws(SheetError) -> SavedFileFingerprint {
        var status = stat()
        guard stat(url.path, &status) == 0 else {
            throw SheetError.fileVanished(path: url.path)
        }
        let bytes: Data
        if let data {
            bytes = data
        } else {
            do {
                bytes = try Data(contentsOf: url)
            } catch {
                throw SheetError.fileNotReadable(path: url.path, underlying: "\(error)")
            }
        }
        return SavedFileFingerprint(
            path: url.path,
            inode: UInt64(status.st_ino),
            deviceID: UInt64(bitPattern: Int64(status.st_dev)),
            modificationDate: Date(
                timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
                    + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
            ),
            size: bytes.count,
            contentHash: SavedFileFingerprint.hash(bytes),
            writtenAt: Date()
        )
    }

    // MARK: - Steps

    private static func temporaryName() -> String {
        // A ULID-shaped name: millisecond timestamp, then randomness. Sorts by creation time,
        // which makes an abandoned temp file's age obvious at a glance.
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        let random = (0 ..< 8).map { _ in String(UInt8.random(in: 0 ... 255), radix: 36) }.joined()
        return ".opensheets-\(String(milliseconds, radix: 36))\(random).tmp"
    }

    private static func writeAndSync(_ data: Data, to url: URL) throws(SheetError) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw posixError(errno, path: url.path) }

        var writeFailure: SheetError?
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.baseAddress
            while offset < raw.count {
                let written = Darwin.write(descriptor, base?.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    writeFailure = posixError(errno, path: url.path)
                    return
                }
                offset += written
            }
        }
        if writeFailure == nil, fsync(descriptor) != 0 {
            writeFailure = posixError(errno, path: url.path)
        }
        close(descriptor)
        if let writeFailure {
            try? FileManager.default.removeItem(at: url)
            throw writeFailure
        }
    }

    private static func syncDirectory(_ url: URL) throws(SheetError) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw posixError(errno, path: url.path) }
        defer { close(descriptor) }
        // A rename is a metadata change in the *directory*, so the directory needs its own
        // barrier. Skipping this is the classic "the file is there but it is empty" bug.
        guard fsync(descriptor) == 0 else { throw posixError(errno, path: url.path) }
    }

    /// Copies mode, ownership and every extended attribute from `source` onto `destination`.
    ///
    /// Best effort by design. Ownership needs privileges we usually do not have, and a failure
    /// to set a Finder tag is not a reason to abandon a save the user asked for — but silently
    /// dropping them all, which is what a naive write-and-rename does, loses work.
    private static func copyMetadata(from source: URL, to destination: URL) {
        var status = stat()
        guard stat(source.path, &status) == 0 else { return }
        chmod(destination.path, status.st_mode & 0o7777)
        chown(destination.path, status.st_uid, status.st_gid)
        copyExtendedAttributes(from: source.path, to: destination.path)
    }

    private static func copyExtendedAttributes(from source: String, to destination: String) {
        let listSize = listxattr(source, nil, 0, XATTR_NOFOLLOW)
        guard listSize > 0 else { return }
        var names = [CChar](repeating: 0, count: listSize)
        guard listxattr(source, &names, listSize, XATTR_NOFOLLOW) == listSize else { return }

        var start = 0
        for index in 0 ..< listSize where names[index] == 0 {
            let name = String(decoding: names[start ..< index].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            start = index + 1
            guard !name.isEmpty else { continue }
            let valueSize = getxattr(source, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard valueSize >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: max(valueSize, 1))
            guard getxattr(source, name, &value, valueSize, 0, XATTR_NOFOLLOW) == valueSize else { continue }
            _ = setxattr(destination, name, value, valueSize, 0, XATTR_NOFOLLOW)
        }
    }

    // MARK: - Errors

    /// Maps `errno` onto the ``SheetError`` case that says something useful.
    ///
    /// PLAN.md §9 names these individually because the user-facing message differs: a full disk
    /// wants "free some space", a permission failure wants "this file is read-only", and a
    /// vanished volume wants "reconnect the drive". "Operation failed (errno 28)" wants nothing.
    static func posixError(_ code: Int32, path: String) -> SheetError {
        switch code {
        case ENOSPC, EDQUOT: .diskFull(path: path)
        case EACCES, EPERM, EROFS: .fileNotWritable(path: path, underlying: describe(code))
        case ENOENT: .fileVanished(path: path)
        case ENOTCONN, ENODEV, EHOSTDOWN: .volumeUnavailable(path: path)
        case ETXTBSY, EBUSY: .fileLocked(path: path)
        default: .fileNotWritable(path: path, underlying: describe(code))
        }
    }

    private static func describe(_ code: Int32) -> String {
        guard let message = strerror(code) else { return "errno \(code)" }
        return String(cString: message)
    }
}
