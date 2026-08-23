//
//  ZipReaderTests.swift
//  SheetFormatTests
//
//  A1. `MiniZip.Reader` and `MiniZip.Inflate` on their own, away from any xlsx semantics.
//

import Compression
import Foundation
import Testing

import MiniZip
import SheetModel
import TestSupport

@Suite("MiniZip reader")
struct ZipReaderTests {
    // MARK: - Building archives by hand
    //
    // Hand-built rather than fixture-driven, because the interesting cases here are shapes A7's
    // corpus has no reason to contain: a Zip64 extra field on a small entry, a stored entry, a
    // prepended self-extracting stub.

    @Test("reads a stored entry and a deflated one out of the same archive")
    func readsBothMethods() throws {
        let archive = try ZipReader.read(
            TestArchive.build([
                TestArchive.Member(path: "stored.txt", contents: Array("hello".utf8), deflate: false),
                TestArchive.Member(path: "deflated.xml", contents: Array(String(repeating: "<a/>", count: 200).utf8)),
            ]),
            name: "mixed.zip"
        )
        #expect(archive.entries.map(\.path) == ["stored.txt", "deflated.xml"])
        #expect(archive.entries[0].compressionMethod == .store)
        #expect(archive.entries[1].compressionMethod == .deflate)
        #expect(try archive.bytes(of: "stored.txt") == Array("hello".utf8))
        #expect(try archive.bytes(of: "deflated.xml").count == 800)
    }

    @Test("archive order is preserved, because some producers are sensitive to it")
    func preservesOrder() throws {
        let names = ["z.xml", "a.xml", "m/b.xml"]
        let archive = try ZipReader.read(
            TestArchive.build(names.map { TestArchive.Member(path: $0, contents: Array("x".utf8)) }),
            name: "order.zip"
        )
        #expect(archive.entries.map(\.path) == names)
    }

    @Test("a Zip64 extra field carries the real sizes")
    func readsZip64Sizes() throws {
        // The entry is tiny; only the *headers* use the Zip64 form. That is exactly the shape
        // `hostile/lying-uncompressed-size.xlsx` uses, and the shape a reader without Zip64
        // support misreads as a 4 GB entry.
        let payload = Array("zip64 payload".utf8)
        let data = TestArchive.build([
            TestArchive.Member(path: "big.bin", contents: payload, deflate: false, forceZip64: true),
        ])
        let archive = try ZipReader.read(data, name: "zip64.zip")
        let entry = try #require(archive["big.bin"])
        #expect(entry.uncompressedSize == UInt64(payload.count))
        #expect(entry.compressedSize == UInt64(payload.count))
        #expect(try archive.bytes(of: entry) == payload)
    }

    @Test("data prepended to the archive shifts every offset and is recovered")
    func recoversFromPrependedData() throws {
        var data = Data("#!/bin/sh\necho self-extracting\nexit 0\n".utf8)
        data.append(TestArchive.build([TestArchive.Member(path: "a.xml", contents: Array("ok".utf8))]))
        let archive = try ZipReader.read(data, name: "sfx.zip")
        #expect(try archive.bytes(of: "a.xml") == Array("ok".utf8))
    }

    @Test("a comment on the end-of-central-directory record does not hide it")
    func findsEOCDBehindAComment() throws {
        let archive = try ZipReader.read(
            TestArchive.build(
                [TestArchive.Member(path: "a.xml", contents: Array("ok".utf8))],
                comment: Array(String(repeating: "c", count: 4000).utf8)
            ),
            name: "commented.zip"
        )
        #expect(archive.entries.count == 1)
    }

    // MARK: - Rejections

    @Test(
        "an unsafe entry name is refused",
        arguments: [
            "../escape.xml", "a/../../escape.xml", "/etc/passwd", "\\\\server\\share",
            "C:\\Windows\\evil.dll", "xl\\..\\..\\evil.dll",
        ]
    )
    func refusesUnsafeNames(name: String) {
        expectThrows(code: "zip.pathTraversal") {
            try ZipReader.read(
                TestArchive.build([TestArchive.Member(path: name, contents: Array("x".utf8))]), name: "bad.zip"
            )
        }
    }

    @Test("a name containing a NUL is refused as bytes, before decoding")
    func refusesNulNames() {
        expectThrows(code: "zip.pathTraversal") {
            try ZipReader.read(
                TestArchive.build([
                    TestArchive.Member(path: "xl/sheet1.xml\u{0}.png", contents: Array("x".utf8)),
                ]),
                name: "nul.zip"
            )
        }
    }

    @Test("two dots inside a component are not traversal")
    func allowsDotsInsideNames() throws {
        let archive = try ZipReader.read(
            TestArchive.build([TestArchive.Member(path: "xl/report..final.xml", contents: Array("x".utf8))]),
            name: "dots.zip"
        )
        #expect(archive.contains("xl/report..final.xml"))
    }

