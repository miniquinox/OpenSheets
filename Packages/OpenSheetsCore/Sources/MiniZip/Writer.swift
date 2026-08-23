//
//  Writer.swift
//  MiniZip
//
//  Building a ZIP archive from `[ZipEntry]`, with byte-identical passthrough as the point.
//
//  A2 owns this file. A1 owns `Reader.swift` and `Inflate.swift`. `Types.swift` is A0's and
//  holds the constants both sides agree on.
//

import Foundation
import SheetModel

/// Writes a ZIP archive.
///
/// # The one trick that matters
///
/// ``archive(_:)`` never compresses anything. It takes entries whose ``ZipEntry/compressedData``
/// is *already* in its final form and lays out headers around them. That is what makes
/// passthrough lossless **and** fast: a chart part, an embedded PNG, a `vbaProject.bin` are
/// copied as the deflated bytes they already were, with the producer's own CRC and sizes, so
/// the bytes cannot drift even by a compression-level setting.
///
/// Fresh content goes through ``entry(path:contents:basedOn:)`` first, which deflates once and
/// hands back an entry in the same shape.
///
/// # What is deliberately not preserved
///
/// Two things are rewritten rather than copied:
///
/// - **Bit 3 of the general-purpose flags** (data descriptor) is cleared. We know every size and
///   CRC up front, so we write them into the local header where every reader can see them, and
///   omit the trailing descriptor. Leaving the bit set while omitting the descriptor produces an
///   archive that some tools read and others reject.
/// - **The Zip64 extra field** (`0x0001`) is stripped from the copied extra data and regenerated
///   when it is actually needed. A stale one describing the entry's position in a *different*
///   archive is worse than none. Every other extra field — Unix timestamps, Info-ZIP fields,
///   producer extensions — is re-emitted verbatim.
public enum ZipWriter {
    // MARK: - Building entries

    /// An entry holding `contents`, deflated unless deflating makes it bigger.
    ///
    /// `template` supplies the metadata a rewrite has no opinion about — the DOS timestamp, the
    /// Unix mode, the entry comment, the producer's extra fields — so re-emitting a part we
    /// modelled changes its bytes and nothing else about it.
    public static func entry(path: String, contents: Data, basedOn template: ZipEntry? = nil) -> ZipEntry {
        let checksum = DeflateCodec.crc32(contents)
        let deflated = DeflateCodec.deflate(contents)
        let method: CompressionMethod = deflated == nil ? .store : .deflate
        let payload = deflated ?? contents

        return ZipEntry(
            path: path,
            compressedData: payload,
            compressionMethod: method,
            crc32: checksum,
            compressedSize: UInt64(payload.count),
            uncompressedSize: UInt64(contents.count),
            lastModified: template?.lastModified ?? .epoch,
            extendedModificationDate: template?.extendedModificationDate,
            // Bit 3 cannot survive: we write the sizes inline.
            generalPurposeFlags: (template?.generalPurposeFlags ?? 0) & ~ZipGeneralPurposeFlags.hasDataDescriptor
                .rawValue,
            versionMadeBy: template?.versionMadeBy ?? 0x031E,
            versionNeeded: template?.versionNeeded ?? 20,
            externalAttributes: template?.externalAttributes ?? 0,
            internalAttributes: template?.internalAttributes ?? 0,
            extraFieldLocal: template?.extraFieldLocal ?? Data(),
            extraFieldCentral: template?.extraFieldCentral ?? Data(),
            comment: template?.comment
        )
    }

    // MARK: - Writing the archive

