import Foundation
import SheetModel
import Testing
@testable import TestSupport

@Suite("Fake workbook IO")
struct FakeWorkbookIOTests {
    private func workbook(_ value: Double) throws -> Workbook {
        try WorkbookBuilder().sheet("Data").cell("A1", .number(value)).build()
    }

    private var url: URL { URL(fileURLWithPath: "/tmp/opensheets-fake/book.xlsx") }

    @Test("a stubbed reader serves the workbook it was given and counts the call")
    func readerServesStub() async throws {
        let reader = FakeWorkbookReader()
        reader.stub(try workbook(42), at: url)

        let result = try await reader.readWorkbook(at: url)
        #expect(result.sheets[0].cells[.origin]?.value == .number(42))
        #expect(reader.callCount == 1)
        #expect(reader.readCount(for: url) == 1)
        #expect(reader.lastURL == url)
    }

    @Test("an unstubbed URL falls back, and without a fallback it is a fileNotFound")
    func readerFallback() async throws {
        let reader = FakeWorkbookReader()
        await #expect(throws: SheetError.self) {
            try await reader.readWorkbook(at: url)
        }

        reader.stubDefault(try workbook(1))
        let anywhere = try await reader.readWorkbook(at: URL(fileURLWithPath: "/tmp/anything.xlsx"))
        #expect(anywhere.sheets[0].cells[.origin]?.value == .number(1))
    }

    @Test("onCall fails exactly once, so a retry succeeds")
    func failOnceThenSucceed() async throws {
        let reader = FakeWorkbookReader(returning: try workbook(7))
        reader.setSchedule(.onCall(1, .fileLocked(path: url.path)))

        await #expect(throws: SheetError.self) { try await reader.readWorkbook(at: url) }
        let retried = try await reader.readWorkbook(at: url)
        #expect(retried.sheets[0].cells[.origin]?.value == .number(7))
        #expect(reader.callCount == 2)
        #expect(reader.successCount == 1)
        #expect(reader.calls.first?.injectedErrorCode == "file.locked")
    }

    @Test("afterCall lets the first N through and then fails for good")
    func failAfterCount() async throws {
        let reader = FakeWorkbookReader(returning: try workbook(1))
        reader.setSchedule(.afterCall(2, .volumeUnavailable(path: url.path)))

        _ = try await reader.readWorkbook(at: url)
        _ = try await reader.readWorkbook(at: url)
        await #expect(throws: SheetError.self) { try await reader.readWorkbook(at: url) }
        await #expect(throws: SheetError.self) { try await reader.readWorkbook(at: url) }
        #expect(reader.successCount == 2)
    }

    @Test("onPath fails only the URLs it names")
    func failByPath() async throws {
        let reader = FakeWorkbookReader(returning: try workbook(1))
        reader.setSchedule(.onPath(containing: "quarantined", .fileNotReadable(path: "x", underlying: "y")))

        _ = try await reader.readWorkbook(at: URL(fileURLWithPath: "/tmp/fine.xlsx"))
        await #expect(throws: SheetError.self) {
            try await reader.readWorkbook(at: URL(fileURLWithPath: "/tmp/quarantined.xlsx"))
        }
    }

    @Test("everyNth fails the first and then every period-th call")
    func failEveryNth() async throws {
        let reader = FakeWorkbookReader(returning: try workbook(1))
        reader.setSchedule(.everyNth(3, .diskFull(path: "/tmp")))

        var outcomes: [Bool] = []
        for _ in 0 ..< 6 {
            do {
                _ = try await reader.readWorkbook(at: url)
                outcomes.append(true)
            } catch {
                outcomes.append(false)
            }
        }
        #expect(outcomes == [false, true, true, false, true, true])
    }

    @Test("latency is honoured without blocking the calling thread")
    func latency() async throws {
        let reader = FakeWorkbookReader(returning: try workbook(1))
        reader.setLatency(.milliseconds(40))

        let clock = ContinuousClock()
        let elapsed = try await clock.measure { _ = try await reader.readWorkbook(at: url) }
        // Only a lower bound is asserted. An upper bound would be a wall-clock assertion on a
        // machine that runs seven agents at once, which is exactly the flake the Wave 1
        // addendum warns about.
        #expect(elapsed >= .milliseconds(35))
    }

    @Test("resetCalls forgets the log and keeps the stubs")
    func resettingTheLog() async throws {
        let reader = FakeWorkbookReader(returning: try workbook(1))
        _ = try await reader.readWorkbook(at: url)
        reader.resetCalls()
        #expect(reader.callCount == 0)
        _ = try await reader.readWorkbook(at: url)
        #expect(reader.callCount == 1)
    }

    @Test("the writer keeps what it was given, keyed by URL")
    func writerCaptures() async throws {
        let writer = FakeWorkbookWriter()
        try await writer.writeWorkbook(try workbook(3), to: url)
        try await writer.writeWorkbook(try workbook(4), to: url)

        #expect(writer.writeCount(for: url) == 2)
        #expect(writer.contents(at: url)?.sheets[0].cells[.origin]?.value == .number(4))
        #expect(writer.lastWrite?.index == 2)
    }

    @Test("a failing writer records the attempt, or not, as configured")
    func writerFailureRecording() async throws {
        let recording = FakeWorkbookWriter(schedule: .always(.diskFull(path: "/tmp")))
        await #expect(throws: SheetError.self) { try await recording.writeWorkbook(try workbook(1), to: url) }
        #expect(recording.writes.count == 1, "by default a failed write still shows what was attempted")
        #expect(recording.calls.first?.injectedErrorCode == "file.diskFull")

        let atomic = FakeWorkbookWriter(schedule: .always(.diskFull(path: "/tmp")))
        atomic.setRecordsFailedWrites(false)
        await #expect(throws: SheetError.self) { try await atomic.writeWorkbook(try workbook(1), to: url) }
        #expect(atomic.writes.isEmpty, "an atomic writer leaves no trace of a failed write")
        #expect(atomic.callCount == 1)
    }

    @Test("a reader and a writer paired over one URL round-trip a workbook")
    func pairing() async throws {
        let writer = FakeWorkbookWriter()
        let reader = FakeWorkbookReader()
        let original = try workbook(11)

        try await writer.writeWorkbook(original, to: url)
        let stored = try #require(writer.contents(at: url))
        reader.stub(stored, at: url)

        let reloaded = try await reader.readWorkbook(at: url)
        #expect(WorkbookMatcher.compare(original, reloaded, options: .strict).matches)
    }

    @Test("the fakes are safe to hammer from many tasks at once")
    func concurrentUse() async throws {
        let reader = FakeWorkbookReader(returning: try workbook(1))
        let target = url
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 32 {
                group.addTask { _ = try? await reader.readWorkbook(at: target) }
            }
        }
        #expect(reader.callCount == 32)
        #expect(Set(reader.calls.map(\.index)).count == 32, "every call got a distinct index")
    }
}
