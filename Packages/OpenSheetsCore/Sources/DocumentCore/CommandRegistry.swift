import Foundation
import GlassUI
import SheetModel

/// What ⌘K can do, and what happens when you pick it.
///
/// The registry is here rather than in `GlassUI` because half of these are menu items and the menu
/// bar is the source of truth for what the app can do. A palette that knows a different set of
/// commands from the menu is a palette that is wrong within a week.
public enum PaletteCommand: Sendable, Hashable {
    case goToCell(CellRef)
    case selectSheet(SheetID)
    case selectDefinedName(String)
    case refresh
    case save
    case undo
    case redo
    case toggleSidebar
    case toggleInspector
    case toggleFormulas
    case snapshots
    case openTerminal
    case insertFunction(String)
    /// PLAN.md §1.2 step 8 — mark here, and measure everything from it.
    case setCheckpoint
    case toggleChangeHighlights
    case nextTab
    case previousTab
}

/// Builds the palette's sections for a query.
public enum CommandRegistry {
    /// The static commands, in the order they appear when the query is empty.
    ///
    /// - Parameters:
    ///   - isTrackingChanges: `Flags.changeTrackingEnabled`. The checkpoint and the highlight
    ///     toggle are **absent** rather than disabled when the flag is off, because the flag's
    ///     promise (§1.10) is the exact pre-feature experience — and a greyed-out row named after
    ///     a feature you have switched off is still the feature, advertising itself.
    ///   - hasTabs: whether there is more than one tab to move between. Same reasoning as the
    ///     menu bar's `Next Tab`, which disables below two: a palette entry that reliably does
    ///     nothing teaches people not to trust the palette.
    public static func actions(
        canUndo: Bool,
        canRedo: Bool,
        canRefresh: Bool,
        canSave: Bool,
        isTrackingChanges: Bool = false,
        hasTabs: Bool = false
    ) -> [(item: CommandItem, command: PaletteCommand)] {
        var built: [(item: CommandItem, command: PaletteCommand)] = [
            (
                CommandItem(
                    id: "refresh", title: "Refresh from disk", symbol: "arrow.clockwise",
                    shortcut: "⌘R", isEnabled: canRefresh
                ),
                .refresh
            ),
            (
                CommandItem(
                    id: "save", title: "Save", symbol: "square.and.arrow.down",
                    shortcut: "⌘S", isEnabled: canSave
                ),
                .save
            ),
            (
                CommandItem(id: "undo", title: "Undo", symbol: "arrow.uturn.backward", shortcut: "⌘Z", isEnabled: canUndo),
                .undo
            ),
            (
                CommandItem(
                    id: "redo", title: "Redo", symbol: "arrow.uturn.forward", shortcut: "⇧⌘Z",
                    isEnabled: canRedo
                ),
                .redo
            ),
            (
                CommandItem(id: "sidebar", title: "Toggle sidebar", symbol: "sidebar.left", shortcut: "⌘0"),
                .toggleSidebar
            ),
            (
                CommandItem(id: "inspector", title: "Toggle inspector", symbol: "paintbrush", shortcut: "⌘⌥1"),
                .toggleInspector
            ),
            (
                CommandItem(id: "formulas", title: "Show formulas", symbol: "function", shortcut: "⌃`"),
                .toggleFormulas
            ),
            (
                CommandItem(id: "snapshots", title: "Restore snapshot…", symbol: "clock.arrow.circlepath"),
                .snapshots
            ),
            (
                CommandItem(id: "terminal", title: "Open terminal here", symbol: "terminal"),
                .openTerminal
            ),
        ]

        if isTrackingChanges {
            built.append(
                (
                    CommandItem(
                        id: "checkpoint", title: "Set checkpoint", symbol: "flag",
                        shortcut: "⇧⌘K"
                    ),
                    .setCheckpoint
                )
            )
            built.append(
                (
                    CommandItem(
                        id: "highlights", title: "Toggle change highlights",
                        symbol: "square.on.square.dashed"
                    ),
                    .toggleChangeHighlights
                )
            )
        }

        if hasTabs {
            built.append(
                (
                    CommandItem(id: "next-tab", title: "Next tab", symbol: "arrow.right", shortcut: "⇧⌘]"),
                    .nextTab
                )
            )
            built.append(
                (
                    CommandItem(
                        id: "previous-tab", title: "Previous tab", symbol: "arrow.left", shortcut: "⇧⌘["
                    ),
                    .previousTab
                )
            )
        }

        return built
    }

    /// Everything the palette should show for `query`.
    ///
    /// A bare cell reference short-circuits to the top as its own section. Typing `D14` into a
    /// spreadsheet's command palette means one thing, and making the user scroll past four fuzzy
    /// matches for "D" to reach it would be a worse answer than a plain Go To dialog.
    public static func sections(
        query: String,
        workbook: Workbook,
        definedNames: [DefinedNameItem],
        canUndo: Bool,
        canRedo: Bool,
        canRefresh: Bool,
        canSave: Bool,
        isTrackingChanges: Bool = false,
        hasTabs: Bool = false
    ) -> (sections: [CommandSection], commands: [String: PaletteCommand]) {
        var sections: [CommandSection] = []
        var commands: [String: PaletteCommand] = [:]

        if let ref = CellRef(a1: query.uppercased()) {
            let item = CommandItem(
                id: "goto", title: "Go to \(ref.a1String)", subtitle: "on this sheet", symbol: "scope"
            )
            commands[item.id] = .goToCell(ref)
            sections.append(CommandSection(id: "goto", title: "Go to", items: [item]))
        }

        let sheetItems = workbook.sheets.map { sheet in
            CommandItem(
                id: "sheet:\(sheet.id.rawValue)",
                title: sheet.name,
                subtitle: sheet.visibility == .visible ? nil : "hidden",
                symbol: "tablecells"
            )
        }
        for (index, sheet) in workbook.sheets.enumerated() {
            commands[sheetItems[index].id] = .selectSheet(sheet.id)
        }
        let rankedSheets = CommandFuzzy.rank(sheetItems, query: query, by: \.title)
        if !rankedSheets.isEmpty {
            sections.append(CommandSection(id: "sheets", title: "Sheets", items: rankedSheets))
        }

        let nameItems = definedNames.map { name in
            CommandItem(
                id: "name:\(name.id)", title: name.name, subtitle: name.rangeLabel, symbol: "at"
            )
        }
        for (index, name) in definedNames.enumerated() {
            commands[nameItems[index].id] = .selectDefinedName(name.name)
        }
        let rankedNames = CommandFuzzy.rank(nameItems, query: query, by: \.title)
        if !rankedNames.isEmpty {
            sections.append(CommandSection(id: "names", title: "Named ranges", items: rankedNames))
        }

        let actionPairs = actions(
            canUndo: canUndo, canRedo: canRedo, canRefresh: canRefresh, canSave: canSave,
            isTrackingChanges: isTrackingChanges, hasTabs: hasTabs
        )
        for pair in actionPairs { commands[pair.item.id] = pair.command }
        let rankedActions = CommandFuzzy.rank(actionPairs.map(\.item), query: query, by: \.title)
        if !rankedActions.isEmpty {
            sections.append(CommandSection(id: "actions", title: "Commands", items: rankedActions))
        }

        return (sections, commands)
    }
}
