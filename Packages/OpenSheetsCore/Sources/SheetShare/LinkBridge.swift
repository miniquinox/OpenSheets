import Darwin
import Foundation
import SheetModel
import SheetStore

/// One `opensheets-mcp` subprocess per active link, and the newline-framed conversation with it.
///
/// # Why a subprocess at all
///
/// This is decision D1, and it is the reason `DOCUMENTATION.md` §5.9's argument survives Cloud
/// Share. The serving process is the same local binary Claude Code spawns, in the same
/// `.enforcementOnly` mode, checking the same grants against the same deny-list. Nothing about
/// what a caller may reach changed; what changed is that the app is now willing to pump that
/// process's stdio to a socket, per link, with the owner's revocable consent. A second transport
/// bolted onto `MCPServer` would have moved the boundary. A pipe does not.
///
/// # Why one call at a time per link (D8)
///
/// The server serialises its own dispatch and emits nothing unsolicited: no notifications,
/// `listChanged: false`, logging to stderr. That makes "write a frame, read the next line" a
/// complete and correct correlation rule — the next line *is* the answer, and no `id` matching is
/// needed. It is only correct while one frame is in flight, so this actor enforces exactly that,
/// per link, with a chain of tasks. Two clients sharing a link take turns; the ceiling matches
/// the server's own.
///
/// A frame with no `id` (a JSON-RPC notification) gets no answer at all, so it is written and
/// forgotten — awaiting a line for it would consume the *next* request's response and desync the
/// stream permanently. The relay knows this too, and sets `expectsReply: false`.
///
/// # What a dead child means
///
/// Nothing is respawned eagerly. A child that crashed, was reaped for idleness, or was killed by
/// a revoke is simply absent, and the next request spawns a new one — the same lazy rule that
/// makes "the flag is off" cost nothing. The request that was in flight when a child died gets
/// ``RelayResponseOutcome/Failure/subprocessFailed``, which the relay turns into the offline
/// JSON-RPC error with the caller's id echoed.
public actor LinkBridge {
    /// Timings, limits, and the two seams a test needs: the child's environment and the clock.
    ///
    /// Every duration here is injectable, and the deterministic cases set none of them — they
    /// call ``LinkBridge/reapIdle(asOf:)`` with a date of their choosing instead, so nothing in
    /// this suite waits on a timer to prove a timer works.
    public struct Configuration: Sendable {
        /// How long one call may take before its child is presumed dead. Under the relay's
        /// 120 s so the Mac gives its own answer rather than letting the relay time out first,
        /// and under Claude's 300 s tool budget by a wide margin.
        public var callTimeout: Duration

        /// How long a child may sit unused before it is reaped. Five minutes: long enough that
        /// a conversation's pauses do not pay start-up costs, short enough that a link nobody
        /// is using is not a process on the owner's Mac.
        public var idleTimeout: Duration

        /// How often the reaper looks. Coarse on purpose — this is housekeeping, not a deadline.
        public var reapInterval: Duration

        /// Mirrors `FrameReader.maximumFrameBytes` (32 MB), which is the ceiling the subprocess
        /// enforces on its own input. Written as a number rather than imported because
        /// `SheetShare` deliberately cannot see `SheetMCP` — the two constants agreeing is
        /// asserted by the bridge tests talking to the real binary.
        public var maximumFrameBytes: Int

        /// The child's environment. `nil` inherits this process's, which is what production
        /// wants. Tests pass a staged `HOME`/`CFFIXED_USER_HOME` so the subprocess reads a
        /// grant store the test built rather than the developer's.
        public var environment: [String: String]?

        /// The clock idle-reaping compares against.
        public var now: @Sendable () -> Date

        /// Where the *reason* a call failed goes.
        ///
        /// The wire only ever carries the three pinned spellings in
        /// ``RelayResponseOutcome/Failure`` — a stranger's MCP client is not the place to
        /// describe our subprocess — so the sentence that says which of the several ways this
        /// went wrong actually happened, plus the tail of the child's stderr, comes out here.
        /// ``CloudShareEngine`` forwards it as a diagnostic event; the default drops it.
        public var log: @Sendable (String) -> Void

        public init(
            callTimeout: Duration = .seconds(90),
            idleTimeout: Duration = .seconds(300),
            reapInterval: Duration = .seconds(60),
            maximumFrameBytes: Int = 32 * 1024 * 1024,
            environment: [String: String]? = nil,
            now: @escaping @Sendable () -> Date = Date.init,
            log: @escaping @Sendable (String) -> Void = { _ in }
        ) {
            self.callTimeout = callTimeout
            self.idleTimeout = idleTimeout
            self.reapInterval = reapInterval
            self.maximumFrameBytes = maximumFrameBytes
            self.environment = environment
            self.now = now
            self.log = log
        }

        public static let `default` = Configuration()
    }

    /// One live subprocess. A class rather than a struct because `Process` is a reference type
    /// already and `lastUsedAt` is touched on every call; it never leaves this actor.
    private final class Child {
        let process: Process
        let channel: SubprocessChannel
        let mode: ShareLinkMode
        var lastUsedAt: Date

        init(process: Process, channel: SubprocessChannel, mode: ShareLinkMode, lastUsedAt: Date) {
            self.process = process
            self.channel = channel
            self.mode = mode
            self.lastUsedAt = lastUsedAt
        }
    }

    private let binaryURL: URL
    private let configuration: Configuration
    private var children: [String: Child] = [:]

    /// The per-link serial chain. See the type's note on D8.
    private var tails: [String: Task<Void, Never>] = [:]
    private var outstanding: [String: Int] = [:]
    private var reaper: Task<Void, Never>?

    /// Bumped every time the reaper starts or stops. A loop whose generation is stale belongs to
    /// a bridge that has been shut down since, and returns rather than reaping for a session
    /// nobody is running — ``RelayClient``'s idea, for the same reason: the alternative is a
    /// teardown that has to cancel a sleeping task correctly.
    private var reaperGeneration: UInt64 = 0

    /// How many children have exited, counted from `Process.terminationHandler`.
    ///
    /// This is the only honest way to assert "the reap actually killed it": the actor's own
    /// bookkeeping says the child was dropped, but the operating system is what says the process
    /// is gone. Diagnostic in production, load-bearing in ``LinkBridgeTests``.
    public private(set) var exitedChildren = 0

    /// - Parameter binaryURL: the embedded `opensheets-mcp`. Injected rather than discovered
    ///   here: the app finds it through `Bundle.main.url(forAuxiliaryExecutable:)`, which is a
    ///   thing only an app bundle has, and a test points at what `swift build` produced.
    public init(binaryURL: URL, configuration: Configuration = .default) {
        self.binaryURL = binaryURL
        self.configuration = configuration
    }

    // MARK: - The conversation

    /// Writes one MCP frame to `linkID`'s subprocess and, if the frame expects one, returns the
    /// single line that came back.
    ///
    /// `nil` means "no answer, and none was owed" — a notification. Everything else is an
    /// outcome the caller can put on the wire verbatim.
    public func exchange(
        linkID: String,
        mode: ShareLinkMode,
        body: String,
        expectsReply: Bool
    ) async -> RelayResponseOutcome? {
        guard body.utf8.count <= configuration.maximumFrameBytes else {
            // Refused before a process exists: an oversize frame is a caller problem, and
            // spawning a subprocess to tell them so would make it ours.
            return expectsReply ? .failed(error: RelayResponseOutcome.Failure.frameTooLarge) : nil
        }
        return await serialized(linkID) { [self] in
            await perform(linkID: linkID, mode: mode, body: body, expectsReply: expectsReply)
        }
    }

    private func perform(
        linkID: String,
        mode: ShareLinkMode,
        body: String,
        expectsReply: Bool
    ) async -> RelayResponseOutcome? {
        let child: Child
        do {
            child = try childFor(linkID: linkID, mode: mode)
        } catch {
            return failed(linkID, expectsReply, error.message, nil)
        }
        child.lastUsedAt = configuration.now()

        let channel = child.channel
        do {
            try channel.writeLine(body)
        } catch {
            // A write that fails is almost always a child that died between the last call and
            // this one, and the pipe only says so on the next write. Drop it; the next request
            // spawns a fresh one.
            drop(linkID: linkID)
            return failed(linkID, expectsReply, error.message, channel)
        }

        guard expectsReply else { return nil }

        // The timeout lives in the channel rather than in a task race: cancelling a task that is
        // parked inside `nextLine()` would leave the pending read half-consumed, and the next
        // call would read the answer to this one.
        let timeout = configuration.callTimeout
        let timer = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            channel.expirePendingRead()
        }
        let outcome = await channel.nextLine()
        timer.cancel()

        switch outcome {
        case let .line(text):
            return .ok(body: text)
        case .closed:
            drop(linkID: linkID)
            return failed(linkID, expectsReply, "its output closed while a call was in flight", channel)
        case .expired:
            drop(linkID: linkID)
            return failed(linkID, expectsReply, "it did not answer within \(timeout)", channel)
        case let .failed(error):
            drop(linkID: linkID)
            if case .resultTooLarge = error {
                configuration.log(
                    "link \(linkID): the subprocess emitted a frame over the "
                        + "\(configuration.maximumFrameBytes)-byte ceiling"
                )
                return expectsReply ? .failed(error: RelayResponseOutcome.Failure.frameTooLarge) : nil
            }
            return failed(linkID, expectsReply, error.message, channel)
        }
    }

    /// Every failure the bridge reports carries the same wire spelling; the reason goes to
    /// ``Configuration/log``, because the relay flattens all of them into one JSON-RPC error
    /// anyway and a stranger's client is not the place to describe our subprocess.
    private func failed(
        _ linkID: String,
        _ expectsReply: Bool,
        _ reason: String,
        _ channel: SubprocessChannel?
    ) -> RelayResponseOutcome? {
        let tail = channel?.recentStandardError ?? ""
        configuration.log("link \(linkID): the MCP subprocess failed — \(reason)\(tail.isEmpty ? "" : ": \(tail)")")
        guard expectsReply else { return nil }
        return .failed(error: RelayResponseOutcome.Failure.subprocessFailed)
    }

    // MARK: - Serialisation (D8)

    /// Runs `work` after every call already queued for this link, and before every call queued
    /// after it.
    ///
    /// The chain is built synchronously inside the actor — no `await` between reading the tail
    /// and installing the new one — which is what makes it a queue rather than a race.
    private func serialized(
        _ linkID: String,
        _ work: @escaping @Sendable () async -> RelayResponseOutcome?
    ) async -> RelayResponseOutcome? {
        outstanding[linkID, default: 0] += 1
        let previous = tails[linkID]
        let task = Task { () -> RelayResponseOutcome? in
            await previous?.value
            return await work()
        }
        tails[linkID] = Task { _ = await task.value }
        let outcome = await task.value
        let remaining = (outstanding[linkID] ?? 1) - 1
        if remaining <= 0 {
            outstanding[linkID] = nil
            tails[linkID] = nil
        } else {
            outstanding[linkID] = remaining
        }
        return outcome
    }

    // MARK: - Children

    private func childFor(linkID: String, mode: ShareLinkMode) throws(SheetError) -> Child {
        if let existing = children[linkID] {
            // A mode change cannot happen in v1 — links are created with a mode and never
            // edited — but a child serving the wrong registry would be a silent privilege
            // change, so it is checked rather than assumed.
            if existing.process.isRunning, existing.mode == mode { return existing }
            drop(linkID: linkID)
        }
        let child = try spawn(mode: mode)
        children[linkID] = child
        return child
    }

    private func spawn(mode: ShareLinkMode) throws(SheetError) -> Child {
        let process = Process()
        process.executableURL = binaryURL
        // The shim prepends `serve`, so this is the whole of what D4 means on the command line.
        // A read-write link passes nothing and gets the standard 25-tool registry.
        process.arguments = mode == .readOnly ? ["--read-only"] : []
        if let environment = configuration.environment { process.environment = environment }

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in
            Task { await self?.noteChildExited() }
        }

        do {
            try process.run()
        } catch {
            throw .fileNotReadable(
                path: binaryURL.path(percentEncoded: false),
                underlying: "the MCP server could not be started: \(error)"
            )
        }
        return Child(
            process: process,
            channel: SubprocessChannel(
                input: input,
                output: output,
                errors: errors,
                maximumFrameBytes: configuration.maximumFrameBytes
            ),
            mode: mode,
            lastUsedAt: configuration.now()
        )
    }

    private func noteChildExited() {
        exitedChildren += 1
    }

    /// Ends a link's subprocess. Used by the reaper, by a revoke, and by every failure path —
    /// there is one way to stop a child, so there is one place that gets the ordering right.
    public func stop(linkID: String) {
        drop(linkID: linkID)
    }

    private func drop(linkID: String) {
        guard let child = children.removeValue(forKey: linkID) else { return }
        // Closing stdin first is the graceful exit: `serve` blocks on stdin and returns at EOF,
        // which lets the server finish whatever it was writing. `terminate()` is the backstop
        // for a child that is wedged rather than idle.
        child.channel.close()
        if child.process.isRunning { child.process.terminate() }
    }

    /// Stops every child. Called when Cloud Share is switched off, and by the app on quit.
    public func stopAll() {
        // Snapshotted: `drop` mutates `children`, and iterating a dictionary's keys view while
        // the dictionary changes underneath is undefined.
        for linkID in Array(children.keys) { drop(linkID: linkID) }
    }

    // MARK: - Idle reaping

    /// Starts the background reaper. Idempotent.
    public func startReaping() {
        guard reaper == nil else { return }
        reaperGeneration &+= 1
        let generation = reaperGeneration
        let interval = configuration.reapInterval
        let now = configuration.now
        // Detached rather than inheriting this actor's isolation: a `Task {}` created inside an
        // actor runs *on* that actor, so this loop would hold its executor for the life of the
        // app while doing nothing but sleeping. Detached keeps the housekeeping off the actor
        // and makes every touch of it the explicit hop the `await` below already says it is.
        reaper = Task.detached { [weak self] in
            while true {
                try? await Task.sleep(for: interval)
                guard let bridge = self, await bridge.reaperGeneration == generation else { return }
                await bridge.reapIdle(asOf: now())
            }
        }
    }

    /// Kills every child untouched since `date` minus the idle timeout.
    ///
    /// Public and takes its own clock so a test can reap deterministically instead of waiting
    /// five minutes for the timer it would otherwise be asserting on.
    public func reapIdle(asOf date: Date) {
        let deadline = date.addingTimeInterval(-configuration.idleTimeout.seconds)
        let idle = children.filter { $0.value.lastUsedAt <= deadline }.map(\.key)
        for linkID in idle { drop(linkID: linkID) }
    }

    /// Stops the reaper and every child. The bridge can be used again afterwards; the next call
    /// spawns what it needs.
    public func shutDown() {
        // The reaper is stopped by the generation rather than by `cancel()`. It wakes at its own
        // pace, sees it belongs to a session nobody is running, and returns; the alternative —
        // unwinding a cancelled sleep — buys a few seconds of tidiness at the cost of a teardown
        // path that has to be right under cancellation, and this loop has nothing worth hurrying.
        reaperGeneration &+= 1
        reaper = nil
        stopAll()
    }

    // MARK: - Diagnostics

    /// Links with a live subprocess right now.
    public var activeLinkIDs: [String] {
        children.keys.sorted()
    }

    /// The child's pid, or `nil` if this link has none. Diagnostic, and how a test tells a
    /// respawned child from the one it replaced.
    public func processIdentifier(forLink linkID: String) -> Int32? {
        children[linkID]?.process.processIdentifier
    }
}

