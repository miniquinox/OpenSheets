//
//  Reader.swift
//  MiniZip
//
//  A1 owns this file. A2 owns `Writer.swift`; we share the target and nothing else.
//

import Foundation

import SheetModel

/// A ZIP archive opened for reading: every entry's metadata and its **still-compressed** bytes.
///
/// Nothing is inflated by opening one. That is deliberate and is the difference between opening
/// `Fixtures/hostile/zip-bomb-nested.xlsx` (a valid workbook with a 1030:1 bomb parked in
/// `xl/media/`) and refusing it. Inflation happens per entry, on demand, under
/// ``DecompressionBudget``.
public struct ZipArchive: Sendable {
    /// Entries in the archive's original central-directory order.
    public let entries: [ZipEntry]

    /// The shared allowance every ``bytes(of:)`` charges against.
    public let budget: DecompressionBudget

    /// Per-entry caps.
    public let caps: InflateCaps

    /// A name for this archive in error messages — normally the file's path.
    public let name: String

    private let index: [String: Int]

    init(entries: [ZipEntry], name: String, caps: InflateCaps, budget: DecompressionBudget) {
        self.entries = entries
        self.name = name
        self.caps = caps
        self.budget = budget
        var built = [String: Int](minimumCapacity: entries.count)
        for (position, entry) in entries.enumerated() {
            built[entry.path] = position
        }
        index = built
    }

    /// The entry at `path`, or `nil`.
    public subscript(path: String) -> ZipEntry? {
        index[path].map { entries[$0] }
    }

    /// Whether the archive holds an entry with this exact name.
    public func contains(_ path: String) -> Bool { index[path] != nil }

    /// Inflates one entry, verifying its CRC-32 and its declared size.
    ///
    /// Throws ``SheetError/archiveEntryNotFound(path:)`` rather than returning `nil`, because
    /// every call site that reaches here has already decided the part must exist.
    public func bytes(of path: String) throws(SheetError) -> [UInt8] {
        guard let entry = self[path] else { throw SheetError.archiveEntryNotFound(path: path) }
        return try bytes(of: entry)
    }

    /// Inflates one entry, or returns `nil` when the archive does not hold it.
    public func bytesIfPresent(of path: String) throws(SheetError) -> [UInt8]? {
        guard self[path] != nil else { return nil }
        return try bytes(of: path)
    }

    /// Inflates `entry`, verifying its CRC-32 and its declared size.
    public func bytes(of entry: ZipEntry) throws(SheetError) -> [UInt8] {
        let inflated: [UInt8] = switch entry.compressionMethod {
        case .store:
            try Inflate.copyStored(
                entry.compressedData, declaredSize: entry.uncompressedSize,
                path: entry.path, caps: caps, budget: budget
            )
        case .deflate:
            try Inflate.inflate(
                entry.compressedData, declaredSize: entry.uncompressedSize,
                path: entry.path, caps: caps, budget: budget
            )
        case let .other(method):
            throw SheetError.archiveUnsupportedCompression(path: entry.path, method: method)
        }

        let actual = Inflate.crc32(inflated)
        guard actual == entry.crc32 else {
            throw SheetError.archiveChecksumMismatch(path: entry.path, expected: entry.crc32, actual: actual)
        }
        return inflated
    }

    /// Every entry, ready to hand to ``SheetModel/OpaqueParts``.
    ///
    /// `modelled` is the set of paths the caller regenerates on write; everything else is copied
    /// through byte-identical.
    public func opaqueParts(modelled: Set<String> = []) -> OpaqueParts {
        OpaqueParts(entries: entries, modelled: modelled)
    }
}

