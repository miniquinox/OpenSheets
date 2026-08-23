//
//  FailingFileSystem.swift
//  TestSupport
//
//  A filesystem that fails where you tell it to, so "atomic" can be proved rather than claimed.
//

import Darwin
import Foundation
import SheetModel
import Synchronization

/// The filesystem operations a save or a load performs, at the granularity a failure test cares
/// about.
///
/// Named after the syscall rather than after the `FileManager` method, because the interesting
/// question is always *"what happens if the `rename` fails?"* and never *"what happens if
/// `replaceItemAt` fails?"*.
public enum FileSystemOperation: String, Sendable, Hashable, CaseIterable, Codable {
    case createDirectory
    case openForWriting
    case write
    case sync
    case close
    case rename
    case replace
    case unlink
    case read
    case stat
    case listDirectory
    case setAttributes
}

/// The filesystem surface a component under test should depend on, so a test can swap it.
///
/// Deliberately small. Every method maps onto one or two syscalls, and there is no
/// `FileManager`-shaped convenience in it: a protocol that grows a `copyItem` gains a method
/// nobody can inject a failure into meaningfully.
public protocol FileSystemOperations: Sendable {
    func createDirectory(at url: URL) throws(SheetError)
    func writeFile(_ data: Data, to url: URL) throws(SheetError)
    func readFile(at url: URL) throws(SheetError) -> Data
    func fileExists(at url: URL) -> Bool
    func fileSize(at url: URL) throws(SheetError) -> Int
    func removeItem(at url: URL) throws(SheetError)
    func moveItem(at source: URL, to destination: URL) throws(SheetError)
    func replaceItem(at destination: URL, with source: URL) throws(SheetError)
    func synchronize(at url: URL) throws(SheetError)
    func contentsOfDirectory(at url: URL) throws(SheetError) -> [URL]
}

/// The real thing, with `SheetError` in place of `NSError`.
public struct RealFileSystem: FileSystemOperations {
    public init() {}

    public func createDirectory(at url: URL) throws(SheetError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SheetError.fileNotWritable(path: url.path, underlying: "\(error)")
        }
    }

    public func writeFile(_ data: Data, to url: URL) throws(SheetError) {
        do {
            try data.write(to: url)
        } catch {
            throw SheetError.fileNotWritable(path: url.path, underlying: "\(error)")
        }
    }

    public func readFile(at url: URL) throws(SheetError) -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SheetError.fileNotFound(path: url.path)
            }
            throw SheetError.fileNotReadable(path: url.path, underlying: "\(error)")
        }
    }

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func fileSize(at url: URL) throws(SheetError) -> Int {
        var status = stat()
        guard stat(url.path(percentEncoded: false), &status) == 0 else {
            throw SheetError.fileNotFound(path: url.path)
        }
        return Int(status.st_size)
    }

    public func removeItem(at url: URL) throws(SheetError) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SheetError.fileNotWritable(path: url.path, underlying: "\(error)")
        }
    }

    public func moveItem(at source: URL, to destination: URL) throws(SheetError) {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            throw SheetError.atomicReplaceFailed(path: destination.path, underlying: "\(error)")
        }
    }

    public func replaceItem(at destination: URL, with source: URL) throws(SheetError) {
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } catch {
            throw SheetError.atomicReplaceFailed(path: destination.path, underlying: "\(error)")
        }
    }

    public func synchronize(at url: URL) throws(SheetError) {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY)
        guard descriptor >= 0 else {
            throw SheetError.fileNotReadable(path: url.path, underlying: "errno \(errno)")
        }
        defer { close(descriptor) }
        // `F_FULLFSYNC` is the only real barrier on Darwin; plain `fsync` stops at the drive
        // cache. Falling back rather than failing, because some filesystems reject it.
        if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) == -1 {
            throw SheetError.fileNotWritable(path: url.path, underlying: "fsync: errno \(errno)")
        }
    }

    public func contentsOfDirectory(at url: URL) throws(SheetError) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } catch {
            throw SheetError.fileNotReadable(path: url.path, underlying: "\(error)")
        }
    }
}

