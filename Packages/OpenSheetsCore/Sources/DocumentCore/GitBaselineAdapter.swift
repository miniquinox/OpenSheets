import Foundation
import SheetModel
import SheetStore

/// Makes ``BaselineSource/gitHEAD`` real: the bridge from ``SheetStore/GitFileVersion``'s bytes
/// to the ``SheetModel/Workbook`` a document diffs against.
///
/// # Why the model does not do this itself
///
/// ``DocumentModel`` declares ``DocumentModel/gitBaselineProvider`` and knows nothing about git,
/// on purpose. `DocumentCore` describes a document; running a subprocess is a capability, and a
/// capability that a model *contains* is one no test can take away. Injected, the whole git path
/// is dormant until somebody installs it, which is exactly what the wave-1 package shipped.
///
/// # Security posture (PLAN.md §1.6)
///
/// Nothing here widens what git is asked. ``SheetStore/GitFileVersion`` runs `/usr/bin/git` with
/// fixed argument arrays and no shell; the only URL that ever reaches it is an open document's
/// own, which has already passed ``AppModel``'s workspace-grant check — this adapter is only
/// reachable from a document that exists. What comes back is bytes, and the bytes go through the
/// same hardened reader a file on disk goes through, caps and all. Every failure is `nil`: no
/// `git`, no repository, an untracked file, a byte cap, an unparseable blob. A baseline source
/// that is quietly not offered beats an alert about a subprocess.
public enum GitBaselineAdapter {
    /// Installs the git provider on `model`.
    ///
    /// One line, and that is the whole contract. Setting
    /// ``DocumentModel/gitBaselineProvider`` fires the model's own availability probe from its
    /// `didSet` — the probe calls this provider once, keeps the workbook it gets back so the
    /// first switch to git costs nothing, and sets `isGitBaselineAvailable` itself. Callers must
    /// not try to set that flag: it is `private(set)`, and it is `private(set)` because a shell
    /// that could claim availability could claim it wrongly.
    ///
    /// Call it once, on the tab-ready path. Installing again re-probes, which is a second
    /// `git show` and a second parse for an answer that has not changed.
    ///
    /// Cheap for a document that is not in a repository: the provider asks
    /// `git rev-parse --show-toplevel` first and gives up there.
    @MainActor
    public static func install(on model: DocumentModel) {
        model.gitBaselineProvider = provider()
    }

    /// The closure ``DocumentModel/gitBaselineProvider`` wants, for a shell that would rather
    /// hold it than install it — or a test that wants to call it directly.
    public static func provider() -> @Sendable (URL) async -> Workbook? {
        { url in await committedWorkbook(for: url) }
    }

    /// The workbook `url` had at `HEAD`, or `nil`.
    public static func committedWorkbook(for url: URL) async -> Workbook? {
        guard let bytes = await GitFileVersion.headBytes(for: url) else { return nil }
        return await parse(bytes, like: url)
    }

    /// Whether offering ``BaselineSource/gitHEAD`` for `url` is worth the ask.
    ///
    /// The cheap half of the question — is this file inside a work tree at all — costing one
    /// `rev-parse` rather than a `git show` and a workbook parse. It answers `true` for a file
    /// that is inside a repository and untracked, where ``committedWorkbook(for:)`` will still
    /// come back `nil`; that is the intended split. A shell can use this to skip installing a
    /// provider for the many documents that live nowhere near a repository, and the model's own
    /// probe — which runs the real thing — remains the authority on whether the source appears.
    public static func probeAvailability(for url: URL) async -> Bool {
        await GitFileVersion.repositoryRoot(for: url) != nil
    }

    /// Parses committed bytes through the very reader a file goes through.
    ///
    /// Via a temporary file, for the same reason ``CheckpointStore`` does it: `DocumentWorkbookReader`
    /// is URL-based all the way down — the xlsx path memory-maps the package, the delimited path
    /// sniffs the encoding off the file — and a second, data-based entry point would mean two
    /// parse paths to keep in step, with this one being the path nobody exercises. The extension
    /// is carried over so the reader makes the same xlsx-or-delimited decision it made for the
    /// real file.
    ///
    /// Deliberately duplicated rather than shared with ``CheckpointStore``'s copy: that one is
    /// `private` inside another task's file, and a dozen lines of temporary-file handling is a
    /// cheaper thing to repeat than a cross-file seam is to negotiate mid-wave.
    private static func parse(_ data: Data, like url: URL) async -> Workbook? {
        var temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-git-baseline-\(UUID().uuidString)")
        if !url.pathExtension.isEmpty {
            temporary = temporary.appendingPathExtension(url.pathExtension)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try data.write(to: temporary, options: .atomic)
        } catch {
            return nil
        }
        return try? await DocumentWorkbookReader.read(temporary)
    }
}
