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
/// # The field is the text — there is no second copy of it
///
/// Two earlier arrangements are worth naming, because both of them lost formulas and both looked
/// reasonable on the way in.
///
/// The first drew the coloured `Text` inside a `Button` and swapped in a `TextField` on click. A
/// `Button` cannot take a caret, so the click fired an action and the keyboard stayed where it
/// was. The second kept a live `TextField` at `opacity(0)` *underneath* the coloured `Text`, so
/// the click would fall through to it. That one focused — but it was invisible, which meant the
/// select-all every `NSTextField` performs on focus was invisible too, so the first character
/// typed replaced the whole cell with no caret, no selection and no warning.
///
/// So the field is now ``FormulaSourceField``: one visible `NSTextView` that holds the real
/// characters, colours them, and shows the caret AppKit is actually using. Nothing is layered
/// over it, nothing is mirrored into it, and there is no state in which the thing you are looking
/// at is not the thing you are editing. The failure modes it closes are written up on that type.
///
/// The one case that keeps the old shape is ``FormulaBarState/isEditable`` being `false`: there
/// the `Button` is right, because the click has to reach the shell to be *refused out loud*
/// rather than silently swallowed by a disabled control.
public struct FormulaBar: View {
    private let state: FormulaBarState
    private let context: AppearanceContext
    private let perform: (FormulaBarAction) -> Void

    /// What the field is showing. Tracks the document while the caret is elsewhere, and the
    /// field's own storage while it is being typed in.
    @State private var draft: String = ""
    /// AppKit's answer, not SwiftUI's. `@FocusState` is what the previous version asked, and it
    /// is a *transition*: a field that already held the caret reported nothing when it was
    /// clicked again, so the second click and every click after it told the document nothing.
    @State private var isFieldFocused: Bool = false
    @State private var handle = FormulaFieldHandle()

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
        .hoverTitle("Cell reference or defined name")
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
        .hoverTitle("Insert function")
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

    /// Whether the trailing controls are the commit/cancel pair rather than the disclosure alone.
    private var isEditingSource: Bool { state.isEditing || isFieldFocused }

    private var editableField: some View {
        FormulaSourceField(
            text: draft,
            isExpanded: state.isExpanded,
            appearance: context,
            onBeginEditing: { perform(.beginEditing) },
            onTextChanged: { typed in
                draft = typed
                perform(.textChanged(typed))
            },
            onCommit: { typed, advance in
                draft = typed
                perform(.commit(typed, advance: advance))
            },
            // The field has already put the original characters back by the time this arrives, so
            // the bar shows the cell's content again whether or not the document answers.
            onCancel: { restored in
                draft = restored
                perform(.cancel)
            },
            onFocusChange: { isFieldFocused = $0 },
            handle: handle
        )
        .frame(maxWidth: .infinity)
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
        Text(FormulaSyntax.display(state.text, context: context))
            .font(DS.Text.formula)
            .lineLimit(state.isExpanded ? 5 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityText: String {
        state.text.isEmpty ? "Formula, empty" : "Formula, \(state.text)"
    }

    /// The tick. Goes through the field so the caret is released before the shell moves it, which
    /// is the same order Return takes.
    private func commitFromButton() {
        handle.releaseFocus()
        perform(.commit(draft, advance: .stay))
    }

    /// The cross. **Restores through the field**, not by waiting for the document to push the old
    /// text back: a click on a button is not a focus change, so nothing else would resync the
    /// characters on screen, and the bar would go on showing the abandoned edit.
    private func cancelFromButton() {
        if let restored = handle.restore() { draft = restored }
        perform(.cancel)
    }

    // MARK: Trailing

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: DS.Space.xs) {
            if isEditingSource {
                Button { cancelFromButton() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.Chrome.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel edit")

                Button { commitFromButton() } label: {
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
            .hoverTitle(state.isExpanded ? "Collapse formula bar" : "Expand formula bar")
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
