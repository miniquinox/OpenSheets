import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// PLAN.md §5.5. The safety net for *"Claude trashed my sheet"* — a headline feature, so the
/// tests are about the promise, not about the plumbing: the bytes come back exactly, restoring
/// does not set off a refresh loop, and the caps hold.
@Suite struct SnapshotStoreTests {
    private func store(_ scratch: TemporaryDirectory, perFile: Int = 20, totalBytes: Int = 500 * 1024 * 1024)
        -> SnapshotStore {
        SnapshotStore(configuration: SnapshotStore.Configuration(
            root: scratch.url.appendingPathComponent("Snapshots"),
            maximumPerFile: perFile,
            maximumTotalBytes: totalBytes
        ))
    }

    /// **A restore returns byte-identical content**, including for bytes we could never parse —
    /// which is exactly when a snapshot is most wanted.
    @Test func restoreReturnsByteIdenticalContent() async throws {
        let scratch = TemporaryDirectory("restore")
        let store = store(scratch)
        let file = scratch.url.appendingPathComponent("book.xlsx")

        var original = Data([0x50, 0x4B, 0x03, 0x04])
        original.append(contentsOf: (0 ..< 200_000).map { UInt8($0 % 256) })
        try original.write(to: file)

        let record = try #require(await store.capture(url: file, reason: .preSave))
        #expect(record.byteCount == original.count)
        #expect(record.compressedByteCount < original.count)

        try Data("Claude trashed this".utf8).write(to: file)
        #expect(bytes(of: file) != original)

        let suppressor = SelfWriteSuppressor()
        _ = try await store.restore(record.id, to: file, suppressor: suppressor)
        #expect(bytes(of: file) == original, "the restore did not return the original bytes")
    }

    /// **A restore does not set off a refresh loop.** It goes through the same fingerprinted
    /// atomic write as a save, so the watcher recognises it as ours.
    @Test func restoreDoesNotTriggerARefresh() async throws {
        let scratch = TemporaryDirectory("restore-quiet")
        let store = store(scratch)
        let file = scratch.file("book.xlsx", contents: "version one")

        let record = try #require(await store.capture(url: file, reason: .manual))
        try Data("version two".utf8).write(to: file)

        let suppressor = SelfWriteSuppressor()
        let watcher = FileWatcher(url: file, configuration: .fast, suppressor: suppressor)
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        _ = try await store.restore(record.id, to: file, suppressor: suppressor)
        let spurious = await collector.settle(.milliseconds(500))
        await collector.stop()

        #expect(spurious == 0, "the restore produced \(spurious) refresh events")
        #expect(bytes(of: file) == Data("version one".utf8))
    }

    /// Restoring takes a `.preRestore` snapshot first, so undoing the undo is possible. A
    /// safety net with a hole where somebody panicking will fall through is not a safety net.
    @Test func restoringSnapshotsTheCurrentStateFirst() async throws {
        let scratch = TemporaryDirectory("undo-the-undo")
        let store = store(scratch)
        let file = scratch.file("book.xlsx", contents: "version one")

        let first = try #require(await store.capture(url: file, reason: .manual))
        try Data("version two".utf8).write(to: file)

        _ = try await store.restore(first.id, to: file, suppressor: SelfWriteSuppressor())
        let history = try await store.snapshots(for: file)
        #expect(history.contains { $0.reason == .preRestore })

        let undo = try #require(history.first { $0.reason == .preRestore })
        _ = try await store.restore(undo.id, to: file, suppressor: SelfWriteSuppressor())
        #expect(bytes(of: file) == Data("version two".utf8))
    }

