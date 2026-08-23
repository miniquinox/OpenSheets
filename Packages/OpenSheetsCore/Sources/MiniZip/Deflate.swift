//
//  Deflate.swift
//  MiniZip
//
//  Raw DEFLATE (RFC 1951) and CRC-32, for the writer.
//
//  A2 owns this file. A1 owns `Reader.swift` and `Inflate.swift`; nothing here is called from
//  there and nothing here calls into there. Everything lives under one `DeflateCodec`
//  namespace precisely so two agents can add compression helpers to the same target without
//  colliding on a top-level `Inflate` or `CRC32`.
//

import Compression
import Foundation
import SheetModel

/// Raw DEFLATE and CRC-32, as the ZIP writer needs them.
///
/// # Why raw DEFLATE and not zlib
///
/// ZIP method 8 stores an RFC 1951 stream with **no** zlib header and no trailing Adler-32.
/// Apple's `COMPRESSION_ZLIB` is exactly that despite the name, which is why this is a thin
/// wrapper rather than a hand-written encoder.
///
/// # Why there is a decompressor here at all
///
/// The writer is not supposed to inflate anything — passthrough copies compressed bytes
/// straight across. But three parts have to be *read* before they can be rewritten:
/// `sheetN.xml` (to salvage unmodelled child elements verbatim), `sharedStrings.xml` (to append
/// to the string table without renumbering it), and `[Content_Types].xml` (to drop one
/// `Override` when `calcChain.xml` goes). Those are parts we chose to touch, so inflating them
/// is not the eager whole-archive inflation the Wave 1 addendum §2 warns against — and the cap
/// still applies per entry.
public enum DeflateCodec {
    /// Bytes we will ever inflate for one part, mirroring ``Limits/maxEntryDecompressedBytes``.
    public static let defaultInflateLimit = Limits.maxEntryDecompressedBytes

    // MARK: - Deflate

    /// Deflates `input` as a raw RFC 1951 stream.
    ///
    /// Returns `nil` when the result would not be smaller than the input, which is the signal
    /// to store the entry instead. Incompressible payloads — an already-deflated PNG, a JPEG —
    /// otherwise grow by the block overhead for nothing.
    public static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        guard let output = transform(input, operation: COMPRESSION_STREAM_ENCODE, limit: nil) else { return nil }
        guard output.count < input.count else { return nil }
        return Data(output)
    }

    // MARK: - Inflate

    /// Inflates a raw RFC 1951 stream, refusing to produce more than `limit` bytes.
    ///
    /// The cap is enforced *during* inflation, not after: a bomb that claims 120 bytes and
    /// produces 10 GB has to be stopped while it is producing, or the cap is decoration.
    public static func inflate(
        _ input: Data,
        path: String,
        limit: Int = defaultInflateLimit
    ) throws(SheetError) -> Data {
        guard !input.isEmpty else { return Data() }
        guard let output = transform(input, operation: COMPRESSION_STREAM_DECODE, limit: limit) else {
            throw SheetError.archiveMalformed(detail: "entry '\(path)' is not a valid DEFLATE stream")
        }
        guard output.count <= limit else {
            throw SheetError.archiveEntryTooLarge(path: path, declaredBytes: output.count, limit: limit)
        }
        return Data(output)
    }

    /// Returns the bytes of `entry`, inflating only if it is stored deflated.
    ///
    /// Refuses anything that is neither stored nor deflated — an AES-encrypted entry can be
    /// copied through, but it cannot be understood, and pretending otherwise is how a writer
    /// emits garbage.
    public static func contents(
        of entry: ZipEntry,
        limit: Int = defaultInflateLimit
    ) throws(SheetError) -> Data {
        guard entry.uncompressedSize <= UInt64(limit) else {
            throw SheetError.archiveEntryTooLarge(
                path: entry.path, declaredBytes: Int(clamping: entry.uncompressedSize), limit: limit
            )
        }
        switch entry.compressionMethod {
        case .store:
            return entry.compressedData
        case .deflate:
            return try inflate(entry.compressedData, path: entry.path, limit: limit)
        case let .other(method):
            throw SheetError.archiveUnsupportedCompression(path: entry.path, method: method)
        }
    }

    // MARK: - CRC-32

    /// The ISO 3309 CRC-32 a ZIP entry records for its *uncompressed* bytes.
    ///
    /// Only ever computed for entries we rewrite. A passthrough entry re-emits the CRC that was
    /// in the original central directory, because recomputing it would mean inflating bytes we
    /// promised not to touch.
    public static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        bytes.withUnsafeBytes { raw in
            for byte in raw {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The standard reflected polynomial table, built once.
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0 ..< 256 {
            var value = UInt32(index)
            for _ in 0 ..< 8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        return table
    }()

    // MARK: - Streaming plumbing

    /// Runs `input` through one `compression_stream`, stopping early if `limit` is exceeded.
    ///
    /// Returns `nil` on any stream error, which both callers translate into their own domain:
    /// a failed deflate means "store it instead", a failed inflate means "this archive lies".
    private static func transform(
        _ input: Data,
        operation: compression_stream_operation,
        limit: Int?
    ) -> [UInt8]? {
        let scratchSize = 64 * 1024
        var scratch = [UInt8](repeating: 0, count: scratchSize)
        var output: [UInt8] = []
        output.reserveCapacity(operation == COMPRESSION_STREAM_ENCODE ? input.count / 2 + 64 : input.count * 4 + 64)

        // `compression_stream` has no safe initialiser — every field is a pointer the library
        // fills in — so it is allocated rather than value-initialised with dummy pointers.
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(stream) }

        var failed = false
        var overLimit = false
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                failed = true
                return
            }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = raw.count

            while true {
                var status = COMPRESSION_STATUS_OK
                scratch.withUnsafeMutableBufferPointer { destination in
                    let start = destination.baseAddress!
                    stream.pointee.dst_ptr = start
                    stream.pointee.dst_size = destination.count
                    status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = destination.count - stream.pointee.dst_size
                    if produced > 0 {
                        output.append(contentsOf: UnsafeBufferPointer(start: start, count: produced))
                    }
                }
                if let limit, output.count > limit {
                    overLimit = true
                    return
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_END:
                    return
                default:
                    failed = true
                    return
                }
            }
        }
        if failed { return nil }
        if overLimit { return output }
        return output
    }
}
