import Foundation
import SheetModel
import SheetStore

/// Where the *before* side of change tracking comes from (PLAN.md §1.3).
///
/// Three sources rather than one because "what has changed" is three different questions
/// depending on who is asking:
///
/// - ``asOpened`` answers *"what has happened while I have been looking at this"*. It costs the
///   user nothing to set up, which is why it is the default: the interesting case for this
///   product is an agent editing a file under an open window, and the window already holds the
///   value the file had when it opened.
/// - ``checkpoint`` answers *"what has happened since I said go"*. Backed by a byte snapshot so
///   it survives relaunch — a baseline that evaporates when the app quits is a baseline nobody
///   sets.
/// - ``gitHEAD`` answers *"what is not committed"*, and is only offered when the file actually
///   resolves inside a work tree.
public enum BaselineSource: Sendable, Equatable {
    /// The workbook this document opened with. The default.
    case asOpened
    /// A point the user marked, backed by a snapshot.
    case checkpoint
    /// The committed bytes of the file, via an injected provider.
    case gitHEAD
}

/// The aggregate the title-bar chip reads: `+12 ~5 −3`.
///
/// Separate from ``WorkbookDiff`` on purpose. The diff is the record of *what* changed and is
/// arbitrarily large; this is the four numbers a chip can hold, and it is what a view should
/// depend on so that a hundred more changed cells do not re-evaluate a body that only ever
/// shows a count.
public struct BaselineCounts: Sendable, Equatable {
    /// Cells that exist now and did not exist at the baseline. Green.
    public var added: Int
    /// Cells whose value or formula moved. Amber.
    public var modified: Int
    /// Cells that existed at the baseline and are gone. Red.
    public var removed: Int
    /// Cells whose *only* difference is formatting. Counted, never tinted — the same reasoning
    /// that keeps the refresh flash off a reformat (`SheetModel/SheetDiff.swift:7-9`).
    public var styleOnly: Int
    /// Whether the numbers are a floor rather than a total: the differ gave up, or a sheet hit
    /// its listing cap. The chip says `500+` rather than pretending to a precision it lost.
    public var isTruncated: Bool

    public init(
        added: Int = 0,
        modified: Int = 0,
        removed: Int = 0,
        styleOnly: Int = 0,
        isTruncated: Bool = false
    ) {
        self.added = added
        self.modified = modified
        self.removed = removed
        self.styleOnly = styleOnly
        self.isTruncated = isTruncated
    }

    /// Nothing has changed — and what ``DocumentModel/baselineCounts`` reports while there is no
    /// diff to report on.
    public static let zero = BaselineCounts()

    /// Whether there is anything worth showing a chip for.
    public var isEmpty: Bool {
        added == 0 && modified == 0 && removed == 0 && styleOnly == 0 && !isTruncated
    }
}

/// How a document tracks changes: whether at all, and where its checkpoint is written down.
///
/// One parameter on ``DocumentModel`` rather than two, because the two travel together and an
/// initialiser that grows a parameter per feature is how initialisers reach nine of them.
public struct ChangeTracking: Sendable {
    /// `OSFlagChangeTracking` (PLAN.md §1.7). **False must cost nothing** — no diffing, no
    /// snapshots, no background tasks — rather than merely hiding the chip.
    public var isEnabled: Bool
    /// Where a checkpoint's identity is persisted. `nil` leaves checkpoints session-scoped,
    /// which is what a document opened without a store gets.
    public var checkpoints: CheckpointStore?

    public init(isEnabled: Bool, checkpoints: CheckpointStore? = nil) {
        self.isEnabled = isEnabled
        self.checkpoints = checkpoints
    }

    /// The flag turned off.
    public static let disabled = ChangeTracking(isEnabled: false)
}

/// The parts of change tracking that are neither on the main actor nor observable: the diff
/// itself, and the arithmetic that turns one into the chip's four numbers.
///
/// Split out of ``DocumentModel`` because both are pure functions of `Sendable` values, and a
/// pure function of `Sendable` values is the only kind of work that can safely leave the main
/// actor. Everything stateful — which baseline, when it was taken, which result is still
/// current — stays on the model, where the generation counters that guard it live.
public enum BaselineTracker {
    /// Diffs the baseline against the current workbook, **off the main actor**.
    ///
    /// `Task.detached` rather than a plain `Task`: a plain one inherits the caller's actor, and
    /// the caller is `@MainActor`, so the whole point — a million-cell comparison that does not
    /// stall the grid — would be lost to a single missing keyword. Both operands are `Workbook`
    /// values, which are copy-on-write and `Sendable`, so nothing is copied to send them.
    ///
    /// `.utility` because this is standing state, not the frame the user is waiting on: the
    /// tints are news about what an agent did, and news that arrives 200 ms late is still news.
    public static func diff(
        baseline: Workbook,
        current: Workbook,
        options: WorkbookDiffer.Options = .default
    ) async -> WorkbookDiff {
        await Task.detached(priority: .utility) {
            WorkbookDiffer(options: options).diff(before: baseline, after: current)
        }.value
    }

