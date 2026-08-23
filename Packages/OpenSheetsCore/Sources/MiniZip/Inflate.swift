//
//  Inflate.swift
//  MiniZip
//
//  A1 owns this file. Raw-DEFLATE decompression with the zip-bomb caps applied *while*
//  inflating, never after.
//

import Compression
import Foundation
import Synchronization

import SheetModel

/// The caps one entry's inflation is held to.
///
/// These are per-entry and are checked **during** decompression. A reader that inflates into a
/// buffer and then measures it has already spent the memory the cap exists to protect
/// (`Fixtures/hostile/zip-bomb.xlsx` would cost 200 MB before the check ran).
public struct InflateCaps: Sendable, Hashable {
    /// Bytes a single entry may inflate to. Also checked against the *declared* size before a
    /// single byte is produced, because `Fixtures/hostile/lying-uncompressed-size.xlsx` is a
    /// 120-byte entry claiming 10 GB and a reader that pre-allocates from that claim is a
    /// denial of service.
    public var maxEntryBytes: Int

    /// Compressed-to-uncompressed ratio ceiling. Real spreadsheet XML sits around 10:1.
    public var maxRatio: Double

    /// Output size below which ``maxRatio`` is not enforced.
    ///
    /// This floor is not slack, it is correctness. A 700 KB part that came from 988 compressed
    /// bytes has a ratio of 708:1 and is completely harmless — `hostile/deep-nesting-100k.xlsx`
    /// is exactly that, and its *expected* rejection is the XML depth cap, not a bomb error.
    /// Small, highly-repetitive XML compresses absurdly well; only sustained expansion past a
    /// size that could actually hurt is evidence of an attack.
    public var ratioFloorBytes: Int

    public init(
        maxEntryBytes: Int = Limits.maxEntryDecompressedBytes,
        maxRatio: Double = Limits.maxCompressionRatio,
        ratioFloorBytes: Int = 1 << 20
    ) {
        self.maxEntryBytes = maxEntryBytes
        self.maxRatio = maxRatio
        self.ratioFloorBytes = ratioFloorBytes
    }

    /// The caps from ``SheetModel/Limits``.
    public static let standard = InflateCaps()
}

/// The archive-wide decompression allowance, shared by every entry a single read inflates.
///
/// Deliberately *not* a check over the whole archive's declared sizes:
/// `Fixtures/hostile/zip-bomb-nested.xlsx` parks a bomb in `xl/media/` and is a perfectly valid
/// workbook, so summing what the archive *claims* would reject a file that must open. This
/// counts only what we actually chose to inflate.
public final class DecompressionBudget: Sendable {
    private let consumed: Mutex<Int>

    /// The ceiling, from ``SheetModel/Limits/maxDecompressedBytes`` unless overridden.
    public let limit: Int

    public init(limit: Int = Limits.maxDecompressedBytes) {
        self.limit = limit
        consumed = Mutex(0)
    }

    /// Bytes inflated so far under this budget.
    public var used: Int { consumed.withLock { $0 } }

    /// Charges `bytes` to the budget, throwing when the archive as a whole has inflated too
    /// much. Safe to call from several sheet-parsing tasks at once.
    public func charge(_ bytes: Int) throws(SheetError) {
        let total = consumed.withLock { current -> Int in
            current += bytes
            return current
        }
        if total > limit {
            throw SheetError.archiveTooLarge(decompressedBytes: total, limit: limit)
        }
    }
}

/// Raw DEFLATE (RFC 1951) decompression, plus the CRC-32 a ZIP entry is verified against.
///
/// Apple's `Compression` framework spells raw DEFLATE `COMPRESSION_ZLIB` — no zlib wrapper, no
/// gzip header — which is exactly what sits inside a ZIP entry.
public enum Inflate {
    /// Bytes produced per `compression_stream_process` call. 64 KB keeps the syscall-free inner
    /// loop hot without holding a large scratch buffer per sheet task.
    private static let chunkSize = 64 * 1024

