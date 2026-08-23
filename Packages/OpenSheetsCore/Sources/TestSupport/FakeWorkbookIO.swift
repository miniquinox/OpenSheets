//
//  FakeWorkbookIO.swift
//  TestSupport
//
//  Readers and writers that do not touch a disk, with programmable latency and failures.
//

import Foundation
import SheetModel
import Synchronization

/// Reads a workbook from a URL.
///
/// **Declared here rather than imported from `SheetStore`.** `TestSupport` depends on
/// `SheetModel` alone — that is what `Package.swift` says, and widening it would make
/// `TestSupport` unusable from `SheetFormat`'s tests, which sit *below* `SheetStore` in the
/// dependency graph. If A6 lands an equivalent protocol, conforming these fakes to it is a
/// one-line extension in `SheetStoreTests`; nothing here needs to change.
public protocol WorkbookReading: Sendable {
    /// The workbook at `url`.
    func readWorkbook(at url: URL) async throws(SheetError) -> Workbook
}

/// Writes a workbook to a URL.
///
/// See ``WorkbookReading`` for why this lives in `TestSupport`.
public protocol WorkbookWriting: Sendable {
    /// Writes `workbook` to `url`, replacing whatever was there.
    func writeWorkbook(_ workbook: Workbook, to url: URL) async throws(SheetError)
}

/// When an injected failure fires.
///
/// Built from a decision closure rather than an enum of cases so the common shapes are static
/// factories and anything unusual is still expressible without adding a case here.
public struct FailureSchedule: Sendable {
    /// Given the 1-based call index and the URL, the error to throw — or `nil` to succeed.
    public let decide: @Sendable (Int, URL) -> SheetError?

    public init(decide: @escaping @Sendable (Int, URL) -> SheetError?) {
        self.decide = decide
    }

    /// Never fail.
    public static let never = FailureSchedule { _, _ in nil }

    /// Fail every call.
    public static func always(_ error: SheetError) -> FailureSchedule {
        FailureSchedule { _, _ in error }
    }

    /// Fail exactly the `index`-th call, 1-based, and succeed on every other.
    ///
    /// The shape a retry test needs: fail once, then let the retry through.
    public static func onCall(_ index: Int, _ error: SheetError) -> FailureSchedule {
        FailureSchedule { call, _ in call == index ? error : nil }
    }

    /// Succeed for the first `count` calls, then fail from then on.
    public static func afterCall(_ count: Int, _ error: SheetError) -> FailureSchedule {
        FailureSchedule { call, _ in call > count ? error : nil }
    }

    /// Fail only for URLs whose path contains `fragment`.
    public static func onPath(containing fragment: String, _ error: SheetError) -> FailureSchedule {
        FailureSchedule { _, url in url.path.contains(fragment) ? error : nil }
    }

    /// Fail on the first call and every `period`-th call after it, for flapping-IO tests.
    public static func everyNth(_ period: Int, _ error: SheetError) -> FailureSchedule {
        FailureSchedule { call, _ in period > 0 && call % period == 1 ? error : nil }
    }
}

/// One recorded call against a fake.
public struct FakeIOCall: Sendable, Hashable {
    /// 1-based index in the order the fake saw it.
    public var index: Int
    public var url: URL
    /// The error the schedule injected, if any.
    public var injectedErrorCode: String?

    public var succeeded: Bool { injectedErrorCode == nil }
}

/// A ``WorkbookReading`` that serves workbooks from memory.
///
/// Three knobs, all settable while a test is running:
///
/// - **stubs** — what to return for a given URL, or a default for anything unstubbed.
/// - **latency** — how long each read takes, so a test can prove that a slow open shows a
///   progress indicator rather than blocking the main actor.
/// - **schedule** — when to fail, and with which ``SheetError``.
///
/// It also **counts**, which matters more than it sounds: "did the sync engine read the file
/// once or four times?" is a correctness question, it is answered by a counter rather than by a
/// stopwatch, and a counter does not flake on a loaded machine.
public final class FakeWorkbookReader: WorkbookReading, Sendable {
    private struct State {
        var stubs: [String: Workbook] = [:]
        var fallback: Workbook?
        var latency: Duration = .zero
        var schedule: FailureSchedule = .never
        var calls: [FakeIOCall] = []
    }

    private let state = Mutex(State())

    public init(latency: Duration = .zero, schedule: FailureSchedule = .never) {
        state.withLock {
            $0.latency = latency
            $0.schedule = schedule
        }
    }

    /// A reader that returns `workbook` for any URL.
    public convenience init(returning workbook: Workbook) {
        self.init()
        stubDefault(workbook)
    }

    // MARK: - Programming it

    /// Serves `workbook` for exactly this URL.
    public func stub(_ workbook: Workbook, at url: URL) {
        state.withLock { $0.stubs[url.standardizedFileURL.path] = workbook }
    }

    /// Serves `workbook` for any URL with no specific stub.
    public func stubDefault(_ workbook: Workbook?) {
        state.withLock { $0.fallback = workbook }
    }

    /// How long each read takes from now on.
    public func setLatency(_ latency: Duration) {
        state.withLock { $0.latency = latency }
    }

    /// When reads fail from now on.
    public func setSchedule(_ schedule: FailureSchedule) {
        state.withLock { $0.schedule = schedule }
    }