// MARK: - The pipe

/// Newline-framed reading and writing over one child's pipes.
///
/// # Why this is hand-rolled rather than `FileHandle.bytes`
///
/// `AsyncBytes` cannot be cancelled out of without consuming what it already buffered, and this
/// conversation has exactly one rule: **one write, one line**. A timeout that abandoned a
/// half-read line would hand the next call somebody else's answer, which is the one failure this
/// design cannot tolerate — it would mean a client seeing another client's spreadsheet. So the
/// buffer is explicit, the single pending read is explicit, and expiring it is a method rather
/// than a cancellation.
///
/// `@unchecked Sendable` because the lock, not the compiler, is what makes this safe:
/// `readabilityHandler` is called from Foundation's own queue and there is no way to express
/// that isolation in the type system. Every mutable field below is touched only under `lock`.
final class SubprocessChannel: @unchecked Sendable {
    /// What one read produced.
    enum ReadOutcome: Sendable {
        case line(String)
        /// The pipe reached EOF: the child exited.
        case closed
        /// The call timed out. The child is presumed dead and dropped by the caller.
        case expired
        case failed(SheetError)
    }

    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle
    private let maximumFrameBytes: Int

    private let lock = NSLock()
    private var pending: [UInt8] = []
    private var lines: [String] = []
    private var waiter: CheckedContinuation<ReadOutcome, Never>?
    /// Sticky once set: a closed pipe stays closed, and every later read says so immediately.
    private var terminal: ReadOutcome?
    private var stderrTail: [UInt8] = []
    private var isClosed = false

