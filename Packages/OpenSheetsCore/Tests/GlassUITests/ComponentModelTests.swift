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

    // MARK: - File tabs

    @Test("A tab is identified by its document key, not by its name")
    func fileTabIdentityIsTheDocumentKey() {
        // Two files called data.csv are two tabs; one file reached by two spellings of its path is
        // one tab. Both facts fall out of using the model layer's own key as the id, which is why
        // the strip takes a resolved string rather than a URL.
        let work = FileTabItem(id: "/w/data.csv", title: "data.csv", fullPath: "/w/data.csv")
        let models = FileTabItem(id: "/m/data.csv", title: "data.csv", fullPath: "/m/data.csv")
        #expect(work != models)
        #expect(work.id != models.id)

        var renamed = work
        renamed.title = "renamed.csv"
        #expect(renamed.id == work.id, "a rename is not a different tab")

        let state = FileTabStripState(tabs: [work, models], activeID: models.id)
        #expect(Set(state.tabs.map(\.id)).count == 2)
        #expect(state.activeID == models.id)
        #expect(!state.isEmpty)
        #expect(FileTabStripState(tabs: []).isEmpty)
    }

    @Test("Equal states are equal, so the strip does not re-render on a no-op")
    func fileTabStripStateEquality() {
        let tabs = [FileTabItem(id: "1", title: "a.csv", fullPath: "/a.csv")]
        #expect(FileTabStripState(tabs: tabs, activeID: "1") == FileTabStripState(tabs: tabs, activeID: "1"))
        #expect(FileTabStripState(tabs: tabs, activeID: "1") != FileTabStripState(tabs: tabs))

        var changed = tabs
        changed[0].status = .agentChanged
        #expect(FileTabStripState(tabs: changed) != FileTabStripState(tabs: tabs))
    }

    @Test("Every status maps to exactly one dot, and only two of them draw nothing")
    func statusMapsToOneDot() {
        // Plan §1.5: one dot per tab, worst news wins. The precedence itself belongs to the app
        // layer; what belongs here is that each resolved status has one unambiguous rendering.
        let expected: [(FileTabItem.Status, FileTabDot)] = [
            (.none, .absent),
            (.loading, .progress),
            (.unsaved, .unsaved),
            (.agentChanged, .agent),
            (.conflict, .conflict),
            (.problem, .problem),
        ]
        for (status, dot) in expected {
            #expect(FileTabDot(status) == dot)
        }
        // Distinct statuses must not collapse onto one dot, or the strip is telling six stories
        // with five faces.
        #expect(Set(expected.map(\.1)).count == expected.count)

        for context in AppearanceContext.snapshotMatrix {
            #expect(FileTabDot.absent.color(context) == nil, "an absent dot has no colour to draw")
            #expect(FileTabDot.progress.color(context) == nil, "loading draws a spinner, not a dot")
            for dot in [FileTabDot.unsaved, .agent, .conflict, .problem] {
                #expect(dot.color(context) != nil, "\(dot) has no colour in \(context.snapshotName)")
            }
        }
    }

    @Test("The dot is spoken, never left to colour alone")
    func statusIsCarriedInTheAccessibilityLabel() {
        #expect(FileTabDot.absent.spokenStatus == nil, "silence is correct when nothing is wrong")
        for dot in [FileTabDot.progress, .unsaved, .agent, .conflict, .problem] {
            #expect(dot.spokenStatus?.isEmpty == false, "\(dot) says nothing to VoiceOver")
        }

        let tab = FileTabItem(
            id: "1", title: "data.csv", disambiguator: "work",
            fullPath: "/w/data.csv", status: .conflict
        )
        let label = tab.accessibilityLabel
        #expect(label.contains("data.csv"))
        #expect(label.contains("work"), "the disambiguator is on screen, so it is spoken")
        #expect(label.contains("conflict"))

        let quiet = FileTabItem(id: "2", title: "b.csv", fullPath: "/b.csv")
        #expect(quiet.accessibilityLabel == "b.csv", "a quiet tab says its name and stops")
    }

    // MARK: - Change tracking

    @Test("The chip counts what it tints, and nothing else")
    func chipCountsExcludeFormatting() {
        let chip = ChangeTrackingChipState(added: 12, modified: 5, removed: 3)
        #expect(chip.total == 20)
        #expect(!chip.isEmpty)
        #expect(chip.count(.added) == 12)
        #expect(chip.count(.modified) == 5)
        #expect(chip.count(.removed) == 3)

        // Zero is hidden, not rendered as `+0 ~0 −0`.
        #expect(ChangeTrackingChipState().isEmpty)
        // …unless the differ gave up, in which case zero is a floor rather than a fact and the
        // chip has to stay on screen to say so.
        #expect(!ChangeTrackingChipState(isTruncated: true).isEmpty)
    }

    @Test("A row is identified by sheet and address, so two sheets never collide")
    func panelRowIDsAreUniqueAcrossSheets() {
        let sections = [
            ChangeTrackingPanelState.Section(
                id: "Q4", sheetName: "Q4",
                rows: [
                    .init(id: "Q4!D2", sheetName: "Q4", refA1: "D2", summary: "120 → 129.6", kind: .modified),
                    .init(id: "Q4!E7", sheetName: "Q4", refA1: "E7", summary: "new", kind: .added),
                ]
            ),
            ChangeTrackingPanelState.Section(
                id: "Summary", sheetName: "Summary",
                rows: [
                    // The same address on a different sheet. A bare "D2" id here would make one of
                    // these rows disappear from the ForEach, which is the specific bug this pins.
                    .init(id: "Summary!D2", sheetName: "Summary", refA1: "D2", summary: "9 → 11", kind: .modified),
                    .init(
                        id: "structural-Summary-rows-14", sheetName: "Summary",
                        summary: "deleted 2 rows at 14", kind: .structural
                    ),
                ]
            ),
        ]
        let ids = sections.flatMap { $0.rows.map(\.id) }
        #expect(Set(ids).count == ids.count, "two rows share an id: \(ids)")
        #expect(Set(sections.map(\.id)).count == sections.count)

        // A structural row has nowhere to jump to, and the panel must be able to tell.
        let structural = sections[1].rows[1]
        #expect(structural.refA1 == nil)
        #expect(sections[0].rows.allSatisfy { $0.refA1 != nil })
    }

    @Test("Every baseline source names itself")
    func baselineSourcesAreLabelled() {
        let sources: [ChangeTrackingPanelState.SourceChoice] = [.asOpened, .checkpoint, .gitHEAD]
        for source in sources {
            #expect(!source.label.isEmpty)
        }
        #expect(Set(sources.map(\.label)).count == sources.count, "two sources read the same")
        // The default offer omits git: it is only real inside a work tree, and an option that can
        // never be chosen on this machine is better absent than permanently greyed out.
        let panel = ChangeTrackingPanelState(chip: .init(), baselineLabel: "Since opened")
        #expect(!panel.sources.contains(.gitHEAD))
        #expect(panel.activeSource == .asOpened)
    }

    @Test("Change kinds carry a glyph and a word, not just a colour")
    func changeKindsAreNotColourOnly() {
        for kind in DS.Change.Kind.allCases {
            #expect(!kind.glyph.isEmpty)
            #expect(!kind.symbolName.isEmpty)
            #expect(!kind.label.isEmpty)
        }
        #expect(DS.Change.Kind.allCases.count == 3, "style-only changes are counted, never tinted")
        #expect(Set(DS.Change.Kind.allCases.map(\.glyph)).count == 3)
        // A real minus sign, not a hyphen: next to tabular figures a hyphen sits too high and too
        // short to read as a sign.
        #expect(DS.Change.Kind.removed.glyph == "\u{2212}")
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