    /// Twenty per file, oldest evicted. ULID filenames sort chronologically, so "oldest" is a
    /// string sort rather than a `stat` per file.
    @Test func keepsTwentyPerFileAndEvictsTheOldest() async throws {
        let scratch = TemporaryDirectory("evict")
        let store = store(scratch, perFile: 20)
        let file = scratch.file("book.xlsx")

        var ids: [ULID] = []
        for index in 0 ..< 25 {
            try Data("version-\(index)".utf8).write(to: file)
            if let record = try await store.capture(url: file, reason: .preSave) { ids.append(record.id) }
        }

        let history = try await store.snapshots(for: file)
        #expect(history.count == 20)
        #expect(history.first?.id == ids.last, "the newest snapshot should be first")
        #expect(!history.contains { $0.id == ids[0] }, "the oldest snapshot should have been evicted")
        #expect(history.contains { $0.id == ids[5] })
    }

    /// The global cap, with the rule that keeps it fair: never evict a file's *only* remaining
    /// snapshot, so one enormous workbook cannot wipe out every other document's safety net.
    @Test func globalCapNeverLeavesAFileWithNothing() async throws {
        let scratch = TemporaryDirectory("global-cap")
        // Small enough that the second capture per file is over budget. Random bytes so gzip
        // cannot compress the payload away and make the cap unreachable.
        let store = store(scratch, perFile: 20, totalBytes: 40_000)

        for index in 0 ..< 6 {
            let file = scratch.url.appendingPathComponent("book-\(index).xlsx")
            for round in 0 ..< 3 {
                var payload = Data("file-\(index)-round-\(round)".utf8)
                payload.append(contentsOf: (0 ..< 20_000).map { _ in UInt8.random(in: 0 ... 255) })
                try payload.write(to: file)
                _ = try? await store.capture(url: file, reason: .preSave)
            }
        }

        for index in 0 ..< 6 {
            let file = scratch.url.appendingPathComponent("book-\(index).xlsx")
            let history = try await store.snapshots(for: file)
            #expect(!history.isEmpty, "book-\(index) has no snapshots left at all")
        }
    }

    /// Nothing to snapshot is not an error. A file that does not exist yet, and one too large
    /// for the store, both return `nil` — refusing to save because the safety net will not fit
    /// would be the wrong trade.
    @Test func returnsNilRatherThanThrowingWhenThereIsNothingToCapture() async throws {
        let scratch = TemporaryDirectory("nothing")
        let store = store(scratch)
        #expect(try await store.capture(url: scratch.url.appendingPathComponent("gone.xlsx"), reason: .preSave) == nil)

        let tiny = SnapshotStore(configuration: SnapshotStore.Configuration(
            root: scratch.url.appendingPathComponent("Snapshots2"),
            maximumFileBytes: 4
        ))
        let file = scratch.file("big.xlsx", contents: "much larger than four bytes")
        #expect(try await tiny.capture(url: file, reason: .preSave) == nil)
    }

    /// The path is hashed, never embedded. A file called `../../etc/passwd` cannot make the
    /// store write outside itself.
    @Test func hostilePathsCannotEscapeTheStore() async throws {
        let scratch = TemporaryDirectory("hostile-path")
        let root = scratch.url.appendingPathComponent("Snapshots")
        let store = SnapshotStore(configuration: SnapshotStore.Configuration(root: root))
        let nested = scratch.directory("a/b")
        let file = nested.appendingPathComponent("..evil..xlsx")
        try Data("payload".utf8).write(to: file)

        _ = try await store.capture(url: file, reason: .manual)
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        #expect(entries.count == 1)
        #expect(entries[0].count == 64, "the directory name should be a sha256 hex digest, got \(entries[0])")
    }

