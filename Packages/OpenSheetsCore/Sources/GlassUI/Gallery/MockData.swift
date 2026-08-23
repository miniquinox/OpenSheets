import SheetModel
import SwiftUI

/// Fixed mock values for the gallery, the previews and the snapshot tests.
///
/// **Nothing here is random and nothing here reads a clock.** Every timestamp is a literal string,
/// every count is a literal number. A gallery whose contents drift is a gallery you cannot compare
/// two screenshots of, and a snapshot test with `Date()` in it fails at midnight.
///
/// The content is one plausible scenario end to end — `~/work/q4-budget.xlsx`, into which Claude
/// Code has just added a projected column — rather than seven unrelated lorem samples. Judging a
/// design needs a story: the same file name, the same sheet names and the same 42 cells appear in
/// the pill, the diff, the sidebar feed and the tab bar, so the components can be judged as a
/// product instead of as a parts bin.
public enum Mock {
    // MARK: The scenario

    public static let fileName = "q4-budget.xlsx"
    public static let workspacePath = "~/work/finance"

    public static let sheetIDs: [SheetID] = [1, 2, 3, 4]

    public static let tabs: [SheetTabItem] = [
        SheetTabItem(id: 1, name: "Summary", colorIndex: 5),
        SheetTabItem(id: 2, name: "Q4", colorIndex: 3, pendingChangeCount: 42),
        SheetTabItem(id: 3, name: "Headcount"),
        SheetTabItem(id: 4, name: "Assumptions", colorIndex: 7),
        SheetTabItem(id: 5, name: "Scratch", visibility: .hidden),
        SheetTabItem(id: 6, name: "_xlnm_data", visibility: .veryHidden),
    ]

    public static let definedNames: [DefinedNameItem] = [
        DefinedNameItem(name: "GrowthRate", rangeLabel: "Assumptions!$B$4"),
        DefinedNameItem(name: "Q4Total", rangeLabel: "Q4!$F$16"),
        DefinedNameItem(name: "Headcount", rangeLabel: "Headcount!$A$1:$D$52", scope: "Headcount"),
    ]

    public static let fileInfo = FileInfo(
        name: fileName,
        path: "\(workspacePath)/\(fileName)",
        size: "412 KB",
        modified: "Today at 14:22",
        format: "Excel Workbook (.xlsx)",
        sheetCount: 6,
        containsMacros: true
    )

    // MARK: The change

    public static let notice = RefreshNotice(
        signal: .agent,
        headline: "Changed on disk",
        sheetCount: 1,
        cellCount: 42,
        shortcut: "⌘R"
    )

    public static let conflictNotice = RefreshNotice(
        signal: .conflict,
        headline: "Conflict",
        sheetCount: 1,
        cellCount: 42,
        localEditCount: 3,
        shortcut: "⌘R"
    )

    public static let failureNotice = RefreshNotice(
        signal: .failure,
        headline: "Could not read the file",
        sheetCount: 0,
        cellCount: 0,
        shortcut: nil,
        isWatching: false
    )

    /// A believable diff: a new projected column, one rounding change, one deleted note.
    public static let changes: [CellChange] = [
        change(row: 1, column: 5, before: "", after: "Q4 +8%", kind: .added),
        change(row: 2, column: 5, before: "", after: "464,400", kind: .added),
        change(row: 3, column: 5, before: "", after: "56,160", kind: .added),
        change(row: 4, column: 5, before: "", after: "42,228", kind: .added),
        change(row: 5, column: 5, before: "", after: "14,472", kind: .added),
        change(row: 6, column: 5, before: "", after: "20,304", kind: .added),
        change(row: 7, column: 5, before: "", after: "33,696", kind: .added),
        change(row: 8, column: 5, before: "", after: "112,968", kind: .added),
        change(row: 12, column: 3, before: "120", after: "129.6"),
        change(row: 13, column: 3, before: "1,204.55", after: "1,300.91"),
        change(row: 14, column: 3, before: "88,000", after: "95,040"),
        change(row: 15, column: 6, before: "check with finance", after: "", kind: .removed),
        change(row: 16, column: 3, before: "#DIV/0!", after: "0"),
    ]