    /// Lays `entries` out as a ZIP archive, in the order given.
    ///
    /// Order is preserved exactly. Some producers — and some consumers of the files we write —
    /// care about which part comes first, and reordering costs nothing to avoid.
    public static func archive(_ entries: [ZipEntry]) throws(SheetError) -> Data {
        var seen = Set<String>()
        seen.reserveCapacity(entries.count)
        for entry in entries {
            try validate(path: entry.path)
            guard seen.insert(entry.path).inserted else {
                throw SheetError.archiveDuplicateEntry(name: entry.path)
            }
            guard UInt64(entry.compressedData.count) == entry.compressedSize else {
                throw SheetError.internalInconsistency(
                    detail: "entry '\(entry.path)' carries \(entry.compressedData.count) bytes "
                        + "but declares a compressed size of \(entry.compressedSize)"
                )
            }
        }

        var output = [UInt8]()
        output.reserveCapacity(entries.reduce(1024) { $0 + $1.compressedData.count + 128 })

        var directory = [UInt8]()
        directory.reserveCapacity(entries.count * 96)

        var needsZip64 = false

        for entry in entries {
            let name = Array(entry.path.utf8)
            let localOffset = UInt64(output.count)
            let sizesOverflow = entry.compressedSize > ZipFormat.maximumNonZip64Bytes
                || entry.uncompressedSize > ZipFormat.maximumNonZip64Bytes
            let offsetOverflows = localOffset > ZipFormat.maximumNonZip64Bytes
            needsZip64 = needsZip64 || sizesOverflow || offsetOverflows

            let flags = outputFlags(for: entry, name: entry.path)
            let versionNeeded = sizesOverflow || offsetOverflows ? max(entry.versionNeeded, 45) : entry.versionNeeded

            // --- local file header -------------------------------------------------------
            var localExtra = stripZip64(entry.extraFieldLocal)
            if sizesOverflow {
                localExtra.append(contentsOf: zip64ExtraField(
                    uncompressedSize: entry.uncompressedSize,
                    compressedSize: entry.compressedSize,
                    localHeaderOffset: nil
                ))
            }

            append32(&output, ZipFormat.localFileHeaderSignature)
            append16(&output, versionNeeded)
            append16(&output, flags)
            append16(&output, entry.compressionMethod.rawValue)
            append16(&output, entry.lastModified.time)
            append16(&output, entry.lastModified.date)
            append32(&output, entry.crc32)
            append32(&output, sizesOverflow ? ZipFormat.zip64Sentinel32 : UInt32(entry.compressedSize))
            append32(&output, sizesOverflow ? ZipFormat.zip64Sentinel32 : UInt32(entry.uncompressedSize))
            append16(&output, UInt16(name.count))
            append16(&output, UInt16(localExtra.count))
            output.append(contentsOf: name)
            output.append(contentsOf: localExtra)
            output.append(contentsOf: entry.compressedData)

            // --- central directory entry -------------------------------------------------
            var centralExtra = stripZip64(entry.extraFieldCentral)
            if sizesOverflow || offsetOverflows {
                centralExtra.append(contentsOf: zip64ExtraField(
                    uncompressedSize: sizesOverflow ? entry.uncompressedSize : nil,
                    compressedSize: sizesOverflow ? entry.compressedSize : nil,
                    localHeaderOffset: offsetOverflows ? localOffset : nil
                ))
            }
            let comment = Array((entry.comment ?? "").utf8)

            append32(&directory, ZipFormat.centralDirectorySignature)
            append16(&directory, entry.versionMadeBy)
            append16(&directory, versionNeeded)
            append16(&directory, flags)
            append16(&directory, entry.compressionMethod.rawValue)
            append16(&directory, entry.lastModified.time)
            append16(&directory, entry.lastModified.date)
            append32(&directory, entry.crc32)
            append32(&directory, sizesOverflow ? ZipFormat.zip64Sentinel32 : UInt32(entry.compressedSize))
            append32(&directory, sizesOverflow ? ZipFormat.zip64Sentinel32 : UInt32(entry.uncompressedSize))
            append16(&directory, UInt16(name.count))
            append16(&directory, UInt16(centralExtra.count))
            append16(&directory, UInt16(comment.count))
            append16(&directory, 0) // disk number start
            append16(&directory, entry.internalAttributes)
            append32(&directory, entry.externalAttributes)
            append32(&directory, offsetOverflows ? ZipFormat.zip64Sentinel32 : UInt32(localOffset))
            directory.append(contentsOf: name)
            directory.append(contentsOf: centralExtra)
            directory.append(contentsOf: comment)
        }

        let directoryOffset = UInt64(output.count)
        let directorySize = UInt64(directory.count)
        output.append(contentsOf: directory)

        needsZip64 = needsZip64
            || entries.count > ZipFormat.maximumNonZip64Entries
            || directoryOffset > ZipFormat.maximumNonZip64Bytes
            || directorySize > ZipFormat.maximumNonZip64Bytes

        if needsZip64 {
            let zip64Offset = UInt64(output.count)

            append32(&output, ZipFormat.zip64EndOfCentralDirectorySignature)
            append64(&output, 44) // size of the remainder of this record
            append16(&output, 45) // version made by
            append16(&output, 45) // version needed
            append32(&output, 0) // this disk
            append32(&output, 0) // disk with the central directory
            append64(&output, UInt64(entries.count))
            append64(&output, UInt64(entries.count))
            append64(&output, directorySize)
            append64(&output, directoryOffset)

            append32(&output, ZipFormat.zip64EndOfCentralDirectoryLocatorSignature)
            append32(&output, 0) // disk holding the Zip64 record
            append64(&output, zip64Offset)
            append32(&output, 1) // total disks
        }

        let entryCountField = entries.count > ZipFormat.maximumNonZip64Entries
            ? ZipFormat.zip64Sentinel16
            : UInt16(entries.count)

        append32(&output, ZipFormat.endOfCentralDirectorySignature)
        append16(&output, 0) // this disk
        append16(&output, 0) // disk with the central directory
        append16(&output, entryCountField)
        append16(&output, entryCountField)
        append32(&output, directorySize > ZipFormat.maximumNonZip64Bytes
            ? ZipFormat.zip64Sentinel32 : UInt32(directorySize))
        append32(&output, directoryOffset > ZipFormat.maximumNonZip64Bytes
            ? ZipFormat.zip64Sentinel32 : UInt32(directoryOffset))
        append16(&output, 0) // archive comment length

        return Data(output)
    }