    /// Snapshots are keyed on the resolved path, so a file opened through a symlink and through
    /// its real path shows one history rather than two.
    @Test func snapshotsFollowSymlinks() async throws {
        let scratch = TemporaryDirectory("snap-symlink")
        let store = store(scratch)
        let real = scratch.file("real.xlsx", contents: "content")
        let link = scratch.url.appendingPathComponent("link.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        _ = try await store.capture(url: real, reason: .preSave)
        _ = try await store.capture(url: link, reason: .preRefresh)
        #expect(try await store.snapshots(for: real).count == 2)
        #expect(try await store.snapshots(for: link).count == 2)
    }

    /// The database index and the directory must agree, and the directory wins when they do
    /// not — it is the only one that says what can actually be restored.
    @Test func fallsBackToTheDirectoryWhenTheIndexIsEmpty() async throws {
        let scratch = TemporaryDirectory("index-fallback")
        let database = try Database(url: scratch.url.appendingPathComponent("db.sqlite"))
        let store = SnapshotStore(
            configuration: SnapshotStore.Configuration(root: scratch.url.appendingPathComponent("Snapshots")),
            index: database
        )
        let file = scratch.file("book.xlsx", contents: "content")

        let record = try #require(await store.capture(url: file, reason: .preSave))
        #expect(try database.snapshots(forPath: record.filePath).count == 1)

        try database.deleteSnapshots(forPath: record.filePath)
        let recovered = try await store.snapshots(for: file)
        #expect(recovered.count == 1, "the store must still list what is on disk")
        #expect(recovered.first?.id == record.id)
    }

    /// A missing snapshot is a typed error, not a crash.
    @Test func missingSnapshotIsATypedError() async throws {
        let scratch = TemporaryDirectory("missing-snapshot")
        let store = store(scratch)
        let file = scratch.file("book.xlsx")
        do {
            _ = try await store.data(for: ULID(), of: file)
            Issue.record("reading a snapshot that does not exist succeeded")
        } catch {
            #expect(error.code == "snapshot.notFound")
        }
    }

    /// A checkpoint (PLAN.md §1.3) is an ordinary snapshot wearing its own reason.
    ///
    /// Which is the point: the baseline machinery gets persistence, eviction and byte-identical
    /// restore for free, and nothing about the store had to learn what a baseline is. What the
    /// new reason buys is that the copy is *self-describing* — a user recovering by hand, or the
    /// snapshot browser, can tell the deliberate mark from the twenty automatic copies around it.
    @Test func checkpointsAreOrdinarySnapshotsWithTheirOwnName() async throws {
        let scratch = TemporaryDirectory("checkpoint")
        let store = store(scratch)
        let file = scratch.file("book.xlsx", contents: "at the checkpoint")

        let record = try #require(await store.capture(url: file, reason: .checkpoint, summary: "checkpoint"))
        #expect(record.reason == .checkpoint)
        #expect(record.summary == "checkpoint")
        #expect(SnapshotStore.fileName(id: record.id, reason: .checkpoint) == "\(record.id.rawValue).checkpoint.gz")

        let directory = scratch.url
            .appendingPathComponent("Snapshots")
            .appendingPathComponent(SnapshotStore.digest(Data(SnapshotStore.canonicalPath(file).utf8)))
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
        #expect(entries == ["\(record.id.rawValue).checkpoint.gz"])

        let history = try await store.snapshots(for: file)
        #expect(history.map(\.reason) == [.checkpoint])

        try Data("moved on since".utf8).write(to: file)
        _ = try await store.restore(record.id, to: file, suppressor: SelfWriteSuppressor())
        #expect(bytes(of: file) == Data("at the checkpoint".utf8))
    }

    /// The filename is the fallback index, so it has to parse both ways — and a reason a future
    /// build invents must degrade to `.manual` rather than making the snapshot invisible.
    @Test func checkpointFilenamesRoundTripAndUnknownReasonsDegrade() throws {
        let id = ULID()
        let parsed = try #require(SnapshotStore.parse(fileName: "\(id.rawValue).checkpoint.gz"))
        #expect(parsed.id == id)
        #expect(parsed.reason == .checkpoint)

        let future = try #require(SnapshotStore.parse(fileName: "\(id.rawValue).timeTravel.gz"))
        #expect(future.reason == .manual, "an unknown reason must not lose the snapshot")
    }

    /// Closing a document's history removes both halves.
    @Test func forgetRemovesEverything() async throws {
        let scratch = TemporaryDirectory("forget-snapshots")
        let store = store(scratch)
        let file = scratch.file("book.xlsx", contents: "content")

        _ = try await store.capture(url: file, reason: .preSave)
        #expect(try await store.snapshots(for: file).count == 1)
        await store.forget(file)
        #expect(try await store.snapshots(for: file).isEmpty)
    }
}

/// The gzip container, on its own.
@Suite struct GzipTests {
    /// Round-trips, including the shapes that break naive framing.
    @Test(arguments: [0, 1, 2, 1023, 65_536, 1_048_577])
    func roundTripsAtEverySize(size: Int) throws {
        let original = Data((0 ..< size).map { UInt8(($0 &* 31) % 251) })
        let compressed = try Gzip.compress(original)
        #expect(try Gzip.decompress(compressed) == original)
    }

