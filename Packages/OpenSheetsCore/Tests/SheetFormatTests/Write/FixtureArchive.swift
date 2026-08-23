//
//  FixtureArchive.swift
//  SheetFormatTests
//
//  A2's own, deliberately small, read side.
//
//  A1 owns `MiniZip.Reader` and the real `XLSX/Read` parser and is writing them concurrently.
//  The writer's acceptance criteria are all of the form "read → modify → write → compare", so
//  the tests need *a* reader — and waiting for someone else's would mean the write path went
//  untested until both landed. This one exists only to feed the writer's tests: it is pointed
//  exclusively at `Fixtures/`, which is trusted input, so it has none of the hardening the real
//  reader must have and must never be used outside tests.
//

import Foundation
import MiniZip
@testable import SheetFormat
import SheetModel

/// The repository's `Fixtures/` directory.
///
/// Found by walking up from this source file rather than from the working directory, which
/// differs between `swift test`, Xcode, and CI. `OPENSHEETS_FIXTURES` overrides it.
enum FixtureRoot {
    static let url: URL = {
        if let override = ProcessInfo.processInfo.environment["OPENSHEETS_FIXTURES"] {
            return URL(fileURLWithPath: override)
        }
        for start in [URL(fileURLWithPath: #filePath), URL(fileURLWithPath: FileManager.default
                .currentDirectoryPath)] {
            var directory = start
            for _ in 0 ..< 10 {
                directory.deleteLastPathComponent()
                let candidate = directory.appendingPathComponent("Fixtures")
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("README.md").path) {
                    return candidate
                }
            }
        }
        return URL(fileURLWithPath: "Fixtures")
    }()

    static func url(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }
}

/// A minimal ZIP central-directory reader.
struct FixtureArchive {
    var entries: [ZipEntry]

    private var index: [String: Int]

    subscript(path: String) -> ZipEntry? {
        index[path].map { entries[$0] }
    }

    var paths: [String] { entries.map(\.path) }

    /// Inflated bytes for one entry.
    func contents(_ path: String) throws -> Data {
        guard let entry = self[path] else {
            throw SheetError.archiveEntryNotFound(path: path)
        }
        return try DeflateCodec.contents(of: entry)
    }

    /// Inflated text for one entry.
    func text(_ path: String) throws -> String {
        String(decoding: try contents(path), as: UTF8.self)
    }

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard let directoryStart = Self.endOfCentralDirectory(in: bytes) else {
            throw SheetError.archiveMalformed(detail: "no end-of-central-directory record")
        }

        var entries: [ZipEntry] = []
        var cursor = directoryStart
        while cursor + 46 <= bytes.count, Self.read32(bytes, cursor) == ZipFormat.centralDirectorySignature {
            let versionMadeBy = Self.read16(bytes, cursor + 4)
            let versionNeeded = Self.read16(bytes, cursor + 6)
            let flags = Self.read16(bytes, cursor + 8)
            let method = Self.read16(bytes, cursor + 10)
            let time = Self.read16(bytes, cursor + 12)
            let date = Self.read16(bytes, cursor + 14)
            let crc = Self.read32(bytes, cursor + 16)
            let compressedSize = UInt64(Self.read32(bytes, cursor + 20))
            let uncompressedSize = UInt64(Self.read32(bytes, cursor + 24))
            let nameLength = Int(Self.read16(bytes, cursor + 28))
            let extraLength = Int(Self.read16(bytes, cursor + 30))
            let commentLength = Int(Self.read16(bytes, cursor + 32))
            let internalAttributes = Self.read16(bytes, cursor + 36)
            let externalAttributes = Self.read32(bytes, cursor + 38)
            let localOffset = Int(Self.read32(bytes, cursor + 42))

            let nameStart = cursor + 46
            let name = String(decoding: bytes[nameStart ..< nameStart + nameLength], as: UTF8.self)
            let extraStart = nameStart + nameLength
            let centralExtra = Data(bytes[extraStart ..< extraStart + extraLength])
            let commentStart = extraStart + extraLength
            let comment = commentLength > 0
                ? String(decoding: bytes[commentStart ..< commentStart + commentLength], as: UTF8.self)
                : nil

            // The payload's real offset is behind the local header, whose name and extra field
            // lengths differ from the central directory's.
            let localNameLength = Int(Self.read16(bytes, localOffset + 26))
            let localExtraLength = Int(Self.read16(bytes, localOffset + 28))
            let payloadStart = localOffset + 30 + localNameLength + localExtraLength
            let localExtra = Data(
                bytes[(localOffset + 30 + localNameLength) ..< (localOffset + 30 + localNameLength + localExtraLength)]
            )
            let payload = Data(bytes[payloadStart ..< payloadStart + Int(compressedSize)])

            entries.append(ZipEntry(
                path: name,
                compressedData: payload,
                compressionMethod: CompressionMethod(rawValue: method),
                crc32: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                lastModified: DOSTimestamp(date: date, time: time),
                generalPurposeFlags: flags,
                versionMadeBy: versionMadeBy,
                versionNeeded: versionNeeded,
                externalAttributes: externalAttributes,
                internalAttributes: internalAttributes,
                extraFieldLocal: localExtra,
                extraFieldCentral: centralExtra,
                comment: comment
            ))
            cursor = commentStart + commentLength
        }

        self.entries = entries
        index = [:]
        for (position, entry) in entries.enumerated() { index[entry.path] = position }
    }

    init(contentsOf url: URL) throws {
        try self.init(try Data(contentsOf: url))
    }

    /// The entries as `OpaqueParts`, with the parts the model represents marked.
    func opaqueParts(modelled: Set<String>) -> OpaqueParts {
        OpaqueParts(entries: entries, modelled: modelled)
    }

    private static func endOfCentralDirectory(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        var cursor = bytes.count - 22
        let floor = max(0, bytes.count - ZipFormat.maximumEndOfCentralDirectorySearch)
        while cursor >= floor {
            if read32(bytes, cursor) == ZipFormat.endOfCentralDirectorySignature {
                return Int(read32(bytes, cursor + 16))
            }
            cursor -= 1
        }
        return nil
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
