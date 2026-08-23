import CoreServices
import Darwin
import Dispatch
import Foundation
import SheetModel

/// Something happened to the watched file.
///
/// Already debounced, already de-duplicated against the last known state, and already checked
/// against ``SelfWriteSuppressor`` — one of these means *the file really changed and it was not
/// us*. Everything downstream can trust that.
public enum FileWatcherEvent: Sendable, Hashable {
    /// The file exists and its content differs from the last state we saw.
    case changed(FileProbe)
    /// Permissions or flags changed but the content did not — the file was locked, unlocked,
    /// or its mode changed. Carries the new probe so the state machine can choose between
    /// `LOCKED`, `READ_ONLY` and going back to `SYNCED`.
    case attributesChanged(FileProbe)
    /// The path no longer resolves to a file.
    case vanished
    /// The path resolves again after having vanished.
    case reappeared(FileProbe)
    /// The volume the file lives on went away.
    case volumeUnavailable
    /// An iCloud or Dropbox placeholder that has not been materialised.
    case notDownloaded
    /// Something is there and we cannot read it — including "a directory now sits where the
    /// file used to be", which is rare and extremely confusing when it is not reported.
    case unreadable(SheetError)
    /// The watcher could not keep watching. Terminal; the watcher has stopped.
    case failed(SheetError)
}

/// Watches one file, and does not stop watching it (PLAN.md §6.1).
///
/// **Two sources, and both are mandatory.**
///
/// - A `DispatchSource` file-system-object source on an open descriptor sees in-place writes
///   the instant they happen, but a descriptor follows the *inode*. When a writer saves the
///   way every careful writer saves — write a sibling, rename over the original — the
///   descriptor is still attached to the old, now-unlinked inode. It reports `.rename`/`.delete`
///   and then goes quiet forever. Our own ``AtomicWriter`` saves this way, as do `openpyxl`,
///   `xlsxwriter`, `pandas`, `exceljs` and every editor worth using.
/// - An FSEvents stream on the *parent directory* sees the rename, because it watches by path.
///   It is also what reports the file coming back after a delete, and what survives the parent
///   directory itself being renamed (`kFSEventStreamCreateFlagWatchRoot`).
///
/// So: the descriptor source gives low latency, FSEvents gives durability, and the descriptor
/// source is **re-armed on the new inode** every time the path is replaced. That re-arm is the
/// single line whose absence produces the classic "it worked once and then the app stopped
/// noticing" bug, so ``FileWatcherTests`` drives 100 consecutive atomic replaces through it.
///
/// Everything below runs on one serial queue. The class is `@unchecked Sendable` because that
/// queue, not the compiler, is what makes the mutable state safe — FSEvents hands us a raw C
/// callback and there is no way to express that in the type system.
public final class FileWatcher: @unchecked Sendable {
    /// Timings, all defaulting to ``Limits``. Tests turn them down; nothing else should.
    public struct Configuration: Sendable {
        /// How long to wait for a burst of events to finish before probing. PLAN.md §6.1: 150 ms.
        public var debounce: Duration
        /// After probing, wait this long and probe again. If the two disagree the writer is
        /// still going, so back off — this is what stops a half-written archive reaching the
        /// parser. Set to `.zero` to skip.
        public var stabilityInterval: Duration
        /// How many times to back off before reporting what we have anyway.
        public var maximumStabilityRetries: Int
        /// How often to retry arming the descriptor source while the file does not exist.
        public var rearmInterval: Duration
        /// Bytes of the file covered by ``FileFingerprint/headHash``.
        public var headByteCount: Int
        /// FSEvents coalescing window. Lower than the debounce on purpose: FSEvents latency
        /// adds to it rather than replacing it.
        public var fsEventsLatency: TimeInterval

        public init(
            debounce: Duration = Limits.watcherDebounce,
            stabilityInterval: Duration = .milliseconds(30),
            maximumStabilityRetries: Int = 20,
            rearmInterval: Duration = .milliseconds(250),
            headByteCount: Int = FileFingerprint.defaultHeadByteCount,
            fsEventsLatency: TimeInterval = 0.02
        ) {
            self.debounce = debounce
            self.stabilityInterval = stabilityInterval
            self.maximumStabilityRetries = maximumStabilityRetries
            self.rearmInterval = rearmInterval
            self.headByteCount = headByteCount
            self.fsEventsLatency = fsEventsLatency
        }

