import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// PLAN.md §6.2. Two properties, pulling against each other, and both have to hold:
/// our own saves must never cause a refresh, and somebody else's must never be swallowed.
@Suite(.serialized) struct SelfWriteSuppressorTests {
    /// **Fifty saves in a row produce zero refresh events.**
    ///
    /// Without suppression the app refreshes itself after every ⌘S, which the user experiences
    /// as the document flickering and the scroll position jumping. Fifty rather than one
    /// because the failure mode that matters is a fingerprint that goes stale after the first.
    @Test func fiftySavesProduceZeroSpuriousRefreshes() async throws {
        let scratch = TemporaryDirectory("fifty-saves")
        let file = scratch.file("book.xlsx")
        let suppressor = SelfWriteSuppressor()
        let watcher = FileWatcher(url: file, configuration: .fast, suppressor: suppressor)
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        for index in 1 ... 50 {
            _ = try suppressor.write(Data("our-own-save-\(index)".utf8), to: file)
            try? await Task.sleep(for: .milliseconds(6))
        }

        let spurious = await collector.settle(.milliseconds(500))
        await collector.stop()
        #expect(spurious == 0, "50 of our own saves produced \(spurious) refresh events")
    }

    /// The other half. A genuine external write immediately after ours is *not* ours, and must
    /// get through — a suppressor that swallows it loses Claude's edit silently, which is the
    /// worst failure this component can have.
    @Test func externalWriteRightAfterOursIsNotSwallowed() async throws {
        let scratch = TemporaryDirectory("external-after")
        let file = scratch.file("book.xlsx")
        let suppressor = SelfWriteSuppressor()
        let watcher = FileWatcher(url: file, configuration: .fast, suppressor: suppressor)
        try watcher.start()
        defer { watcher.stop() }
        let collector = EventCollector()
        await collector.attach(watcher)

        _ = try suppressor.write(Data("ours".utf8), to: file)
        #expect(Shell.run("printf 'theirs, milliseconds later' > '\(file.path(percentEncoded: false))'") == 0)

        #expect(await collector.waitForCount(1), "an external write right after ours was swallowed")
        await collector.stop()
    }

    /// The bracket, which closes the race the fingerprint alone cannot: the watcher can observe
    /// the new file before the writer has returned.
    @Test func writeBracketSuppressesBeforeTheFingerprintExists() throws {
        let scratch = TemporaryDirectory("bracket")
        let file = scratch.file("book.xlsx")
        let suppressor = SelfWriteSuppressor()

        let token = suppressor.beginWrite(file)
        #expect(suppressor.decide(url: file, observed: nil) == .suppressedWriteInProgress)
        let probe = try FileFingerprint.capture(at: file)
        #expect(suppressor.decide(url: file, observed: probe) == .suppressedWriteInProgress)

        suppressor.endWrite(token, fingerprint: probe)
        #expect(suppressor.decide(url: file, observed: probe) == .suppressedFingerprintMatch)
    }

    /// A failed save records nothing, because the file is in whatever state it already was —
    /// and that state may be one somebody else put it in.
    @Test func failedWriteRecordsNoFingerprint() throws {
        let scratch = TemporaryDirectory("failed-write")
        let file = scratch.file("book.xlsx")
        let suppressor = SelfWriteSuppressor()

        let token = suppressor.beginWrite(file)
        suppressor.endWrite(token, fingerprint: nil)

        let probe = try FileFingerprint.capture(at: file)
        #expect(suppressor.decide(url: file, observed: probe) == .deliver)
        #expect(suppressor.expectationCount(for: file) == 0)
    }

    /// Fingerprints expire. PLAN.md §6.2 puts the lifetime at 5 s so a genuine external write
    /// arriving late is not mistaken for ours.
    @Test func fingerprintsExpire() async throws {
        let scratch = TemporaryDirectory("expiry")
        let file = scratch.file("book.xlsx")
        let suppressor = SelfWriteSuppressor(lifetime: .milliseconds(120))

        let fingerprint = try suppressor.write(Data("ours".utf8), to: file)
        #expect(suppressor.decide(url: file, observed: fingerprint) == .suppressedFingerprintMatch)
        try await Task.sleep(for: .milliseconds(220))
        #expect(suppressor.decide(url: file, observed: fingerprint) == .deliver)
    }

    /// A writer that crashes between `beginWrite` and `endWrite` must not suppress the path
    /// forever. "The app stopped noticing my file" with no error is the worst possible failure
    /// mode here, so the bracket has a hard ceiling of its own.
    @Test func abandonedWriteBracketExpires() async throws {
        let scratch = TemporaryDirectory("abandoned")
        let file = scratch.file("book.xlsx")
        let suppressor = SelfWriteSuppressor(lifetime: .seconds(5), inFlightCeiling: .milliseconds(120))

        _ = suppressor.beginWrite(file)
        #expect(suppressor.decide(url: file, observed: nil) == .suppressedWriteInProgress)
        try await Task.sleep(for: .milliseconds(220))
        #expect(suppressor.decide(url: file, observed: nil) == .deliver)
    }

    /// A fingerprint suppresses only the exact state we produced. Same size, same nanosecond
    /// mtime, different content — still delivered, because the head hash differs.
    @Test func suppressionIsExactRatherThanApproximate() throws {
        let scratch = TemporaryDirectory("exact")
        let file = scratch.file("book.xlsx")
        let suppressor = SelfWriteSuppressor()

        let ours = try suppressor.write(Data("aaaa".utf8), to: file)
        var impostor = ours
        impostor.headHash &+= 1
        #expect(suppressor.decide(url: file, observed: impostor) == .deliver)

        var resized = ours
        resized.size += 1
        #expect(suppressor.decide(url: file, observed: resized) == .deliver)

        var reinoded = ours
        reinoded.inode &+= 1
        #expect(suppressor.decide(url: file, observed: reinoded) == .deliver)

        var retimed = ours
        retimed.modified.nanoseconds &+= 1
        #expect(suppressor.decide(url: file, observed: retimed) == .deliver)
    }

    /// Suppression is keyed on the resolved path. A save through a symlink has to suppress the
    /// watcher looking at the real file, or exactly one refresh loop survives — the one hardest
    /// to reproduce.
    @Test func suppressionFollowsSymlinks() throws {
        let scratch = TemporaryDirectory("symlink-suppress")
        let real = scratch.file("real.xlsx")
        let link = scratch.url.appendingPathComponent("link.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let suppressor = SelfWriteSuppressor()
        let fingerprint = try suppressor.write(Data("through the link".utf8), to: link)
        #expect(suppressor.decide(url: real, observed: fingerprint) == .suppressedFingerprintMatch)
    }

    /// `forget` clears a closed document, so a stale fingerprint cannot suppress an event for
    /// a file the user reopens later.
    @Test func forgetClearsEverythingForAPath() throws {
        let scratch = TemporaryDirectory("forget")
        let file = scratch.file("book.xlsx")
        let suppressor = SelfWriteSuppressor()

        let fingerprint = try suppressor.write(Data("ours".utf8), to: file)
        #expect(suppressor.decide(url: file, observed: fingerprint) == .suppressedFingerprintMatch)
        suppressor.forget(file)
        #expect(suppressor.decide(url: file, observed: fingerprint) == .deliver)
    }
}