    private static func change(
        row: Int,
        column: Int,
        before: String,
        after: String,
        kind: CellChange.Kind = .changed
    ) -> CellChange {
        CellChange(
            sheetName: "Q4",
            ref: CellRef(row: row, column: column),
            before: before,
            after: after,
            kind: kind
        )
    }

    public static let sheetSummaries: [SheetChangeSummary] = [
        SheetChangeSummary(name: "Q4", changedCount: 5, addedCount: 36, removedCount: 1),
        SheetChangeSummary(name: "Summary", changedCount: 0, addedCount: 0, removedCount: 0),
        SheetChangeSummary(name: "Assumptions v2", changedCount: 1, renamedFrom: "Assumptions"),
    ]

    public static let changeSet = FileChangeSet(
        notice: notice,
        sheets: sheetSummaries,
        changes: changes,
        truncatedCount: 29
    )

    public static let conflictChangeSet = FileChangeSet(
        notice: conflictNotice,
        sheets: sheetSummaries,
        changes: changes,
        truncatedCount: 29,
        wasRediffed: true
    )

    // MARK: Claude

    public static let feed: [SessionFeedEntry] = [
        SessionFeedEntry(
            id: "f3",
            timestamp: "14:22",
            summary: "Added a Q4 column projecting 8% growth",
            sheetName: "Q4",
            cellCount: 42
        ),
        SessionFeedEntry(
            id: "f2",
            timestamp: "13:58",
            summary: "Renamed Assumptions to Assumptions v2",
            sheetName: "Assumptions v2",
            cellCount: 1
        ),
        SessionFeedEntry(
            id: "f1",
            timestamp: "11:04",
            summary: "Fixed a #DIV/0! in the summary total",
            sheetName: "Summary",
            cellCount: 1
        ),
    ]

    public static let claudePanel = ClaudePanelState(
        workspacePath: workspacePath,
        isGranted: true,
        mcpStatus: .connected,
        feed: feed
    )

    public static let claudePanelUnconfigured = ClaudePanelState(
        workspacePath: workspacePath,
        isGranted: false,
        mcpStatus: .notConfigured,
        feed: []
    )

    public static let sidebar = SidebarState(
        sheets: tabs,
        selection: 2,
        definedNames: definedNames,
        fileInfo: fileInfo,
        claude: claudePanel
    )

    // MARK: Chrome

    public static let toolbar = ToolbarState(
        isBold: true,
        alignment: .trailing,
        numberFormat: .currency,
        fontName: "Calibri",
        fontSize: 11
    )

    public static let formulaBar = FormulaBarState(
        nameBoxText: "F16",
        definedNames: definedNames,
        text: #"IF(SUM(Q4!$D$2:$D$15)>0, ROUND(SUM(Q4!$D$2:$D$15)*GrowthRate, 2), "—")"#
    )

    public static let formulaBarWithError = FormulaBarState(
        nameBoxText: "F17",
        definedNames: definedNames,
        text: #"VLOOKUP(A17, Headcount!$A:$D, 9, FALSE) + #REF!"#,
        diagnostic: "VLOOKUP: column 9 is outside the range Headcount!$A:$D."
    )

    public static let tabBar = SheetTabBarState(tabs: tabs, selection: 2)

    public static let inspector = InspectorState(
        selectionLabel: "F2:F16",
        numberFormat: .currency,
        decimalPlaces: 2,
        customFormatCode: #"_("$"* #,##0.00_)"#,
        fontName: "Calibri",
        fontSize: 11,
        isBold: true,
        fillIndex: 3,
        borders: .outline,
        alignment: .trailing
    )

    public static let selectionStats = SelectionStats(
        rangeLabel: "F2:F16",
        values: [
            .sum: "$1,284,905.28",
            .average: "$85,660.35",
            .count: "15",
            .numericCount: "14",
            .minimum: "$5,275.00",
            .maximum: "$464,400.00",
        ]
    )

    // MARK: Floating