        public static let `default` = Configuration()
    }

    /// The file being watched, as the caller spelled it.
    public let url: URL
    /// See ``Configuration``.
    public let configuration: Configuration

    private let queue: DispatchQueue
    private let suppressor: SelfWriteSuppressor?
    private let continuation: AsyncStream<FileWatcherEvent>.Continuation

    /// Every event, in order. Unbounded buffering: dropping one here would be a lost refresh,
    /// which is precisely what this component exists to prevent.
    public let events: AsyncStream<FileWatcherEvent>

    // MARK: - Queue-confined state

    private var descriptorSource: (any DispatchSourceFileSystemObject)?
    /// Bumped on every re-arm. A handler belonging to a superseded source sees a stale value
    /// and returns, which is how an event for an inode nobody can reach is discarded without
    /// the handler having to hold a reference to its own source (and thus a retain cycle).
    private var descriptorGeneration: UInt64 = 0
    private var stream: FSEventStreamRef?
    private var contextBox: Unmanaged<CallbackBox>?
    private var debounceWork: DispatchWorkItem?
    private var rearmWork: DispatchWorkItem?
    private var stabilityAttempt = 0
    private var lastCondition: FileCondition?
    private var isRunning = false
    private var hasVanished = false

    private static let queueKey = DispatchSpecificKey<Bool>()

    /// - Parameters:
    ///   - url: the file to watch. Symlinks are resolved for watching, reported as given.
    ///   - suppressor: consulted before every emission, so our own saves never reach the
    ///     consumer. Optional only so the watcher can be tested on its own.
    public init(
        url: URL,
        configuration: Configuration = .default,
        suppressor: SelfWriteSuppressor? = nil
    ) {
        self.url = url
        self.configuration = configuration
        self.suppressor = suppressor
        queue = DispatchQueue(label: "com.opensheets.filewatcher.\(ULID().rawValue)", qos: .utility)
        let (stream, continuation) = AsyncStream<FileWatcherEvent>.makeStream(bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation
        queue.setSpecific(key: FileWatcher.queueKey, value: true)
    }

    deinit {
        // Tear down synchronously: an FSEvents callback in flight against a deallocating
        // object is a use-after-free, and the only guarantee against it is doing the
        // stop/unschedule/invalidate dance on the queue the stream was scheduled on.
        if DispatchQueue.getSpecific(key: FileWatcher.queueKey) == true {
            teardownOnQueue()
        } else {
            queue.sync { teardownOnQueue() }
        }
        continuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts watching. A second call is a no-op.
    ///
    /// Does **not** require the file to exist. A watcher armed on a path that is about to be
    /// created is a legitimate thing to want, and FSEvents reports its arrival.
    public func start() throws(SheetError) {
        var failure: SheetError?
        queue.sync {
            guard !isRunning else { return }
            isRunning = true
            let condition = probe()
            lastCondition = condition
            hasVanished = condition.probe == nil
            if let error = startDirectoryStream() {
                failure = error
                isRunning = false
                return
            }
            armDescriptorSource()
        }
        if let failure {
            continuation.yield(.failed(failure))
            continuation.finish()
            throw failure
        }
    }

    /// Stops watching and finishes ``events``. Idempotent.
    public func stop() {
        queue.sync { teardownOnQueue() }
        continuation.finish()
    }

    /// Probes now, bypassing the debounce, and emits if anything differs. For ⌘R, and for
    /// tests that want a deterministic checkpoint rather than a timing one.
    public func poll() {
        queue.async { [weak self] in self?.evaluate() }
    }

    /// The last condition the watcher observed. Diagnostics and tests.
    public var lastObservedCondition: FileCondition? {
        queue.sync { lastCondition }
    }

    // MARK: - Descriptor source

    /// The path FSEvents and `open` should use — symlinks resolved, `..` removed.
    private var resolvedPath: String {
        url.resolvingSymlinksInPath().standardized.path(percentEncoded: false)
    }

    private var watchedDirectory: String {
        url.resolvingSymlinksInPath().standardized.deletingLastPathComponent().path(percentEncoded: false)
    }

    private func armDescriptorSource() {
        dispatchPrecondition(condition: .onQueue(queue))
        descriptorSource?.cancel()
        descriptorSource = nil
        descriptorGeneration &+= 1
        rearmWork?.cancel()
        rearmWork = nil

        guard isRunning else { return }
        let descriptor = open(resolvedPath, O_EVTONLY)
        guard descriptor >= 0 else {
            // Not there yet, or not there any more. FSEvents on the parent will say when that
            // changes; the timer is the belt to its braces, for the events FSEvents coalesces.
            scheduleRearm()
            return
        }

        let generation = descriptorGeneration
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete, .revoke, .funlock],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, descriptorGeneration == generation else { return }
            let mask = descriptorSource?.data ?? []
            // `.rename`, `.delete` and `.revoke` all mean this descriptor now points at an
            // inode nobody can reach. Re-arm on whatever the path resolves to now — this is
            // the line that keeps the watcher alive across an atomic replace.
            if !mask.isDisjoint(with: [.rename, .delete, .revoke]) {
                armDescriptorSource()
            }
            scheduleEvaluation()
        }
        source.setCancelHandler { _ = close(descriptor) }
        descriptorSource = source
        source.resume()
    }

