import SheetModel
import SwiftUI

// MARK: - Value types

/// Horizontal cell alignment, as the toolbar sees it.
///
/// A local enum rather than `SwiftUI.TextAlignment` because the toolbar has a fourth state Excel
/// has and SwiftUI does not: *general*, where numbers go right and text goes left. It is the
/// default for every cell in every spreadsheet ever made, and losing it would mean a fresh file
/// shows every column left-aligned.
public enum CellAlign: String, Sendable, Hashable, CaseIterable, Codable {
    case general
    case leading
    case center
    case trailing

    public var symbolName: String {
        switch self {
        case .general: "text.alignleft"
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }

    public var label: String {
        switch self {
        case .general: "General alignment"
        case .leading: "Align left"
        case .center: "Align centre"
        case .trailing: "Align right"
        }
    }
}

/// The number-format presets the toolbar offers.
///
/// Seven, not the full OOXML format-code space. Anything else is typed into the inspector as a
/// format code; this is the ribbon, and a ribbon that offers everything offers nothing.
public enum NumberFormatChoice: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    case general
    case number
    case currency
    case percent
    case scientific
    case date
    case text

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: "General"
        case .number: "Number"
        case .currency: "Currency"
        case .percent: "Percent"
        case .scientific: "Scientific"
        case .date: "Date"
        case .text: "Text"
        }
    }

    /// Shown next to the name in the menu, so the choice is made by recognition rather than by
    /// remembering what "Scientific" does to 1234.5.
    public var sample: String {
        switch self {
        case .general: "1234.5"
        case .number: "1,234.50"
        case .currency: "$1,234.50"
        case .percent: "123,450%"
        case .scientific: "1.23E+03"
        case .date: "6 May 1903"
        case .text: "1234.5"
        }
    }
}

/// What the sum button inserts.
public enum AutoSumFunction: String, Sendable, Hashable, CaseIterable, Codable, Identifiable {
    case sum
    case average
    case count
    case min
    case max

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
}

/// Everything the toolbar renders from. A plain value; the toolbar reads nothing else.
public struct ToolbarState: Sendable, Hashable {
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    public var alignment: CellAlign
    public var wrapsText: Bool
    public var isMerged: Bool
    public var numberFormat: NumberFormatChoice
    public var fontName: String
    public var fontSize: Double
    /// The selection's text colour, or `nil` when it is automatic or the cells disagree. Resolved
    /// by the app layer, because turning a ``SheetModel/StyleColor`` into a `Color` needs the
    /// document's palette and `GlassUI` does not have one.
    public var textColor: Color?
    /// The selection's fill, or `nil` for none.
    public var fillColor: Color?
    /// Whether the pasteboard holds something we can take.
    public var canPaste: Bool
    /// Whether anything is selected. Almost everything is disabled without a selection, and
    /// showing it disabled is better than showing it enabled and having it do nothing.
    public var hasSelection: Bool
    /// False for a read-only workbook (PLAN.md §5.2: we open rather than refuse, but we do not
    /// pretend it is editable).
    public var isEditable: Bool

    public init(
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        alignment: CellAlign = .general,
        wrapsText: Bool = false,
        isMerged: Bool = false,
        numberFormat: NumberFormatChoice = .general,
        fontName: String = "Calibri",
        fontSize: Double = 11,
        textColor: Color? = nil,
        fillColor: Color? = nil,
        canPaste: Bool = true,
        hasSelection: Bool = true,
        isEditable: Bool = true
    ) {
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.alignment = alignment
        self.wrapsText = wrapsText
        self.isMerged = isMerged
        self.numberFormat = numberFormat
        self.fontName = fontName
        self.fontSize = fontSize
        self.textColor = textColor
        self.fillColor = fillColor
        self.canPaste = canPaste
        self.hasSelection = hasSelection
        self.isEditable = isEditable
    }
}

/// Everything the toolbar can ask for.
public enum ToolbarAction: Sendable, Hashable {
    case cut
    case copy
    case paste
    case pasteValuesOnly
    case pasteFormatsOnly

