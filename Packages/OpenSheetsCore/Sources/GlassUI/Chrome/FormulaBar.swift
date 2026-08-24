import SheetModel
import SwiftUI

/// A defined name, as the name box lists it.
public struct DefinedNameItem: Sendable, Hashable, Identifiable {
    public var name: String
    /// `Sheet1!$A$1:$D$20`, already formatted. Shown as the subtitle so a name is picked by what
    /// it points at, not by remembering.
    public var rangeLabel: String
    /// A name scoped to one sheet rather than the workbook.
    public var scope: String?

    public init(name: String, rangeLabel: String, scope: String? = nil) {
        self.name = name
        self.rangeLabel = rangeLabel
        self.scope = scope
    }

    public var id: String { scope.map { "\($0)!\(name)" } ?? name }
}

/// Everything the formula bar renders from.
public struct FormulaBarState: Sendable, Hashable {
    /// What the name box shows: `A1`, `B2:D9`, or a defined name when the selection matches one.
    public var nameBoxText: String
    /// The workbook's defined names, for the picker.
    public var definedNames: [DefinedNameItem]
    /// **The active cell's whole content, exactly as it is edited.** A formula arrives with its
    /// leading `=` already on it; a literal arrives as the round-trippable text — `1234.5`, not
    /// `£1,234.50`. Empty for an empty cell.
    ///
    /// This used to be *"the formula source, without the leading `=`"*, and the bar put the `=`
    /// back itself. That contract could only ever describe a formula: every text cell and every
    /// typed number reached it as an empty string, because the alternative was rendering
    /// `=Line item`. The prefix now comes from the caller, which is the only place that knows
    /// whether there is one — and the caller passes the same string it seeds the in-cell editor
    /// with, so the bar and the cell cannot disagree about what is in the cell.
    public var text: String
    /// True while the user is typing — in this field **or** in the cell, which mirror each other.
    /// Changes the field's ink from "showing" to "editing" and swaps the trailing controls for
    /// commit/cancel.
    public var isEditing: Bool
    /// True when the user has pulled the bar open to see a long formula.
    public var isExpanded: Bool
    /// A problem A3 found, or a refusal the shell had to explain. Shown as a line under the
    /// field, never as an alert.
    public var diagnostic: String?
    /// Whether the field takes the caret.
    ///
    /// False for a read-only workbook, and false for a cell whose value is written by a formula
    /// anchored somewhere else — a spill or an array region, which Excel refuses to edit in
    /// pieces. The field still shows its content and still reports the click as
    /// ``FormulaBarAction/beginEditing`` in that state, so the shell can answer with a
    /// ``diagnostic`` saying which cell owns it. A click that does nothing at all is the bug this
    /// bar was reported for.
    public var isEditable: Bool

    public init(
        nameBoxText: String = "A1",
        definedNames: [DefinedNameItem] = [],
        text: String = "",
        isEditing: Bool = false,
        isExpanded: Bool = false,
        diagnostic: String? = nil,
        isEditable: Bool = true
    ) {
        self.nameBoxText = nameBoxText
        self.definedNames = definedNames
        self.text = text
        self.isEditing = isEditing
        self.isExpanded = isExpanded
        self.diagnostic = diagnostic
        self.isEditable = isEditable
    }
}

/// Where the caret goes after the formula bar commits.
///
/// A mirror of `GridKit.AdvanceDirection`, spelled again here because the chrome does not depend
/// on the grid and is not going to start. The shell maps one onto the other in one line.
public enum FormulaBarAdvance: Sendable, Hashable {
    /// Return.
    case down
    /// Shift-Return.
    case up
    /// Tab.
    case forward
    /// Shift-Tab.
    case backward
    /// The tick button: commit, and leave the selection where it is.
    case stay
}

