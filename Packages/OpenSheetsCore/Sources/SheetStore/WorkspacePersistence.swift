import Foundation
import SheetModel

/// The `preference` rows the app writes and the MCP server reads.
///
/// # Why these strings live below both front ends
///
/// The app owns the Files panel and the tab strip; the MCP server has to answer *"what is in the
/// user's OpenSheets right now"* without asking the app, because the app may not be running. Both
/// therefore read the same two rows out of the same SQLite file, and the moment the key or the
/// payload shape is spelled twice, the two halves can disagree — silently, and only on the machine
/// where somebody had actually opened a folder.
///
/// `SheetStore` is the lowest target both of them import, so the strings and the payloads live
/// here and nowhere else. `DocumentCore` consumes these same types (`WorkspaceTreeState` and
/// `TabsModel.PersistedTabs` are typealiases onto them), which is what makes drift a compile
/// error instead of a support ticket.
///
/// One duplicate is left standing on purpose: `App/OpenSheetsApp.swift` spells `"workspace.tabs"`
/// itself, because the App target is the thin SwiftUI layer and editing it to import a constant
/// buys less than it costs. It is one string in one file, and `PersistedOpenTabs.read(from:)`
/// reads what it writes — asserted by ``WorkspacePersistenceTests``.
public enum WorkspacePreferenceKey {
    /// The Files panel: which folders were expanded, and which were pinned as roots.
    ///
    /// Documented as the way to reset the explorer —
    /// `sqlite3 … "DELETE FROM preference WHERE key='workspace.explorer';"` — so it is part of the
    /// contract rather than a detail.
    public static let explorer = "workspace.explorer"

    /// The tab strip: which files were open and which one was in front (PLAN.md §1.7).
    public static let tabs = "workspace.tabs"
}

/// Everything the explorer remembers between launches: which folders were open, and which ones
/// the user had deliberately opened as workspaces.
///
/// # Why it decodes three shapes and writes one
///
/// `workspace.explorer` shipped as a bare JSON array of paths, then as an object with a single
/// `pinnedRoot` beside the expansion set, and now as an object with a `pinnedRoots` list. There
/// are databases holding each of the first two right now — the developer's had `["/tmp/x"]` in it
/// before it had the object. A decoder that only knew the newest shape would read every older row
/// as "nothing expanded, nothing open" on the launch that upgraded it: a preference silently
/// discarded, on the one launch where the user is least likely to connect the two.
///
/// So all three are read and only the newest is written. The array is tried first, then
/// `pinnedRoots`, then `pinnedRoot` — which becomes a one-element list, because one open folder is
/// what that session actually had. Migration runs in the direction it has to and no further; there
/// is no version number, because "list or dictionary, and which key" already answers the only
/// question there is.
///
/// The pins are a key beside the paths rather than marked elements inside them. A sentinel in a
/// list of paths is a path, and a path is something somebody eventually grants.
public struct PersistedWorkspaceTree: Sendable, Equatable, Codable {
    /// Folders that were open, canonical.
    public var expanded: [String]

    /// The folders that were open as workspaces, in the order they were opened. Empty for a
    /// session that never opened one.
    public var pinnedRoots: [String]

    public init(expanded: [String] = [], pinnedRoots: [String] = []) {
        self.expanded = expanded
        self.pinnedRoots = pinnedRoots
    }

    private enum CodingKeys: String, CodingKey {
        case expanded
        case pinnedRoots
        /// The single pin the object form shipped with. Read, never written.
        case pinnedRoot
    }

    public init(from decoder: any Decoder) throws {
        if let legacy = try? [String](from: decoder) {
            expanded = legacy
            pinnedRoots = []
            return
        }
        // `decodeIfPresent` throughout, so an object that is merely *not this* — the shape the
        // corrupt-preference test writes — lands on the same empty state a missing row does.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expanded = try container.decodeIfPresent([String].self, forKey: .expanded) ?? []
        if let roots = try container.decodeIfPresent([String].self, forKey: .pinnedRoots) {
            pinnedRoots = roots
            return
        }
        pinnedRoots = try container.decodeIfPresent(String.self, forKey: .pinnedRoot).map { [$0] } ?? []
    }