    // MARK: - Entry names

    /// Rejects a name that would escape the archive on extraction.
    ///
    /// The reader refuses these on the way in, but a writer that trusts its input is one bug
    /// away from producing the file it just refused to read.
    private static func validate(path: String) throws(SheetError) {
        guard !path.isEmpty else {
            throw SheetError.archiveMalformed(detail: "an archive entry cannot have an empty name")
        }
        let looksAbsolute = path.hasPrefix("/")
        let hasBackslash = path.contains("\\")
        let hasDriveLetter = path.count >= 2 && path.first!.isLetter && path[path.index(after: path.startIndex)] == ":"
        let hasNUL = path.utf8.contains(0)
        let escapes = path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        guard !looksAbsolute, !hasBackslash, !hasDriveLetter, !hasNUL, !escapes else {
            throw SheetError.archivePathTraversal(entryName: path)
        }
    }

    /// The flag word to write: the original, minus the data-descriptor bit, plus the UTF-8 bit
    /// whenever the name needs it.
    private static func outputFlags(for entry: ZipEntry, name: String) -> UInt16 {
        var flags = entry.generalPurposeFlags & ~ZipGeneralPurposeFlags.hasDataDescriptor.rawValue
        if !name.allSatisfy(\.isASCII) {
            flags |= ZipGeneralPurposeFlags.utf8Name.rawValue
        }
        return flags
    }

    // MARK: - Extra fields

    /// Removes any `0x0001` Zip64 field, leaving every other extra field byte-identical.
    ///
    /// Walks the `id`/`size`/`payload` chain rather than searching for bytes, because `0x0001`
    /// occurs constantly inside other fields' payloads. A malformed chain is dropped entirely:
    /// an extra field we cannot parse is one we cannot safely re-emit either.
    private static func stripZip64(_ extra: Data) -> [UInt8] {
        guard !extra.isEmpty else { return [] }
        let bytes = [UInt8](extra)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var cursor = 0
        while cursor + 4 <= bytes.count {
            let identifier = UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8)
            let size = Int(UInt16(bytes[cursor + 2]) | (UInt16(bytes[cursor + 3]) << 8))
            let next = cursor + 4 + size
            guard next <= bytes.count else { return result }
            if identifier != ZipFormat.zip64ExtraFieldID {
                result.append(contentsOf: bytes[cursor ..< next])
            }
            cursor = next
        }
        return result
    }

    /// A Zip64 extra field carrying exactly the values whose 32-bit slots hold the sentinel.
    ///
    /// The order is fixed by the specification — uncompressed size, compressed size, local
    /// header offset, disk number — and readers index into it positionally, so a field that
    /// includes a value whose 32-bit slot is *not* sentinelled is misread.
    private static func zip64ExtraField(
        uncompressedSize: UInt64?,
        compressedSize: UInt64?,
        localHeaderOffset: UInt64?
    ) -> [UInt8] {
        var payload: [UInt8] = []
        if let uncompressedSize { append64(&payload, uncompressedSize) }
        if let compressedSize { append64(&payload, compressedSize) }
        if let localHeaderOffset { append64(&payload, localHeaderOffset) }
        guard !payload.isEmpty else { return [] }

        var field: [UInt8] = []
        append16(&field, ZipFormat.zip64ExtraFieldID)
        append16(&field, UInt16(payload.count))
        field.append(contentsOf: payload)
        return field
    }

    // MARK: - Little-endian primitives

    private static func append16(_ buffer: inout [UInt8], _ value: UInt16) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
    }

    private static func append32(_ buffer: inout [UInt8], _ value: UInt32) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8((value >> 16) & 0xFF))
        buffer.append(UInt8((value >> 24) & 0xFF))
    }

    private static func append64(_ buffer: inout [UInt8], _ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            buffer.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }
}
