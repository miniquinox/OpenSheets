import DocumentCore
import Foundation
import SheetFormat
import SheetModel
import SheetStore
import TestSupport
import Testing

/// What happens when a file is opened — once, twice, or five times at the same instant — and what
/// opening it does to the workspace grants.
///
/// # Why this suite exists
///
/// A8's acceptance criterion was *"the same file open twice shares one `DocumentModel`"*, and the
/// implementation looked like it held: ``DocumentCore/AppModel`` keeps a weak table of open
/// documents and returns the live one. It held only for opens that did not overlap. The lookup
/// happens before two `await`s, so five windows asking in the same run-loop turn all saw "nothing
/// open" and the file ended up with five models, five sessions and five watchers — which is what
/// five stray windows on screen actually meant, and what would have turned a save into data loss.
///
/// A criterion nothing checks is a comment. These are the checks.
@Suite(.serialized)
@MainActor
struct OpenDocumentTests {
    // MARK: - One model per file

    @Test func theSameFileOpenedTwiceSharesOneDocumentModel() async throws {
        let harness = try await Harness(autoRefresh: nil)
        let again = try await harness.app.openDocument(at: harness.url)

        #expect(again === harness.model)
        #expect(harness.app.openDocuments.count == 1)
        harness.close()
    }

    /// The same file reached by two spellings of one path is still one document.
    @Test func aSymlinkedPathIsTheSameDocument() async throws {
        let harness = try await Harness(autoRefresh: nil)
        let link = harness.directory.appendingPathComponent("alias.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: harness.url)

        let again = try await harness.app.openDocument(at: link)
        #expect(again === harness.model)
        #expect(harness.app.openDocuments.count == 1)
        harness.close()
    }

    /// The one the window bug was made of: five opens started before any of them finishes.
    ///
    /// Without the in-flight table this fails with five distinct models — and it fails the same
    /// way whether the five requests came from five windows, five drops, or `open(1)` pointed at
    /// the same file five times, which is exactly how it was hit.
    @Test func fiveSimultaneousOpensOfOneFileShareOneDocumentModel() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "contended.xlsx")
        let app = AppModel(store: try Harness.makeStore())

        // Five tasks created before any of them runs. They inherit the main actor from this
        // test, so each one gets as far as `openDocument`'s first suspension before the next
        // starts — which is precisely the interleaving five windows produce.
        let attempts = (0 ..< 5).map { _ in
            Task { try await app.openDocument(at: url, consent: .userSelectedInPanel) }
        }
        var models: [DocumentModel] = []
        for attempt in attempts { models.append(try await attempt.value) }

        #expect(models.count == 5, "every caller should get a model, not an error")
        #expect(Set(models.map(ObjectIdentifier.init)).count == 1, "and it should be the same one")
        #expect(app.openDocuments.count == 1, "one file, one session, one watcher")
        for model in models { app.closeDocument(model) }
        scratch.remove()
    }

    /// Closing the document really does forget it, so the next open is a fresh one rather than a
    /// resurrected model whose session has already been stopped.
    @Test func closingForgetsTheDocument() async throws {
        let harness = try await Harness(autoRefresh: nil)
        harness.close()
        #expect(harness.app.openDocuments.isEmpty)
    }

    // MARK: - Opening a file grants its folder (PLAN.md §1.1)

    @Test func openingFromAPanelGrantsTheParentFolderWithoutAskingAgain() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "budget.xlsx")
        let app = AppModel(store: try Harness.makeStore())
        let asked = Counter()
        app.confirmWorkspaceGrant = { _ in
            asked.bump()
            return true
        }

        #expect(app.grants.isEmpty, "the point of the test is that this starts empty")
        let model = try await app.openDocument(at: url, consent: .userSelectedInPanel)

        #expect(asked.value == 0, "the panel was the consent gesture; asking twice is nagging")
        #expect(app.grants.map(\.path).contains { $0.hasSuffix(scratch.url.lastPathComponent) })
        #expect(app.store.grants.isAllowed(url))
        // …and the user is told, in the panel that already shows the workspace path.
        #expect(model.feed.contains { $0.summary.contains("Granted") }, "a silent grant is the bug")
        app.closeDocument(model)
        scratch.remove()
    }

    @Test func openingAFileFromOutsideTheAppAsksFirst() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "dropped.xlsx")
        let app = AppModel(store: try Harness.makeStore())
        let asked = Counter()
        app.confirmWorkspaceGrant = { _ in
            asked.bump()
            return true
        }

        let model = try await app.openDocument(at: url, consent: .fromOutsideTheApp)
        #expect(asked.value == 1)
        #expect(app.store.grants.isAllowed(url))
        app.closeDocument(model)
        scratch.remove()
    }

    @Test func sayingNoLeavesNoGrantAndNoDocument() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "refused.xlsx")
        let app = AppModel(store: try Harness.makeStore())
        app.confirmWorkspaceGrant = { _ in false }

        await #expect(throws: SheetError.self) {
            _ = try await app.openDocument(at: url, consent: .fromOutsideTheApp)
        }
        #expect(app.grants.isEmpty)
        #expect(!app.store.grants.isAllowed(url))
        #expect(app.openDocuments.isEmpty)
        scratch.remove()
    }

    /// No hook installed is the same answer as "no". A permission that is granted because nobody
    /// wired up the question is a permission nobody granted.
    @Test func noConfirmationHookRefusesRatherThanGrants() async throws {
        let scratch = try Scratch()
        let url = try scratch.writeWorkbook(named: "unasked.xlsx")
        let app = AppModel(store: try Harness.makeStore())

        await #expect(throws: SheetError.self) {
            _ = try await app.openDocument(at: url, consent: .fromOutsideTheApp)
        }
        #expect(app.grants.isEmpty)
        scratch.remove()
    }

    /// A folder that is already granted is never asked about again, however the file arrives.
    @Test func anAlreadyGrantedFolderIsNotAskedAboutAgain() async throws {
        let scratch = try Scratch()
        let first = try scratch.writeWorkbook(named: "one.xlsx")
        let second = try scratch.writeWorkbook(named: "two.xlsx")
        let app = AppModel(store: try Harness.makeStore())
        let asked = Counter()
        app.confirmWorkspaceGrant = { _ in
            asked.bump()
            return true
        }

        let one = try await app.openDocument(at: first, consent: .fromOutsideTheApp)
        let two = try await app.openDocument(at: second, consent: .fromOutsideTheApp)
        #expect(asked.value == 1)
        #expect(two.feed.contains { $0.summary.contains("Granted") } == false, "said once, not per file")
        app.closeDocument(one)
        app.closeDocument(two)
        scratch.remove()
    }

    // MARK: - Scaffolding

    /// A temporary folder holding real `.xlsx` bytes, so the grant under test is a grant on a
    /// folder that exists.
    @MainActor
    struct Scratch {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("opensheets-open-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func writeWorkbook(named name: String) throws -> URL {
            let target = url.appendingPathComponent(name)
            let workbook = try Harness.seedWorkbook(1)
            var tracker = WorkbookEditTracker()
            for sheet in workbook.sheets { tracker.noteSheetReplaced(sheet) }
            try XLSXWriter.data(for: workbook, edits: tracker).write(to: target)
            return target
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    /// A counter the `@Sendable` confirmation hook can bump.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func bump() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}
