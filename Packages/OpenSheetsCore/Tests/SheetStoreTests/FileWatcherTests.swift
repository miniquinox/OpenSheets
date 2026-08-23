import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// The tests that decide whether this product works.
///
/// "Claude Code edits the file, the app notices" is the whole feature, and every way it can
/// silently stop working goes through this type. The first test below is the one that matters
/// most: it is the regression test for a watcher that dies after the first atomic replace,
/// which reads to a user as "the app is flaky" rather than as a bug anyone can report.
@Suite(.serialized) struct FileWatcherTests {
    // MARK: - The one that matters

    /// **100 consecutive atomic replaces fire exactly 100 times.**
    ///
    /// A file-descriptor source follows the inode, and an atomic replace makes a new one. If
    /// the watcher does not re-arm, this test passes on iteration 1 and stalls on iteration 2.
    /// Waiting for each event before triggering the next is deliberate: it makes the count
    /// exact rather than a function of how the debounce happened to line up, so a failure means
    /// "the watcher stopped", not "the machine was busy".
    @Test func survives100ConsecutiveAtomicReplaces() async throws {
        let scratch = TemporaryDirectory("atomic-100")
        let file = scratch.file("book.xlsx")
        let watcher = FileWatcher(url: file, configuration: .fast)
        try watcher.start()
        defer { watcher.stop() }

        let collector = EventCollector()
        await collector.attach(watcher)
        let writer = AtomicWriter()

        for index in 1 ... 100 {
            _ = try writer.write(Data("payload-\(index)-\(String(repeating: "x", count: index))".utf8), to: file)
            let arrived = await collector.waitForCount(index)
            let seen = await collector.count
            #expect(arrived, "the watcher stopped reporting after \(seen) of \(index) atomic replaces")
            if !arrived { break }
        }

        let events = await collector.all
        await collector.stop()
        #expect(events.count == 100)
        #expect(events.count { $0.isChanged } == 100)
    }

    // MARK: - Every way a file gets written

    /// In-place write, `mv` over the file, `rm` + recreate, another process, and a symlink
    /// pointing at the file. Each must produce exactly one event, of the right kind.
    @Test func firesForEveryWriteMode() async throws {
        let scratch = TemporaryDirectory("write-modes")
        let file = scratch.file("book.xlsx")
        let watcher = FileWatcher(url: file, configuration: .fast)
        try watcher.start()
        defer { watcher.stop() }

        let collector = EventCollector()
        await collector.attach(watcher)

        func step(_ label: String, _ body: () throws -> Void) async throws -> FileWatcherEvent? {
            let before = await collector.count
            try body()
            let arrived = await collector.waitForCount(before + 1)
            #expect(arrived, "no event for \(label)")
            _ = await collector.settle(.milliseconds(250))
            let after = await collector.all
            #expect(after.count == before + 1, "\(label) produced \(after.count - before) events, expected 1")
            return after.count > before ? after[before] : nil
        }

        let inPlace = try await step("in-place write") {
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("-appended".utf8))
            try handle.close()
        }
        #expect(inPlace?.isChanged == true)

        let moved = try await step("mv over the file") {
            let sibling = scratch.file("other.bin", contents: "moved-content-here")
            _ = try FileManager.default.replaceItemAt(file, withItemAt: sibling)
        }
        #expect(moved?.isChanged == true)

        let removed = try await step("rm") {
            try FileManager.default.removeItem(at: file)
        }
        #expect(removed?.isVanished == true)

        let recreated = try await step("recreate") {
            try Data("recreated-content".utf8).write(to: file)
        }
        #expect(recreated?.isReappeared == true)

        let external = try await step("edit from another process") {
            #expect(Shell.run("printf 'from-another-process' > '\(file.path(percentEncoded: false))'") == 0)
        }
        #expect(external?.isChanged == true)

        let throughLink = try await step("edit via a symlink to the file") {
            let link = scratch.url.appendingPathComponent("link.xlsx")
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            _ = try AtomicWriter().write(Data("written-through-the-symlink".utf8), to: link)
        }
        #expect(throughLink?.isChanged == true)

