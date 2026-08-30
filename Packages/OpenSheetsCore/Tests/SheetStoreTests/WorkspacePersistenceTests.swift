import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// **The two preference rows the app writes and the server reads, pinned to their bytes.**
///
/// These payloads used to live in `DocumentCore`, where only the app could see them. They moved
/// here so `SheetMCP` can answer "what is in the user's Files panel" with the app closed — and the
/// move is only safe if the decoder still reads every shape sitting in somebody's database today.
/// So the historical spellings are written down as literals rather than produced by the encoder: a
/// golden string cannot drift with the type it is checking.
///
/// `.serialized` because half the cases open a real SQLite file. The pure decoding cases could run
/// without one, but splitting the suite would put the round trip and the shapes it has to survive
/// in two different places.
@Suite("Workspace preferences — the shapes on disk", .serialized)
struct WorkspacePersistenceTests {
    /// A database in a directory that deletes itself. Both halves are kept, following
    /// ``DatabaseTests``: the scratch directory has to outlive the connection.
    private struct Fixture {
        var scratch: TemporaryDirectory
        var database: Database
    }

    private func makeFixture() throws -> Fixture {
        let scratch = TemporaryDirectory("workspace-preferences")
        let database = try Database(url: scratch.url.appendingPathComponent("OpenSheets.sqlite"))
        return Fixture(scratch: scratch, database: database)
    }

    // MARK: - The explorer row, in all three spellings it has ever had