    case toggleBold
    case toggleItalic
    case toggleUnderline
    case setFontName(String)
    case setFontSize(Double)
    /// The text colour. ``SheetModel/StyleColor/automatic`` is "whatever the grid says", which is
    /// how text stays legible when the canvas is dark — so it is a real choice, not a clear.
    case setTextColor(StyleColor)
    /// The cell's background, or `nil` for no fill at all. `nil` rather than white, because a
    /// white fill and no fill look identical on screen and behave differently everywhere else:
    /// printing, banded rows, and every conditional format underneath.
    case setFillColor(StyleColor?)

    case setAlignment(CellAlign)
    case toggleWrapText
    case toggleMerge

    case setNumberFormat(NumberFormatChoice)
    case increaseDecimals
    case decreaseDecimals

    case insertRows
    case insertColumns
    case deleteRows
    case deleteColumns

    case autoSum(AutoSumFunction)
    case find
    case sortAscending
    case sortDescending
    case toggleFilter
}

// MARK: - The bar

/// A distilled Excel Home ribbon: clipboard, font, alignment, number, structure, sum, find.
///
/// **One ``GlassCluster`` per group, not one for the whole bar.** Merging the entire ribbon into a
/// single lens loses the grouping that makes a ribbon usable at a glance, and the groups are far
/// enough apart that they should not merge anyway. Inside a group the buttons are close enough
/// that the container resolves them as one continuous lens — which is the whole point, and the
/// difference between this and seven translucent rectangles.
///
/// Overflow: at narrow widths the tail groups collapse into a single `Menu`. `ViewThatFits` picks
/// the widest arrangement that fits, so there is no width breakpoint to keep in sync with the
/// window's minimum size.
public struct ToolbarSurface: View {
    private let state: ToolbarState
    private let context: AppearanceContext
    private let perform: (ToolbarAction) -> Void

