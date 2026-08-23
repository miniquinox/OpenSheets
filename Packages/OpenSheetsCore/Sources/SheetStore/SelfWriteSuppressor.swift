import Foundation
import SheetModel
import Synchronization

/// Stops the app reacting to its own saves (PLAN.md §6.2).
///
/// Without this, every save produces a filesystem event, which produces a refresh, which the
/// user sees as the document flashing after every ⌘S. With a naive version of it, a genuine
/// external write landing right after ours gets swallowed and the user silently loses Claude's
/// edit. The design threads that needle with two mechanisms:
///
/// 1. **A write bracket.** ``beginWrite(_:)``/``endWrite(_:fingerprint:)`` suppress everything
///    for a path for as long as our writer is inside it. This closes the race the fingerprint
///    alone cannot: the watcher can observe the new file *before* the writer has returned the
///    fingerprint to register.
/// 2. **An expected fingerprint**, valid for ``Limits/selfWriteFingerprintLifetime`` (5 s).
///    An event is dropped only if the file *right now* is byte-for-byte the state our save
///    produced — same device, inode, size, nanosecond mtime and head hash. Anything else,
///    including an external writer restoring different content, gets through.
///
/// The second point is the one that makes this safe rather than merely convenient: suppression
/// is keyed on the observed state of the file, not on timing. A genuine external write 10 ms
/// after ours has a different mtime, so it is never mistaken for ours.
///
/// Thread-safe and `Sendable`; the watcher consults it from its own queue.
public final class SelfWriteSuppressor: Sendable {
    /// A write in progress. Hand it back to ``endWrite(_:fingerprint:)``.
    public struct WriteToken: Sendable, Hashable {
        let id: UInt64
        let key: String
    }

    /// Why an event was let through or dropped — recorded so a test can assert the *reason*
    /// rather than just the outcome, and so a bug report can say which mechanism fired.
    public enum Decision: String, Sendable, Hashable, CaseIterable {
        /// No reason to suppress; the consumer should react.
        case deliver
        /// One of our writes is in flight on this path.
        case suppressedWriteInProgress
        /// The file is in exactly the state our save left it in.
        case suppressedFingerprintMatch
    }

    private struct Expectation {
        var fingerprint: FileFingerprint
        var expiry: ContinuousClock.Instant
    }

    private struct InFlight {
        var count: Int
        var deadline: ContinuousClock.Instant
    }

    private struct State {
        var expectations: [String: [Expectation]] = [:]
        var inFlight: [String: InFlight] = [:]
        var nextToken: UInt64 = 1
    }

    private let state = Mutex(State())
    private let lifetime: Duration
    private let inFlightCeiling: Duration

    /// - Parameters:
    ///   - lifetime: how long a recorded fingerprint suppresses. Defaults to
    ///     ``Limits/selfWriteFingerprintLifetime``.
    ///   - inFlightCeiling: a hard ceiling on the write bracket. If a writer crashes between
    ///     `beginWrite` and `endWrite` the bracket would otherwise suppress this path forever,
    ///     which is a silent "the app stopped noticing my file" bug — the worst kind here.
    public init(
        lifetime: Duration = Limits.selfWriteFingerprintLifetime,
        inFlightCeiling: Duration = .seconds(60)
    ) {
        self.lifetime = lifetime
        self.inFlightCeiling = inFlightCeiling
    }

    /// Marks the start of one of our writes to `url`.
    public func beginWrite(_ url: URL) -> WriteToken {
        let key = SelfWriteSuppressor.key(for: url)
        return state.withLock { state in
            let token = WriteToken(id: state.nextToken, key: key)
            state.nextToken += 1
            var entry = state.inFlight[key] ?? InFlight(count: 0, deadline: .now)
            entry.count += 1
            entry.deadline = .now.advanced(by: inFlightCeiling)
            state.inFlight[key] = entry
            return token
        }
    }

    /// Marks the end of one of our writes, recording what it produced.
    ///
    /// Pass `nil` when the write failed: the bracket lifts and nothing is suppressed
    /// afterwards, because a failed save leaves the file in whatever state it was already in.
    public func endWrite(_ token: WriteToken, fingerprint: FileFingerprint?) {
        state.withLock { state in
            if var entry = state.inFlight[token.key] {
                entry.count -= 1
                if entry.count <= 0 { state.inFlight[token.key] = nil } else { state.inFlight[token.key] = entry }
            }
            guard let fingerprint else { return }
            var list = state.expectations[token.key] ?? []
            list.removeAll { $0.expiry <= .now }
            list.append(Expectation(fingerprint: fingerprint, expiry: .now.advanced(by: lifetime)))
            // A burst of saves can leave several live expectations; keep the newest few rather
            // than growing without bound on a path somebody is scripting.
            if list.count > 8 { list.removeFirst(list.count - 8) }
            state.expectations[token.key] = list
        }
    }

