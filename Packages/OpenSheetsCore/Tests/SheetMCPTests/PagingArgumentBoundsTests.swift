import Foundation
import SheetModel
import Testing

@testable import SheetMCP

/// Every count-shaped argument must be *rejected*, never trapped on.
///
/// The bug this pins killed the server. `filter` read `limit` with the unbounded accessor and
/// passed it straight to `Collection.prefix`, whose precondition **traps** on a negative count —
/// `Fatal error: Can't take a prefix of negative length`. A trap is not catchable, so `MCPServer`
/// could not turn it into `tool.invalidArguments`; the process died mid-session with SIGTRAP and
/// took the client's conversation with it.
///
/// The caller is a language model choosing arguments, so an out-of-range value is an ordinary
/// event, not an attack. Every such argument goes through `integer(_:default:atLeast:atMost:)`.
@Suite("Paging arguments are bounded, not trapped on")
struct PagingArgumentBoundsTests {
    /// Each tool paired with the count-shaped argument it reads.
    private static let pagingArguments: [(tool: String, argument: String)] = [
        ("read_range", "maxRows"),
        ("find", "limit"),
        ("filter", "limit"),
        ("describe", "maxColumns"),
        ("insert_rows", "count"),
        ("list_snapshots", "limit"),
        ("list_files", "limit"),
    ]

    @Test("A bounded read rejects a negative value instead of trapping")
    func negativeIsRejected() throws {
        for (tool, argument) in Self.pagingArguments {
            let arguments = ToolArguments(tool: tool, values: [argument: .number(-1)])
            #expect(throws: SheetError.self) {
                _ = try arguments.integer(argument, default: 100, atLeast: 1)
            }
        }
    }

    @Test("Zero is rejected too — prefix(0) does not trap, but an empty page is never what was meant")
    func zeroIsRejected() throws {
        let arguments = ToolArguments(tool: "filter", values: ["limit": .number(0)])
        #expect(throws: SheetError.self) {
            _ = try arguments.integer("limit", default: 100, atLeast: 1)
        }
    }

    @Test("The error names the argument, the bound, and what was actually sent")
    func theErrorIsActionable() {
        let arguments = ToolArguments(tool: "filter", values: ["limit": .number(-1)])
        do {
            _ = try arguments.integer("limit", default: 100, atLeast: 1)
            Issue.record("expected a rejection")
        } catch {
            let message = error.message
            #expect(message.contains("limit"), "the argument is named: \(message)")
            #expect(message.contains("-1"), "the offending value is quoted back: \(message)")
            #expect(error.code == "tool.invalidArguments", "got \(error.code)")
        }
    }

    @Test("An upper bound is enforced and described")
    func upperBoundIsEnforced() {
        let arguments = ToolArguments(tool: "insert_rows", values: ["count": .number(9_999_999)])
        do {
            _ = try arguments.integer("count", default: 1, atLeast: 1, atMost: Limits.rowCount)
            Issue.record("expected a rejection")
        } catch {
            #expect(error.message.contains("between"), "a two-sided bound says so: \(error.message)")
        }
    }

    @Test("Values inside the range pass through unchanged, and the default still applies")
    func validValuesArePreserved() throws {
        let given = ToolArguments(tool: "filter", values: ["limit": .number(25)])
        #expect(try given.integer("limit", default: 100, atLeast: 1) == 25)

        let absent = ToolArguments(tool: "filter", values: [:])
        #expect(try absent.integer("limit", default: 100, atLeast: 1) == 100)

        let atTheBound = ToolArguments(tool: "filter", values: ["limit": .number(1)])
        #expect(try atTheBound.integer("limit", default: 100, atLeast: 1) == 1)
    }

    /// The one that would have caught the shipped bug: the server is still answering afterwards.
    ///
    /// Every test above reads the accessor directly, which proves the bound exists but *cannot*
    /// prove the fix, because the failure being pinned was a process death — `opensheets filter …
    /// --limit -1` exited **133** with no output, and over MCP that ended the session rather than
    /// the call. A trap in the handler would have taken this test process down too, so the claim
    /// has to be made from the far side of the bad call: run `filter` with `limit: -1` through the
    /// real dispatch path, then run a *second* filter on the same harness. If the first one
    /// trapped, there is no second one to assert on.
    @Test("A negative limit is refused instead of trapping, and the server answers the next call")
    @MainActor
    func aNegativeLimitIsRefusedInsteadOfTrapping() async throws {
        let harness = try Harness.make("filter-negative-limit")
        let path = try harness.install(try Fixtures.mixedTypes(), as: "imported.xlsx")
        let condition = JSONValue.array([.object([
            "column": .string("amount"), "op": .string("gt"), "value": .number(5),
        ])])

        let refused = await harness.call("filter", [
            "path": .string(path),
            "where": condition,
            "limit": .integer(-1),
        ])
        #expect(refused.isError, "a negative `limit` is refused, not obeyed: \(refused.text)")
        #expect(
            refused.text.contains("tool.invalidArguments"),
            "and refused as a classifiable tool-argument failure: \(refused.text)"
        )
        #expect(refused.text.contains("limit"), "which names the argument at fault: \(refused.text)")

        // The whole point: something is still alive to answer this.
        let afterwards = await harness.call("filter", [
            "path": .string(path),
            "where": condition,
            "limit": .integer(5),
        ])
        #expect(!afterwards.isError, "the server outlived the bad call: \(afterwards.text)")
        #expect(afterwards.text.contains("rows matched"), "\(afterwards.text)")
    }
}
