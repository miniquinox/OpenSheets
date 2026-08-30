import Synchronization
import Testing

@testable import DocumentCore

/// The workspace tree's node type, on its own.
///
/// Small assertions about a small value, and worth writing anyway: `WorkspaceNode` is the type
/// three later agents key their diffing, their expansion set and their SwiftUI identity on. If
/// its `Hashable` conformance ever stops distinguishing two nodes it should distinguish, the
/// symptom is a row that will not redraw — which nobody debugs by looking here.
@Suite("Workspace node")
struct WorkspaceNodeTests {
    // MARK: - Load

    @Test("A loaded count is part of the value")
    func loadedCountRoundTripsThroughHashable() {
        let three = WorkspaceNode.Load.loaded(omitted: 3)
        #expect(three == .loaded(omitted: 3))
        #expect(three != .loaded(omitted: 4))
        #expect(three != .loaded(omitted: 0))

        // Through a Set, because that is how a diff actually consumes it: if the payload were
        // dropped from the hash, "500 shown, 2,609 hidden" and "500 shown, nothing hidden" would
        // collapse into one state and the truncation note would stop appearing.
        var seen: Set<WorkspaceNode.Load> = [three]
        seen.insert(.loaded(omitted: 3))
        #expect(seen.count == 1)
        seen.insert(.loaded(omitted: 4))
        #expect(seen.count == 2)

        let byLoad: [WorkspaceNode.Load: String] = [.loaded(omitted: 3): "three", .loaded(omitted: 0): "none"]
        #expect(byLoad[.loaded(omitted: 3)] == "three")
        #expect(byLoad[.loaded(omitted: 0)] == "none")
    }

    @Test("An unlisted folder and an empty one are different states")
    func idleIsNotLoadedEmpty() {
        // Lazy loading only works if these two can be told apart: one draws a triangle worth
        // clicking, the other draws a folder that is genuinely empty.
        #expect(WorkspaceNode.Load.idle != .loaded(omitted: 0))
        #expect(WorkspaceNode.Load.unreadable != .missing)
        #expect(WorkspaceNode.Load.loading != .idle)
    }

    // MARK: - Identity

    @Test("Same path, different depth, different node")
    func depthParticipatesInEquality() {
        // The same file can appear at two depths — granting both `~/Reports` and its parent puts
        // `q3.xlsx` in the tree twice. The rows are not interchangeable: one is indented further
        // than the other, so a value that ignored depth would let a diff swap them and leave the
        // indentation stale.
        let shallow = WorkspaceNode(id: "/Users/x/Reports/q3.xlsx", name: "q3.xlsx", depth: 1, kind: .file)
        let deep = WorkspaceNode(id: "/Users/x/Reports/q3.xlsx", name: "q3.xlsx", depth: 2, kind: .file)
        #expect(shallow != deep)
        #expect(shallow.id == deep.id)
        #expect(Set([shallow, deep]).count == 2)
    }

    @Test("Everything else about a node is part of it too")
    func expansionAndSizeParticipateInEquality() {
        let collapsed = WorkspaceNode(id: "/Users/x/Reports", name: "Reports", depth: 0, kind: .root)
        var expanded = collapsed
        expanded.isExpanded = true
        #expect(collapsed != expanded)

        var sized = collapsed
        sized.byteCount = 12_345
        #expect(collapsed != sized)
        #expect(collapsed.byteCount == nil)
        #expect(collapsed == WorkspaceNode(id: "/Users/x/Reports", name: "Reports", depth: 0, kind: .root))
    }

    @Test("A fresh node has looked at nothing and is closed")
    func defaultsAreUnvisited() {
        let node = WorkspaceNode(id: "/Users/x", name: "x", depth: 0, kind: .root)
        #expect(node.load == .idle)
        #expect(!node.isExpanded)
        #expect(node.byteCount == nil)
    }

    // MARK: - Storage

    @Test("The expansion store is conformable without a database")
    func storageIsUsableInMemory() {
        // The reason the protocol exists. If this ever stops compiling, the tree can only be
        // tested against SQLite, and E4's tests become integration tests by accident.
        let storage: any WorkspaceTreeStorage = MemoryTreeStorage()
        #expect(storage.expandedPaths().isEmpty)
        storage.setExpandedPaths(["/Users/x/Reports", "/Users/x"])
        #expect(storage.expandedPaths() == ["/Users/x/Reports", "/Users/x"])
        storage.setExpandedPaths([])
        #expect(storage.expandedPaths().isEmpty)
    }
}

/// The fake E4 will want: an expansion set that lives for the length of one test.
///
/// A `Mutex` rather than a bare `var` because ``WorkspaceTreeStorage`` is `Sendable` and its
/// setter is not `mutating` — the protocol is shaped for a store that is shared, which is exactly
/// what makes it usable from a `@MainActor` view and a background lister at once.
private final class MemoryTreeStorage: WorkspaceTreeStorage {
    private let paths = Mutex<[String]>([])

    func expandedPaths() -> [String] { paths.withLock { $0 } }

    func setExpandedPaths(_ newPaths: [String]) { paths.withLock { $0 = newPaths } }
}