/// Reads a ZIP archive's central directory.
///
/// # What this refuses, and why
///
/// A spreadsheet is untrusted input (PLAN.md §7.4), and an `.xlsx` is a ZIP with a friendly
/// extension. Every rejection below has a fixture behind it in `Fixtures/hostile/`:
///
/// - more than ``SheetModel/Limits/maxArchiveEntries`` entries, checked from the
///   end-of-central-directory count **and** while walking, so 12,004 entries never become
///   12,004 allocations;
/// - an entry name containing `..`, a leading separator, a Windows drive letter, or a NUL —
///   validated as raw bytes, before any decoding, because a poisoned NUL exists precisely to
///   make a C-string API and a ZIP index disagree;
/// - two entries with the same name, which is ambiguous by construction;
/// - a compression method other than store or deflate.
///
/// Size and ratio caps are **not** here. They belong at inflate time, per entry, on the entries
/// somebody actually asked for — see ``Inflate``.
public enum ZipReader {
    /// Opens the archive at `url`, memory-mapping it where the OS says that is safe.
    public static func read(
        contentsOf url: URL,
        caps: InflateCaps = .standard,
        budget: DecompressionBudget? = nil
    ) throws(SheetError) -> ZipArchive {
        let path = url.path(percentEncoded: false)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw SheetError.fileNotFound(path: path)
        } catch {
            throw SheetError.fileNotReadable(path: path, underlying: error.localizedDescription)
        }
        guard data.count <= Limits.maxFileBytes else {
            throw SheetError.fileTooLarge(path: path, bytes: data.count, limit: Limits.maxFileBytes)
        }
        return try read(data, name: path, caps: caps, budget: budget)
    }

    /// Opens an archive already in memory. `name` only ever appears in error messages.
    public static func read(
        _ data: Data,
        name: String,
        caps: InflateCaps = .standard,
        budget: DecompressionBudget? = nil
    ) throws(SheetError) -> ZipArchive {
        let layout = try parse(data)
        var entries = [ZipEntry]()
        entries.reserveCapacity(layout.records.count)
        let base = data.startIndex
        for record in layout.records {
            entries.append(
                ZipEntry(
                    path: record.name,
                    compressedData: data[(base + record.dataOffset) ..< (base + record.dataOffset + record.dataLength)],
                    compressionMethod: record.method,
                    crc32: record.crc32,
                    compressedSize: record.compressedSize,
                    uncompressedSize: record.uncompressedSize,
                    lastModified: DOSTimestamp(date: record.modifiedDate, time: record.modifiedTime),
                    extendedModificationDate: record.extendedModificationDate,
                    generalPurposeFlags: record.flags,
                    versionMadeBy: record.versionMadeBy,
                    versionNeeded: record.versionNeeded,
                    externalAttributes: record.externalAttributes,
                    internalAttributes: record.internalAttributes,
                    extraFieldLocal: data[(base + record.localExtraOffset) ..<
                        (base + record.localExtraOffset + record.localExtraLength)],
                    extraFieldCentral: data[(base + record.centralExtraOffset) ..<
                        (base + record.centralExtraOffset + record.centralExtraLength)],
                    comment: record.comment
                )
            )
        }
        return ZipArchive(
            entries: entries, name: name, caps: caps, budget: budget ?? DecompressionBudget()
        )
    }

    // MARK: - Central directory

    /// One central-directory entry, resolved down to byte offsets into the file.
    private struct Record {
        var name: String
        var method: CompressionMethod
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var modifiedDate: UInt16
        var modifiedTime: UInt16
        var extendedModificationDate: Date?
        var flags: UInt16
        var versionMadeBy: UInt16
        var versionNeeded: UInt16
        var externalAttributes: UInt32
        var internalAttributes: UInt16
        var comment: String?
        var dataOffset: Int
        var dataLength: Int
        var localExtraOffset: Int
        var localExtraLength: Int
        var centralExtraOffset: Int
        var centralExtraLength: Int
    }

    private struct Layout {
        var records: [Record]
    }

    private static func parse(_ data: Data) throws(SheetError) -> Layout {
        var thrown: SheetError?
        var layout = Layout(records: [])
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            do {
                layout = try parse(raw)
            } catch {
                // The closure is not typed-throwing, so the binding widens to `any Error`.
                thrown = error as? SheetError ?? .internalInconsistency(detail: "\(error)")
            }
        }
        if let thrown { throw thrown }
        return layout
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func parse(_ bytes: UnsafeRawBufferPointer) throws(SheetError) -> Layout {
        let size = bytes.count
        guard size >= ZipFormat.endOfCentralDirectorySize else {
            throw looksLikeZip(bytes)
                ? SheetError.archiveTruncated(detail: "the file is \(size) bytes, too short to hold a ZIP directory")
                : SheetError.archiveMalformed(detail: "not a ZIP archive: the file is only \(size) bytes")
        }

        guard let eocd = findEndOfCentralDirectory(bytes) else {
            throw looksLikeZip(bytes)
                ? SheetError.archiveTruncated(detail: "no end-of-central-directory record; the file is incomplete")
                : SheetError.archiveMalformed(detail: "not a ZIP archive: no PK\\5\\6 signature")
        }

        var totalEntries = Int(read16(bytes, eocd + 10))
        var directorySize = Int(read32(bytes, eocd + 12))
        var directoryOffset = Int(read32(bytes, eocd + 16))

        // Zip64. PLAN.md only mentions it for the writer; the read side needs it too, or a
        // >4 GB archive — and `hostile/lying-uncompressed-size.xlsx`, which hides its claim in a
        // Zip64 extra field — reads as corrupt.
        if totalEntries == Int(ZipFormat.zip64Sentinel16)
            || directorySize == Int(ZipFormat.zip64Sentinel32)
            || directoryOffset == Int(ZipFormat.zip64Sentinel32) {
            guard eocd >= 20,
                  read32(bytes, eocd - 20) == ZipFormat.zip64EndOfCentralDirectoryLocatorSignature
            else {
                throw SheetError.archiveMalformed(detail: "Zip64 sizes are declared but the Zip64 locator is missing")
            }
            let recordOffset = Int(clamping: read64(bytes, eocd - 20 + 8))
            guard recordOffset >= 0, recordOffset + 56 <= size,
                  read32(bytes, recordOffset) == ZipFormat.zip64EndOfCentralDirectorySignature
            else {
                throw SheetError.archiveMalformed(detail: "the Zip64 end-of-central-directory record is unreadable")
            }
            totalEntries = Int(clamping: read64(bytes, recordOffset + 32))
            directorySize = Int(clamping: read64(bytes, recordOffset + 40))
            directoryOffset = Int(clamping: read64(bytes, recordOffset + 48))
        }

        guard totalEntries >= 0, directorySize >= 0, directoryOffset >= 0 else {
            throw SheetError.archiveMalformed(detail: "the central directory has a negative size or offset")
        }
        // Enforce the count from the header, before allocating anything sized by it.
        guard totalEntries <= Limits.maxArchiveEntries else {
            throw SheetError.archiveTooManyEntries(count: totalEntries, limit: Limits.maxArchiveEntries)
        }
        guard directoryOffset + directorySize <= size else {
            throw SheetError.archiveTruncated(
                detail: "the central directory runs past the end of the file"
            )
        }

        // Some archives carry prepended data (self-extracting stubs), which shifts every
        // recorded offset by a constant. Recover it rather than declaring the file corrupt.
        var shift = 0
        if directoryOffset + 4 > size || read32(bytes, directoryOffset) != ZipFormat.centralDirectorySignature {
            let recovered = eocd - directorySize - directoryOffset
            guard recovered > 0, directoryOffset + recovered + 4 <= size,
                  read32(bytes, directoryOffset + recovered) == ZipFormat.centralDirectorySignature
            else {
                throw SheetError.archiveMalformed(detail: "the central directory is not where the archive says it is")
            }
            shift = recovered
        }

        var records = [Record]()
        records.reserveCapacity(min(totalEntries, 1024))
        var seen = Set<String>(minimumCapacity: min(totalEntries, 1024))
        var cursor = directoryOffset + shift

        for _ in 0 ..< totalEntries {
            guard cursor + ZipFormat.centralDirectoryEntrySize <= size,
                  read32(bytes, cursor) == ZipFormat.centralDirectorySignature
            else {
                throw SheetError.archiveTruncated(detail: "the central directory ends after \(records.count) entries")
            }
            // Belt and braces: the header count can lie, so cap while walking too.
            guard records.count < Limits.maxArchiveEntries else {
                throw SheetError.archiveTooManyEntries(count: records.count + 1, limit: Limits.maxArchiveEntries)
            }

            let versionMadeBy = read16(bytes, cursor + 4)
            let versionNeeded = read16(bytes, cursor + 6)
            let flags = read16(bytes, cursor + 8)
            let method = CompressionMethod(rawValue: read16(bytes, cursor + 10))
            let modifiedTime = read16(bytes, cursor + 12)
            let modifiedDate = read16(bytes, cursor + 14)
            let crc = read32(bytes, cursor + 16)
            var compressedSize = UInt64(read32(bytes, cursor + 20))
            var uncompressedSize = UInt64(read32(bytes, cursor + 24))
            let nameLength = Int(read16(bytes, cursor + 28))
            let extraLength = Int(read16(bytes, cursor + 30))
            let commentLength = Int(read16(bytes, cursor + 32))
            let internalAttributes = read16(bytes, cursor + 36)
            let externalAttributes = read32(bytes, cursor + 38)
            var localHeaderOffset = UInt64(read32(bytes, cursor + 42))

            let nameOffset = cursor + ZipFormat.centralDirectoryEntrySize
            let extraOffset = nameOffset + nameLength
            let commentOffset = extraOffset + extraLength
            let nextCursor = commentOffset + commentLength
            guard nextCursor <= size else {
                throw SheetError.archiveTruncated(detail: "a central directory entry runs past the end of the file")
            }

            let nameBytes = UnsafeRawBufferPointer(rebasing: bytes[nameOffset ..< extraOffset])
            let name = try validatedName(nameBytes, isUTF8: (flags & (1 << 11)) != 0)
            guard seen.insert(name).inserted else {
                throw SheetError.archiveDuplicateEntry(name: name)
            }

            let extra = UnsafeRawBufferPointer(rebasing: bytes[extraOffset ..< commentOffset])
            applyZip64Extra(
                extra,
                compressedSize: &compressedSize,
                uncompressedSize: &uncompressedSize,
                localHeaderOffset: &localHeaderOffset
            )
            let extendedDate = extendedTimestamp(extra)

            // An unsupported method is *not* rejected here. Only store and deflate occur in
            // OOXML, but the archive is still copyable through `OpaqueParts`, and refusing to
            // open a file over an entry we were never going to read contradicts the same
            // laziness that lets `hostile/zip-bomb-nested.xlsx` open. The refusal lives in
            // ``ZipArchive/bytes(of:)-(ZipEntry)``, where someone actually asked for the bytes.

            let localOffset = Int(clamping: localHeaderOffset) + shift
            guard localOffset >= 0, localOffset + ZipFormat.localFileHeaderSize <= size,
                  read32(bytes, localOffset) == ZipFormat.localFileHeaderSignature
            else {
                throw SheetError.archiveTruncated(detail: "'\(name)' has no local file header at its recorded offset")
            }
            let localNameLength = Int(read16(bytes, localOffset + 26))
            let localExtraLength = Int(read16(bytes, localOffset + 28))
            let localExtraOffset = localOffset + ZipFormat.localFileHeaderSize + localNameLength
            let dataOffset = localExtraOffset + localExtraLength
            let dataLength = Int(clamping: compressedSize)
            guard dataOffset >= 0, dataLength >= 0, dataOffset + dataLength <= size else {
                throw SheetError.archiveTruncated(detail: "'\(name)' claims \(dataLength) bytes that are not there")
            }

            records.append(
                Record(
                    name: name,
                    method: method,
                    crc32: crc,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    modifiedDate: modifiedDate,
                    modifiedTime: modifiedTime,
                    extendedModificationDate: extendedDate,
                    flags: flags,
                    versionMadeBy: versionMadeBy,
                    versionNeeded: versionNeeded,
                    externalAttributes: externalAttributes,
                    internalAttributes: internalAttributes,
                    comment: commentLength == 0
                        ? nil
                        : decodeName(
                            UnsafeRawBufferPointer(rebasing: bytes[commentOffset ..< nextCursor]), isUTF8: true
                        ),
                    dataOffset: dataOffset,
                    dataLength: dataLength,
                    localExtraOffset: localExtraOffset,
                    localExtraLength: localExtraLength,
                    centralExtraOffset: extraOffset,
                    centralExtraLength: extraLength
                )
            )
            cursor = nextCursor
        }

        return Layout(records: records)
    }

    // MARK: - Entry names

    /// Validates an entry name **as bytes**, then decodes it.
    ///
    /// Byte-first is the whole point: `xl/worksheets/sheet1.xml\0.png` decodes to something a
    /// `strlen`-based API would happily treat as `xl/worksheets/sheet1.xml`, and that
    /// disagreement is the attack. OpenSheets never extracts to disk, but `OpaqueParts` is keyed
    /// by these names and A2 writes them back out, so a traversal name must never get that far.
    private static func validatedName(
        _ bytes: UnsafeRawBufferPointer,
        isUTF8: Bool
    ) throws(SheetError) -> String {
        guard !bytes.isEmpty else {
            throw SheetError.archiveMalformed(detail: "an entry has an empty name")
        }
        let name = decodeName(bytes, isUTF8: isUTF8)

        for byte in bytes where byte == 0 {
            throw SheetError.archivePathTraversal(entryName: name)
        }
        let first = bytes[0]
        if first == UInt8(ascii: "/") || first == UInt8(ascii: "\\") {
            throw SheetError.archivePathTraversal(entryName: name)
        }
        // A Windows drive letter — `C:\Windows\…` — is absolute even without a leading slash.
        if bytes.count >= 2, bytes[1] == UInt8(ascii: ":"),
           (first | 0x20) >= UInt8(ascii: "a"), (first | 0x20) <= UInt8(ascii: "z") {
            throw SheetError.archivePathTraversal(entryName: name)
        }
        // `..` as a whole path component, under either separator. A name that merely *contains*
        // two dots (`report..final.xml`) is legal and must not be rejected.
        var componentStart = 0
        var position = 0
        while position <= bytes.count {
            let atEnd = position == bytes.count
            if atEnd || bytes[position] == UInt8(ascii: "/") || bytes[position] == UInt8(ascii: "\\") {
                if position - componentStart == 2,
                   bytes[componentStart] == UInt8(ascii: "."), bytes[componentStart + 1] == UInt8(ascii: ".") {
                    throw SheetError.archivePathTraversal(entryName: name)
                }
                componentStart = position + 1
            }
            position += 1
        }
        return name
    }

    private static func decodeName(_ bytes: UnsafeRawBufferPointer, isUTF8: Bool) -> String {
        let buffer = bytes.bindMemory(to: UInt8.self)
        if isUTF8 || bytes.allSatisfy({ $0 < 0x80 }) {
            if let text = String(bytes: buffer, encoding: .utf8) { return text }
        }
        // Not valid UTF-8 and not flagged as such: the format says CP437. Latin-1 agrees with
        // CP437 across every byte an OOXML producer realistically emits and never fails, which
        // matters more here than exactness — a name we cannot decode is a name we cannot
        // round-trip.
        return String(bytes: buffer, encoding: .isoLatin1) ?? String(decoding: buffer, as: UTF8.self)
    }

    // MARK: - Extra fields

    private static func applyZip64Extra(
        _ extra: UnsafeRawBufferPointer,
        compressedSize: inout UInt64,
        uncompressedSize: inout UInt64,
        localHeaderOffset: inout UInt64
    ) {
        forEachExtraField(extra) { id, payload in
            guard id == ZipFormat.zip64ExtraFieldID else { return }
            var offset = 0
            // The fields appear in a fixed order, but only those whose 32-bit counterpart held
            // the sentinel are actually present.
            if uncompressedSize == UInt64(ZipFormat.zip64Sentinel32), offset + 8 <= payload.count {
                uncompressedSize = read64(payload, offset)
                offset += 8
            }
            if compressedSize == UInt64(ZipFormat.zip64Sentinel32), offset + 8 <= payload.count {
                compressedSize = read64(payload, offset)
                offset += 8
            }
            if localHeaderOffset == UInt64(ZipFormat.zip64Sentinel32), offset + 8 <= payload.count {
                localHeaderOffset = read64(payload, offset)
            }
        }
    }

    private static func extendedTimestamp(_ extra: UnsafeRawBufferPointer) -> Date? {
        var result: Date?
        forEachExtraField(extra) { id, payload in
            guard id == ZipFormat.extendedTimestampExtraFieldID, payload.count >= 5 else { return }
            guard payload[0] & 0x01 != 0 else { return }
            result = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: read32(payload, 1))))
        }
        return result
    }

    private static func forEachExtraField(
        _ extra: UnsafeRawBufferPointer,
        _ body: (UInt16, UnsafeRawBufferPointer) -> Void
    ) {
        var offset = 0
        while offset + 4 <= extra.count {
            let id = read16(extra, offset)
            let length = Int(read16(extra, offset + 2))
            let start = offset + 4
            guard start + length <= extra.count else { return }
            body(id, UnsafeRawBufferPointer(rebasing: extra[start ..< start + length]))
            offset = start + length
        }
    }

    // MARK: - Scanning

    private static func looksLikeZip(_ bytes: UnsafeRawBufferPointer) -> Bool {
        bytes.count >= 2 && bytes[0] == UInt8(ascii: "P") && bytes[1] == UInt8(ascii: "K")
    }

    /// Scans backwards for `PK\5\6`, which can sit up to a 64 KB comment away from the end.
    private static func findEndOfCentralDirectory(_ bytes: UnsafeRawBufferPointer) -> Int? {
        let size = bytes.count
        let window = min(size, ZipFormat.maximumEndOfCentralDirectorySearch)
        var offset = size - ZipFormat.endOfCentralDirectorySize
        let lowest = size - window
        while offset >= lowest, offset >= 0 {
            if read32(bytes, offset) == ZipFormat.endOfCentralDirectorySignature {
                // Trust it only if the recorded comment length actually reaches the end, which
                // rules out a `PK\5\6` that happens to appear inside compressed data.
                let commentLength = Int(read16(bytes, offset + 20))
                if offset + ZipFormat.endOfCentralDirectorySize + commentLength == size { return offset }
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - Little-endian primitives

    private static func read16(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func read32(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func read64(_ bytes: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for step in 0 ..< 8 {
            value |= UInt64(bytes[offset + step]) << (8 * step)
        }
        return value
    }
}
