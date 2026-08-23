import Compression
import Foundation
import SheetModel

/// RFC 1952 gzip, over Apple's raw-DEFLATE codec.
///
/// `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) with no container, so the ten-byte header and
/// the CRC-32/ISIZE trailer are written here. That is eight lines of framing in exchange for
/// snapshots that are real `.gz` files: a user who has lost confidence in the app can recover
/// their spreadsheet with `gunzip`, without the app, without us. For a safety net, being
/// openable by something other than the thing that failed is most of the value.
///
/// Decompression verifies both the CRC-32 and the length. A snapshot that silently restored
/// corrupt bytes would be worse than one that refused to restore at all.
public enum Gzip {
    private static let chunkSize = 64 * 1024

    /// Compresses `data` into a complete gzip member.
    public static func compress(_ data: Data) throws(SheetError) -> Data {
        var output = Data()
        output.reserveCapacity(data.count / 3 + 64)
        output.append(contentsOf: [
            0x1F, 0x8B, // magic
            0x08, // CM = deflate
            0x00, // FLG: no extra fields
            0x00, 0x00, 0x00, 0x00, // MTIME 0 — deliberate: the snapshot's time is in the
            // database and in its ULID, and a timestamp here would make two
            // snapshots of identical bytes differ.
            0x00, // XFL
            0xFF, // OS = unknown
        ])
        output.append(try transcode(data, operation: COMPRESSION_STREAM_ENCODE))
        var crc = CRC32.checksum(data).littleEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
        return output
    }

    /// Decompresses a gzip member, verifying its checksum and length.
    public static func decompress(_ data: Data) throws(SheetError) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B else {
            throw SheetError.archiveMalformed(detail: "not a gzip stream")
        }
        guard bytes[2] == 0x08 else {
            throw SheetError.archiveUnsupportedCompression(path: "snapshot", method: UInt16(bytes[2]))
        }

        // Skip the optional header fields. We never write them, but a snapshot a user replaced
        // by hand with `gzip file` will have FNAME set, and refusing to read that would be a
        // gratuitous way to fail a restore.
        let flags = bytes[3]
        var cursor = 10
        if flags & 0x04 != 0 {
            guard cursor + 2 <= bytes.count else { throw SheetError.archiveTruncated(detail: "gzip FEXTRA") }
            let length = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            cursor += 2 + length
        }
        for mask in [UInt8(0x08), UInt8(0x10)] where flags & mask != 0 {
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        if flags & 0x02 != 0 { cursor += 2 }
        guard cursor + 8 <= bytes.count else { throw SheetError.archiveTruncated(detail: "gzip header") }

        let payload = Data(bytes[cursor ..< (bytes.count - 8)])
        let inflated = try transcode(payload, operation: COMPRESSION_STREAM_DECODE)

        let trailer = bytes.suffix(8)
        let expectedCRC = UInt32(trailer[trailer.startIndex])
            | (UInt32(trailer[trailer.startIndex + 1]) << 8)
            | (UInt32(trailer[trailer.startIndex + 2]) << 16)
            | (UInt32(trailer[trailer.startIndex + 3]) << 24)
        let expectedSize = UInt32(trailer[trailer.startIndex + 4])
            | (UInt32(trailer[trailer.startIndex + 5]) << 8)
            | (UInt32(trailer[trailer.startIndex + 6]) << 16)
            | (UInt32(trailer[trailer.startIndex + 7]) << 24)

        guard UInt32(truncatingIfNeeded: inflated.count) == expectedSize else {
            throw SheetError.archiveTruncated(
                detail: "gzip length mismatch: \(inflated.count) bytes, header claims \(expectedSize)"
            )
        }
        let actualCRC = CRC32.checksum(inflated)
        guard actualCRC == expectedCRC else {
            throw SheetError.archiveChecksumMismatch(path: "snapshot", expected: expectedCRC, actual: actualCRC)
        }
        return inflated
    }

    /// Runs one direction of the codec.
    private static func transcode(
        _ input: Data,
        operation: compression_stream_operation
    ) throws(SheetError) -> Data {
        var output = Data()
        var failed = false

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw SheetError.internalInconsistency(detail: "the compression codec would not start")
        }
        defer { compression_stream_destroy(streamPointer) }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        // A one-byte scratch buffer stands in for empty input: `withUnsafeBytes` on empty
        // `Data` yields a null base address, and the codec rejects null rather than reading it
        // as "no input" — which would make compressing an empty file throw.
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        placeholder.initialize(to: 0)
        defer { placeholder.deallocate() }

        input.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(placeholder)
            streamPointer.pointee.src_ptr = base
            streamPointer.pointee.src_size = raw.count

            repeat {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = chunkSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - streamPointer.pointee.dst_size
                if produced > 0 { output.append(buffer, count: produced) }
                if status == COMPRESSION_STATUS_END { return }
                if status != COMPRESSION_STATUS_OK {
                    failed = true
                    return
                }
            } while true
        }

        if failed {
            throw operation == COMPRESSION_STREAM_ENCODE
                ? SheetError.internalInconsistency(detail: "the snapshot could not be compressed")
                : SheetError.archiveMalformed(detail: "the snapshot's deflate stream is corrupt")
        }
        return output
    }
}

/// The CRC-32 gzip specifies (IEEE 802.3 polynomial, reflected).
///
/// Written out rather than reached for from zlib because there is no zlib module on the Swift
/// side of this package, and 20 lines of table-driven CRC is a smaller dependency than a
/// module map.
enum CRC32 {
    private static let table: [UInt32] = {
        (0 ..< 256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