/// One filesystem call, as recorded.
public struct FileSystemEvent: Sendable, Hashable {
    /// 1-based position in the log.
    public var index: Int
    public var operation: FileSystemOperation
    public var path: String
    /// The second path, for the two-argument operations.
    public var destinationPath: String?
    /// The code of the error that was injected, or `nil` if the call ran for real.
    public var injectedErrorCode: String?

    public var wasInjected: Bool { injectedErrorCode != nil }
}

/// Where a failure is injected.
public struct FileSystemFailure: Sendable, Hashable {
    /// The operation to fail.
    public var operation: FileSystemOperation
    /// Which occurrence of that operation to fail, 1-based. `nil` fails every one.
    public var occurrence: Int?
    /// Fail only when the path contains this fragment.
    public var pathContains: String?
    /// The error to throw.
    public var error: SheetError

    public init(
        operation: FileSystemOperation,
        occurrence: Int? = 1,
        pathContains: String? = nil,
        error: SheetError = .diskFull(path: "<injected>")
    ) {
        self.operation = operation
        self.occurrence = occurrence
        self.pathContains = pathContains
        self.error = error
    }

    /// Fail every occurrence of `operation`.
    public static func always(_ operation: FileSystemOperation, _ error: SheetError) -> FileSystemFailure {
        FileSystemFailure(operation: operation, occurrence: nil, error: error)
    }

    /// Fail the volume mid-write, which is the failure that most often eats a file.
    public static func diskFullDuringWrite(path: String = "<injected>") -> FileSystemFailure {
        FileSystemFailure(operation: .write, error: .diskFull(path: path))
    }

    /// Fail the final rename — the one moment where a non-atomic writer loses the original.
    public static func renameFails(path: String = "<injected>") -> FileSystemFailure {
        FileSystemFailure(
            operation: .rename,
            error: .atomicReplaceFailed(path: path, underlying: "injected by FailingFileSystem")
        )
    }
}

/// A filesystem that runs for real, records everything, and fails exactly where told.
///
/// The recording matters as much as the failing. Two questions a perf gate can ask it without a
/// stopwatch, and therefore without flaking under load:
///
/// - *How many `read` calls did opening this workbook make?* A reader that inflates every entry
///   in the archive rather than only the parts it parses shows up as a count, immediately.
/// - *How many `write` calls did one save make?* One is right; more means a re-encode.
///
/// The failure injection runs **after** the wrapped operation for `write` and **before** it for
/// everything else, which is not an accident: a `write` that fails without having written
/// anything cannot model a half-written file, and a half-written file is the case an atomic
/// writer exists to survive.
public final class FailingFileSystem: FileSystemOperations, Sendable {
    private struct State {
        var failures: [FileSystemFailure] = []
        var counts: [FileSystemOperation: Int] = [:]
        var events: [FileSystemEvent] = []
        /// Bytes actually written before an injected `write` failure, as a fraction.
        var partialWriteFraction: Double = 0.5
    }

    private let base: any FileSystemOperations
    private let state = Mutex(State())

    /// Wraps `base`, failing where `failures` say.
    public init(wrapping base: any FileSystemOperations = RealFileSystem(), failures: [FileSystemFailure] = []) {
        self.base = base
        state.withLock { $0.failures = failures }
    }

    /// Wraps the real filesystem and fails at one operation.
    public convenience init(failingAt operation: FileSystemOperation, with error: SheetError) {
        self.init(failures: [FileSystemFailure(operation: operation, error: error)])
    }

    // MARK: - Programming it

    /// Replaces the failure list.
    public func setFailures(_ failures: [FileSystemFailure]) {
        state.withLock { $0.failures = failures }
    }

    /// Adds one more failure.
    public func addFailure(_ failure: FileSystemFailure) {
        state.withLock { $0.failures.append(failure) }
    }

    /// Removes every injected failure, so the wrapped filesystem runs clean from here on.
    public func clearFailures() {
        state.withLock { $0.failures.removeAll() }
    }

