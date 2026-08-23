//
//  AtomicWriteTests.swift
//  SheetFormatTests
//
//  "The original is still there" is the only acceptable outcome of a failed save.
//

import Darwin
import Foundation
@testable import SheetFormat
import SheetModel
import Testing

@Suite("Atomic save")
struct AtomicWriteTests {
    /// A scratch directory that cleans itself up.
    struct Scratch: ~Copyable {
        let url: URL

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("opensheets-a2-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: url) }

        var leftovers: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
                .filter { $0.hasPrefix(".opensheets-") }
        }
    }

    @Test("writing a new file leaves a correct fingerprint")
    func writingANewFile() throws {
        let scratch = try Scratch()
        let target = scratch.url.appendingPathComponent("book.xlsx")
        let payload = Data("hello world".utf8)

        let fingerprint = try AtomicFileWriter.write(payload, to: target)

        #expect(try Data(contentsOf: target) == payload)
        #expect(fingerprint.size == payload.count)
        #expect(fingerprint.contentHash == SavedFileFingerprint.hash(payload))
        #expect(fingerprint.inode != 0)
        #expect(fingerprint.path == target.path)
        #expect(scratch.leftovers.isEmpty)

        // Reading it back off disk agrees.
        let observed = try AtomicFileWriter.fingerprint(of: target)
        #expect(observed.matches(fingerprint))
    }

    @Test("an interruption before the replace leaves the original untouched", arguments: [
        AtomicFileWriter.Phase.temporaryFileWritten,
        .temporaryFileSynced,
        .metadataCopied,
        .beforeReplace,
    ])
    func interruptionLeavesTheOriginalIntact(_ phase: AtomicFileWriter.Phase) throws {
        let scratch = try Scratch()
        let target = scratch.url.appendingPathComponent("book.xlsx")
        let original = Data("the original contents, which must survive".utf8)
        try original.write(to: target)

        struct Interrupted: Error {}
        #expect(throws: (any Error).self) {
            try AtomicFileWriter.write(Data("replacement".utf8), to: target) { reached in
                if reached == phase { throw Interrupted() }
            }
        }

        #expect(try Data(contentsOf: target) == original, "the original was damaged at \(phase)")
        #expect(scratch.leftovers.isEmpty, "a temp file was left behind at \(phase)")
    }

    @Test("permissions and extended attributes survive a replace")
    func metadataIsPreserved() throws {
        let scratch = try Scratch()
        let target = scratch.url.appendingPathComponent("book.xlsx")
        try Data("original".utf8).write(to: target)
        chmod(target.path, 0o640)

        // A Finder tag lives in an extended attribute; losing them on save loses the tag.
        let tag = Data("orange".utf8)
        let set = tag.withUnsafeBytes { raw in
            setxattr(target.path, "com.apple.metadata:_kMDItemUserTags", raw.baseAddress, raw.count, 0, 0)
        }
        #expect(set == 0)

        try AtomicFileWriter.write(Data("replacement".utf8), to: target)

        var status = stat()
        #expect(stat(target.path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o640)

        let size = getxattr(target.path, "com.apple.metadata:_kMDItemUserTags", nil, 0, 0, 0)
        #expect(size == tag.count, "the extended attribute did not survive")
        var value = [UInt8](repeating: 0, count: max(size, 1))
        #expect(getxattr(target.path, "com.apple.metadata:_kMDItemUserTags", &value, size, 0, 0) == size)
        #expect(Data(value.prefix(max(size, 0))) == tag)
        #expect(scratch.leftovers.isEmpty)
    }

    @Test("the inode changes, which is what makes the fingerprint useful")
    func replaceChangesTheInode() throws {
        let scratch = try Scratch()
        let target = scratch.url.appendingPathComponent("book.xlsx")
        let first = try AtomicFileWriter.write(Data("one".utf8), to: target)
        let second = try AtomicFileWriter.write(Data("two".utf8), to: target)
        #expect(first.inode != second.inode)
        #expect(first.deviceID == second.deviceID)
        #expect(!first.matches(second))
    }

    @Test("a directory that is not there fails cleanly")
    func missingDirectoryFails() throws {
        let scratch = try Scratch()
        let target = scratch.url
            .appendingPathComponent("gone")
            .appendingPathComponent("book.xlsx")
        #expect(throws: SheetError.self) {
            try AtomicFileWriter.write(Data("x".utf8), to: target)
        }
        #expect(scratch.leftovers.isEmpty)
    }

    @Test("a read-only directory fails cleanly and leaves the original alone")
    func readOnlyDirectoryFails() throws {
        let scratch = try Scratch()
        let locked = scratch.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let target = locked.appendingPathComponent("book.xlsx")
        let original = Data("original".utf8)
        try original.write(to: target)
        chmod(locked.path, 0o500)
        defer { chmod(locked.path, 0o755) }

        #expect(throws: SheetError.self) {
            try AtomicFileWriter.write(Data("replacement".utf8), to: target)
        }
        #expect(try Data(contentsOf: target) == original)
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: locked.path)) ?? [])
            .filter { $0.hasPrefix(".opensheets-") }
        #expect(leftovers.isEmpty)
    }

    @Test("errno becomes the error whose message says what to do about it", arguments: [
        (ENOSPC, "file.diskFull"),
        (EDQUOT, "file.diskFull"),
        (EACCES, "file.notWritable"),
        (EROFS, "file.notWritable"),
        (ENOENT, "file.vanished"),
        (ENOTCONN, "file.volumeUnavailable"),
        (EBUSY, "file.locked"),
    ])
    func errnoMapping(_ code: Int32, _ expected: String) {
        // A full disk wants "free some space", a read-only volume wants "this file cannot be
        // written", an unmounted share wants "reconnect the drive". "Operation failed (errno 28)"
        // wants nothing, which is why PLAN.md §9 lists them separately.
        #expect(AtomicFileWriter.posixError(code, path: "/tmp/x").code == expected)
    }

    @Test("a whole workbook save is atomic too")
    func savingAWorkbookIsAtomic() throws {
        let scratch = try Scratch()
        let target = scratch.url.appendingPathComponent("book.xlsx")
        let original = try HandBuiltPackage.archiveData()
        try original.write(to: target)

        let loaded = try HandBuiltPackage.load()
        var workbook = loaded.workbook
        let first = try #require(workbook.sheets.first)
        try workbook.withSheet(first.id) { sheet in
            try sheet.cells.setCell(Cell.number(1), at: .origin)
        }
        var edits = WorkbookEditTracker()
        edits.noteCellsChanged(in: try #require(workbook[first.id]))

        struct Interrupted: Error {}
        #expect(throws: (any Error).self) {
            try XLSXWriter.save(workbook, edits: edits, to: target) { phase in
                if phase == .beforeReplace { throw Interrupted() }
            }
        }
        #expect(try Data(contentsOf: target) == original)
        #expect(scratch.leftovers.isEmpty)

        let fingerprint = try XLSXWriter.save(workbook, edits: edits, to: target)
        #expect(try Data(contentsOf: target).count == fingerprint.size)
        #expect(try Data(contentsOf: target) != original)
        #expect(scratch.leftovers.isEmpty)
    }
}
