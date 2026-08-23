//
//  ZipWriterTests.swift
//  SheetFormatTests
//
//  The archive layer, where "byte-identical" is either true by construction or not at all.
//

import Foundation
import MiniZip
@testable import SheetFormat
import SheetModel
import Testing

@Suite("ZIP writer")
struct ZipWriterTests {
    @Test("a fresh entry round-trips through the archive")
    func freshEntriesRoundTrip() throws {
        let payload = Data(String(repeating: "spreadsheet ", count: 400).utf8)
        let entry = ZipWriter.entry(path: "xl/worksheets/sheet1.xml", contents: payload)
        let archive = try FixtureArchive(try ZipWriter.archive([entry]))

        #expect(archive.paths == ["xl/worksheets/sheet1.xml"])
        #expect(try archive.contents("xl/worksheets/sheet1.xml") == payload)
        #expect(try #require(archive["xl/worksheets/sheet1.xml"]).crc32 == DeflateCodec.crc32(payload))
        #expect(try #require(archive["xl/worksheets/sheet1.xml"]).compressionMethod == .deflate)
    }

    @Test("an already-compressed entry is copied, not re-compressed")
    func passthroughCopiesStoredBytes() throws {
        let payload = Data((0 ..< 2048).map { UInt8($0 % 251) })
        let source = ZipWriter.entry(path: "xl/media/image1.png", contents: payload)

        // Round it through the archive twice: the second write must produce the same stored
        // bytes as the first, which only happens if nothing re-deflated them.
        let once = try FixtureArchive(try ZipWriter.archive([source]))
        let carried = try #require(once["xl/media/image1.png"])
        let twice = try FixtureArchive(try ZipWriter.archive([carried]))
        let final = try #require(twice["xl/media/image1.png"])

        #expect(final.compressedData == carried.compressedData)
        #expect(final.crc32 == carried.crc32)
        #expect(final.uncompressedSize == carried.uncompressedSize)
        #expect(try twice.contents("xl/media/image1.png") == payload)
    }

    @Test("incompressible content is stored rather than grown")
    func incompressibleContentIsStored() throws {
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0 ..< 4096).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
        let entry = ZipWriter.entry(path: "xl/media/noise.bin", contents: payload)
        #expect(entry.compressionMethod == .store)
        #expect(entry.compressedData.count == payload.count)

