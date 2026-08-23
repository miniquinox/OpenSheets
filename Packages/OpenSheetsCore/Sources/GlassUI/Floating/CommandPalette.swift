import SwiftUI

/// One thing the palette can do.
public struct CommandItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    /// The sheet a "go to" command lands on, the signature of a function, the value of a cell.
    public var subtitle: String?
    public var symbol: String
    /// Already composed as glyphs (`"⌘R"`). Display only.
    public var shortcut: String?
    /// False for a command that exists but cannot run right now — "Refresh" with nothing to
    /// refresh. Shown dimmed rather than hidden, so the palette's contents are stable enough to
    /// learn.
    public var isEnabled: Bool

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        shortcut: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.shortcut = shortcut
        self.isEnabled = isEnabled
    }
}

public struct CommandSection: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var items: [CommandItem]

    public init(id: String, title: String, items: [CommandItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct CommandPaletteState: Sendable, Hashable {
    public var query: String
    /// Already filtered and ordered by the caller. The palette does not own the command registry
    /// — A8 does, because half the commands are menu items and the menu bar is the source of
    /// truth for what the app can do.
    public var sections: [CommandSection]
    public var selectedID: String?
    /// Set while an async source (a function search, a cell scan) is still returning.
    public var isSearching: Bool

    public init(
        query: String = "",
        sections: [CommandSection] = [],
        selectedID: String? = nil,
        isSearching: Bool = false
    ) {
        self.query = query
        self.sections = sections
        self.selectedID = selectedID
        self.isSearching = isSearching
    }

    public var allItems: [CommandItem] { sections.flatMap(\.items) }
    public var isEmpty: Bool { allItems.isEmpty }
}

public enum CommandPaletteAction: Sendable, Hashable {
    case queryChanged(String)
    /// `-1` for up, `+1` for down. Wrapping is the caller's decision, because whether the list
    /// wraps depends on whether it is complete.
    case moveSelection(Int)
    case run(String)
    case dismiss
}

/// ⌘K. Go to a cell, run a function, switch sheet, ask Claude.
///
/// A floating card, centred, over a dimmed window. The field sits *inside* the card rather than
/// above it, so the palette is one object rather than a search box with results hanging off it —
/// which is what makes it feel like a single surface you summoned rather than a menu.
public struct CommandPalette: View {
    private let state: CommandPaletteState
    private let context: AppearanceContext
    private let perform: (CommandPaletteAction) -> Void

    @FocusState private var isFieldFocused: Bool

    public init(
        state: CommandPaletteState,
        context: AppearanceContext,
        perform: @escaping (CommandPaletteAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(spacing: 0) {
            field
            if !state.isEmpty {
                Divider().overlay(DS.Chrome.separator(context))
                results
            } else if !state.query.isEmpty {
                empty
            }
        }
        .frame(width: 520)
        .glassCard(context: context)
        .onAppear { isFieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command palette")
    }

    private var field: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: state.isSearching ? "ellipsis" : "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Chrome.secondary)
                .symbolEffect(.pulse, isActive: state.isSearching && !context.reduceMotion)

            TextField(
                "Go to a cell, run a command, switch sheet…",
                text: Binding(
                    get: { state.query },
                    set: { perform(.queryChanged($0)) }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .focused($isFieldFocused)
            .onSubmit {
                if let id = state.selectedID { perform(.run(id)) }
            }
            .onExitCommand { perform(.dismiss) }
            .onKeyPress(.upArrow) {
                perform(.moveSelection(-1))
                return .handled
            }
            .onKeyPress(.downArrow) {
                perform(.moveSelection(1))
                return .handled
            }
            .accessibilityLabel("Command query")

            if !state.query.isEmpty {
                Button { perform(.queryChanged("")) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.Chrome.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.l)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(state.sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            CommandRow(
                                item: item,
                                isSelected: item.id == state.selectedID,
                                context: context
                            ) { perform(.run(item.id)) }
                        }
                    } header: {
                        Text(section.title)
                            .dsSectionLabel()
                            .padding(.horizontal, DS.Space.xl)
                            .padding(.top, DS.Space.m)
                            .padding(.bottom, DS.Space.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, DS.Space.s)
        }
        .frame(maxHeight: 340)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var empty: some View {
        VStack(spacing: DS.Space.xs) {
            Text("Nothing matches “\(state.query)”")
                .font(DS.Text.body)
                .foregroundStyle(DS.Chrome.secondary)
            Text("Try a cell reference like D14, a sheet name, or a function.")
                .font(DS.Text.caption)
                .foregroundStyle(DS.Chrome.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.xl)
    }
}

public struct CommandRow: View {
    private let item: CommandItem
    private let isSelected: Bool
    private let context: AppearanceContext
    private let action: () -> Void

    public init(
        item: CommandItem,
        isSelected: Bool,
        context: AppearanceContext,
        action: @escaping () -> Void
    ) {
        self.item = item
        self.isSelected = isSelected
        self.context = context
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? DS.Chrome.accent : DS.Chrome.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title)
                        .font(DS.Text.body)
                        .foregroundStyle(DS.Chrome.primary)
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(DS.Text.mono)
                            .foregroundStyle(DS.Chrome.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: DS.Space.m)

                if let shortcut = item.shortcut {
                    ShortcutHint(shortcut)
                }
            }
            .opacity(item.isEnabled ? 1 : 0.45)
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.s)
            .background {
                if isSelected {
                    DS.Radius.shape(DS.Radius.control)
                        .fill(DS.Chrome.selectedRow)
                        .padding(.horizontal, DS.Space.m)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
        .accessibilityLabel(item.subtitle.map { "\(item.title), \($0)" } ?? item.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Subsequence matching with a bias toward word starts.
///
/// Lives in the design system because the palette is the only thing that uses it and because the
/// *ranking* is a design decision: typing `sd` should find "**S**ort **d**escending" before it
/// finds "**s**hare**d** strings", and that preference is what makes a palette feel like it read
/// your mind rather than like it ran a filter.
///
/// Deliberately not a full fuzzy library. No transposition, no typo tolerance, no learned
/// frecency — those need usage data this app does not collect (PLAN.md §11: no telemetry).
public enum CommandFuzzy {
    /// `nil` when the query is not a subsequence of the candidate. Higher is better.
    public static func score(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let queryChars = Array(query.lowercased())
        let candidateChars = Array(candidate)
        var score = 0
        var queryIndex = 0
        var previousMatched = false

        for (position, character) in candidateChars.enumerated() {
            guard queryIndex < queryChars.count else { break }
            guard Character(character.lowercased()) == queryChars[queryIndex] else {
                previousMatched = false
                continue
            }
            score += 1
            // A match at the start of a word is worth much more than one in the middle.
            let isWordStart = position == 0
                || candidateChars[position - 1] == " "
                || candidateChars[position - 1] == "."
                || (character.isUppercase && !candidateChars[position - 1].isUppercase)
            if isWordStart { score += 8 }
            // Consecutive matches read as a prefix, which is what people are usually typing.
            if previousMatched { score += 4 }
            previousMatched = true
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }
        // Shorter candidates win ties: "Sum" before "Summarise selection".
        return score * 100 - candidateChars.count
    }

    /// Filters and ranks in one pass. Stable for equal scores, so a caller's own ordering
    /// survives inside a score band.
    public static func rank<T>(
        _ items: [T],
        query: String,
        by text: (T) -> String
    ) -> [T] {
        guard !query.isEmpty else { return items }
        return items
            .compactMap { item -> (T, Int)? in
                score(query: query, candidate: text(item)).map { (item, $0) }
            }
            .enumerated()
            .sorted { left, right in
                left.element.1 == right.element.1
                    ? left.offset < right.offset
                    : left.element.1 > right.element.1
            }
            .map(\.element.0)
    }
}