    /// Retries arming while the path cannot be opened, and **probes on every retry**.
    ///
    /// The probe is not optional. Between the file vanishing and the descriptor being armed
    /// again there is no descriptor source at all, so if FSEvents coalesces the create away —
    /// which it is explicitly documented to be allowed to do — nothing else would ever notice
    /// the file came back, and the document would sit in `MISSING` until the user's next
    /// unrelated edit. That is the failure mode this whole class exists to prevent, so the
    /// timer is a poll of last resort rather than only a re-arm.
    private func scheduleRearm() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning, rearmWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            rearmWork = nil
            if descriptorSource == nil { armDescriptorSource() }
            evaluate()
        }
        rearmWork = work
        queue.asyncAfter(deadline: .now() + configuration.rearmInterval.timeInterval, execute: work)
    }

    // MARK: - FSEvents

    /// Retained by the FSEvents stream, holding the watcher weakly, so a callback already in
    /// flight cannot resurrect or outlive the object it points at.
    fileprivate final class CallbackBox {
        weak var watcher: FileWatcher?
        init(_ watcher: FileWatcher) { self.watcher = watcher }
    }

    /// Returns the failure rather than throwing: this runs inside a non-throwing
    /// `queue.sync` closure, where a `do`/`catch` would erase the typed error back to
    /// `any Error` and the caller could no longer put it on the event stream.
    private func startDirectoryStream() -> SheetError? {
        dispatchPrecondition(condition: .onQueue(queue))
        let directory = watchedDirectory
        let unmanaged = Unmanaged.passRetained(CallbackBox(self))

        var context = FSEventStreamContext(
            version: 0,
            info: unmanaged.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            configuration.fsEventsLatency,
            flags
        ) else {
            unmanaged.release()
            return .fileNotReadable(
                path: directory,
                underlying: "the system refused to watch this folder for changes"
            )
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            unmanaged.release()
            return .fileNotReadable(
                path: directory,
                underlying: "the folder change stream could not be started"
            )
        }
        stream = created
        contextBox = unmanaged
        return nil
    }

    /// Called from the C callback, already on `queue`.
    fileprivate func handleDirectoryEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning else { return }
        let target = resolvedPath
        var interesting = false

        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & UInt32(kFSEventStreamEventFlagRootChanged) != 0 {
                // The directory we watch was moved or replaced. Everything we know about the
                // path is stale, so rebuild from scratch.
                interesting = true
                armDescriptorSource()
                continue
            }
            let structural = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
                | UInt32(kFSEventStreamEventFlagUnmount)
                | UInt32(kFSEventStreamEventFlagMount)
            if flag & structural != 0 {
                interesting = true
                continue
            }
            // `path` arrives already resolved (`/tmp` comes back as `/private/tmp`), which is
            // why the comparison is against the resolved form of our own path.
            if path == target || path.hasPrefix(target + "/") { interesting = true }
        }

        guard interesting else { return }
        // An atomic replace repoints the path at a new inode. Whether or not the descriptor
        // source noticed, re-resolving here is free and closes the window where it did not.
        if descriptorSource == nil { armDescriptorSource() }
        scheduleEvaluation()
    }

    // MARK: - Debounce and evaluation

    private func scheduleEvaluation() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning else { return }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            debounceWork = nil
            evaluate()
        }
        debounceWork = work
        let delay = configuration.debounce.timeInterval
        if delay <= 0 {
            queue.async(execute: work)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func probe() -> FileCondition {
        FileProbe.probe(url, headByteCount: configuration.headByteCount)
    }

    private func evaluate() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning else { return }
        let condition = probe()
        guard condition != lastCondition else { return }

        // Stability check: a writer still going produces a file whose size or head hash is
        // different a moment later. Backing off costs 30 ms; not backing off costs a parse
        // failure on a file that was perfectly fine by the time we reported it.
        guard configuration.stabilityInterval > .zero,
              stabilityAttempt < configuration.maximumStabilityRetries
        else {
            stabilityAttempt = 0
            emit(condition)
            return
        }
        let settled = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let again = probe()
            if again == condition {
                stabilityAttempt = 0
                emit(again)
            } else {
                stabilityAttempt += 1
                evaluate()
            }
        }
        queue.asyncAfter(deadline: .now() + configuration.stabilityInterval.timeInterval, execute: settled)
    }

    private func emit(_ condition: FileCondition) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isRunning, condition != lastCondition else { return }
        let previous = lastCondition
        lastCondition = condition

        if let suppressor, suppressor.shouldSuppress(url: url, observed: condition.probe?.fingerprint) {
            // The file genuinely is in this state now, so `lastCondition` above still had to
            // be updated: the next external write must be compared against what we wrote, not
            // against what came before it.
            hasVanished = condition.probe == nil
            return
        }

        switch condition {
        case let .readable(probe):
            if hasVanished {
                hasVanished = false
                continuation.yield(.reappeared(probe))
            } else if let old = previous?.probe, old.fingerprint == probe.fingerprint {
                continuation.yield(.attributesChanged(probe))
            } else {
                continuation.yield(.changed(probe))
            }
        case .missing:
            hasVanished = true
            continuation.yield(.vanished)
        case .volumeUnavailable:
            hasVanished = true
            continuation.yield(.volumeUnavailable)
        case .notDownloaded:
            hasVanished = true
            continuation.yield(.notDownloaded)
        case let .unreadable(error):
            continuation.yield(.unreadable(error))
        }
    }

    // MARK: - Teardown

    private func teardownOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        isRunning = false
        debounceWork?.cancel()
        debounceWork = nil
        rearmWork?.cancel()
        rearmWork = nil
        descriptorSource?.cancel()
        descriptorSource = nil
        descriptorGeneration &+= 1
        if let stream {
            // This exact order, on this exact queue, is the documented way to guarantee no
            // further callbacks: stop, unschedule, invalidate, release.
            FSEventStreamStop(stream)
            FSEventStreamSetDispatchQueue(stream, nil)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        contextBox?.release()
        contextBox = nil
    }
}

// MARK: - FSEvents trampoline

/// The C callback FSEvents demands. Hops straight back onto the watcher, which is already the
/// queue this runs on.
private let fsEventsCallback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
    guard let info else { return }
    let box = Unmanaged<FileWatcher.CallbackBox>.fromOpaque(info).takeUnretainedValue()
    guard let watcher = box.watcher else { return }

    var paths: [String] = []
    if let array = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] { paths = array }
    var flags: [FSEventStreamEventFlags] = []
    flags.reserveCapacity(count)
    for index in 0 ..< count { flags.append(rawFlags[index]) }

    watcher.handleDirectoryEvents(paths: paths, flags: flags)
}

extension Duration {
    /// Seconds as a `Double`, for the `DispatchTime` arithmetic the dispatch API still wants.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