    public init(
        state: ToolbarState,
        context: AppearanceContext,
        perform: @escaping (ToolbarAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            full
            medium
            compact
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formatting toolbar")
    }

    private var full: some View {
        HStack(spacing: DS.Space.l) {
            clipboard
            font
            alignment
            number
            structure
            formulas
            search
        }
    }

    private var medium: some View {
        HStack(spacing: DS.Space.l) {
            clipboard
            font
            alignment
            number
            overflow
        }
    }

    private var compact: some View {
        HStack(spacing: DS.Space.l) {
            font
            alignment
            overflow
        }
    }

    // MARK: Groups

    private var clipboard: some View {
        ToolbarGroup {
            GlassIconButton(
                symbol: "scissors", label: "Cut", isEnabled: enabled, shortcut: "⌘X",
                context: context
            ) { perform(.cut) }
            GlassIconButton(
                symbol: "doc.on.doc", label: "Copy", isEnabled: state.hasSelection, shortcut: "⌘C",
                context: context
            ) { perform(.copy) }
            ToolbarMenuButton(
                symbol: "clipboard",
                label: "Paste",
                isEnabled: enabled && state.canPaste,
                shortcut: "⌘V",
                context: context
            ) {
                Button("Paste") { perform(.paste) }
                Button("Paste values only") { perform(.pasteValuesOnly) }
                Button("Paste formats only") { perform(.pasteFormatsOnly) }
            }
        }
    }

    private var font: some View {
        ToolbarGroup {
            GlassIconButton(
                symbol: "bold", label: "Bold", isOn: state.isBold, isEnabled: enabled,
                shortcut: "⌘B", context: context
            ) { perform(.toggleBold) }
            GlassIconButton(
                symbol: "italic", label: "Italic", isOn: state.isItalic, isEnabled: enabled,
                shortcut: "⌘I", context: context
            ) { perform(.toggleItalic) }
            GlassIconButton(
                symbol: "underline", label: "Underline", isOn: state.isUnderline,
                isEnabled: enabled, shortcut: "⌘U", context: context
            ) { perform(.toggleUnderline) }
            colorMenu(
                symbol: "character",
                label: "Text colour",
                bar: state.textColor,
                resetTitle: "Automatic"
            ) { perform(.setTextColor($0.map { StyleColor.rgb($0.color) } ?? .automatic)) }
            colorMenu(
                symbol: "paintbrush.fill",
                label: "Fill colour",
                bar: state.fillColor,
                resetTitle: "No Fill"
            ) { perform(.setFillColor($0.map { StyleColor.rgb($0.color) })) }
        }
    }

    /// A colour control: the toolbar's own menu button, with the swatches inside it.
    ///
    /// ``ToolbarMenuButton``, not a `Menu` dressed to look like one. That was the first attempt and
    /// it is the mistake the type's own doc comment already warns about: a `Menu` with
    /// `.buttonStyle(.glass)` does not give its label vibrancy, so the glyph keeps one colour while
    /// the lens takes the grid's — and over a white column the control disappears. It also read as
    /// two loose glyphs beside a row of buttons, which is what made it obvious.
    ///
    /// The grid is built out of plain menu rows rather than a `LazyVGrid`, because a grid inside
    /// an AppKit menu does not lay out — it collapses to nothing and the menu opens empty.
    private func colorMenu(
        symbol: String,
        label: String,
        bar: Color?,
        resetTitle: String,
        perform apply: @escaping (CellSwatches.Swatch?) -> Void
    ) -> some View {
        ToolbarMenuButton(symbol: symbol, label: label, isEnabled: enabled, bar: bar, context: context) {
            Button(resetTitle) { apply(nil) }
            Divider()
            ForEach(Array(CellSwatches.all.enumerated()), id: \.offset) { _, row in
                ForEach(row) { swatch in
                    Button {
                        apply(swatch)
                    } label: {
                        Label {
                            Text(swatch.name)
                        } icon: {
                            Image(systemName: "square.fill").foregroundStyle(swatch.display)
                        }
                    }
                }
                Divider()
            }
        }
    }

    private var alignment: some View {
        ToolbarGroup {
            ForEach([CellAlign.leading, .center, .trailing], id: \.self) { align in
                GlassIconButton(
                    symbol: align.symbolName,
                    label: align.label,
                    isOn: state.alignment == align,
                    isEnabled: enabled,
                    context: context
                ) { perform(.setAlignment(align)) }
            }
            GlassIconButton(
                symbol: "text.append",
                label: "Wrap text",
                isOn: state.wrapsText,
                isEnabled: enabled,
                context: context
            ) { perform(.toggleWrapText) }
            GlassIconButton(
                symbol: "square.split.1x2",
                label: "Merge cells",
                isOn: state.isMerged,
                isEnabled: enabled,
                shortcut: "⌃⌘M",
                context: context
            ) { perform(.toggleMerge) }
        }
    }

    private var number: some View {
        ToolbarGroup {
            ToolbarMenuButton(
                symbol: "numbersign",
                label: "Number format: \(state.numberFormat.label)",
                isEnabled: enabled,
                context: context
            ) {
                ForEach(NumberFormatChoice.allCases) { choice in
                    Button {
                        perform(.setNumberFormat(choice))
                    } label: {
                        Text("\(choice.label)   \(choice.sample)")
                    }
                }
            }
            GlassIconButton(
                symbol: "increase.quotelevel", label: "Add a decimal place", isEnabled: enabled,
                context: context
            ) { perform(.increaseDecimals) }
            GlassIconButton(
                symbol: "decrease.quotelevel", label: "Remove a decimal place", isEnabled: enabled,
                context: context
            ) { perform(.decreaseDecimals) }
        }
    }

    private var structure: some View {
        ToolbarGroup {
            ToolbarMenuButton(
                symbol: "plus.rectangle", label: "Insert rows or columns",
                isEnabled: enabled, context: context
            ) {
                Button("Insert rows") { perform(.insertRows) }
                Button("Insert columns") { perform(.insertColumns) }
            }
            ToolbarMenuButton(
                symbol: "minus.rectangle", label: "Delete rows or columns",
                isEnabled: enabled, context: context
            ) {
                Button("Delete rows") { perform(.deleteRows) }
                Button("Delete columns") { perform(.deleteColumns) }
            }
        }
    }

    private var formulas: some View {
        ToolbarGroup {
            ToolbarMenuButton(
                symbol: "sum", label: "AutoSum", isEnabled: enabled, context: context
            ) {
                ForEach(AutoSumFunction.allCases) { function in
                    Button(function.label) { perform(.autoSum(function)) }
                }
            }
            ToolbarMenuButton(
                symbol: "arrow.up.arrow.down", label: "Sort and filter", isEnabled: state.hasSelection,
                context: context
            ) {
                Button("Sort ascending") { perform(.sortAscending) }
                Button("Sort descending") { perform(.sortDescending) }
                Divider()
                Button("Toggle filter") { perform(.toggleFilter) }
            }
        }
    }

    /// One button, so it needs no cluster of its own — and putting a lone lens in a container
    /// would be a container that merges nothing.
    private var search: some View {
        GlassIconButton(
            symbol: "magnifyingglass", label: "Find", shortcut: "⌘F", context: context
        ) { perform(.find) }
    }

    private var overflow: some View {
        ToolbarMenuButton(
            symbol: "ellipsis", label: "More formatting", isEnabled: true, context: context
        ) {
            Button("Insert rows") { perform(.insertRows) }
            Button("Insert columns") { perform(.insertColumns) }
            Button("Delete rows") { perform(.deleteRows) }
            Button("Delete columns") { perform(.deleteColumns) }
            Divider()
            ForEach(AutoSumFunction.allCases) { function in
                Button(function.label) { perform(.autoSum(function)) }
            }
            Divider()
            Button("Find…") { perform(.find) }
        }
    }

    private var enabled: Bool { state.isEditable && state.hasSelection }
}

/// A cluster of related toolbar controls: one lens, several buttons.
///
/// This is `GlassEffectContainer` and nothing else — no background, no padding of its own. The
/// buttons carry their own glass via `.buttonStyle(.glass)`; adding a glass background here would
/// put a lens behind a lens, which is the failure this whole type exists to prevent.
public struct ToolbarGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        GlassCluster(spacing: DS.Space.glassMerge) {
            HStack(spacing: DS.Space.xs) {
                content
            }
        }
    }
}

