import Foundation

/// Reads the committed version of a file out of a git work tree, without linking libgit2:
/// `git` is invoked as a subprocess.
///
/// This exists for one product question — "what did this file look like before the agent
/// touched it?" — and the answer is worth having only if asking is free. So **everything
/// degrades to `nil`**: no git binary, not a repository, the file untracked, a non-zero exit,
/// a file past the byte cap, a hung command. None of it throws, none of it logs, and none of
/// it reaches the user; the caller simply does not offer "Since last git commit" as a
/// baseline. A feature that is quietly absent is better than one that puts a subprocess
/// failure in front of somebody editing a spreadsheet.
///
/// # Why `/usr/bin/git` and never `PATH`
///
/// `Process.executableURL` is set to the literal path `/usr/bin/git` and the search path is
/// never consulted. That is a security posture, not a convenience (plan §1.6): `PATH` is
/// attacker-influenced in a way the app cannot audit — a `git` earlier in it, dropped in by
/// anything that ever ran in this user's session, would be executed with the app's privileges
/// against the user's documents. `/usr/bin/git` is the shim Apple ships; if the Command Line
/// Tools are not installed the launch fails, which is exactly the `nil` this type promises.
///
/// The same posture runs through the rest of it: every invocation is a **fixed argument
/// array** — no shell, no interpolation into a command line, so a path cannot become an
/// option or a second command. Only the repo-relative path varies, and it varies as one
/// argument (`HEAD:<relpath>`). What comes back is **bytes, never code**: it is handed to the
/// same hardened workbook readers a file on disk goes through.
///
/// # Concurrency
///
/// Every entry point is `async` and does its work inside a detached task, because `Process`
/// blocks the thread that runs it and none of this may happen on the main actor. `Process` is
/// not `Sendable` and is never shared: one invocation owns its process for that process's
/// whole life, and the only thing that crosses a thread boundary is the watchdog
/// (``ProcessWatchdog``) that may have to kill it.
///
/// stdout is read to EOF **before** `waitUntilExit()`. The other order deadlocks the moment
/// git writes more than a pipe buffer: the parent waits for a child that is blocked writing
/// to a pipe nobody is draining. It is the classic subprocess bug and it only shows up on
/// large files, which is to say on the user's machine and not in a test.
public enum GitFileVersion {
    /// The repo work-tree root containing `url`, or `nil`.
    ///
    /// `git rev-parse --show-toplevel`, run with `url`'s directory as the working directory,
    /// so discovery is git's own walk up the tree and not ours. The path it returns has
    /// symlinks resolved (it is the kernel's `getcwd`), which is why callers comparing it to a
    /// URL they built themselves should canonicalise first — `/var/folders/…` and
    /// `/private/var/folders/…` are the same directory and spell it differently.
    public static func repositoryRoot(for url: URL) async -> URL? {
        guard let output = await text(["rev-parse", "--show-toplevel"], for: url) else { return nil }
        guard output.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: output, isDirectory: true)
    }

    /// The bytes of `url` at HEAD, or `nil`.
    ///
    /// `git show HEAD:<relpath>`, with the path computed from ``repositoryRoot(for:)`` rather
    /// than trusted from the caller. `--no-textconv` keeps a configured diff filter from
    /// turning a workbook into its human-readable rendering: the caller wants the committed
    /// bytes, byte for byte, because it is about to parse them.
    ///
    /// - Parameter maxBytes: refused past this, and refused **while reading** rather than
    ///   after — the point of a cap is that the bytes never all exist at once. Defaults to
    ///   256 MB, the same ceiling as `SnapshotStore.Configuration.maximumFileBytes`, so a
    ///   workbook too large to snapshot is also too large to baseline against. A cap of zero
    ///   or less admits nothing and returns `nil` without launching anything.
    public static func headBytes(for url: URL, maxBytes: Int = 256 * 1024 * 1024) async -> Data? {
        guard maxBytes > 0 else { return nil }
        guard let root = await repositoryRoot(for: url) else { return nil }
        guard let relativePath = repositoryRelativePath(of: url, in: root) else { return nil }
        return await run(["show", "--no-textconv", "HEAD:\(relativePath)"], in: root, maxBytes: maxBytes)
    }

    /// Short HEAD hash for labels ("a1b2c3d"), or `nil`.
    ///
    /// Validated as hex before it is returned. It goes into a string the user reads, and the
    /// one thing that must never happen is a chip captioned with whatever a subprocess
    /// happened to print.
    public static func headShortHash(for url: URL) async -> String? {
        guard let output = await text(["rev-parse", "--short", "HEAD"], for: url) else { return nil }
        guard (4 ... 40).contains(output.count) else { return nil }
        guard output.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return output
    }

    // MARK: - Locating git

    /// See the type's doc comment: the literal path, never a `PATH` lookup.
    static let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    /// How long a single invocation may take before it is killed and the answer is `nil`.
    ///
    /// A repository on a network filesystem that has gone away will make `git` sit there, and
    /// a baseline switch is a click in the title bar: it may fail, but it may not hang. Ten
    /// seconds is far longer than a local `git show` ever needs and short enough that a stuck
    /// one is over before the user has finished wondering.
    static let timeout: TimeInterval = 10

    /// Output larger than this from a command whose answer is a path or a hash is not an
    /// answer. Caps `rev-parse`, never ``headBytes(for:maxBytes:)``.
    private static let maximumTextBytes = 64 * 1024

    private static let readChunkBytes = 64 * 1024

    // MARK: - Repository-relative paths

    /// `url` expressed relative to `root`, the form `git show HEAD:…` wants.
    ///
    /// The directory half is canonicalised and the **last component is kept verbatim**, which
    /// is the only ordering that works: git records the name of a symlink, not the name of
    /// what it points at, so resolving the whole path would ask for the wrong blob. Comparison
    /// is by path components rather than by string prefix — `/repo-backup` is not inside
    /// `/repo` — and it follows the volume's own case rule instead of lowercasing, because on
    /// a case-sensitive volume `Data` and `data` are two different files.
    static func repositoryRelativePath(of url: URL, in root: URL) -> String? {
        let name = url.lastPathComponent.precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return nil }
        guard let parent = try? PathCanonicalizer.canonicalize(url.deletingLastPathComponent()),
              let rootPath = try? PathCanonicalizer.canonicalize(root)
        else { return nil }

        let rootComponents = PathCanonicalizer.components(rootPath)
        let parentComponents = PathCanonicalizer.components(parent)
        let caseInsensitive = !PathCanonicalizer.volumeIsCaseSensitive(rootPath)
        guard PathCanonicalizer.contains(
            container: rootComponents,
            path: parentComponents,
            caseInsensitive: caseInsensitive
        ) else { return nil }

        return (parentComponents.dropFirst(rootComponents.count) + [name]).joined(separator: "/")
    }

    // MARK: - Running git

    /// A command whose answer is a short line of text: decoded strictly as UTF-8, trimmed,
    /// and `nil` when empty. Strictly, because a path that is not valid UTF-8 is a path we
    /// cannot hand back to git as an argument — plan §1.8 says that is a `nil`, not a guess.
    private static func text(_ arguments: [String], for url: URL) async -> String? {
        guard let data = await run(arguments, in: workingDirectory(for: url), maxBytes: maximumTextBytes),
              let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The directory a command runs in: `url` itself when it is one, else its parent. A
    /// directory that does not exist makes the launch fail, which is the `nil` we want.
    private static func workingDirectory(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    /// Runs one invocation off the current executor and hands back its stdout, or `nil`.
    private static func run(_ arguments: [String], in directory: URL, maxBytes: Int) async -> Data? {
        guard maxBytes > 0 else { return nil }
        let task = Task.detached(priority: .utility) {
            GitFileVersion.runBlocking(arguments, in: directory, maxBytes: maxBytes)
        }
        // Detached rather than merely `nonisolated`, so this is off the main actor whatever
        // the caller's isolation and whatever a future language mode does to inheritance.
        // Cancelling the caller does not cut the invocation short; the watchdog bounds it
        // instead, which is why the bound is seconds and not minutes.
        return await task.value
    }

    /// The blocking half. Owns its `Process` from `run()` to the last `waitUntilExit()`.
    private static func runBlocking(_ arguments: [String], in directory: URL, maxBytes: Int) -> Data? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment()
        process.qualityOfService = .utility

        let output = Pipe()
        process.standardOutput = output
        // stderr is discarded on purpose: `fatal: path … does not exist in 'HEAD'` is the
        // normal answer for an untracked file, not news. stdin is /dev/null so nothing git
        // decides to ask about can ever block on a terminal that is not there.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            // No Command Line Tools, no such directory, no permission to execute.
            return nil
        }

        let watchdog = ProcessWatchdog(process, killingAfter: timeout)
        let reader = output.fileHandleForReading
        var data = Data()
        var refused = false

        while true {
            let chunk: Data?
            do {
                chunk = try reader.read(upToCount: readChunkBytes)
            } catch {
                refused = true
                break
            }
            guard let chunk, !chunk.isEmpty else { break }
            guard data.count + chunk.count <= maxBytes else {
                refused = true
                break
            }
            data.append(chunk)
        }

        // Order matters when the cap was hit: kill first so git stops producing, then close
        // the read end so a git already blocked writing into a full pipe gets EPIPE and
        // exits, then reap. Skipping either step leaves a process behind.
        if refused {
            watchdog.terminateIfRunning(timedOut: false)
        }
        try? reader.close()
        process.waitUntilExit()
        watchdog.disarm()

        guard !refused, !watchdog.didTimeOut else { return nil }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return data
    }

    /// The child's environment: the process's own, minus everything that could point git at a
    /// different repository than the one on disk.
    ///
    /// Inherited rather than emptied, because `/usr/bin/git` is a shim that needs a working
    /// environment to find the real binary. So the redirecting variables are removed by name
    /// instead — a stray `GIT_DIR` in the app's environment would otherwise silently answer
    /// every question about every document from one unrelated repository.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in redirectingVariables {
            environment.removeValue(forKey: key)
        }
        // Never prompt for credentials, never take a lock (these are read-only questions and
        // must not write an index), never start a pager. Each of the three is a way to hang.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_PAGER"] = "cat"
        return environment
    }

    private static let redirectingVariables = [
        "GIT_DIR",
        "GIT_WORK_TREE",
        "GIT_COMMON_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_CEILING_DIRECTORIES",
        "GIT_NAMESPACE",
        "GIT_PREFIX",
        "GIT_CONFIG",
    ]
}