    /// Forgets the call log. Stubs, latency and schedule are left alone.
    public func resetCalls() {
        state.withLock { $0.calls.removeAll() }
    }

    // MARK: - Observing it

    /// Every call, in order.
    public var calls: [FakeIOCall] { state.withLock { $0.calls } }
    /// How many reads have been attempted, successful or not.
    public var callCount: Int { state.withLock { $0.calls.count } }
    /// How many reads returned a workbook.
    public var successCount: Int { state.withLock { $0.calls.count { $0.succeeded } } }
    /// The URL of the most recent read.
    public var lastURL: URL? { state.withLock { $0.calls.last?.url } }
    /// The paths read, in order, with duplicates.
    public var readPaths: [String] { state.withLock { $0.calls.map(\.url.path) } }

    /// How many times `url` was read — the counter a "did we re-read after our own write?"
    /// assertion needs.
    public func readCount(for url: URL) -> Int {
        let path = url.standardizedFileURL.path
        return state.withLock { $0.calls.count { $0.url.standardizedFileURL.path == path } }
    }

    // MARK: - WorkbookReading

    public func readWorkbook(at url: URL) async throws(SheetError) -> Workbook {
        let (latency, error, workbook) = state.withLock { state -> (Duration, SheetError?, Workbook?) in
            let index = state.calls.count + 1
            let error = state.schedule.decide(index, url)
            state.calls.append(FakeIOCall(index: index, url: url, injectedErrorCode: error?.code))
            let stub = state.stubs[url.standardizedFileURL.path] ?? state.fallback
            return (state.latency, error, stub)
        }
        if latency > .zero {
            // `Task.sleep` rather than a blocking sleep: a fake that parked the calling thread
            // would deadlock any test using a serial executor, which is most of them.
            try? await Task.sleep(for: latency)
        }
        if let error { throw error }
        guard let workbook else {
            throw SheetError.fileNotFound(path: url.path)
        }
        return workbook
    }
}

/// A ``WorkbookWriting`` that keeps what it was given instead of writing it.
///
/// The counterpart to ``FakeWorkbookReader``, and the two share a URL space: pair them and a
/// test can prove that what the writer received is what the reader serves back, without a
/// single byte of encoding.
public final class FakeWorkbookWriter: WorkbookWriting, Sendable {
    /// One captured write.
    public struct Write: Sendable {
        public var index: Int
        public var url: URL
        public var workbook: Workbook
    }

    private struct State {
        var writes: [Write] = []
        var calls: [FakeIOCall] = []
        var latency: Duration = .zero
        var schedule: FailureSchedule = .never
        /// Whether a failed write still records what it was asked to write.
        var recordsFailedWrites = true
    }

    private let state = Mutex(State())

    public init(latency: Duration = .zero, schedule: FailureSchedule = .never) {
        state.withLock {
            $0.latency = latency
            $0.schedule = schedule
        }
    }

    // MARK: - Programming it

    public func setLatency(_ latency: Duration) {
        state.withLock { $0.latency = latency }
    }

    public func setSchedule(_ schedule: FailureSchedule) {
        state.withLock { $0.schedule = schedule }
    }

    /// Whether a write that the schedule failed still shows up in ``writes``.
    ///
    /// `true` by default, because "what did the caller *try* to write" is usually the question.
    /// Set it `false` to model a writer that is genuinely atomic, where a failed write leaves no
    /// trace at all — which is what A2 and A6 have to prove about the real one.
    public func setRecordsFailedWrites(_ records: Bool) {
        state.withLock { $0.recordsFailedWrites = records }
    }

    public func reset() {
        state.withLock {
            $0.writes.removeAll()
            $0.calls.removeAll()
        }
    }

    // MARK: - Observing it

    /// Every write, in order.
    public var writes: [Write] { state.withLock { $0.writes } }
    /// Every call, including the ones that failed.
    public var calls: [FakeIOCall] { state.withLock { $0.calls } }
    public var callCount: Int { state.withLock { $0.calls.count } }
    public var lastWrite: Write? { state.withLock { $0.writes.last } }

    /// The most recent workbook written to `url`.
    public func contents(at url: URL) -> Workbook? {
        let path = url.standardizedFileURL.path
        return state.withLock { $0.writes.last { $0.url.standardizedFileURL.path == path }?.workbook }
    }

    /// How many writes landed on `url`.
    ///
    /// The self-write suppressor's whole job is keeping this from becoming a loop, so the
    /// assertion is a count and not a duration.
    public func writeCount(for url: URL) -> Int {
        let path = url.standardizedFileURL.path
        return state.withLock { $0.writes.count { $0.url.standardizedFileURL.path == path } }
    }

    // MARK: - WorkbookWriting

    public func writeWorkbook(_ workbook: Workbook, to url: URL) async throws(SheetError) {
        let (latency, error) = state.withLock { state -> (Duration, SheetError?) in
            let index = state.calls.count + 1
            let error = state.schedule.decide(index, url)
            state.calls.append(FakeIOCall(index: index, url: url, injectedErrorCode: error?.code))
            if error == nil || state.recordsFailedWrites {
                state.writes.append(Write(index: index, url: url, workbook: workbook))
            }
            return (state.latency, error)
        }
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }
        if let error { throw error }
    }
}