/// A glass toolbar button that opens a menu.
///
/// **The lens and the menu are two views, and that is not gratuitous.** `Menu` with
/// `.menuStyle(.button)` and `.buttonStyle(.glass)` produces a lens, but its label does not receive
/// the vibrancy that a plain `Button`'s label does — so the glyph keeps the colour scheme's label
/// colour while the lens takes its brightness from whatever the grid is showing underneath. Over a
/// white-filled column in a dark window that is a white glyph on a pale lens, and six of the
/// toolbar's controls simply vanished. It is invisible in a preview over a dark grid and obvious
/// the moment you test the combination PLAN.md §3.5 tells you to test.
///
/// So the visible control is a ``GlassIconButton`` — vibrant label, correct in both directions —
/// and the menu is an invisible `Menu` laid over it that takes the click. The button underneath
/// does nothing on its own; the overlay always wins the hit test.
public struct ToolbarMenuButton<Content: View>: View {
    private let symbol: String
    private let label: String
    private let isEnabled: Bool
    /// Shown after the label on hover, like ``GlassIconButton``'s.
    private let shortcut: String?
    /// Passed straight to the button beneath. See ``GlassIconButton``.
    private let bar: Color?
    private let context: AppearanceContext
    private let content: Content

    public init(
        symbol: String,
        label: String,
        isEnabled: Bool = true,
        shortcut: String? = nil,
        bar: Color? = nil,
        context: AppearanceContext,
        @ViewBuilder content: () -> Content
    ) {
        self.symbol = symbol
        self.label = label
        self.isEnabled = isEnabled
        self.shortcut = shortcut
        self.bar = bar
        self.context = context
        self.content = content()
    }

    /// Label, then the shortcut if there is one — the same shape ``GlassIconButton`` uses, so the
    /// two kinds of control in one group read identically on hover.
    private var helpText: String {
        ToolbarHelp.text(label: label, shortcut: shortcut)
    }

    public var body: some View {
        GlassIconButton(
            symbol: symbol,
            label: label,
            isEnabled: isEnabled,
            bar: bar,
            context: context
        ) {}
            .overlay {
                Menu {
                    content
                } label: {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(!isEnabled)
                .accessibilityHidden(true)
                // On the overlay, not only on the composed view. The overlay is what the pointer
                // is actually over, and a `.help` underneath it never gets asked — which is why
                // every menu button in this toolbar was silent on hover while the plain buttons
                // beside them were not.
                .help(helpText)
            }
            .help(helpText)
            .accessibilityLabel(helpText)
            .accessibilityAddTraits(.isButton)
    }
}
