import DocumentCore
import Foundation
import SheetStore
import Testing

/// **The invariant the discovery tools rest on: if it shows in the Files panel, an agent can find
/// it.**
///
/// The panel filters its listings with `DocumentWorkbookReader`'s two sets; the MCP server filters
/// its listings with ``SheetStore/SpreadsheetFileTypes/listable``. They have to be the same set, and
/// they cannot be the same *constant*: the reader lives in `DocumentCore`, above `SheetMCP`, so the
/// server cannot see it, and `SheetStore` cannot import downwards to fetch it.
///
/// So parity is enforced here instead of by a refactor. This test target is the only place that can
/// see both modules at once, which makes it the cheapest possible seam — and it means `AppModel`,
/// which somebody else owns, is not touched to satisfy a layering constraint. The same trick
/// `CLISurfaceTests` uses to keep the CLI and the tool registry in step.
///
/// If this fails, the fix is to add the extension to ``SheetStore/SpreadsheetFileTypes/listable``
/// too — not to relax the assertion. A sidebar and a tool that disagree about which files exist is
/// the bug report nobody can reproduce.
@Suite("Files panel and MCP listing agree about which files exist")
struct WorkspaceParityTests {
    /// The set the panel lists is exactly the set the server lists.
    @Test func theListableExtensionsAreTheOnesTheFilesPanelShows() {
        let panel = DocumentWorkbookReader.workbookExtensions
            .union(DocumentWorkbookReader.delimitedExtensions)

        #expect(panel == SpreadsheetFileTypes.listable)
    }

    /// And it is a real set rather than two empty ones agreeing — the failure mode a `==` between
    /// two computed constants would otherwise hide.
    @Test func theAgreementIsAboutSomethingRatherThanNothing() {
        #expect(SpreadsheetFileTypes.listable.contains("xlsx"))
        #expect(SpreadsheetFileTypes.listable.contains("csv"))
        #expect(SpreadsheetFileTypes.listable.count == 8)
    }

    /// The payloads `DocumentCore` names and the ones `SheetStore` owns are one type, not two that
    /// happen to encode alike. A typealias makes drift a compile error; this asserts it is still a
    /// typealias and not a copy somebody re-introduced.
    @Test func theWorkspacePayloadsAreTheSameTypesTheServerReads() {
        #expect(WorkspaceTreeState.self == PersistedWorkspaceTree.self)
        #expect(TabsModel.PersistedTabs.self == PersistedOpenTabs.self)
        #expect(DatabaseWorkspaceTreeStorage.preferenceKey == WorkspacePreferenceKey.explorer)
    }
}
