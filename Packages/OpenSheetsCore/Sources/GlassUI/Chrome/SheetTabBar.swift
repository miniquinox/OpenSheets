import SheetModel
import SwiftUI

/// Whether a sheet is on the tab bar, off it, or off it and not offered.
///
/// `veryHidden` is a real xlsx state (`state="veryHidden"`), set by VBA and by people who do not
/// want you looking at the sheet. We show it in the hidden-sheets menu anyway, marked, rather than
/// pretending it does not exist — this is a viewer, and hiding data from the person who opened the
/// file is not our call.
public enum TabVisibility: String, Sendable, Hashable, CaseIterable, Codable {
    case visible
    case hidden
    case veryHidden
}

/// One sheet tab.
public struct SheetTabItem: Sendable, Hashable, Identifiable {
    public var id: SheetID
    public var name: String
    /// Index into ``Palette/tabSwatches``. `nil` means no colour, which is the default and should
    /// stay the default — a workbook where every tab is coloured is a workbook where no tab is.
    public var colorIndex: Int?
    public var visibility: TabVisibility
    /// Cells the agent changed on this sheet since the last refresh. Drives the small accent dot,
    /// which is how you find out *which* sheet Claude touched without opening the diff.
    public var pendingChangeCount: Int

    public init(
        id: SheetID,
        name: String,
        colorIndex: Int? = nil,
        visibility: TabVisibility = .visible,
        pendingChangeCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.visibility = visibility
        self.pendingChangeCount = pendingChangeCount
    }
}

public struct SheetTabBarState: Sendable, Hashable {
    public var tabs: [SheetTabItem]
    public var selection: SheetID?
    /// Which tab is being renamed, if any. Owned by A8 so a rename survives a re-render.
    public var renaming: SheetID?
    public var isEditable: Bool

    public init(
        tabs: [SheetTabItem],
        selection: SheetID? = nil,
        renaming: SheetID? = nil,
        isEditable: Bool = true
    ) {
        self.tabs = tabs
        self.selection = selection
        self.renaming = renaming
        self.isEditable = isEditable
    }

    public var visibleTabs: [SheetTabItem] { tabs.filter { $0.visibility == .visible } }
    public var hiddenTabs: [SheetTabItem] { tabs.filter { $0.visibility != .visible } }
}

public enum SheetTabAction: Sendable, Hashable {
    case select(SheetID)
    case beginRename(SheetID)
    case commitRename(SheetID, String)
    case cancelRename
    /// Both indices are into ``SheetTabBarState/visibleTabs``.
    case reorder(from: Int, to: Int)
    case add
    case duplicate(SheetID)
    case delete(SheetID)
    case setColor(SheetID, Int?)
    case setVisibility(SheetID, TabVisibility)
}

/// The capsule strip along the bottom of the window.
///
/// Chrome glass, one lens for the whole strip: the tabs are *not* individually glass. A row of
/// twelve glass capsules is twelve lenses in a line, which is both the visual tell of a fake and,
/// at twelve sheets, genuinely slow. The strip is the lens; the tabs are fills inside it.
///
/// The selected tab is filled with the accent rather than outlined, because at 11pt in a busy
/// window an outline is not enough of a difference and you end up hunting for which sheet you are
/// on. Hunting for the current sheet is the specific failure this control has to avoid.
public struct SheetTabBar: View {
    private let state: SheetTabBarState
    private let context: AppearanceContext
    private let perform: (SheetTabAction) -> Void

    @State private var draggingID: SheetID?
    @State private var renameDraft: String = ""
    @FocusState private var renameFocused: Bool

    public init(
        state: SheetTabBarState,
        context: AppearanceContext,
        perform: @escaping (SheetTabAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        HStack(spacing: DS.Space.s) {
            addButton
            divider
            ScrollView(.horizontal) {
                HStack(spacing: DS.Space.xs) {
                    ForEach(Array(state.visibleTabs.enumerated()), id: \.element.id) { index, tab in
                        tabView(tab, at: index)
                    }
                }
                .padding(.horizontal, DS.Space.hair)
            }
            .scrollIndicators(.never)
            if !state.hiddenTabs.isEmpty {
                divider
                hiddenMenu
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs + 1)
        .glassChrome(context: context, radius: DS.Radius.control)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sheets")
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Chrome.separator(context))
            .frame(width: DS.Stroke.hairline(context), height: 14)
            .accessibilityHidden(true)
    }

    private var addButton: some View {
        Button { perform(.add) } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.Chrome.secondary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.isEditable)
        .help("New sheet")
        .accessibilityLabel("New sheet")
    }