    public static let commandPalette = CommandPaletteState(
        query: "q4",
        sections: [
            CommandSection(
                id: "go",
                title: "Go to",
                items: [
                    CommandItem(
                        id: "go.sheet.q4",
                        title: "Q4",
                        subtitle: "Sheet · 42 changed cells",
                        symbol: "tablecells"
                    ),
                    CommandItem(
                        id: "go.name.q4total",
                        title: "Q4Total",
                        subtitle: "Q4!$F$16",
                        symbol: "at"
                    ),
                ]
            ),
            CommandSection(
                id: "file",
                title: "File",
                items: [
                    CommandItem(
                        id: "file.refresh",
                        title: "Refresh from disk",
                        subtitle: "1 sheet, 42 cells changed",
                        symbol: "arrow.clockwise",
                        shortcut: "⌘R"
                    ),
                    CommandItem(
                        id: "file.snapshots",
                        title: "Restore snapshot…",
                        symbol: "clock.arrow.circlepath"
                    ),
                ]
            ),
            CommandSection(
                id: "claude",
                title: "Claude",
                items: [
                    CommandItem(
                        id: "claude.terminal",
                        title: "Open terminal in ~/work/finance",
                        symbol: "terminal"
                    ),
                    CommandItem(
                        id: "claude.mcp",
                        title: "Copy MCP setup command",
                        symbol: "doc.on.clipboard",
                        isEnabled: false
                    ),
                ]
            ),
        ],
        selectedID: "go.sheet.q4"
    )

    public static let snapshots = SnapshotBrowserState(
        entries: [
            SnapshotEntry(
                id: "s5",
                takenAt: "Today at 14:22",
                relative: "4m ago",
                reason: .preRefresh,
                summary: "Before Claude added the Q4 column",
                size: "118 KB"
            ),
            SnapshotEntry(
                id: "s4",
                takenAt: "Today at 13:58",
                relative: "28m ago",
                reason: .preRefresh,
                summary: "Before the Assumptions rename",
                size: "117 KB"
            ),
            SnapshotEntry(
                id: "s3",
                takenAt: "Today at 11:40",
                relative: "2h ago",
                reason: .preSave,
                summary: "Before saving 14 edits",
                size: "116 KB"
            ),
            SnapshotEntry(
                id: "s2",
                takenAt: "Yesterday at 18:02",
                relative: "20h ago",
                reason: .manual,
                summary: "End of day",
                size: "112 KB"
            ),
        ],
        selectedID: "s5",
        storageSummary: "1.4 MB of 500 MB"
    )

    public static let conflict = ConflictBanner.Model(
        localEditCount: 3,
        fileName: fileName,
        changedAgo: "2 minutes ago"
    )

    // MARK: Launcher

    public static let launcher = LauncherState(
        recents: [
            RecentItem(
                id: "r1", name: "q4-budget.xlsx", folder: "~/work/finance",
                lastOpened: "4m ago", sheetCount: 6
            ),
            RecentItem(
                id: "r2", name: "headcount-2026.xlsx", folder: "~/work/people",
                lastOpened: "yesterday", sheetCount: 3
            ),
            RecentItem(
                id: "r3", name: "exports.csv", folder: "~/Downloads",
                lastOpened: "3d ago", sheetCount: 1, isGranted: false
            ),
            RecentItem(
                id: "r4", name: "old-model.xlsx", folder: "~/Desktop",
                lastOpened: "2w ago", sheetCount: 11, exists: false
            ),
        ],
        grants: [
            WorkspaceGrantItem(id: "g1", path: "~/work/finance", grantedAt: "3d ago", fileCount: 14),
            WorkspaceGrantItem(id: "g2", path: "~/work/people", grantedAt: "1w ago", fileCount: 6),
        ]
    )

    // MARK: Sync states

    public static let syncStates: [SyncState] = [
        .watching,
        .synced,
        .stale(cellCount: 42),
        .conflict(localEdits: 3),
        .dirty(localEdits: 3),
        .watchingPaused,
        .readOnly(reason: "This workbook uses a feature we cannot write back safely."),
        .locked(holder: "Microsoft Excel"),
        .missing,
    ]
}