    /// The chip's four numbers, from a diff.
    ///
    /// `SheetDiff.changedCount` counts style-only differences along with real ones — see
    /// `ChangeCollector.add` — and there is no aggregate that separates them, only the *listed*
    /// changes. So style-only cells are counted from the list and subtracted, which is exact
    /// until a sheet hits its listing cap and honest afterwards: past the cap the excess lands
    /// in ``BaselineCounts/modified`` and ``BaselineCounts/isTruncated`` is set, which is the
    /// direction that under-claims rather than the one that invents a reformat.
    public static func counts(for diff: WorkbookDiff?) -> BaselineCounts {
        guard let diff else { return .zero }
        var counts = BaselineCounts(isTruncated: diff.wasTruncated)
        for sheet in diff.sheetDiffs {
            let styleOnly = sheet.cellChanges.count { $0.kind == .styleChanged }
            counts.added += sheet.addedCount
            counts.removed += sheet.removedCount
            counts.modified += sheet.changedCount - styleOnly
            counts.styleOnly += styleOnly
            if sheet.omittedCellChangeCount > 0 { counts.isTruncated = true }
        }
        // A sheet that appeared wholesale is every one of its cells added. The differ reports it
        // as a summary rather than as cell changes, and a chip that ignored it would read `+0`
        // next to a grid full of green.
        for sheet in diff.addedSheets { counts.added += sheet.cellCount }
        for sheet in diff.removedSheets { counts.removed += sheet.cellCount }
        return counts
    }
}

/// Where a checkpoint is written down so it outlives the process (PLAN.md §1.7).
///
/// Two halves that have to agree: the bytes live in the ``SheetStore/SnapshotStore`` under a
/// `.checkpoint` reason, and the id of those bytes lives in the `preference` table under
/// `checkpoint:<canonical path>`. Neither is authoritative alone — the snapshot store evicts on
/// a twenty-per-file budget, so a preference can outlive the bytes it names, and this type's
/// job is to notice that and say no rather than to hand back a baseline that is not there.
///
/// A value type over two `Sendable` references, so a document can hand it to a background task
/// without ceremony.
public struct CheckpointStore: Sendable {
    private let database: Database
    private let snapshots: SnapshotStore

    public init(database: Database, snapshots: SnapshotStore) {
        self.database = database
        self.snapshots = snapshots
    }

    /// PLAN.md §1.7's key. The canonical path, so a file reached through a symlink and through
    /// its real path share one checkpoint rather than two — the same identity the model layer
    /// and the snapshot store already use.
    static func key(for url: URL) -> String {
        "checkpoint:" + AppModel.documentKey(for: url)
    }

    /// The checkpoint recorded for `url`, or `nil`.
    func storedID(for url: URL) -> ULID? {
        guard let raw = try? database.preference(CheckpointStore.key(for: url)) else { return nil }
        return ULID(rawValue: raw)
    }

    /// Records — or, with `nil`, forgets — the checkpoint for `url`.
    func store(_ id: ULID?, for url: URL) {
        try? database.setPreference(CheckpointStore.key(for: url), to: id?.rawValue)
    }

    /// The workbook a stored checkpoint's bytes parse to, and when they were taken.
    ///
    /// `nil` covers every way this can fail — no checkpoint recorded, the snapshot evicted
    /// under the per-file cap, a corrupt archive, bytes we can no longer parse because the file
    /// changed format on disk. All of them mean the same thing to the caller (fall back to
    /// ``BaselineSource/asOpened``), and none of them is an error the user caused, so none of
    /// them is worth an alert. A dead reference is cleared on the way past: retrying a parse
    /// that cannot succeed on every launch buys nothing.
    func checkpointBaseline(for url: URL) async -> (workbook: Workbook, takenAt: Date)? {
        guard let id = storedID(for: url) else { return nil }
        guard let data = try? await snapshots.data(for: id, of: url),
              let workbook = await CheckpointStore.parse(data, like: url)
        else {
            store(nil, for: url)
            return nil
        }
        // The ULID *is* the timestamp — 48 bits of it — so the chip's "Since checkpoint · 12:03"
        // needs no second column and cannot disagree with the file it names.
        return (workbook, id.timestamp)
    }

    /// Parses snapshot bytes through the very reader a file goes through.
    ///
    /// Via a temporary file, which looks like a detour and is not: ``DocumentWorkbookReader`` is
    /// URL-based all the way down (the xlsx path memory-maps the package, the CSV path sniffs
    /// the encoding off the file), and giving it a second, data-based entry point would mean two
    /// parse paths that have to stay in step — with the checkpoint one being the one nobody
    /// exercises. A few hundred kilobytes through the temporary directory, once, when a document
    /// opens, is the cheaper half of that trade. The extension is carried over so the reader
    /// makes the same xlsx-or-delimited decision it made for the real file.
    private static func parse(_ data: Data, like url: URL) async -> Workbook? {
        var temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("opensheets-checkpoint-\(UUID().uuidString)")
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
