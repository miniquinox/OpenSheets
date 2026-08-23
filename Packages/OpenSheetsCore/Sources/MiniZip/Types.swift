import Foundation
public import SheetModel

// A0 owns this file. A1 owns `Reader.swift` and `Inflate.swift`; A2 owns `Writer.swift` and
// `Deflate.swift`. All three of us share this target, so nobody edits anyone else's file.
//
// There is no zip logic here — only the constants and shapes the reader and the writer both
// need in order to agree without ever having seen each other's code.

/// One entry in a ZIP archive.
///
/// Defined in `SheetModel` and re-exported here. It has to live there because
/// ``SheetModel/Workbook/passthrough`` holds entries and `SheetModel` cannot depend on
/// `MiniZip` — the dependency runs the other way. Use whichever spelling reads better; they
/// are the same type.
public typealias ZipEntry = SheetModel.ZipEntry

/// How an entry's bytes are stored. See ``SheetModel/CompressionMethod``.
public typealias CompressionMethod = SheetModel.CompressionMethod

/// The MS-DOS timestamp fields an entry carries. See ``SheetModel/DOSTimestamp``.
public typealias DOSTimestamp = SheetModel.DOSTimestamp

/// The fixed numbers in the ZIP format.
///
/// Both the reader and the writer need these, and a mismatched signature produces an archive
/// that opens in one tool and not another — so they are written down once.
public enum ZipFormat {
    /// `PK\3\4` — precedes every local file header.
    public static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    /// `PK\1\2` — precedes every central directory entry.
    public static let centralDirectorySignature: UInt32 = 0x0201_4B50
    /// `PK\5\6` — the end-of-central-directory record.
    public static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    /// `PK\6\6` — the Zip64 end-of-central-directory record.
    public static let zip64EndOfCentralDirectorySignature: UInt32 = 0x0606_4B50
    /// `PK\6\7` — the Zip64 end-of-central-directory locator.
    public static let zip64EndOfCentralDirectoryLocatorSignature: UInt32 = 0x0706_4B50
    /// `PK\7\8` — the optional data descriptor that follows an entry written with bit 3 set.
    public static let dataDescriptorSignature: UInt32 = 0x0807_4B50

    /// Bytes in a local file header before the variable-length name and extra field.
    public static let localFileHeaderSize = 30
    /// Bytes in a central directory entry before its variable-length fields.
    public static let centralDirectoryEntrySize = 46
    /// Bytes in an end-of-central-directory record before its comment.
    public static let endOfCentralDirectorySize = 22

    /// The sentinel a 32-bit size or offset field carries when the real value is in a Zip64
    /// extra field. Seeing this and not looking for the extra field is how a large archive
    /// gets read as a corrupt one.
    public static let zip64Sentinel32: UInt32 = 0xFFFF_FFFF
    /// The 16-bit counterpart, for entry counts.
    public static let zip64Sentinel16: UInt16 = 0xFFFF

    /// Extra-field header id for Zip64 sizes and offsets.
    public static let zip64ExtraFieldID: UInt16 = 0x0001
    /// Extra-field header id for the extended (Unix, 1-second) timestamps.
    public static let extendedTimestampExtraFieldID: UInt16 = 0x5455

    /// Largest value a 32-bit size field can hold. Anything larger forces Zip64.
    public static let maximumNonZip64Bytes: UInt64 = 0xFFFF_FFFE
    /// Largest entry count a non-Zip64 archive can hold.
    public static let maximumNonZip64Entries = 65_534

    /// The end-of-central-directory record can sit up to this far from the end of the file,
    /// because of its variable-length comment. A reader scans backwards over this window.
    public static let maximumEndOfCentralDirectorySearch = 65_557
}

/// Bits in an entry's general-purpose flag word.
///
/// Two of these change how an entry must be *written*, so they have to survive a round-trip
/// rather than being recomputed from scratch.
public struct ZipGeneralPurposeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// Bit 0 — the entry is encrypted. We refuse these.
    public static let encrypted = ZipGeneralPurposeFlags(rawValue: 1 << 0)

    /// Bit 3 — sizes and CRC follow the data in a descriptor rather than sitting in the local
    /// header. Streaming writers set this, so real `.xlsx` files from web services have it.
    /// A reader that trusts the local header's zeroes on such an entry reads nothing.
    public static let hasDataDescriptor = ZipGeneralPurposeFlags(rawValue: 1 << 3)

    /// Bit 11 — the entry name is UTF-8 rather than CP437. Emoji in a sheet name end up here.
    public static let utf8Name = ZipGeneralPurposeFlags(rawValue: 1 << 11)
}

extension ZipEntry {
    /// This entry's general-purpose flags as an option set.
    public var flags: ZipGeneralPurposeFlags {
        ZipGeneralPurposeFlags(rawValue: generalPurposeFlags)
    }

    /// Whether this entry needs Zip64 fields to be written correctly.
    public var requiresZip64: Bool {
        compressedSize > ZipFormat.maximumNonZip64Bytes || uncompressedSize > ZipFormat.maximumNonZip64Bytes
    }
}
