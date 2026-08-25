import Foundation
@testable import SheetStore
import Testing

/// Whether the machine has the binary ``GitFileVersion`` is hard-coded to use.
///
/// CI has it; a user's Mac without the Command Line Tools does not, and the whole point of
/// this type is that such a Mac is not a failure. So the suite skips rather than fails — which
/// also means these tests never accidentally pass by testing nothing.
private let gitIsInstalled = FileManager.default.isExecutableFile(atPath: "/usr/bin/git")

/// Plan §1.6's subprocess rules, asserted against a real repository this file builds itself.
///
/// Fixtures rather than mocks, because every interesting behaviour here is git's: what
/// `HEAD:<path>` means when the working tree has moved on, what an untracked path does, where
/// `rev-parse` stops walking up. A fake would encode our belief about those and prove nothing.
@Suite(.enabled(if: gitIsInstalled))
struct GitFileVersionTests {
    // MARK: - Finding the repository

    /// Discovery is git's walk up the tree, so it has to work from anywhere inside the repo,
    /// not just from the root.
    @Test func findsTheWorkTreeRootFromAnywhereInside() async throws {
        let repository = Repository("git-root")
        let file = repository.write("a,b\n1,2\n", to: "nested/deep/inner.csv")
        #expect(repository.commit())

        let expected = try PathCanonicalizer.canonicalize(repository.root)
        let fromFile = try #require(await GitFileVersion.repositoryRoot(for: file))
        let fromDirectory = try #require(
            await GitFileVersion.repositoryRoot(for: repository.root.appendingPathComponent("nested"))
        )
        let fromRoot = try #require(await GitFileVersion.repositoryRoot(for: repository.root))

