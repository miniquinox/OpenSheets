import Darwin
import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// PLAN.md §5.2's "never write in place", from the angle that matters: what is on disk at every
/// instant the save could stop.
@Suite struct AtomicWriterTests {
    // MARK: - Failure at every stage

    /// **A save that fails at any stage leaves the original byte-identical and no temporary
    /// behind.**
    ///
    /// Run over every stage rather than a representative one, because a cleanup path that was
    /// forgotten is forgotten at exactly one stage, and it will not be the one somebody
    /// happened to test.
    @Test(arguments: AtomicWriteStage.allCases)
    func failureAtAnyStageLeavesTheOriginalIntact(stage: AtomicWriteStage) throws {
        let scratch = TemporaryDirectory("stage-\(stage.rawValue)")
        let file = scratch.file("book.xlsx", contents: "the original contents, all of them")
        let original = try #require(bytes(of: file))

        let options = AtomicWriter.Options(observer: { reached in
            if reached == stage { throw SheetError.cancelled(operation: "injected at \(reached.rawValue)") }
        })

        #expect(throws: SheetError.self) {
            try AtomicWriter().write(Data("the replacement contents".utf8), to: file, options: options)
        }

        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: scratch.url.path(percentEncoded: false))
            .filter { $0.hasPrefix(AtomicWriter.temporaryPrefix) }
        #expect(leftovers.isEmpty, "\(stage.rawValue) left \(leftovers)")

        if stage == .replaced {
            // Documented behaviour: by this stage the rename has happened. The file is the
            // *new* content, complete — never a mixture.
            #expect(bytes(of: file) == Data("the replacement contents".utf8))
        } else {
            #expect(bytes(of: file) == original, "\(stage.rawValue) damaged the original")
        }
    }

    /// A successful save reaches every stage in order, and the file holds the new bytes.
    @Test func successfulSaveVisitsEveryStageInOrder() throws {
        let scratch = TemporaryDirectory("stages")
        let file = scratch.file("book.xlsx")

        let seen = Recorder()
        let fingerprint = try AtomicWriter().write(
            Data("new".utf8),
            to: file,
            options: AtomicWriter.Options(observer: { seen.record($0) })
        )
        #expect(seen.stages == AtomicWriteStage.allCases)
        #expect(bytes(of: file) == Data("new".utf8))
        #expect(fingerprint.size == 3)
        #expect(fingerprint == (try FileFingerprint.capture(at: file)))
    }

    // MARK: - kill -9

    /// **A hard kill during a save leaves the original intact.**
    ///
    /// Two halves, because neither alone is honest:
    ///
    /// 1. The test above proves *our writer* never touches the destination before the rename —
    ///    exhaustively, at every stage.
    /// 2. This proves the sequence survives a real `SIGKILL` of a real process: a process
    ///    performing the same temp-then-rename dance is killed mid-write, and the original is
    ///    still byte-identical afterwards, with only a sweepable temporary left behind.
    @Test func killDuringASaveLeavesTheOriginalIntact() throws {
        let scratch = TemporaryDirectory("kill9")
        let file = scratch.file("book.xlsx", contents: String(repeating: "original-", count: 4096))
        let original = try #require(bytes(of: file))
        let directory = scratch.url.path(percentEncoded: false)
        let temporary = "\(directory)/\(AtomicWriter.temporaryPrefix)\(ULID().rawValue)\(AtomicWriter.temporarySuffix)"

        // The writer's exact sequence: a sibling temporary in the same directory, written to
        // slowly, and the destination untouched until a rename that never happens.
        let process = try #require(Shell.spawn(
            "for i in $(seq 1 200); do printf 'replacement-' >> '\(temporary)'; sleep 0.01; done; " +
                "mv '\(temporary)' '\(file.path(percentEncoded: false))'"
        ))
        Thread.sleep(forTimeInterval: 0.25)
        #expect(process.isRunning, "the helper finished before it could be killed")
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()

        #expect(bytes(of: file) == original, "a kill -9 mid-save damaged the original")
        #expect(FileManager.default.fileExists(atPath: temporary), "the partial temporary should still be there")

        // …and the sweeper removes exactly that residue.
        let removed = AtomicWriter.cleanUpStaleTemporaries(in: scratch.url, olderThan: -1)
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: temporary))
        #expect(bytes(of: file) == original)
    }

    /// The sweeper only touches our own temporaries, and only stale ones. A save running
    /// concurrently in the other process must never be sabotaged.
    @Test func sweeperIsConservative() throws {
        let scratch = TemporaryDirectory("sweep")
        let ours = scratch.file("\(AtomicWriter.temporaryPrefix)\(ULID().rawValue)\(AtomicWriter.temporarySuffix)")
        let theirs = scratch.file(".someone-elses.tmp")
        let real = scratch.file("book.xlsx")

        #expect(AtomicWriter.cleanUpStaleTemporaries(in: scratch.url, olderThan: 3600) == 0)
        #expect(FileManager.default.fileExists(atPath: ours.path(percentEncoded: false)))

        #expect(AtomicWriter.cleanUpStaleTemporaries(in: scratch.url, olderThan: -1) == 1)
        #expect(FileManager.default.fileExists(atPath: theirs.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: real.path(percentEncoded: false)))
    }

    // MARK: - Metadata

    /// POSIX permissions and extended attributes — Finder tags among them — belong to the file,
    /// not to its bytes, and must survive a save.
    @Test func preservesPermissionsAndExtendedAttributes() throws {
        let scratch = TemporaryDirectory("metadata")
        let file = scratch.file("book.xlsx")
        let path = file.path(percentEncoded: false)

        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let tag = Data("com.apple.metadata:_kMDItemUserTags".utf8)
        #expect(setxattr(path, "com.opensheets.test", [UInt8](tag), tag.count, 0, 0) == 0)

        try AtomicWriter().write(Data("replacement".utf8), to: file)

        let mode = try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o640, "the save changed the file's permissions")
        #expect(getxattr(path, "com.opensheets.test", nil, 0, 0, 0) == tag.count, "the save dropped an xattr")
    }

    /// Saving through a symlink replaces the **target**, and leaves the link a link. Replacing
    /// the link itself detaches it silently, which is data loss nobody notices for weeks.
    @Test func writesThroughASymlinkRatherThanOverIt() throws {
        let scratch = TemporaryDirectory("symlink-write")
        let real = scratch.file("real.xlsx", contents: "before")
        let link = scratch.url.appendingPathComponent("link.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try AtomicWriter().write(Data("after".utf8), to: link)

        var status = stat()
        #expect(lstat(link.path(percentEncoded: false), &status) == 0)
        #expect((status.st_mode & S_IFMT) == S_IFLNK, "the symlink was replaced by a regular file")
        #expect(bytes(of: real) == Data("after".utf8))
    }

    // MARK: - Refusals

    /// Writing zero bytes over a workbook is nearly always an upstream bug, and the two
    /// outcomes are not symmetric: a spurious refusal is a message, a permitted one is the
    /// user's data.
    @Test func refusesToEmptyANonEmptyFile() throws {
        let scratch = TemporaryDirectory("empty-guard")
        let file = scratch.file("book.xlsx", contents: "real content")

        #expect(throws: SheetError.self) {
            try AtomicWriter().write(Data(), to: file)
        }
        #expect(bytes(of: file) == Data("real content".utf8))

        try AtomicWriter().write(
            Data(),
            to: file,
            options: AtomicWriter.Options(refusesEmptyOverwrite: false)
        )
        #expect(bytes(of: file)?.isEmpty == true)
    }

    /// A locked file (`chflags uchg`) is refused with the right code, not with a random errno.
    @Test func refusesToWriteALockedFile() throws {
        let scratch = TemporaryDirectory("locked")
        let file = scratch.file("book.xlsx")
        let path = file.path(percentEncoded: false)
        #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(path, 0) }

        do {
            try AtomicWriter().write(Data("nope".utf8), to: file)
            Issue.record("writing a locked file succeeded")
        } catch {
            #expect(error.code == "file.locked")
        }
        #expect(bytes(of: file) == Data("seed".utf8))
    }

    /// A read-only directory cannot take an atomic replace, and saying so before writing beats
    /// discovering it after the user typed.
    @Test func refusesWhenTheDirectoryIsNotWritable() throws {
        let scratch = TemporaryDirectory("ro-dir")
        let locked = scratch.directory("locked")
        let file = locked.appendingPathComponent("book.xlsx")
        try Data("seed".utf8).write(to: file)
        let path = locked.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }

        do {
            try AtomicWriter().write(Data("nope".utf8), to: file)
            Issue.record("writing into a read-only directory succeeded")
        } catch {
            #expect(error.code == "file.notWritable")
        }
        #expect(bytes(of: file) == Data("seed".utf8))
    }

    /// Creating a file that does not exist yet works too — `replaceItemAt` needs a destination,
    /// so that path uses a plain rename, which is equally atomic.
    @Test func createsAFileThatDidNotExist() throws {
        let scratch = TemporaryDirectory("create")
        let file = scratch.url.appendingPathComponent("brand-new.xlsx")

        let fingerprint = try AtomicWriter().write(Data("hello".utf8), to: file)
        #expect(bytes(of: file) == Data("hello".utf8))
        #expect(fingerprint.size == 5)
    }

    /// A hundred saves in a row leave nothing behind. A writer that leaks one temporary per
    /// save fills a folder with hidden files over a working day.
    @Test func repeatedSavesLeaveNoResidue() throws {
        let scratch = TemporaryDirectory("residue")
        let file = scratch.file("book.xlsx")
        let writer = AtomicWriter()

        for index in 0 ..< 100 {
            try writer.write(Data("save-\(index)".utf8), to: file)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path(percentEncoded: false))
        #expect(entries == ["book.xlsx"], "left behind \(entries)")
    }

    /// Records the stages a save passes through.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [AtomicWriteStage] = []

        func record(_ stage: AtomicWriteStage) {
            lock.lock()
            seen.append(stage)
            lock.unlock()
        }

        var stages: [AtomicWriteStage] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }
    }
}
