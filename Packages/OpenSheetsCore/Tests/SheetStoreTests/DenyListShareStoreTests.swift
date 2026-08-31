import Foundation
import SheetModel
@testable import SheetStore
import Testing

/// The OpenSheets store directory is denied to the tools.
///
/// Cloud Share keeps each link's full capability URL in plaintext, because Copy has to work
/// months after the token stopped being derivable from its hash. That trade is only sound if an
/// agent holding a broad grant cannot read the file those URLs are in — so the store directory
/// joins ``DenyList/standard``, alongside the snapshots and the database it sits with, and this
/// suite is the proof. An agent that could read its own leash could hand it to the next one.
///
/// Written as a new file on purpose: the three pinned deny suites
/// (`WorkspaceGrantsTests.escapeSuiteFindsNoEscapes`, `GrantEscapeTests`,
/// `ShippedBinaryTests`) pin the boundary as it stood, and a change that narrows the boundary
/// has no business editing the tests that prove it did not widen.
@Suite struct DenyListShareStoreTests {
    private var home: String { NSHomeDirectory() }

    private func grantsOverLibrary() throws -> WorkspaceGrants {
        let grants = WorkspaceGrants(mode: .app, storage: nil, denyList: .standard)
        try grants.grant(UserGrantAuthorization(unchecked: URL(fileURLWithPath: "\(home)/Library")))
        return grants
    }

    /// The claim, in the form it will be relied on: `~/Library` is a folder somebody will grant,
    /// and granting it must not hand over the share links.
    ///
    /// Every spelling is here because each fails differently — the bare directory, a file that
    /// exists, a file nested below one that does not exist yet, the unexpanded tilde, and the
    /// wrong case on a case-insensitive boot volume.
    @Test func aGrantOfLibraryStillCannotReachTheOpenSheetsStore() throws {
        let grants = try grantsOverLibrary()

        let denied = [
            ("the store directory itself", "\(home)/Library/Application Support/OpenSheets"),
            ("the database", "\(home)/Library/Application Support/OpenSheets/OpenSheets.sqlite"),
            ("the WAL beside it", "\(home)/Library/Application Support/OpenSheets/OpenSheets.sqlite-wal"),
            ("a snapshot blob", "\(home)/Library/Application Support/OpenSheets/Snapshots/deep/01H.gz"),
            ("a path that does not exist yet", "\(home)/Library/Application Support/OpenSheets/new/file.csv"),
            ("the unexpanded tilde", "~/Library/Application Support/OpenSheets/OpenSheets.sqlite"),
            ("the wrong case", "\(home)/Library/Application Support/opensheets/OpenSheets.sqlite"),
            ("a traversal into it", "\(home)/Library/Preferences/../Application Support/OpenSheets/x.csv"),
        ]

        var reachable: [String] = []
        for entry in denied where grants.isAllowed(entry.1) {
            reachable.append("\(entry.0): \(entry.1)")
        }
        #expect(reachable.isEmpty, "the share store was reachable through a grant of ~/Library: \(reachable)")
    }

    /// The refusal names the rule that fired. "It matched `~/Library/Application Support/
    /// OpenSheets`" is actionable; "denied" is not — the reasoning ``DenyList/matchingRule(for:)``
    /// already stands on.
    @Test func theRefusalNamesTheStoreRule() throws {
        let grants = try grantsOverLibrary()

        let error = #expect(throws: SheetError.self) {
            try grants.check("\(home)/Library/Application Support/OpenSheets/OpenSheets.sqlite")
        }
        guard let error, case let .pathDenyListed(_, rule) = error else {
            Issue.record("expected pathDenyListed, got \(String(describing: error))")
            return
        }
        #expect(rule == "~/Library/Application Support/OpenSheets")
    }

    /// The neighbour test that keeps the rule honest: the deny-list compares path *components*,
    /// so a folder whose name merely starts with `OpenSheets` is somebody's ordinary data and
    /// stays readable. A prefix match here would quietly deny more than it claims to.
    @Test func aSiblingThatMerelySharesThePrefixIsStillReadable() throws {
        let grants = try grantsOverLibrary()

        #expect(grants.isAllowed("\(home)/Library/Application Support/OpenSheetsExports/report.xlsx"))
        #expect(grants.isAllowed("\(home)/Library/Application Support/Numbers/report.xlsx"))
    }

    /// A store configured to live somewhere other than the standard path — a staged `HOME` in a
    /// test, or a relocated one — is covered by composing the list, not by editing the constant.
    @Test func aConfiguredStoreDirectoryIsDeniedWhenTheListIsComposed() throws {
        let scratch = TemporaryDirectory("deny-configured-store")
        let workspace = scratch.directory("Granted")
        let support = scratch.directory("Granted/OpenSheets")
        let database = support.appendingPathComponent("OpenSheets.sqlite")
        try Data("os1.dEvIcE.secret".utf8).write(to: database)
        let workbook = workspace.appendingPathComponent("Budget.xlsx")
        try Data("seed".utf8).write(to: workbook)

        let grants = WorkspaceGrants(
            mode: .app,
            storage: nil,
            denyList: DenyList.standard.denying(directory: support)
        )
        try grants.grant(UserGrantAuthorization(unchecked: workspace))

        #expect(grants.isAllowed(workbook.path(percentEncoded: false)), "the granted folder must still work")
        #expect(!grants.isAllowed(database.path(percentEncoded: false)))
        #expect(!grants.isAllowed(support.path(percentEncoded: false)))
    }

    /// Composing only ever denies more. Whatever the standard list already refused, the composed
    /// one refuses too — otherwise `denying(directory:)` would be a way to widen the boundary.
    @Test func composingNeverWidensTheList() {
        let composed = DenyList.standard.denying(
            directory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wherever")
        )

        for directory in DenyList.standard.directories {
            #expect(composed.directories.contains(directory), "composing dropped \(directory)")
        }
        #expect(composed.files == DenyList.standard.files)
        #expect(composed.filenamePatterns == DenyList.standard.filenamePatterns)
        #expect(composed.directories.count == DenyList.standard.directories.count + 1)
    }

    /// A pin on the constant itself, so a refactor that reshuffles the list and drops this entry
    /// fails here with the reason spelled out rather than silently reopening the store.
    @Test func theStandardListNamesTheStoreDirectory() {
        #expect(DenyList.standard.directories.contains("~/Library/Application Support/OpenSheets"))
    }
}