        await collector.stop()
    }

    /// Watching *through* a symlink: the watcher is pointed at the link, the edit lands on the
    /// target. The fd is opened on the resolved path, so this only works if the resolution
    /// happens at arm time rather than being assumed.
    @Test func watchesThroughASymlinkToTheFile() async throws {
        let scratch = TemporaryDirectory("symlink-watch")
        let real = scratch.file("real.xlsx")
        let link = scratch.url.appendingPathComponent("link.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let watcher = FileWatcher(url: link, configuration: .fast)
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        _ = try AtomicWriter().write(Data("changed-at-the-real-path".utf8), to: real)
        #expect(await collector.waitForCount(1))
        await collector.stop()
    }

    // MARK: - Bursts and debounce

    /// A writer that emits forty small writes is one save, not forty. PLAN.md §6.1's debounce
    /// exists so the app reparses once.
    @Test func coalescesABurstOfWrites() async throws {
        let scratch = TemporaryDirectory("burst")
        let file = scratch.file("book.xlsx")
        let watcher = FileWatcher(url: file, configuration: FileWatcher.Configuration(
            debounce: .milliseconds(150),
            stabilityInterval: .milliseconds(20),
            fsEventsLatency: 0.01
        ))
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        let handle = try FileHandle(forWritingTo: file)
        for index in 0 ..< 40 { try handle.write(contentsOf: Data("chunk-\(index)".utf8)) }
        try handle.close()

        #expect(await collector.waitForCount(1))
        let total = await collector.settle(.milliseconds(700))
        await collector.stop()
        #expect(total <= 4, "forty writes in one burst produced \(total) events")
    }

    /// A file being written slowly must not be reported half-finished. The stability check
    /// re-probes and backs off; without it the parser sees a truncated archive.
    @Test func waitsForASlowWriterToFinish() async throws {
        let scratch = TemporaryDirectory("slow-writer")
        let file = scratch.file("book.xlsx")
        let watcher = FileWatcher(url: file, configuration: FileWatcher.Configuration(
            debounce: .milliseconds(10),
            stabilityInterval: .milliseconds(40),
            fsEventsLatency: 0.005
        ))
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        let path = file.path(percentEncoded: false)
        // Ten writes 30 ms apart: shorter than one stability interval, so every probe pair
        // disagrees until the writer stops.
        let process = Shell.spawn(
            ": > '\(path)'; for i in 1 2 3 4 5 6 7 8 9 10; do printf 'part-%s-' \"$i\" >> '\(path)'; sleep 0.03; done"
        )
        #expect(await collector.waitForCount(1))
        process?.waitUntilExit()
        _ = await collector.settle(.milliseconds(300))

        let events = await collector.all
        await collector.stop()
        // Whatever it reported, it reported the *finished* file — that is the property that
        // matters, not the event count.
        let expected = (1 ... 10).map { "part-\($0)-" }.joined()
        if case let .changed(probe) = events.last {
            #expect(probe.fingerprint.size == Int64(expected.utf8.count))
        } else {
            Issue.record("expected a .changed event, got \(String(describing: events.last))")
        }
    }

    // MARK: - Hostile filesystem shapes

    /// PLAN.md §9: the file is replaced by a directory. Must report, not crash, not hang.
    @Test func reportsAFileReplacedByADirectory() async throws {
        let scratch = TemporaryDirectory("dir-swap")
        let file = scratch.file("book.xlsx")
        let watcher = FileWatcher(url: file, configuration: .fast)
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)

        #expect(await collector.waitForCount(1))
        _ = await collector.settle(.milliseconds(250))
        let events = await collector.all
        await collector.stop()
        #expect(events.contains { $0.isUnreadable })
    }

    /// The parent directory is renamed out from under the watcher, then the original path is
    /// recreated. `kFSEventStreamCreateFlagWatchRoot` plus the re-arm timer have to bring it
    /// back — a watcher that gives up here is one that stops working when the user reorganises
    /// their folders.
    @Test func survivesTheParentDirectoryBeingRenamed() async throws {
        let scratch = TemporaryDirectory("parent-rename")
        let inner = scratch.directory("inner")
        let file = inner.appendingPathComponent("book.xlsx")
        try Data("seed".utf8).write(to: file)

        let watcher = FileWatcher(url: file, configuration: .fast)
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        try FileManager.default.moveItem(at: inner, to: scratch.url.appendingPathComponent("renamed"))
        #expect(await collector.waitForCount(1))
        _ = await collector.settle(.milliseconds(250))
        #expect(await collector.all.contains { $0.isVanished })

        let before = await collector.count
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("a-brand-new-file-at-the-old-path".utf8).write(to: file)
        #expect(await collector.waitForCount(before + 1))
        await collector.stop()
    }

    /// A `chmod` is not an edit. The content hash is unchanged, so the event says
    /// `attributesChanged` and the document does not reparse.
    @Test func distinguishesAPermissionChangeFromAnEdit() async throws {
        let scratch = TemporaryDirectory("chmod")
        let file = scratch.file("book.xlsx", contents: "stable contents")
        let watcher = FileWatcher(url: file, configuration: .fast)
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        let path = file.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
        #expect(await collector.waitForCount(1))
        _ = await collector.settle(.milliseconds(250))
        let events = await collector.all
        await collector.stop()
        #expect(events.first?.isAttributesChanged == true, "got \(String(describing: events.first))")
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }

    /// A watcher armed on a path that does not exist yet reports the file's arrival. Opening a
    /// document Claude is about to create is a real workflow.
    @Test func noticesAFileThatDidNotExistWhenWatchingStarted() async throws {
        let scratch = TemporaryDirectory("not-yet")
        let file = scratch.url.appendingPathComponent("future.xlsx")
        let watcher = FileWatcher(url: file, configuration: .fast)
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        try Data("created-later".utf8).write(to: file)
        #expect(await collector.waitForCount(1))
        #expect(await collector.all.first?.isReappeared == true)
        await collector.stop()
    }

    /// Stopping the watcher finishes the stream and stops delivering. A watcher that keeps
    /// firing after a document closes is a leak with a user-visible symptom.
    @Test func stopsCleanly() async throws {
        let scratch = TemporaryDirectory("stop")
        let file = scratch.file("book.xlsx")
        let watcher = FileWatcher(url: file, configuration: .fast)
        try watcher.start()
        let collector = EventCollector()
        await collector.attach(watcher)
        watcher.stop()
        watcher.stop() // idempotent

        try Data("after-stop".utf8).write(to: file)
        #expect(await collector.settle(.milliseconds(250)) == 0)
        await collector.stop()
    }
}