    /// Records a fingerprint we expect to see, outside a write bracket.
    ///
    /// For writes performed by code that cannot use ``write(to:options:body:)`` — A2's writer,
    /// once it is wired in. Prefer the bracket: this form has the race the bracket closes.
    public func expect(_ fingerprint: FileFingerprint, for url: URL) {
        let token = beginWrite(url)
        endWrite(token, fingerprint: fingerprint)
    }

    /// Whether an event about `url` observing `fingerprint` should be delivered or dropped.
    ///
    /// `fingerprint` is `nil` when the file could not be read at all — a deletion, say. That is
    /// never suppressed by a fingerprint match, only by an in-flight write, because a file
    /// disappearing during our own atomic replace is a transient we created.
    public func decide(url: URL, observed fingerprint: FileFingerprint?) -> Decision {
        let key = SelfWriteSuppressor.key(for: url)
        return state.withLock { state in
            if let entry = state.inFlight[key] {
                if entry.deadline > .now { return .suppressedWriteInProgress }
                state.inFlight[key] = nil
            }
            guard let fingerprint, var list = state.expectations[key] else { return .deliver }
            let before = list.count
            list.removeAll { $0.expiry <= .now }
            if list.isEmpty {
                state.expectations[key] = nil
            } else if list.count != before {
                state.expectations[key] = list
            }
            // Deliberately not consumed on match: while the file still *is* what we wrote,
            // every event about it is still ours, and a writer's burst produces several.
            return list.contains { $0.fingerprint == fingerprint } ? .suppressedFingerprintMatch : .deliver
        }
    }

    /// Convenience over ``decide(url:observed:)``.
    public func shouldSuppress(url: URL, observed fingerprint: FileFingerprint?) -> Bool {
        decide(url: url, observed: fingerprint) != .deliver
    }

    /// Runs `body` inside a write bracket and records the fingerprint it returns.
    ///
    /// The shape every save should use — there is no path through it that forgets to register,
    /// including the throwing one.
    @discardableResult
    public func write(
        to url: URL,
        options: AtomicWriter.Options = .default,
        body: (AtomicWriter, URL, AtomicWriter.Options) throws(SheetError) -> FileFingerprint
    ) throws(SheetError) -> FileFingerprint {
        let token = beginWrite(url)
        do {
            let fingerprint = try body(AtomicWriter(), url, options)
            endWrite(token, fingerprint: fingerprint)
            return fingerprint
        } catch {
            endWrite(token, fingerprint: nil)
            throw error
        }
    }

    /// Writes `data` to `url` atomically, suppressing the events it causes.
    @discardableResult
    public func write(
        _ data: Data,
        to url: URL,
        options: AtomicWriter.Options = .default
    ) throws(SheetError) -> FileFingerprint {
        try write(to: url, options: options) { writer, target, writeOptions throws(SheetError) in
            try writer.write(data, to: target, options: writeOptions)
        }
    }

    /// Drops everything recorded for `url`. Used when a document is closed.
    public func forget(_ url: URL) {
        let key = SelfWriteSuppressor.key(for: url)
        state.withLock { state in
            state.expectations[key] = nil
            state.inFlight[key] = nil
        }
    }

    /// Live expectation count for a path. Tests only; the production answer is ``decide(url:observed:)``.
    func expectationCount(for url: URL) -> Int {
        let key = SelfWriteSuppressor.key(for: url)
        return state.withLock { state in
            (state.expectations[key] ?? []).count { $0.expiry > .now }
        }
    }

    /// Suppression is keyed on the *resolved* path, so a save through `~/link.xlsx` also
    /// suppresses the watcher that is looking at `~/real.xlsx`. Keying on the literal string
    /// would leave exactly one refresh loop unfixed, and it would be the one hardest to
    /// reproduce.
    private static func key(for url: URL) -> String {
        AtomicWriter.writeTarget(for: url).resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }
}