// MARK: - Watchdog

/// Kills one `Process` if it outlives its deadline.
///
/// `@unchecked Sendable` for the usual honest reason: this is the one object two threads
/// touch — the thread draining stdout and the timer that may have to end the process it is
/// draining — and every access to the process goes through the lock, so the guarantee is real
/// even though the compiler cannot see it. `Process` itself never escapes.
///
/// `isRunning` is checked under the same lock, so `terminate()` is only ever sent to a process
/// that has not been reaped. Signalling a reaped process would at best be pointless and at
/// worst find a recycled pid.
///
/// Internal rather than private so `GitFileVersionTests` can point it at a process that
/// deliberately overstays. A real `git` cannot be made to hang on demand, and this is the one
/// path here where being wrong wedges the caller instead of returning `nil`.
final class ProcessWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var timer: DispatchWorkItem?
    private var timedOut = false

    init(_ process: Process, killingAfter seconds: TimeInterval) {
        self.process = process
        let timer = DispatchWorkItem { [weak self] in
            self?.terminateIfRunning(timedOut: true)
        }
        self.timer = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    /// Whether the deadline, rather than git, ended the process.
    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func terminateIfRunning(timedOut: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return }
        if timedOut {
            self.timedOut = true
        }
        process.terminate()
    }

    /// The process has been reaped. Nothing may signal it after this.
    func disarm() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
        process = nil
    }
}
