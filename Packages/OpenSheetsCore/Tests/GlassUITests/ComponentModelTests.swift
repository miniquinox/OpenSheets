import Foundation
import SheetModel
import Testing

@testable import GlassUI

/// The logic inside the components — the parts that are not "does it look right".
///
/// Every component takes a value in and emits an action out, and the interesting behaviour lives
/// in the value types: how a formula is coloured, how the palette ranks a query, what the pill
/// says when there is exactly one cell. None of that needs a renderer, and all of it is the kind
/// of thing that quietly regresses.
@Suite("Component behaviour")
struct ComponentModelTests {
    // MARK: - Formula syntax

    @Test("References, functions, strings and errors are classified")
    func formulaTokensAreClassified() {
        let tokens = FormulaSyntax.tokenize(#"=SUM(A1:B2) & "total" + #REF!"#)
        let kinds = tokens.map(\.kind)
        #expect(kinds.contains(.function))
        #expect(kinds.contains(.reference))
        #expect(kinds.contains(.string))
        #expect(kinds.contains(.error))

        let functionNames = tokens.filter { $0.kind == .function }.map(\.text)
        #expect(functionNames == ["SUM"])

        let references = tokens.filter { $0.kind == .reference }.map(\.text)
        #expect(references == ["A1", "B2"])

        let errors = tokens.filter { $0.kind == .error }.map(\.text)
        #expect(errors == ["#REF!"])
    }

    @Test("Every error literal is matched whole")
    func errorLiteralsAreNotTruncated() {
        // `#DIV/0!` starts with `#D`, and a naive longest-first list gets `#N/A` wrong because it
        // is a prefix of nothing but contains a slash. Both are worth pinning.
        for literal in ["#DIV/0!", "#VALUE!", "#NAME?", "#REF!", "#NULL!", "#NUM!", "#N/A"] {
            let tokens = FormulaSyntax.tokenize(literal)
            #expect(tokens.count == 1, "\(literal) split into \(tokens.count) tokens")
            #expect(tokens.first?.kind == .error)
            #expect(tokens.first?.text == literal)
        }
    }

    @Test("Sheet-qualified references stay one token")
    func sheetQualifiedReferences() {
        #expect(
            FormulaSyntax.tokenize("Sheet1!A1").map(\.text) == ["Sheet1!A1"]
        )
        #expect(
            FormulaSyntax.tokenize("'My Sheet'!$B$7").first?.kind == .reference
        )
    }

    @Test("A half-typed formula never crashes and never loses characters")
    func partialFormulasAreSafe() {
        // The lexer runs on every keystroke, so the interesting inputs are all the broken ones.
        let inputs = [
            "=", "=SUM(", "=SUM(A1:", #"="unterminated"#, "=1E", "=1E-", "=$", "='", "=A1:",
            "=IF(A1>0,", "=#", "=@#$%", "", "=(((", "=1..2",
        ]
        for input in inputs {
            let tokens = FormulaSyntax.tokenize(input)
            let roundTrip = tokens.map(\.text).joined()
            #expect(
                roundTrip == input,
                "tokenising \(input.debugDescription) lost or invented characters: \(roundTrip.debugDescription)"
            )
        }
    }

    @Test("A defined name is not mistaken for a reference")
    func definedNamesAreNotReferences() {
        #expect(FormulaSyntax.isReference("A1"))
        #expect(FormulaSyntax.isReference("$A$1"))
        #expect(FormulaSyntax.isReference("XFD1048576"))
        #expect(!FormulaSyntax.isReference("SUM"))
        #expect(!FormulaSyntax.isReference("Q4Total"))
        #expect(!FormulaSyntax.isReference("GrowthRate"))
        #expect(!FormulaSyntax.isReference("ABCD1"), "four letters is not a column")

        let tokens = FormulaSyntax.tokenize("=GrowthRate * 2")
        #expect(tokens.first(where: { $0.text == "GrowthRate" })?.kind == .name)
    }

    @Test("Scientific notation is one number")
    func scientificNotation() {
        #expect(FormulaSyntax.tokenize("1.5E-3").map(\.text) == ["1.5E-3"])
        #expect(FormulaSyntax.tokenize("1E+10").first?.kind == .number)
    }

    // MARK: - Command palette

    @Test("Word starts outrank mid-word matches")
    func fuzzyPrefersWordStarts() {
        let sortDescending = CommandFuzzy.score(query: "sd", candidate: "Sort descending")
        let sharedStrings = CommandFuzzy.score(query: "sd", candidate: "Shared strings dump")
        #expect(sortDescending != nil)
        #expect(sharedStrings != nil)
        #expect(sortDescending! > sharedStrings!)
    }

    @Test("A non-subsequence does not match")
    func fuzzyRejectsNonMatches() {
        #expect(CommandFuzzy.score(query: "zzz", candidate: "Sort ascending") == nil)
        #expect(CommandFuzzy.score(query: "gnidnecsa", candidate: "ascending") == nil)
    }

    @Test("Shorter candidates win ties")
    func fuzzyPrefersShorter() {
        let short = CommandFuzzy.score(query: "sum", candidate: "Sum")!
        let long = CommandFuzzy.score(query: "sum", candidate: "Summarise the selection")!
        #expect(short > long)
    }

    @Test("An empty query keeps the caller's order")
    func fuzzyEmptyQueryIsIdentity() {
        let items = ["Third", "First", "Second"]
        #expect(CommandFuzzy.rank(items, query: "", by: { $0 }) == items)
    }

    @Test("Ranking is stable inside a score band")
    func fuzzyRankingIsStable() {
        // Two candidates that score identically must keep the order they arrived in, or the
        // palette's list reshuffles between keystrokes that changed nothing.
        let items = ["Alpha one", "Alpha two"]
        #expect(CommandFuzzy.rank(items, query: "a", by: { $0 }) == items)
    }

    // MARK: - Selection stats

    @Test("Only applicable statistics are shown")
    func statsHideWhatDoesNotApply() {
        let textOnly = SelectionStats(rangeLabel: "A1:A9", values: [.count: "9"])
        #expect(textOnly.displayed == [.count])
        #expect(!textOnly.isEmpty)

        let nothing = SelectionStats(rangeLabel: "A1", values: [:])
        #expect(nothing.isEmpty)
    }

    @Test("Cycling walks every statistic and returns to the start")
    func statsCycleIsAClosedLoop() {
        var window = SelectionStat.defaultVisible
        var seen: Set<SelectionStat> = Set(window)
        for _ in 0 ..< SelectionStat.allCases.count {
            window = SelectionStats.cycled(window)
            #expect(window.count == 3)
            seen.formUnion(window)
        }
        #expect(seen == Set(SelectionStat.allCases), "cycling never reaches some statistics")
        // One full lap returns to where it started, so the control is predictable rather than
        // merely varied.
        #expect(window == SelectionStat.defaultVisible)
    }

    // MARK: - The sync surface

    @Test("The pill's detail line is grammatical at every count")
    func noticeDetailPluralises() {
        #expect(RefreshNotice(sheetCount: 1, cellCount: 1).detail == "1 sheet, 1 cell")
        #expect(RefreshNotice(sheetCount: 2, cellCount: 42).detail == "2 sheets, 42 cells")
        #expect(RefreshNotice(sheetCount: 0, cellCount: 0).detail.isEmpty)
        #expect(
            RefreshNotice(sheetCount: 1, cellCount: 3, localEditCount: 1).detail
                == "1 sheet, 3 cells, 1 unsaved edit"
        )
    }

    @Test("Large counts are grouped")
    func noticeGroupsThousands() {
        // 100,000 changed cells is a real number when an agent rewrites a column, and "100000
        // cells" in the app's signature moment would be the first thing anybody noticed.
        let detail = RefreshNotice(sheetCount: 1, cellCount: 100_000).detail
        #expect(detail.contains("100,000") || detail.contains("100 000"))
    }

    @Test("A change identifies itself by sheet and address")
    func changeIdentity() {
        let change = CellChange(
            sheetName: "Q4",
            ref: CellRef(row: 1, column: 3),
            before: "120",
            after: "129.6"
        )
        #expect(change.refLabel == "D2")
        #expect(change.id == "Q4!D2")
        #expect(change.beforeDisplay == "120")

        let added = CellChange(
            sheetName: "Q4", ref: .origin, before: "", after: "new", kind: .added
        )
        #expect(added.beforeDisplay == "—", "an empty before column reads as a rendering bug")
        #expect(added.refLabel == "A1")
    }

    @Test("Every sync state names itself and says what to do")
    func syncStatesAreComplete() {
        let states: [SyncState] = [
            .synced, .watching, .watchingPaused, .stale(cellCount: 42), .conflict(localEdits: 3),
            .dirty(localEdits: 1), .readOnly(reason: "On a read-only volume."), .missing,
            .locked(holder: "Excel"), .locked(holder: nil),
        ]
        for state in states {
            #expect(!state.label.isEmpty)
            #expect(!state.detail.isEmpty, "\(state.label) has no explanation")
            #expect(!state.symbolName.isEmpty)
            // A state that only says what went wrong is an alert. Every unhappy state ends with
            // something the reader can do.
            if state.signal != .neutral {
                #expect(state.detail.count > 20, "\(state.label)'s detail is too terse to act on")
            }
        }
    }

    @Test("Signals carry a glyph and a word, not just a colour")
    func signalsAreNotColourOnly() {
        for kind in DS.SignalKind.allCases {
            #expect(!kind.symbolName.isEmpty)
            #expect(!kind.label.isEmpty)
        }
        // Three tints, and only three. A fourth would make all four mean nothing.
        let tinted = DS.SignalKind.allCases.filter { DS.Signal.tintValue($0, .light) != nil }
        #expect(tinted.count == 3)
    }

    // MARK: - Claude panel

    @Test("Every MCP state has an instruction, not just a status")
    func mcpStatusExplainsItself() {
        let statuses: [MCPStatus] = [
            .connected, .idle, .notConfigured, .failing("Timed out after 5 s"),
        ]
        for status in statuses {
            let panel = ClaudePanelState(
                workspacePath: "~/work", isGranted: true, mcpStatus: status
            )
            #expect(!panel.statusDetail.isEmpty)
            #expect(!status.label.isEmpty)
        }
        let unconfigured = ClaudePanelState(
            workspacePath: "~/work", isGranted: false, mcpStatus: .notConfigured
        )
        #expect(
            unconfigured.statusDetail.contains("claude mcp add"),
            "the not-set-up state must say the command, because that is the whole fix"
        )
    }

    // MARK: - Sheets

    @Test("Hidden and very-hidden sheets stay off the tab bar but stay reachable")
    func tabVisibilityPartitions() {
        let state = SheetTabBarState(tabs: Mock.tabs, selection: 2)
        #expect(state.visibleTabs.count + state.hiddenTabs.count == Mock.tabs.count)
        #expect(state.hiddenTabs.contains { $0.visibility == .veryHidden })
        #expect(!state.visibleTabs.contains { $0.visibility != .visible })
    }

    @Test("The name box shows a defined name when the selection is one")
    func nameBoxPrefersDefinedNames() {
        let names = [DefinedNameItem(name: "Q4Total", rangeLabel: "F16")]
        let single = CellRange(CellRef(row: 15, column: 5))
        #expect(NameBoxLabel.text(for: single, definedNames: names) == "Q4Total")

        let other = CellRange(start: CellRef(row: 0, column: 0), end: CellRef(row: 8, column: 3))
        #expect(NameBoxLabel.text(for: other, definedNames: names) == "A1:D9")
    }

    // MARK: - Empty states

    @Test("Every empty state says what happened and offers a way forward")
    func emptyStatesAreActionable() {
        for model in EmptyStateModel.all {
            #expect(!model.title.isEmpty)
            #expect(!model.message.isEmpty)
            #expect(!model.symbol.isEmpty)
            #expect(
                model.primaryLabel != nil,
                "\(model.title) is a dead end — an empty screen is an invitation to act"
            )
            // The interface's voice, not a person's. No apologies, no blame.
            let text = (model.title + " " + model.message).lowercased()
            for banned in ["sorry", "oops", "unfortunately", "failed to", "unexpected error"] {
                #expect(!text.contains(banned), "\(model.title) says \"\(banned)\"")
            }
        }
    }

    @Test("The technical detail is available but not in the way")
    func technicalDetailIsProgressive() {
        let unreadable = EmptyStateModel.unreadable(detail: "zip.pathTraversal(\"../x\")")
        #expect(unreadable.technicalDetail != nil)
        #expect(
            !unreadable.message.contains("zip."),
            "the error code belongs behind the disclosure, not in the sentence"
        )
    }

    // MARK: - Conflict

    @Test("The conflict banner counts the user's edits correctly")
    func conflictCopyIsGrammatical() {
        #expect(
            ConflictBanner.Model(localEditCount: 1, fileName: "a.xlsx").headline
                == "Conflict — you have 1 unsaved edit"
        )
        #expect(
            ConflictBanner.Model(localEditCount: 3, fileName: "a.xlsx").headline
                == "Conflict — you have 3 unsaved edits"
        )
        #expect(
            ConflictBanner.Model(localEditCount: 3, fileName: "a.xlsx", changedAgo: "2 minutes ago")
                .detail == "a.xlsx also changed on disk 2 minutes ago."
        )
    }

    // MARK: - Tokens

    @Test("Hex parsing round-trips")
    func rgbaHexRoundTrip() {
        for hex in ["#000000", "#FFFFFF", "#1C1C1E", "#007AFF", "#00000026"] {
            #expect(RGBA(parsingHex: hex)?.hexString == hex)
        }
        #expect(RGBA(parsingHex: "not a colour") == nil)
        #expect(RGBA(parsingHex: "#FFF") == nil, "three-digit hex is ambiguous; we do not accept it")
    }

    @Test("Compositing matches the arithmetic")
    func compositingIsCorrect() {
        let half = RGBA(hex: "#000000").opacity(0.5)
        let onWhite = half.composited(over: RGBA(hex: "#FFFFFF"))
        #expect(onWhite.hexString == "#808080")
        #expect(onWhite.alpha == 1)

        // An opaque colour composites to itself.
        let opaque = RGBA(hex: "#123456")
        #expect(opaque.composited(over: RGBA(hex: "#FFFFFF")) == opaque)
    }

    @Test("Contrast maths matches the WCAG reference values")
    func contrastMathIsCorrect() {
        let white = RGBA(hex: "#FFFFFF")
        let black = RGBA(hex: "#000000")
        #expect(abs(black.contrastRatio(against: white) - 21) < 0.01)
        #expect(abs(white.contrastRatio(against: white) - 1) < 0.01)
        // #767676 on white is the canonical 4.54:1 example from the WCAG techniques.
        #expect(abs(RGBA(hex: "#767676").contrastRatio(against: white) - 4.54) < 0.02)
    }

    @Test("An appearance context names itself uniquely")
    func snapshotNamesAreUnique() {
        let names = AppearanceContext.snapshotMatrix.map(\.snapshotName)
        #expect(Set(names).count == names.count)
        #expect(AppearanceContext.light.snapshotName == "light-normal")
        #expect(
            AppearanceContext(colorScheme: .dark, reduceTransparency: true).snapshotName
                == "dark-reduceTransparency"
        )
    }

    @Test("pick() is a switch, not a derivation")
    func lightAndDarkAreIndependent() {
        let light = RGBA(hex: "#111111")
        let dark = RGBA(hex: "#EEEEEE")
        #expect(AppearanceContext.light.pick(light: light, dark: dark) == light)
        #expect(AppearanceContext.dark.pick(light: light, dark: dark) == dark)
    }

    @Test("Morph identities are distinct")
    func morphIDsAreDistinct() {
        // Two surfaces sharing an id would morph into each other across the window, which looks
        // exactly as wrong as it sounds and is impossible to debug from the outside.
        let ids = GlassMorphID.allCases.map(\.rawValue)
        #expect(Set(ids).count == ids.count)
    }

    @Test("The mock scenario is internally consistent")
    func mockDataTellsOneStory() {
        // The gallery and the screenshots are only useful if the pill, the diff and the feed are
        // describing the same event. This is the cheapest way to keep them that way.
        #expect(Mock.changeSet.notice.cellCount == 42)
        #expect(Mock.feed.first?.cellCount == Mock.changeSet.notice.cellCount)
        #expect(Mock.tabs.first { $0.name == "Q4" }?.pendingChangeCount == 42)
        #expect(Mock.changes.allSatisfy { $0.sheetName == "Q4" })
        #expect(Mock.sheetSummaries.contains { $0.name == "Q4" })
        #expect(Mock.fileInfo.sheetCount == Mock.tabs.count)
    }
}