    /// Inflates `source`, enforcing `caps` as output is produced.
    ///
    /// - Parameters:
    ///   - source: the entry's stored bytes, still deflated.
    ///   - declaredSize: what the archive claims this inflates to. A claim, not a fact — it is
    ///     range-checked before anything is allocated and verified against reality afterwards.
    ///   - path: the entry name, for the error message.
    ///   - caps: per-entry limits.
    ///   - budget: the archive-wide allowance, or `nil` to skip that check.
    public static func inflate(
        _ source: Data,
        declaredSize: UInt64,
        path: String,
        caps: InflateCaps = .standard,
        budget: DecompressionBudget? = nil
    ) throws(SheetError) -> [UInt8] {
        // Reject the *claim* first. This is the whole point of the check: allocating from a
        // declared size is a denial of service before a single byte has been inflated.
        if declaredSize > UInt64(caps.maxEntryBytes) {
            throw SheetError.archiveEntryTooLarge(
                path: path,
                declaredBytes: declaredSize > UInt64(Int.max) ? Int.max : Int(declaredSize),
                limit: caps.maxEntryBytes
            )
        }
        if source.isEmpty {
            guard declaredSize == 0 else {
                throw SheetError.archiveTruncated(detail: "'\(path)' has no stored bytes but claims \(declaredSize)")
            }
            return []
        }

        // Reserving the declared size is safe now that it has been bounded, and it removes the
        // repeated growth that otherwise dominates a 30 MB sheet.
        var output = [UInt8]()
        output.reserveCapacity(min(Int(declaredSize), caps.maxEntryBytes) + 1)

        var thrown: SheetError?
        source.withUnsafeBytes { (rawSource: UnsafeRawBufferPointer) in
            guard let sourceBase = rawSource.baseAddress else {
                thrown = .archiveTruncated(detail: "'\(path)' has no readable bytes")
                return
            }
            let sourceCount = rawSource.count

            var stream = compression_stream(
                dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: -1)!,
                dst_size: 0,
                src_ptr: UnsafePointer<UInt8>(bitPattern: -1)!,
                src_size: 0,
                state: nil
            )
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
                == COMPRESSION_STATUS_OK
            else {
                thrown = .archiveMalformed(detail: "could not start decompression for '\(path)'")
                return
            }
            defer { compression_stream_destroy(&stream) }

            stream.src_ptr = sourceBase.assumingMemoryBound(to: UInt8.self)
            stream.src_size = sourceCount

            let scratch = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: chunkSize)
            defer { scratch.deallocate() }

            var status = COMPRESSION_STATUS_OK
            while status == COMPRESSION_STATUS_OK {
                stream.dst_ptr = scratch.baseAddress!
                stream.dst_size = chunkSize
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    output.append(contentsOf: UnsafeBufferPointer(start: scratch.baseAddress!, count: produced))
                }

                if status == COMPRESSION_STATUS_ERROR {
                    thrown = .archiveTruncated(detail: "'\(path)' is not a valid deflate stream")
                    return
                }
                if output.count > caps.maxEntryBytes {
                    thrown = .archiveEntryTooLarge(
                        path: path, declaredBytes: output.count, limit: caps.maxEntryBytes
                    )
                    return
                }
                // Ratio against the input *consumed so far*, not the whole entry: on a bomb the
                // decoder has read a kilobyte by the time it has written a megabyte, and that
                // is the signal. Comparing against the full compressed size would look
                // innocent right up until the last chunk.
                if output.count >= caps.ratioFloorBytes {
                    let consumed = max(sourceCount - stream.src_size, 1)
                    let ratio = Double(output.count) / Double(consumed)
                    if ratio > caps.maxRatio {
                        thrown = .archiveCompressionRatioExceeded(
                            path: path, ratio: ratio, limit: caps.maxRatio
                        )
                        return
                    }
                }
            }
        }
        if let thrown { throw thrown }

        // A late whole-entry ratio check, for a stream that stayed under the floor the whole
        // way and still ended up implausible.
        if output.count >= caps.ratioFloorBytes {
            let ratio = Double(output.count) / Double(max(source.count, 1))
            if ratio > caps.maxRatio {
                throw SheetError.archiveCompressionRatioExceeded(path: path, ratio: ratio, limit: caps.maxRatio)
            }
        }
        if declaredSize != 0, UInt64(output.count) != declaredSize {
            throw SheetError.archiveTruncated(
                detail: "'\(path)' inflated to \(output.count) bytes but the archive declares \(declaredSize)"
            )
        }
        try budget?.charge(output.count)
        return output
    }

    /// Copies a stored (method 0) entry, applying the same caps so one code path owns them.
    public static func copyStored(
        _ source: Data,
        declaredSize: UInt64,
        path: String,
        caps: InflateCaps = .standard,
        budget: DecompressionBudget? = nil
    ) throws(SheetError) -> [UInt8] {
        if declaredSize > UInt64(caps.maxEntryBytes) || source.count > caps.maxEntryBytes {
            throw SheetError.archiveEntryTooLarge(
                path: path,
                declaredBytes: max(Int(clamping: declaredSize), source.count),
                limit: caps.maxEntryBytes
            )
        }
        if declaredSize != 0, UInt64(source.count) != declaredSize {
            throw SheetError.archiveTruncated(
                detail: "'\(path)' stores \(source.count) bytes but the archive declares \(declaredSize)"
            )
        }
        try budget?.charge(source.count)
        return [UInt8](source)
    }

    // MARK: - CRC-32

    /// The IEEE 802.3 CRC-32 a ZIP entry records for its *uncompressed* bytes.
    ///
    /// Written out rather than pulled from zlib so the reader has no C dependency of its own and
    /// so the table is visible to a test.
    public static func crc32(_ bytes: some Collection<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = {
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
}