        #expect(try PathCanonicalizer.canonicalize(fromFile) == expected)
        #expect(try PathCanonicalizer.canonicalize(fromDirectory) == expected)
        #expect(try PathCanonicalizer.canonicalize(fromRoot) == expected)
    }

    /// A path with no repository above it is the common case on a Mac, and it must cost
    /// nothing and say nothing.
    @Test func aPathOutsideAnyRepositoryIsNil() async {
        let scratch = TemporaryDirectory("git-none")
        let file = scratch.file("loose.csv", contents: "a,b\n")

        #expect(await GitFileVersion.repositoryRoot(for: file) == nil)
        #expect(await GitFileVersion.headBytes(for: file) == nil)
        #expect(await GitFileVersion.headShortHash(for: file) == nil)
        // Also the fixture's own lifetime: a `nil` because the directory had already been
        // cleaned up would be three passing assertions about nothing.
        #expect(FileManager.default.fileExists(atPath: scratch.url.path(percentEncoded: false)))
    }

    // MARK: - Committed bytes

    /// **The committed bytes, not the ones on disk.** This is the entire product question: an
    /// agent has rewritten the file, and the baseline is what was there before it did.
    @Test func readsTheCommittedBytesRatherThanTheWorkingTreeBytes() async throws {
        let repository = Repository("git-head")
        let committed = Data("a,b\n1,2\n".utf8)
        let file = repository.write(bytes: committed, to: "budget.csv")
        #expect(repository.commit())

        let working = Data("a,b\n99,98\nextra,row\n".utf8)
        try working.write(to: file)

        let head = try #require(await GitFileVersion.headBytes(for: file))
        #expect(head == committed)
        #expect(head != working, "headBytes read the working tree")
    }

    /// The repo-relative path is ours to compute, so a file several directories down is the
    /// case that proves we computed it and did not just pass a file name.
    @Test func readsAFileInASubdirectory() async throws {
        let repository = Repository("git-nested")
        let committed = Data("committed\n".utf8)
        let file = repository.write(bytes: committed, to: "models/quarterly/forecast.csv")
        #expect(repository.commit())
        try Data("changed\n".utf8).write(to: file)

        #expect(await GitFileVersion.headBytes(for: file) == committed)
    }

    /// Bytes, verbatim — NULs, CRLFs and all. A committed workbook is a zip; a version of this
    /// that helpfully normalised line endings would hand the reader a corrupt archive.
    @Test func bytesComeBackVerbatim() async throws {
        let repository = Repository("git-binary")
        let committed = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x0D, 0x0A, 0xFF, 0xFE, 0x00, 0x41])
        let file = repository.write(bytes: committed, to: "book.xlsx")
        #expect(repository.commit())
        try Data("clobbered".utf8).write(to: file)

        #expect(await GitFileVersion.headBytes(for: file) == committed)
    }

    /// A file the agent deleted still has a committed version, and that is precisely when
    /// somebody wants to see it.
    @Test func readsAFileThatIsNoLongerOnDisk() async throws {
        let repository = Repository("git-deleted")
        let committed = Data("still here in HEAD\n".utf8)
        let file = repository.write(bytes: committed, to: "gone.csv")
        #expect(repository.commit())
        try FileManager.default.removeItem(at: file)

        #expect(await GitFileVersion.headBytes(for: file) == committed)
    }

    // MARK: - The absences

    /// Untracked is not an error. It is the answer "there is no committed version", and the
    /// caller turns it into a baseline source it does not offer.
    @Test func anUntrackedFileHasNoCommittedVersion() async {
        let repository = Repository("git-untracked")
        repository.write("tracked\n", to: "tracked.csv")
        #expect(repository.commit())
        let untracked = repository.write("untracked\n", to: "untracked.csv")

        #expect(await GitFileVersion.headBytes(for: untracked) == nil)
        // …and the repository is still found, so the failure is about the file, not the repo.
        #expect(await GitFileVersion.repositoryRoot(for: untracked) != nil)
    }

    /// A repository before its first commit has a work tree but no HEAD.
    @Test func aRepositoryWithoutCommitsHasNoHead() async {
        let repository = Repository("git-empty")
        let file = repository.write("uncommitted\n", to: "data.csv")

        #expect(await GitFileVersion.repositoryRoot(for: file) != nil)
        #expect(await GitFileVersion.headBytes(for: file) == nil)
        #expect(await GitFileVersion.headShortHash(for: file) == nil)
    }

    /// A directory is not a blob. `HEAD:<dir>` prints a tree listing, which is text that looks
    /// enough like a file to be dangerous if it were ever handed to a parser.
    @Test func aDirectoryHasNoCommittedBytes() async {
        let repository = Repository("git-directory")
        repository.write("x\n", to: "sheets/data.csv")
        #expect(repository.commit())

        #expect(await GitFileVersion.headBytes(for: repository.root) == nil)
    }

    // MARK: - The cap

    /// The cap is enforced while reading, so a file past it never fully exists in memory. What
    /// the test can see is the refusal; what it is really asserting is that a 900 MB blob
    /// cannot be materialised by asking for a baseline.
    @Test func aFileLargerThanTheCapIsRefused() async {
        let repository = Repository("git-cap")
        let committed = Data(repeating: 0x41, count: 200_000)
        let file = repository.write(bytes: committed, to: "big.csv")
        #expect(repository.commit())

        #expect(await GitFileVersion.headBytes(for: file, maxBytes: 4) == nil)
        #expect(await GitFileVersion.headBytes(for: file, maxBytes: committed.count - 1) == nil)
        #expect(await GitFileVersion.headBytes(for: file, maxBytes: committed.count)?.count == committed.count)
    }

    /// A cap of zero admits nothing, and a negative cap is a caller bug that must refuse
    /// rather than wrap around into "unlimited".
    @Test(arguments: [0, -1, Int.min])
    func aCapOfZeroOrLessAdmitsNothing(maxBytes: Int) async {
        let repository = Repository("git-cap-zero")
        let file = repository.write("a,b\n", to: "small.csv")
        #expect(repository.commit())

        #expect(await GitFileVersion.headBytes(for: file, maxBytes: maxBytes) == nil)
    }

    // MARK: - The hash

    /// The short hash goes into a label the user reads, so it is validated as hex and checked
    /// against the real HEAD rather than merely being non-empty.
    @Test func theShortHashAbbreviatesHead() async throws {
        let repository = Repository("git-hash")
        let file = repository.write("a,b\n", to: "data.csv")
        #expect(repository.commit())

        let short = try #require(await GitFileVersion.headShortHash(for: file))
        #expect(short.count >= 7)
        #expect(short.allSatisfy { $0.isASCII && $0.isHexDigit })

        let full = try #require(Git.output(["rev-parse", "HEAD"], in: repository.root))
        #expect(full.hasPrefix(short))
    }

    // MARK: - Relative paths

    /// The path arithmetic on its own, including the two ways it must refuse: a file beside
    /// the repository rather than inside it, and a sibling directory whose name merely starts
    /// with the root's.
    @Test func repositoryRelativePathsAreComputedByComponent() {
        let scratch = TemporaryDirectory("git-relative")
        let root = scratch.directory("repo")
        _ = scratch.directory("repo/models")

        #expect(GitFileVersion.repositoryRelativePath(
            of: root.appendingPathComponent("budget.csv"),
            in: root
        ) == "budget.csv")
        #expect(GitFileVersion.repositoryRelativePath(
            of: root.appendingPathComponent("models/forecast.csv"),
            in: root
        ) == "models/forecast.csv")

        let neighbour = scratch.directory("repo-backup")
        #expect(GitFileVersion.repositoryRelativePath(
            of: neighbour.appendingPathComponent("budget.csv"),
            in: root
        ) == nil, "a sibling whose name starts with the root's is not inside it")
        #expect(GitFileVersion.repositoryRelativePath(of: root, in: root) == nil)
    }

    // MARK: - The deadline

    /// **A command that overstays is killed, and says so.** A repository on a network mount
    /// that has gone away will make `git` sit there forever; switching a baseline is a click
    /// in the title bar, and it may fail but it may not hang.
    ///
    /// Asserted against `/bin/sleep` rather than `git`, with a deadline in the milliseconds:
    /// the production ten seconds is a product judgement, but the machinery underneath it is
    /// what needs proving, and it cannot be proved by waiting ten seconds for a git that
    /// cooperates.
    @Test func aProcessThatOverstaysItsDeadlineIsKilled() throws {
        let process = try #require(sleepingProcess(seconds: "30"))
        let watchdog = ProcessWatchdog(process, killingAfter: 0.2)

        process.waitUntilExit()
        watchdog.disarm()

        #expect(watchdog.didTimeOut)
        #expect(process.terminationReason == .uncaughtSignal, "the deadline did not end the process")
        #expect(!process.isRunning)
    }

    /// The other half: a process that finishes in time is not reported as timed out, and
    /// disarming means nothing signals it afterwards.
    @Test func aProcessThatFinishesInTimeIsNotMarkedTimedOut() throws {
        let process = try #require(sleepingProcess(seconds: "0"))
        let watchdog = ProcessWatchdog(process, killingAfter: 30)

        process.waitUntilExit()
        watchdog.disarm()

        #expect(!watchdog.didTimeOut)
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 0)

        // Disarmed: a late fire must find nothing to signal rather than a recycled pid.
        watchdog.terminateIfRunning(timedOut: true)
        #expect(!watchdog.didTimeOut)
    }

    private func sleepingProcess(seconds: String) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        return process
    }

    // MARK: - Housekeeping

    /// Every fixture is a fresh UUID directory that removes itself, so a run leaves nothing in
    /// `/tmp` — including the read-only object files a repository is mostly made of.
    @Test func aFixtureRepositoryRemovesItself() {
        let path: String
        do {
            let repository = Repository("git-cleanup")
            repository.write("a,b\n", to: "data.csv")
            #expect(repository.commit())
            path = repository.root.path(percentEncoded: false)
            #expect(FileManager.default.fileExists(atPath: repository.root.path(percentEncoded: false)))
        }
        #expect(!FileManager.default.fileExists(atPath: path), "the fixture left \(path) behind")
    }
}