    /// How much of the data lands on disk before an injected `write` failure. `0` writes
    /// nothing, `1` writes everything and then fails. Defaults to half.
    public func setPartialWriteFraction(_ fraction: Double) {
        state.withLock { $0.partialWriteFraction = min(max(fraction, 0), 1) }
    }

    /// Forgets the event log and the per-operation counters. Failures are left alone.
    public func resetLog() {
        state.withLock {
            $0.events.removeAll()
            $0.counts.removeAll()
        }
    }

    // MARK: - Observing it

    /// Everything that happened, in order.
    public var events: [FileSystemEvent] { state.withLock { $0.events } }

    /// How many times `operation` was attempted.
    public func count(of operation: FileSystemOperation) -> Int {
        state.withLock { $0.counts[operation] ?? 0 }
    }

    /// The per-operation tally — a work-done metric that does not depend on how busy the
    /// machine is.
    public var operationCounts: [FileSystemOperation: Int] { state.withLock { $0.counts } }

    /// Whether any injected failure actually fired. A failure test that never triggers its own
    /// injection is passing for the wrong reason, and this is how to catch that.
    public var didInjectFailure: Bool { state.withLock { $0.events.contains { $0.wasInjected } } }

    /// A one-line summary for a failure message.
    public var summary: String {
        let counts = operationCounts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue)=\($0.value)" }
            .joined(separator: " ")
        return counts.isEmpty ? "no filesystem activity" : counts
    }

    // MARK: - FileSystemOperations

    public func createDirectory(at url: URL) throws(SheetError) {
        if let error = check(.createDirectory, url) { throw error }
        try base.createDirectory(at: url)
    }

    public func writeFile(_ data: Data, to url: URL) throws(SheetError) {
        // Write-then-fail, so the destination is left holding a truncated file — which is
        // exactly the state a caller claiming atomicity must never leave behind.
        if let error = check(.write, url) {
            let fraction = state.withLock { $0.partialWriteFraction }
            let prefixLength = Int(Double(data.count) * fraction)
            if prefixLength > 0 {
                try? base.writeFile(data.prefix(prefixLength), to: url)
            }
            throw error
        }
        try base.writeFile(data, to: url)
    }

    public func readFile(at url: URL) throws(SheetError) -> Data {
        if let error = check(.read, url) { throw error }
        return try base.readFile(at: url)
    }

    /// Reports `false` when a `.stat` failure is injected, because that is what a caller sees
    /// when `stat` fails: as far as it can tell, the file is not there.
    ///
    /// It goes through the same counter as ``fileSize(at:)`` rather than a private one, so that
    /// `FileSystemFailure(operation: .stat, occurrence: 2)` means the second `stat` *this
    /// filesystem performed* — not the second of whichever of the two entry points happened to
    /// be counted separately.
    public func fileExists(at url: URL) -> Bool {
        if check(.stat, url) != nil { return false }
        return base.fileExists(at: url)
    }

    public func fileSize(at url: URL) throws(SheetError) -> Int {
        if let error = check(.stat, url) { throw error }
        return try base.fileSize(at: url)
    }

    public func removeItem(at url: URL) throws(SheetError) {
        if let error = check(.unlink, url) { throw error }
        try base.removeItem(at: url)
    }

    public func moveItem(at source: URL, to destination: URL) throws(SheetError) {
        if let error = check(.rename, source, destination: destination) { throw error }
        try base.moveItem(at: source, to: destination)
    }

    public func replaceItem(at destination: URL, with source: URL) throws(SheetError) {
        if let error = check(.replace, destination, destination: source) { throw error }
        try base.replaceItem(at: destination, with: source)
    }

    public func synchronize(at url: URL) throws(SheetError) {
        if let error = check(.sync, url) { throw error }
        try base.synchronize(at: url)
    }

    public func contentsOfDirectory(at url: URL) throws(SheetError) -> [URL] {
        if let error = check(.listDirectory, url) { throw error }
        return try base.contentsOfDirectory(at: url)
    }

    // MARK: - Plumbing

    /// Tallies the call, decides whether it fails, and logs the decision.
    private func check(
        _ operation: FileSystemOperation,
        _ url: URL,
        destination: URL? = nil
    ) -> SheetError? {
        state.withLock { state in
            let occurrence = (state.counts[operation] ?? 0) + 1
            state.counts[operation] = occurrence
            let path = url.path(percentEncoded: false)
            let match = state.failures.first { failure in
                failure.operation == operation
                    && (failure.occurrence == nil || failure.occurrence == occurrence)
                    && (failure.pathContains.map { path.contains($0) } ?? true)
            }
            state.events.append(FileSystemEvent(
                index: state.events.count + 1,
                operation: operation,
                path: path,
                destinationPath: destination?.path(percentEncoded: false),
                injectedErrorCode: match?.error.code
            ))
            return match?.error
        }
    }

}