    /// Highly compressible input actually compresses, so a snapshot store cap means something.
    @Test func compressesRepetitiveContent() throws {
        let original = Data(String(repeating: "spreadsheet,", count: 20_000).utf8)
        let compressed = try Gzip.compress(original)
        #expect(compressed.count < original.count / 10)
        #expect(try Gzip.decompress(compressed) == original)
    }

    /// **A real `.gz`**, readable by `gunzip`. A safety net that only the thing that failed can
    /// open is most of the way to not being one.
    @Test func producesArchivesTheSystemGunzipCanRead() throws {
        let scratch = TemporaryDirectory("gunzip")
        let original = Data(String(repeating: "row,of,data\n", count: 5000).utf8)
        let archive = scratch.url.appendingPathComponent("snapshot.gz")
        try Gzip.compress(original).write(to: archive)

        let output = scratch.url.appendingPathComponent("snapshot")
        #expect(Shell.run("/usr/bin/gunzip -c '\(archive.path(percentEncoded: false))' > " +
            "'\(output.path(percentEncoded: false))'") == 0)
        #expect(bytes(of: output) == original)
    }

    /// …and reads what `gzip` writes, header extras and all.
    @Test func readsArchivesTheSystemGzipProduced() throws {
        let scratch = TemporaryDirectory("gzip-in")
        let source = scratch.file("payload.txt", contents: String(repeating: "hello gzip ", count: 2000))
        let original = try #require(bytes(of: source))
        #expect(Shell.run("/usr/bin/gzip -n -f '\(source.path(percentEncoded: false))'") == 0)

        let archive = scratch.url.appendingPathComponent("payload.txt.gz")
        #expect(try Gzip.decompress(try #require(bytes(of: archive))) == original)
    }

    /// Corruption is caught rather than restored. A snapshot that silently returns wrong bytes
    /// is worse than one that refuses.
    @Test func detectsCorruption() throws {
        let original = Data(String(repeating: "important data ", count: 1000).utf8)
        var compressed = try Gzip.compress(original)

        var truncated = compressed
        truncated.removeLast(4)
        #expect(throws: SheetError.self) { try Gzip.decompress(truncated) }

        // Flip a bit in the CRC trailer.
        compressed[compressed.count - 6] ^= 0xFF
        #expect(throws: SheetError.self) { try Gzip.decompress(compressed) }

        #expect(throws: SheetError.self) { try Gzip.decompress(Data("not gzip at all, not even close".utf8)) }
    }

    /// The CRC-32 matches the one everyone else computes.
    @Test func crc32MatchesTheStandardVectors() {
        #expect(CRC32.checksum(Data()) == 0)
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414F_A339)
    }

    /// ULIDs sort chronologically, which is what makes snapshot eviction a string sort.
    @Test func ulidsSortByTime() async throws {
        let before = Date()
        var ids: [ULID] = []
        for _ in 0 ..< 8 {
            ids.append(ULID())
            try await Task.sleep(for: .milliseconds(3))
        }
        let after = Date()
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == 8)
        #expect(ULID(rawValue: "not-a-ulid") == nil)
        #expect(ULID(rawValue: ids[0].rawValue) == ids[0])
        // Bracketed rather than measured against "now": the real claim is that the encoded
        // timestamp is the moment the ULID was made. An absolute window instead measured how
        // long the test itself took to run, and failed at 6.7 s under load.
        #expect(ids[0].timestamp >= before.addingTimeInterval(-1))
        #expect(ids[0].timestamp <= after.addingTimeInterval(1))
    }
}