    @Test("a duplicated name is refused")
    func refusesDuplicates() {
        expectThrows(code: "zip.duplicateEntry") {
            try ZipReader.read(
                TestArchive.build([
                    TestArchive.Member(path: "a.xml", contents: Array("one".utf8)),
                    TestArchive.Member(path: "a.xml", contents: Array("two".utf8)),
                ]),
                name: "dup.zip"
            )
        }
    }

    @Test("a file with no PK signature at all is malformed, not truncated")
    func refusesNonArchives() {
        expectThrows(code: "zip.malformed") {
            try ZipReader.read(Data(repeating: 0x41, count: 4096), name: "text.bin")
        }
    }

    @Test("a file that starts like a zip and ends early is truncated")
    func refusesTruncatedArchives() {
        let whole = TestArchive.build([
            TestArchive.Member(path: "a.xml", contents: Array(String(repeating: "x", count: 400).utf8)),
        ])
        expectThrows(code: "zip.truncated") {
            try ZipReader.read(whole.prefix(whole.count / 2), name: "half.zip")
        }
    }

    @Test("an unreadable compression method is refused when its bytes are asked for, not before")
    func refusesUnsupportedMethodLazily() throws {
        let data = TestArchive.build([
            TestArchive.Member(path: "xl/media/thing.bin", contents: Array("x".utf8), deflate: false, method: 99),
            TestArchive.Member(path: "xl/workbook.xml", contents: Array("<w/>".utf8)),
        ])
        // Opening succeeds: the odd entry is still copyable through `OpaqueParts`, and refusing a
        // whole workbook over a part nobody was going to read contradicts the same laziness that
        // lets `hostile/zip-bomb-nested.xlsx` open.
        let archive = try ZipReader.read(data, name: "method99.zip")
        #expect(archive.entries.count == 2)
        #expect(try archive.bytes(of: "xl/workbook.xml") == Array("<w/>".utf8))
        expectThrows(code: "zip.unsupportedCompression") {
            try archive.bytes(of: "xl/media/thing.bin")
        }
    }

    @Test("a wrong CRC is caught on inflation")
    func catchesChecksumMismatch() throws {
        let archive = try ZipReader.read(
            TestArchive.build([
                TestArchive.Member(path: "a.xml", contents: Array("hello".utf8), crcOverride: 0xDEAD_BEEF),
            ]),
            name: "crc.zip"
        )
        expectThrows(code: "zip.checksumMismatch") { try archive.bytes(of: "a.xml") }
    }

    @Test("a declared size past the per-entry cap is refused before anything is allocated")
    func refusesLyingDeclaredSizes() {
        expectThrows(code: "zip.bomb.entry") {
            try Inflate.inflate(
                Data([0x03, 0x00]),
                declaredSize: 10 * 1024 * 1024 * 1024,
                path: "xl/sharedStrings.xml"
            )
        }
    }

    @Test("the archive-wide budget is shared across entries")
    func sharedBudgetIsEnforced() throws {
        let budget = DecompressionBudget(limit: 32)
        let archive = try ZipReader.read(
            TestArchive.build([
                TestArchive.Member(path: "a.xml", contents: Array(String(repeating: "a", count: 24).utf8)),
                TestArchive.Member(path: "b.xml", contents: Array(String(repeating: "b", count: 24).utf8)),
            ]),
            name: "budget.zip",
            budget: budget
        )
        _ = try archive.bytes(of: "a.xml")
        expectThrows(code: "zip.bomb.total") { try archive.bytes(of: "b.xml") }
    }

    @Test("a highly compressible small part is not mistaken for a bomb")
    func ratioFloorProtectsSmallParts() throws {
        // 700 KB of one repeated byte compresses about 700:1 and is completely harmless. This is
        // `hostile/deep-nesting-100k.xlsx`'s shape, whose expected rejection is the XML depth cap
        // — a ratio check with no size floor would steal it and report a bomb instead.
        let payload = [UInt8](repeating: UInt8(ascii: "a"), count: 700_000)
        let archive = try ZipReader.read(
            TestArchive.build([TestArchive.Member(path: "flat.xml", contents: payload)]),
            name: "compressible.zip"
        )
        let entry = try #require(archive["flat.xml"])
        #expect(entry.claimedCompressionRatio > Limits.maxCompressionRatio, "the fixture is no longer compressible")
        #expect(try archive.bytes(of: "flat.xml").count == payload.count)
    }

    @Test("CRC-32 agrees with the values the corpus recorded")
    func crc32IsCorrect() {
        #expect(Inflate.crc32([UInt8]()) == 0)
        #expect(Inflate.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(Inflate.crc32(Array("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test("entry metadata that only matters on write survives the trip")
    func preservesWriteCriticalMetadata() throws {
        guard FixtureLibrary.isAvailable else { return }
        let archive = try ZipReader.read(
            try FixtureLibrary.data("passthrough/kitchen-sink.xlsm"), name: "kitchen-sink"
        )
        for entry in archive.entries {
            #expect(entry.compressedSize == UInt64(entry.compressedData.count), "\(entry.path): size disagreement")
            #expect(entry.versionMadeBy != 0 || entry.versionNeeded != 0, "\(entry.path): version words lost")
        }
    }
}

/// Builds ZIP archives byte by byte, so a test can construct a shape no real producer would.
///
/// Deliberately not built on A2's writer: a reader test that uses the writer to make its input
/// proves only that the two agree, which is precisely the failure mode both of them are supposed
/// to catch.
enum TestArchive {
    struct Member {
        var path: String
        var contents: [UInt8]
        var deflate = true
        var method: UInt16?
        var crcOverride: UInt32?
        var forceZip64 = false
    }

