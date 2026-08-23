import Foundation
@testable import MiniZip
import SheetModel
import Testing

/// A0 owns `MiniZip/Types.swift`, so A0 tests it. A1's reader tests and A2's writer tests live
/// in their own files in this target.
@Suite("MiniZip shared types")
struct MiniZipTypesTests {
    @Test("the signatures are the ones on the wire")
    func signatures() {
        // "PK\3\4" little-endian is 0x04034B50 — spelled out so a typo cannot hide.
        #expect(ZipFormat.localFileHeaderSignature == 0x0403_4B50)
        #expect(ZipFormat.centralDirectorySignature == 0x0201_4B50)
        #expect(ZipFormat.endOfCentralDirectorySignature == 0x0605_4B50)
        #expect(ZipFormat.zip64EndOfCentralDirectorySignature == 0x0606_4B50)
        #expect(ZipFormat.zip64EndOfCentralDirectoryLocatorSignature == 0x0706_4B50)
        #expect(ZipFormat.dataDescriptorSignature == 0x0807_4B50)

        for signature in [
            ZipFormat.localFileHeaderSignature, ZipFormat.centralDirectorySignature,
            ZipFormat.endOfCentralDirectorySignature,
        ] {
            #expect(UInt8(signature & 0xFF) == UInt8(ascii: "P"))
            #expect(UInt8((signature >> 8) & 0xFF) == UInt8(ascii: "K"))
        }
    }

    @Test("the fixed header sizes are right")
    func headerSizes() {
        #expect(ZipFormat.localFileHeaderSize == 30)
        #expect(ZipFormat.centralDirectoryEntrySize == 46)
        #expect(ZipFormat.endOfCentralDirectorySize == 22)
        // The end record can be pushed back by a 64 KB comment, so a reader scans this far.
        #expect(ZipFormat.maximumEndOfCentralDirectorySearch == 22 + 65_535)
    }

    @Test("the Zip64 sentinels and thresholds line up")
    func zip64Constants() {
        #expect(ZipFormat.zip64Sentinel32 == 0xFFFF_FFFF)
        #expect(ZipFormat.zip64Sentinel16 == 0xFFFF)
        #expect(ZipFormat.maximumNonZip64Bytes == UInt64(ZipFormat.zip64Sentinel32) - 1)
        #expect(ZipFormat.maximumNonZip64Entries == Int(ZipFormat.zip64Sentinel16) - 1)
        #expect(ZipFormat.zip64ExtraFieldID == 0x0001)
        #expect(ZipFormat.extendedTimestampExtraFieldID == 0x5455)
    }

    @Test("general-purpose flags decode the bits that change how an entry is written")
    func generalPurposeFlags() {
        let streamed = ZipEntry(path: "a", compressedData: Data(), generalPurposeFlags: 0x0008)
        #expect(streamed.flags.contains(.hasDataDescriptor))
        #expect(!streamed.flags.contains(.encrypted))
        #expect(!streamed.flags.contains(.utf8Name))

        let utf8Named = ZipEntry(path: "📊.xml", compressedData: Data(), generalPurposeFlags: 0x0800)
        #expect(utf8Named.flags.contains(.utf8Name))

        let encrypted = ZipEntry(path: "a", compressedData: Data(), generalPurposeFlags: 0x0001)
        #expect(encrypted.flags.contains(.encrypted))
    }

    @Test("Zip64 is required past the 32-bit size limit")
    func zip64Threshold() {
        var big = ZipEntry(path: "big.bin", compressedData: Data())
        big.uncompressedSize = 5_000_000_000
        #expect(big.requiresZip64)

        var wide = ZipEntry(path: "wide.bin", compressedData: Data())
        wide.compressedSize = ZipFormat.maximumNonZip64Bytes + 1
        #expect(wide.requiresZip64)

        #expect(!ZipEntry(path: "small.bin", compressedData: Data([1, 2, 3])).requiresZip64)
    }

    @Test("the typealiases really do point at SheetModel's types")
    func typeAliases() {
        // If these ever diverge, `Workbook.passthrough` and the reader stop agreeing.
        #expect(MiniZip.ZipEntry.self == SheetModel.ZipEntry.self)
        #expect(MiniZip.CompressionMethod.self == SheetModel.CompressionMethod.self)
        #expect(MiniZip.DOSTimestamp.self == SheetModel.DOSTimestamp.self)
    }
}