    /// Written by hand rather than synthesised, because ``CodingKeys`` carries a case for the
    /// legacy key that no property matches.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(expanded, forKey: .expanded)
        // Omitted rather than written as `[]`, matching what the optional `pinnedRoot` used to
        // encode to: a row for somebody who has never opened a folder should say nothing about
        // folders, since the documented way to inspect this preference is to read it in `sqlite3`.
        guard !pinnedRoots.isEmpty else { return }
        try container.encode(pinnedRoots, forKey: .pinnedRoots)
    }

    /// The stored row, or `nil` for any of the ways there is not one: the read failed, the row does
    /// not exist, or what is in it will not decode.
    ///
    /// Fail-soft on purpose, and this is the property the MCP side depends on. A discovery tool
    /// that errored because a preference row was malformed would tell an agent "your workspace is
    /// broken" when the truth is "the app has not written this yet" — and there is no recovery to
    /// offer either way. The caller substitutes an empty state and says so.
    public static func read(from database: Database) -> PersistedWorkspaceTree? {
        guard let raw = try? database.preference(WorkspacePreferenceKey.explorer),
              let data = raw.data(using: .utf8),
              let state = try? JSONDecoder().decode(PersistedWorkspaceTree.self, from: data)
        else { return nil }
        return state
    }

    /// The exact bytes that go into the row, or `nil` if the encode failed.
    ///
    /// Separate from ``write(to:)`` so the encoder settings can be pinned by a test that does not
    /// need a database: those settings are the whole reason this is not a one-liner.
    public func encodedJSON() -> String? {
        let encoder = JSONEncoder()
        // Sorted keys for the reason the paths themselves are sorted before they get here: the
        // stored text has to be a function of the state and nothing else. Unescaped slashes
        // because the documented way to reset the explorer is to read this row in `sqlite3`, and
        // `["\/Users\/x"]` is a path nobody can grep for.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Writes the row, swallowing failure.
    ///
    /// The precedent is `CheckpointStore.storedID(for:)`, which swallows for the same reason: a
    /// tree that refuses to draw because a preference would not save is worse than a tree that
    /// starts collapsed next launch.
    public func write(to database: Database) {
        guard let text = encodedJSON() else { return }
        try? database.setPreference(WorkspacePreferenceKey.explorer, to: text)
    }
}

/// The tab set as it goes into the `workspace.tabs` preference (PLAN.md §1.7).
///
/// Paths rather than identities: the identity is a *resolved* path, and writing that down would
/// silently rewrite a user's symlinked path into whatever it pointed at on the day they opened
/// it. The tab's own URL is the spelling they gave us.
///
/// Encoded by the App layer with a plain `JSONEncoder` — no sorted keys, slashes escaped — which
/// is why this type has no `write`. Nothing reads these bytes but `JSONDecoder`, so their exact
/// spelling is not a contract the way ``PersistedWorkspaceTree``'s is, and moving the write here
/// would change bytes already sitting in every user's database for no gain.
public struct PersistedOpenTabs: Codable, Sendable, Equatable {
    public var paths: [String]
    public var activeIndex: Int?

    public init(paths: [String] = [], activeIndex: Int? = nil) {
        self.paths = paths
        self.activeIndex = activeIndex
    }

    /// The stored row, or `nil` when there is not one or it will not decode. See
    /// ``PersistedWorkspaceTree/read(from:)`` for why this fails soft.
    ///
    /// An empty `paths` list is returned as-is rather than folded into `nil`: "the app ran and
    /// closed every tab" and "the app has never written this" are different answers, and the tool
    /// reporting them says different things.
    public static func read(from database: Database) -> PersistedOpenTabs? {
        guard let raw = try? database.preference(WorkspacePreferenceKey.tabs),
              let data = raw.data(using: .utf8),
              let tabs = try? JSONDecoder().decode(PersistedOpenTabs.self, from: data)
        else { return nil }
        return tabs
    }
}

/// The file extensions the Files panel lists.
///
/// # Why this is not derived from the reader that owns them
///
/// The panel's set is `DocumentWorkbookReader.workbookExtensions ∪ .delimitedExtensions`, and that
/// type lives in `DocumentCore` — *above* `SheetStore`, and unreachable from `SheetMCP`. Importing
/// it here would invert the dependency graph; re-deriving it would be a second answer to a
/// question that already has one.
///
/// So the set is written down once here and pinned to the reader's by
/// `DocumentCoreTests/WorkspaceParityTests`, which can see both modules. Adding an extension to the
/// reader without adding it here fails that test rather than quietly producing an MCP listing that
/// omits files the user can see in the sidebar. That invariant — *anything visible in the Files
/// panel is reachable by the MCP server* — is the whole point of the discovery tools.
///
/// Note what this is not: the set the document broker can *open*. `WorkbookFormatSupport.readable`
/// is narrower (no `.xltm`, no `.tab`), so two of these list but do not yet read. Listing them
/// anyway and saying so is more honest than a sidebar and a tool that disagree about what exists.
public enum SpreadsheetFileTypes {
    /// Lowercase, without the dot — the form ``DirectoryLister/list(_:fileExtensions:limit:)``
    /// expects.
    public static let listable: Set<String> = [
        "xlsx", "xlsm", "xltx", "xltm",
        "csv", "tsv", "txt", "tab",
    ]
}
