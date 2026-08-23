import Foundation
import SheetModel
import Testing
@testable import TestSupport

@Suite("FailingFileSystem")
struct FailingFileSystemTests {
    @Test("a clean wrapper passes everything through and counts it")
    func passthrough() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-passthrough")
        defer { directory.remove() }

        let filesystem = FailingFileSystem()
        let target = directory.file("book.xlsx")
        try filesystem.writeFile(Data("hello".utf8), to: target)
        let read = try filesystem.readFile(at: target)

        #expect(String(decoding: read, as: UTF8.self) == "hello")
        #expect(filesystem.count(of: .write) == 1)
        #expect(filesystem.count(of: .read) == 1)
        #expect(!filesystem.didInjectFailure)
        #expect(filesystem.summary.contains("write=1"))
    }

    @Test("a rename failure leaves the original byte-identical — the whole point of the tool")
    func renameFailureKeepsTheOriginal() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-rename")
        defer { directory.remove() }

        let original = Data("the user's real workbook".utf8)
        let destination = try directory.write(original, to: "book.xlsx")
        let temporary = try directory.write(Data("the new contents".utf8), to: "book.xlsx.tmp")

        let filesystem = FailingFileSystem(failures: [.renameFails(path: destination.path)])
        #expect(throws: SheetError.self) {
            try filesystem.moveItem(at: temporary, to: destination)
        }

        #expect(try filesystem.readFile(at: destination) == original)
        #expect(filesystem.didInjectFailure)
    }

    @Test("an injected write failure leaves a truncated file, which is what atomicity must survive")
    func partialWrite() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-partial")
        defer { directory.remove() }

        let filesystem = FailingFileSystem(failures: [.diskFullDuringWrite()])
        filesystem.setPartialWriteFraction(0.25)
        let target = directory.file("scratch.bin")
        let payload = Data(repeating: 0xAB, count: 400)

        #expect(throws: SheetError.self) { try filesystem.writeFile(payload, to: target) }

        let landed = try Data(contentsOf: target)
        #expect(landed.count == 100)
        #expect(landed.count < payload.count, "a writer that treats this as success has a bug worth finding")
    }

    @Test("a write failure with a zero fraction writes nothing at all")
    func noPartialWrite() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-nopartial")
        defer { directory.remove() }

        let filesystem = FailingFileSystem(failures: [.diskFullDuringWrite()])
        filesystem.setPartialWriteFraction(0)
        let target = directory.file("scratch.bin")

        #expect(throws: SheetError.self) { try filesystem.writeFile(Data(repeating: 1, count: 10), to: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test("occurrence targets one call, so the retry after a failure gets through")
    func occurrenceTargeting() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-occurrence")
        defer { directory.remove() }

        let filesystem = FailingFileSystem(failures: [
            FileSystemFailure(operation: .write, occurrence: 2, error: .diskFull(path: "x")),
        ])
        try filesystem.writeFile(Data("a".utf8), to: directory.file("one"))
        #expect(throws: SheetError.self) { try filesystem.writeFile(Data("b".utf8), to: directory.file("two")) }
        try filesystem.writeFile(Data("c".utf8), to: directory.file("three"))

        #expect(filesystem.count(of: .write) == 3)
        #expect(filesystem.events.count { $0.wasInjected } == 1)
    }

    @Test("pathContains scopes a failure to one file")
    func pathScoping() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-path")
        defer { directory.remove() }

        let filesystem = FailingFileSystem(failures: [
            FileSystemFailure(
                operation: .write, occurrence: nil, pathContains: "sensitive", error: .fileNotWritable(
                    path: "x", underlying: "injected"
                )
            ),
        ])
        try filesystem.writeFile(Data("ok".utf8), to: directory.file("ordinary.txt"))
        #expect(throws: SheetError.self) {
            try filesystem.writeFile(Data("no".utf8), to: directory.file("sensitive.txt"))
        }
    }

    @Test("clearFailures makes the wrapper transparent again")
    func clearing() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-clear")
        defer { directory.remove() }

        let filesystem = FailingFileSystem(failingAt: .write, with: .diskFull(path: "x"))
        #expect(throws: SheetError.self) { try filesystem.writeFile(Data(), to: directory.file("a")) }
        filesystem.clearFailures()
        try filesystem.writeFile(Data("fine".utf8), to: directory.file("b"))
    }

    @Test("the event log is a work-done metric a loaded machine cannot distort")
    func eventLogIsDeterministic() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-log")
        defer { directory.remove() }

        let filesystem = FailingFileSystem()
        let target = try directory.write("x", to: "a.txt")
        _ = filesystem.fileExists(at: target)
        _ = try filesystem.readFile(at: target)
        _ = try filesystem.contentsOfDirectory(at: directory.url)

        #expect(filesystem.events.map(\.operation) == [.stat, .read, .listDirectory])
        #expect(filesystem.events.map(\.index) == [1, 2, 3])
    }

    @Test("an injected stat failure makes the file look absent, on the shared stat counter")
    func statInjection() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-stat")
        defer { directory.remove() }
        let target = try directory.write("x", to: "a.txt")

        let filesystem = FailingFileSystem(failures: [
            FileSystemFailure(operation: .stat, occurrence: 2, error: .fileVanished(path: target.path)),
        ])
        #expect(filesystem.fileExists(at: target), "first stat: the file is there")
        #expect(!filesystem.fileExists(at: target), "second stat: injected, so it reads as absent")
        #expect(filesystem.count(of: .stat) == 2)
        // fileExists and fileSize share the counter, so an occurrence means the Nth stat of
        // either kind rather than the Nth of whichever entry point was used.
        #expect(throws: Never.self) { try filesystem.fileSize(at: target) }
        #expect(filesystem.count(of: .stat) == 3)
    }

    @Test("a read-only directory produces a real errno failure, not an injected one")
    func realPermissionFailure() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-readonly")
        defer {
            directory.makeWritable()
            directory.remove()
        }

        let filesystem = FailingFileSystem()
        #expect(directory.makeReadOnly())
        #expect(throws: SheetError.self) {
            try filesystem.writeFile(Data("nope".utf8), to: directory.file("blocked.txt"))
        }
        #expect(!filesystem.didInjectFailure, "this failure came from the kernel, which is the point")
    }

    @Test("writing where a directory sits fails for real")
    func directoryInTheWay() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-eisdir")
        defer { directory.remove() }

        let blocked = try #require(directory.placeDirectory(named: "book.xlsx"))
        let filesystem = RealFileSystem()
        #expect(throws: SheetError.self) { try filesystem.writeFile(Data("x".utf8), to: blocked) }
    }

    @Test("a broken symlink reads as a missing file rather than as a present one")
    func brokenSymlink() throws {
        let directory = try TemporaryDirectory(prefix: "ffs-symlink")
        defer { directory.remove() }

        let link = try #require(directory.placeBrokenSymlink(named: "dangling.xlsx"))
        let filesystem = RealFileSystem()
        #expect(!filesystem.fileExists(at: link))
        #expect(throws: SheetError.self) { _ = try filesystem.readFile(at: link) }
    }

    @Test("withTemporaryDirectory cleans up even when the body throws")
    func scopedCleanup() {
        var captured: URL?
        #expect(throws: SheetError.self) {
            try TemporaryDirectory.withTemporaryDirectory { directory in
                captured = directory.url
                try directory.write("x", to: "a.txt")
                throw SheetError.cancelled(operation: "on purpose")
            }
        }
        #expect(captured != nil)
        if let captured {
            #expect(!FileManager.default.fileExists(atPath: captured.path))
        }
    }

    @Test("two temporary directories never collide")
    func uniqueDirectories() throws {
        let first = try TemporaryDirectory()
        let second = try TemporaryDirectory()
        defer {
            first.remove()
            second.remove()
        }
        #expect(first.url != second.url)
    }
}