/// A real directory under `NSTemporaryDirectory()`, deleted when you say so.
///
/// Every failure test needs one and every one of them gets the cleanup subtly wrong. This one
/// is uniquely named, so two tests running in parallel — which they do, Swift Testing runs
/// suites concurrently by default — cannot collide.
public struct TemporaryDirectory: Sendable {
    public let url: URL

    /// Creates the directory. Throws if it cannot be created, rather than failing later at the
    /// first write with a confusing error.
    public init(prefix: String = "opensheets-test") throws(SheetError) {
        let candidate = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        } catch {
            throw SheetError.fileNotWritable(path: candidate.path, underlying: "\(error)")
        }
        url = candidate
    }

    /// A path inside the directory. The file does not have to exist.
    public func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Writes `contents` to `name` and returns its URL.
    @discardableResult
    public func write(_ contents: Data, to name: String) throws(SheetError) -> URL {
        let target = file(name)
        do {
            try contents.write(to: target)
        } catch {
            throw SheetError.fileNotWritable(path: target.path, underlying: "\(error)")
        }
        return target
    }

    /// Writes UTF-8 text to `name`.
    @discardableResult
    public func write(_ text: String, to name: String) throws(SheetError) -> URL {
        try write(Data(text.utf8), to: name)
    }

    /// Deletes the directory and everything in it. Safe to call twice.
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Runs `body` with a fresh temporary directory and removes it afterwards, even on a throw.
    public static func withTemporaryDirectory<Result>(
        prefix: String = "opensheets-test",
        _ body: (TemporaryDirectory) throws -> Result
    ) throws -> Result {
        let directory = try TemporaryDirectory(prefix: prefix)
        defer { directory.remove() }
        return try body(directory)
    }

    /// The async form.
    public static func withTemporaryDirectory<Result>(
        prefix: String = "opensheets-test",
        _ body: (TemporaryDirectory) async throws -> Result
    ) async throws -> Result {
        let directory = try TemporaryDirectory(prefix: prefix)
        defer { directory.remove() }
        return try await body(directory)
    }

    // MARK: - Real-errno scenarios

    /// Makes the directory unwritable, so the *real* `open` fails with `EACCES`.
    ///
    /// Injection proves the error-handling path; this proves the error-*detection* path, and
    /// they are not the same test. A writer that only ever sees a `SheetError` thrown by a fake
    /// has never been shown to notice a real `errno`.
    @discardableResult
    public func makeReadOnly() -> Bool {
        chmod(url.path(percentEncoded: false), 0o500) == 0
    }

    /// Restores write permission, so ``remove()`` can do its job.
    @discardableResult
    public func makeWritable() -> Bool {
        chmod(url.path(percentEncoded: false), 0o700) == 0
    }

    /// Creates a directory where a file is expected, so a real write fails with `EISDIR`.
    @discardableResult
    public func placeDirectory(named name: String) -> URL? {
        let target = file(name)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        } catch {
            return nil
        }
    }

    /// Creates a symlink pointing at nothing, so a real read fails with `ENOENT` on a path that
    /// `lstat` says exists.
    @discardableResult
    public func placeBrokenSymlink(named name: String) -> URL? {
        let target = file(name)
        let missing = file("does-not-exist-\(UUID().uuidString)")
        do {
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: missing)
            return target
        } catch {
            return nil
        }
    }
}