    static func build(_ members: [Member], comment: [UInt8] = []) -> Data {
        var output = [UInt8]()
        var directory = [UInt8]()
        var count = 0

        for member in members {
            let name = Array(member.path.utf8)
            let stored = member.deflate ? deflate(member.contents) : member.contents
            let method: UInt16 = member.method ?? (member.deflate ? 8 : 0)
            let crc = member.crcOverride ?? Inflate.crc32(member.contents)
            let localOffset = output.count

            let zip64Extra: [UInt8] = member.forceZip64
                ? [0x01, 0x00, 0x10, 0x00]
                + le64(UInt64(member.contents.count)) + le64(UInt64(stored.count))
                : []

            output += le32(ZipFormat.localFileHeaderSignature)
            output += le16(member.forceZip64 ? 45 : 20)
            output += le16(1 << 11)
            output += le16(method)
            output += le16(0) + le16(0x0021)
            output += le32(crc)
            output += le32(member.forceZip64 ? ZipFormat.zip64Sentinel32 : UInt32(stored.count))
            output += le32(member.forceZip64 ? ZipFormat.zip64Sentinel32 : UInt32(member.contents.count))
            output += le16(UInt16(name.count))
            output += le16(UInt16(zip64Extra.count))
            output += name
            output += zip64Extra
            output += stored

            directory += le32(ZipFormat.centralDirectorySignature)
            directory += le16(0x031E)
            directory += le16(member.forceZip64 ? 45 : 20)
            directory += le16(1 << 11)
            directory += le16(method)
            directory += le16(0) + le16(0x0021)
            directory += le32(crc)
            directory += le32(member.forceZip64 ? ZipFormat.zip64Sentinel32 : UInt32(stored.count))
            directory += le32(member.forceZip64 ? ZipFormat.zip64Sentinel32 : UInt32(member.contents.count))
            directory += le16(UInt16(name.count))
            directory += le16(UInt16(zip64Extra.count))
            directory += le16(0) + le16(0) + le16(0)
            directory += le32(0)
            directory += le32(UInt32(localOffset))
            directory += name
            directory += zip64Extra
            count += 1
        }

        let directoryOffset = output.count
        output += directory
        output += le32(ZipFormat.endOfCentralDirectorySignature)
        output += le16(0) + le16(0)
        output += le16(UInt16(count)) + le16(UInt16(count))
        output += le32(UInt32(directory.count))
        output += le32(UInt32(directoryOffset))
        output += le16(UInt16(comment.count))
        output += comment
        return Data(output)
    }

    /// Raw DEFLATE.
    ///
    /// Written here rather than called out to `MiniZip.Deflate`: that file is A2's, and a reader
    /// test whose input comes from the writer proves only that the two agree, which is exactly
    /// the failure both of them exist to catch.
    private static func deflate(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        let capacity = bytes.count + bytes.count / 2 + 128
        var output = [UInt8](repeating: 0, count: capacity)
        let produced = output.withUnsafeMutableBufferPointer { destination in
            bytes.withUnsafeBufferPointer { source in
                compression_encode_buffer(
                    destination.baseAddress!, capacity,
                    source.baseAddress!, source.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        precondition(produced > 0, "deflate produced nothing for \(bytes.count) bytes")
        return Array(output[0 ..< produced])
    }

    private static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        (0 ..< 4).map { UInt8((value >> UInt32($0 * 8)) & 0xFF) }
    }

    private static func le64(_ value: UInt64) -> [UInt8] {
        (0 ..< 8).map { UInt8((value >> UInt64($0 * 8)) & 0xFF) }
    }
}

/// Rebuilds a real fixture with one part's text changed.
///
/// For the handful of tests that need a *nearly* valid workbook — one attribute or one content
/// type away from the corpus — which is a shape it would be wasteful to add a fixture for and
/// dishonest to hand-write from scratch.
enum RepackagedArchive {
    static func replacing(
        _ path: String,
        in original: Data,
        with transform: (String) -> String
    ) throws -> Data {
        let archive = try ZipReader.read(original, name: "original")
        var members: [TestArchive.Member] = []
        for entry in archive.entries {
            let bytes = try archive.bytes(of: entry)
            let contents = entry.path == path
                ? Array(transform(String(decoding: bytes, as: UTF8.self)).utf8)
                : bytes
            members.append(
                TestArchive.Member(
                    path: entry.path,
                    contents: contents,
                    deflate: entry.compressionMethod == .deflate
                )
            )
        }
        return TestArchive.build(members)
    }
}