/// Everything the formula bar can ask for.
public enum FormulaBarAction: Sendable, Hashable {
    /// The user typed. Sent on every keystroke so A8 can live-highlight the referenced ranges in
    /// the grid, which is the feature that makes a formula bar worth having.
    case textChanged(String)
    /// Return, Tab, or clicking the tick. `advance` says where the caret goes afterwards.
    case commit(String, advance: FormulaBarAdvance)
    /// Escape, or clicking the cross.
    case cancel
    /// The field took the caret, or was clicked while it could not take it. The shell answers by
    /// starting the edit, or by refusing it with a reason in ``FormulaBarState/diagnostic``.
    case beginEditing
    /// A name or an address was entered in the name box.
    case navigate(String)
    /// A defined name was picked from the menu.
    case selectDefinedName(String)
    /// The `fx` button.
    case insertFunction
    /// The disclosure chevron at the right end.
    case toggleExpanded
}

/// Name box · `fx` · field.
///
/// One chrome lens, three regions, in the order Excel put them thirty years ago — because every
/// person who will use this app already knows where the name box is, and moving it buys nothing.
///
/// # The field is one live `TextField` under a coloured `Text`
///
/// A `TextField` cannot render an `AttributedString`, so the syntax colouring has to come from a
/// `Text`. The first version of this file drew that `Text` inside a `Button` and swapped in a
/// `TextField` on click — and that is the arrangement the bug report was about, because a
/// `Button` cannot take a caret: the click fired an action, the field never focused, and there
/// was nowhere for the next keystroke to go.
///
/// So the `TextField` is now **always there**, always holding the real text, and the coloured
/// `Text` sits on top of it with `allowsHitTesting(false)` until the field takes focus. The click
/// lands in the field, through the transparent overlay, and AppKit puts the insertion point at
/// the character the pointer was over — which is what "click into a formula to edit it" means
/// and what no amount of `beginEditing` plumbing can reproduce after the fact. Both layers use
/// `DS.Text.formula` so the glyphs the user aimed at are exactly the glyphs the field measures.
///
/// The one case that keeps the old shape is ``FormulaBarState/isEditable`` being `false`: there
/// the `Button` is right, because the click has to reach the shell to be *refused out loud*
/// rather than silently swallowed by a disabled control.
public struct FormulaBar: View {
    private let state: FormulaBarState
    private let context: AppearanceContext
    private let perform: (FormulaBarAction) -> Void

    @State private var draft: String = ""
    @FocusState private var isFieldFocused: Bool