    private var hiddenMenu: some View {
        Menu {
            ForEach(state.hiddenTabs) { tab in
                Button {
                    perform(.setVisibility(tab.id, .visible))
                } label: {
                    Text(tab.visibility == .veryHidden ? "\(tab.name)  (very hidden)" : tab.name)
                }
            }
        } label: {
            HStack(spacing: DS.Space.chipY) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .medium))
                Text("\(state.hiddenTabs.count)")
                    .dsNumeric(DS.Text.numericCaption)
            }
            .foregroundStyle(DS.Chrome.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(state.hiddenTabs.count) hidden sheets")
        .accessibilityLabel("\(state.hiddenTabs.count) hidden sheets")
    }

    // MARK: One tab

    @ViewBuilder
    private func tabView(_ tab: SheetTabItem, at index: Int) -> some View {
        let isSelected = tab.id == state.selection
        let isRenaming = tab.id == state.renaming

        HStack(spacing: DS.Space.xs) {
            if let colorIndex = tab.colorIndex, colorIndex < Palette.tabSwatches.count {
                Circle()
                    .fill(swatch(colorIndex))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }

            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(DS.Text.controlEmphasis)
                    .frame(minWidth: 48)
                    .focused($renameFocused)
                    .onSubmit { perform(.commitRename(tab.id, renameDraft)) }
                    .onExitCommand { perform(.cancelRename) }
                    .onAppear {
                        renameDraft = tab.name
                        renameFocused = true
                    }
            } else {
                Text(tab.name)
                    .font(isSelected ? DS.Text.controlEmphasis : DS.Text.control)
                    .lineLimit(1)
            }

            if tab.pendingChangeCount > 0 {
                Circle()
                    .fill(DS.Chrome.accent)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(isSelected ? DS.Chrome.onAccent : DS.Chrome.primary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.xs)
        .background {
            if isSelected {
                Capsule(style: .continuous).fill(DS.Chrome.accent)
            } else if draggingID == tab.id {
                Capsule(style: .continuous).fill(DS.Chrome.separator)
            }
        }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture(count: 2) { if state.isEditable { perform(.beginRename(tab.id)) } }
        .onTapGesture { perform(.select(tab.id)) }
        .contextMenu { contextMenu(for: tab) }
        .draggable(String(tab.id.rawValue)) {
            Text(tab.name).font(DS.Text.control)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let value = Int32(raw),
                  let from = state.visibleTabs.firstIndex(where: { $0.id.rawValue == value }),
                  from != index else { return false }
            perform(.reorder(from: from, to: index))
            return true
        } isTargeted: { targeted in
            draggingID = targeted ? tab.id : nil
        }
        .animation(DS.Motion.snappy, value: isSelected)
        .accessibilityLabel(accessibilityLabel(for: tab))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func contextMenu(for tab: SheetTabItem) -> some View {
        Button("Rename…") { perform(.beginRename(tab.id)) }
        Button("Duplicate") { perform(.duplicate(tab.id)) }
        Divider()
        Menu("Colour") {
            Button("None") { perform(.setColor(tab.id, nil)) }
            ForEach(Array(Palette.tabSwatches.enumerated()), id: \.offset) { index, swatch in
                Button(swatch.name) { perform(.setColor(tab.id, index)) }
            }
        }
        Button("Hide") { perform(.setVisibility(tab.id, .hidden)) }
        Divider()
        Button("Delete", role: .destructive) { perform(.delete(tab.id)) }
    }

    private func swatch(_ index: Int) -> Color {
        let entry = Palette.tabSwatches[index]
        return context.pick(light: entry.light, dark: entry.dark).color
    }

    private func accessibilityLabel(for tab: SheetTabItem) -> String {
        var label = tab.name
        if let colorIndex = tab.colorIndex, colorIndex < Palette.tabSwatches.count {
            label += ", \(Palette.tabSwatches[colorIndex].name)"
        }
        if tab.pendingChangeCount > 0 {
            label += ", \(tab.pendingChangeCount) pending changes"
        }
        return label
    }
}