    /// Every shape `workspace.explorer` has ever held still decodes, and the two that carry a pin
    /// agree about which folder it is.
    ///
    /// The bare array predates pins entirely, so "no folder open" is the true answer for it rather
    /// than a decode that gave up — which is why it is asserted separately instead of being folded
    /// into the same expectation.
    @Test func everyShapeThePreferenceEverHadStillDecodes() throws {
        let bareArray = #"["/x"]"#
        let singlePin = #"{"expanded":["/x"],"pinnedRoot":"/x"}"#
        let pinList = #"{"expanded":["/x"],"pinnedRoots":["/x"]}"#

        let decoded = try [bareArray, singlePin, pinList].map { json in
            try JSONDecoder().decode(PersistedWorkspaceTree.self, from: Data(json.utf8))
        }

        #expect(decoded.map(\.expanded) == [["/x"], ["/x"], ["/x"]], "all three carry the expansion set")
        #expect(
            decoded[1].pinnedRoots == decoded[2].pinnedRoots,
            "the single pin and the pin list name the same open folder"
        )
        #expect(decoded[1].pinnedRoots == ["/x"])
        #expect(decoded[0].pinnedRoots.isEmpty, "the array shipped before pins existed; it has none to report")
    }

    /// A shape that is an object but not *this* object reads as an empty state rather than
    /// throwing — the same answer a missing row gives.
    @Test func anUnrecognisedObjectReadsAsAnEmptyState() throws {
        let decoded = try JSONDecoder().decode(
            PersistedWorkspaceTree.self,
            from: Data(#"{"somethingElse":true}"#.utf8)
        )
        #expect(decoded == PersistedWorkspaceTree())
    }

    /// Only the newest shape is written, with sorted keys and unescaped slashes — because the
    /// documented way to inspect this row is to read it in `sqlite3`, and `["\/Users\/x"]` is a
    /// path nobody can grep for.
    @Test func onlyTheNewestShapeIsWrittenAndItIsGreppable() {
        let state = PersistedWorkspaceTree(expanded: ["/Users/x"], pinnedRoots: ["/Users/x"])
        #expect(state.encodedJSON() == #"{"expanded":["/Users/x"],"pinnedRoots":["/Users/x"]}"#)

        // A session that never opened a folder says nothing about folders rather than writing an
        // empty list — matching what the optional `pinnedRoot` used to encode to.
        #expect(PersistedWorkspaceTree(expanded: ["/tmp/x"]).encodedJSON() == #"{"expanded":["/tmp/x"]}"#)
    }

    /// The row is read from, and written to, the key the rollback instructions name.
    @Test func theExplorerRowUsesTheDocumentedKey() throws {
        #expect(WorkspacePreferenceKey.explorer == "workspace.explorer")

        let fixture = try makeFixture()
        let state = PersistedWorkspaceTree(expanded: ["/Users/x"], pinnedRoots: ["/Users/x"])
        state.write(to: fixture.database)

        let raw = try fixture.database.preference("workspace.explorer")
        #expect(raw == state.encodedJSON())
        #expect(PersistedWorkspaceTree.read(from: fixture.database) == state)
    }

    /// A legacy row survives the trip through the reader unchanged, and the next write upgrades it.
    ///
    /// The migration is the load-bearing half: a database holding the bare array must come back
    /// with its expansion set, not with the empty state a strict decoder would produce — on the one
    /// launch where nobody would connect the reset to the upgrade that caused it.
    @Test func aLegacyRowIsReadThenUpgradedInPlace() throws {
        let fixture = try makeFixture()
        try fixture.database.setPreference(WorkspacePreferenceKey.explorer, to: #"["/tmp/x"]"#)

        let restored = try #require(PersistedWorkspaceTree.read(from: fixture.database))
        #expect(restored == PersistedWorkspaceTree(expanded: ["/tmp/x"], pinnedRoots: []))

        restored.write(to: fixture.database)
        let raw = try fixture.database.preference(WorkspacePreferenceKey.explorer)
        #expect(raw == #"{"expanded":["/tmp/x"]}"#)
    }

    /// Neither an absent row nor a corrupt one is an error. A discovery tool that failed because a
    /// preference would not parse would tell an agent the workspace is broken when the truth is
    /// that the app has not written this yet — and there is no recovery to offer either way.
    @Test func anAbsentOrCorruptRowIsNilRatherThanAThrow() throws {
        let fixture = try makeFixture()
        #expect(PersistedWorkspaceTree.read(from: fixture.database) == nil)
        #expect(PersistedOpenTabs.read(from: fixture.database) == nil)

        try fixture.database.setPreference(WorkspacePreferenceKey.explorer, to: "{ not json")
        try fixture.database.setPreference(WorkspacePreferenceKey.tabs, to: "{ not json")
        #expect(PersistedWorkspaceTree.read(from: fixture.database) == nil)
        #expect(PersistedOpenTabs.read(from: fixture.database) == nil)
    }

    // MARK: - The tabs row

    /// The server reads what the app writes, byte for byte — including the app's plain
    /// `JSONEncoder`, which sorts nothing and escapes its slashes.
    ///
    /// Encoded with that encoder on purpose: `App/OpenSheetsApp.swift` writes this row and is not
    /// this module's to change, so the case has to prove the reader copes with *its* output rather
    /// than with output produced here.
    @Test func theTabsRowIsReadExactlyAsTheAppWroteIt() throws {
        let fixture = try makeFixture()
        let tabs = PersistedOpenTabs(paths: ["/files/budget.xlsx", "/files/plan.csv"], activeIndex: 1)
        let encoded = try JSONEncoder().encode(tabs)
        let json = try #require(String(data: encoded, encoding: .utf8))
        try fixture.database.setPreference(WorkspacePreferenceKey.tabs, to: json)

        #expect(WorkspacePreferenceKey.tabs == "workspace.tabs")
        #expect(json.contains(#"\/files\/budget.xlsx"#), "the app's encoder escapes slashes; the reader must cope")
        #expect(PersistedOpenTabs.read(from: fixture.database) == tabs)
    }

    /// No active tab is a real state, not a missing one: a workspace can hold open files with none
    /// in front while a window is being restored.
    @Test func anAbsentActiveIndexSurvivesTheRoundTrip() throws {
        let tabs = PersistedOpenTabs(paths: ["/files/budget.xlsx"], activeIndex: nil)
        let encoded = try JSONEncoder().encode(tabs)
        #expect(try JSONDecoder().decode(PersistedOpenTabs.self, from: encoded) == tabs)
    }

    /// "The app ran and closed every tab" and "the app has never written this" are different
    /// answers, so an empty tab list comes back as itself rather than as `nil`.
    @Test func anEmptyTabListIsAnAnswerAndNotAnAbsence() throws {
        let fixture = try makeFixture()
        let encoded = try JSONEncoder().encode(PersistedOpenTabs())
        let json = try #require(String(data: encoded, encoding: .utf8))
        try fixture.database.setPreference(WorkspacePreferenceKey.tabs, to: json)

        let read = try #require(PersistedOpenTabs.read(from: fixture.database))
        #expect(read.paths.isEmpty)
        #expect(read.activeIndex == nil)
    }

    // MARK: - The extension set

    /// The listable set is spelled the way the lister compares it: lowercase, no dot. That it
    /// *equals* the Files panel's set is `DocumentCoreTests/WorkspaceParityTests`' job — this case
    /// only guards the spelling, which is what a filter matches against.
    @Test func theListableExtensionsAreSpelledTheWayTheListerComparesThem() {
        #expect(SpreadsheetFileTypes.listable.count == 8)
        for name in SpreadsheetFileTypes.listable {
            #expect(name == name.lowercased(), "\(name) is not lowercase")
            #expect(!name.hasPrefix("."), "\(name) carries a dot the lister never sees")
        }
    }
}