    public init(
        state: FormulaBarState,
        context: AppearanceContext,
        perform: @escaping (FormulaBarAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                nameBox
                divider
                functionButton
                field
                trailingControls
            }
            if let diagnostic = state.diagnostic {
                Label(diagnostic, systemImage: "exclamationmark.circle")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Signal.errorInk(context))
                    .padding(.leading, DS.Space.m)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .glassChrome(context: context, radius: DS.Radius.control)
        .onAppear { draft = state.text }
        .onChange(of: state.text) { _, newValue in
            if !isFieldFocused { draft = newValue }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Formula bar")
    }

    // MARK: Name box

    private var nameBox: some View {
        Menu {
            if state.definedNames.isEmpty {
                Text("No defined names")
            } else {
                ForEach(state.definedNames) { item in
                    Button {
                        perform(.selectDefinedName(item.name))
                    } label: {
                        Text("\(item.name)   \(item.rangeLabel)")
                    }
                }
            }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(state.nameBoxText)
                    .font(DS.Text.formula)
                    .foregroundStyle(DS.Chrome.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DS.Chrome.tertiary)
            }
            .frame(minWidth: 76, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Cell reference or defined name")
        .accessibilityLabel("Name box, \(state.nameBoxText)")
    }

    private var divider: some View {
        Rectangle()
            .fill(DS.Chrome.separator(context))
            .frame(width: DS.Stroke.hairline(context), height: 16)
            .accessibilityHidden(true)
    }

    private var functionButton: some View {
        Button { perform(.insertFunction) } label: {
            Text("fx")
                .font(.system(size: 12, weight: .semibold, design: .serif))
                .italic()
                .foregroundStyle(DS.Chrome.accent)
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!state.isEditable)
        .help("Insert function")
        .accessibilityLabel("Insert function")
    }

    // MARK: Field

    @ViewBuilder
    private var field: some View {
        if state.isEditable {
            editableField
        } else {
            refusableField
        }
    }

    /// Whether the field is showing raw, editable source rather than the coloured reading copy.
    private var isEditingSource: Bool { state.isEditing || isFieldFocused }

    private var editableField: some View {
        ZStack(alignment: .leading) {
            TextField("", text: $draft, axis: state.isExpanded ? .vertical : .horizontal)
                .textFieldStyle(.plain)
                .font(DS.Text.formula)
                .foregroundStyle(DS.Chrome.primary)
                .lineLimit(state.isExpanded ? 5 : 1)
                .focused($isFieldFocused)
                // Zero opacity, not `.hidden()` and not a conditional branch: the field has to
                // stay hit-testable so the click that reveals it is the same click that places
                // the caret, and it has to keep its identity so the caret survives the reveal.
                .opacity(isEditingSource ? 1 : 0)
                .onChange(of: isFieldFocused) { _, focused in if focused { perform(.beginEditing) } }
                .onChange(of: draft) { _, newValue in perform(.textChanged(newValue)) }
                .onSubmit { end(.commit(draft, advance: .down)) }
                .onExitCommand { end(.cancel) }
                // Tab never reaches `onSubmit` — AppKit's key view loop takes it first — so it is
                // claimed here, before the loop, and spends it the way a spreadsheet does.
                .onKeyPress(keys: [.tab]) { press in
                    end(.commit(draft, advance: press.modifiers.contains(.shift) ? .backward : .forward))
                    return .handled
                }
                .accessibilityLabel("Formula")

            highlighted
                .opacity(isEditingSource ? 0 : 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// The read-only presentation: still legible, still clickable, and the click is answered.
    private var refusableField: some View {
        Button { perform(.beginEditing) } label: {
            highlighted.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
    }

    private var highlighted: some View {
        Text(FormulaSyntax.highlight(state.text, context: context))
            .font(DS.Text.formula)
            .lineLimit(state.isExpanded ? 5 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityText: String {
        state.text.isEmpty ? "Formula, empty" : "Formula, \(state.text)"
    }

    /// Ends the edit: hands the action to the shell, then gives the caret back.
    ///
    /// Releasing focus is half the action, not tidying up. `isFieldFocused` is what keeps the raw
    /// source on screen in place of the coloured reading copy, and it is what stops `draft` being
    /// resynced from the model — so a commit or a cancel that left it set would show the abandoned
    /// text for as long as the window stayed open.
    private func end(_ action: FormulaBarAction) {
        perform(action)
        isFieldFocused = false
    }

    // MARK: Trailing

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: DS.Space.xs) {
            if isEditingSource {
                Button { end(.cancel) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Chrome.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel edit")

                Button { end(.commit(draft, advance: .stay)) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Chrome.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Commit edit")
            }

            Button { perform(.toggleExpanded) } label: {
                Image(systemName: state.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.Chrome.tertiary)
            }
            .buttonStyle(.plain)
            .help(state.isExpanded ? "Collapse formula bar" : "Expand formula bar")
            .accessibilityLabel(state.isExpanded ? "Collapse formula bar" : "Expand formula bar")
        }
    }
}

/// Turns a selection into the string the name box shows.
///
/// Lives here rather than in A8 because the rule — a single cell shows as `A1`, a range as
/// `A1:D9`, and a range that exactly matches a defined name shows the *name* — is a presentation
/// rule, and getting it wrong is a design bug rather than a data bug.
public enum NameBoxLabel {
    public static func text(for range: CellRange, definedNames: [DefinedNameItem] = []) -> String {
        let formatted = A1Notation.format(sheetName: nil, range: range)
        if let match = definedNames.first(where: { $0.rangeLabel == formatted }) {
            return match.name
        }
        return formatted
    }
}