        let archive = try FixtureArchive(try ZipWriter.archive([entry]))
        #expect(try archive.contents("xl/media/noise.bin") == payload)
    }

    @Test("an empty entry is legal")
    func emptyEntries() throws {
        let archive = try FixtureArchive(try ZipWriter.archive([
            ZipWriter.entry(path: "empty.xml", contents: Data()),
        ]))
        #expect(try archive.contents("empty.xml").isEmpty)
        #expect(try #require(archive["empty.xml"]).crc32 == 0)
    }

    @Test("entry order is preserved exactly")
    func orderIsPreserved() throws {
        let paths = ["c.xml", "a.xml", "b/z.xml", "b/a.xml"]
        let archive = try FixtureArchive(try ZipWriter.archive(
            paths.map { ZipWriter.entry(path: $0, contents: Data($0.utf8)) }
        ))
        #expect(archive.paths == paths)
    }

    @Test("the data-descriptor flag is cleared, because the sizes are written inline")
    func dataDescriptorFlagIsCleared() throws {
        var entry = ZipWriter.entry(path: "a.xml", contents: Data("hello".utf8))
        entry.generalPurposeFlags |= ZipGeneralPurposeFlags.hasDataDescriptor.rawValue
        let archive = try FixtureArchive(try ZipWriter.archive([entry]))
        let written = try #require(archive["a.xml"])
        #expect(!written.flags.contains(.hasDataDescriptor))
        #expect(written.compressedSize == UInt64(written.compressedData.count))
    }

    @Test("a non-ASCII entry name gets the UTF-8 flag")
    func unicodeNamesAreFlagged() throws {
        let archive = try FixtureArchive(try ZipWriter.archive([
            ZipWriter.entry(path: "xl/worksheets/naïve 🎉.xml", contents: Data("x".utf8)),
        ]))
        let written = try #require(archive["xl/worksheets/naïve 🎉.xml"])
        #expect(written.flags.contains(.utf8Name))
    }

    @Test("extra fields survive, except a stale Zip64 one")
    func extraFieldsSurvive() throws {
        // 0x5455 extended timestamp, then a Zip64 field that describes some other archive.
        let timestamp: [UInt8] = [0x55, 0x54, 0x05, 0x00, 0x03, 0x01, 0x02, 0x03, 0x04]
        let staleZip64: [UInt8] = [0x01, 0x00, 0x10, 0x00] + [UInt8](repeating: 0xEE, count: 16)
        var entry = ZipWriter.entry(path: "a.xml", contents: Data("hello".utf8))
        entry.extraFieldCentral = Data(timestamp + staleZip64)
        entry.extraFieldLocal = Data(timestamp)

        let archive = try FixtureArchive(try ZipWriter.archive([entry]))
        let written = try #require(archive["a.xml"])
        #expect([UInt8](written.extraFieldCentral) == timestamp)
        #expect([UInt8](written.extraFieldLocal) == timestamp)
    }

    @Test("names that would escape the archive are refused", arguments: [
        "../secrets", "a/../../b", "/etc/passwd", "C:\\Windows\\system32", "a\\b", "",
    ])
    func hostileNamesAreRefused(_ path: String) {
        #expect(throws: SheetError.self) {
            try ZipWriter.archive([ZipWriter.entry(path: path, contents: Data())])
        }
    }

    @Test("a name with an embedded NUL is refused")
    func nulNamesAreRefused() {
        let path = "sheet\u{0000}.xml"
        #expect(throws: SheetError.archivePathTraversal(entryName: path)) {
            try ZipWriter.archive([ZipWriter.entry(path: path, contents: Data())])
        }
    }

    @Test("two entries with the same name are refused")
    func duplicateNamesAreRefused() {
        #expect(throws: SheetError.archiveDuplicateEntry(name: "a.xml")) {
            try ZipWriter.archive([
                ZipWriter.entry(path: "a.xml", contents: Data("one".utf8)),
                ZipWriter.entry(path: "a.xml", contents: Data("two".utf8)),
            ])
        }
    }

    @Test("past 65,534 entries the archive switches to Zip64")
    func manyEntriesTriggerZip64() throws {
        let count = ZipFormat.maximumNonZip64Entries + 6
        var entries: [ZipEntry] = []
        entries.reserveCapacity(count)
        for index in 0 ..< count {
            // Built directly rather than through `entry(path:contents:)`: deflating 65,000
            // one-byte payloads costs seconds and proves nothing this test is about.
            let payload = Data([UInt8(index % 251)])
            entries.append(ZipEntry(
                path: "e/\(index).bin",
                compressedData: payload,
                compressionMethod: .store,
                crc32: DeflateCodec.crc32(payload),
                compressedSize: 1,
                uncompressedSize: 1
            ))
        }
        let bytes = try ZipWriter.archive(entries)

        // The Zip64 end-of-central-directory record and its locator are both present…
        #expect(contains(bytes, signature: ZipFormat.zip64EndOfCentralDirectorySignature))
        #expect(contains(bytes, signature: ZipFormat.zip64EndOfCentralDirectoryLocatorSignature))
        // …and the classic record carries the sentinel instead of a truncated count.
        let tail = [UInt8](bytes.suffix(22))
        let recorded = UInt16(tail[10]) | (UInt16(tail[11]) << 8)
        #expect(recorded == ZipFormat.zip64Sentinel16)

        let archive = try FixtureArchive(bytes)
        #expect(archive.entries.count == count)
        #expect(try archive.contents("e/0.bin") == Data([0]))
        #expect(try archive.contents("e/\(count - 1).bin") == Data([UInt8((count - 1) % 251)]))
    }

    @Test("a declared size that does not match the payload is refused")
    func inconsistentEntriesAreRefused() {
        var entry = ZipWriter.entry(path: "a.xml", contents: Data("hello".utf8))
        entry.compressedSize += 10
        #expect(throws: SheetError.self) {
            try ZipWriter.archive([entry])
        }
    }

    @Test("CRC-32 agrees with the reference vectors")
    func crcVectors() {
        #expect(DeflateCodec.crc32(Data()) == 0)
        #expect(DeflateCodec.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(DeflateCodec.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    @Test("deflate and inflate are inverses, and the inflate cap holds")
    func deflateRoundTrip() throws {
        let payload = Data(String(repeating: "the quick brown fox ", count: 5000).utf8)
        let deflated = try #require(DeflateCodec.deflate(payload))
        #expect(deflated.count < payload.count / 4)
        #expect(try DeflateCodec.inflate(deflated, path: "a.xml") == payload)

        #expect(throws: SheetError.self) {
            try DeflateCodec.inflate(deflated, path: "a.xml", limit: 1024)
        }
        #expect(throws: SheetError.self) {
            try DeflateCodec.inflate(Data([0xFF, 0xFF, 0xFF, 0xFF]), path: "a.xml")
        }
    }

    private func contains(_ data: Data, signature: UInt32) -> Bool {
        let needle: [UInt8] = [
            UInt8(signature & 0xFF), UInt8((signature >> 8) & 0xFF),
            UInt8((signature >> 16) & 0xFF), UInt8((signature >> 24) & 0xFF),
        ]
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return false }
        for index in 0 ... (bytes.count - 4) where Array(bytes[index ..< index + 4]) == needle {
            return true
        }
        return false
    }
}