// MARK: - Fixtures

/// A throwaway git repository in a fresh temporary directory.
private struct Repository {
    let scratch: TemporaryDirectory

    var root: URL {
        scratch.url
    }

    init(_ name: String) {
        scratch = TemporaryDirectory(name)
        Git.run(["init", "-q", "."], in: scratch.url)
    }

    @discardableResult
    func write(_ contents: String, to relativePath: String) -> URL {
        write(bytes: Data(contents.utf8), to: relativePath)
    }

    @discardableResult
    func write(bytes: Data, to relativePath: String) -> URL {
        let target = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? bytes.write(to: target)
        return target
    }

    func commit(_ message: String = "fixture") -> Bool {
        Git.run(["add", "-A", "."], in: root) == 0
            && Git.run(["commit", "-q", "--no-verify", "-m", message], in: root) == 0
    }
}

/// Runs the same binary the implementation does, with a fixed argument array.
///
/// The `-c` prefix pins every setting that a developer's global config could otherwise use to
/// break these tests on their machine and nowhere else: an identity to commit as, no signing,
/// no global excludes hiding the fixture files, and no line-ending translation to argue with
/// ``GitFileVersionTests/bytesComeBackVerbatim()``.
private enum Git {
    static let settings = [
        "-c", "user.name=OpenSheets Tests",
        "-c", "user.email=tests@opensheets.invalid",
        "-c", "commit.gpgsign=false",
        "-c", "core.excludesFile=/dev/null",
        "-c", "core.autocrlf=false",
        "-c", "init.defaultBranch=main",
    ]

    @discardableResult
    static func run(_ arguments: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = GitFileVersion.executableURL
        process.arguments = settings + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Trimmed stdout of a command expected to print one short line, or `nil`.
    static func output(_ arguments: [String], in directory: URL) -> String? {
        let process = Process()
        process.executableURL = GitFileVersion.executableURL
        process.arguments = settings + arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