    /// The last few KB the child wrote to stderr, for a log line that says *why* a subprocess
    /// failed rather than only that it did.
    var recentStandardError: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrTail, as: UTF8.self)
    }

    init(input: Pipe, output: Pipe, errors: Pipe, maximumFrameBytes: Int) {
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        self.errors = errors.fileHandleForReading
        self.maximumFrameBytes = maximumFrameBytes

        // Writing to a pipe whose reader has exited raises SIGPIPE, whose default disposition
        // kills *this* process — the app. `F_SETNOSIGPIPE` turns that into an `EPIPE` the write
        // can throw, which is the difference between "the bridge reports a dead child" and
        // "OpenSheets quits because a share link's subprocess crashed".
        _ = fcntl(self.input.fileDescriptor, F_SETNOSIGPIPE, 1)

        self.output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                finish(.closed)
            } else {
                absorb(data)
            }
        }
        self.errors.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                absorbStandardError(data)
            }
        }
    }

    // MARK: - Writing

    func writeLine(_ text: String) throws(SheetError) {
        lock.lock()
        let closed = isClosed
        lock.unlock()
        guard !closed else {
            throw .fileNotWritable(path: "opensheets-mcp stdin", underlying: "the pipe is closed")
        }
        do {
            try input.write(contentsOf: Data((text + "\n").utf8))
        } catch {
            throw .fileNotWritable(path: "opensheets-mcp stdin", underlying: "\(error)")
        }
    }

    // MARK: - Reading

    func nextLine() async -> ReadOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<ReadOutcome, Never>) in
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                continuation.resume(returning: .line(line))
                return
            }
            if let terminal {
                lock.unlock()
                continuation.resume(returning: terminal)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    /// Gives up on the read that is currently pending, if any. The caller kills the child
    /// afterwards, which is what keeps "one write, one line" true: a line that arrives after
    /// this would have no owner.
    func expirePendingRead() {
        lock.lock()
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: .expired)
    }

    func close() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        lock.unlock()

        output.readabilityHandler = nil
        errors.readabilityHandler = nil
        try? input.close()
        finish(.closed)
    }

    // MARK: - Pipe callbacks

    private func absorb(_ data: Data) {
        lock.lock()
        pending.append(contentsOf: data)
        var delivered: [String] = []
        while let index = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[..<index], as: UTF8.self)
            pending.removeSubrange(...index)
            if !line.isEmpty { delivered.append(line) }
        }
        if pending.count > maximumFrameBytes {
            let overflow = pending.count
            pending = []
            lock.unlock()
            finish(.failed(.resultTooLarge(bytes: overflow, limit: maximumFrameBytes)))
            return
        }
        lines.append(contentsOf: delivered)
        var waiting: CheckedContinuation<ReadOutcome, Never>?
        var next: String?
        if let waiter, !lines.isEmpty {
            waiting = waiter
            self.waiter = nil
            next = lines.removeFirst()
        }
        lock.unlock()
        if let waiting, let next { waiting.resume(returning: .line(next)) }
    }

    private func absorbStandardError(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stderrTail.append(contentsOf: data)
        if stderrTail.count > SubprocessChannel.standardErrorTailBytes {
            stderrTail.removeFirst(stderrTail.count - SubprocessChannel.standardErrorTailBytes)
        }
    }

    /// Records a terminal state and wakes whoever was waiting. Sticky: the first terminal
    /// outcome is the one every later read gets.
    private func finish(_ outcome: ReadOutcome) {
        lock.lock()
        if terminal == nil { terminal = outcome }
        let waiting = waiter
        waiter = nil
        let settled = terminal ?? outcome
        lock.unlock()
        waiting?.resume(returning: settled)
    }

    private static let standardErrorTailBytes = 4096
}
